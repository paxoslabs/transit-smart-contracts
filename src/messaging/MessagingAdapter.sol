// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IMessagingAdapter } from "src/interfaces/IMessagingAdapter.sol";
import { IMessagingReceiver } from "src/interfaces/IMessagingReceiver.sol";

abstract contract MessagingAdapter is AccessManaged, IMessagingAdapter {

    /// @inheritdoc IMessagingAdapter
    address public immutable LOCAL_TURNSTILE;
    /// @inheritdoc IMessagingAdapter
    uint64 public immutable HUB_CHAIN_ID;

    /// @inheritdoc IMessagingAdapter
    mapping(uint64 chainId => PeerConfig) public peers;
    /// @inheritdoc IMessagingAdapter
    mapping(uint256 remoteId => uint64 chainId) public chainIdForRemoteId;

    constructor(address _authority, address _localTurnstile, uint64 _hubChainId) AccessManaged(_authority) {
        LOCAL_TURNSTILE = _localTurnstile;
        HUB_CHAIN_ID = _hubChainId;
    }

    /// @inheritdoc IMessagingAdapter
    function setPeer(
        uint64 chainId,
        bytes32 peer,
        uint256 remoteId,
        uint64 messageGasLimit,
        uint64 minimumMessageGas,
        bool allowMessagesFrom,
        bool allowMessagesTo
    )
        external
        restricted
    {
        if (messageGasLimit == 0) revert ZeroMessageGasLimit();
        peers[chainId] =
            PeerConfig(peer, remoteId, messageGasLimit, minimumMessageGas, allowMessagesFrom, allowMessagesTo);
        chainIdForRemoteId[remoteId] = chainId;
        emit PeerSet(chainId, peer, remoteId, messageGasLimit, minimumMessageGas, allowMessagesFrom, allowMessagesTo);
        emit ChainGasLimitSet(chainId, messageGasLimit);
        emit AllowMessagesFromChainSet(chainId, allowMessagesFrom);
        emit AllowMessagesToChainSet(chainId, allowMessagesTo);
    }

    /// @inheritdoc IMessagingAdapter
    function removePeer(uint64 chainId) external restricted {
        delete chainIdForRemoteId[peers[chainId].remoteId];
        delete peers[chainId];
        emit PeerRemoved(chainId);
    }

    /// @inheritdoc IMessagingAdapter
    function setAllowMessagesFromChain(uint64 chainId, bool allowed) external restricted {
        peers[chainId].allowMessagesFrom = allowed;
        emit AllowMessagesFromChainSet(chainId, allowed);
    }

    /// @inheritdoc IMessagingAdapter
    function setAllowMessagesToChain(uint64 chainId, bool allowed) external restricted {
        peers[chainId].allowMessagesTo = allowed;
        emit AllowMessagesToChainSet(chainId, allowed);
    }

    /// @inheritdoc IMessagingAdapter
    function setChainGasLimit(uint64 chainId, uint64 messageGasLimit) external restricted {
        if (messageGasLimit == 0) revert ZeroMessageGasLimit();
        peers[chainId].messageGasLimit = messageGasLimit;
        emit ChainGasLimitSet(chainId, messageGasLimit);
    }

    /// @inheritdoc IMessagingAdapter
    function send(uint64 chainId, uint64 gasLimit, bytes calldata payload)
        external
        payable
        returns (bytes32 messageId)
    {
        if (msg.sender != LOCAL_TURNSTILE) revert OnlyLocalTurnstile();

        PeerConfig memory peer = _validateOutboundAndGetPeer(chainId, gasLimit);
        messageId = _send(chainId, gasLimit, peer, payload);

        emit MessageSent(chainId, messageId, payload);
    }

    function _send(
        uint64 chainId,
        uint64 gasLimit,
        PeerConfig memory peer,
        bytes calldata payload
    )
        internal
        virtual
        returns (bytes32 messageId);

    function _receive(uint64 chainId, bytes32 sender, bytes memory payload) internal {
        PeerConfig memory peer = _peerOf(chainId);
        if (peer.peer != sender) revert UnauthorizedPeer(chainId, sender);
        if (!peer.allowMessagesFrom) revert MessagesNotAllowedFrom(chainId);

        emit MessageReceived(chainId, sender, payload);

        IMessagingReceiver(LOCAL_TURNSTILE).handleReceivedMessage(chainId, payload);
    }

    function _peerOf(uint64 chainId) internal view returns (PeerConfig memory peer) {
        peer = peers[chainId];
        if (peer.peer == bytes32(0)) revert PeerNotSet(chainId);
    }

    /// @dev Returns the chain's peer after checking a message may be sent to it: the peer is set, sending is allowed,
    /// and gasLimit is within [minimumMessageGas, messageGasLimit]. Reverts otherwise.
    function _validateOutboundAndGetPeer(
        uint64 chainId,
        uint64 gasLimit
    )
        internal
        view
        returns (PeerConfig memory peer)
    {
        peer = _peerOf(chainId);
        if (!peer.allowMessagesTo) revert MessagesNotAllowedTo(chainId);
        if (gasLimit > peer.messageGasLimit) revert GasLimitExceeded();
        if (gasLimit < peer.minimumMessageGas) revert GasTooLow();
    }

}
