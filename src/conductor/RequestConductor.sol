// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { IDepot } from "src/interfaces/IDepot.sol";
import { TurnstileGated } from "src/turnstile/TurnstileGated.sol";
import { IRequestConductor } from "src/interfaces/IRequestConductor.sol";

/**
 * @title RequestConductor
 * @notice Base for conductors whose user actions (withdrawals, transfers) must be requested one epoch before they
 * execute. A request reserves the funds in the Depot so they cannot be spent elsewhere; once the epoch arrives anyone
 * may execute it, which releases the reservation and consumes the request.
 * @dev The delay keeps user-initiated outflows from invalidating a solver batch already in flight. A facilitated owner
 * may skip the request and execute immediately, as the facilitator is trusted to coordinate with solvers.
 */
abstract contract RequestConductor is IRequestConductor, TurnstileGated {

    /// @inheritdoc IRequestConductor
    uint256 public constant EXECUTED = type(uint256).max;

    /// @inheritdoc IRequestConductor
    address public immutable DEPOT;

    /// @inheritdoc IRequestConductor
    mapping(bytes28 accountId => mapping(bytes32 requestId => uint256 effectiveAtEpoch)) public requestEffectiveAtEpoch;

    constructor(address _depot, address _turnstile) TurnstileGated(_turnstile) {
        DEPOT = _depot;
    }

    function _request(bytes28 ownerAccountId, bytes32 requestId, bytes28 assetId, uint256 amount) internal {
        bytes28 senderAccountId = _senderAccountId();
        if (senderAccountId != ownerAccountId) revert NotOwner();
        if (requestEffectiveAtEpoch[senderAccountId][requestId] != 0) revert RequestReplay();
        uint256 effectiveAtEpoch = IDepot(DEPOT).settlementEpoch() + 1;
        IDepot(DEPOT).reserve(senderAccountId, assetId, amount);
        requestEffectiveAtEpoch[senderAccountId][requestId] = effectiveAtEpoch;
        emit Requested(senderAccountId, requestId, effectiveAtEpoch);
    }

    function _consume(bytes28 ownerAccountId, bytes32 requestId, bytes28 assetId, uint256 amount) internal {
        _requireEffective(ownerAccountId, requestId);
        uint256 effectiveAtEpoch = requestEffectiveAtEpoch[ownerAccountId][requestId];
        if (effectiveAtEpoch == EXECUTED) revert RequestReplay();
        requestEffectiveAtEpoch[ownerAccountId][requestId] = EXECUTED;
        // 0 means a facilitated owner skipped the request, so there is no reservation to release.
        if (effectiveAtEpoch != 0) IDepot(DEPOT).release(ownerAccountId, assetId, amount);
        emit Consumed(ownerAccountId, requestId);
    }

    function _executableAmount(
        bytes28 accountId,
        bytes28 assetId,
        uint256 requested,
        bool partiallyFillable
    )
        internal
        view
        returns (uint256 amount)
    {
        amount = FixedPointMathLib.min(requested, IDepot(DEPOT).freeBalanceOf(accountId, assetId));
        if (!partiallyFillable && amount < requested) amount = 0;
    }

    function _requireEffective(bytes28 ownerAccountId, bytes32 requestId) private view {
        uint256 effectiveAtEpoch = requestEffectiveAtEpoch[ownerAccountId][requestId];
        // A facilitated owner with no prior request may execute immediately: the facilitator is trusted not to pull
        // funds out from under an in-flight batch. Anyone else must wait for the request to become effective.
        if (effectiveAtEpoch == 0 && _facilitated() && _senderAccountId() == ownerAccountId) return;
        // Already consumed; _consume reverts on replay.
        if (effectiveAtEpoch == EXECUTED) return;
        if (effectiveAtEpoch == 0 || IDepot(DEPOT).settlementEpoch() < effectiveAtEpoch) revert NotEffective();
    }

}
