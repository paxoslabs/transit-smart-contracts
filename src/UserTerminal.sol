// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { Hub } from "./Hub.sol";
import { ITurnstile } from "./ITurnstile.sol";
import { TransitTokenLib } from "./helpers/TransitTokenLib.sol";
import { TurnstileGated } from "./TurnstileGated.sol";

contract UserTerminal is TurnstileGated, ReentrancyGuard {

    struct TransferRequest {
        uint64 ownerChainId;
        address owner;
        uint64 toChainId;
        address to;
        bytes32 assetId;
        uint256 amount;
        uint256 nonce;
        uint256 deadline;
        bool partiallyFillable;
    }

    struct WithdrawalRequest {
        uint64 ownerChainId;
        address owner;
        address to;
        bytes32 assetId;
        uint256 amount;
        uint256 nonce;
        uint256 deadline;
        bool partiallyFillable;
    }

    struct MintRequest {
        uint64 ownerChainId;
        address owner;
        bytes32 assetId;
        uint256 amount;
        uint256 nonce;
        uint256 deadline;
        bool partiallyFillable;
    }

    bytes32 public constant TRANSFER_REQUEST_TYPEHASH = keccak256(
        "TransferRequest(uint64 ownerChainId,address owner,uint64 toChainId,address to,bytes32 assetId,uint256 amount,uint256 nonce,uint256 deadline,bool partiallyFillable)"
    );

    bytes32 public constant WITHDRAWAL_REQUEST_TYPEHASH = keccak256(
        "WithdrawalRequest(uint64 ownerChainId,address owner,address to,bytes32 assetId,uint256 amount,uint256 nonce,uint256 deadline,bool partiallyFillable)"
    );

    bytes32 public constant MINT_REQUEST_TYPEHASH = keccak256(
        "MintRequest(uint64 ownerChainId,address owner,bytes32 assetId,uint256 amount,uint256 nonce,uint256 deadline,bool partiallyFillable)"
    );

    Hub public immutable HUB;

    event TransferRequested(bytes32 indexed requestId, TransferRequest request, uint256 effectiveAtEpoch);
    event WithdrawalRequested(bytes32 indexed requestId, WithdrawalRequest request, uint256 effectiveAtEpoch);
    event MintRequested(bytes32 indexed requestId, MintRequest request, uint256 effectiveAtEpoch);
    event TransferExecuted(bytes32 indexed requestId, uint256 amount);
    event WithdrawalExecuted(bytes32 indexed requestId, uint256 amount);
    event MintExecuted(bytes32 indexed requestId, uint256 amount);

    error NotEffective();
    error ZeroAddress();
    error InsufficientBalance();

    constructor(Hub _hub, address _turnstile) TurnstileGated(_turnstile) {
        HUB = _hub;
    }

    function reserve(bytes32 assetId, uint256 amount) external {
        HUB.reserve(_senderAccountId(), assetId, amount);
    }

    function reserveAndRequest(bytes32 requestId, bytes32 assetId, uint256 amount) external {
        HUB.reserveAndRequest(_senderAccountId(), requestId, assetId, amount);
    }

    function executeTransfer(TransferRequest calldata request) external nonReentrant {
        if (request.to == address(0)) revert ZeroAddress();
        bytes32 requestId = hashTransferRequest(request);
        bytes32 accountId = _consume(request.ownerChainId, request.owner, requestId, request.assetId, request.amount);

        /// TODO: Decide expired-request handling. Currently consumes it and releases the reservation without moving funds.
        if (block.timestamp > request.deadline) {
            emit TransferExecuted(requestId, 0);
            return;
        }

        uint256 amount = _fillAmount(accountId, request.assetId, request.amount, request.partiallyFillable);
        HUB.transferFrom(
            accountId, TransitTokenLib.formatAccountId(request.toChainId, request.to), request.assetId, amount
        );

        emit TransferExecuted(requestId, amount);
    }

    function executeWithdrawal(
        WithdrawalRequest calldata request,
        uint64 messageGas
    )
        external
        payable
        nonReentrant
    {
        bytes32 requestId = hashWithdrawalRequest(request);
        bytes32 accountId = _consume(request.ownerChainId, request.owner, requestId, request.assetId, request.amount);

        /// TODO: Decide expired-request handling. Currently consumes it and releases the reservation without moving funds.
        if (block.timestamp > request.deadline) {
            emit WithdrawalExecuted(requestId, 0);
            return;
        }

        uint256 amount = _fillAmount(accountId, request.assetId, request.amount, request.partiallyFillable);
        HUB.burn(accountId, request.assetId, amount);

        (uint64 assetChainId, address asset) = TransitTokenLib.parseAssetId(request.assetId);
        ITurnstile(TURNSTILE).sendWithdrawalMessage{ value: msg.value }(
            assetChainId, messageGas, asset, amount, request.to
        );

        emit WithdrawalExecuted(requestId, amount);
    }

    function executeMint(MintRequest calldata request) external nonReentrant {
        bytes32 requestId = hashMintRequest(request);
        bytes32 accountId = _consume(request.ownerChainId, request.owner, requestId, request.assetId, request.amount);

        /// TODO: Decide expired-request handling. Currently consumes it and releases the reservation without moving funds.
        if (block.timestamp > request.deadline) {
            emit MintExecuted(requestId, 0);
            return;
        }

        uint256 amount = _fillAmount(accountId, request.assetId, request.amount, request.partiallyFillable);
        HUB.delayedSettlementAssetRegistry().mint(accountId, request.assetId, amount);

        emit MintExecuted(requestId, amount);
    }

    /// TODO: Decide hashing. Currently plain struct hash with no EIP-712 domain, so IDs are the same across terminal versions.
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
                request.nonce,
                request.deadline,
                request.partiallyFillable
            )
        );
    }

    function hashWithdrawalRequest(WithdrawalRequest memory request) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                WITHDRAWAL_REQUEST_TYPEHASH,
                request.ownerChainId,
                request.owner,
                request.to,
                request.assetId,
                request.amount,
                request.nonce,
                request.deadline,
                request.partiallyFillable
            )
        );
    }

    function hashMintRequest(MintRequest memory request) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                MINT_REQUEST_TYPEHASH,
                request.ownerChainId,
                request.owner,
                request.assetId,
                request.amount,
                request.nonce,
                request.deadline,
                request.partiallyFillable
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
        HUB.consumeRequest(accountId, requestId);
        if (!_facilitated()) HUB.release(accountId, assetId, amount);
    }

    /// TODO: Decide partial-fill cap. Uses raw balanceOf as before, but transferFrom/burn now also enforce other reservations and revert InsufficientBalance.
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
        amount = FixedPointMathLib.min(requested, HUB.balanceOf(accountId, assetId));
        if (!partiallyFillable && amount < requested) revert InsufficientBalance();
    }

    function _requireEffective(uint64 ownerChainId, address owner, bytes32 requestId) private view {
        bytes32 ownerAccountId = TransitTokenLib.formatAccountId(ownerChainId, owner);
        if (_senderAccountId() == ownerAccountId) return;
        uint256 status = HUB.requestStatus(ownerAccountId, requestId);
        if (status == HUB.EXECUTED()) return;
        if (status == 0 || HUB.settlementEpoch() < status) revert NotEffective();
    }

}
