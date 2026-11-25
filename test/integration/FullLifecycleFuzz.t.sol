// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { SharedSetup } from "test/integration/SharedSetup.sol";
import { MockERC20 } from "lib/solady/test/utils/mocks/MockERC20.sol";
import { ITurnstile } from "src/interfaces/ITurnstile.sol";
import { IUserConductor } from "src/interfaces/IUserConductor.sol";
import { ISpotSwapConductor } from "src/interfaces/ISpotSwapConductor.sol";
import { UserConductor } from "src/conductor/UserConductor.sol";

/// @dev Fuzzed end to end path: alice deposits USDG on Robinhood, transfers it to bob, bob swaps it all for USDC in
/// one batch against `mirrorCount` maker orders of `mirrorSize` each (one order filled by many), then bob withdraws
/// USDC on the hub and the maker withdraws the USDG to Robinhood. Amounts range from 1 unit to 1M tokens per mirror.
/// After every step, each asset's Depot supply (summed over every account that can hold it) must not exceed its VAULT.
contract FullLifecycleFuzz is SharedSetup {

    uint64 constant SPOKE = ROBINHOOD_CHAIN_ID;

    address alice;
    uint256 alicePk;
    address bob;
    uint256 bobPk;
    address maker;
    uint256 makerPk;
    MockERC20 robinhoodUsdg;

    function setUp() public override {
        super.setUp();
        (alice, alicePk) = makeAddrAndKey("alice");
        (bob, bobPk) = makeAddrAndKey("bob");
        (maker, makerPk) = makeAddrAndKey("maker");
        robinhoodUsdg = spokeUsdg[SPOKE];
    }

    function testFuzzDepositTransferSwapWithdraw(uint256 mirrorSize, uint256 mirrorCount) public {
        mirrorSize = bound(mirrorSize, 1, 1e12);
        mirrorCount = bound(mirrorCount, 1, 50);
        uint256 amount = mirrorSize * mirrorCount;

        _deposit(alice, SPOKE, robinhoodUsdg, HUB_CHAIN_ID, amount);
        _deposit(maker, HUB_CHAIN_ID, usdc, HUB_CHAIN_ID, amount);
        _assertBacked();
        _relayMessages();
        _assertBacked();
        assertEq(_balance(HUB_CHAIN_ID, alice, SPOKE), amount, "alice deposited");

        _transferToBob(amount);
        _assertBacked();
        assertEq(_balance(HUB_CHAIN_ID, alice, SPOKE), 0, "alice transferred");
        assertEq(_balance(HUB_CHAIN_ID, bob, SPOKE), amount, "bob received");

        _swap(amount, mirrorSize, mirrorCount);
        _assertBacked();
        bytes28 usdcId = _account(HUB_CHAIN_ID, address(usdc));
        assertEq(_balance(HUB_CHAIN_ID, bob, SPOKE), 0, "bob sold usdg");
        assertEq(depot.balanceOf(_account(HUB_CHAIN_ID, bob), usdcId), amount, "bob bought usdc");
        assertEq(depot.balanceOf(_account(HUB_CHAIN_ID, maker), usdcId), 0, "maker sold usdc");
        assertEq(_balance(HUB_CHAIN_ID, maker, SPOKE), amount, "maker bought usdg");

        _withdraw(bob, bobPk, HUB_CHAIN_ID, address(usdc), amount);
        _withdraw(maker, makerPk, SPOKE, address(robinhoodUsdg), amount);
        _assertBacked();
        _relayMessages();
        _assertBacked();

        assertEq(usdc.balanceOf(bob), amount, "bob withdrew usdc on hub");
        assertEq(robinhoodUsdg.balanceOf(maker), amount, "maker withdrew usdg on robinhood");
        assertEq(depot.balanceOf(_account(HUB_CHAIN_ID, bob), usdcId), 0, "bob depot usdc burned");
        assertEq(_balance(HUB_CHAIN_ID, maker, SPOKE), 0, "maker depot usdg burned");
        assertEq(usdc.balanceOf(VAULT), 0, "hub vault emptied");
        assertEq(robinhoodUsdg.balanceOf(VAULT), 0, "robinhood vault emptied");
    }

    function _assertBacked() internal view {
        assertLe(_supply(_account(SPOKE, address(robinhoodUsdg))), robinhoodUsdg.balanceOf(VAULT), "usdg backed");
        assertLe(_supply(_account(HUB_CHAIN_ID, address(usdc))), usdc.balanceOf(VAULT), "usdc backed");
    }

    function _supply(bytes28 assetId) internal view returns (uint256) {
        return depot.balanceOf(_account(HUB_CHAIN_ID, alice), assetId)
            + depot.balanceOf(_account(HUB_CHAIN_ID, bob), assetId)
            + depot.balanceOf(_account(HUB_CHAIN_ID, maker), assetId);
    }

    function _transferToBob(uint256 amount) internal {
        IUserConductor.TransferRequest memory request = IUserConductor.TransferRequest({
            ownerChainId: HUB_CHAIN_ID,
            owner: alice,
            toChainId: HUB_CHAIN_ID,
            to: bob,
            assetChainId: SPOKE,
            asset: address(robinhoodUsdg),
            amount: amount,
            deadline: type(uint256).max,
            partiallyFillable: false,
            salt: bytes32(0)
        });
        ITurnstile.GenericAction memory action = ITurnstile.GenericAction({
            ownerChainId: HUB_CHAIN_ID,
            owner: alice,
            target: address(userConductor),
            data: abi.encodeCall(UserConductor.executeTransfer, (request)),
            deadline: type(uint256).max,
            dependsOn: bytes32(0),
            salt: bytes32(0)
        });
        vm.chainId(HUB_CHAIN_ID);
        bytes memory signature = _sign(alicePk, turnstile.hashGenericAction(action));
        _facilitate(HUB_CHAIN_ID, ITurnstile.ActionType.Generic, abi.encode(action), signature);
    }

    function _swap(uint256 amount, uint256 mirrorSize, uint256 mirrorCount) internal {
        vm.chainId(HUB_CHAIN_ID);
        ISpotSwapConductor.Order memory bobOrder = ISpotSwapConductor.Order({
            ownerChainId: HUB_CHAIN_ID,
            owner: bob,
            sellTokenChainId: SPOKE,
            sellToken: address(robinhoodUsdg),
            buyTokenChainId: HUB_CHAIN_ID,
            buyToken: address(usdc),
            sellAmount: amount,
            buyAmount: amount,
            receiverChainId: HUB_CHAIN_ID,
            receiver: bob,
            expiresAt: type(uint256).max,
            partiallyFillable: true,
            salt: bytes32(0)
        });
        bytes memory bobSignature = _sign(bobPk, spotSwapConductor.hashOrder(bobOrder));
        ISpotSwapConductor.Fill memory fill = ISpotSwapConductor.Fill({ sellFilled: mirrorSize, buyFilled: mirrorSize });

        ISpotSwapConductor.OrderFill[] memory orderFills = new ISpotSwapConductor.OrderFill[](mirrorCount * 2);
        for (uint256 i; i < mirrorCount; i++) {
            ISpotSwapConductor.Order memory mirror = ISpotSwapConductor.Order({
                ownerChainId: HUB_CHAIN_ID,
                owner: maker,
                sellTokenChainId: HUB_CHAIN_ID,
                sellToken: address(usdc),
                buyTokenChainId: SPOKE,
                buyToken: address(robinhoodUsdg),
                sellAmount: mirrorSize,
                buyAmount: mirrorSize,
                receiverChainId: HUB_CHAIN_ID,
                receiver: maker,
                expiresAt: type(uint256).max,
                partiallyFillable: false,
                salt: bytes32(i)
            });
            orderFills[i * 2] = ISpotSwapConductor.OrderFill({ order: bobOrder, signature: bobSignature, fill: fill });
            orderFills[i * 2 + 1] = ISpotSwapConductor.OrderFill({
                order: mirror, signature: _sign(makerPk, spotSwapConductor.hashOrder(mirror)), fill: fill
            });
        }

        uint256 epoch = depot.settlementEpoch();
        vm.prank(SOLVER_ADDRESS);
        spotSwapConductor.settle(epoch, orderFills, new ISpotSwapConductor.Fee[](0));
        assertEq(spotSwapConductor.filledAmount(spotSwapConductor.hashOrder(bobOrder)), amount, "bob order filled");
    }

    function _withdraw(address owner, uint256 ownerPk, uint64 assetChainId, address asset, uint256 amount) internal {
        ITurnstile.WithdrawalAction memory action = ITurnstile.WithdrawalAction({
            ownerChainId: HUB_CHAIN_ID,
            owner: owner,
            to: owner,
            assetChainId: assetChainId,
            asset: asset,
            amount: amount,
            deadline: type(uint256).max,
            partiallyFillable: false,
            conductor: address(hubWarehouseConductor),
            dependsOn: bytes32(0),
            salt: bytes32(0)
        });
        vm.chainId(HUB_CHAIN_ID);
        bytes memory signature = _sign(ownerPk, turnstile.hashWithdrawalAction(action));
        _facilitate(HUB_CHAIN_ID, ITurnstile.ActionType.Withdrawal, abi.encode(action), signature);
    }

}
