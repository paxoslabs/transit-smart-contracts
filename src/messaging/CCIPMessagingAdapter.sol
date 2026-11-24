// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { CCIPReceiver } from "@chainlink/contracts-ccip/applications/CCIPReceiver.sol";
import { IRouterClient } from "@chainlink/contracts-ccip/interfaces/IRouterClient.sol";
import { Client } from "@chainlink/contracts-ccip/libraries/Client.sol";
import { ExtraArgsCodec } from "@chainlink/contracts-ccip/libraries/ExtraArgsCodec.sol";
import { FinalityCodec } from "@chainlink/contracts-ccip/libraries/FinalityCodec.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";
import { MessagingAdapter } from "src/messaging/MessagingAdapter.sol";

/**
 * @title CCIPMessagingAdapter
 * @notice MessagingAdapter over Chainlink CCIP. Peers are mapped to CCIP chain selectors through remoteId, and the
 * bridge fee is paid in native gas.
 * @custom:security-contact security@paxoslabs.com
 */
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

    function getCCVsAndFinalityConfig(
        uint64,
        bytes calldata
    )
        external
        pure
        override
        returns (
            address[] memory requiredCCVs,
            address[] memory optionalCCVs,
            uint8 optionalThreshold,
            bytes4 allowedFinalityConfig
        )
    {
        return (new address[](0), new address[](0), 0, FinalityCodec.WAIT_FOR_SAFE_FLAG);
    }

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
        return
            IRouterClient(getRouter())
                .getFee(SafeCastLib.toUint64(peer.remoteId), _buildMessage(peer, gasLimit, payload));
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
        // The router wraps and keeps all of msg.value (underpayment reverts), so overpayment is not refunded and no
        // ETH comes back to this adapter. Overpaid fees go to Chainlink's fee aggregator and are not recoverable.
        return IRouterClient(getRouter()).ccipSend{ value: msg.value }(
            SafeCastLib.toUint64(peer.remoteId), _buildMessage(peer, gasLimit, payload)
        );
    }

    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        _receive(chainIdForRemoteId[message.sourceChainSelector], bytes32(message.sender), message.data);
    }

    /// @dev extraArgs are GenericExtraArgsV3 (contracts-ccip v2.0.0 ExtraArgsCodec) requesting full finality, which
    /// every lane allows. V3 has no ordering flag; messages don't need ordering. V3's gasLimit is uint32, so a larger
    /// gasLimit reverts.
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
            extraArgs: ExtraArgsCodec._getBasicEncodedExtraArgsV3(
                SafeCastLib.toUint32(gasLimit), FinalityCodec.WAIT_FOR_FINALITY_FLAG
            )
        });
    }

}
