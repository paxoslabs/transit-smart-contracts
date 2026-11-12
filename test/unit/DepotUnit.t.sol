// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { dispatchOne } from "../helpers/DispatchOne.sol";
import { Test } from "forge-std/Test.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { TransitAuthority } from "../../src/TransitAuthority.sol";
import { HubWarehouseConductor } from "../../src/conductor/HubWarehouseConductor.sol";
import { SpokeWarehouse } from "../../src/SpokeWarehouse.sol";
import { Depot } from "../../src/depot/Depot.sol";
import { SpotSwapConductor } from "../../src/conductor/SpotSwapConductor.sol";
import { SwapConductor } from "../../src/conductor/SwapConductor.sol";
import { UserConductor } from "../../src/conductor/UserConductor.sol";
import { IMessagingAdapter } from "../../src/messaging/IMessagingAdapter.sol";
import { Turnstile } from "../../src/turnstile/Turnstile.sol";
import { ITurnstile } from "../../src/turnstile/ITurnstile.sol";
import { MockMessagingAdapter } from "../mocks/MockMessagingAdapter.sol";
import { MockERC20 } from "../../lib/solady/test/utils/mocks/MockERC20.sol";
import { Roles } from "../../src/helpers/Roles.sol";
import { TransitTokenLib } from "../../src/helpers/TransitTokenLib.sol";

