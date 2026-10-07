// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";
import { EIP712 } from "solady/utils/EIP712.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SignatureCheckerLib } from "solady/utils/SignatureCheckerLib.sol";
import { Warehouse } from "./Warehouse.sol";
import { IMessagingAdapter } from "./crosschain/IMessagingAdapter.sol";

contract Hub is AccessManaged, EIP712, ReentrancyGuard, Pausable {

    struct WithdrawRequest {
        address owner;
        ERC20 asset;
        uint64 assetChainId;
        uint256 amount;
        address to;
        uint256 nonce;
        uint256 deadline;
    }

    bytes32 public constant WITHDRAW_REQUEST_TYPEHASH = keccak256(
        "WithdrawRequest(address owner,address asset,uint64 assetChainId,uint256 amount,address to,uint256 nonce,uint256 deadline)"
    );

    uint256 public outboundNonce;

    IMessagingAdapter public messagingAdapter;

    mapping(address user => mapping(uint64 assetChainId => mapping(address asset => uint256))) public balanceOf;
    mapping(uint64 chainId => Warehouse.Chain) public chains;
    mapping(uint64 sourceChainId => mapping(uint256 nonce => bool)) public messageConsumed;
    mapping(bytes32 withdrawId => bool) public withdrawUsed;

    event Transfer(address indexed from, address indexed to, uint64 assetChainId, address indexed asset, uint256 amount);
    event MessagingAdapterUpdated(address indexed adapter);
    event ChainAdded(uint64 indexed chainId, Warehouse.Chain chain);
    event ChainRemoved(uint64 indexed chainId);
    event Withdraw(bytes32 indexed withdrawId, address indexed asset, address indexed to, uint256 amount);
    event MessageSent(bytes32 messageId, uint256 shareAmount, address to);
    event MessageReceived(bytes32 messageId, uint256 shareAmount, address to);

    error UnknownSourceChain(uint64 chainId);
    error BadSignature();
    error Expired();
    error WithdrawReplay();
    error MessageReplay();
    error UnknownAdapter();
    error MessagesNotAllowedFrom(uint64 chainId);
    error MessagesNotAllowedTo(uint64 chainId);
    error ZeroAddress();
    error LengthMismatch();
    error ChainMismatch(uint64 chainId);

    constructor(address _authority) AccessManaged(_authority) { }

    /// TODO: Decide the EIP712 domain name and version. Currently "Transit Hub" and "1".
    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return ("Transit Hub", "1");
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparator();
    }

    // ========================================= ADMIN =========================================

    function setMessagingAdapter(IMessagingAdapter adapter) external restricted {
        messagingAdapter = adapter;
        emit MessagingAdapterUpdated(address(adapter));
    }

    function pause() external restricted {
        _pause();
    }

    function unpause() external restricted {
        _unpause();
    }

    function addChain(
        uint64 chainId,
        bool allowMessagesFrom,
        bool allowMessagesTo
    )
        external
        restricted
    {
        if (chainId == 0) revert UnknownSourceChain(chainId);
        Warehouse.Chain memory chain = Warehouse.Chain(allowMessagesFrom, allowMessagesTo, true);
        chains[chainId] = chain;
        emit ChainAdded(chainId, chain);
    }

    function removeChain(uint64 chainId) external restricted {
        delete chains[chainId];
        emit ChainRemoved(chainId);
    }

    function setAllowMessagesFromChain(uint64 chainId, bool allowed) external restricted {
        chains[chainId].allowMessagesFrom = allowed;
    }

    function setAllowMessagesToChain(uint64 chainId, bool allowed) external restricted {
        chains[chainId].allowMessagesTo = allowed;
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
        _transfer(from, to, assetChainId, asset, amount);
    }

    // ========================================= USER =========================================

    function withdrawWithSignature(
        WithdrawRequest[] calldata requests,
        bytes[] calldata signatures,
        Warehouse.BridgeData calldata data
    )
        external
        payable
        restricted
        nonReentrant
        returns (bytes32[] memory withdrawIds)
    {
        _requireNotPaused();
        if (requests.length != signatures.length) revert LengthMismatch();

        uint64 assetChainId = requests[0].assetChainId;
        withdrawIds = new bytes32[](requests.length);
        Warehouse.TransferMessage[] memory messages = new Warehouse.TransferMessage[](requests.length);

        for (uint256 i; i < requests.length; i++) {
            WithdrawRequest calldata request = requests[i];
            if (request.assetChainId != assetChainId) revert ChainMismatch(request.assetChainId);
            if (block.timestamp > request.deadline) revert Expired();

            bytes32 withdrawId = hashWithdrawRequest(request);
            if (withdrawUsed[withdrawId]) revert WithdrawReplay();
            if (!SignatureCheckerLib.isValidSignatureNowCalldata(request.owner, withdrawId, signatures[i])) {
                revert BadSignature();
            }
            withdrawUsed[withdrawId] = true;
            withdrawIds[i] = withdrawId;

            _transfer(request.owner, address(0), assetChainId, address(request.asset), request.amount);

            messages[i] = Warehouse.TransferMessage({
                asset: address(request.asset),
                nonce: ++outboundNonce,
                amount: request.amount,
                to: request.to
            });

            emit Withdraw(withdrawId, address(request.asset), request.to, request.amount);
        }

        _checkRoute(assetChainId);

        bytes memory payload = abi.encode(Warehouse.MessageType.Withdrawal, abi.encode(messages));

        IMessagingAdapter adapter = messagingAdapter;
        if (address(adapter) == address(0)) revert UnknownAdapter();
        bytes32 messageId = adapter.send{ value: msg.value }(assetChainId, data.messageGas, payload);

        for (uint256 i; i < messages.length; i++) {
            emit MessageSent(messageId, messages[i].amount, messages[i].to);
        }
    }

    // ========================================= ADAPTER ========================================

    function receiveMessage(uint64 chainId, bytes calldata payload) external restricted nonReentrant {
        Warehouse.Chain memory chain = chains[chainId];
        if (!chain.registered) revert UnknownSourceChain(chainId);
        if (!chain.allowMessagesFrom) revert MessagesNotAllowedFrom(chainId);

        (Warehouse.MessageType messageType, bytes memory body) = abi.decode(payload, (Warehouse.MessageType, bytes));

        if (messageType == Warehouse.MessageType.Deposit) {
            _receiveTransfer(chainId, abi.decode(body, (Warehouse.TransferMessage)));
        } else {
            assert(false);
        }
    }

    function _receiveTransfer(uint64 sourceChainId, Warehouse.TransferMessage memory message) internal {
        // A revert here leaves the delivery failed in the bridge's queue forever; it is never retried successfully.
        if (messageConsumed[sourceChainId][message.nonce]) revert MessageReplay();
        messageConsumed[sourceChainId][message.nonce] = true;

        _requireNotPaused();

        _transfer(address(0), message.to, sourceChainId, message.asset, message.amount);

        emit MessageReceived(bytes32(message.nonce), message.amount, message.to);
    }

    // ========================================= VIEWS =========================================

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
                    request.nonce,
                    request.deadline
                )
            )
        );
    }

    // ========================================= INTERNAL =========================================

    function _transfer(address from, address to, uint64 assetChainId, address asset, uint256 amount) internal {
        if (from != address(0)) balanceOf[from][assetChainId][asset] -= amount;
        if (to != address(0)) balanceOf[to][assetChainId][asset] += amount;
        emit Transfer(from, to, assetChainId, asset, amount);
    }

    function _checkRoute(uint64 chainId) internal view {
        if (!chains[chainId].allowMessagesTo) revert MessagesNotAllowedTo(chainId);
    }

}
