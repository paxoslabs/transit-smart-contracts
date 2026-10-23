// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { ECDSA } from "solady/utils/ECDSA.sol";
import { EIP712 } from "solady/utils/EIP712.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { DelayedSettlementAssetRegistry } from "./DelayedSettlementAssetRegistry.sol";
import { TransitTokenLib } from "./helpers/TransitTokenLib.sol";
import { MessagingEndpoint } from "./messaging/MessagingEndpoint.sol";

contract Hub is MessagingEndpoint, EIP712 {

    struct Order {
        uint64 ownerChainId;
        address owner;
        bytes32 sellTokenId;
        bytes32 buyTokenId;
        uint256 sellAmount;
        uint256 buyAmount;
        uint64 receiverChainId;
        address receiver;
        uint256 expiresAt;
        bytes32 salt;
        bool partiallyFillable;
    }

    struct Fill {
        uint256 sellFilled;
        uint256 buyFilled;
    }

    /// TODO: Decide fields. The full Order would allow keying cancelledFrom by hash alone.
    struct OrderCancellationRequest {
        uint64 ownerChainId;
        address owner;
        bytes32 orderHash;
        bytes32 sellTokenId;
        uint256 maxFee;
    }

    struct TransferRequest {
        uint64 ownerChainId;
        address owner;
        uint64 toChainId;
        address to;
        bytes32 assetId;
        uint256 amount;
        uint256 maxFee;
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
        uint256 maxFee;
        uint256 nonce;
        uint256 deadline;
        bool partiallyFillable;
    }

    struct MintRequest {
        uint64 ownerChainId;
        address owner;
        bytes32 assetId;
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
        bytes32 fromAccountId;
        bytes32 toAccountId;
        bytes32 assetId;
        uint256 amount;
    }

    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(uint64 ownerChainId,address owner,bytes32 sellTokenId,bytes32 buyTokenId,uint256 sellAmount,uint256 buyAmount,uint64 receiverChainId,address receiver,uint256 expiresAt,bytes32 salt,bool partiallyFillable)"
    );

    bytes32 public constant ORDER_CANCELLATION_REQUEST_TYPEHASH = keccak256(
        "OrderCancellationRequest(uint64 ownerChainId,address owner,bytes32 orderHash,bytes32 sellTokenId,uint256 maxFee)"
    );

    bytes32 public constant TRANSFER_REQUEST_TYPEHASH = keccak256(
        "TransferRequest(uint64 ownerChainId,address owner,uint64 toChainId,address to,bytes32 assetId,uint256 amount,uint256 maxFee,uint256 nonce,uint256 deadline,bool partiallyFillable)"
    );

    bytes32 public constant WITHDRAWAL_REQUEST_TYPEHASH = keccak256(
        "WithdrawalRequest(uint64 ownerChainId,address owner,address to,bytes32 assetId,uint256 amount,uint256 maxFee,uint256 nonce,uint256 deadline,bool partiallyFillable)"
    );

    bytes32 public constant MINT_REQUEST_TYPEHASH = keccak256(
        "MintRequest(uint64 ownerChainId,address owner,bytes32 assetId,uint256 amount,uint256 maxFee,uint256 nonce,uint256 deadline,bool partiallyFillable)"
    );

    mapping(bytes32 accountId => mapping(bytes32 assetId => uint256)) public balanceOf;
    uint256 public constant EXECUTED = type(uint256).max;

    mapping(bytes32 requestId => uint256 status) public requestStatus;
    mapping(bytes32 accountId => mapping(bytes32 assetId => Reservation)) public reservation;

    mapping(bytes32 orderHash => uint256) public filledAmount;
    mapping(bytes32 accountId => mapping(bytes32 orderHash => uint256 epoch)) public cancelledFrom;
    mapping(bytes32 orderHash => bool) public preApproved;

    uint256 public settlementEpoch;
    uint256 public lastEpochAdvancedAt;

    DelayedSettlementAssetRegistry public delayedSettlementAssetRegistry;

    event Transfer(bytes32 indexed fromAccountId, bytes32 indexed toAccountId, bytes32 indexed assetId, uint256 amount);
    event EpochAdvanced(uint256 epoch);
    event OrderCancellationRequested(bytes32 indexed ownerAccountId, bytes32 indexed orderHash, uint256 effectiveAtEpoch);
    event PreApproved(bytes32 indexed ownerAccountId, bytes32 indexed orderHash, Order order);
    event TransferRequested(bytes32 indexed requestId, TransferRequest request, uint256 effectiveAtEpoch);
    event TransferExecuted(bytes32 indexed requestId, uint256 amount);
    event WithdrawalRequested(bytes32 indexed requestId, WithdrawalRequest request, uint256 effectiveAtEpoch);
    event WithdrawalExecuted(bytes32 indexed requestId, uint256 amount);
    event MintRequested(bytes32 indexed requestId, MintRequest request, uint256 effectiveAtEpoch);
    event MintExecuted(bytes32 indexed requestId, uint256 amount);

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
    error FlaggedAssetId();

    constructor(address _authority) MessagingEndpoint(_authority) {
        settlementEpoch = 1;
        lastEpochAdvancedAt = block.timestamp;
    }

    /// TODO: Decide the EIP712 domain name and version. Currently "Transit Hub" and "1".
    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return ("Transit Hub", "1");
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparator();
    }

    function setDelayedSettlementAssetRegistry(DelayedSettlementAssetRegistry registry) external restricted {
        delayedSettlementAssetRegistry = registry;
    }

    // ========================================= LEDGER =========================================

    function transferFrom(
        bytes32 fromAccountId,
        bytes32 toAccountId,
        bytes32 assetId,
        uint256 amount
    )
        external
        restricted
    {
        _requireNotPaused();
        if (fromAccountId == bytes32(0) || toAccountId == bytes32(0)) revert ZeroAddress();
        if (balanceOf[fromAccountId][assetId] < _reserved(fromAccountId, assetId) + amount) revert InsufficientBalance();
        _transfer(fromAccountId, toAccountId, assetId, amount);
    }

    function transferAmong(TransferDelta[] calldata deltas) external restricted {
        _requireNotPaused();
        bytes32[] memory assetIds = new bytes32[](deltas.length);
        uint256[] memory debits = new uint256[](deltas.length);
        uint256[] memory credits = new uint256[](deltas.length);
        uint256 count;
        for (uint256 i; i < deltas.length; i++) {
            TransferDelta calldata delta = deltas[i];
            bytes32 assetId = delta.assetId;
            uint256 j;
            while (j < count && assetIds[j] != assetId) j++;
            if (j == count) {
                assetIds[j] = assetId;
                count++;
            }
            if (delta.fromAccountId != bytes32(0)) {
                if (balanceOf[delta.fromAccountId][assetId] < _reserved(delta.fromAccountId, assetId) + delta.amount) {
                    revert InsufficientBalance();
                }
                debits[j] += delta.amount;
            }
            if (delta.toAccountId != bytes32(0)) credits[j] += delta.amount;
            _transfer(delta.fromAccountId, delta.toAccountId, assetId, delta.amount);
        }
        for (uint256 j; j < count; j++) {
            if (debits[j] != credits[j]) revert NotZeroSum();
        }
    }

    function mint(bytes32 toAccountId, bytes32 assetId, uint256 amount) external restricted {
        _requireNotPaused();
        if (toAccountId == bytes32(0)) revert ZeroAddress();
        _transfer(bytes32(0), toAccountId, assetId, amount);
    }

    function burn(bytes32 fromAccountId, bytes32 assetId, uint256 amount) external restricted {
        _requireNotPaused();
        if (fromAccountId == bytes32(0)) revert ZeroAddress();
        if (balanceOf[fromAccountId][assetId] < _reserved(fromAccountId, assetId) + amount) revert InsufficientBalance();
        _transfer(fromAccountId, bytes32(0), assetId, amount);
    }

    function advanceEpoch(uint256 epoch) external {
        if (block.timestamp < lastEpochAdvancedAt + 24 hours) _checkCanCall(_msgSender(), _msgData());
        if (epoch != settlementEpoch) revert BadEpoch(epoch);
        settlementEpoch = epoch + 1;
        lastEpochAdvancedAt = block.timestamp;
        emit EpochAdvanced(epoch + 1);
    }

    // ========================================= ORDERS =========================================

    function _requestOrderCancellation(bytes32 senderAccountId, OrderCancellationRequest memory request) internal {
        if (senderAccountId != TransitTokenLib.formatAccountId(request.ownerChainId, request.owner)) revert NotOwner();
        if (cancelledFrom[senderAccountId][request.orderHash] != 0) return;
        uint256 effectiveAtEpoch = settlementEpoch + 1;
        cancelledFrom[senderAccountId][request.orderHash] = effectiveAtEpoch;
        emit OrderCancellationRequested(senderAccountId, request.orderHash, effectiveAtEpoch);
    }

    function _preApprove(bytes32 senderAccountId, Order memory order) internal {
        if (senderAccountId != TransitTokenLib.formatAccountId(order.ownerChainId, order.owner)) revert NotOwner();
        bytes32 orderHash = hashOrder(order);
        preApproved[orderHash] = true;
        emit PreApproved(senderAccountId, orderHash, order);
    }

    function facilitateOrderCancellation(
        OrderCancellationRequest[] calldata requests,
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
            OrderCancellationRequest calldata request = requests[i];
            if (TransitTokenLib.hasFlags(request.sellTokenId)) revert FlaggedAssetId();
            bytes32 ownerAccountId = TransitTokenLib.formatAccountId(request.ownerChainId, request.owner);

            bytes32 cancelId = hashOrderCancellationRequest(request);
            if (ECDSA.recoverCalldata(cancelId, signatures[i]) != request.owner) {
                revert BadSignature();
            }
            uint256 cancelled = cancelledFrom[ownerAccountId][request.orderHash];
            if (cancelled != 0 && cancelled <= settlementEpoch) continue;
            if (fees[i] > request.maxFee) revert ExceedsMaxFee();

            cancelledFrom[ownerAccountId][request.orderHash] = settlementEpoch;

            /// TODO: Decide fee recipient. Currently msg.sender.
            if (fees[i] != 0) _transfer(ownerAccountId, _hubAccountId(msg.sender), request.sellTokenId, fees[i]);

            emit OrderCancellationRequested(ownerAccountId, request.orderHash, settlementEpoch);
        }
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
            if (TransitTokenLib.hasFlags(request.assetId)) revert FlaggedAssetId();

            bytes32 transferId = hashTransferRequest(request);
            if (requestStatus[transferId] != 0) revert RequestReplay();
            if (ECDSA.recoverCalldata(transferId, signatures[i]) != request.owner) {
                revert BadSignature();
            }
            requestStatus[transferId] = EXECUTED;
            emit TransferRequested(transferId, request, settlementEpoch);

            if (block.timestamp > request.deadline) revert Expired(transferId);

            bytes32 ownerAccountId = TransitTokenLib.formatAccountId(request.ownerChainId, request.owner);
            /// TODO: Decide fee recipient. Currently msg.sender.
            if (fees[i] > request.maxFee) revert ExceedsMaxFee();
            if (fees[i] != 0) _transfer(ownerAccountId, _hubAccountId(msg.sender), request.assetId, fees[i]);
            _transfer(
                ownerAccountId,
                TransitTokenLib.formatAccountId(request.toChainId, request.to),
                request.assetId,
                request.amount - fees[i]
            );

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

        (uint64 assetChainId,) = TransitTokenLib.parseAssetId(requests[0].assetId);
        withdrawIds = new bytes32[](requests.length);
        WithdrawalMessage[] memory messages = new WithdrawalMessage[](requests.length);

        for (uint256 i; i < requests.length; i++) {
            WithdrawalRequest calldata request = requests[i];
            (uint64 requestChainId, address asset) = TransitTokenLib.parseAssetId(request.assetId);
            if (requestChainId != assetChainId) revert ChainMismatch(requestChainId);
            if (TransitTokenLib.hasFlags(request.assetId)) revert FlaggedAssetId();

            bytes32 withdrawId = hashWithdrawalRequest(request);
            if (requestStatus[withdrawId] != 0) revert RequestReplay();
            if (ECDSA.recoverCalldata(withdrawId, signatures[i]) != request.owner) {
                revert BadSignature();
            }
            requestStatus[withdrawId] = EXECUTED;
            emit WithdrawalRequested(withdrawId, request, settlementEpoch);
            withdrawIds[i] = withdrawId;

            if (block.timestamp > request.deadline) revert Expired(withdrawId);

            bytes32 ownerAccountId = TransitTokenLib.formatAccountId(request.ownerChainId, request.owner);
            /// TODO: Decide fee recipient. Currently msg.sender.
            if (fees[i] > request.maxFee) revert ExceedsMaxFee();
            if (fees[i] != 0) _transfer(ownerAccountId, _hubAccountId(msg.sender), request.assetId, fees[i]);
            uint256 amount = request.amount - fees[i];
            _transfer(ownerAccountId, bytes32(0), request.assetId, amount);

            messages[i] = WithdrawalMessage({
                asset: asset,
                nonce: ++outboundNonce,
                amount: amount,
                to: request.to
            });

            emit WithdrawalExecuted(withdrawId, amount);
        }

        _sendMessage(assetChainId, messageGas, MessageType.Withdrawal, abi.encode(messages));
    }

    function facilitateFill(
        Order[] calldata orders,
        bytes[] calldata signatures,
        Fill[] calldata fills
    )
        external
        restricted
        returns (bytes32[] memory orderHashes)
    {
        if (orders.length == 0) revert EmptyBatch();
        if (orders.length != signatures.length || orders.length != fills.length) revert LengthMismatch();

        orderHashes = new bytes32[](orders.length);
        for (uint256 i; i < orders.length; i++) {
            Order calldata order = orders[i];
            bytes32 orderHash = hashOrder(order);
            orderHashes[i] = orderHash;

            if (block.timestamp > order.expiresAt) revert Expired(orderHash);
            uint256 sellFilled = fills[i].sellFilled;
            uint256 filled = filledAmount[orderHash] + sellFilled;
            if (filled > order.sellAmount) revert Overfill(orderHash);
            if (!order.partiallyFillable && sellFilled != order.sellAmount) revert NotPartiallyFillable(orderHash);
            filledAmount[orderHash] = filled;

            // Empty signature: pre-approved order. Otherwise ECDSA.
            if (signatures[i].length == 0) {
                if (!preApproved[orderHash]) revert NotPreApproved(orderHash);
            } else if (ECDSA.recoverCalldata(orderHash, signatures[i]) != order.owner) {
                revert BadSignature();
            }
            uint256 cancelled =
                cancelledFrom[TransitTokenLib.formatAccountId(order.ownerChainId, order.owner)][orderHash];
            if (cancelled != 0 && settlementEpoch >= cancelled) revert Cancelled(orderHash);
        }
    }

    function _requestTransfer(bytes32 senderAccountId, TransferRequest memory request) internal {
        if (senderAccountId != TransitTokenLib.formatAccountId(request.ownerChainId, request.owner)) revert NotOwner();
        if (request.to == address(0)) revert ZeroAddress();
        if (TransitTokenLib.hasFlags(request.assetId)) revert FlaggedAssetId();
        bytes32 requestId = hashTransferRequest(request);
        if (requestStatus[requestId] != 0) revert RequestReplay();

        uint256 effectiveAtEpoch = settlementEpoch + 1;
        requestStatus[requestId] = effectiveAtEpoch;
        _reserve(senderAccountId, request.assetId, request.amount);

        emit TransferRequested(requestId, request, effectiveAtEpoch);
    }

    function executeTransfer(TransferRequest calldata request) external nonReentrant {
        _requireNotPaused();
        bytes32 requestId = hashTransferRequest(request);
        _consumeRequest(requestId);
        bytes32 assetId = request.assetId;
        bytes32 ownerAccountId = TransitTokenLib.formatAccountId(request.ownerChainId, request.owner);
        _release(ownerAccountId, assetId, request.amount);

        /// TODO: Decide expired-request handling. Currently consumes it and releases the reservation without moving funds.
        if (block.timestamp > request.deadline) {
            emit TransferExecuted(requestId, 0);
            return;
        }

        uint256 amount = FixedPointMathLib.min(request.amount, balanceOf[ownerAccountId][assetId]);
        if (!request.partiallyFillable && amount < request.amount) revert InsufficientBalance();
        uint256 fee = FixedPointMathLib.min(request.maxFee, amount);
        if (fee != 0) _transfer(ownerAccountId, _hubAccountId(msg.sender), assetId, fee);
        amount -= fee;
        _transfer(ownerAccountId, TransitTokenLib.formatAccountId(request.toChainId, request.to), assetId, amount);

        emit TransferExecuted(requestId, amount);
    }

    function _requestWithdrawal(bytes32 senderAccountId, WithdrawalRequest memory request) internal {
        if (senderAccountId != TransitTokenLib.formatAccountId(request.ownerChainId, request.owner)) revert NotOwner();
        if (TransitTokenLib.hasFlags(request.assetId)) revert FlaggedAssetId();
        bytes32 requestId = hashWithdrawalRequest(request);
        if (requestStatus[requestId] != 0) revert RequestReplay();

        uint256 effectiveAtEpoch = settlementEpoch + 1;
        requestStatus[requestId] = effectiveAtEpoch;
        _reserve(senderAccountId, request.assetId, request.amount);

        emit WithdrawalRequested(requestId, request, effectiveAtEpoch);
    }

    function executeWithdrawal(WithdrawalRequest calldata request, uint64 messageGas) external payable nonReentrant {
        _requireNotPaused();
        bytes32 requestId = hashWithdrawalRequest(request);
        _consumeRequest(requestId);
        bytes32 assetId = request.assetId;
        bytes32 ownerAccountId = TransitTokenLib.formatAccountId(request.ownerChainId, request.owner);
        _release(ownerAccountId, assetId, request.amount);

        /// TODO: Decide expired-request handling. Currently consumes it and releases the reservation without moving funds.
        if (block.timestamp > request.deadline) {
            emit WithdrawalExecuted(requestId, 0);
            return;
        }

        uint256 amount = FixedPointMathLib.min(request.amount, balanceOf[ownerAccountId][assetId]);
        if (!request.partiallyFillable && amount < request.amount) revert InsufficientBalance();
        uint256 fee = FixedPointMathLib.min(request.maxFee, amount);
        if (fee != 0) _transfer(ownerAccountId, _hubAccountId(msg.sender), assetId, fee);
        amount -= fee;
        _transfer(ownerAccountId, bytes32(0), assetId, amount);

        WithdrawalMessage[] memory messages = new WithdrawalMessage[](1);
        (uint64 assetChainId, address asset) = TransitTokenLib.parseAssetId(assetId);
        messages[0] = WithdrawalMessage({ asset: asset, nonce: ++outboundNonce, amount: amount, to: request.to });
        _sendMessage(assetChainId, messageGas, MessageType.Withdrawal, abi.encode(messages));

        emit WithdrawalExecuted(requestId, amount);
    }

    function _requestMint(bytes32 senderAccountId, MintRequest memory request) internal {
        if (senderAccountId != TransitTokenLib.formatAccountId(request.ownerChainId, request.owner)) revert NotOwner();
        if (TransitTokenLib.hasFlags(request.assetId)) revert FlaggedAssetId();
        bytes32 requestId = hashMintRequest(request);
        if (requestStatus[requestId] != 0) revert RequestReplay();

        uint256 effectiveAtEpoch = settlementEpoch + 1;
        requestStatus[requestId] = effectiveAtEpoch;
        _reserve(senderAccountId, request.assetId, request.amount);

        emit MintRequested(requestId, request, effectiveAtEpoch);
    }

    function executeMint(MintRequest calldata request) external nonReentrant {
        _requireNotPaused();
        bytes32 requestId = hashMintRequest(request);
        _consumeRequest(requestId);
        bytes32 assetId = request.assetId;
        bytes32 ownerAccountId = TransitTokenLib.formatAccountId(request.ownerChainId, request.owner);
        _release(ownerAccountId, assetId, request.amount);

        /// TODO: Decide expired-request handling. Currently consumes it and releases the reservation without moving funds.
        if (block.timestamp > request.deadline) {
            emit MintExecuted(requestId, 0);
            return;
        }

        uint256 amount = FixedPointMathLib.min(request.amount, balanceOf[ownerAccountId][assetId]);
        if (!request.partiallyFillable && amount < request.amount) revert InsufficientBalance();
        uint256 fee = FixedPointMathLib.min(request.maxFee, amount);
        if (fee != 0) _transfer(ownerAccountId, _hubAccountId(msg.sender), assetId, fee);
        amount -= fee;
        delayedSettlementAssetRegistry.mint(ownerAccountId, assetId, amount);

        emit MintExecuted(requestId, amount);
    }

    // ========================================= ADAPTER ========================================

    function _handleMessage(uint64 chainId, MessageType messageType, bytes memory body) internal override {
        if (messageType == MessageType.Deposit) {
            _receiveDeposit(chainId, abi.decode(body, (DepositMessage)));
        } else if (messageType == MessageType.PreApproval) {
            (address owner, Order memory order) = abi.decode(body, (address, Order));
            _preApprove(TransitTokenLib.formatAccountId(chainId, owner), order);
        } else if (messageType == MessageType.OrderCancellationRequest) {
            (address owner, OrderCancellationRequest memory request) =
                abi.decode(body, (address, OrderCancellationRequest));
            _requestOrderCancellation(TransitTokenLib.formatAccountId(chainId, owner), request);
        } else if (messageType == MessageType.TransferRequest) {
            (address owner, TransferRequest memory request) = abi.decode(body, (address, TransferRequest));
            _requestTransfer(TransitTokenLib.formatAccountId(chainId, owner), request);
        } else if (messageType == MessageType.WithdrawalRequest) {
            (address owner, WithdrawalRequest memory request) = abi.decode(body, (address, WithdrawalRequest));
            _requestWithdrawal(TransitTokenLib.formatAccountId(chainId, owner), request);
        } else if (messageType == MessageType.MintRequest) {
            (address owner, MintRequest memory request) = abi.decode(body, (address, MintRequest));
            _requestMint(TransitTokenLib.formatAccountId(chainId, owner), request);
        } else {
            assert(false);
        }
    }

    function _receiveDeposit(uint64 sourceChainId, DepositMessage memory message) internal {
        _consume(sourceChainId, message.nonce);

        _requireNotPaused();

        _transfer(
            bytes32(0),
            message.toAccountId,
            TransitTokenLib.formatAssetId(sourceChainId, message.asset),
            message.amount
        );
    }

    // ========================================= VIEWS =========================================

    function hashOrder(Order memory order) public view returns (bytes32) {
        return _hashTypedData(
            keccak256(
                abi.encode(
                    ORDER_TYPEHASH,
                    order.ownerChainId,
                    order.owner,
                    order.sellTokenId,
                    order.buyTokenId,
                    order.sellAmount,
                    order.buyAmount,
                    order.receiverChainId,
                    order.receiver,
                    order.expiresAt,
                    order.salt,
                    order.partiallyFillable
                )
            )
        );
    }

    function hashOrderCancellationRequest(OrderCancellationRequest memory request) public view returns (bytes32) {
        return _hashTypedData(
            keccak256(
                abi.encode(
                    ORDER_CANCELLATION_REQUEST_TYPEHASH,
                    request.ownerChainId,
                    request.owner,
                    request.orderHash,
                    request.sellTokenId,
                    request.maxFee
                )
            )
        );
    }

    function hashTransferRequest(TransferRequest memory request) public view returns (bytes32) {
        return _hashTypedData(
            keccak256(
                abi.encode(
                    TRANSFER_REQUEST_TYPEHASH,
                    request.ownerChainId,
                    request.owner,
                    request.toChainId,
                    request.to,
                    request.assetId,
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
                    request.ownerChainId,
                    request.owner,
                    request.to,
                    request.assetId,
                    request.amount,
                    request.maxFee,
                    request.nonce,
                    request.deadline,
                    request.partiallyFillable
                )
            )
        );
    }

    function hashMintRequest(MintRequest memory request) public view returns (bytes32) {
        return _hashTypedData(
            keccak256(
                abi.encode(
                    MINT_REQUEST_TYPEHASH,
                    request.ownerChainId,
                    request.owner,
                    request.assetId,
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

    function _reserved(bytes32 accountId, bytes32 assetId) internal view returns (uint256) {
        Reservation storage res = reservation[accountId][assetId];
        if (res.pendingEpoch <= settlementEpoch) return res.effective + res.pending;
        return res.effective;
    }

    function _reserve(bytes32 accountId, bytes32 assetId, uint256 amount) internal {
        Reservation storage res = _rollReservation(accountId, assetId);
        res.pending += amount;
        res.pendingEpoch = settlementEpoch + 1;
    }

    function _release(bytes32 accountId, bytes32 assetId, uint256 amount) internal {
        _rollReservation(accountId, assetId).effective -= amount;
    }

    function _rollReservation(bytes32 accountId, bytes32 assetId) internal returns (Reservation storage res) {
        res = reservation[accountId][assetId];
        if (res.pendingEpoch <= settlementEpoch) {
            res.effective += res.pending;
            res.pending = 0;
        }
    }

    function _transfer(bytes32 fromAccountId, bytes32 toAccountId, bytes32 assetId, uint256 amount) internal {
        if (fromAccountId != bytes32(0)) balanceOf[fromAccountId][assetId] -= amount;
        if (toAccountId != bytes32(0)) balanceOf[toAccountId][assetId] += amount;
        emit Transfer(fromAccountId, toAccountId, assetId, amount);
    }

    function _hubAccountId(address account) internal view returns (bytes32) {
        return TransitTokenLib.formatAccountId(uint64(block.chainid), account);
    }

}
