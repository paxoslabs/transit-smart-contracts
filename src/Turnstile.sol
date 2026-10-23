// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { Hub } from "./Hub.sol";
import { TransitTokenLib } from "./helpers/TransitTokenLib.sol";
import { IMessagingAdapter } from "./messaging/IMessagingAdapter.sol";
import { MessagingEndpoint } from "./messaging/MessagingEndpoint.sol";

contract Turnstile is MessagingEndpoint {

    /// TODO: Inherit Turnstile into Hub. Removes the circular deployment dependency (Turnstile needs Hub for
    /// deposits, Hub needs Turnstile as its immutable TURNSTILE) and the external call for deposits.
    Hub public immutable HUB;

    mapping(address target => mapping(bytes4 selector => bool)) public routable;
    mapping(bytes32 messageHash => bool) public failed;

    event MessageFailed(
        uint64 indexed sourceChainId, MessageType indexed messageType, bytes32 messageHash, bytes body
    );
    event MessageRetried(uint64 indexed sourceChainId, MessageType indexed messageType, bytes32 messageHash);

    error OutOfGas();
    error NotRoutable();
    error NotFailed();

    constructor(address _authority, Hub _hub) MessagingEndpoint(_authority) {
        HUB = _hub;
    }

    function setRoutable(address target, bytes4[] calldata selectors, bool allowed) external restricted {
        for (uint256 i; i < selectors.length; i++) {
            routable[target][selectors[i]] = allowed;
        }
    }

    function send(
        uint64 chainId,
        uint64 gasLimit,
        bytes calldata payload
    )
        external
        payable
        restricted
        returns (bytes32 messageId)
    {
        IMessagingAdapter adapter = messagingAdapter;
        if (address(adapter) == address(0)) revert UnknownAdapter();
        messageId = adapter.send{ value: msg.value }(chainId, gasLimit, payload);
    }

    function retry(uint64 sourceChainId, MessageType messageType, bytes calldata body) external restricted nonReentrant {
        _requireNotPaused();
        bytes32 messageHash = keccak256(abi.encode(sourceChainId, messageType, body));
        if (!failed[messageHash]) revert NotFailed();
        delete failed[messageHash];
        emit MessageRetried(sourceChainId, messageType, messageHash);
        _execute(sourceChainId, messageType, body);
    }

    function _handleMessage(uint64 chainId, MessageType messageType, bytes memory body) internal override {
        _requireNotPaused();
        if (messageType == MessageType.Deposit) {
            _consume(chainId, abi.decode(body, (DepositMessage)).nonce);
        } else if (messageType == MessageType.Generic) {
            _consume(chainId, abi.decode(body, (GenericMessage)).nonce);
        } else {
            assert(false);
        }
        _execute(chainId, messageType, body);
    }

    function _execute(uint64 sourceChainId, MessageType messageType, bytes memory body) internal {
        bool ok;
        bytes memory result;
        uint256 gasBefore;
        if (messageType == MessageType.Deposit) {
            DepositMessage memory message = abi.decode(body, (DepositMessage));
            gasBefore = gasleft();
            (ok, result) = address(HUB).call(abi.encodeCall(Hub.receiveDeposit, (sourceChainId, message)));
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
