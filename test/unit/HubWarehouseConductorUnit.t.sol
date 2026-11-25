// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { Test } from "forge-std/Test.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Depot } from "src/depot/Depot.sol";
import { AddressFreezeList } from "src/AddressFreezeList.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { Roles } from "src/helpers/Roles.sol";
import { Typehashes } from "src/helpers/Typehashes.sol";
import { TransitAddressLib } from "src/helpers/TransitAddressLib.sol";
import { HubWarehouseConductor } from "src/conductor/HubWarehouseConductor.sol";
import { IHubWarehouseConductor } from "src/interfaces/IHubWarehouseConductor.sol";
import { IRequestConductor } from "src/interfaces/IRequestConductor.sol";
import { ITurnstile } from "src/interfaces/ITurnstile.sol";
import { FACILITATED_FLAG } from "src/conductor/ConductorGatedByTurnstile.sol";

contract HubWarehouseConductorUnitTest is Test {

    uint64 constant REMOTE_CHAIN = 1;

    address admin = makeAddr("admin");
    address turnstile = makeAddr("turnstile");
    address seeder = makeAddr("seeder");
    address owner = makeAddr("owner");
    address recipient = makeAddr("recipient");
    address stranger = makeAddr("stranger");
    address feeReceiver = makeAddr("feeReceiver");
    address asset = makeAddr("asset");

    AccessManager authority;
    AddressFreezeList freezeList;
    Depot depot;
    HubWarehouseConductor conductor;

    bytes28 OWNER_ACCOUNT;
    bytes28 ASSET_ID;
    bytes28 REMOTE_ASSET_ID;

    function setUp() public {
        vm.warp(10_000);
        authority = new AccessManager(admin);
        freezeList = new AddressFreezeList(address(authority));
        depot = new Depot(address(authority), freezeList);
        conductor = new HubWarehouseConductor(address(authority), address(depot), turnstile);

        OWNER_ACCOUNT = TransitAddressLib.formatTransitAddress(uint64(block.chainid), owner);
        ASSET_ID = TransitAddressLib.formatTransitAddress(uint64(block.chainid), asset);
        REMOTE_ASSET_ID = TransitAddressLib.formatTransitAddress(REMOTE_CHAIN, asset);

        bytes4[] memory depotSelectors = new bytes4[](5);
        depotSelectors[0] = Depot.mint.selector;
        depotSelectors[1] = Depot.burn.selector;
        depotSelectors[2] = Depot.reserve.selector;
        depotSelectors[3] = Depot.release.selector;
        depotSelectors[4] = Depot.transferFrom.selector;

        bytes4[] memory turnstileSelectors = new bytes4[](2);
        turnstileSelectors[0] = HubWarehouseConductor.receiveDeposit.selector;
        turnstileSelectors[1] = HubWarehouseConductor.executeWithdrawal.selector;

        vm.startPrank(admin);
        authority.setTargetFunctionRole(address(depot), depotSelectors, Roles.CONDUCTOR);
        authority.setTargetFunctionRole(address(depot), _selectors(Depot.advanceEpoch.selector), Roles.EPOCH);
        authority.setTargetFunctionRole(address(conductor), turnstileSelectors, Roles.TURNSTILE);
        authority.setTargetFunctionRole(
            address(freezeList), _selectors(AddressFreezeList.freeze.selector), Roles.FREEZE_MANAGER
        );
        authority.grantRole(Roles.CONDUCTOR, address(conductor), 0);
        authority.grantRole(Roles.CONDUCTOR, seeder, 0);
        authority.grantRole(Roles.EPOCH, seeder, 0);
        authority.grantRole(Roles.TURNSTILE, turnstile, 0);
        authority.grantRole(Roles.FREEZE_MANAGER, admin, 0);
        vm.stopPrank();
    }

    function _selectors(bytes4 a) internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = a;
    }

    function _seed(bytes28 accountId, bytes28 assetId, uint256 amount) internal {
        vm.prank(seeder);
        depot.mint(accountId, assetId, amount);
    }

    function _advanceEpoch() internal {
        vm.prank(seeder);
        depot.advanceEpoch();
    }

    function _freeze(address account) internal {
        vm.prank(admin);
        freezeList.freeze(account);
    }

    function _withdrawalAction() internal view returns (ITurnstile.WithdrawalAction memory a) {
        a.ownerChainId = uint64(block.chainid);
        a.owner = owner;
        a.to = recipient;
        a.assetChainId = uint64(block.chainid);
        a.asset = asset;
        a.amount = 100;
        a.deadline = block.timestamp + 1 hours;
        a.partiallyFillable = true;
        a.salt = bytes32(uint256(2));
    }

    function _requestAndAdvance(ITurnstile.WithdrawalAction memory a) internal {
        vm.prank(owner);
        conductor.requestWithdrawal(a);
        _advanceEpoch();
    }

    function _execute(
        ITurnstile.WithdrawalAction memory a,
        bytes28 accountId,
        bool facilitated
    )
        internal
        returns (uint256)
    {
        vm.prank(turnstile);
        (bool ok, bytes memory result) = address(conductor)
            .call(
                abi.encodePacked(
                    abi.encodeCall(IHubWarehouseConductor.executeWithdrawal, (a)),
                    accountId,
                    facilitated ? FACILITATED_FLAG : bytes4(0)
                )
            );
        if (!ok) {
            assembly { revert(add(result, 32), mload(result)) }
        }
        return abi.decode(result, (uint256));
    }

    function test_constructor_SetsAuthority() public view {
        assertEq(conductor.authority(), address(authority), "authority not set");
    }

    function test_constructor_SetsDepot() public view {
        assertEq(conductor.DEPOT(), address(depot), "DEPOT not set");
    }

    function test_constructor_SetsTurnstile() public view {
        assertEq(conductor.TURNSTILE(), turnstile, "TURNSTILE not set");
    }

    function test_requestWithdrawal_ReservesAmountOfAssetFromOwnerAccount() public {
        ITurnstile.WithdrawalAction memory a = _withdrawalAction();
        vm.prank(owner);
        conductor.requestWithdrawal(a);
        (, uint256 pending,) = depot.reservation(OWNER_ACCOUNT, ASSET_ID);
        assertEq(pending, 100, "amount not reserved");
    }

    function test_requestWithdrawal_SetsRequestEffectiveAtEpochToNextSettlementEpoch() public {
        ITurnstile.WithdrawalAction memory a = _withdrawalAction();
        vm.prank(owner);
        conductor.requestWithdrawal(a);
        bytes32 requestId = conductor.hashWithdrawalAction(a);
        assertEq(
            conductor.requestEffectiveAtEpoch(OWNER_ACCOUNT, requestId),
            depot.settlementEpoch() + 1,
            "effective epoch not settlementEpoch + 1"
        );
    }

    function test_requestWithdrawal_EmitsRequestedEvent() public {
        ITurnstile.WithdrawalAction memory a = _withdrawalAction();
        bytes32 requestId = conductor.hashWithdrawalAction(a);
        vm.expectEmit(address(conductor));
        emit IRequestConductor.Requested(OWNER_ACCOUNT, requestId, depot.settlementEpoch() + 1);
        vm.prank(owner);
        conductor.requestWithdrawal(a);
    }

    function test_requestWithdrawal_RevertIf_SenderIsNotActionOwner() public {
        ITurnstile.WithdrawalAction memory a = _withdrawalAction();
        vm.expectRevert(IRequestConductor.NotOwner.selector);
        vm.prank(stranger);
        conductor.requestWithdrawal(a);
    }

    function test_requestWithdrawal_RevertIf_RequestWasAlreadyMade() public {
        ITurnstile.WithdrawalAction memory a = _withdrawalAction();
        vm.prank(owner);
        conductor.requestWithdrawal(a);
        vm.expectRevert(IRequestConductor.RequestReplay.selector);
        vm.prank(owner);
        conductor.requestWithdrawal(a);
    }

    function test_receiveDeposit_MintsSourceChainAssetToRecipient() public {
        bytes28 toAccountId = TransitAddressLib.formatTransitAddress(uint64(block.chainid), recipient);
        vm.prank(turnstile);
        conductor.receiveDeposit(REMOTE_CHAIN, asset, 100, OWNER_ACCOUNT, toAccountId, 0, bytes28(0));
        assertEq(depot.balanceOf(toAccountId, REMOTE_ASSET_ID), 100, "recipient not minted source chain asset");
    }

    function test_receiveDeposit_MintsToDepositingAccountIfDepositingAccountIsFrozen() public {
        bytes28 fromAccountId = TransitAddressLib.formatTransitAddress(REMOTE_CHAIN, owner);
        bytes28 toAccountId = TransitAddressLib.formatTransitAddress(uint64(block.chainid), recipient);
        _freeze(owner);
        vm.prank(turnstile);
        conductor.receiveDeposit(REMOTE_CHAIN, asset, 100, fromAccountId, toAccountId, 0, bytes28(0));
        assertEq(depot.balanceOf(fromAccountId, REMOTE_ASSET_ID), 100, "depositing account not minted");
        assertEq(depot.balanceOf(toAccountId, REMOTE_ASSET_ID), 0, "recipient minted");
    }

    function test_receiveDeposit_TransfersFacilitationFeeToFeeReceiverAccount() public {
        bytes28 toAccountId = TransitAddressLib.formatTransitAddress(uint64(block.chainid), recipient);
        bytes28 feeAccountId = TransitAddressLib.formatTransitAddress(uint64(block.chainid), feeReceiver);
        vm.prank(turnstile);
        conductor.receiveDeposit(REMOTE_CHAIN, asset, 100, OWNER_ACCOUNT, toAccountId, 10, feeAccountId);
        assertEq(depot.balanceOf(toAccountId, REMOTE_ASSET_ID), 90, "recipient not minted amount less fee");
        assertEq(depot.balanceOf(feeAccountId, REMOTE_ASSET_ID), 10, "fee receiver not paid");
    }

    function test_receiveDeposit_SkipsFacilitationFeeIfDepositingAccountIsFrozen() public {
        bytes28 fromAccountId = TransitAddressLib.formatTransitAddress(REMOTE_CHAIN, owner);
        bytes28 toAccountId = TransitAddressLib.formatTransitAddress(uint64(block.chainid), recipient);
        bytes28 feeAccountId = TransitAddressLib.formatTransitAddress(uint64(block.chainid), feeReceiver);
        _freeze(owner);
        vm.prank(turnstile);
        conductor.receiveDeposit(REMOTE_CHAIN, asset, 100, fromAccountId, toAccountId, 10, feeAccountId);
        assertEq(depot.balanceOf(fromAccountId, REMOTE_ASSET_ID), 100, "depositing account not minted in full");
        assertEq(depot.balanceOf(feeAccountId, REMOTE_ASSET_ID), 0, "fee taken from frozen deposit");
    }

    function test_receiveDeposit_RevertIf_SenderIsUnauthorized() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vm.prank(stranger);
        conductor.receiveDeposit(REMOTE_CHAIN, asset, 100, OWNER_ACCOUNT, OWNER_ACCOUNT, 0, bytes28(0));
    }

    function test_executeWithdrawal_BurnsAmountFromOwnerAccount() public {
        ITurnstile.WithdrawalAction memory a = _withdrawalAction();
        _seed(OWNER_ACCOUNT, ASSET_ID, 100);
        _requestAndAdvance(a);
        _execute(a, OWNER_ACCOUNT, false);
        assertEq(depot.balanceOf(OWNER_ACCOUNT, ASSET_ID), 0, "amount not burned");
    }

    function test_executeWithdrawal_ReturnsAmountBurned() public {
        ITurnstile.WithdrawalAction memory a = _withdrawalAction();
        _seed(OWNER_ACCOUNT, ASSET_ID, 100);
        _requestAndAdvance(a);
        assertEq(_execute(a, OWNER_ACCOUNT, false), 100, "amount returned wrong");
    }

    function test_executeWithdrawal_ReleasesReservationOfConsumedRequest() public {
        ITurnstile.WithdrawalAction memory a = _withdrawalAction();
        _seed(OWNER_ACCOUNT, ASSET_ID, 100);
        _requestAndAdvance(a);
        _execute(a, OWNER_ACCOUNT, false);
        (uint256 effective, uint256 pending,) = depot.reservation(OWNER_ACCOUNT, ASSET_ID);
        assertEq(effective, 0, "effective reservation not released");
        assertEq(pending, 0, "pending reservation not released");
    }

    function test_executeWithdrawal_ReleasesEntireReservationOnPartialFill() public {
        ITurnstile.WithdrawalAction memory a = _withdrawalAction();
        _seed(OWNER_ACCOUNT, ASSET_ID, 60);
        _requestAndAdvance(a);
        _execute(a, OWNER_ACCOUNT, false);
        (uint256 effective, uint256 pending,) = depot.reservation(OWNER_ACCOUNT, ASSET_ID);
        assertEq(effective, 0, "effective reservation not fully released");
        assertEq(pending, 0, "pending reservation not fully released");
    }

    function test_executeWithdrawal_ReleasesEntireReservationOnZeroFill() public {
        ITurnstile.WithdrawalAction memory a = _withdrawalAction();
        a.partiallyFillable = false;
        _seed(OWNER_ACCOUNT, ASSET_ID, 60);
        _requestAndAdvance(a);
        _execute(a, OWNER_ACCOUNT, false);
        (uint256 effective, uint256 pending,) = depot.reservation(OWNER_ACCOUNT, ASSET_ID);
        assertEq(effective, 0, "effective reservation not fully released");
        assertEq(pending, 0, "pending reservation not fully released");
    }

    function test_executeWithdrawal_ReleasesEntireReservationIfDeadlineHasPassed() public {
        ITurnstile.WithdrawalAction memory a = _withdrawalAction();
        _seed(OWNER_ACCOUNT, ASSET_ID, 100);
        _requestAndAdvance(a);
        vm.warp(a.deadline + 1);
        _execute(a, OWNER_ACCOUNT, false);
        (uint256 effective, uint256 pending,) = depot.reservation(OWNER_ACCOUNT, ASSET_ID);
        assertEq(effective, 0, "effective reservation not fully released");
        assertEq(pending, 0, "pending reservation not fully released");
    }

    function test_executeWithdrawal_SetsRequestEffectiveAtEpochToExecuted() public {
        ITurnstile.WithdrawalAction memory a = _withdrawalAction();
        _seed(OWNER_ACCOUNT, ASSET_ID, 100);
        _requestAndAdvance(a);
        _execute(a, OWNER_ACCOUNT, false);
        bytes32 requestId = conductor.hashWithdrawalAction(a);
        assertEq(conductor.requestEffectiveAtEpoch(OWNER_ACCOUNT, requestId), conductor.EXECUTED(), "not EXECUTED");
    }

    function test_executeWithdrawal_AllowsFacilitatedOwnerToExecuteWithoutPriorRequest() public {
        ITurnstile.WithdrawalAction memory a = _withdrawalAction();
        _seed(OWNER_ACCOUNT, ASSET_ID, 100);
        assertEq(_execute(a, OWNER_ACCOUNT, true), 100, "facilitated amount wrong");
        assertEq(depot.balanceOf(OWNER_ACCOUNT, ASSET_ID), 0, "amount not burned");
    }

    function test_executeWithdrawal_BurnsPartialAmountIfPartiallyFillableAndFreeBalanceIsInsufficient() public {
        ITurnstile.WithdrawalAction memory a = _withdrawalAction();
        _seed(OWNER_ACCOUNT, ASSET_ID, 60);
        _requestAndAdvance(a);
        assertEq(_execute(a, OWNER_ACCOUNT, false), 60, "partial amount not burned");
        assertEq(depot.balanceOf(OWNER_ACCOUNT, ASSET_ID), 0, "balance not zero");
    }

    function test_executeWithdrawal_BurnsZeroIfNotPartiallyFillableAndFreeBalanceIsInsufficient() public {
        ITurnstile.WithdrawalAction memory a = _withdrawalAction();
        a.partiallyFillable = false;
        _seed(OWNER_ACCOUNT, ASSET_ID, 60);
        _requestAndAdvance(a);
        assertEq(_execute(a, OWNER_ACCOUNT, false), 0, "amount burned");
        assertEq(depot.balanceOf(OWNER_ACCOUNT, ASSET_ID), 60, "balance moved");
    }

    function test_executeWithdrawal_ConsumesRequestWithoutBurningIfDeadlineHasPassed() public {
        ITurnstile.WithdrawalAction memory a = _withdrawalAction();
        _seed(OWNER_ACCOUNT, ASSET_ID, 100);
        _requestAndAdvance(a);
        vm.warp(a.deadline + 1);
        _execute(a, OWNER_ACCOUNT, false);
        bytes32 requestId = conductor.hashWithdrawalAction(a);
        assertEq(conductor.requestEffectiveAtEpoch(OWNER_ACCOUNT, requestId), conductor.EXECUTED(), "not consumed");
        assertEq(depot.balanceOf(OWNER_ACCOUNT, ASSET_ID), 100, "amount burned");
    }

    function test_executeWithdrawal_ReturnsZeroIfDeadlineHasPassed() public {
        ITurnstile.WithdrawalAction memory a = _withdrawalAction();
        _seed(OWNER_ACCOUNT, ASSET_ID, 100);
        _requestAndAdvance(a);
        vm.warp(a.deadline + 1);
        assertEq(_execute(a, OWNER_ACCOUNT, false), 0, "amount returned nonzero");
    }

    function test_executeWithdrawal_EmitsConsumedEvent() public {
        ITurnstile.WithdrawalAction memory a = _withdrawalAction();
        _seed(OWNER_ACCOUNT, ASSET_ID, 100);
        _requestAndAdvance(a);
        bytes32 requestId = conductor.hashWithdrawalAction(a);
        vm.expectEmit(address(conductor));
        emit IRequestConductor.Consumed(OWNER_ACCOUNT, requestId);
        _execute(a, OWNER_ACCOUNT, false);
    }

    function test_executeWithdrawal_EmitsWithdrawalExecutedEvent() public {
        ITurnstile.WithdrawalAction memory a = _withdrawalAction();
        _seed(OWNER_ACCOUNT, ASSET_ID, 100);
        _requestAndAdvance(a);
        bytes32 requestId = conductor.hashWithdrawalAction(a);
        vm.expectEmit(address(conductor));
        emit IHubWarehouseConductor.WithdrawalExecuted(requestId, 100);
        _execute(a, OWNER_ACCOUNT, false);
    }

    function test_executeWithdrawal_EmitsRequestExpiredEventIfDeadlineHasPassed() public {
        ITurnstile.WithdrawalAction memory a = _withdrawalAction();
        _seed(OWNER_ACCOUNT, ASSET_ID, 100);
        _requestAndAdvance(a);
        bytes32 requestId = conductor.hashWithdrawalAction(a);
        vm.warp(a.deadline + 1);
        vm.expectEmit(address(conductor));
        emit IRequestConductor.RequestExpired(requestId);
        _execute(a, OWNER_ACCOUNT, false);
    }

    function test_executeWithdrawal_RevertIf_SenderIsUnauthorized() public {
        ITurnstile.WithdrawalAction memory a = _withdrawalAction();
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vm.prank(stranger);
        conductor.executeWithdrawal(a);
    }

    function test_executeWithdrawal_RevertIf_RequestWasNeverMade() public {
        ITurnstile.WithdrawalAction memory a = _withdrawalAction();
        vm.expectRevert(IRequestConductor.NotEffective.selector);
        _execute(a, OWNER_ACCOUNT, false);
    }

    function test_executeWithdrawal_RevertIf_RequestEpochHasNotArrived() public {
        ITurnstile.WithdrawalAction memory a = _withdrawalAction();
        vm.prank(owner);
        conductor.requestWithdrawal(a);
        vm.expectRevert(IRequestConductor.NotEffective.selector);
        _execute(a, OWNER_ACCOUNT, false);
    }

    function test_executeWithdrawal_RevertIf_RequestWasAlreadyExecuted() public {
        ITurnstile.WithdrawalAction memory a = _withdrawalAction();
        _seed(OWNER_ACCOUNT, ASSET_ID, 100);
        _requestAndAdvance(a);
        _execute(a, OWNER_ACCOUNT, false);
        vm.expectRevert(IRequestConductor.RequestReplay.selector);
        _execute(a, OWNER_ACCOUNT, false);
    }

    function test_hashWithdrawalAction_ReturnsHashOfTypehashAndAction() public view {
        ITurnstile.WithdrawalAction memory a = _withdrawalAction();
        bytes32 expected = keccak256(
            abi.encode(
                Typehashes.WITHDRAWAL_ACTION,
                a.ownerChainId,
                a.owner,
                a.to,
                a.assetChainId,
                a.asset,
                a.amount,
                a.deadline,
                a.partiallyFillable,
                a.dependsOn,
                a.salt
            )
        );
        assertEq(conductor.hashWithdrawalAction(a), expected, "hash wrong");
    }

}
