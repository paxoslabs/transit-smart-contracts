// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { Hub } from "./Hub.sol";
import { ITurnstile } from "./ITurnstile.sol";
import { Warehouse } from "./Warehouse.sol";
import { TransitTokenLib } from "./helpers/TransitTokenLib.sol";
import { IMessagingAdapter } from "./messaging/IMessagingAdapter.sol";

contract Turnstile is AccessManaged, Pausable, ReentrancyGuard, ITurnstile {

    address public immutable HUB;
    address public immutable WAREHOUSE;

    IMessagingAdapter public messagingAdapter;

    mapping(bytes32 messageHash => bool) public messageConsumed;
    mapping(address target => mapping(bytes4 selector => bool)) public routable;
    mapping(bytes32 messageHash => bool) public failed;

    constructor(address _authority, address _hub, address _warehouse) AccessManaged(_authority) {
        HUB = _hub;
        WAREHOUSE = _warehouse;
    }

    // ========================================= ADMIN =========================================

    function setMessagingAdapter(IMessagingAdapter adapter) external restricted {
        messagingAdapter = adapter;
        emit MessagingAdapterUpdated(address(adapter));
    }

    function setRoutable(address target, bytes4[] calldata selectors, bool allowed) external restricted {
        for (uint256 i; i < selectors.length; i++) {
            routable[target][selectors[i]] = allowed;
        }
    }

    function pause() external restricted {
        _pause();
    }

    function unpause() external restricted {
        _unpause();
    }

    function send(
        uint64 chainId,
        uint64 messageGas,
        MessageType messageType,
        bytes calldata body
    )
        external
        payable
        restricted
        returns (bytes32 messageId)
    {
        if (chainId == block.chainid) {
            if (msg.value != 0) revert NoFee();
            messageId = keccak256(abi.encode(messageType, body));
            _handleMessage(chainId, messageType, body);
        } else {
            messageId = _sendMessage(chainId, messageGas, messageType, body);
        }
    }

    function retry(uint64 sourceChainId, MessageType messageType, bytes calldata body) external restricted nonReentrant {
        _requireNotPaused();
        bytes32 messageHash = keccak256(abi.encode(sourceChainId, messageType, body));
        if (!failed[messageHash]) revert NotFailed();
        delete failed[messageHash];
        emit MessageRetried(sourceChainId, messageType, messageHash);
        _execute(sourceChainId, messageType, body);
    }

    // ========================================= ADAPTER ========================================

    function receiveMessage(uint64 chainId, bytes calldata payload) external restricted nonReentrant {
        (MessageType messageType, bytes memory body) = abi.decode(payload, (MessageType, bytes));
        _handleMessage(chainId, messageType, body);
    }

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

    function _handleMessage(uint64 chainId, MessageType messageType, bytes memory body) internal {
        _requireNotPaused();
        _consume(keccak256(abi.encode(chainId, messageType, body)));
        _execute(chainId, messageType, body);
    }

    function _consume(bytes32 messageHash) internal {
        // A revert here leaves the delivery failed in the bridge's queue forever; it is never retried successfully.
        if (messageConsumed[messageHash]) revert MessageReplay();
        messageConsumed[messageHash] = true;
    }

    function _execute(uint64 sourceChainId, MessageType messageType, bytes memory body) internal {
        bool ok;
        bytes memory result;
        uint256 gasBefore;
        if (messageType == MessageType.Deposit) {
            if (HUB == address(0)) revert NoHandler();
            DepositMessage memory message = abi.decode(body, (DepositMessage));
            gasBefore = gasleft();
            (ok, result) = HUB.call(abi.encodeCall(Hub.receiveDeposit, (sourceChainId, message)));
        } else if (messageType == MessageType.Withdrawal) {
            if (WAREHOUSE == address(0)) revert NoHandler();
            WithdrawalMessage[] memory messages = abi.decode(body, (WithdrawalMessage[]));
            gasBefore = gasleft();
            (ok, result) = WAREHOUSE.call(abi.encodeCall(Warehouse.receiveWithdrawal, (messages)));
        } else {
            GenericMessage memory message = abi.decode(body, (GenericMessage));
            if (routable[message.target][bytes4(message.data)]) {
                gasBefore = gasleft();
                (ok, result) = message.target.call(
                    abi.encodePacked(message.data, TransitTokenLib.formatAccountId(sourceChainId, message.sender))
                );
            } else {
                result = abi.encodeWithSelector(NotRoutable.selector);
            }
        }
        if (ok) return;
        if (sourceChainId == block.chainid) {
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }
        if (gasleft() <= gasBefore / 63) revert OutOfGas();
        bytes32 messageHash = keccak256(abi.encode(sourceChainId, messageType, body));
        failed[messageHash] = true;
        emit MessageFailed(sourceChainId, messageType, messageHash, body);
    }

}
