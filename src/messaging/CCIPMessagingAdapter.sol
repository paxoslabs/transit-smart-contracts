// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { CCIPReceiver } from "@chainlink/contracts-ccip/applications/CCIPReceiver.sol";
import { IRouterClient } from "@chainlink/contracts-ccip/interfaces/IRouterClient.sol";
import { Client } from "@chainlink/contracts-ccip/libraries/Client.sol";
import { MessagingAdapter } from "./MessagingAdapter.sol";

contract CCIPMessagingAdapter is MessagingAdapter, CCIPReceiver {

    constructor(
        address _authority,
        address _endpoint,
        address _localEndpoint,
        address _router
    )
        MessagingAdapter(_authority, _endpoint, _localEndpoint)
        CCIPReceiver(_router)
    { }

    function quote(
        uint64 chainId,
        uint64 gasLimit,
        bytes calldata payload
    )
        external
        view
        override
        returns (uint256 fee)
    {
        PeerConfig memory peer = _peerOf(chainId);
        return IRouterClient(getRouter()).getFee(uint64(peer.remoteId), _buildMessage(peer, gasLimit, payload));
    }

    function _send(
        uint64,
        uint64 gasLimit,
        PeerConfig memory peer,
        bytes calldata payload
    )
        internal
        override
        returns (bytes32 messageId)
    {
        return IRouterClient(getRouter()).ccipSend{ value: msg.value }(
            uint64(peer.remoteId), _buildMessage(peer, gasLimit, payload)
        );
    }

    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        _receive(chainIdForRemoteId[message.sourceChainSelector], bytes32(message.sender), message.data);
    }

    /// TODO: Decide extraArgs. Currently legacy GenericExtraArgsV2 with allowOutOfOrderExecution = true (Warehouse
    /// nonces don't need ordering). CCIP v2.0 lanes also accept GenericExtraArgsV3 (finality config, custom CCVs).
    function _buildMessage(
        PeerConfig memory peer,
        uint64 gasLimit,
        bytes calldata payload
    )
        internal
        pure
        returns (Client.EVM2AnyMessage memory)
    {
        return Client.EVM2AnyMessage({
            receiver: abi.encode(peer.peer),
            data: payload,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: address(0),
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({ gasLimit: gasLimit, allowOutOfOrderExecution: true })
            )
        });
    }

}
