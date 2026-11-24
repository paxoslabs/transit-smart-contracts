// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { Client } from "@chainlink/contracts-ccip/libraries/Client.sol";
import { MessagingAdapter } from "src/messaging/MessagingAdapter.sol";

contract MessagingAdapterHarness is MessagingAdapter {

    uint256 public sendCount;
    uint64 public lastChainId;
    uint64 public lastGasLimit;
    bytes32 public lastPeer;
    bytes public lastPayload;
    uint256 public lastValue;

    constructor(
        address _authority,
        address _localTurnstile,
        uint64 _hubChainId
    )
        MessagingAdapter(_authority, _localTurnstile, _hubChainId)
    { }

    function $_receive(uint64 chainId, bytes32 sender, bytes memory payload) external {
        _receive(chainId, sender, payload);
    }

    function _send(
        uint64 chainId,
        uint64 gasLimit,
        PeerConfig memory peer,
        bytes calldata payload
    )
        internal
        override
        returns (bytes32 messageId)
    {
        sendCount++;
        lastChainId = chainId;
        lastGasLimit = gasLimit;
        lastPeer = peer.peer;
        lastPayload = payload;
        lastValue = msg.value;
        return keccak256(abi.encode(sendCount));
    }

    function _quote(
        uint64 chainId,
        uint64 gasLimit,
        PeerConfig memory peer,
        bytes calldata payload
    )
        internal
        pure
        override
        returns (uint256 bridgeFee)
    {
        return uint256(keccak256(abi.encode(chainId, gasLimit, peer.peer, payload))) >> 128;
    }

}

contract MockMessagingReceiver {

    error Boom();

    bool public shouldRevert;
    uint256 public callCount;
    uint64 public lastChainId;
    bytes public lastPayload;

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function handleReceivedMessage(uint64 chainId, bytes calldata payload) external {
        if (shouldRevert) revert Boom();
        callCount++;
        lastChainId = chainId;
        lastPayload = payload;
    }

}

contract MockCCIPRouter {

    error Boom();

    bytes32 public constant MESSAGE_ID = keccak256("messageId");

    bool public shouldRevert;
    uint256 public fee;
    uint64 public lastDestinationChainSelector;
    bytes public lastReceiver;
    bytes public lastData;
    uint256 public lastTokenAmountsLength;
    address public lastFeeToken;
    bytes public lastExtraArgs;
    uint256 public lastValue;

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function setFee(uint256 _fee) external {
        fee = _fee;
    }

    function getFee(uint64, Client.EVM2AnyMessage memory message) external view returns (uint256) {
        return fee + uint256(keccak256(abi.encode(message))) % 1000;
    }

    function ccipSend(
        uint64 destinationChainSelector,
        Client.EVM2AnyMessage calldata message
    )
        external
        payable
        returns (bytes32)
    {
        if (shouldRevert) revert Boom();
        lastDestinationChainSelector = destinationChainSelector;
        lastReceiver = message.receiver;
        lastData = message.data;
        lastTokenAmountsLength = message.tokenAmounts.length;
        lastFeeToken = message.feeToken;
        lastExtraArgs = message.extraArgs;
        lastValue = msg.value;
        return MESSAGE_ID;
    }

}

contract ETHRejecter { }
