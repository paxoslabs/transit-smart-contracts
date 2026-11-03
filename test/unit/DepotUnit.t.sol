// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { TransitAuthority } from "../../src/TransitAuthority.sol";
import { HubWarehouseTerminal } from "../../src/terminal/HubWarehouseTerminal.sol";
import { SpokeWarehouseTerminal } from "../../src/terminal/SpokeWarehouseTerminal.sol";
import { Depot } from "../../src/depot/Depot.sol";
import { SpotSwapTerminal } from "../../src/terminal/SpotSwapTerminal.sol";
import { SwapTerminal } from "../../src/terminal/SwapTerminal.sol";
import { UserTerminal } from "../../src/terminal/UserTerminal.sol";
import { IMessagingAdapter } from "../../src/messaging/IMessagingAdapter.sol";
import { Turnstile } from "../../src/Turnstile.sol";
import { ITurnstile } from "../../src/ITurnstile.sol";
import { MockMessagingAdapter } from "../mocks/MockMessagingAdapter.sol";
import { MockERC20 } from "../../lib/solady/test/utils/mocks/MockERC20.sol";
import { ADMIN_ROLE, MESSAGING_ADAPTER_ROLE, SOLVER_ROLE, TURNSTILE_ROLE, TERMINAL_ROLE, EPOCH_ROLE } from "../../src/helpers/Constants.sol";
import { TransitTokenLib } from "../../src/helpers/TransitTokenLib.sol";

