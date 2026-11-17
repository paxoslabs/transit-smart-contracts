// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";
import { EIP712 } from "solady/utils/EIP712.sol";
import { IDepot } from "src/depot/IDepot.sol";
import { TurnstileGated } from "src/turnstile/TurnstileGated.sol";

/**
 * @title SwapConductor
 * @notice Shared base for swap conductors. Tracks per-order fill progress, pre-approvals, and owner cancellations,
 * and verifies order signatures.
 * @dev Orders are user-signed EIP-712 messages settled by a restricted solver in epoch batches. Cancellations take
 * effect from the next epoch, so a batch already in flight cannot be invalidated by one; a facilitated cancellation
 * takes effect in the current epoch.
 */
abstract contract SwapConductor is AccessManaged, EIP712, TurnstileGated {

    /// @notice The Depot ledger settlements are applied to.
    address public immutable DEPOT;
    /// @notice Account credited with settlement fees.
    bytes28 public immutable SURPLUS_RECIPIENT_ACCOUNT_ID;

    /// @notice Total sell amount filled so far per order.
    mapping(bytes32 orderHash => uint256) public filledAmount;
    /// @notice Epoch from which an owner's order may no longer be filled. 0 means not cancelled.
    mapping(bytes28 accountId => mapping(bytes32 orderHash => uint256 epoch)) public cancelledFrom;
    /// @notice Orders approved on-chain by their owner, settled with an empty signature.
    mapping(bytes32 orderHash => bool) public preApproved;

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

    error LimitPrice(bytes32 orderHash);
    error BadSignature();
    error NotPreApproved(bytes32 orderHash);
    error LengthMismatch();
    error NotOwner();
    error Expired(bytes32 id);
    error Overfill(bytes32 orderHash);
    error NotPartiallyFillable(bytes32 orderHash);
    error Cancelled(bytes32 orderHash);
    error BadEpoch(uint256 epoch);

    constructor(
        address _authority,
        address _depot,
        bytes28 _surplusRecipientAccountId,
        address _turnstile
    )
        AccessManaged(_authority)
        TurnstileGated(_turnstile)
    {
        DEPOT = _depot;
        SURPLUS_RECIPIENT_ACCOUNT_ID = _surplusRecipientAccountId;
    }

    /// @notice EIP-712 domain separator orders are signed under.
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparator();
    }

    // ========================================= USER =========================================

    /// @notice Cancel one of the sender's orders from the next epoch, or the current epoch if facilitated. An earlier
    /// pending cancellation is kept.
    /// @param orderHash Order to cancel.
    function requestOrderCancellation(bytes32 orderHash) external {
        bytes28 accountId = _senderAccountId();
        uint256 effectiveAtEpoch = IDepot(DEPOT).settlementEpoch();
        if (!_facilitated()) effectiveAtEpoch++;
        uint256 cancelled = cancelledFrom[accountId][orderHash];
        if (cancelled != 0 && cancelled <= effectiveAtEpoch) return;
        cancelledFrom[accountId][orderHash] = effectiveAtEpoch;
        emit OrderCancellationRequested(accountId, orderHash, effectiveAtEpoch);
    }

    /// @dev An empty signature means the owner pre-approved the order on-chain; otherwise it must be the owner's ECDSA
    /// signature over the order hash.
    function _verifySignature(bytes32 orderHash, address owner, bytes calldata signature) internal view {
        if (signature.length == 0) {
            if (!preApproved[orderHash]) revert NotPreApproved(orderHash);
        } else if (ECDSA.recoverCalldata(orderHash, signature) != owner) {
            revert BadSignature();
        }
    }

    /// @dev Adds a fill to the order's progress and emits Filled. Reverts if the order would be overfilled or its
    /// cancellation is effective at this settlement epoch.
    function _recordFill(
        bytes32 orderHash,
        bytes28 ownerAccountId,
        uint256 sellAmount,
        uint256 sellFilled,
        uint256 buyFilled,
        uint256 settlementEpoch
    )
        internal
    {
        uint256 filled = filledAmount[orderHash] + sellFilled;
        if (filled > sellAmount) revert Overfill(orderHash);
        filledAmount[orderHash] = filled;
        uint256 cancelled = cancelledFrom[ownerAccountId][orderHash];
        if (cancelled != 0 && settlementEpoch >= cancelled) revert Cancelled(orderHash);

        emit Filled(orderHash, ownerAccountId, sellFilled, buyFilled);
    }

}
