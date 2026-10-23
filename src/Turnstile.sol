// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { Hub } from "./Hub.sol";
import { Warehouse } from "./Warehouse.sol";
import { TransitTokenLib } from "./helpers/TransitTokenLib.sol";
import { MessagingEndpoint } from "./messaging/MessagingEndpoint.sol";

contract Turnstile is MessagingEndpoint {

    address public immutable HUB;
    address public immutable WAREHOUSE;

    mapping(address target => mapping(bytes4 selector => bool)) public routable;
    mapping(bytes32 messageHash => bool) public failed;

    event MessageFailed(
        uint64 indexed sourceChainId, MessageType indexed messageType, bytes32 messageHash, bytes body
    );
    event MessageRetried(uint64 indexed sourceChainId, MessageType indexed messageType, bytes32 messageHash);

    error OutOfGas();
    error NotRoutable();
    error NotFailed();
    error NoHandler();
    error NoFee();

    constructor(address _authority, address _hub, address _warehouse) MessagingEndpoint(_authority) {
        HUB = _hub;
        WAREHOUSE = _warehouse;
    }

    function setRoutable(address target, bytes4[] calldata selectors, bool allowed) external restricted {
        for (uint256 i; i < selectors.length; i++) {
            routable[target][selectors[i]] = allowed;
        }
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

    function _handleMessage(uint64 chainId, MessageType messageType, bytes memory body) internal override {
        _requireNotPaused();
        _consume(keccak256(abi.encode(chainId, messageType, body)));
        _execute(chainId, messageType, body);
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
