// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { ECDSA } from "solady/utils/ECDSA.sol";
import { EIP712 } from "solady/utils/EIP712.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SignatureCheckerLib } from "solady/utils/SignatureCheckerLib.sol";
import { MessagingEndpoint } from "./messaging/MessagingEndpoint.sol";

contract Hub is MessagingEndpoint, EIP712 {

    struct Order {
        address owner;
        uint64 sellTokenChainId;
        address sellToken;
        uint64 buyTokenChainId;
        address buyToken;
        uint256 sellAmount;
        uint256 buyAmount;
        address receiver;
        uint256 expiresAt;
        bytes32 salt;
        bool partiallyFillable;
    }

    struct Fill {
        Order order;
        bytes signature;
        uint256 sellFilled;
        uint256 buyFilled;
    }

    /// TODO: Decide fields. Currently owner + orderHash; the full Order would allow keying cancelledFrom by hash alone.
    struct OrderCancellationRequest {
        address owner;
        bytes32 orderHash;
    }

    struct TransferRequest {
        address owner;
        address to;
        uint64 assetChainId;
        address asset;
        uint256 amount;
        uint256 maxFee;
        uint256 nonce;
        uint256 deadline;
        bool partiallyFillable;
    }

    struct WithdrawalRequest {
        address owner;
        address to;
        uint64 assetChainId;
        address asset;
        uint256 amount;
        uint256 maxFee;
        uint256 nonce;
        uint256 deadline;
        bool partiallyFillable;
    }

    struct Reservation {
        uint256 effective;
        uint256 pending;
        uint256 pendingEpoch;
    }

    struct TransferDelta {
        address from;
        address to;
        uint64 assetChainId;
        address asset;
        uint256 amount;
    }

    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(address owner,uint64 sellTokenChainId,address sellToken,uint64 buyTokenChainId,address buyToken,uint256 sellAmount,uint256 buyAmount,address receiver,uint256 expiresAt,bytes32 salt,bool partiallyFillable)"
    );

    bytes32 public constant TRANSFER_REQUEST_TYPEHASH = keccak256(
        "TransferRequest(address owner,address to,uint64 assetChainId,address asset,uint256 amount,uint256 maxFee,uint256 nonce,uint256 deadline,bool partiallyFillable)"
    );

    bytes32 public constant WITHDRAWAL_REQUEST_TYPEHASH = keccak256(
        "WithdrawalRequest(address owner,address to,uint64 assetChainId,address asset,uint256 amount,uint256 maxFee,uint256 nonce,uint256 deadline,bool partiallyFillable)"
    );

    mapping(address user => mapping(uint64 assetChainId => mapping(address asset => uint256))) public balanceOf;
    uint256 public constant EXECUTED = type(uint256).max;

    mapping(bytes32 requestId => uint256 status) public requestStatus;
    mapping(address user => mapping(uint64 assetChainId => mapping(address asset => Reservation))) public reservation;

    mapping(bytes32 orderHash => uint256) public filledAmount;
    mapping(address owner => mapping(bytes32 orderHash => uint256 epoch)) public cancelledFrom;
    mapping(bytes32 orderHash => bool) public preApproved;

    uint256 public settlementEpoch;
    uint256 public lastEpochAdvancedAt;

    event Transfer(address indexed from, address indexed to, uint64 assetChainId, address indexed asset, uint256 amount);
    event EpochAdvanced(uint256 epoch);
    event OrderCancellationRequested(address indexed owner, bytes32 indexed orderHash, uint256 effectiveAtEpoch);
    event PreApproved(address indexed owner, bytes32 indexed orderHash, Order order);
    event TransferRequested(bytes32 indexed requestId, TransferRequest request, uint256 effectiveAtEpoch);
    event TransferExecuted(bytes32 indexed requestId, uint256 amount);
    event WithdrawalRequested(bytes32 indexed requestId, WithdrawalRequest request, uint256 effectiveAtEpoch);
    event WithdrawalExecuted(bytes32 indexed requestId, uint256 amount);

    error BadSignature();
    error RequestReplay();
    error ZeroAddress();
    error LengthMismatch();
    error EmptyBatch();
    error ChainMismatch(uint64 chainId);
    error BadEpoch(uint256 epoch);
    error NotEffective();
    error NotOwner();
    error InsufficientBalance();
    error NotZeroSum();
    error ExceedsMaxFee();
    error Expired(bytes32 id);
    error Overfill(bytes32 orderHash);
    error NotPartiallyFillable(bytes32 orderHash);
    error Cancelled(bytes32 orderHash);
    error NotPreApproved(bytes32 orderHash);

    constructor(address _authority) MessagingEndpoint(_authority) {
        lastEpochAdvancedAt = block.timestamp;
    }

    /// TODO: Decide the EIP712 domain name and version. Currently "Transit Hub" and "1".
    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return ("Transit Hub", "1");
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparator();
    }

    // ========================================= LEDGER =========================================

    function transferFrom(
        address from,
        address to,
        uint64 assetChainId,
        address asset,
        uint256 amount
    )
        external
        restricted
    {
        _requireNotPaused();
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        if (balanceOf[from][assetChainId][asset] < _reserved(from, assetChainId, asset) + amount) {
            revert InsufficientBalance();
        }
        _transfer(from, to, assetChainId, asset, amount);
    }

    function transferAmong(TransferDelta[] calldata deltas) external restricted {
        _requireNotPaused();
        uint64[] memory chainIds = new uint64[](deltas.length);
        address[] memory assets = new address[](deltas.length);
        uint256[] memory debits = new uint256[](deltas.length);
        uint256[] memory credits = new uint256[](deltas.length);
        uint256 count;
        for (uint256 i; i < deltas.length; i++) {
            TransferDelta calldata delta = deltas[i];
            uint256 j;
            while (j < count && (chainIds[j] != delta.assetChainId || assets[j] != delta.asset)) j++;
            if (j == count) {
                chainIds[j] = delta.assetChainId;
                assets[j] = delta.asset;
                count++;
            }
            if (delta.from != address(0)) {
                if (
                    balanceOf[delta.from][delta.assetChainId][delta.asset]
                        < _reserved(delta.from, delta.assetChainId, delta.asset) + delta.amount
                ) {
                    revert InsufficientBalance();
                }
                debits[j] += delta.amount;
            }
            if (delta.to != address(0)) credits[j] += delta.amount;
            _transfer(delta.from, delta.to, delta.assetChainId, delta.asset, delta.amount);
        }
        for (uint256 j; j < count; j++) {
            if (debits[j] != credits[j]) revert NotZeroSum();
        }
    }

    function advanceEpoch(uint256 epoch) external {
        if (block.timestamp < lastEpochAdvancedAt + 24 hours) _checkCanCall(_msgSender(), _msgData());
        if (epoch != settlementEpoch) revert BadEpoch(epoch);
        settlementEpoch = epoch + 1;
        lastEpochAdvancedAt = block.timestamp;
        emit EpochAdvanced(epoch + 1);
    }

    // ========================================= ORDERS =========================================

    function _requestOrderCancellation(address sender, OrderCancellationRequest memory request) internal {
        if (sender != request.owner) revert NotOwner();
        if (cancelledFrom[sender][request.orderHash] != 0) return;
        uint256 effectiveAtEpoch = settlementEpoch + 1;
        cancelledFrom[sender][request.orderHash] = effectiveAtEpoch;
        emit OrderCancellationRequested(sender, request.orderHash, effectiveAtEpoch);
    }

    function fill(Fill[] calldata fills) external restricted returns (bytes32[] memory orderHashes) {
        if (fills.length == 0) revert EmptyBatch();

        orderHashes = new bytes32[](fills.length);
        for (uint256 i; i < fills.length; i++) {
            Fill calldata fill = fills[i];
            Order calldata order = fill.order;
            bytes32 orderHash = hashOrder(order);
            orderHashes[i] = orderHash;

            if (block.timestamp > order.expiresAt) revert Expired(orderHash);
            uint256 filled = filledAmount[orderHash] + fill.sellFilled;
            if (filled > order.sellAmount) revert Overfill(orderHash);
            if (!order.partiallyFillable && fill.sellFilled != order.sellAmount) {
                revert NotPartiallyFillable(orderHash);
            }
            filledAmount[orderHash] = filled;

            address owner = order.owner;
            // Empty signature: pre-approved order. Otherwise ECDSA.
            if (fill.signature.length == 0) {
                if (!preApproved[orderHash]) revert NotPreApproved(orderHash);
            } else if (ECDSA.recoverCalldata(orderHash, fill.signature) != owner) {
                revert BadSignature();
            }
            uint256 cancelled = cancelledFrom[owner][orderHash];
            if (cancelled != 0 && settlementEpoch >= cancelled) revert Cancelled(orderHash);
        }
    }

    function _preApprove(address sender, Order memory order) internal {
        if (sender != order.owner) revert NotOwner();
        bytes32 orderHash = hashOrder(order);
        preApproved[orderHash] = true;
        emit PreApproved(sender, orderHash, order);
    }

    // ========================================= USER =========================================

    function facilitateTransfer(
        TransferRequest[] calldata requests,
        bytes[] calldata signatures,
        uint256[] calldata fees
    )
        external
        restricted
        nonReentrant
    {
        _requireNotPaused();
        if (requests.length == 0) revert EmptyBatch();
        if (requests.length != signatures.length || requests.length != fees.length) revert LengthMismatch();

        for (uint256 i; i < requests.length; i++) {
            TransferRequest calldata request = requests[i];
            if (request.to == address(0)) revert ZeroAddress();

            bytes32 transferId = hashTransferRequest(request);
            if (requestStatus[transferId] != 0) revert RequestReplay();
            if (!SignatureCheckerLib.isValidSignatureNowCalldata(request.owner, transferId, signatures[i])) {
                revert BadSignature();
            }
            requestStatus[transferId] = EXECUTED;
            emit TransferRequested(transferId, request, settlementEpoch);

            if (block.timestamp > request.deadline) revert Expired(transferId);

            /// TODO: Decide fee recipient. Currently msg.sender.
            if (fees[i] > request.maxFee) revert ExceedsMaxFee();
            if (fees[i] != 0) _transfer(request.owner, msg.sender, request.assetChainId, request.asset, fees[i]);
            _transfer(request.owner, request.to, request.assetChainId, request.asset, request.amount - fees[i]);

            emit TransferExecuted(transferId, request.amount - fees[i]);
        }
    }

    function facilitateWithdraw(
        WithdrawalRequest[] calldata requests,
        bytes[] calldata signatures,
        uint256[] calldata fees,
        uint64 messageGas
    )
        external
        payable
        restricted
        nonReentrant
        returns (bytes32[] memory withdrawIds)
    {
        _requireNotPaused();
        if (requests.length == 0) revert EmptyBatch();
        if (requests.length != signatures.length || requests.length != fees.length) revert LengthMismatch();

        uint64 assetChainId = requests[0].assetChainId;
        withdrawIds = new bytes32[](requests.length);
        TransferMessage[] memory messages = new TransferMessage[](requests.length);

        for (uint256 i; i < requests.length; i++) {
            WithdrawalRequest calldata request = requests[i];
            if (request.assetChainId != assetChainId) revert ChainMismatch(request.assetChainId);

            bytes32 withdrawId = hashWithdrawalRequest(request);
            if (requestStatus[withdrawId] != 0) revert RequestReplay();
            if (!SignatureCheckerLib.isValidSignatureNowCalldata(request.owner, withdrawId, signatures[i])) {
                revert BadSignature();
            }
            requestStatus[withdrawId] = EXECUTED;
            emit WithdrawalRequested(withdrawId, request, settlementEpoch);
            withdrawIds[i] = withdrawId;

            if (block.timestamp > request.deadline) revert Expired(withdrawId);

            /// TODO: Decide fee recipient. Currently msg.sender.
            if (fees[i] > request.maxFee) revert ExceedsMaxFee();
            if (fees[i] != 0) _transfer(request.owner, msg.sender, assetChainId, request.asset, fees[i]);
            uint256 amount = request.amount - fees[i];
            _transfer(request.owner, address(0), assetChainId, request.asset, amount);

            messages[i] = TransferMessage({
                asset: request.asset,
                nonce: ++outboundNonce,
                amount: amount,
                to: request.to
            });

            emit WithdrawalExecuted(withdrawId, amount);
        }

        bytes32 messageId =
            _sendMessage(assetChainId, messageGas, MessageType.Withdrawal, abi.encode(messages));

        for (uint256 i; i < messages.length; i++) {
            emit MessageSent(messageId, messages[i].amount, messages[i].to);
        }
    }

    function _requestTransfer(address sender, TransferRequest memory request) internal {
        if (sender != request.owner) revert NotOwner();
        if (request.to == address(0)) revert ZeroAddress();
        bytes32 requestId = hashTransferRequest(request);
        if (requestStatus[requestId] != 0) revert RequestReplay();

        uint256 effectiveAtEpoch = settlementEpoch + 1;
        requestStatus[requestId] = effectiveAtEpoch;
        _reserve(sender, request.assetChainId, request.asset, request.amount);

        emit TransferRequested(requestId, request, effectiveAtEpoch);
    }

    function executeTransfer(TransferRequest calldata request) external nonReentrant {
        _requireNotPaused();
        bytes32 requestId = hashTransferRequest(request);
        _consumeRequest(requestId);
        _release(request.owner, request.assetChainId, request.asset, request.amount);

        /// TODO: Decide expired-request handling. Currently consumes it and releases the reservation without moving funds.
        if (block.timestamp > request.deadline) {
            emit TransferExecuted(requestId, 0);
            return;
        }

        uint256 amount =
            FixedPointMathLib.min(request.amount, balanceOf[request.owner][request.assetChainId][request.asset]);
        if (!request.partiallyFillable && amount < request.amount) revert InsufficientBalance();
        uint256 fee = FixedPointMathLib.min(request.maxFee, amount);
        if (fee != 0) _transfer(request.owner, msg.sender, request.assetChainId, request.asset, fee);
        amount -= fee;
        _transfer(request.owner, request.to, request.assetChainId, request.asset, amount);

        emit TransferExecuted(requestId, amount);
    }

    function _requestWithdrawal(address sender, WithdrawalRequest memory request) internal {
        if (sender != request.owner) revert NotOwner();
        bytes32 requestId = hashWithdrawalRequest(request);
        if (requestStatus[requestId] != 0) revert RequestReplay();

        uint256 effectiveAtEpoch = settlementEpoch + 1;
        requestStatus[requestId] = effectiveAtEpoch;
        _reserve(sender, request.assetChainId, request.asset, request.amount);

        emit WithdrawalRequested(requestId, request, effectiveAtEpoch);
    }

    function executeWithdrawal(WithdrawalRequest calldata request, uint64 messageGas) external payable nonReentrant {
        _requireNotPaused();
        bytes32 requestId = hashWithdrawalRequest(request);
        _consumeRequest(requestId);
        _release(request.owner, request.assetChainId, request.asset, request.amount);

        /// TODO: Decide expired-request handling. Currently consumes it and releases the reservation without moving funds.
        if (block.timestamp > request.deadline) {
            emit WithdrawalExecuted(requestId, 0);
            return;
        }

        uint256 amount =
            FixedPointMathLib.min(request.amount, balanceOf[request.owner][request.assetChainId][request.asset]);
        if (!request.partiallyFillable && amount < request.amount) revert InsufficientBalance();
        uint256 fee = FixedPointMathLib.min(request.maxFee, amount);
        if (fee != 0) _transfer(request.owner, msg.sender, request.assetChainId, request.asset, fee);
        amount -= fee;
        _transfer(request.owner, address(0), request.assetChainId, request.asset, amount);

        TransferMessage[] memory messages = new TransferMessage[](1);
        messages[0] = TransferMessage({ asset: request.asset, nonce: ++outboundNonce, amount: amount, to: request.to });
        bytes32 messageId =
            _sendMessage(request.assetChainId, messageGas, MessageType.Withdrawal, abi.encode(messages));

        emit MessageSent(messageId, amount, request.to);
        emit WithdrawalExecuted(requestId, amount);
    }

    // ========================================= ADAPTER ========================================

    function _handleMessage(uint64 chainId, MessageType messageType, bytes memory body) internal override {
        if (messageType == MessageType.Deposit) {
            _receiveTransfer(chainId, abi.decode(body, (TransferMessage)));
        } else if (messageType == MessageType.PreApproval) {
            (address owner, Order memory order) = abi.decode(body, (address, Order));
            _preApprove(owner, order);
        } else if (messageType == MessageType.OrderCancellationRequest) {
            (address owner, OrderCancellationRequest memory request) =
                abi.decode(body, (address, OrderCancellationRequest));
            _requestOrderCancellation(owner, request);
        } else if (messageType == MessageType.TransferRequest) {
            (address owner, TransferRequest memory request) = abi.decode(body, (address, TransferRequest));
            _requestTransfer(owner, request);
        } else if (messageType == MessageType.WithdrawalRequest) {
            (address owner, WithdrawalRequest memory request) = abi.decode(body, (address, WithdrawalRequest));
            _requestWithdrawal(owner, request);
        } else {
            assert(false);
        }
    }

    function _receiveTransfer(uint64 sourceChainId, TransferMessage memory message) internal {
        _consume(sourceChainId, message.nonce);

        _requireNotPaused();

        _transfer(address(0), message.to, sourceChainId, message.asset, message.amount);

        emit MessageReceived(bytes32(message.nonce), message.amount, message.to);
    }

    // ========================================= VIEWS =========================================

    function hashOrder(Order memory order) public view returns (bytes32) {
        return _hashTypedData(
            keccak256(
                abi.encode(
                    ORDER_TYPEHASH,
                    order.owner,
                    order.sellTokenChainId,
                    order.sellToken,
                    order.buyTokenChainId,
                    order.buyToken,
                    order.sellAmount,
                    order.buyAmount,
                    order.receiver,
                    order.expiresAt,
                    order.salt,
                    order.partiallyFillable
                )
            )
        );
    }

    function hashTransferRequest(TransferRequest memory request) public view returns (bytes32) {
        return _hashTypedData(
            keccak256(
                abi.encode(
                    TRANSFER_REQUEST_TYPEHASH,
                    request.owner,
                    request.to,
                    request.assetChainId,
                    request.asset,
                    request.amount,
                    request.maxFee,
                    request.nonce,
                    request.deadline,
                    request.partiallyFillable
                )
            )
        );
    }

    function hashWithdrawalRequest(WithdrawalRequest memory request) public view returns (bytes32) {
        return _hashTypedData(
            keccak256(
                abi.encode(
                    WITHDRAWAL_REQUEST_TYPEHASH,
                    request.owner,
                    request.to,
                    request.assetChainId,
                    request.asset,
                    request.amount,
                    request.maxFee,
                    request.nonce,
                    request.deadline,
                    request.partiallyFillable
                )
            )
        );
    }

    // ========================================= INTERNAL =========================================

    function _consumeRequest(bytes32 requestId) internal {
        uint256 status = requestStatus[requestId];
        if (status == 0 || status == EXECUTED || settlementEpoch < status) revert NotEffective();
        requestStatus[requestId] = EXECUTED;
    }

    function _reserved(address user, uint64 assetChainId, address asset) internal view returns (uint256) {
        Reservation storage res = reservation[user][assetChainId][asset];
        if (res.pendingEpoch <= settlementEpoch) return res.effective + res.pending;
        return res.effective;
    }

    function _reserve(address user, uint64 assetChainId, address asset, uint256 amount) internal {
        Reservation storage res = _rollReservation(user, assetChainId, asset);
        res.pending += amount;
        res.pendingEpoch = settlementEpoch + 1;
    }

    function _release(address user, uint64 assetChainId, address asset, uint256 amount) internal {
        _rollReservation(user, assetChainId, asset).effective -= amount;
    }

    function _rollReservation(
        address user,
        uint64 assetChainId,
        address asset
    )
        internal
        returns (Reservation storage res)
    {
        res = reservation[user][assetChainId][asset];
        if (res.pendingEpoch <= settlementEpoch) {
            res.effective += res.pending;
            res.pending = 0;
        }
    }

    function _transfer(address from, address to, uint64 assetChainId, address asset, uint256 amount) internal {
        if (from != address(0)) balanceOf[from][assetChainId][asset] -= amount;
        if (to != address(0)) balanceOf[to][assetChainId][asset] += amount;
        emit Transfer(from, to, assetChainId, asset, amount);
    }

}
