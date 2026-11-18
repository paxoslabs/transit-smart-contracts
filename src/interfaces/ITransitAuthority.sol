// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

/// @title Transit Terminal TransitAuthority
/// @notice Authority for AccessManaged Transit contracts: maps each (target, selector) to a role.
interface ITransitAuthority {

    /// @notice A function's required role was set.
    /// @param target Contract.
    /// @param selector Function selector.
    /// @param role Role required to call it.
    event TargetFunctionRoleSet(address indexed target, bytes4 indexed selector, bytes32 indexed role);

    /// @notice Role required to call a function. Zero means no one may call it.
    /// @param target Contract.
    /// @param selector Function selector.
    /// @return role Required role.
    function roleOf(address target, bytes4 selector) external view returns (bytes32 role);

    /// @notice Whether a caller may call a function, as asked by AccessManaged.
    /// @param caller Caller.
    /// @param target Contract.
    /// @param selector Function selector.
    /// @return True if the caller holds the function's role.
    function canCall(address caller, address target, bytes4 selector) external view returns (bool);

    /// @notice Set the role required to call functions on a target.
    /// @param target Contract.
    /// @param selectors Function selectors.
    /// @param role Role required.
    function setTargetFunctionRole(address target, bytes4[] calldata selectors, bytes32 role) external;

    /// @notice Move an AccessManaged target to a new authority. Not expected to be used; kept so contracts are not
    /// bound to this authority forever, since AccessManaged.setAuthority only accepts calls from the current authority.
    /// @param target AccessManaged contract.
    /// @param newAuthority New authority; must have code.
    function updateAuthority(address target, address newAuthority) external;

}
