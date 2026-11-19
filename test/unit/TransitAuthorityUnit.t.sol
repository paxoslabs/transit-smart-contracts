// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { Test } from "forge-std/Test.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { TransitAuthority } from "src/TransitAuthority.sol";
import { ITransitAuthority } from "src/interfaces/ITransitAuthority.sol";
import { Roles } from "src/helpers/Roles.sol";

contract TransitAuthorityUnitTest is Test {

    address constant PREDICATE_FREEZE_MANAGER = 0x363c256D368277BBFaf6EaF65beE123a7AdbA464;
    bytes4 constant SELECTOR_A = bytes4(keccak256("a()"));
    bytes4 constant SELECTOR_B = bytes4(keccak256("b()"));

    address admin = makeAddr("admin");
    address caller = makeAddr("caller");
    address stranger = makeAddr("stranger");
    address target = makeAddr("target");
    address otherTarget = makeAddr("otherTarget");

    TransitAuthority authority;

    function setUp() public {
        authority = new TransitAuthority(admin);
    }

    function _selectors(bytes4 a) internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = a;
    }

    function _selectors(bytes4 a, bytes4 b) internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = a;
        selectors[1] = b;
    }

    function _setRole(address target_, bytes4[] memory selectors, bytes32 role) internal {
        vm.prank(admin);
        authority.setTargetFunctionRole(target_, selectors, role);
    }

    function _grant(bytes32 role, address account) internal {
        vm.prank(admin);
        authority.grantRole(role, account);
    }

    function test_constructor_GrantsDefaultAdminRoleToAdmin() public view {
        assertTrue(authority.hasRole(authority.DEFAULT_ADMIN_ROLE(), admin), "admin lacks DEFAULT_ADMIN_ROLE");
    }

    function test_constructor_GrantsAdminRoleToAdmin() public view {
        assertTrue(authority.hasRole(Roles.ADMIN, admin), "admin lacks Roles.ADMIN");
    }

    function test_constructor_GrantsFreezeManagerRoleToPredicateFreezeManager() public view {
        assertTrue(
            authority.hasRole(Roles.FREEZE_MANAGER, PREDICATE_FREEZE_MANAGER),
            "Predicate freeze manager lacks Roles.FREEZE_MANAGER"
        );
    }

    function test_roleOf_ReturnsRoleSetForTargetAndSelector() public {
        _setRole(target, _selectors(SELECTOR_A), Roles.PAUSER);
        assertEq(authority.roleOf(target, SELECTOR_A), Roles.PAUSER, "role not returned");
    }

    function test_roleOf_ReturnsZeroForUnmappedTargetAndSelector() public view {
        assertEq(authority.roleOf(target, SELECTOR_A), bytes32(0), "unmapped role not zero");
    }

    function test_canCall_ReturnsTrueIfCallerHoldsRole() public {
        _setRole(target, _selectors(SELECTOR_A), Roles.PAUSER);
        _grant(Roles.PAUSER, caller);
        assertTrue(authority.canCall(caller, target, SELECTOR_A), "role holder cannot call");
    }

    function test_canCall_ReturnsFalseIfCallerDoesNotHoldRole() public {
        _setRole(target, _selectors(SELECTOR_A), Roles.PAUSER);
        assertFalse(authority.canCall(stranger, target, SELECTOR_A), "non-holder can call");
    }

    function test_canCall_ReturnsFalseForUnmappedTargetAndSelector() public {
        _grant(Roles.PAUSER, caller);
        assertFalse(authority.canCall(caller, target, SELECTOR_A), "unmapped selector callable");
    }

    function test_canCall_ReturnsFalseForUnmappedTargetAndSelectorEvenIfCallerHoldsDefaultAdminRole() public view {
        assertFalse(
            authority.canCall(admin, target, SELECTOR_A), "DEFAULT_ADMIN_ROLE holder can call unmapped selector"
        );
    }

    function test_canCall_ReturnsFalseAfterRoleIsRevokedFromCaller() public {
        _setRole(target, _selectors(SELECTOR_A), Roles.PAUSER);
        _grant(Roles.PAUSER, caller);
        vm.prank(admin);
        authority.revokeRole(Roles.PAUSER, caller);
        assertFalse(authority.canCall(caller, target, SELECTOR_A), "revoked caller can call");
    }

    function test_setTargetFunctionRole_SetsRoleForEachSelector() public {
        _setRole(target, _selectors(SELECTOR_A, SELECTOR_B), Roles.PAUSER);
        assertEq(authority.roleOf(target, SELECTOR_A), Roles.PAUSER, "first selector role not set");
        assertEq(authority.roleOf(target, SELECTOR_B), Roles.PAUSER, "second selector role not set");
    }

    function test_setTargetFunctionRole_OverwritesPreviouslySetRole() public {
        _setRole(target, _selectors(SELECTOR_A), Roles.PAUSER);
        _setRole(target, _selectors(SELECTOR_A), Roles.CONDUCTOR);
        assertEq(authority.roleOf(target, SELECTOR_A), Roles.CONDUCTOR, "role not overwritten");
    }

    function test_setTargetFunctionRole_UnmapsSelectorsWhenRoleIsZero() public {
        _setRole(target, _selectors(SELECTOR_A), Roles.PAUSER);
        _grant(Roles.PAUSER, caller);
        _setRole(target, _selectors(SELECTOR_A), bytes32(0));
        assertEq(authority.roleOf(target, SELECTOR_A), bytes32(0), "role not cleared");
        assertFalse(authority.canCall(caller, target, SELECTOR_A), "unmapped selector still callable");
    }

    function test_setTargetFunctionRole_DoesNotAffectSameSelectorOnOtherTargets() public {
        _setRole(target, _selectors(SELECTOR_A), Roles.PAUSER);
        assertEq(authority.roleOf(otherTarget, SELECTOR_A), bytes32(0), "other target affected");
    }

    function test_setTargetFunctionRole_AcceptsEmptySelectorsArray() public {
        _setRole(target, new bytes4[](0), Roles.PAUSER);
    }

    function test_setTargetFunctionRole_EmitsTargetFunctionRoleSetEventPerSelector() public {
        vm.expectEmit(address(authority));
        emit ITransitAuthority.TargetFunctionRoleSet(target, SELECTOR_A, Roles.PAUSER);
        vm.expectEmit(address(authority));
        emit ITransitAuthority.TargetFunctionRoleSet(target, SELECTOR_B, Roles.PAUSER);
        _setRole(target, _selectors(SELECTOR_A, SELECTOR_B), Roles.PAUSER);
    }

    function test_setTargetFunctionRole_RevertIf_SenderLacksDefaultAdminRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, authority.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(stranger);
        authority.setTargetFunctionRole(target, _selectors(SELECTOR_A), Roles.PAUSER);
    }

    function test_setTargetFunctionRole_RevertIf_SenderHoldsRolesAdminButLacksDefaultAdminRole() public {
        _grant(Roles.ADMIN, caller);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, caller, authority.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(caller);
        authority.setTargetFunctionRole(target, _selectors(SELECTOR_A), Roles.PAUSER);
    }

}
