// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { AccessControlEnumerable } from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Roles } from "src/helpers/Roles.sol";
import { ITransitAuthority } from "src/interfaces/ITransitAuthority.sol";

/**
 * @title TransitAuthority
 * @notice Central authority for every AccessManaged Transit contract. Each (target, selector) is mapped to one role,
 * and a caller may call that function if it holds the role. Roles are enumerable on-chain.
 * @dev Glue between AccessManaged, which asks canCall(caller, target, selector), and OZ AccessControlEnumerable, which
 * only answers hasRole. Unmapped functions are callable by no one. Used instead of OZ AccessManager to keep role
 * enumeration.
 * @custom:security-contact security@paxoslabs.com
 */
contract TransitAuthority is ITransitAuthority, AccessControlEnumerable {

    // Predicate's freeze manager on all EVM chains, granted Roles.FREEZE_MANAGER to enforce Asset Compliance
    // freezes on AddressFreezeList. See https://docs.predicate.io/v2/assets/get-started
    address constant PREDICATE_FREEZE_MANAGER = 0x363c256D368277BBFaf6EaF65beE123a7AdbA464;

    /// @inheritdoc ITransitAuthority
    mapping(address target => mapping(bytes4 selector => bytes32 role)) public roleOf;

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.ADMIN, admin);
        _grantRole(Roles.FREEZE_MANAGER, PREDICATE_FREEZE_MANAGER);
    }

    /// @inheritdoc ITransitAuthority
    function canCall(address caller, address target, bytes4 selector) external view returns (bool) {
        bytes32 role = roleOf[target][selector];
        if (role == bytes32(0)) return false;
        return hasRole(role, caller);
    }

    /// @inheritdoc ITransitAuthority
    function setTargetFunctionRole(
        address target,
        bytes4[] calldata selectors,
        bytes32 role
    )
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        for (uint256 i; i < selectors.length; ++i) {
            roleOf[target][selectors[i]] = role;
            emit TargetFunctionRoleSet(target, selectors[i], role);
        }
    }

    /// @inheritdoc ITransitAuthority
    function updateAuthority(address target, address newAuthority) external onlyRole(DEFAULT_ADMIN_ROLE) {
        IAccessManaged(target).setAuthority(newAuthority);
    }

}
