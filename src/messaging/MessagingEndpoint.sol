// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { IMessagingAdapter } from "./IMessagingAdapter.sol";
import { IMessagingEndpoint } from "./IMessagingEndpoint.sol";

abstract contract MessagingEndpoint is AccessManaged, Pausable, ReentrancyGuard, IMessagingEndpoint {

    enum MessageType {
        Deposit,
        Withdrawal,
        Generic
    }

    struct DepositMessage {
        address asset;
        uint256 nonce;
        uint256 amount;
        bytes32 toAccountId;
    }

    struct GenericMessage {
        uint256 nonce;
        address sender;
        address target;
        bytes data;
    }

    struct WithdrawalMessage {
        address asset;
        uint256 nonce;
        uint256 amount;
        address to;
    }

    IMessagingAdapter public messagingAdapter;
    uint256 public outboundNonce;

    mapping(uint64 sourceChainId => mapping(uint256 nonce => bool)) public messageConsumed;

    event MessagingAdapterUpdated(address indexed adapter);

    error MessageReplay();
    error UnknownAdapter();

    constructor(address _authority) AccessManaged(_authority) { }

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

    // ========================================= ADAPTER ========================================

    function receiveMessage(uint64 chainId, bytes calldata payload) external restricted nonReentrant {
        (MessageType messageType, bytes memory body) = abi.decode(payload, (MessageType, bytes));
        _handleMessage(chainId, messageType, body);
    }

    function _handleMessage(uint64 chainId, MessageType messageType, bytes memory body) internal virtual;

    function _sendMessage(
        uint64 chainId,
        uint64 messageGas,
        MessageType messageType,
        bytes memory body
    )
        internal
        returns (bytes32 messageId)
    {
        IMessagingAdapter adapter = messagingAdapter;
        if (address(adapter) == address(0)) revert UnknownAdapter();
        messageId = adapter.send{ value: msg.value }(chainId, messageGas, abi.encode(messageType, body));
    }

    function _consume(uint64 sourceChainId, uint256 nonce) internal {
        // A revert here leaves the delivery failed in the bridge's queue forever; it is never retried successfully.
        if (messageConsumed[sourceChainId][nonce]) revert MessageReplay();
        messageConsumed[sourceChainId][nonce] = true;
    }

}
