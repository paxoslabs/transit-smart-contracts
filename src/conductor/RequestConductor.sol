// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { IDepot } from "../depot/IDepot.sol";
import { TransitTokenLib } from "../helpers/TransitTokenLib.sol";
import { TurnstileGated } from "../turnstile/TurnstileGated.sol";

abstract contract RequestConductor is TurnstileGated {

    uint256 public constant EXECUTED = type(uint256).max;

    address public immutable DEPOT;

    mapping(bytes32 accountId => mapping(bytes32 requestId => uint256 status)) public requestStatus;

    event Requested(bytes32 indexed accountId, bytes32 indexed requestId, uint256 effectiveAtEpoch);

    error RequestReplay();
    error NotEffective();
    error InsufficientBalance();

    constructor(address _depot, address _turnstile) TurnstileGated(_turnstile) {
        DEPOT = _depot;
    }

    function reserveAndRequest(bytes32 requestId, bytes32 assetId, uint256 amount) external {
        bytes32 accountId = _senderAccountId();
        if (requestStatus[accountId][requestId] != 0) revert RequestReplay();
        uint256 effectiveAtEpoch = IDepot(DEPOT).settlementEpoch() + 1;
        requestStatus[accountId][requestId] = effectiveAtEpoch;
        IDepot(DEPOT).reserve(accountId, assetId, amount);
        emit Requested(accountId, requestId, effectiveAtEpoch);
    }

    function _consume(
        uint64 ownerChainId,
        address owner,
        bytes32 requestId,
        bytes32 assetId,
        uint256 amount
    )
        internal
        returns (bytes32 accountId)
    {
        _requireEffective(ownerChainId, owner, requestId);
        accountId = TransitTokenLib.formatAccountId(ownerChainId, owner, false);
        uint256 status = requestStatus[accountId][requestId];
        if (status == EXECUTED) revert RequestReplay();
        requestStatus[accountId][requestId] = EXECUTED;
        if (status != 0 || !_facilitated()) IDepot(DEPOT).release(accountId, assetId, amount);
    }

    /// TODO: Decide partial-fill cap. Uses raw balanceOf as before, but transferFrom/burn now also enforce other
    /// reservations and revert InsufficientBalance.
    function _fillAmount(
        bytes32 accountId,
        bytes32 assetId,
        uint256 requested,
        bool partiallyFillable
    )
        internal
        view
        returns (uint256 amount)
    {
        amount = FixedPointMathLib.min(requested, IDepot(DEPOT).balanceOf(accountId, assetId));
        if (!partiallyFillable && amount < requested) revert InsufficientBalance();
    }

    function _requireEffective(uint64 ownerChainId, address owner, bytes32 requestId) private view {
        bytes32 ownerAccountId = TransitTokenLib.formatAccountId(ownerChainId, owner, false);
        if (_senderAccountId() == ownerAccountId) return;
        uint256 status = requestStatus[ownerAccountId][requestId];
        if (status == EXECUTED) return;
        if (status == 0 || IDepot(DEPOT).settlementEpoch() < status) revert NotEffective();
    }

}
