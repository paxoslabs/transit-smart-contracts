// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { SharedSetup } from "test/integration/SharedSetup.sol";
import { MockERC20 } from "lib/solady/test/utils/mocks/MockERC20.sol";
import { ITurnstile } from "src/interfaces/ITurnstile.sol";
import { IDelayedSettlementSwapConductor } from "src/interfaces/IDelayedSettlementSwapConductor.sol";
import { DelayedSettlementSwapConductor } from "src/conductor/DelayedSettlementSwapConductor.sol";

contract DelayedSettlementHappyPaths is SharedSetup {

    uint64 constant SPOKE = ROBINHOOD_CHAIN_ID;
    uint256 constant AMOUNT = 100e6;
    uint256 constant COLLATERAL = 1e6;
    uint256 constant FEE = 1e6;
    uint256 constant PERIOD = 1 days;

    address alice;
    uint256 alicePk;
    address bob;
    uint256 bobPk;
    MockERC20 robinhoodUsdg;

    function setUp() public override {
        super.setUp();
        (alice, alicePk) = makeAddrAndKey("alice");
        (bob, bobPk) = makeAddrAndKey("bob");
        robinhoodUsdg = spokeUsdg[SPOKE];
    }

    /// @dev Neither order is collateralized, so the pair is escrowed and released in the same settle, each side paying
    /// a fee. bob then withdraws the USDG he bought to Robinhood.
    function testUncollateralizedPairReleasedInSettleThenWithdrawnToSpoke() public {
        _deposit(alice, SPOKE, robinhoodUsdg, HUB_CHAIN_ID, AMOUNT);
        _deposit(bob, HUB_CHAIN_ID, usdc, HUB_CHAIN_ID, AMOUNT);
        _relayMessages();

        IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders =
            new IDelayedSettlementSwapConductor.DelayedSettlementOrder[](2);
        orders[0] = _usdgForUsdc(HUB_CHAIN_ID, alice, AMOUNT - FEE, false);
        orders[1] = _usdcForUsdg(bob, AMOUNT - FEE, false);
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = _signOrder(alicePk, orders[0]);
        signatures[1] = _signOrder(bobPk, orders[1]);
        _settle(orders, signatures, FEE);

        assertEq(_balance(HUB_CHAIN_ID, alice, SPOKE), 0, "alice sold usdg");
        assertEq(_balance(HUB_CHAIN_ID, alice, HUB_CHAIN_ID, usdc), AMOUNT - FEE, "alice bought usdc less fee");
        assertEq(_balance(HUB_CHAIN_ID, bob, HUB_CHAIN_ID, usdc), 0, "bob sold usdc");
        assertEq(_balance(HUB_CHAIN_ID, bob, SPOKE), AMOUNT - FEE, "bob bought usdg less fee");
        assertEq(_balance(HUB_CHAIN_ID, SURPLUS_RECIPIENT, SPOKE), FEE, "usdg fee");
        assertEq(_balance(HUB_CHAIN_ID, SURPLUS_RECIPIENT, HUB_CHAIN_ID, usdc), FEE, "usdc fee");
        assertEq(delayedSettlementSwapConductor.escrowDeadline(1), 0, "escrow released");

        ITurnstile.WithdrawalAction memory withdrawal = ITurnstile.WithdrawalAction({
            ownerChainId: HUB_CHAIN_ID,
            owner: bob,
            to: bob,
            assetChainId: SPOKE,
            asset: address(robinhoodUsdg),
            amount: AMOUNT - FEE,
            deadline: type(uint256).max,
            partiallyFillable: false,
            conductor: address(hubWarehouseConductor),
            dependsOn: bytes32(0),
            salt: bytes32(0)
        });
        _facilitate(
            HUB_CHAIN_ID,
            ITurnstile.ActionType.Withdrawal,
            abi.encode(withdrawal),
            _sign(bobPk, turnstile.hashWithdrawalAction(withdrawal))
        );
        _relayMessages();
        assertEq(robinhoodUsdg.balanceOf(bob), AMOUNT - FEE, "bob received usdg on robinhood");
    }

    /// @dev alice sells USDG collateralized: she posts 1% now and brings the rest within the settlement period. bob's
    /// USDC is escrowed in full. Once alice deposits and repays the rest, the escrow releases both sides.
    function testCollateralizedOrderRepaidBeforeDeadline() public {
        _deposit(alice, SPOKE, robinhoodUsdg, HUB_CHAIN_ID, COLLATERAL);
        _deposit(bob, HUB_CHAIN_ID, usdc, HUB_CHAIN_ID, AMOUNT);
        _relayMessages();
        _settleCollateralizedPair();

        assertEq(_balance(HUB_CHAIN_ID, alice, SPOKE), 0, "alice posted collateral");
        assertEq(_balance(HUB_CHAIN_ID, bob, HUB_CHAIN_ID, usdc), 0, "bob escrowed in full");
        (,,,, uint256 debt, uint256 collateral,) = delayedSettlementSwapConductor.escrowLegs(1, 0);
        assertEq(debt, AMOUNT - COLLATERAL, "alice owes the amount less collateral");
        assertEq(collateral, COLLATERAL, "alice collateral recorded");

        _deposit(alice, SPOKE, robinhoodUsdg, HUB_CHAIN_ID, AMOUNT - COLLATERAL);
        _relayMessages();
        vm.chainId(HUB_CHAIN_ID);
        vm.prank(alice);
        delayedSettlementSwapConductor.repay(1, 0);

        assertEq(_balance(HUB_CHAIN_ID, alice, SPOKE), 0, "alice spent the full amount");
        assertEq(_balance(HUB_CHAIN_ID, alice, HUB_CHAIN_ID, usdc), AMOUNT, "alice bought usdc");
        assertEq(_balance(HUB_CHAIN_ID, bob, SPOKE), AMOUNT, "bob bought usdg");
        assertEq(delayedSettlementSwapConductor.escrowDeadline(1), 0, "escrow released");
    }

    /// @dev alice never repays. After the deadline she can no longer repay, anyone may reclaim, bob's USDC is returned
    /// and alice's collateral goes to the penalty recipient.
    function testCollateralizedOrderUnpaidIsReclaimed() public {
        _deposit(alice, SPOKE, robinhoodUsdg, HUB_CHAIN_ID, AMOUNT);
        _deposit(bob, HUB_CHAIN_ID, usdc, HUB_CHAIN_ID, AMOUNT);
        _relayMessages();
        _settleCollateralizedPair();

        vm.warp(block.timestamp + PERIOD + 1);
        vm.chainId(HUB_CHAIN_ID);
        vm.prank(alice);
        vm.expectRevert(IDelayedSettlementSwapConductor.SettlementPeriodOver.selector);
        delayedSettlementSwapConductor.repay(1, 0);

        uint256[] memory escrowIds = new uint256[](1);
        escrowIds[0] = 1;
        vm.prank(makeAddr("anyone"));
        delayedSettlementSwapConductor.reclaim(escrowIds);

        assertEq(_balance(HUB_CHAIN_ID, bob, HUB_CHAIN_ID, usdc), AMOUNT, "bob usdc returned");
        assertEq(_balance(HUB_CHAIN_ID, bob, SPOKE), 0, "bob bought nothing");
        assertEq(_balance(HUB_CHAIN_ID, alice, SPOKE), AMOUNT - COLLATERAL, "alice lost only her collateral");
        assertEq(_balance(HUB_CHAIN_ID, PENALTY_RECIPIENT, SPOKE), COLLATERAL, "collateral forfeited");
    }

    /// @dev Both orders are collateralized, so both post 1% and must repay within the shared settlement period. The
    /// escrow stays open after alice repays and releases only once bob repays too.
    function testBothCollateralizedRepaidReleases() public {
        _deposit(alice, SPOKE, robinhoodUsdg, HUB_CHAIN_ID, COLLATERAL);
        _deposit(bob, HUB_CHAIN_ID, usdc, HUB_CHAIN_ID, COLLATERAL);
        _relayMessages();
        _settleCollateralizedPair(true);

        assertEq(_balance(HUB_CHAIN_ID, alice, SPOKE), 0, "alice posted collateral");
        assertEq(_balance(HUB_CHAIN_ID, bob, HUB_CHAIN_ID, usdc), 0, "bob posted collateral");

        _deposit(alice, SPOKE, robinhoodUsdg, HUB_CHAIN_ID, AMOUNT - COLLATERAL);
        _deposit(bob, HUB_CHAIN_ID, usdc, HUB_CHAIN_ID, AMOUNT - COLLATERAL);
        _relayMessages();
        vm.chainId(HUB_CHAIN_ID);
        vm.prank(alice);
        delayedSettlementSwapConductor.repay(1, 0);
        assertTrue(delayedSettlementSwapConductor.escrowDeadline(1) != 0, "escrow open until bob repays");

        vm.prank(bob);
        delayedSettlementSwapConductor.repay(1, 1);

        assertEq(_balance(HUB_CHAIN_ID, alice, SPOKE), 0, "alice spent the full amount");
        assertEq(_balance(HUB_CHAIN_ID, alice, HUB_CHAIN_ID, usdc), AMOUNT, "alice bought usdc");
        assertEq(_balance(HUB_CHAIN_ID, bob, HUB_CHAIN_ID, usdc), 0, "bob spent the full amount");
        assertEq(_balance(HUB_CHAIN_ID, bob, SPOKE), AMOUNT, "bob bought usdg");
        assertEq(delayedSettlementSwapConductor.escrowDeadline(1), 0, "escrow released");
    }

    /// @dev Both orders are collateralized but only alice repays. On reclaim alice gets her full amount back, and bob's
    /// collateral is forfeited.
    function testBothCollateralizedOneDefaultsIsReclaimed() public {
        _deposit(alice, SPOKE, robinhoodUsdg, HUB_CHAIN_ID, AMOUNT);
        _deposit(bob, HUB_CHAIN_ID, usdc, HUB_CHAIN_ID, COLLATERAL);
        _relayMessages();
        _settleCollateralizedPair(true);

        vm.chainId(HUB_CHAIN_ID);
        vm.prank(alice);
        delayedSettlementSwapConductor.repay(1, 0);

        vm.warp(block.timestamp + PERIOD + 1);
        uint256[] memory escrowIds = new uint256[](1);
        escrowIds[0] = 1;
        vm.prank(makeAddr("anyone"));
        delayedSettlementSwapConductor.reclaim(escrowIds);

        assertEq(_balance(HUB_CHAIN_ID, alice, SPOKE), AMOUNT, "alice full amount returned");
        assertEq(_balance(HUB_CHAIN_ID, alice, HUB_CHAIN_ID, usdc), 0, "alice bought nothing");
        assertEq(_balance(HUB_CHAIN_ID, bob, SPOKE), 0, "bob bought nothing");
        assertEq(_balance(HUB_CHAIN_ID, PENALTY_RECIPIENT, HUB_CHAIN_ID, usdc), COLLATERAL, "bob collateral forfeited");
    }

    /// @dev alice owns a Robinhood account and never signs: she pre-approves and later repays with Generic messages
    /// from Robinhood.
    function testSpokeOwnerPreApprovesAndRepaysFromSpoke() public {
        _deposit(alice, SPOKE, robinhoodUsdg, SPOKE, COLLATERAL);
        _deposit(bob, HUB_CHAIN_ID, usdc, HUB_CHAIN_ID, AMOUNT);
        _relayMessages();

        IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders =
            new IDelayedSettlementSwapConductor.DelayedSettlementOrder[](2);
        orders[0] = _usdgForUsdc(SPOKE, alice, AMOUNT, true);
        orders[1] = _usdcForUsdg(bob, AMOUNT, false);
        _genericFromSpoke(abi.encodeCall(DelayedSettlementSwapConductor.preApprove, (orders[0])));
        _relayMessages();
        bytes[] memory signatures = new bytes[](2);
        signatures[1] = _signOrder(bobPk, orders[1]);
        _settle(orders, signatures, 0);
        assertEq(_balance(SPOKE, alice, SPOKE), 0, "alice posted collateral");

        _deposit(alice, SPOKE, robinhoodUsdg, SPOKE, AMOUNT - COLLATERAL);
        _genericFromSpoke(abi.encodeCall(DelayedSettlementSwapConductor.repay, (1, 0)));
        _relayMessages();

        assertEq(_balance(SPOKE, alice, SPOKE), 0, "alice spent the full amount");
        assertEq(_balance(SPOKE, alice, HUB_CHAIN_ID, usdc), AMOUNT, "alice bought usdc");
        assertEq(_balance(HUB_CHAIN_ID, bob, SPOKE), AMOUNT, "bob bought usdg");
    }

    function _settleCollateralizedPair() internal {
        _settleCollateralizedPair(false);
    }

    function _settleCollateralizedPair(bool bobCollateralized) internal {
        IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders =
            new IDelayedSettlementSwapConductor.DelayedSettlementOrder[](2);
        orders[0] = _usdgForUsdc(HUB_CHAIN_ID, alice, AMOUNT, true);
        orders[1] = _usdcForUsdg(bob, AMOUNT, bobCollateralized);
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = _signOrder(alicePk, orders[0]);
        signatures[1] = _signOrder(bobPk, orders[1]);
        _settle(orders, signatures, 0);
    }

    function _settle(
        IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders,
        bytes[] memory signatures,
        uint256 fee
    )
        internal
    {
        IDelayedSettlementSwapConductor.PairedFill[] memory fills = new IDelayedSettlementSwapConductor.PairedFill[](1);
        fills[0] = IDelayedSettlementSwapConductor.PairedFill({
            orderIndexes: [uint256(0), 1], amounts: [AMOUNT, AMOUNT], fees: [fee, fee]
        });
        vm.chainId(HUB_CHAIN_ID);
        uint256 epoch = depot.settlementEpoch();
        vm.prank(SOLVER_ADDRESS);
        delayedSettlementSwapConductor.settle(epoch, orders, signatures, fills);
    }

    function _genericFromSpoke(bytes memory data) internal {
        vm.chainId(SPOKE);
        vm.prank(alice);
        _dispatchOne(
            spokeTurnstile[SPOKE],
            ITurnstile.ActionType.Generic,
            abi.encode(
                ITurnstile.GenericAction({
                    ownerChainId: SPOKE,
                    owner: alice,
                    target: address(delayedSettlementSwapConductor),
                    data: data,
                    deadline: type(uint256).max,
                    dependsOn: bytes32(0),
                    salt: bytes32(0)
                })
            )
        );
    }

    function _signOrder(
        uint256 privateKey,
        IDelayedSettlementSwapConductor.DelayedSettlementOrder memory order
    )
        internal
        returns (bytes memory)
    {
        vm.chainId(HUB_CHAIN_ID);
        return _sign(privateKey, delayedSettlementSwapConductor.hashOrder(order));
    }

    function _usdgForUsdc(
        uint64 ownerChainId,
        address owner,
        uint256 buyAmount,
        bool collateralized
    )
        internal
        view
        returns (IDelayedSettlementSwapConductor.DelayedSettlementOrder memory)
    {
        return _order(
            ownerChainId, owner, SPOKE, address(robinhoodUsdg), HUB_CHAIN_ID, address(usdc), buyAmount, collateralized
        );
    }

    function _usdcForUsdg(
        address owner,
        uint256 buyAmount,
        bool collateralized
    )
        internal
        view
        returns (IDelayedSettlementSwapConductor.DelayedSettlementOrder memory)
    {
        return _order(
            HUB_CHAIN_ID, owner, HUB_CHAIN_ID, address(usdc), SPOKE, address(robinhoodUsdg), buyAmount, collateralized
        );
    }

    function _order(
        uint64 ownerChainId,
        address owner,
        uint64 sellTokenChainId,
        address sellToken,
        uint64 buyTokenChainId,
        address buyToken,
        uint256 buyAmount,
        bool collateralized
    )
        internal
        pure
        returns (IDelayedSettlementSwapConductor.DelayedSettlementOrder memory)
    {
        return IDelayedSettlementSwapConductor.DelayedSettlementOrder({
            ownerChainId: ownerChainId,
            owner: owner,
            sellTokenChainId: sellTokenChainId,
            sellToken: sellToken,
            buyTokenChainId: buyTokenChainId,
            buyToken: buyToken,
            sellAmount: AMOUNT,
            buyAmount: buyAmount,
            receiverChainId: ownerChainId,
            receiver: owner,
            expiresAt: type(uint256).max,
            partiallyFillable: false,
            collateralized: collateralized,
            settlementPeriod: PERIOD,
            salt: bytes32(0)
        });
    }

    function _balance(
        uint64 accountChainId,
        address account,
        uint64 assetChainId,
        MockERC20 asset
    )
        internal
        view
        returns (uint256)
    {
        return depot.balanceOf(_account(accountChainId, account), _account(assetChainId, address(asset)));
    }

}
