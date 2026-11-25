// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { Test, Vm } from "forge-std/Test.sol";
import { Depot } from "src/depot/Depot.sol";
import { AddressFreezeList } from "src/AddressFreezeList.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { Roles } from "src/helpers/Roles.sol";
import { Typehashes } from "src/helpers/Typehashes.sol";
import { TransitAddressLib } from "src/helpers/TransitAddressLib.sol";
import { UserConductor } from "src/conductor/UserConductor.sol";
import { IUserConductor } from "src/interfaces/IUserConductor.sol";
import { IRequestConductor } from "src/interfaces/IRequestConductor.sol";
import { FACILITATED_FLAG } from "src/conductor/Conductor.sol";
import { IConductor } from "src/interfaces/IConductor.sol";

contract UserConductorUnitTest is Test {

    uint64 constant REMOTE_CHAIN = 1;

    address admin = makeAddr("admin");
    address turnstile = makeAddr("turnstile");
    address seeder = makeAddr("seeder");
    address owner = makeAddr("owner");
    address recipient = makeAddr("recipient");
    address stranger = makeAddr("stranger");
    address asset = makeAddr("asset");

    AccessManager authority;
    AddressFreezeList freezeList;
    Depot depot;
    UserConductor conductor;

    bytes28 OWNER_ACCOUNT;
    bytes28 RECIPIENT_ACCOUNT;
    bytes28 ASSET_ID;

    function setUp() public {
        vm.warp(10_000);
        authority = new AccessManager(admin);
        freezeList = new AddressFreezeList(address(authority));
        depot = new Depot(address(authority), freezeList);
        conductor = new UserConductor(address(depot), turnstile);

        OWNER_ACCOUNT = TransitAddressLib.formatTransitAddress(uint64(block.chainid), owner);
        RECIPIENT_ACCOUNT = TransitAddressLib.formatTransitAddress(uint64(block.chainid), recipient);
        ASSET_ID = TransitAddressLib.formatTransitAddress(uint64(block.chainid), asset);

        bytes4[] memory conductorSelectors = new bytes4[](4);
        conductorSelectors[0] = Depot.transferFrom.selector;
        conductorSelectors[1] = Depot.reserve.selector;
        conductorSelectors[2] = Depot.release.selector;
        conductorSelectors[3] = Depot.mint.selector;

        vm.startPrank(admin);
        authority.setTargetFunctionRole(address(depot), conductorSelectors, Roles.CONDUCTOR);
        authority.setTargetFunctionRole(address(depot), _selectors(Depot.advanceEpoch.selector), Roles.EPOCH);
        authority.grantRole(Roles.CONDUCTOR, address(conductor), 0);
        authority.grantRole(Roles.CONDUCTOR, seeder, 0);
        authority.grantRole(Roles.EPOCH, seeder, 0);
        vm.stopPrank();
    }

    function _selectors(bytes4 a) internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = a;
    }

    function _seed(bytes28 accountId, uint256 amount) internal {
        vm.prank(seeder);
        depot.mint(accountId, ASSET_ID, amount);
    }

    function _advanceEpoch() internal {
        vm.prank(seeder);
        depot.advanceEpoch();
    }

    function _transferRequest() internal view returns (IUserConductor.TransferRequest memory r) {
        r.ownerChainId = uint64(block.chainid);
        r.owner = owner;
        r.toChainId = uint64(block.chainid);
        r.to = recipient;
        r.assetChainId = uint64(block.chainid);
        r.asset = asset;
        r.amount = 100;
        r.deadline = block.timestamp + 1 hours;
        r.partiallyFillable = true;
        r.salt = bytes32(uint256(1));
    }

    function _requestAndAdvance(IUserConductor.TransferRequest memory r) internal {
        vm.prank(owner);
        conductor.requestTransfer(r);
        _advanceEpoch();
    }

    function _relay(bytes memory data, bytes28 accountId, bool facilitated) internal {
        vm.prank(turnstile);
        (bool ok, bytes memory result) =
            address(conductor).call(abi.encodePacked(data, accountId, facilitated ? FACILITATED_FLAG : bytes4(0)));
        if (!ok) {
            assembly { revert(add(result, 32), mload(result)) }
        }
    }

    function test_constructor_SetsDepot() public view {
        assertEq(conductor.DEPOT(), address(depot), "DEPOT not set");
    }

    function test_constructor_SetsTurnstile() public view {
        assertEq(conductor.TURNSTILE(), turnstile, "TURNSTILE not set");
    }

    function test_EXECUTED_ReturnsMaxUint() public view {
        assertEq(conductor.EXECUTED(), type(uint256).max, "EXECUTED not max uint");
    }

    function test_DEPOT_ReturnsDepot() public view {
        assertEq(conductor.DEPOT(), address(depot), "DEPOT not returned");
    }

    function test_requestEffectiveAtEpoch_ReturnsZeroForRequestNeverMade() public view {
        bytes32 requestId = conductor.transferRequestId(_transferRequest());
        assertEq(conductor.requestEffectiveAtEpoch(OWNER_ACCOUNT, requestId), 0, "unknown request not zero");
    }

    function test_requestEffectiveAtEpoch_ReturnsEffectiveEpochForPendingRequest() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        vm.prank(owner);
        conductor.requestTransfer(r);
        bytes32 requestId = conductor.transferRequestId(r);
        assertEq(
            conductor.requestEffectiveAtEpoch(OWNER_ACCOUNT, requestId),
            depot.settlementEpoch() + 1,
            "effective epoch not settlementEpoch + 1"
        );
    }

    function test_requestEffectiveAtEpoch_ReturnsExecutedForConsumedRequest() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        _seed(OWNER_ACCOUNT, 100);
        _requestAndAdvance(r);
        conductor.executeTransfer(r);
        bytes32 requestId = conductor.transferRequestId(r);
        assertEq(conductor.requestEffectiveAtEpoch(OWNER_ACCOUNT, requestId), conductor.EXECUTED(), "not EXECUTED");
    }

    function test_requestTransfer_ReservesAmountOfAssetFromOwnerAccount() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        vm.prank(owner);
        conductor.requestTransfer(r);
        (, uint256 pending,) = depot.reservation(OWNER_ACCOUNT, ASSET_ID);
        assertEq(pending, 100, "amount not reserved");
    }

    function test_requestTransfer_SetsRequestEffectiveAtEpochToNextSettlementEpoch() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        vm.prank(owner);
        conductor.requestTransfer(r);
        bytes32 requestId = conductor.transferRequestId(r);
        assertEq(
            conductor.requestEffectiveAtEpoch(OWNER_ACCOUNT, requestId),
            depot.settlementEpoch() + 1,
            "effective epoch not settlementEpoch + 1"
        );
    }

    function test_requestTransfer_AcceptsOwnerRelayedThroughTurnstile() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        r.ownerChainId = REMOTE_CHAIN;
        bytes28 remoteAccount = TransitAddressLib.formatTransitAddress(REMOTE_CHAIN, owner);
        bytes32 requestId = conductor.transferRequestId(r);
        _relay(abi.encodeCall(IUserConductor.requestTransfer, (r)), remoteAccount, false);
        assertEq(
            conductor.requestEffectiveAtEpoch(remoteAccount, requestId),
            depot.settlementEpoch() + 1,
            "relayed request not recorded"
        );
        (, uint256 pending,) = depot.reservation(remoteAccount, ASSET_ID);
        assertEq(pending, 100, "amount not reserved for relayed owner");
    }

    function test_requestTransfer_EmitsRequestedEvent() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        bytes32 requestId = conductor.transferRequestId(r);
        vm.expectEmit(address(conductor));
        emit IRequestConductor.Requested(OWNER_ACCOUNT, requestId, depot.settlementEpoch() + 1);
        vm.prank(owner);
        conductor.requestTransfer(r);
    }

    function test_requestTransfer_RevertIf_SenderIsNotRequestOwner() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        vm.expectRevert(IConductor.NotOwner.selector);
        vm.prank(stranger);
        conductor.requestTransfer(r);
    }

    function test_requestTransfer_RevertIf_RequestWasAlreadyMade() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        vm.prank(owner);
        conductor.requestTransfer(r);
        vm.expectRevert(IRequestConductor.RequestReplay.selector);
        vm.prank(owner);
        conductor.requestTransfer(r);
    }

    function test_executeTransfer_MovesBalance() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        _seed(OWNER_ACCOUNT, 100);
        _requestAndAdvance(r);
        conductor.executeTransfer(r);
        assertEq(depot.balanceOf(OWNER_ACCOUNT, ASSET_ID), 0, "owner balance wrong");
        assertEq(depot.balanceOf(RECIPIENT_ACCOUNT, ASSET_ID), 100, "recipient balance wrong");
    }

    function test_executeTransfer_ReleasesReservationOfConsumedRequest() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        _seed(OWNER_ACCOUNT, 100);
        _requestAndAdvance(r);
        conductor.executeTransfer(r);
        (uint256 effective, uint256 pending,) = depot.reservation(OWNER_ACCOUNT, ASSET_ID);
        assertEq(effective, 0, "effective reservation not released");
        assertEq(pending, 0, "pending reservation not released");
    }

    function test_executeTransfer_ReleasesEntireReservationOnPartialFill() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        _seed(OWNER_ACCOUNT, 60);
        _requestAndAdvance(r);
        conductor.executeTransfer(r);
        (uint256 effective, uint256 pending,) = depot.reservation(OWNER_ACCOUNT, ASSET_ID);
        assertEq(effective, 0, "effective reservation not fully released");
        assertEq(pending, 0, "pending reservation not fully released");
    }

    function test_executeTransfer_ReleasesEntireReservationOnZeroFill() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        r.partiallyFillable = false;
        _seed(OWNER_ACCOUNT, 60);
        _requestAndAdvance(r);
        conductor.executeTransfer(r);
        (uint256 effective, uint256 pending,) = depot.reservation(OWNER_ACCOUNT, ASSET_ID);
        assertEq(effective, 0, "effective reservation not fully released");
        assertEq(pending, 0, "pending reservation not fully released");
    }

    function test_executeTransfer_ReleasesEntireReservationIfDeadlineHasPassed() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        _seed(OWNER_ACCOUNT, 100);
        _requestAndAdvance(r);
        vm.warp(r.deadline + 1);
        conductor.executeTransfer(r);
        (uint256 effective, uint256 pending,) = depot.reservation(OWNER_ACCOUNT, ASSET_ID);
        assertEq(effective, 0, "effective reservation not fully released");
        assertEq(pending, 0, "pending reservation not fully released");
    }

    function test_executeTransfer_SetsRequestEffectiveAtEpochToExecuted() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        _seed(OWNER_ACCOUNT, 100);
        _requestAndAdvance(r);
        conductor.executeTransfer(r);
        bytes32 requestId = conductor.transferRequestId(r);
        assertEq(conductor.requestEffectiveAtEpoch(OWNER_ACCOUNT, requestId), conductor.EXECUTED(), "not EXECUTED");
    }

    function test_executeTransfer_AllowsExecutionByAccountOtherThanOwner() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        _seed(OWNER_ACCOUNT, 100);
        _requestAndAdvance(r);
        vm.prank(stranger);
        conductor.executeTransfer(r);
        assertEq(depot.balanceOf(RECIPIENT_ACCOUNT, ASSET_ID), 100, "recipient not paid");
    }

    function test_executeTransfer_AllowsFacilitatedOwnerToExecuteWithoutPriorRequest() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        _seed(OWNER_ACCOUNT, 100);
        _relay(abi.encodeCall(IUserConductor.executeTransfer, (r)), OWNER_ACCOUNT, true);
        assertEq(depot.balanceOf(RECIPIENT_ACCOUNT, ASSET_ID), 100, "recipient not paid");
        bytes32 requestId = conductor.transferRequestId(r);
        assertEq(conductor.requestEffectiveAtEpoch(OWNER_ACCOUNT, requestId), conductor.EXECUTED(), "not EXECUTED");
    }

    function test_executeTransfer_TransfersPartialAmountIfPartiallyFillableAndFreeBalanceIsInsufficient() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        _seed(OWNER_ACCOUNT, 60);
        _requestAndAdvance(r);
        conductor.executeTransfer(r);
        assertEq(depot.balanceOf(RECIPIENT_ACCOUNT, ASSET_ID), 60, "partial amount not transferred");
    }

    function test_executeTransfer_TransfersZeroIfNotPartiallyFillableAndFreeBalanceIsInsufficient() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        r.partiallyFillable = false;
        _seed(OWNER_ACCOUNT, 60);
        _requestAndAdvance(r);
        conductor.executeTransfer(r);
        assertEq(depot.balanceOf(OWNER_ACCOUNT, ASSET_ID), 60, "owner balance moved");
        assertEq(depot.balanceOf(RECIPIENT_ACCOUNT, ASSET_ID), 0, "recipient paid");
    }

    function test_executeTransfer_ConsumesRequestWithoutMovingFundsIfDeadlineHasPassed() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        _seed(OWNER_ACCOUNT, 100);
        _requestAndAdvance(r);
        vm.warp(r.deadline + 1);
        conductor.executeTransfer(r);
        bytes32 requestId = conductor.transferRequestId(r);
        assertEq(conductor.requestEffectiveAtEpoch(OWNER_ACCOUNT, requestId), conductor.EXECUTED(), "not consumed");
        assertEq(depot.balanceOf(RECIPIENT_ACCOUNT, ASSET_ID), 0, "funds moved");
    }

    function test_executeTransfer_ConsumesRequestWithoutMovingFundsIfRecipientAddressIsZero() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        r.to = address(0);
        _seed(OWNER_ACCOUNT, 100);
        _requestAndAdvance(r);
        conductor.executeTransfer(r);
        bytes32 requestId = conductor.transferRequestId(r);
        assertEq(conductor.requestEffectiveAtEpoch(OWNER_ACCOUNT, requestId), conductor.EXECUTED(), "not consumed");
        assertEq(depot.balanceOf(OWNER_ACCOUNT, ASSET_ID), 100, "funds moved");
        (uint256 effective, uint256 pending,) = depot.reservation(OWNER_ACCOUNT, ASSET_ID);
        assertEq(effective, 0, "effective reservation not released");
        assertEq(pending, 0, "pending reservation not released");
    }

    function test_executeTransfer_ConsumesRequestWithoutMovingFundsIfRecipientChainIdIsZero() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        r.toChainId = 0;
        _seed(OWNER_ACCOUNT, 100);
        _requestAndAdvance(r);
        conductor.executeTransfer(r);
        bytes32 requestId = conductor.transferRequestId(r);
        assertEq(conductor.requestEffectiveAtEpoch(OWNER_ACCOUNT, requestId), conductor.EXECUTED(), "not consumed");
        assertEq(depot.balanceOf(OWNER_ACCOUNT, ASSET_ID), 100, "funds moved");
        (uint256 effective, uint256 pending,) = depot.reservation(OWNER_ACCOUNT, ASSET_ID);
        assertEq(effective, 0, "effective reservation not released");
        assertEq(pending, 0, "pending reservation not released");
    }

    function test_executeTransfer_EmitsRequestVoidedEventIfRecipientIsInvalid() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        r.to = address(0);
        _seed(OWNER_ACCOUNT, 100);
        _requestAndAdvance(r);
        bytes32 requestId = conductor.transferRequestId(r);
        vm.expectEmit(address(conductor));
        emit IRequestConductor.RequestVoided(requestId);
        conductor.executeTransfer(r);
    }

    function test_executeTransfer_EmitsConsumedEvent() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        _seed(OWNER_ACCOUNT, 100);
        _requestAndAdvance(r);
        bytes32 requestId = conductor.transferRequestId(r);
        vm.expectEmit(address(conductor));
        emit IRequestConductor.Consumed(OWNER_ACCOUNT, requestId);
        conductor.executeTransfer(r);
    }

    function test_executeTransfer_EmitsTransferExecutedEvent() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        _seed(OWNER_ACCOUNT, 100);
        _requestAndAdvance(r);
        bytes32 requestId = conductor.transferRequestId(r);
        vm.expectEmit(address(conductor));
        emit IUserConductor.TransferExecuted(requestId, 100);
        conductor.executeTransfer(r);
    }

    function test_executeTransfer_EmitsRequestExpiredEventIfDeadlineHasPassed() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        _seed(OWNER_ACCOUNT, 100);
        _requestAndAdvance(r);
        bytes32 requestId = conductor.transferRequestId(r);
        vm.warp(r.deadline + 1);
        vm.expectEmit(address(conductor));
        emit IRequestConductor.RequestExpired(requestId);
        conductor.executeTransfer(r);
    }

    function test_executeTransfer_DoesNotEmitTransferExecutedEventIfDeadlineHasPassed() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        _seed(OWNER_ACCOUNT, 100);
        _requestAndAdvance(r);
        vm.warp(r.deadline + 1);
        vm.recordLogs();
        conductor.executeTransfer(r);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 transferExecutedTopic = keccak256("TransferExecuted(bytes32,uint256)");
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != transferExecutedTopic, "TransferExecuted emitted");
        }
    }

    function test_executeTransfer_RevertIf_RequestWasNeverMadeAndSenderIsNotFacilitatedOwner() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        vm.expectRevert(IRequestConductor.NotEffective.selector);
        vm.prank(owner);
        conductor.executeTransfer(r);
    }

    function test_executeTransfer_RevertIf_RequestEpochHasNotArrived() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        vm.prank(owner);
        conductor.requestTransfer(r);
        vm.expectRevert(IRequestConductor.NotEffective.selector);
        conductor.executeTransfer(r);
    }

    function test_executeTransfer_RevertIf_RequestWasAlreadyExecuted() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        _seed(OWNER_ACCOUNT, 100);
        _requestAndAdvance(r);
        conductor.executeTransfer(r);
        vm.expectRevert(IRequestConductor.RequestReplay.selector);
        conductor.executeTransfer(r);
    }

    function test_executeTransfer_RevertIf_RequestWasCancelled() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        _seed(OWNER_ACCOUNT, 100);
        _requestAndAdvance(r);
        vm.prank(owner);
        conductor.cancelTransfer(r);
        vm.expectRevert(IRequestConductor.RequestReplay.selector);
        conductor.executeTransfer(r);
    }

    function test_cancelTransfer_ReleasesReservationOfCancelledRequest() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        _requestAndAdvance(r);
        vm.prank(owner);
        conductor.cancelTransfer(r);
        (uint256 effective, uint256 pending,) = depot.reservation(OWNER_ACCOUNT, ASSET_ID);
        assertEq(effective, 0, "effective reservation not released");
        assertEq(pending, 0, "pending reservation not released");
    }

    function test_cancelTransfer_KeepsOwnerBalance() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        _seed(OWNER_ACCOUNT, 100);
        _requestAndAdvance(r);
        vm.prank(owner);
        conductor.cancelTransfer(r);
        assertEq(depot.balanceOf(OWNER_ACCOUNT, ASSET_ID), 100, "owner balance moved");
    }

    function test_cancelTransfer_SetsRequestEffectiveAtEpochToExecuted() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        _requestAndAdvance(r);
        vm.prank(owner);
        conductor.cancelTransfer(r);
        bytes32 requestId = conductor.transferRequestId(r);
        assertEq(conductor.requestEffectiveAtEpoch(OWNER_ACCOUNT, requestId), conductor.EXECUTED(), "not EXECUTED");
    }

    function test_cancelTransfer_AcceptsOwnerRelayedThroughTurnstile() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        r.ownerChainId = REMOTE_CHAIN;
        bytes28 remoteAccount = TransitAddressLib.formatTransitAddress(REMOTE_CHAIN, owner);
        _relay(abi.encodeCall(IUserConductor.requestTransfer, (r)), remoteAccount, false);
        _advanceEpoch();
        _relay(abi.encodeCall(IUserConductor.cancelTransfer, (r)), remoteAccount, false);
        bytes32 requestId = conductor.transferRequestId(r);
        assertEq(
            conductor.requestEffectiveAtEpoch(remoteAccount, requestId), conductor.EXECUTED(), "relayed cancel failed"
        );
    }

    function test_cancelTransfer_EmitsConsumedEvent() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        _requestAndAdvance(r);
        bytes32 requestId = conductor.transferRequestId(r);
        vm.expectEmit(address(conductor));
        emit IRequestConductor.Consumed(OWNER_ACCOUNT, requestId);
        vm.prank(owner);
        conductor.cancelTransfer(r);
    }

    function test_cancelTransfer_EmitsRequestCancelledEvent() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        _requestAndAdvance(r);
        bytes32 requestId = conductor.transferRequestId(r);
        vm.expectEmit(address(conductor));
        emit IRequestConductor.RequestCancelled(requestId);
        vm.prank(owner);
        conductor.cancelTransfer(r);
    }

    function test_cancelTransfer_RevertIf_SenderIsNotRequestOwner() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        _requestAndAdvance(r);
        vm.expectRevert(IConductor.NotOwner.selector);
        vm.prank(stranger);
        conductor.cancelTransfer(r);
    }

    function test_cancelTransfer_RevertIf_RequestWasNeverMade() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        vm.expectRevert(IRequestConductor.NotEffective.selector);
        vm.prank(owner);
        conductor.cancelTransfer(r);
    }

    function test_cancelTransfer_RevertIf_RequestWasNeverMadeAndSenderIsFacilitatedOwner() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        vm.expectRevert(IRequestConductor.NotEffective.selector);
        _relay(abi.encodeCall(IUserConductor.cancelTransfer, (r)), OWNER_ACCOUNT, true);
    }

    function test_cancelTransfer_RevertIf_RequestEpochHasNotArrived() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        vm.prank(owner);
        conductor.requestTransfer(r);
        vm.expectRevert(IRequestConductor.NotEffective.selector);
        vm.prank(owner);
        conductor.cancelTransfer(r);
    }

    function test_cancelTransfer_RevertIf_RequestWasAlreadyCancelled() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        _requestAndAdvance(r);
        vm.prank(owner);
        conductor.cancelTransfer(r);
        vm.expectRevert(IRequestConductor.RequestReplay.selector);
        vm.prank(owner);
        conductor.cancelTransfer(r);
    }

    function test_cancelTransfer_RevertIf_RequestWasAlreadyExecuted() public {
        IUserConductor.TransferRequest memory r = _transferRequest();
        _seed(OWNER_ACCOUNT, 100);
        _requestAndAdvance(r);
        conductor.executeTransfer(r);
        vm.expectRevert(IRequestConductor.RequestReplay.selector);
        vm.prank(owner);
        conductor.cancelTransfer(r);
    }

    function test_transferRequestId_ReturnsHashOfTypehashAndRequest() public view {
        IUserConductor.TransferRequest memory r = _transferRequest();
        bytes32 expected = keccak256(
            abi.encode(
                Typehashes.TRANSFER_REQUEST,
                r.ownerChainId,
                r.owner,
                r.toChainId,
                r.to,
                r.assetChainId,
                r.asset,
                r.amount,
                r.deadline,
                r.partiallyFillable,
                r.salt
            )
        );
        assertEq(conductor.transferRequestId(r), expected, "request id wrong");
    }

}
