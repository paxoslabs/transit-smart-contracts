// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { IConductor } from "src/interfaces/IConductor.sol";

/// @title Transit Terminal SwapConductor
/// @notice Shared state, events and errors of swap conductors: fill progress, pre-approvals and owner cancellations.
/// @custom:security-contact security@paxoslabs.com
interface ISwapConductor is IConductor {

    /// @notice An owner requested an order's cancellation.
    /// @param ownerAccountId Account that cancelled.
    /// @param orderHash Order cancelled.
    /// @param effectiveAtEpoch Epoch from which the order can no longer be filled.
    event OrderCancellationRequested(
        bytes28 indexed ownerAccountId, bytes32 indexed orderHash, uint256 effectiveAtEpoch
    );

    /// @notice An order was filled in a settlement.
    /// @param orderHash Order filled.
    /// @param ownerAccountId Order owner.
    /// @param sellFilled Amount of sell token taken from the owner.
    /// @param buyFilled Amount of buy token given to the receiver.
    event Filled(bytes32 indexed orderHash, bytes28 indexed ownerAccountId, uint256 sellFilled, uint256 buyFilled);

    /// @notice A fill gives the receiver less than the order's limit price.
    error LimitPrice(bytes32 orderHash);

    /// @notice A signature was not made by the order's owner.
    error BadSignature();

    /// @notice An order with an empty signature was not pre-approved.
    error NotPreApproved(bytes32 orderHash);

    /// @notice Lengths of parallel arrays do not match.
    error LengthMismatch();

    /// @notice An order has expired.
    error Expired(bytes32 id);

    /// @notice A fill would exceed the order's sellAmount.
    error Overfill(bytes32 orderHash);

    /// @notice A non partially fillable order was not filled in full.
    error NotPartiallyFillable(bytes32 orderHash);

    /// @notice The order's cancellation is effective at this settlement epoch.
    error Cancelled(bytes32 orderHash);

    /// @notice The settlement epoch advanced since the batch was built.
    error BadEpoch(uint256 epoch);

    /// @notice An account is not a valid transit address.
    error InvalidAccount();

    /// @notice Account credited with settlement fees.
    /// @return Surplus recipient account id.
    function SURPLUS_RECIPIENT_ACCOUNT_ID() external view returns (bytes28);

    /// @notice Total sell amount filled so far per order.
    /// @param orderHash Order to query.
    /// @return Amount of sell token filled.
    function filledAmount(bytes32 orderHash) external view returns (uint256);

    /// @notice Epoch from which an owner's order may no longer be filled. 0 means not cancelled.
    /// @param accountId Owner account.
    /// @param orderHash Order to query.
    /// @return Cancellation epoch, or 0.
    function cancelledFrom(bytes28 accountId, bytes32 orderHash) external view returns (uint256);

    /// @notice Orders approved on-chain by their owner, settled with an empty signature.
    /// @param orderHash Order to query.
    /// @return Whether the order is pre-approved.
    function preApproved(bytes32 orderHash) external view returns (bool);

    /// @notice EIP-712 domain separator orders are signed under.
    /// @return Domain separator.
    function DOMAIN_SEPARATOR() external view returns (bytes32);

    /// @notice Cancel one of the sender's orders from the next epoch, or the current epoch if facilitated. An earlier
    /// pending cancellation is kept.
    /// @param orderHash Order to cancel.
    function requestOrderCancellation(bytes32 orderHash) external;

}
