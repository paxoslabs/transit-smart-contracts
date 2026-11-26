// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";
import { EIP712 } from "solady/utils/EIP712.sol";
import { IDepot } from "src/interfaces/IDepot.sol";
import { ISwapConductor } from "src/interfaces/ISwapConductor.sol";
import { TransitAddressLib } from "src/helpers/TransitAddressLib.sol";
import { ConductorGatedByTurnstile } from "src/conductor/ConductorGatedByTurnstile.sol";

/**
 * @title SwapConductor
 * @notice Shared base for swap conductors. Tracks per-order fill progress, pre-approvals, and owner cancellations,
 * and verifies order signatures.
 * @dev Orders are user-signed EIP-712 messages settled by a restricted solver in epoch batches. Cancellations take
 * effect from the next epoch, so a batch already in flight cannot be invalidated by one; a facilitated cancellation
 * takes effect in the current epoch.
 * @custom:security-contact security@paxoslabs.com
 */
abstract contract SwapConductor is ISwapConductor, AccessManaged, EIP712, ConductorGatedByTurnstile {

    /// @inheritdoc ISwapConductor
    address public immutable DEPOT;
    /// @inheritdoc ISwapConductor
    bytes28 public immutable SURPLUS_RECIPIENT_ACCOUNT_ID;

    /// @inheritdoc ISwapConductor
    mapping(bytes32 orderHash => uint256) public filledAmount;
    /// @inheritdoc ISwapConductor
    mapping(bytes28 accountId => mapping(bytes32 orderHash => uint256 epoch)) public cancelledFrom;
    /// @inheritdoc ISwapConductor
    mapping(bytes32 orderHash => bool) public preApproved;

    constructor(
        address _authority,
        address _depot,
        bytes28 _surplusRecipientAccountId,
        address _turnstile
    )
        AccessManaged(_authority)
        ConductorGatedByTurnstile(_turnstile)
    {
        if (!TransitAddressLib.isValid(_surplusRecipientAccountId)) revert InvalidAccount();
        DEPOT = _depot;
        SURPLUS_RECIPIENT_ACCOUNT_ID = _surplusRecipientAccountId;
    }

    /// @inheritdoc ISwapConductor
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparator();
    }

    // ========================================= USER =========================================

    /// @inheritdoc ISwapConductor
    function requestOrderCancellation(bytes32 orderHash) external {
        bytes28 accountId = _senderAccountId();
        uint256 effectiveAtEpoch = IDepot(DEPOT).settlementEpoch();
        if (!_facilitated()) effectiveAtEpoch++;
        uint256 cancelledFromEpoch = cancelledFrom[accountId][orderHash];
        if (cancelledFromEpoch != 0 && cancelledFromEpoch <= effectiveAtEpoch) return;
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
        uint256 cancelledFromEpoch = cancelledFrom[ownerAccountId][orderHash];
        if (cancelledFromEpoch != 0 && settlementEpoch >= cancelledFromEpoch) revert Cancelled(orderHash);

        emit Filled(orderHash, ownerAccountId, sellFilled, buyFilled);
    }

}
