// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

/// @title Transit Terminal Conductor
/// @notice Shared state and errors of conductors users reach through the Turnstile.
/// @custom:security-contact security@paxoslabs.com
interface IConductor {

    /// @notice The sender is not the owner.
    error NotOwner();

    /// @notice The Depot ledger this conductor acts on.
    /// @return Depot address.
    function DEPOT() external view returns (address);

    /// @notice The Turnstile whose appended sender suffix is trusted.
    /// @return Turnstile address.
    function TURNSTILE() external view returns (address);

}