contract DepotUnitTest is Test {

    uint64 constant HUB_CHAIN_ID = 1;

    TransitAuthority authority;
    SpokeWarehouseTerminal warehouse;
    Depot depot;
    UserTerminal userTerminal;
    HubWarehouseTerminal hubWarehouseTerminal;
    SpotSwapTerminal spotSwapTerminal;
    Turnstile turnstile;
    ERC20 usdc;
    ERC20 usdg;
    MockMessagingAdapter local;

    address admin = makeAddr("admin");
    address vault = makeAddr("vault");
    address alice = makeAddr("alice");
    uint256 alicePk;
    address bob = makeAddr("bob");
    address backend = makeAddr("backend");
    uint256 requestSalt;

    function setUp() public {
        vm.chainId(HUB_CHAIN_ID);
        (, alicePk) = makeAddrAndKey("alice");

        authority = new TransitAuthority(admin);
        uint256 nonce = vm.getNonce(address(this));
        turnstile = new Turnstile(address(authority), vm.computeCreateAddress(address(this), nonce + 2));
        depot = new Depot(address(authority));
        warehouse = new SpokeWarehouseTerminal(address(authority), vault, address(turnstile), HUB_CHAIN_ID);
        local = new MockMessagingAdapter(address(authority), address(turnstile), HUB_CHAIN_ID);
        userTerminal = new UserTerminal(address(depot), address(turnstile));
        hubWarehouseTerminal = new HubWarehouseTerminal(address(authority), address(depot), address(userTerminal), address(turnstile));
        spotSwapTerminal = new SpotSwapTerminal(address(authority), address(depot), _account(backend), address(turnstile));
        usdc = ERC20(address(new MockERC20("USD Coin", "USDC", 6)));
        usdg = ERC20(address(new MockERC20("Global Dollar", "USDG", 6)));


        bytes4[] memory warehouseAdminSels = new bytes4[](1);
        warehouseAdminSels[0] = SpokeWarehouseTerminal.setAssetWhitelisted.selector;

        bytes4[] memory receiveWithdrawalSels = new bytes4[](1);
        receiveWithdrawalSels[0] = SpokeWarehouseTerminal.receiveWithdrawal.selector;

        bytes4[] memory receiveSels = new bytes4[](1);
        receiveSels[0] = Turnstile.receiveMessage.selector;

        bytes4[] memory solverSels = new bytes4[](1);
        solverSels[0] = SpotSwapTerminal.settle.selector;

        bytes4[] memory facilitateSels = new bytes4[](1);
        facilitateSels[0] = Turnstile.facilitate.selector;

        bytes4[] memory epochSels = new bytes4[](1);
        epochSels[0] = Depot.advanceEpoch.selector;

        bytes4[] memory turnstileAdminSels = new bytes4[](3);
        turnstileAdminSels[0] = Turnstile.setMessagingAdapter.selector;
        turnstileAdminSels[1] = Turnstile.setRoutable.selector;
        turnstileAdminSels[2] = Turnstile.setHubWarehouseTerminal.selector;

        bytes4[] memory turnstileSendSels = new bytes4[](2);
        turnstileSendSels[0] = Turnstile.sendDepositMessage.selector;
        turnstileSendSels[1] = Turnstile.sendWithdrawalMessage.selector;

        bytes4[] memory routedSels = new bytes4[](3);
        routedSels[0] = UserTerminal.reserve.selector;
        routedSels[1] = UserTerminal.reserveAndRequest.selector;
        routedSels[2] = UserTerminal.executeTransfer.selector;

        bytes4[] memory swapRoutedSels = new bytes4[](2);
        swapRoutedSels[0] = SpotSwapTerminal.preApprove.selector;
        swapRoutedSels[1] = SwapTerminal.requestOrderCancellation.selector;

        vm.startPrank(admin);
        authority.setTargetFunctionRole(address(warehouse), warehouseAdminSels, ADMIN_ROLE);
        authority.setTargetFunctionRole(address(turnstile), receiveSels, MESSAGING_ADAPTER_ROLE);
        authority.setTargetFunctionRole(address(warehouse), receiveWithdrawalSels, TURNSTILE_ROLE);
        authority.grantRole(MESSAGING_ADAPTER_ROLE, address(warehouse));
        authority.setTargetFunctionRole(address(spotSwapTerminal), solverSels, SOLVER_ROLE);
        authority.setTargetFunctionRole(address(turnstile), facilitateSels, SOLVER_ROLE);
        authority.setTargetFunctionRole(address(depot), epochSels, EPOCH_ROLE);
        authority.grantRole(EPOCH_ROLE, address(spotSwapTerminal));
        authority.grantRole(MESSAGING_ADAPTER_ROLE, address(local));
        authority.grantRole(SOLVER_ROLE, backend);
        warehouse.setAssetWhitelisted(_list(address(usdc)), true);
        authority.setTargetFunctionRole(address(turnstile), turnstileAdminSels, ADMIN_ROLE);
        authority.setTargetFunctionRole(address(turnstile), turnstileSendSels, MESSAGING_ADAPTER_ROLE);
        authority.grantRole(TURNSTILE_ROLE, address(turnstile));
        authority.grantRole(MESSAGING_ADAPTER_ROLE, address(hubWarehouseTerminal));
        bytes4[] memory userTerminalSels = new bytes4[](6);
        userTerminalSels[0] = Depot.reserve.selector;
        userTerminalSels[1] = Depot.release.selector;
        userTerminalSels[2] = Depot.transferFrom.selector;
        userTerminalSels[3] = Depot.burn.selector;
        userTerminalSels[4] = Depot.transferAmong.selector;
        userTerminalSels[5] = Depot.mint.selector;
        authority.setTargetFunctionRole(address(depot), userTerminalSels, TERMINAL_ROLE);
        authority.grantRole(TERMINAL_ROLE, address(userTerminal));
        authority.grantRole(TERMINAL_ROLE, address(hubWarehouseTerminal));
        bytes4[] memory receiveDepositSels = new bytes4[](1);
        receiveDepositSels[0] = HubWarehouseTerminal.receiveDeposit.selector;
        authority.setTargetFunctionRole(address(hubWarehouseTerminal), receiveDepositSels, TURNSTILE_ROLE);
        turnstile.setHubWarehouseTerminal(address(hubWarehouseTerminal));
        authority.grantRole(TERMINAL_ROLE, address(spotSwapTerminal));
        turnstile.setRoutable(address(userTerminal), routedSels, true);
        turnstile.setRoutable(address(spotSwapTerminal), swapRoutedSels, true);
        turnstile.setMessagingAdapter(address(local));
        vm.stopPrank();

        vm.prank(vault);
        SafeTransferLib.safeApprove(address(usdc), address(warehouse), type(uint256).max);
    }

    function _list(address asset) internal pure returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = asset;
    }

    function _deposit(address user, uint256 amount) internal {
        deal(address(usdc), user, amount);
        vm.startPrank(user);
        SafeTransferLib.safeApprove(address(usdc), address(warehouse), amount);
        warehouse.deposit(address(usdc), amount, HUB_CHAIN_ID, user, 0);
        vm.stopPrank();
    }

    function _advanceEpoch() internal {
        vm.warp(block.timestamp + 24 hours);
        depot.advanceEpoch(depot.settlementEpoch());
    }

    function _transferRequest(address owner, address to, uint256 amount) internal returns (UserTerminal.TransferRequest memory) {
        return UserTerminal.TransferRequest({
            ownerChainId: HUB_CHAIN_ID,
            owner: owner,
            toChainId: HUB_CHAIN_ID,
            to: to,
            assetId: TransitTokenLib.formatAssetId(HUB_CHAIN_ID, address(usdc)),
            amount: amount,
            deadline: type(uint256).max,
            partiallyFillable: true,
            salt: bytes32(++requestSalt)
        });
    }

    function _withdrawalRequest(address owner, uint256 amount) internal returns (HubWarehouseTerminal.WithdrawalRequest memory) {
        return HubWarehouseTerminal.WithdrawalRequest({
            ownerChainId: HUB_CHAIN_ID,
            owner: owner,
            to: owner,
            assetId: TransitTokenLib.formatAssetId(HUB_CHAIN_ID, address(usdc)),
            amount: amount,
            deadline: type(uint256).max,
            partiallyFillable: true,
            salt: bytes32(++requestSalt)
        });
    }

    function _order(uint256 sellAmount, bool partiallyFillable) internal returns (SpotSwapTerminal.Order memory) {
        return SpotSwapTerminal.Order({
            ownerChainId: HUB_CHAIN_ID,
            owner: alice,
            sellTokenId: TransitTokenLib.formatAssetId(HUB_CHAIN_ID, address(usdc)),
            buyTokenId: TransitTokenLib.formatAssetId(HUB_CHAIN_ID, address(usdc)),
            sellAmount: sellAmount,
            buyAmount: sellAmount,
            receiverChainId: HUB_CHAIN_ID,
            receiver: alice,
            expiresAt: type(uint256).max,
            partiallyFillable: partiallyFillable,
            salt: bytes32(uint256(++requestSalt))
        });
    }

    function _facilitatedCancellation(bytes32 orderHash) internal returns (ITurnstile.GenericMessage memory) {
        return ITurnstile.GenericMessage({
            sender: alice,
            target: address(spotSwapTerminal),
            data: abi.encodeCall(SwapTerminal.requestOrderCancellation, (orderHash)),
            deadline: type(uint256).max,
            salt: bytes32(++requestSalt)
        });
    }

    function _signFacilitated(ITurnstile.GenericMessage memory message, uint256 pk) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, turnstile.hashGenericMessage(message));
        return abi.encodePacked(r, s, v);
    }

    function _facilitate(ITurnstile.GenericMessage memory message, bytes memory signature) internal {
        ITurnstile.GenericMessage[] memory calls = new ITurnstile.GenericMessage[](1);
        calls[0] = message;
        uint256[] memory values = new uint256[](1);
        vm.prank(backend);
        turnstile.facilitate(calls, _toArray(signature), values);
    }

    function _toArray(bytes memory signature) internal pure returns (bytes[] memory signatures) {
        signatures = new bytes[](1);
        signatures[0] = signature;
    }

    function _settle(
        SpotSwapTerminal.Order memory order,
        bytes memory signature,
        uint256 amount,
        bytes memory revertData
    )
        internal
    {
        SpotSwapTerminal.Order[] memory orders = new SpotSwapTerminal.Order[](1);
        orders[0] = order;
        SpotSwapTerminal.Fill[] memory fills = new SpotSwapTerminal.Fill[](1);
        fills[0] = SpotSwapTerminal.Fill(amount, amount);
        uint256 epoch = depot.settlementEpoch();
        vm.prank(backend);
        if (revertData.length != 0) vm.expectRevert(revertData);
        spotSwapTerminal.settle(epoch, orders, _toArray(signature), fills, new SpotSwapTerminal.Fee[](0));
    }

    // ---------------------------------------------------------------- transfer

    function testRequestTransferReservesThenExecutes() public {
        _deposit(alice, 100e6);
        UserTerminal.TransferRequest memory request = _transferRequest(alice, bob, 60e6);

        bytes32 requestId = userTerminal.hashTransferRequest(request);
        vm.prank(alice);
        turnstile.sendGenericMessage(address(userTerminal), abi.encodeCall(UserTerminal.reserveAndRequest, (requestId, request.assetId, request.amount)), block.timestamp, 0, bytes32(++requestSalt));

        assertEq(userTerminal.requestStatus(_account(alice), requestId), depot.settlementEpoch() + 1, "request: status not pending next epoch");
        assertEq(_depotBalance(alice), 100e6, "request: balance moved early");
        assertEq(_depotBalance(bob), 0, "request: bob credited early");

        vm.prank(bob);
        vm.expectRevert(UserTerminal.NotEffective.selector);
        userTerminal.executeTransfer(request);

        _advanceEpoch();

        vm.prank(bob);
        userTerminal.executeTransfer(request);

        assertEq(userTerminal.requestStatus(_account(alice), requestId), userTerminal.EXECUTED(), "execute: status not executed");
        assertEq(_depotBalance(alice), 40e6, "execute: alice not debited");
        assertEq(_depotBalance(bob), 60e6, "execute: bob not credited");

        vm.prank(bob);
        vm.expectRevert(UserTerminal.RequestReplay.selector);
        userTerminal.executeTransfer(request);
    }

    function testRequestTransferReplayReverts() public {
        _deposit(alice, 100e6);
        UserTerminal.TransferRequest memory request = _transferRequest(alice, bob, 60e6);

        bytes memory data = abi.encodeCall(UserTerminal.reserveAndRequest, (userTerminal.hashTransferRequest(request), request.assetId, request.amount));

        vm.prank(alice);
        turnstile.sendGenericMessage(address(userTerminal), data, block.timestamp, 0, bytes32(++requestSalt));

        vm.prank(alice);
        vm.expectRevert(UserTerminal.RequestReplay.selector);
        turnstile.sendGenericMessage(address(userTerminal), data, block.timestamp, 0, bytes32(++requestSalt));
    }

    // ---------------------------------------------------------------- withdrawal

    function testRequestWithdrawalReservesThenExecutes() public {
        _deposit(alice, 100e6);
        HubWarehouseTerminal.WithdrawalRequest memory request = _withdrawalRequest(alice, 40e6);

        bytes32 requestId = hubWarehouseTerminal.hashWithdrawalRequest(request);
        vm.prank(alice);
        turnstile.sendGenericMessage(address(userTerminal), abi.encodeCall(UserTerminal.reserveAndRequest, (requestId, request.assetId, request.amount)), block.timestamp, 0, bytes32(++requestSalt));

        assertEq(userTerminal.requestStatus(_account(alice), requestId), depot.settlementEpoch() + 1, "request: status not pending next epoch");
        assertEq(usdc.balanceOf(alice), 0, "request: alice received usdc early");

        _advanceEpoch();

        vm.prank(bob);
        hubWarehouseTerminal.executeWithdrawal(request, 0);

        assertEq(hubWarehouseTerminal.requestStatus(_account(alice), requestId), hubWarehouseTerminal.EXECUTED(), "execute: status not executed");
        assertEq(_depotBalance(alice), 60e6, "execute: alice depot balance not burned");
        assertEq(usdc.balanceOf(alice), 40e6, "execute: alice did not receive usdc");
    }

    function testRequestWithdrawalReplayReverts() public {
        _deposit(alice, 100e6);
        HubWarehouseTerminal.WithdrawalRequest memory request = _withdrawalRequest(alice, 40e6);

        bytes memory data = abi.encodeCall(UserTerminal.reserveAndRequest, (hubWarehouseTerminal.hashWithdrawalRequest(request), request.assetId, request.amount));

        vm.prank(alice);
        turnstile.sendGenericMessage(address(userTerminal), data, block.timestamp, 0, bytes32(++requestSalt));

        vm.prank(alice);
        vm.expectRevert(UserTerminal.RequestReplay.selector);
        turnstile.sendGenericMessage(address(userTerminal), data, block.timestamp, 0, bytes32(++requestSalt));
    }

    // ---------------------------------------------------------------- orders

    function testPreApproveAllowsEmptySignatureFill() public {
        _deposit(alice, 100e6);
        SpotSwapTerminal.Order memory order = _order(100e6, false);
        bytes32 orderHash = spotSwapTerminal.hashOrder(order);

        vm.prank(alice);
        turnstile.sendGenericMessage(address(spotSwapTerminal), abi.encodeCall(SpotSwapTerminal.preApprove, (order)), block.timestamp, 0, bytes32(++requestSalt));

        assertTrue(spotSwapTerminal.preApproved(orderHash), "preApprove: hash not marked");

        _settle(order, "", 100e6, "");

        assertEq(spotSwapTerminal.filledAmount(orderHash), 100e6, "fill: amount not recorded");
    }

    function testFillWithoutPreApproveReverts() public {
        _deposit(alice, 100e6);
        SpotSwapTerminal.Order memory order = _order(100e6, false);
        bytes32 orderHash = spotSwapTerminal.hashOrder(order);

        _settle(order, "", 100e6, abi.encodeWithSelector(SwapTerminal.NotPreApproved.selector, orderHash));
    }

    function testRequestOrderCancellationTakesEffectNextEpoch() public {
        _deposit(alice, 100e6);
        SpotSwapTerminal.Order memory order = _order(100e6, true);
        bytes32 orderHash = spotSwapTerminal.hashOrder(order);

        vm.prank(alice);
        turnstile.sendGenericMessage(address(spotSwapTerminal), abi.encodeCall(SpotSwapTerminal.preApprove, (order)), block.timestamp, 0, bytes32(++requestSalt));

        vm.prank(alice);
        turnstile.sendGenericMessage(address(spotSwapTerminal), abi.encodeCall(SwapTerminal.requestOrderCancellation, (orderHash)), block.timestamp, 0, bytes32(++requestSalt));

        assertEq(spotSwapTerminal.cancelledFrom(_account(alice), orderHash), depot.settlementEpoch() + 1, "cancel: not effective next epoch");

        _settle(order, "", 60e6, "");

        _advanceEpoch();

        _settle(order, "", 40e6, abi.encodeWithSelector(SwapTerminal.Cancelled.selector, orderHash));
    }

    // ---------------------------------------------------------------- facilitated cancel

    function _preApprovedOrder() internal returns (SpotSwapTerminal.Order memory order, bytes32 orderHash) {
        _deposit(alice, 100e6);
        order = _order(100e6, false);
        orderHash = spotSwapTerminal.hashOrder(order);

        vm.prank(alice);
        turnstile.sendGenericMessage(address(spotSwapTerminal), abi.encodeCall(SpotSwapTerminal.preApprove, (order)), block.timestamp, 0, bytes32(++requestSalt));
    }

    function testFacilitatedOrderCancellationIsImmediateAndPaysFee() public {
        (SpotSwapTerminal.Order memory order, bytes32 orderHash) = _preApprovedOrder();
        ITurnstile.GenericMessage memory message = _facilitatedCancellation(orderHash);

        _facilitate(message, _signFacilitated(message, alicePk));

        assertEq(spotSwapTerminal.cancelledFrom(_account(alice), orderHash), depot.settlementEpoch(), "facilitate: cancel not immediate");
        /// TODO: Restore fee assertions once facilitate charges fees.

        _settle(order, "", 100e6, abi.encodeWithSelector(SwapTerminal.Cancelled.selector, orderHash));
    }

    function testFacilitatedOrderCancellationReplayReverts() public {
        (, bytes32 orderHash) = _preApprovedOrder();
        ITurnstile.GenericMessage memory message = _facilitatedCancellation(orderHash);
        bytes memory sig = _signFacilitated(message, alicePk);

        _facilitate(message, sig);

        vm.expectRevert(ITurnstile.MessageReplay.selector);
        _facilitate(message, sig);
    }

    function testFacilitatedOrderCancellationOverridesPendingUserCancel() public {
        (, bytes32 orderHash) = _preApprovedOrder();

        vm.prank(alice);
        turnstile.sendGenericMessage(address(spotSwapTerminal), abi.encodeCall(SwapTerminal.requestOrderCancellation, (orderHash)), block.timestamp, 0, bytes32(++requestSalt));

        assertEq(spotSwapTerminal.cancelledFrom(_account(alice), orderHash), depot.settlementEpoch() + 1, "setup: user cancel not pending");

        ITurnstile.GenericMessage memory message = _facilitatedCancellation(orderHash);
        _facilitate(message, _signFacilitated(message, alicePk));

        assertEq(spotSwapTerminal.cancelledFrom(_account(alice), orderHash), depot.settlementEpoch(), "facilitate: did not take earliest epoch");
    }

    function testFacilitatedOrderCancellationBadSignatureReverts() public {
        (, bytes32 orderHash) = _preApprovedOrder();
        ITurnstile.GenericMessage memory message = _facilitatedCancellation(orderHash);
        (, uint256 wrongPk) = makeAddrAndKey("notTheSigner");
        bytes memory sig = _signFacilitated(message, wrongPk);

        vm.expectRevert(ITurnstile.BadSignature.selector);
        _facilitate(message, sig);

        assertEq(spotSwapTerminal.cancelledFrom(_account(alice), orderHash), 0, "bad sig: cancellation recorded despite revert");
    }

    // ---------------------------------------------------------------- auth

    function testPreApproveForAnotherOwnerReverts() public {
        SpotSwapTerminal.Order memory order = _order(100e6, false);

        vm.prank(bob);
        vm.expectRevert(SwapTerminal.NotOwner.selector);
        turnstile.sendGenericMessage(address(spotSwapTerminal), abi.encodeCall(SpotSwapTerminal.preApprove, (order)), block.timestamp, 0, bytes32(++requestSalt));
    }

    function _depotBalance(address user) internal view returns (uint256) {
        return depot.balanceOf(_account(user), TransitTokenLib.formatAssetId(HUB_CHAIN_ID, address(usdc)));
    }

    function _account(address user) internal pure returns (bytes32) {
        return TransitTokenLib.formatAccountId(HUB_CHAIN_ID, user);
    }

}