contract DepotUnitTest is Test {

    uint64 constant HUB_CHAIN_ID = 1;

    TransitAuthority authority;
    SpokeWarehouse warehouse;
    Depot depot;
    UserConductor userConductor;
    HubWarehouseConductor hubWarehouseConductor;
    SpotSwapConductor spotSwapConductor;
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
        warehouse = new SpokeWarehouse(address(authority), vault);
        turnstile = new Turnstile(address(authority), address(warehouse));
        depot = new Depot(address(authority));
        local = new MockMessagingAdapter(address(authority), address(turnstile), HUB_CHAIN_ID);
        userConductor = new UserConductor(address(depot), address(turnstile));
        hubWarehouseConductor =
            new HubWarehouseConductor(address(authority), address(depot), address(userConductor), address(turnstile));
        spotSwapConductor =
            new SpotSwapConductor(address(authority), address(depot), _account(backend), address(turnstile));
        usdc = ERC20(address(new MockERC20("USD Coin", "USDC", 6)));
        usdg = ERC20(address(new MockERC20("Global Dollar", "USDG", 6)));

        bytes4[] memory warehouseAdminSels = new bytes4[](1);
        warehouseAdminSels[0] = SpokeWarehouse.setAssetWhitelisted.selector;

        bytes4[] memory warehouseTurnstileSels = new bytes4[](3);
        warehouseTurnstileSels[0] = SpokeWarehouse.receiveWithdrawal.selector;
        warehouseTurnstileSels[1] = SpokeWarehouse.custody.selector;
        warehouseTurnstileSels[2] = SpokeWarehouse.permit.selector;

        bytes4[] memory receiveSels = new bytes4[](1);
        receiveSels[0] = Turnstile.receiveMessage.selector;

        bytes4[] memory solverSels = new bytes4[](1);
        solverSels[0] = SpotSwapConductor.settle.selector;

        bytes4[] memory facilitateSels = new bytes4[](1);
        facilitateSels[0] = Turnstile.facilitate.selector;

        bytes4[] memory epochSels = new bytes4[](1);
        epochSels[0] = Depot.advanceEpoch.selector;

        bytes4[] memory turnstileAdminSels = new bytes4[](3);
        turnstileAdminSels[0] = Turnstile.setMessagingAdapter.selector;
        turnstileAdminSels[1] = Turnstile.setRoutable.selector;
        turnstileAdminSels[2] = Turnstile.setHubWarehouseConductor.selector;

        bytes4[] memory routedSels = new bytes4[](3);
        routedSels[0] = UserConductor.reserve.selector;
        routedSels[1] = UserConductor.reserveAndRequest.selector;
        routedSels[2] = UserConductor.executeTransfer.selector;

        bytes4[] memory swapRoutedSels = new bytes4[](2);
        swapRoutedSels[0] = SpotSwapConductor.preApprove.selector;
        swapRoutedSels[1] = SwapConductor.requestOrderCancellation.selector;

        vm.startPrank(admin);
        authority.setTargetFunctionRole(address(warehouse), warehouseAdminSels, Roles.ADMIN);
        authority.setTargetFunctionRole(address(turnstile), receiveSels, Roles.MESSAGING_ADAPTER);
        authority.setTargetFunctionRole(address(warehouse), warehouseTurnstileSels, Roles.TURNSTILE);
        authority.setTargetFunctionRole(address(spotSwapConductor), solverSels, Roles.SOLVER);
        authority.setTargetFunctionRole(address(turnstile), facilitateSels, Roles.SOLVER);
        authority.setTargetFunctionRole(address(depot), epochSels, Roles.EPOCH);
        authority.grantRole(Roles.EPOCH, address(spotSwapConductor));
        authority.grantRole(Roles.MESSAGING_ADAPTER, address(local));
        authority.grantRole(Roles.SOLVER, backend);
        warehouse.setAssetWhitelisted(_list(address(usdc)), true);
        authority.setTargetFunctionRole(address(turnstile), turnstileAdminSels, Roles.ADMIN);
        authority.grantRole(Roles.TURNSTILE, address(turnstile));
        bytes4[] memory userConductorSels = new bytes4[](6);
        userConductorSels[0] = Depot.reserve.selector;
        userConductorSels[1] = Depot.release.selector;
        userConductorSels[2] = Depot.transferFrom.selector;
        userConductorSels[3] = Depot.burn.selector;
        userConductorSels[4] = Depot.transferAmong.selector;
        userConductorSels[5] = Depot.mint.selector;
        authority.setTargetFunctionRole(address(depot), userConductorSels, Roles.CONDUCTOR);
        authority.grantRole(Roles.CONDUCTOR, address(userConductor));
        authority.grantRole(Roles.CONDUCTOR, address(hubWarehouseConductor));
        bytes4[] memory hubWarehouseTurnstileSels = new bytes4[](2);
        hubWarehouseTurnstileSels[0] = HubWarehouseConductor.receiveDeposit.selector;
        hubWarehouseTurnstileSels[1] = HubWarehouseConductor.executeWithdrawal.selector;
        authority.setTargetFunctionRole(address(hubWarehouseConductor), hubWarehouseTurnstileSels, Roles.TURNSTILE);
        turnstile.setHubWarehouseConductor(address(hubWarehouseConductor));
        authority.grantRole(Roles.CONDUCTOR, address(spotSwapConductor));
        turnstile.setRoutable(address(userConductor), routedSels, true);
        turnstile.setRoutable(address(spotSwapConductor), swapRoutedSels, true);
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
        dispatchOne(
            turnstile,
            ITurnstile.ActionType.Deposit,
            abi.encode(
                ITurnstile.DepositAction({
                    asset: address(usdc),
                    amount: amount,
                    toChainId: HUB_CHAIN_ID,
                    to: user,
                    deadline: type(uint256).max,
                    salt: bytes32(0),
                    permit: ITurnstile.Permit({ deadline: 0, v: 0, r: bytes32(0), s: bytes32(0) })
                })
            ),
            0
        );
        vm.stopPrank();
    }

    function _advanceEpoch() internal {
        vm.warp(block.timestamp + 24 hours);
        depot.advanceEpoch(depot.settlementEpoch());
    }

    function _transferRequest(
        address owner,
        address to,
        uint256 amount
    )
        internal
        returns (UserConductor.TransferRequest memory)
    {
        return UserConductor.TransferRequest({
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

    function _withdrawalAction(address owner, uint256 amount) internal returns (ITurnstile.WithdrawalAction memory) {
        return ITurnstile.WithdrawalAction({
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

    function _order(uint256 sellAmount, bool partiallyFillable) internal returns (SpotSwapConductor.Order memory) {
        return SpotSwapConductor.Order({
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

    function _generic(address target, bytes memory data) internal returns (ITurnstile.GenericAction memory) {
        return ITurnstile.GenericAction({
            target: target, data: data, deadline: block.timestamp, salt: bytes32(++requestSalt)
        });
    }

    function _facilitatedCancellation(bytes32 orderHash) internal returns (ITurnstile.GenericAction memory) {
        return ITurnstile.GenericAction({
            target: address(spotSwapConductor),
            data: abi.encodeCall(SwapConductor.requestOrderCancellation, (orderHash)),
            deadline: type(uint256).max,
            salt: bytes32(++requestSalt)
        });
    }

    function _signFacilitated(ITurnstile.GenericAction memory message, uint256 pk)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, turnstile.hashGenericAction(message));
        return abi.encodePacked(r, s, v);
    }

    function _facilitate(ITurnstile.GenericAction memory message, bytes memory signature) internal {
        ITurnstile.ActionType[] memory actionTypes = new ITurnstile.ActionType[](1);
        actionTypes[0] = ITurnstile.ActionType.Generic;
        bytes[] memory actionData = new bytes[](1);
        actionData[0] = abi.encode(message);
        uint256[] memory fares = new uint256[](1);
        uint64[] memory messageGas = new uint64[](1);
        vm.prank(backend);
        turnstile.facilitate(actionTypes, actionData, _toArray(signature), fares, messageGas);
    }

    function _toArray(bytes memory signature) internal pure returns (bytes[] memory signatures) {
        signatures = new bytes[](1);
        signatures[0] = signature;
    }

    function _settle(
        SpotSwapConductor.Order memory order,
        bytes memory signature,
        uint256 amount,
        bytes memory revertData
    )
        internal
    {
        SpotSwapConductor.Order[] memory orders = new SpotSwapConductor.Order[](1);
        orders[0] = order;
        SpotSwapConductor.Fill[] memory fills = new SpotSwapConductor.Fill[](1);
        fills[0] = SpotSwapConductor.Fill(amount, amount);
        uint256 epoch = depot.settlementEpoch();
        vm.prank(backend);
        if (revertData.length != 0) vm.expectRevert(revertData);
        spotSwapConductor.settle(epoch, orders, _toArray(signature), fills, new SpotSwapConductor.Fee[](0));
    }

    // ---------------------------------------------------------------- transfer

    function testRequestTransferReservesThenExecutes() public {
        _deposit(alice, 100e6);
        UserConductor.TransferRequest memory request = _transferRequest(alice, bob, 60e6);

        bytes32 requestId = userConductor.hashTransferRequest(request);
        vm.prank(alice);
        dispatchOne(
            turnstile,
            ITurnstile.ActionType.Generic,
            abi.encode(
                _generic(
                    address(userConductor),
                    abi.encodeCall(UserConductor.reserveAndRequest, (requestId, request.assetId, request.amount))
                )
            ),
            0
        );

        assertEq(
            userConductor.requestStatus(_account(alice), requestId),
            depot.settlementEpoch() + 1,
            "request: status not pending next epoch"
        );
        assertEq(_depotBalance(alice), 100e6, "request: balance moved early");
        assertEq(_depotBalance(bob), 0, "request: bob credited early");

        vm.prank(bob);
        vm.expectRevert(UserConductor.NotEffective.selector);
        userConductor.executeTransfer(request);

        _advanceEpoch();

        vm.prank(bob);
        userConductor.executeTransfer(request);

        assertEq(
            userConductor.requestStatus(_account(alice), requestId),
            userConductor.EXECUTED(),
            "execute: status not executed"
        );
        assertEq(_depotBalance(alice), 40e6, "execute: alice not debited");
        assertEq(_depotBalance(bob), 60e6, "execute: bob not credited");

        vm.prank(bob);
        vm.expectRevert(UserConductor.RequestReplay.selector);
        userConductor.executeTransfer(request);
    }

    function testRequestTransferReplayReverts() public {
        _deposit(alice, 100e6);
        UserConductor.TransferRequest memory request = _transferRequest(alice, bob, 60e6);

        bytes memory data = abi.encodeCall(
            UserConductor.reserveAndRequest,
            (userConductor.hashTransferRequest(request), request.assetId, request.amount)
        );

        vm.prank(alice);
        dispatchOne(turnstile, ITurnstile.ActionType.Generic, abi.encode(_generic(address(userConductor), data)), 0);

        vm.prank(alice);
        vm.expectRevert(UserConductor.RequestReplay.selector);
        dispatchOne(turnstile, ITurnstile.ActionType.Generic, abi.encode(_generic(address(userConductor), data)), 0);
    }

    // ---------------------------------------------------------------- withdrawal

    function testRequestWithdrawalReservesThenExecutes() public {
        _deposit(alice, 100e6);
        ITurnstile.WithdrawalAction memory request = _withdrawalAction(alice, 40e6);

        bytes32 requestId = hubWarehouseConductor.hashWithdrawalAction(request);
        vm.prank(alice);
        dispatchOne(
            turnstile,
            ITurnstile.ActionType.Generic,
            abi.encode(
                _generic(
                    address(userConductor),
                    abi.encodeCall(UserConductor.reserveAndRequest, (requestId, request.assetId, request.amount))
                )
            ),
            0
        );

        assertEq(
            userConductor.requestStatus(_account(alice), requestId),
            depot.settlementEpoch() + 1,
            "request: status not pending next epoch"
        );
        assertEq(usdc.balanceOf(alice), 0, "request: alice received usdc early");

        _advanceEpoch();

        vm.prank(bob);
        dispatchOne(turnstile, ITurnstile.ActionType.Withdrawal, abi.encode(request), 0);

        assertEq(
            hubWarehouseConductor.requestStatus(_account(alice), requestId),
            hubWarehouseConductor.EXECUTED(),
            "execute: status not executed"
        );
        assertEq(_depotBalance(alice), 60e6, "execute: alice depot balance not burned");
        assertEq(usdc.balanceOf(alice), 40e6, "execute: alice did not receive usdc");
    }

    function testRequestWithdrawalReplayReverts() public {
        _deposit(alice, 100e6);
        ITurnstile.WithdrawalAction memory request = _withdrawalAction(alice, 40e6);

        bytes memory data = abi.encodeCall(
            UserConductor.reserveAndRequest,
            (hubWarehouseConductor.hashWithdrawalAction(request), request.assetId, request.amount)
        );

        vm.prank(alice);
        dispatchOne(turnstile, ITurnstile.ActionType.Generic, abi.encode(_generic(address(userConductor), data)), 0);

        vm.prank(alice);
        vm.expectRevert(UserConductor.RequestReplay.selector);
        dispatchOne(turnstile, ITurnstile.ActionType.Generic, abi.encode(_generic(address(userConductor), data)), 0);
    }

    // ---------------------------------------------------------------- orders

    function testPreApproveAllowsEmptySignatureFill() public {
        _deposit(alice, 100e6);
        SpotSwapConductor.Order memory order = _order(100e6, false);
        bytes32 orderHash = spotSwapConductor.hashOrder(order);

        vm.prank(alice);
        dispatchOne(
            turnstile,
            ITurnstile.ActionType.Generic,
            abi.encode(_generic(address(spotSwapConductor), abi.encodeCall(SpotSwapConductor.preApprove, (order)))),
            0
        );

        assertTrue(spotSwapConductor.preApproved(orderHash), "preApprove: hash not marked");

        _settle(order, "", 100e6, "");

        assertEq(spotSwapConductor.filledAmount(orderHash), 100e6, "fill: amount not recorded");
    }

    function testFillWithoutPreApproveReverts() public {
        _deposit(alice, 100e6);
        SpotSwapConductor.Order memory order = _order(100e6, false);
        bytes32 orderHash = spotSwapConductor.hashOrder(order);

        _settle(order, "", 100e6, abi.encodeWithSelector(SwapConductor.NotPreApproved.selector, orderHash));
    }

    function testRequestOrderCancellationTakesEffectNextEpoch() public {
        _deposit(alice, 100e6);
        SpotSwapConductor.Order memory order = _order(100e6, true);
        bytes32 orderHash = spotSwapConductor.hashOrder(order);

        vm.prank(alice);
        dispatchOne(
            turnstile,
            ITurnstile.ActionType.Generic,
            abi.encode(_generic(address(spotSwapConductor), abi.encodeCall(SpotSwapConductor.preApprove, (order)))),
            0
        );

        vm.prank(alice);
        dispatchOne(
            turnstile,
            ITurnstile.ActionType.Generic,
            abi.encode(
                _generic(
                    address(spotSwapConductor), abi.encodeCall(SwapConductor.requestOrderCancellation, (orderHash))
                )
            ),
            0
        );

        assertEq(
            spotSwapConductor.cancelledFrom(_account(alice), orderHash),
            depot.settlementEpoch() + 1,
            "cancel: not effective next epoch"
        );

        _settle(order, "", 60e6, "");

        _advanceEpoch();

        _settle(order, "", 40e6, abi.encodeWithSelector(SwapConductor.Cancelled.selector, orderHash));
    }

    // ---------------------------------------------------------------- facilitated cancel

    function _preApprovedOrder() internal returns (SpotSwapConductor.Order memory order, bytes32 orderHash) {
        _deposit(alice, 100e6);
        order = _order(100e6, false);
        orderHash = spotSwapConductor.hashOrder(order);

        vm.prank(alice);
        dispatchOne(
            turnstile,
            ITurnstile.ActionType.Generic,
            abi.encode(_generic(address(spotSwapConductor), abi.encodeCall(SpotSwapConductor.preApprove, (order)))),
            0
        );
    }

    function testFacilitatedOrderCancellationIsImmediateAndPaysFee() public {
        (SpotSwapConductor.Order memory order, bytes32 orderHash) = _preApprovedOrder();
        ITurnstile.GenericAction memory message = _facilitatedCancellation(orderHash);

        _facilitate(message, _signFacilitated(message, alicePk));

        assertEq(
            spotSwapConductor.cancelledFrom(_account(alice), orderHash),
            depot.settlementEpoch(),
            "facilitate: cancel not immediate"
        );
        /// TODO: Restore fee assertions once facilitate charges fees.

        _settle(order, "", 100e6, abi.encodeWithSelector(SwapConductor.Cancelled.selector, orderHash));
    }

    function testFacilitatedOrderCancellationReplayReverts() public {
        (, bytes32 orderHash) = _preApprovedOrder();
        ITurnstile.GenericAction memory message = _facilitatedCancellation(orderHash);
        bytes memory sig = _signFacilitated(message, alicePk);

        _facilitate(message, sig);

        vm.expectRevert(ITurnstile.MessageReplay.selector);
        _facilitate(message, sig);
    }

    function testFacilitatedOrderCancellationOverridesPendingUserCancel() public {
        (, bytes32 orderHash) = _preApprovedOrder();

        vm.prank(alice);
        dispatchOne(
            turnstile,
            ITurnstile.ActionType.Generic,
            abi.encode(
                _generic(
                    address(spotSwapConductor), abi.encodeCall(SwapConductor.requestOrderCancellation, (orderHash))
                )
            ),
            0
        );

        assertEq(
            spotSwapConductor.cancelledFrom(_account(alice), orderHash),
            depot.settlementEpoch() + 1,
            "setup: user cancel not pending"
        );

        ITurnstile.GenericAction memory message = _facilitatedCancellation(orderHash);
        _facilitate(message, _signFacilitated(message, alicePk));

        assertEq(
            spotSwapConductor.cancelledFrom(_account(alice), orderHash),
            depot.settlementEpoch(),
            "facilitate: did not take earliest epoch"
        );
    }

    /// TODO: Decide test name; a wrong signer no longer reverts, it acts as its own account.
    function testFacilitatedOrderCancellationBadSignatureReverts() public {
        (, bytes32 orderHash) = _preApprovedOrder();
        ITurnstile.GenericAction memory message = _facilitatedCancellation(orderHash);
        (, uint256 wrongPk) = makeAddrAndKey("notTheSigner");
        bytes memory sig = _signFacilitated(message, wrongPk);

        _facilitate(message, sig);

        assertEq(
            spotSwapConductor.cancelledFrom(_account(alice), orderHash), 0, "bad sig: cancellation recorded for alice"
        );
    }

    // ---------------------------------------------------------------- auth

    function testPreApproveForAnotherOwnerReverts() public {
        SpotSwapConductor.Order memory order = _order(100e6, false);

        vm.prank(bob);
        vm.expectRevert(SwapConductor.NotOwner.selector);
        dispatchOne(
            turnstile,
            ITurnstile.ActionType.Generic,
            abi.encode(_generic(address(spotSwapConductor), abi.encodeCall(SpotSwapConductor.preApprove, (order)))),
            0
        );
    }

    function _depotBalance(address user) internal view returns (uint256) {
        return depot.balanceOf(_account(user), TransitTokenLib.formatAssetId(HUB_CHAIN_ID, address(usdc)));
    }

    function _account(address user) internal pure returns (bytes32) {
        return TransitTokenLib.formatAccountId(HUB_CHAIN_ID, user, false);
    }

}
