// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { EIP712 } from "solady/utils/EIP712.sol";
import { IDepot } from "../depot/IDepot.sol";
import { TurnstileGated } from "../TurnstileGated.sol";

abstract contract SwapConductor is AccessManaged, EIP712, TurnstileGated {

    address public immutable DEPOT;
    bytes32 public immutable SURPLUS_RECIPIENT_ACCOUNT_ID;

    mapping(bytes32 orderHash => uint256) public filledAmount;
    mapping(bytes32 accountId => mapping(bytes32 orderHash => uint256 epoch)) public cancelledFrom;
    mapping(bytes32 orderHash => bool) public preApproved;

    event OrderCancellationRequested(
        bytes32 indexed ownerAccountId, bytes32 indexed orderHash, uint256 effectiveAtEpoch
    );
    event PreApproved(bytes32 indexed ownerAccountId, bytes32 indexed orderHash);
    event Filled(bytes32 indexed orderHash, bytes32 indexed ownerAccountId, uint256 sellFilled, uint256 buyFilled);

    error LimitPrice(bytes32 orderHash);
    error BadSignature();
    error NotPreApproved(bytes32 orderHash);
    error LengthMismatch();
    error NotOwner();
    error Expired(bytes32 id);
    error Overfill(bytes32 orderHash);
    error NotPartiallyFillable(bytes32 orderHash);
    error Cancelled(bytes32 orderHash);

    constructor(
        address _authority,
        address _depot,
        bytes32 _surplusRecipientAccountId,
        address _turnstile
    )
        AccessManaged(_authority)
        TurnstileGated(_turnstile)
    {
        DEPOT = _depot;
        SURPLUS_RECIPIENT_ACCOUNT_ID = _surplusRecipientAccountId;
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparator();
    }

    // ========================================= USER =========================================

    function requestOrderCancellation(bytes32 orderHash) external {
        bytes32 accountId = _senderAccountId();
        uint256 effectiveAtEpoch = IDepot(DEPOT).settlementEpoch();
        if (!_facilitated()) effectiveAtEpoch++;
        uint256 cancelled = cancelledFrom[accountId][orderHash];
        if (cancelled != 0 && cancelled <= effectiveAtEpoch) return;
        cancelledFrom[accountId][orderHash] = effectiveAtEpoch;
        emit OrderCancellationRequested(accountId, orderHash, effectiveAtEpoch);
    }

    function _recordFill(
        bytes32 orderHash,
        bytes32 ownerAccountId,
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
