// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { Test, stdError } from "forge-std/Test.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { Depot } from "src/depot/Depot.sol";
import { IDepot } from "src/interfaces/IDepot.sol";
import { AddressFreezeList } from "src/AddressFreezeList.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { Roles } from "src/helpers/Roles.sol";
import { TransitAddressLib } from "src/helpers/TransitAddressLib.sol";

contract DepotUnitTest is Test {

    address admin = makeAddr("admin");
    address pauser = makeAddr("pauser");
    address conductor = makeAddr("conductor");
    address epochKeeper = makeAddr("epochKeeper");
    address stranger = makeAddr("stranger");

    bytes28 ALICE = TransitAddressLib.formatTransitAddress(1, makeAddr("alice"));
    bytes28 BOB = TransitAddressLib.formatTransitAddress(1, makeAddr("bob"));
    bytes28 CAROL = TransitAddressLib.formatTransitAddress(1, makeAddr("carol"));
    bytes28 ASSET = TransitAddressLib.formatTransitAddress(1, makeAddr("asset"));
    bytes28 ASSET2 = TransitAddressLib.formatTransitAddress(1, makeAddr("asset2"));
    bytes28 INVALID_ZERO_CHAIN = TransitAddressLib.formatTransitAddress(0, makeAddr("invalid"));
    bytes28 INVALID_ZERO_ADDRESS = TransitAddressLib.formatTransitAddress(1, address(0));

    AccessManager authority;
    AddressFreezeList freezeList;
    Depot depot;

    function setUp() public {
        authority = new AccessManager(admin);
        freezeList = new AddressFreezeList(address(authority));
        depot = new Depot(address(authority), freezeList);

        bytes4[] memory pauserSelectors = new bytes4[](2);
        pauserSelectors[0] = Depot.pause.selector;
        pauserSelectors[1] = Depot.unpause.selector;

        bytes4[] memory adminSelectors = new bytes4[](1);
        adminSelectors[0] = Depot.setAddressFreezeList.selector;

        bytes4[] memory conductorSelectors = new bytes4[](7);
        conductorSelectors[0] = Depot.transferFrom.selector;
        conductorSelectors[1] = Depot.transferAmong.selector;
        conductorSelectors[2] = Depot.mint.selector;
        conductorSelectors[3] = Depot.burn.selector;
        conductorSelectors[4] = Depot.forceTransferFrom.selector;
        conductorSelectors[5] = Depot.reserve.selector;
        conductorSelectors[6] = Depot.release.selector;

        bytes4[] memory epochSelectors = new bytes4[](1);
        epochSelectors[0] = Depot.advanceEpoch.selector;

        bytes4[] memory freezeSelectors = new bytes4[](1);
        freezeSelectors[0] = AddressFreezeList.freeze.selector;

        vm.startPrank(admin);
        authority.setTargetFunctionRole(address(depot), pauserSelectors, Roles.PAUSER);
        authority.setTargetFunctionRole(address(depot), adminSelectors, Roles.ADMIN);
        authority.setTargetFunctionRole(address(depot), conductorSelectors, Roles.CONDUCTOR);
        authority.setTargetFunctionRole(address(depot), epochSelectors, Roles.EPOCH);
        authority.setTargetFunctionRole(address(freezeList), freezeSelectors, Roles.FREEZE_MANAGER);
        authority.grantRole(Roles.PAUSER, pauser, 0);
        authority.grantRole(Roles.CONDUCTOR, conductor, 0);
        authority.grantRole(Roles.EPOCH, epochKeeper, 0);
        authority.grantRole(Roles.FREEZE_MANAGER, admin, 0);
        vm.stopPrank();
    }

    function _mint(bytes28 accountId, bytes28 assetId, uint256 amount) internal {
        vm.prank(conductor);
        depot.mint(accountId, assetId, amount);
    }

    function _reserve(bytes28 accountId, bytes28 assetId, uint256 amount) internal {
        vm.prank(conductor);
        depot.reserve(accountId, assetId, amount);
    }

    function _roll(bytes28 accountId, bytes28 assetId) internal {
        vm.prank(conductor);
        depot.release(accountId, assetId, 0);
    }

    function _advanceEpoch() internal {
        vm.prank(epochKeeper);
        depot.advanceEpoch();
    }

    function _freeze(bytes28 accountId) internal {
        (, address account) = TransitAddressLib.parseTransitAddress(accountId);
        vm.prank(admin);
        freezeList.freeze(account);
    }

    function _pause() internal {
        vm.prank(pauser);
        depot.pause();
    }

    function _delta(
        bytes28 fromAccountId,
        bytes28 toAccountId,
        bytes28 assetId,
        uint256 amount
    )
        internal
        pure
        returns (IDepot.TransferDelta memory)
    {
        return IDepot.TransferDelta(fromAccountId, toAccountId, assetId, amount);
    }

    function _deltas(IDepot.TransferDelta memory a) internal pure returns (IDepot.TransferDelta[] memory deltas) {
        deltas = new IDepot.TransferDelta[](1);
        deltas[0] = a;
    }

    function _deltas(
        IDepot.TransferDelta memory a,
        IDepot.TransferDelta memory b
    )
        internal
        pure
        returns (IDepot.TransferDelta[] memory deltas)
    {
        deltas = new IDepot.TransferDelta[](2);
        deltas[0] = a;
        deltas[1] = b;
    }

    function test_constructor_SetsAuthority() public view {
        assertEq(depot.authority(), address(authority), "authority not set");
    }

    function test_constructor_SetsEpochToOne() public view {
        assertEq(depot.settlementEpoch(), 1, "settlementEpoch not 1");
    }

    function test_constructor_SetsLastEpochAdvancedAt() public {
        vm.warp(1000);
        Depot fresh = new Depot(address(authority), freezeList);
        assertEq(fresh.lastEpochAdvancedAt(), 1000, "lastEpochAdvancedAt not current timestamp");
    }

    function test_constructor_SetsFreezeList() public view {
        assertEq(address(depot.addressFreezeList()), address(freezeList), "addressFreezeList not set");
    }

    function test_constructor_EmitsEpochAdvancedEvent() public {
        vm.expectEmit();
        emit IDepot.EpochAdvanced(1);
        new Depot(address(authority), freezeList);
    }

    function test_constructor_EmitsAddressFreezeListSetEvent() public {
        vm.expectEmit();
        emit IDepot.AddressFreezeListSet(freezeList);
        new Depot(address(authority), freezeList);
    }

    function test_constructor_RevertIf_FreezeListHasNoCode() public {
        vm.expectRevert(IDepot.NoCode.selector);
        new Depot(address(authority), AddressFreezeList(makeAddr("noCode")));
    }

    function test_balanceOf_ReturnsBalance() public {
        _mint(ALICE, ASSET, 100);
        assertEq(depot.balanceOf(ALICE, ASSET), 100, "balance not returned");
    }

    function test_balanceOf_IncludesReserved() public {
        _mint(ALICE, ASSET, 100);
        _reserve(ALICE, ASSET, 40);
        _advanceEpoch();
        _roll(ALICE, ASSET);
        assertEq(depot.balanceOf(ALICE, ASSET), 100, "balance excludes reserved amount");
    }

    function test_reservation_ReturnsStoredReservation() public {
        _reserve(ALICE, ASSET, 10);
        _advanceEpoch();
        _reserve(ALICE, ASSET, 5);
        (uint256 effective, uint256 pending, uint256 pendingEpoch) = depot.reservation(ALICE, ASSET);
        assertEq(effective, 10, "effective wrong");
        assertEq(pending, 5, "pending wrong");
        assertEq(pendingEpoch, 3, "pendingEpoch wrong");
    }

    function test_reservation_ReturnsStoredReservationWithoutRolling() public {
        _reserve(ALICE, ASSET, 10);
        _advanceEpoch();
        (uint256 effective, uint256 pending, uint256 pendingEpoch) = depot.reservation(ALICE, ASSET);
        assertEq(effective, 0, "effective rolled");
        assertEq(pending, 10, "pending rolled");
        assertEq(pendingEpoch, 2, "pendingEpoch changed");
    }

    function test_freeBalanceOf_ReturnsBalanceLessEffectiveReservation() public {
        _mint(ALICE, ASSET, 100);
        _reserve(ALICE, ASSET, 30);
        _advanceEpoch();
        _roll(ALICE, ASSET);
        assertEq(depot.freeBalanceOf(ALICE, ASSET), 70, "effective reservation not subtracted");
    }

    function test_freeBalanceOf_ReturnsFullBalanceBeforePendingEpoch() public {
        _mint(ALICE, ASSET, 100);
        _reserve(ALICE, ASSET, 30);
        assertEq(depot.freeBalanceOf(ALICE, ASSET), 100, "pending reservation subtracted early");
    }

    function test_freeBalanceOf_ReturnsBalanceLessReservationAfterEpochAdvance() public {
        _mint(ALICE, ASSET, 100);
        _reserve(ALICE, ASSET, 30);
        _advanceEpoch();
        assertEq(depot.freeBalanceOf(ALICE, ASSET), 70, "arrived pending reservation not subtracted");
    }

    function test_freeBalanceOf_ReturnsZeroIfReservationExceedsBalance() public {
        _mint(ALICE, ASSET, 100);
        _reserve(ALICE, ASSET, 150);
        _advanceEpoch();
        assertEq(depot.freeBalanceOf(ALICE, ASSET), 0, "free balance not floored at zero");
    }

    function test_settlementEpoch_ReturnsCurrentEpoch() public {
        _advanceEpoch();
        _advanceEpoch();
        assertEq(depot.settlementEpoch(), 3, "settlementEpoch wrong");
    }

    function test_lastEpochAdvancedAt_ReturnsLastAdvanceTimestamp() public {
        vm.warp(block.timestamp + 1 hours);
        _advanceEpoch();
        assertEq(depot.lastEpochAdvancedAt(), block.timestamp, "lastEpochAdvancedAt wrong");
    }

    function test_addressFreezeList_ReturnsFreezeList() public view {
        assertEq(address(depot.addressFreezeList()), address(freezeList), "addressFreezeList wrong");
    }

    function test_pause_Pauses() public {
        _pause();
        assertTrue(depot.paused(), "not paused");
    }

    function test_pause_EmitsPausedEvent() public {
        vm.expectEmit(address(depot));
        emit Pausable.Paused(pauser);
        _pause();
    }

    function test_pause_RevertIf_SenderIsUnauthorized() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vm.prank(stranger);
        depot.pause();
    }

    function test_pause_RevertIf_ContractIsAlreadyPaused() public {
        _pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        _pause();
    }

    function test_unpause_Unpauses() public {
        _pause();
        vm.prank(pauser);
        depot.unpause();
        assertFalse(depot.paused(), "still paused");
    }

    function test_unpause_EmitsUnpausedEvent() public {
        _pause();
        vm.expectEmit(address(depot));
        emit Pausable.Unpaused(pauser);
        vm.prank(pauser);
        depot.unpause();
    }

    function test_unpause_RevertIf_SenderIsUnauthorized() public {
        _pause();
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vm.prank(stranger);
        depot.unpause();
    }

    function test_unpause_RevertIf_ContractIsNotPaused() public {
        vm.expectRevert(Pausable.ExpectedPause.selector);
        vm.prank(pauser);
        depot.unpause();
    }

    function test_setAddressFreezeList_SetsFreezeList() public {
        AddressFreezeList newList = new AddressFreezeList(address(authority));
        vm.prank(admin);
        depot.setAddressFreezeList(newList);
        assertEq(address(depot.addressFreezeList()), address(newList), "addressFreezeList not set");
    }

    function test_setAddressFreezeList_EmitsAddressFreezeListSetEvent() public {
        AddressFreezeList newList = new AddressFreezeList(address(authority));
        vm.expectEmit(address(depot));
        emit IDepot.AddressFreezeListSet(newList);
        vm.prank(admin);
        depot.setAddressFreezeList(newList);
    }

    function test_setAddressFreezeList_RevertIf_SenderIsUnauthorized() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vm.prank(stranger);
        depot.setAddressFreezeList(freezeList);
    }

    function test_setAddressFreezeList_RevertIf_AddressHasNoCode() public {
        vm.expectRevert(IDepot.NoCode.selector);
        vm.prank(admin);
        depot.setAddressFreezeList(AddressFreezeList(makeAddr("noCode")));
    }

    function test_transferFrom_MovesBalance() public {
        _mint(ALICE, ASSET, 100);
        vm.prank(conductor);
        depot.transferFrom(ALICE, BOB, ASSET, 40);
        assertEq(depot.balanceOf(ALICE, ASSET), 60, "sender balance wrong");
        assertEq(depot.balanceOf(BOB, ASSET), 40, "recipient balance wrong");
    }

    function test_transferFrom_AllowsEntireFreeBalance() public {
        _mint(ALICE, ASSET, 100);
        _reserve(ALICE, ASSET, 30);
        _advanceEpoch();
        vm.prank(conductor);
        depot.transferFrom(ALICE, BOB, ASSET, 70);
        assertEq(depot.balanceOf(BOB, ASSET), 70, "recipient balance wrong");
        assertEq(depot.freeBalanceOf(ALICE, ASSET), 0, "sender free balance not zero");
    }

    function test_transferFrom_AllowsReservedBalanceBeforeEpochAdvance() public {
        _mint(ALICE, ASSET, 100);
        _reserve(ALICE, ASSET, 100);
        vm.prank(conductor);
        depot.transferFrom(ALICE, BOB, ASSET, 100);
        assertEq(depot.balanceOf(BOB, ASSET), 100, "recipient balance wrong");
    }

    function test_transferFrom_AllowsFrozenRecipient() public {
        _mint(ALICE, ASSET, 100);
        _freeze(BOB);
        vm.prank(conductor);
        depot.transferFrom(ALICE, BOB, ASSET, 100);
        assertEq(depot.balanceOf(BOB, ASSET), 100, "frozen recipient balance wrong");
    }

    function test_transferFrom_EmitsTransferEvent() public {
        _mint(ALICE, ASSET, 100);
        vm.expectEmit(address(depot));
        emit IDepot.Transfer(conductor, ALICE, BOB, ASSET, 40);
        vm.prank(conductor);
        depot.transferFrom(ALICE, BOB, ASSET, 40);
    }

    function test_transferFrom_RevertIf_SenderIsUnauthorized() public {
        _mint(ALICE, ASSET, 100);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vm.prank(stranger);
        depot.transferFrom(ALICE, BOB, ASSET, 40);
    }

    function test_transferFrom_RevertIf_ContractIsPaused() public {
        _mint(ALICE, ASSET, 100);
        _pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(conductor);
        depot.transferFrom(ALICE, BOB, ASSET, 40);
    }

    function test_transferFrom_RevertIf_FromIsInvalid() public {
        vm.expectRevert(IDepot.InvalidAccount.selector);
        vm.prank(conductor);
        depot.transferFrom(INVALID_ZERO_CHAIN, BOB, ASSET, 0);
        vm.expectRevert(IDepot.InvalidAccount.selector);
        vm.prank(conductor);
        depot.transferFrom(INVALID_ZERO_ADDRESS, BOB, ASSET, 0);
    }

    function test_transferFrom_RevertIf_ToIsInvalid() public {
        _mint(ALICE, ASSET, 100);
        vm.expectRevert(IDepot.InvalidAccount.selector);
        vm.prank(conductor);
        depot.transferFrom(ALICE, INVALID_ZERO_CHAIN, ASSET, 40);
        vm.expectRevert(IDepot.InvalidAccount.selector);
        vm.prank(conductor);
        depot.transferFrom(ALICE, INVALID_ZERO_ADDRESS, ASSET, 40);
    }

    function test_transferFrom_RevertIf_FromIsFrozen() public {
        _mint(ALICE, ASSET, 100);
        _freeze(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IDepot.AccountFrozen.selector, ALICE));
        vm.prank(conductor);
        depot.transferFrom(ALICE, BOB, ASSET, 40);
    }

    function test_transferFrom_RevertIf_AmountExceedsBalance() public {
        _mint(ALICE, ASSET, 100);
        vm.expectRevert(IDepot.InsufficientBalance.selector);
        vm.prank(conductor);
        depot.transferFrom(ALICE, BOB, ASSET, 101);
    }

    function test_transferFrom_RevertIf_EffectiveReservationBlocks() public {
        _mint(ALICE, ASSET, 100);
        _reserve(ALICE, ASSET, 30);
        _advanceEpoch();
        _roll(ALICE, ASSET);
        vm.expectRevert(IDepot.InsufficientBalance.selector);
        vm.prank(conductor);
        depot.transferFrom(ALICE, BOB, ASSET, 71);
    }

    function test_transferFrom_RevertIf_ReservationBlocksAfterEpochAdvance() public {
        _mint(ALICE, ASSET, 100);
        _reserve(ALICE, ASSET, 30);
        _advanceEpoch();
        vm.expectRevert(IDepot.InsufficientBalance.selector);
        vm.prank(conductor);
        depot.transferFrom(ALICE, BOB, ASSET, 71);
    }

    function test_transferAmong_TransfersAssetsBetweenAccounts() public {
        _mint(ALICE, ASSET, 100);
        vm.prank(conductor);
        depot.transferAmong(_deltas(_delta(ALICE, BOB, ASSET, 40), _delta(BOB, CAROL, ASSET, 15)));
        assertEq(depot.balanceOf(ALICE, ASSET), 60, "ALICE balance wrong");
        assertEq(depot.balanceOf(BOB, ASSET), 25, "BOB balance wrong");
        assertEq(depot.balanceOf(CAROL, ASSET), 15, "CAROL balance wrong");
    }

    function test_transferAmong_TransfersAssetsAmongAccounts() public {
        _mint(BOB, ASSET, 100);
        vm.prank(conductor);
        depot.transferAmong(_deltas(_delta(bytes28(0), ALICE, ASSET, 40), _delta(BOB, bytes28(0), ASSET, 40)));
        assertEq(depot.balanceOf(ALICE, ASSET), 40, "mint not applied");
        assertEq(depot.balanceOf(BOB, ASSET), 60, "burn not applied");
    }

    function test_transferAmong_AcceptsEmptyDeltas() public {
        vm.prank(conductor);
        depot.transferAmong(new IDepot.TransferDelta[](0));
    }

    function test_transferAmong_TransfersMultipleAssets() public {
        _mint(ALICE, ASSET, 100);
        _mint(BOB, ASSET2, 50);
        vm.prank(conductor);
        depot.transferAmong(_deltas(_delta(ALICE, BOB, ASSET, 40), _delta(BOB, ALICE, ASSET2, 20)));
        assertEq(depot.balanceOf(ALICE, ASSET), 60, "ALICE ASSET balance wrong");
        assertEq(depot.balanceOf(BOB, ASSET), 40, "BOB ASSET balance wrong");
        assertEq(depot.balanceOf(ALICE, ASSET2), 20, "ALICE ASSET2 balance wrong");
        assertEq(depot.balanceOf(BOB, ASSET2), 30, "BOB ASSET2 balance wrong");
    }

    function test_transferAmong_AllowsSpendingCreditFromEarlierDelta() public {
        _mint(ALICE, ASSET, 40);
        vm.prank(conductor);
        depot.transferAmong(_deltas(_delta(ALICE, BOB, ASSET, 40), _delta(BOB, CAROL, ASSET, 40)));
        assertEq(depot.balanceOf(BOB, ASSET), 0, "BOB balance wrong");
        assertEq(depot.balanceOf(CAROL, ASSET), 40, "CAROL balance wrong");
    }

    function test_transferAmong_AllowsFrozenRecipient() public {
        _mint(ALICE, ASSET, 100);
        _freeze(BOB);
        vm.prank(conductor);
        depot.transferAmong(_deltas(_delta(ALICE, BOB, ASSET, 40)));
        assertEq(depot.balanceOf(BOB, ASSET), 40, "frozen recipient balance wrong");
    }

    function test_transferAmong_EmitsTransferEventPerDelta() public {
        _mint(ALICE, ASSET, 100);
        vm.expectEmit(address(depot));
        emit IDepot.Transfer(conductor, ALICE, BOB, ASSET, 40);
        vm.expectEmit(address(depot));
        emit IDepot.Transfer(conductor, BOB, CAROL, ASSET, 15);
        vm.prank(conductor);
        depot.transferAmong(_deltas(_delta(ALICE, BOB, ASSET, 40), _delta(BOB, CAROL, ASSET, 15)));
    }

    function test_transferAmong_RevertIf_SenderIsUnauthorized() public {
        _mint(ALICE, ASSET, 100);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vm.prank(stranger);
        depot.transferAmong(_deltas(_delta(ALICE, BOB, ASSET, 40)));
    }

    function test_transferAmong_RevertIf_ContractIsPaused() public {
        _mint(ALICE, ASSET, 100);
        _pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(conductor);
        depot.transferAmong(_deltas(_delta(ALICE, BOB, ASSET, 40)));
    }

    function test_transferAmong_RevertIf_DeltaIsEmpty() public {
        vm.expectRevert(IDepot.EmptyDelta.selector);
        vm.prank(conductor);
        depot.transferAmong(_deltas(_delta(bytes28(0), bytes28(0), ASSET, 40)));
    }

    function test_transferAmong_RevertIf_AmountIsZero() public {
        _mint(ALICE, ASSET, 100);
        vm.expectRevert(IDepot.ZeroAmount.selector);
        vm.prank(conductor);
        depot.transferAmong(_deltas(_delta(ALICE, BOB, ASSET, 0)));
    }

    function test_transferAmong_RevertIf_AssetIsInvalid() public {
        vm.expectRevert(IDepot.InvalidAsset.selector);
        vm.prank(conductor);
        depot.transferAmong(_deltas(_delta(ALICE, BOB, INVALID_ZERO_CHAIN, 40)));
        vm.expectRevert(IDepot.InvalidAsset.selector);
        vm.prank(conductor);
        depot.transferAmong(_deltas(_delta(ALICE, BOB, INVALID_ZERO_ADDRESS, 40)));
    }

    function test_transferAmong_RevertIf_FromIsInvalid() public {
        vm.expectRevert(IDepot.InvalidAccount.selector);
        vm.prank(conductor);
        depot.transferAmong(_deltas(_delta(INVALID_ZERO_CHAIN, BOB, ASSET, 40)));
        vm.expectRevert(IDepot.InvalidAccount.selector);
        vm.prank(conductor);
        depot.transferAmong(_deltas(_delta(INVALID_ZERO_ADDRESS, BOB, ASSET, 40)));
    }

    function test_transferAmong_RevertIf_ToIsInvalid() public {
        _mint(ALICE, ASSET, 100);
        vm.expectRevert(IDepot.InvalidAccount.selector);
        vm.prank(conductor);
        depot.transferAmong(_deltas(_delta(ALICE, INVALID_ZERO_CHAIN, ASSET, 40)));
        vm.expectRevert(IDepot.InvalidAccount.selector);
        vm.prank(conductor);
        depot.transferAmong(_deltas(_delta(ALICE, INVALID_ZERO_ADDRESS, ASSET, 40)));
    }

    function test_transferAmong_RevertIf_FromIsFrozen() public {
        _mint(ALICE, ASSET, 100);
        _freeze(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IDepot.AccountFrozen.selector, ALICE));
        vm.prank(conductor);
        depot.transferAmong(_deltas(_delta(ALICE, BOB, ASSET, 40)));
    }

    function test_transferAmong_RevertIf_AmountExceedsFreeBalance() public {
        _mint(ALICE, ASSET, 100);
        _reserve(ALICE, ASSET, 30);
        _advanceEpoch();
        vm.expectRevert(IDepot.InsufficientBalance.selector);
        vm.prank(conductor);
        depot.transferAmong(_deltas(_delta(ALICE, BOB, ASSET, 71)));
    }

    function test_transferAmong_RevertIf_SpendingCreditFromLaterDelta() public {
        _mint(ALICE, ASSET, 40);
        vm.expectRevert(IDepot.InsufficientBalance.selector);
        vm.prank(conductor);
        depot.transferAmong(_deltas(_delta(BOB, CAROL, ASSET, 40), _delta(ALICE, BOB, ASSET, 40)));
    }

    function test_transferAmong_RevertIf_AssetDoesNotNetToZero() public {
        _mint(BOB, ASSET2, 40);
        vm.expectRevert(IDepot.NotZeroSum.selector);
        vm.prank(conductor);
        depot.transferAmong(_deltas(_delta(bytes28(0), ALICE, ASSET, 40), _delta(BOB, bytes28(0), ASSET2, 40)));
    }

    function test_transferAmong_RevertIf_MintsExceedBurns() public {
        _mint(BOB, ASSET, 40);
        vm.expectRevert(IDepot.NotZeroSum.selector);
        vm.prank(conductor);
        depot.transferAmong(_deltas(_delta(bytes28(0), ALICE, ASSET, 40), _delta(BOB, bytes28(0), ASSET, 30)));
    }

    function test_transferAmong_RevertIf_BurnsExceedMints() public {
        _mint(BOB, ASSET, 40);
        vm.expectRevert(IDepot.NotZeroSum.selector);
        vm.prank(conductor);
        depot.transferAmong(_deltas(_delta(bytes28(0), ALICE, ASSET, 30), _delta(BOB, bytes28(0), ASSET, 40)));
    }

    function test_mint_IncreasesBalance() public {
        _mint(ALICE, ASSET, 100);
        assertEq(depot.balanceOf(ALICE, ASSET), 100, "balance not increased");
    }

    function test_mint_AllowsFrozenRecipient() public {
        _freeze(ALICE);
        _mint(ALICE, ASSET, 100);
        assertEq(depot.balanceOf(ALICE, ASSET), 100, "frozen recipient balance wrong");
    }

    function test_mint_EmitsTransferEventFromZero() public {
        vm.expectEmit(address(depot));
        emit IDepot.Transfer(conductor, bytes28(0), ALICE, ASSET, 100);
        _mint(ALICE, ASSET, 100);
    }

    function test_mint_RevertIf_SenderIsUnauthorized() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vm.prank(stranger);
        depot.mint(ALICE, ASSET, 100);
    }

    function test_mint_RevertIf_ContractIsPaused() public {
        _pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        _mint(ALICE, ASSET, 100);
    }

    function test_mint_RevertIf_AccountIsInvalid() public {
        vm.expectRevert(IDepot.InvalidAccount.selector);
        _mint(INVALID_ZERO_CHAIN, ASSET, 100);
        vm.expectRevert(IDepot.InvalidAccount.selector);
        _mint(INVALID_ZERO_ADDRESS, ASSET, 100);
    }

    function test_mint_RevertIf_AssetIsInvalid() public {
        vm.expectRevert(IDepot.InvalidAsset.selector);
        _mint(ALICE, INVALID_ZERO_CHAIN, 100);
        vm.expectRevert(IDepot.InvalidAsset.selector);
        _mint(ALICE, INVALID_ZERO_ADDRESS, 100);
    }

    function test_burn_DecreasesBalance() public {
        _mint(ALICE, ASSET, 100);
        vm.prank(conductor);
        depot.burn(ALICE, ASSET, 40);
        assertEq(depot.balanceOf(ALICE, ASSET), 60, "balance not decreased");
    }

    function test_burn_EmitsTransferEventToZero() public {
        _mint(ALICE, ASSET, 100);
        vm.expectEmit(address(depot));
        emit IDepot.Transfer(conductor, ALICE, bytes28(0), ASSET, 40);
        vm.prank(conductor);
        depot.burn(ALICE, ASSET, 40);
    }

    function test_burn_RevertIf_SenderIsUnauthorized() public {
        _mint(ALICE, ASSET, 100);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vm.prank(stranger);
        depot.burn(ALICE, ASSET, 40);
    }

    function test_burn_RevertIf_ContractIsPaused() public {
        _mint(ALICE, ASSET, 100);
        _pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(conductor);
        depot.burn(ALICE, ASSET, 40);
    }

    function test_burn_RevertIf_AccountIsInvalid() public {
        vm.expectRevert(IDepot.InvalidAccount.selector);
        vm.prank(conductor);
        depot.burn(INVALID_ZERO_CHAIN, ASSET, 0);
        vm.expectRevert(IDepot.InvalidAccount.selector);
        vm.prank(conductor);
        depot.burn(INVALID_ZERO_ADDRESS, ASSET, 0);
    }

    function test_burn_RevertIf_AccountIsFrozen() public {
        _mint(ALICE, ASSET, 100);
        _freeze(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IDepot.AccountFrozen.selector, ALICE));
        vm.prank(conductor);
        depot.burn(ALICE, ASSET, 40);
    }

    function test_burn_RevertIf_AmountExceedsBalance() public {
        _mint(ALICE, ASSET, 100);
        vm.expectRevert(IDepot.InsufficientBalance.selector);
        vm.prank(conductor);
        depot.burn(ALICE, ASSET, 101);
    }

    function test_burn_RevertIf_AmountExceedsFreeBalance() public {
        _mint(ALICE, ASSET, 100);
        _reserve(ALICE, ASSET, 30);
        _advanceEpoch();
        vm.expectRevert(IDepot.InsufficientBalance.selector);
        vm.prank(conductor);
        depot.burn(ALICE, ASSET, 71);
    }

    function test_forceTransferFrom_MovesBalance() public {
        _mint(ALICE, ASSET, 100);
        vm.prank(conductor);
        depot.forceTransferFrom(ALICE, BOB, ASSET, 40);
        assertEq(depot.balanceOf(ALICE, ASSET), 60, "sender balance wrong");
        assertEq(depot.balanceOf(BOB, ASSET), 40, "recipient balance wrong");
    }

    function test_forceTransferFrom_MintsFromZero() public {
        vm.prank(conductor);
        depot.forceTransferFrom(bytes28(0), BOB, ASSET, 40);
        assertEq(depot.balanceOf(BOB, ASSET), 40, "mint not applied");
    }

    function test_forceTransferFrom_BurnsToZero() public {
        _mint(ALICE, ASSET, 100);
        vm.prank(conductor);
        depot.forceTransferFrom(ALICE, bytes28(0), ASSET, 40);
        assertEq(depot.balanceOf(ALICE, ASSET), 60, "burn not applied");
    }

    function test_forceTransferFrom_SucceedsWhilePaused() public {
        _mint(ALICE, ASSET, 100);
        _pause();
        vm.prank(conductor);
        depot.forceTransferFrom(ALICE, BOB, ASSET, 40);
        assertEq(depot.balanceOf(BOB, ASSET), 40, "transfer not applied while paused");
    }

    function test_forceTransferFrom_AllowsFrozenSender() public {
        _mint(ALICE, ASSET, 100);
        _freeze(ALICE);
        vm.prank(conductor);
        depot.forceTransferFrom(ALICE, BOB, ASSET, 40);
        assertEq(depot.balanceOf(BOB, ASSET), 40, "transfer from frozen account not applied");
    }

    function test_forceTransferFrom_IgnoresReservation() public {
        _mint(ALICE, ASSET, 100);
        _reserve(ALICE, ASSET, 100);
        _advanceEpoch();
        vm.prank(conductor);
        depot.forceTransferFrom(ALICE, BOB, ASSET, 100);
        assertEq(depot.balanceOf(BOB, ASSET), 100, "transfer of reserved balance not applied");
    }

    function test_forceTransferFrom_AllowsInvalidAccounts() public {
        vm.startPrank(conductor);
        depot.forceTransferFrom(bytes28(0), INVALID_ZERO_CHAIN, ASSET, 40);
        depot.forceTransferFrom(INVALID_ZERO_CHAIN, INVALID_ZERO_ADDRESS, ASSET, 40);
        vm.stopPrank();
        assertEq(depot.balanceOf(INVALID_ZERO_CHAIN, ASSET), 0, "invalid sender balance wrong");
        assertEq(depot.balanceOf(INVALID_ZERO_ADDRESS, ASSET), 40, "invalid recipient balance wrong");
    }

    function test_forceTransferFrom_EmitsTransferEvent() public {
        _mint(ALICE, ASSET, 100);
        vm.expectEmit(address(depot));
        emit IDepot.Transfer(conductor, ALICE, BOB, ASSET, 40);
        vm.prank(conductor);
        depot.forceTransferFrom(ALICE, BOB, ASSET, 40);
    }

    function test_forceTransferFrom_RevertIf_SenderIsUnauthorized() public {
        _mint(ALICE, ASSET, 100);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vm.prank(stranger);
        depot.forceTransferFrom(ALICE, BOB, ASSET, 40);
    }

    function test_forceTransferFrom_RevertIf_AmountExceedsBalance() public {
        _mint(ALICE, ASSET, 100);
        vm.expectRevert(stdError.arithmeticError);
        vm.prank(conductor);
        depot.forceTransferFrom(ALICE, BOB, ASSET, 101);
    }

    function test_advanceEpoch_IncrementsEpoch() public {
        _advanceEpoch();
        assertEq(depot.settlementEpoch(), 2, "settlementEpoch not incremented");
    }

    function test_advanceEpoch_SetsLastEpochAdvancedAt() public {
        vm.warp(block.timestamp + 1 hours);
        _advanceEpoch();
        assertEq(depot.lastEpochAdvancedAt(), block.timestamp, "lastEpochAdvancedAt not current timestamp");
    }

    function test_advanceEpoch_EmitsEpochAdvancedEvent() public {
        vm.expectEmit(address(depot));
        emit IDepot.EpochAdvanced(2);
        _advanceEpoch();
    }

    function test_advanceEpoch_SucceedsWhilePaused() public {
        _pause();
        _advanceEpoch();
        assertEq(depot.settlementEpoch(), 2, "settlementEpoch not incremented while paused");
    }

    function test_advanceEpoch_AllowsAuthorizedBefore24h() public {
        vm.warp(block.timestamp + 24 hours - 1);
        _advanceEpoch();
        assertEq(depot.settlementEpoch(), 2, "authorized sender could not advance");
    }

    function test_advanceEpoch_AllowsAnyoneAfter24h() public {
        vm.warp(block.timestamp + 24 hours);
        vm.prank(stranger);
        depot.advanceEpoch();
        assertEq(depot.settlementEpoch(), 2, "any sender could not advance");
    }

    function test_advanceEpoch_RevertIf_SenderIsUnauthorizedBefore24h() public {
        vm.warp(block.timestamp + 24 hours - 1);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vm.prank(stranger);
        depot.advanceEpoch();
    }

    function test_reserve_AddsAmountToPendingReservation() public {
        _reserve(ALICE, ASSET, 30);
        (, uint256 pending,) = depot.reservation(ALICE, ASSET);
        assertEq(pending, 30, "pending not increased");
    }

    function test_reserve_SetsPendingEpochToNextSettlementEpoch() public {
        _reserve(ALICE, ASSET, 30);
        (,, uint256 pendingEpoch) = depot.reservation(ALICE, ASSET);
        assertEq(pendingEpoch, depot.settlementEpoch() + 1, "pendingEpoch not settlementEpoch + 1");
    }

    function test_reserve_RollsPendingAfterEpochAdvance() public {
        _reserve(ALICE, ASSET, 30);
        _advanceEpoch();
        _reserve(ALICE, ASSET, 20);
        (uint256 effective, uint256 pending,) = depot.reservation(ALICE, ASSET);
        assertEq(effective, 30, "arrived pending not rolled into effective");
        assertEq(pending, 20, "pending not replaced by new amount");
    }

    function test_reserve_AccumulatesWithinEpoch() public {
        _reserve(ALICE, ASSET, 30);
        _reserve(ALICE, ASSET, 20);
        (uint256 effective, uint256 pending,) = depot.reservation(ALICE, ASSET);
        assertEq(effective, 0, "effective changed within epoch");
        assertEq(pending, 50, "pending not accumulated");
    }

    function test_reserve_AllowsExceedingBalance() public {
        _mint(ALICE, ASSET, 10);
        _reserve(ALICE, ASSET, 100);
        (, uint256 pending,) = depot.reservation(ALICE, ASSET);
        assertEq(pending, 100, "reservation in excess of balance not recorded");
    }

    function test_reserve_EmitsReservedEvent() public {
        vm.expectEmit(address(depot));
        emit IDepot.Reserved(ALICE, ASSET, 30, 2);
        _reserve(ALICE, ASSET, 30);
    }

    function test_reserve_RevertIf_SenderIsUnauthorized() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vm.prank(stranger);
        depot.reserve(ALICE, ASSET, 30);
    }

    function test_reserve_RevertIf_ContractIsPaused() public {
        _pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        _reserve(ALICE, ASSET, 30);
    }

    function test_release_DecreasesEffective() public {
        _reserve(ALICE, ASSET, 30);
        _advanceEpoch();
        _roll(ALICE, ASSET);
        vm.prank(conductor);
        depot.release(ALICE, ASSET, 10);
        (uint256 effective,,) = depot.reservation(ALICE, ASSET);
        assertEq(effective, 20, "effective not decreased");
    }

    function test_release_RollsPendingAfterEpochAdvance() public {
        _reserve(ALICE, ASSET, 30);
        _advanceEpoch();
        vm.prank(conductor);
        depot.release(ALICE, ASSET, 10);
        (uint256 effective, uint256 pending,) = depot.reservation(ALICE, ASSET);
        assertEq(effective, 20, "arrived pending not rolled before release");
        assertEq(pending, 0, "pending not cleared by roll");
    }

    function test_release_EmitsReleaseEvent() public {
        _reserve(ALICE, ASSET, 30);
        _advanceEpoch();
        vm.expectEmit(address(depot));
        emit IDepot.Release(ALICE, ASSET, 10);
        vm.prank(conductor);
        depot.release(ALICE, ASSET, 10);
    }

    function test_release_RevertIf_SenderIsUnauthorized() public {
        _reserve(ALICE, ASSET, 30);
        _advanceEpoch();
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vm.prank(stranger);
        depot.release(ALICE, ASSET, 10);
    }

    function test_release_RevertIf_ContractIsPaused() public {
        _reserve(ALICE, ASSET, 30);
        _advanceEpoch();
        _pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(conductor);
        depot.release(ALICE, ASSET, 10);
    }

    function test_release_RevertIf_AmountExceedsEffective() public {
        _reserve(ALICE, ASSET, 30);
        _advanceEpoch();
        vm.expectRevert(abi.encodeWithSelector(IDepot.ReleaseExceedsReserved.selector, 31, 30));
        vm.prank(conductor);
        depot.release(ALICE, ASSET, 31);
    }

    function test_release_RevertIf_AmountIsStillPending() public {
        _reserve(ALICE, ASSET, 30);
        vm.expectRevert(abi.encodeWithSelector(IDepot.ReleaseExceedsReserved.selector, 30, 0));
        vm.prank(conductor);
        depot.release(ALICE, ASSET, 30);
    }

}
