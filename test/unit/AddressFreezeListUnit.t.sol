// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { Test, Vm } from "forge-std/Test.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IFreezable } from "@predicate/interfaces/IFreezable.sol";
import { AddressFreezeList } from "src/AddressFreezeList.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { Roles } from "src/helpers/Roles.sol";
import { TransitAddressLib } from "src/helpers/TransitAddressLib.sol";

contract AddressFreezeListUnitTest is Test {

    address admin = makeAddr("admin");
    address freezeManager = makeAddr("freezeManager");
    address stranger = makeAddr("stranger");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    AccessManager authority;
    AddressFreezeList freezeList;

    function setUp() public {
        authority = new AccessManager(admin);
        freezeList = new AddressFreezeList(address(authority));

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = AddressFreezeList.freeze.selector;
        selectors[1] = AddressFreezeList.freezeAccounts.selector;
        selectors[2] = AddressFreezeList.unfreeze.selector;
        selectors[3] = AddressFreezeList.unfreezeAccounts.selector;

        vm.startPrank(admin);
        authority.setTargetFunctionRole(address(freezeList), selectors, Roles.FREEZE_MANAGER);
        authority.grantRole(Roles.FREEZE_MANAGER, freezeManager, 0);
        vm.stopPrank();
    }

    function _freeze(address account) internal {
        vm.prank(freezeManager);
        freezeList.freeze(account);
    }

    function _pair(address a, address b) internal pure returns (address[] memory accounts) {
        accounts = new address[](2);
        accounts[0] = a;
        accounts[1] = b;
    }

    function test_constructor_SetsAuthority() public view {
        assertEq(freezeList.authority(), address(authority), "authority not set");
    }

    function test_freeze_FreezesAddress() public {
        _freeze(alice);
        assertTrue(freezeList.isFrozen(alice), "address not frozen");
    }

    function test_freeze_EmitsFrozenEvent() public {
        vm.expectEmit(address(freezeList));
        emit IFreezable.Frozen(alice, block.timestamp);
        _freeze(alice);
    }

    function test_freeze_DoesNotEmitFrozenEventIfAddressIsAlreadyFrozen() public {
        _freeze(alice);
        vm.recordLogs();
        _freeze(alice);
        assertEq(vm.getRecordedLogs().length, 0, "event emitted for already frozen address");
    }

    function test_freeze_RevertIf_SenderIsUnauthorized() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vm.prank(stranger);
        freezeList.freeze(alice);
    }

    function test_freezeAccounts_FreezesEachAddress() public {
        vm.prank(freezeManager);
        freezeList.freezeAccounts(_pair(alice, bob));
        assertTrue(freezeList.isFrozen(alice), "first address not frozen");
        assertTrue(freezeList.isFrozen(bob), "second address not frozen");
    }

    function test_freezeAccounts_EmitsFrozenEventPerNewlyFrozenAddress() public {
        vm.expectEmit(address(freezeList));
        emit IFreezable.Frozen(alice, block.timestamp);
        vm.expectEmit(address(freezeList));
        emit IFreezable.Frozen(bob, block.timestamp);
        vm.prank(freezeManager);
        freezeList.freezeAccounts(_pair(alice, bob));
    }

    function test_freezeAccounts_DoesNotEmitFrozenEventForAlreadyFrozenAddresses() public {
        _freeze(alice);
        vm.recordLogs();
        vm.prank(freezeManager);
        freezeList.freezeAccounts(_pair(alice, bob));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "event count not one");
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(bob))), "event not for newly frozen address");
    }

    function test_freezeAccounts_AcceptsEmptyArray() public {
        vm.prank(freezeManager);
        freezeList.freezeAccounts(new address[](0));
    }

    function test_freezeAccounts_RevertIf_SenderIsUnauthorized() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vm.prank(stranger);
        freezeList.freezeAccounts(_pair(alice, bob));
    }

    function test_unfreeze_UnfreezesAddress() public {
        _freeze(alice);
        vm.prank(freezeManager);
        freezeList.unfreeze(alice);
        assertFalse(freezeList.isFrozen(alice), "address still frozen");
    }

    function test_unfreeze_EmitsUnfrozenEvent() public {
        _freeze(alice);
        vm.expectEmit(address(freezeList));
        emit IFreezable.Unfrozen(alice, block.timestamp);
        vm.prank(freezeManager);
        freezeList.unfreeze(alice);
    }

    function test_unfreeze_DoesNotEmitUnfrozenEventIfAddressIsNotFrozen() public {
        vm.recordLogs();
        vm.prank(freezeManager);
        freezeList.unfreeze(alice);
        assertEq(vm.getRecordedLogs().length, 0, "event emitted for address that is not frozen");
    }

    function test_unfreeze_RevertIf_SenderIsUnauthorized() public {
        _freeze(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vm.prank(stranger);
        freezeList.unfreeze(alice);
    }

    function test_unfreezeAccounts_UnfreezesEachAddress() public {
        _freeze(alice);
        _freeze(bob);
        vm.prank(freezeManager);
        freezeList.unfreezeAccounts(_pair(alice, bob));
        assertFalse(freezeList.isFrozen(alice), "first address still frozen");
        assertFalse(freezeList.isFrozen(bob), "second address still frozen");
    }

    function test_unfreezeAccounts_EmitsUnfrozenEventPerNewlyUnfrozenAddress() public {
        _freeze(alice);
        _freeze(bob);
        vm.expectEmit(address(freezeList));
        emit IFreezable.Unfrozen(alice, block.timestamp);
        vm.expectEmit(address(freezeList));
        emit IFreezable.Unfrozen(bob, block.timestamp);
        vm.prank(freezeManager);
        freezeList.unfreezeAccounts(_pair(alice, bob));
    }

    function test_unfreezeAccounts_DoesNotEmitUnfrozenEventForAddressesThatAreNotFrozen() public {
        _freeze(bob);
        vm.recordLogs();
        vm.prank(freezeManager);
        freezeList.unfreezeAccounts(_pair(alice, bob));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "event count not one");
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(bob))), "event not for newly unfrozen address");
    }

    function test_unfreezeAccounts_AcceptsEmptyArray() public {
        vm.prank(freezeManager);
        freezeList.unfreezeAccounts(new address[](0));
    }

    function test_unfreezeAccounts_RevertIf_SenderIsUnauthorized() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vm.prank(stranger);
        freezeList.unfreezeAccounts(_pair(alice, bob));
    }

    function test_isFrozen_ReturnsWhetherAddressIsFrozen() public {
        assertFalse(freezeList.isFrozen(alice), "address frozen before freeze");
        _freeze(alice);
        assertTrue(freezeList.isFrozen(alice), "address not frozen after freeze");
    }

    function test_isFrozen_ReturnsWhetherAccountAddressIsFrozen() public {
        bytes28 accountId = TransitAddressLib.formatTransitAddress(1, alice);
        assertFalse(freezeList.isFrozen(accountId), "account frozen before freeze");
        _freeze(alice);
        assertTrue(freezeList.isFrozen(accountId), "account not frozen after freeze");
    }

    function test_isFrozen_ReturnsTrueForAccountOnAnyChain() public {
        _freeze(alice);
        assertTrue(freezeList.isFrozen(TransitAddressLib.formatTransitAddress(1, alice)), "account on chain 1 not frozen");
        assertTrue(freezeList.isFrozen(TransitAddressLib.formatTransitAddress(10, alice)), "account on chain 10 not frozen");
        assertTrue(
            freezeList.isFrozen(TransitAddressLib.formatTransitAddress(type(uint64).max, alice)),
            "account on max chain not frozen"
        );
    }

    function test_FREEZE_MANAGER_ROLE_ReturnsFreezeManagerRole() public view {
        assertEq(freezeList.FREEZE_MANAGER_ROLE(), bytes32(uint256(Roles.FREEZE_MANAGER)), "role not FREEZE_MANAGER");
    }

}
