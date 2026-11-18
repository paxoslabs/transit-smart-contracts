// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { CCIPReceiver } from "@chainlink/contracts-ccip/applications/CCIPReceiver.sol";
import { IRouterClient } from "@chainlink/contracts-ccip/interfaces/IRouterClient.sol";
import { Client } from "@chainlink/contracts-ccip/libraries/Client.sol";
import { ExtraArgsCodec } from "@chainlink/contracts-ccip/libraries/ExtraArgsCodec.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";
import { MessagingAdapter } from "src/messaging/MessagingAdapter.sol";

contract CCIPMessagingAdapter is MessagingAdapter, CCIPReceiver {

    constructor(
        address _authority,
        address _localTurnstile,
        uint64 _hubChainId,
        address _router
    )
        MessagingAdapter(_authority, _localTurnstile, _hubChainId)
        CCIPReceiver(_router)
    { }

    function _quote(
        uint64,
        uint64 gasLimit,
        PeerConfig memory peer,
        bytes calldata payload
    )
        internal
        view
        override
        returns (uint256 bridgeFee)
    {
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
        /// TODO: Decide whether to refund overpayment. The router keeps all of msg.value; refunding needs an on-chain
        /// getFee here and a refund path back through Turnstile to its caller.
        return IRouterClient(getRouter()).ccipSend{ value: msg.value }(
            uint64(peer.remoteId), _buildMessage(peer, gasLimit, payload)
        );
    }

    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        _receive(chainIdForRemoteId[message.sourceChainSelector], bytes32(message.sender), message.data);
    }

    /// @dev extraArgs are GenericExtraArgsV3 (contracts-ccip v2.0.0 ExtraArgsCodec) requesting the Fast Confirmation
    /// Rule: the message is sent once the source block reaches the `safe` head rather than full finality. V2 extraArgs
    /// cannot request finality. V3 has no ordering flag; messages don't need ordering. Each lane must allow this
    /// finality or the send reverts. V3's gasLimit is uint32, so a larger gasLimit reverts.
    /// NOTE: a reorg past an FCR-confirmed block (requires FCR's assumptions to fail) after a deposit or withdrawal
    /// message is sent would leave the hub balance or the spoke release unbacked.
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
            extraArgs: ExtraArgsCodec._getBasicEncodedExtraArgsV3FastConfirmationRule(SafeCastLib.toUint32(gasLimit))
        });
    }

}
