// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

/// @title Transit Terminal RequestConductor
/// @notice Shared state, events and errors of conductors whose actions are requested one epoch before execution.
/// @custom:security-contact security@paxoslabs.com
interface IRequestConductor {

    /// @notice A request was made and its funds reserved.
    /// @param accountId Requesting account.
    /// @param requestId Request id (hash of the request).
    /// @param effectiveAtEpoch Epoch from which the request may be executed.
    event Requested(bytes28 indexed accountId, bytes32 indexed requestId, uint256 effectiveAtEpoch);

    /// @notice A request was consumed by execution, releasing any reservation.
    /// @param accountId Owner account.
    /// @param requestId Request id.
    event Consumed(bytes28 indexed accountId, bytes32 indexed requestId);

    /// @notice A request was consumed past its deadline without moving funds.
    /// @param requestId Request id.
    event RequestExpired(bytes32 indexed requestId);

    /// @notice A request was consumed without moving funds because its recipient is invalid.
    /// @param requestId Request id.
    event RequestVoided(bytes32 indexed requestId);

    /// @notice The request was already made or already executed.
    error RequestReplay();

    /// @notice The request is not effective yet, or was never made.
    error NotEffective();

    /// @notice The sender is not the request's owner.
    error NotOwner();

    /// @notice Sentinel stored in requestEffectiveAtEpoch once a request has been consumed.
    /// @return type(uint256).max.
    function EXECUTED() external view returns (uint256);

    /// @notice The Depot ledger requests reserve from.
    /// @return Depot address.
    function DEPOT() external view returns (address);

    /// @notice Epoch from which a request may be executed. Two special values: 0 means no request was made, and
    /// EXECUTED (type(uint256).max) means it has been consumed. Any other value is a pending request's epoch.
    /// @param accountId Owner account.
    /// @param requestId Request id.
    /// @return effectiveAtEpoch Epoch, 0, or EXECUTED.
    function requestEffectiveAtEpoch(
        bytes28 accountId,
        bytes32 requestId
    )
        external
        view
        returns (uint256 effectiveAtEpoch);

}
