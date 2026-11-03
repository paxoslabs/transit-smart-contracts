// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { IDepot } from "../depot/IDepot.sol";
import { TransitTokenLib } from "../helpers/TransitTokenLib.sol";
import { TurnstileGated } from "../TurnstileGated.sol";

contract UserTerminal is TurnstileGated {

    struct TransferRequest {
        uint64 ownerChainId;
        address owner;
        uint64 toChainId;
        address to;
        bytes32 assetId;
        uint256 amount;
        uint256 deadline;
        bool partiallyFillable;
        bytes32 salt;
    }

    bytes32 public constant TRANSFER_REQUEST_TYPEHASH = keccak256(
        "TransferRequest(uint64 ownerChainId,address owner,uint64 toChainId,address to,bytes32 assetId,uint256 amount,uint256 deadline,bool partiallyFillable,bytes32 salt)"
    );

    uint256 public constant EXECUTED = type(uint256).max;

    address public immutable DEPOT;

    mapping(bytes32 accountId => mapping(bytes32 requestId => uint256 status)) public requestStatus;

    event Requested(bytes32 indexed accountId, bytes32 indexed requestId, uint256 effectiveAtEpoch);
    event TransferExecuted(bytes32 indexed requestId, uint256 amount);

    error RequestReplay();
    error NotEffective();
    error ZeroAddress();
    error InsufficientBalance();

    constructor(address _depot, address _turnstile) TurnstileGated(_turnstile) {
        DEPOT = _depot;
    }

    function reserve(bytes32 assetId, uint256 amount) external {
        IDepot(DEPOT).reserve(_senderAccountId(), assetId, amount);
    }

    function reserveAndRequest(bytes32 requestId, bytes32 assetId, uint256 amount) external {
        bytes32 accountId = _senderAccountId();
        if (requestStatus[accountId][requestId] != 0) revert RequestReplay();
        uint256 effectiveAtEpoch = IDepot(DEPOT).settlementEpoch() + 1;
        requestStatus[accountId][requestId] = effectiveAtEpoch;
        IDepot(DEPOT).reserve(accountId, assetId, amount);
        emit Requested(accountId, requestId, effectiveAtEpoch);
    }

    function executeTransfer(TransferRequest calldata request) external {
        if (request.to == address(0)) revert ZeroAddress();
        bytes32 requestId = hashTransferRequest(request);
        bytes32 accountId = _consume(request.ownerChainId, request.owner, requestId, request.assetId, request.amount);

        /// TODO: Decide expired-request handling. Currently consumes it and releases the reservation without moving
        /// funds.
        if (block.timestamp > request.deadline) {
            emit TransferExecuted(requestId, 0);
            return;
        }

        uint256 amount = _fillAmount(accountId, request.assetId, request.amount, request.partiallyFillable);
        IDepot(DEPOT)
            .transferFrom(
                accountId, TransitTokenLib.formatAccountId(request.toChainId, request.to), request.assetId, amount
            );

        emit TransferExecuted(requestId, amount);
    }

    /// TODO: Decide hashing. Currently plain struct hash with no EIP-712 domain, so IDs are the same across terminal
    /// versions.
    function hashTransferRequest(TransferRequest memory request) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                TRANSFER_REQUEST_TYPEHASH,
                request.ownerChainId,
                request.owner,
                request.toChainId,
                request.to,
                request.assetId,
                request.amount,
                request.deadline,
                request.partiallyFillable,
                request.salt
            )
        );
    }

    function _consume(
        uint64 ownerChainId,
        address owner,
        bytes32 requestId,
        bytes32 assetId,
        uint256 amount
    )
        private
        returns (bytes32 accountId)
    {
        _requireEffective(ownerChainId, owner, requestId);
        accountId = TransitTokenLib.formatAccountId(ownerChainId, owner);
        if (requestStatus[accountId][requestId] == EXECUTED) revert RequestReplay();
        requestStatus[accountId][requestId] = EXECUTED;
        if (!_facilitated()) IDepot(DEPOT).release(accountId, assetId, amount);
    }

    /// TODO: Decide partial-fill cap. Uses raw balanceOf as before, but transferFrom/burn now also enforce other
    /// reservations and revert InsufficientBalance.
    function _fillAmount(
        bytes32 accountId,
        bytes32 assetId,
        uint256 requested,
        bool partiallyFillable
    )
        private
        view
        returns (uint256 amount)
    {
        amount = FixedPointMathLib.min(requested, IDepot(DEPOT).balanceOf(accountId, assetId));
        if (!partiallyFillable && amount < requested) revert InsufficientBalance();
    }

    function _requireEffective(uint64 ownerChainId, address owner, bytes32 requestId) private view {
        bytes32 ownerAccountId = TransitTokenLib.formatAccountId(ownerChainId, owner);
        if (_senderAccountId() == ownerAccountId) return;
        uint256 status = requestStatus[ownerAccountId][requestId];
        if (status == EXECUTED) return;
        if (status == 0 || IDepot(DEPOT).settlementEpoch() < status) revert NotEffective();
    }

}
