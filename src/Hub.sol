// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { ERC20 } from "solady/tokens/ERC20.sol";
import { EIP712 } from "solady/utils/EIP712.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SignatureCheckerLib } from "solady/utils/SignatureCheckerLib.sol";
import { MessagingEndpoint } from "./messaging/MessagingEndpoint.sol";
import { OrderRegistry } from "./OrderRegistry.sol";

contract Hub is MessagingEndpoint, EIP712 {

    struct TransferRequest {
        address owner;
        address to;
        uint64 assetChainId;
        address asset;
        uint256 amount;
        uint256 nonce;
    }

    struct WithdrawRequest {
        address owner;
        ERC20 asset;
        uint64 assetChainId;
        uint256 amount;
        address to;
        uint256 nonce;
    }

    struct PendingWithdrawal {
        uint256 amount;
        address to;
        uint256 effectiveAtEpoch;
    }

    struct TransferDelta {
        address from;
        address to;
        uint64 assetChainId;
        address asset;
        uint256 amount;
    }

    bytes32 public constant TRANSFER_REQUEST_TYPEHASH = keccak256(
        "TransferRequest(address owner,address to,uint64 assetChainId,address asset,uint256 amount,uint256 nonce)"
    );

    bytes32 public constant WITHDRAW_REQUEST_TYPEHASH = keccak256(
        "WithdrawRequest(address owner,address asset,uint64 assetChainId,uint256 amount,address to,uint256 nonce)"
    );

    mapping(address user => mapping(uint64 assetChainId => mapping(address asset => uint256))) public balanceOf;
    mapping(bytes32 transferId => bool) public transferUsed;
    mapping(bytes32 withdrawId => bool) public withdrawUsed;
    mapping(address user => mapping(uint64 assetChainId => mapping(address asset => PendingWithdrawal))) public
        pendingWithdrawal;

    OrderRegistry public orderRegistry;

    uint256 public settlementEpoch;
    uint256 public lastEpochAdvancedAt;

    event Transfer(address indexed from, address indexed to, uint64 assetChainId, address indexed asset, uint256 amount);
    event Withdraw(bytes32 indexed withdrawId, address indexed asset, address indexed to, uint256 amount);
    event EpochAdvanced(uint256 epoch);
    event OrderRegistryUpdated(address indexed orderRegistry);
    event WithdrawalRequested(
        address indexed owner, uint64 assetChainId, address indexed asset, uint256 amount, address to, uint256 effectiveAtEpoch
    );
    event WithdrawalExecuted(address indexed owner, uint64 assetChainId, address indexed asset, uint256 amount, address to);

    error BadSignature();
    error TransferReplay();
    error WithdrawReplay();
    error ZeroAddress();
    error LengthMismatch();
    error EmptyBatch();
    error ChainMismatch(uint64 chainId);
    error BadEpoch(uint256 epoch);
    error NotEffective();
    error InsufficientBalance();
    error NotZeroSum();

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

    function setOrderRegistry(OrderRegistry _orderRegistry) external restricted {
        orderRegistry = _orderRegistry;
        emit OrderRegistryUpdated(address(_orderRegistry));
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

    // ========================================= USER =========================================

    function transferWithSignature(
        TransferRequest[] calldata requests,
        bytes[] calldata signatures
    )
        external
        restricted
        nonReentrant
    {
        _requireNotPaused();
        if (requests.length == 0) revert EmptyBatch();
        if (requests.length != signatures.length) revert LengthMismatch();

        for (uint256 i; i < requests.length; i++) {
            TransferRequest calldata request = requests[i];
            if (request.to == address(0)) revert ZeroAddress();

            bytes32 transferId = hashTransferRequest(request);
            if (transferUsed[transferId]) revert TransferReplay();
            if (!SignatureCheckerLib.isValidSignatureNowCalldata(request.owner, transferId, signatures[i])) {
                revert BadSignature();
            }
            transferUsed[transferId] = true;

            _transfer(request.owner, request.to, request.assetChainId, request.asset, request.amount);
        }
    }

    function withdrawWithSignature(
        WithdrawRequest[] calldata requests,
        bytes[] calldata signatures,
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
        if (requests.length != signatures.length) revert LengthMismatch();

        uint64 assetChainId = requests[0].assetChainId;
        withdrawIds = new bytes32[](requests.length);
        TransferMessage[] memory messages = new TransferMessage[](requests.length);

        for (uint256 i; i < requests.length; i++) {
            WithdrawRequest calldata request = requests[i];
            if (request.assetChainId != assetChainId) revert ChainMismatch(request.assetChainId);

            bytes32 withdrawId = hashWithdrawRequest(request);
            if (withdrawUsed[withdrawId]) revert WithdrawReplay();
            if (!SignatureCheckerLib.isValidSignatureNowCalldata(request.owner, withdrawId, signatures[i])) {
                revert BadSignature();
            }
            withdrawUsed[withdrawId] = true;
            withdrawIds[i] = withdrawId;

            _transfer(request.owner, address(0), assetChainId, address(request.asset), request.amount);

            messages[i] = TransferMessage({
                asset: address(request.asset),
                nonce: ++outboundNonce,
                amount: request.amount,
                to: request.to
            });

            emit Withdraw(withdrawId, address(request.asset), request.to, request.amount);
        }

        bytes32 messageId =
            _sendMessage(assetChainId, messageGas, MessageType.Withdrawal, abi.encode(messages));

        for (uint256 i; i < messages.length; i++) {
            emit MessageSent(messageId, messages[i].amount, messages[i].to);
        }
    }

    function requestWithdrawal(uint64 assetChainId, address asset, uint256 amount, address to) external {
        uint256 effectiveAtEpoch = settlementEpoch + 1;
        pendingWithdrawal[msg.sender][assetChainId][asset] = PendingWithdrawal(amount, to, effectiveAtEpoch);
        emit WithdrawalRequested(msg.sender, assetChainId, asset, amount, to, effectiveAtEpoch);
    }

    function executeWithdrawal(
        address owner,
        uint64 assetChainId,
        address asset,
        uint64 messageGas
    )
        external
        payable
        nonReentrant
    {
        _requireNotPaused();
        PendingWithdrawal memory pending = pendingWithdrawal[owner][assetChainId][asset];
        if (pending.effectiveAtEpoch == 0 || settlementEpoch < pending.effectiveAtEpoch) revert NotEffective();
        delete pendingWithdrawal[owner][assetChainId][asset];

        uint256 amount = FixedPointMathLib.min(pending.amount, balanceOf[owner][assetChainId][asset]);
        _transfer(owner, address(0), assetChainId, asset, amount);

        TransferMessage[] memory messages = new TransferMessage[](1);
        messages[0] = TransferMessage({ asset: asset, nonce: ++outboundNonce, amount: amount, to: pending.to });
        bytes32 messageId = _sendMessage(assetChainId, messageGas, MessageType.Withdrawal, abi.encode(messages));

        emit MessageSent(messageId, amount, pending.to);
        emit WithdrawalExecuted(owner, assetChainId, asset, amount, pending.to);
    }

    // ========================================= ADAPTER ========================================

    function _handleMessage(uint64 chainId, MessageType messageType, bytes memory body) internal override {
        if (messageType == MessageType.Deposit) {
            _receiveTransfer(chainId, abi.decode(body, (TransferMessage)));
        } else if (messageType == MessageType.PreApproval) {
            (address owner, OrderRegistry.Order memory order) = abi.decode(body, (address, OrderRegistry.Order));
            orderRegistry.preApproveFor(owner, order);
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

    function hashTransferRequest(TransferRequest calldata request) public view returns (bytes32) {
        return _hashTypedData(
            keccak256(
                abi.encode(
                    TRANSFER_REQUEST_TYPEHASH,
                    request.owner,
                    request.to,
                    request.assetChainId,
                    request.asset,
                    request.amount,
                    request.nonce
                )
            )
        );
    }

    function hashWithdrawRequest(WithdrawRequest calldata request) public view returns (bytes32) {
        return _hashTypedData(
            keccak256(
                abi.encode(
                    WITHDRAW_REQUEST_TYPEHASH,
                    request.owner,
                    address(request.asset),
                    request.assetChainId,
                    request.amount,
                    request.to,
                    request.nonce
                )
            )
        );
    }

    // ========================================= INTERNAL =========================================

    function _reserved(address user, uint64 assetChainId, address asset) internal view returns (uint256) {
        PendingWithdrawal storage pending = pendingWithdrawal[user][assetChainId][asset];
        if (pending.effectiveAtEpoch == 0 || settlementEpoch < pending.effectiveAtEpoch) return 0;
        return pending.amount;
    }

    function _transfer(address from, address to, uint64 assetChainId, address asset, uint256 amount) internal {
        if (from != address(0)) balanceOf[from][assetChainId][asset] -= amount;
        if (to != address(0)) balanceOf[to][assetChainId][asset] += amount;
        emit Transfer(from, to, assetChainId, asset, amount);
    }

}
