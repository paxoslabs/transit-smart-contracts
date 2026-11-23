// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { SharedSetup } from "test/integration/SharedSetup.sol";
import { MockERC20 } from "lib/solady/test/utils/mocks/MockERC20.sol";
import { ITurnstile } from "src/interfaces/ITurnstile.sol";
import { IUserConductor } from "src/interfaces/IUserConductor.sol";
import { Turnstile } from "src/turnstile/Turnstile.sol";
import { HubWarehouseConductor } from "src/conductor/HubWarehouseConductor.sol";
import { UserConductor } from "src/conductor/UserConductor.sol";
import { TransitAddressLib } from "src/helpers/TransitAddressLib.sol";

contract TurnstileHappyPaths is SharedSetup {

    uint64 constant SPOKE = ROBINHOOD_CHAIN_ID;
    uint64 constant MESSAGE_GAS = 500_000;
    uint256 constant AMOUNT = 100e6;

    address alice;
    uint256 alicePk;
    address bob = makeAddr("bob");

    function setUp() public override {
        super.setUp();
        (alice, alicePk) = makeAddrAndKey("alice");
    }

    // ========================================= DEPOSITS =========================================

    function testDepositOnHubForHubAccount() public {
        _deposit(HUB_CHAIN_ID, alice, HUB_CHAIN_ID, AMOUNT);
        assertEq(usdg.balanceOf(VAULT), AMOUNT, "hub VAULT holds deposit");
        assertEq(_balance(HUB_CHAIN_ID, alice, HUB_CHAIN_ID), AMOUNT, "hub account credited");
    }

    function testDepositOnHubForSpokeAccount() public {
        _deposit(HUB_CHAIN_ID, alice, SPOKE, AMOUNT);
        assertEq(usdg.balanceOf(VAULT), AMOUNT, "hub VAULT holds deposit");
        assertEq(_balance(SPOKE, alice, HUB_CHAIN_ID), AMOUNT, "spoke account credited");
    }

    function testDepositOnSpokeForHubAccount() public {
        _deposit(SPOKE, alice, HUB_CHAIN_ID, AMOUNT);
        assertEq(_balance(HUB_CHAIN_ID, alice, SPOKE), 0, "not credited before relay");
        _relayMessages();
        assertEq(spokeUsdg[SPOKE].balanceOf(VAULT), AMOUNT, "spoke VAULT holds deposit");
        assertEq(_balance(HUB_CHAIN_ID, alice, SPOKE), AMOUNT, "hub account credited");
    }

    function testDepositOnSpokeForSpokeAccount() public {
        _deposit(SPOKE, alice, SPOKE, AMOUNT);
        _relayMessages();
        assertEq(spokeUsdg[SPOKE].balanceOf(VAULT), AMOUNT, "spoke VAULT holds deposit");
        assertEq(_balance(SPOKE, alice, SPOKE), AMOUNT, "spoke account credited");
    }

    function testDepositFacilitatedOnHubForHubAccount() public {
        uint256 fee = 1e6;
        usdg.mint(alice, AMOUNT);
        vm.prank(alice);
        usdg.approve(address(turnstile), AMOUNT);
        ITurnstile.DepositAction memory action = _depositAction(HUB_CHAIN_ID, alice, HUB_CHAIN_ID, AMOUNT);
        action.facilitationFee = fee;
        action.feeReceiverChainId = HUB_CHAIN_ID;
        action.feeReceiver = SOLVER_ADDRESS;
        _facilitate(
            HUB_CHAIN_ID, ITurnstile.ActionType.Deposit, abi.encode(action), _sign(turnstile.hashDepositAction(action))
        );
        assertEq(_balance(HUB_CHAIN_ID, alice, HUB_CHAIN_ID), AMOUNT - fee, "account credited less fee");
        assertEq(_balance(HUB_CHAIN_ID, SOLVER_ADDRESS, HUB_CHAIN_ID), fee, "solver paid fee");
    }

    function testDepositFacilitatedOnSpokeForSpokeAccount() public {
        uint256 fee = 1e6;
        MockERC20 token = spokeUsdg[SPOKE];
        Turnstile chainTurnstile = spokeTurnstile[SPOKE];
        token.mint(alice, AMOUNT);
        vm.prank(alice);
        token.approve(address(chainTurnstile), AMOUNT);
        ITurnstile.DepositAction memory action = _depositAction(SPOKE, alice, SPOKE, AMOUNT);
        action.facilitationFee = fee;
        action.feeReceiverChainId = HUB_CHAIN_ID;
        action.feeReceiver = SOLVER_ADDRESS;
        vm.chainId(SPOKE);
        _facilitate(
            SPOKE, ITurnstile.ActionType.Deposit, abi.encode(action), _sign(chainTurnstile.hashDepositAction(action))
        );
        _relayMessages();
        assertEq(token.balanceOf(VAULT), AMOUNT, "spoke VAULT holds deposit");
        assertEq(_balance(SPOKE, alice, SPOKE), AMOUNT - fee, "spoke account credited less fee");
        assertEq(_balance(HUB_CHAIN_ID, SOLVER_ADDRESS, SPOKE), fee, "solver paid fee");
    }

    // ========================================= TRANSFERS =========================================

    function testTransferRequestOnHubFromHubAccountToHubAccount() public {
        _transferRequestedAndExecuted(HUB_CHAIN_ID, HUB_CHAIN_ID);
    }

    function testTransferRequestOnHubFromHubAccountToSpokeAccount() public {
        _transferRequestedAndExecuted(HUB_CHAIN_ID, SPOKE);
    }

    function testTransferRequestOnSpokeFromSpokeAccountToHubAccount() public {
        _transferRequestedAndExecuted(SPOKE, HUB_CHAIN_ID);
    }

    function testTransferRequestOnSpokeFromSpokeAccountToSpokeAccount() public {
        _transferRequestedAndExecuted(SPOKE, SPOKE);
    }

    function testTransferFacilitatedOnHubFromHubAccountToSpokeAccount() public {
        _deposit(HUB_CHAIN_ID, alice, HUB_CHAIN_ID, AMOUNT);
        IUserConductor.TransferRequest memory request = _transferRequest(HUB_CHAIN_ID, SPOKE);
        ITurnstile.GenericAction memory action = _genericAction(
            HUB_CHAIN_ID, address(userConductor), abi.encodeCall(UserConductor.executeTransfer, (request))
        );
        _facilitate(
            HUB_CHAIN_ID, ITurnstile.ActionType.Generic, abi.encode(action), _sign(turnstile.hashGenericAction(action))
        );
        assertEq(_balance(HUB_CHAIN_ID, alice, HUB_CHAIN_ID), 0, "owner debited");
        assertEq(_balance(SPOKE, bob, HUB_CHAIN_ID), AMOUNT, "recipient credited without waiting an epoch");
    }

    // ========================================= WITHDRAWALS =========================================

    function testWithdrawalRequestOnSpokeReceiveOnHub() public {
        _withdrawalRequestedAndExecuted(SPOKE, HUB_CHAIN_ID);
        assertEq(usdg.balanceOf(alice), AMOUNT, "received on hub");
    }

    function testWithdrawalRequestOnHubReceiveOnSpoke() public {
        _withdrawalRequestedAndExecuted(HUB_CHAIN_ID, SPOKE);
        assertEq(spokeUsdg[SPOKE].balanceOf(alice), AMOUNT, "received on spoke");
    }

    function testWithdrawalRequestOnSpokeReceiveOnSpoke() public {
        _withdrawalRequestedAndExecuted(SPOKE, SPOKE);
        assertEq(spokeUsdg[SPOKE].balanceOf(alice), AMOUNT, "received on spoke");
    }

    function testWithdrawalRequestOnHubReceiveOnHub() public {
        _withdrawalRequestedAndExecuted(HUB_CHAIN_ID, HUB_CHAIN_ID);
        assertEq(usdg.balanceOf(alice), AMOUNT, "received on hub");
    }

    function testWithdrawalFacilitatedReceiveOnSpoke() public {
        _withdrawalFacilitated(SPOKE);
        assertEq(spokeUsdg[SPOKE].balanceOf(alice), AMOUNT, "received on spoke");
    }

    function testWithdrawalFacilitatedReceiveOnHub() public {
        _withdrawalFacilitated(HUB_CHAIN_ID);
        assertEq(usdg.balanceOf(alice), AMOUNT, "received on hub");
    }

    // ========================================= FLOWS =========================================

    function _transferRequestedAndExecuted(uint64 ownerChainId, uint64 toChainId) internal {
        _deposit(HUB_CHAIN_ID, alice, ownerChainId, AMOUNT);
        IUserConductor.TransferRequest memory request = _transferRequest(ownerChainId, toChainId);
        _dispatchGeneric(ownerChainId, address(userConductor), abi.encodeCall(UserConductor.requestTransfer, (request)));
        _relayMessages();
        _advanceEpoch();

        vm.prank(bob);
        userConductor.executeTransfer(request);
        assertEq(_balance(ownerChainId, alice, HUB_CHAIN_ID), 0, "owner debited");
        assertEq(_balance(toChainId, bob, HUB_CHAIN_ID), AMOUNT, "recipient credited");
    }

    function _withdrawalRequestedAndExecuted(uint64 ownerChainId, uint64 assetChainId) internal {
        _deposit(assetChainId, alice, ownerChainId, AMOUNT);
        _relayMessages();
        ITurnstile.WithdrawalAction memory action = _withdrawalAction(ownerChainId, assetChainId);
        _dispatchGeneric(
            ownerChainId,
            address(hubWarehouseConductor),
            abi.encodeCall(HubWarehouseConductor.requestWithdrawal, (action))
        );
        _relayMessages();
        _advanceEpoch();
        assertEq(
            depot.freeBalanceOf(_account(ownerChainId, alice), _asset(assetChainId)), 0, "request reserves balance"
        );

        vm.chainId(HUB_CHAIN_ID);
        vm.prank(bob);
        _dispatchOne(turnstile, ITurnstile.ActionType.Withdrawal, abi.encode(action));
        _relayMessages();
        assertEq(_balance(ownerChainId, alice, assetChainId), 0, "depot balance burned");
    }

    function _withdrawalFacilitated(uint64 assetChainId) internal {
        _deposit(assetChainId, alice, HUB_CHAIN_ID, AMOUNT);
        _relayMessages();
        ITurnstile.WithdrawalAction memory action = _withdrawalAction(HUB_CHAIN_ID, assetChainId);
        vm.chainId(HUB_CHAIN_ID);
        _facilitate(
            HUB_CHAIN_ID,
            ITurnstile.ActionType.Withdrawal,
            abi.encode(action),
            _sign(turnstile.hashWithdrawalAction(action))
        );
        _relayMessages();
        assertEq(_balance(HUB_CHAIN_ID, alice, assetChainId), 0, "depot balance burned");
    }

    // ========================================= HELPERS =========================================

    function _deposit(uint64 chainId, address owner, uint64 toChainId, uint256 amount) internal {
        vm.chainId(chainId);
        MockERC20 token = _token(chainId);
        Turnstile chainTurnstile = _turnstile(chainId);
        token.mint(owner, amount);
        vm.startPrank(owner);
        token.approve(address(chainTurnstile), amount);
        _dispatchOne(
            chainTurnstile, ITurnstile.ActionType.Deposit, abi.encode(_depositAction(chainId, owner, toChainId, amount))
        );
        vm.stopPrank();
    }

    function _dispatchGeneric(uint64 chainId, address target, bytes memory data) internal {
        vm.chainId(chainId);
        vm.prank(alice);
        _dispatchOne(
            _turnstile(chainId), ITurnstile.ActionType.Generic, abi.encode(_genericAction(chainId, target, data))
        );
    }

    function _dispatchOne(Turnstile chainTurnstile, ITurnstile.ActionType actionType, bytes memory data) internal {
        ITurnstile.Action[] memory actions = new ITurnstile.Action[](1);
        actions[0] = ITurnstile.Action({ actionType: actionType, data: data, bridgeFee: 0, messageGas: MESSAGE_GAS });
        chainTurnstile.dispatch(actions);
    }

    function _facilitate(
        uint64 chainId,
        ITurnstile.ActionType actionType,
        bytes memory data,
        bytes memory signature
    )
        internal
    {
        vm.chainId(chainId);
        ITurnstile.Action[] memory actions = new ITurnstile.Action[](1);
        actions[0] = ITurnstile.Action({ actionType: actionType, data: data, bridgeFee: 0, messageGas: MESSAGE_GAS });
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = signature;
        vm.prank(SOLVER_ADDRESS);
        _turnstile(chainId).facilitate(actions, signatures);
    }

    function _sign(bytes32 digest) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _depositAction(
        uint64 chainId,
        address owner,
        uint64 toChainId,
        uint256 amount
    )
        internal
        view
        returns (ITurnstile.DepositAction memory)
    {
        return ITurnstile.DepositAction({
            ownerChainId: chainId,
            owner: owner,
            asset: address(_token(chainId)),
            amount: amount,
            toChainId: toChainId,
            to: owner,
            facilitationFee: 0,
            feeReceiverChainId: 0,
            feeReceiver: address(0),
            deadline: type(uint256).max,
            dependsOn: bytes32(0),
            salt: bytes32(0),
            permit: ITurnstile.Permit({ deadline: 0, v: 0, r: bytes32(0), s: bytes32(0) })
        });
    }

    function _genericAction(
        uint64 chainId,
        address target,
        bytes memory data
    )
        internal
        view
        returns (ITurnstile.GenericAction memory)
    {
        return ITurnstile.GenericAction({
            ownerChainId: chainId,
            owner: alice,
            target: target,
            data: data,
            deadline: type(uint256).max,
            dependsOn: bytes32(0),
            salt: bytes32(0)
        });
    }

    function _transferRequest(
        uint64 ownerChainId,
        uint64 toChainId
    )
        internal
        view
        returns (IUserConductor.TransferRequest memory)
    {
        return IUserConductor.TransferRequest({
            ownerChainId: ownerChainId,
            owner: alice,
            toChainId: toChainId,
            to: bob,
            assetChainId: HUB_CHAIN_ID,
            asset: address(usdg),
            amount: AMOUNT,
            deadline: type(uint256).max,
            partiallyFillable: false,
            salt: bytes32(0)
        });
    }

    function _withdrawalAction(
        uint64 ownerChainId,
        uint64 assetChainId
    )
        internal
        view
        returns (ITurnstile.WithdrawalAction memory)
    {
        return ITurnstile.WithdrawalAction({
            ownerChainId: ownerChainId,
            owner: alice,
            to: alice,
            assetChainId: assetChainId,
            asset: address(_token(assetChainId)),
            amount: AMOUNT,
            deadline: type(uint256).max,
            partiallyFillable: false,
            dependsOn: bytes32(0),
            salt: bytes32(0)
        });
    }

    function _token(uint64 chainId) internal view returns (MockERC20) {
        return chainId == HUB_CHAIN_ID ? usdg : spokeUsdg[chainId];
    }

    function _turnstile(uint64 chainId) internal view returns (Turnstile) {
        return chainId == HUB_CHAIN_ID ? turnstile : spokeTurnstile[chainId];
    }

    function _account(uint64 chainId, address account) internal pure returns (bytes28) {
        return TransitAddressLib.formatTransitAddress(chainId, account);
    }

    function _asset(uint64 assetChainId) internal view returns (bytes28) {
        return _account(assetChainId, address(_token(assetChainId)));
    }

    function _balance(uint64 accountChainId, address account, uint64 assetChainId) internal view returns (uint256) {
        return depot.balanceOf(_account(accountChainId, account), _asset(assetChainId));
    }

}
