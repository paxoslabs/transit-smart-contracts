// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IMessagingAdapter } from "./IMessagingAdapter.sol";
import { IMessagingReceiver } from "./IMessagingReceiver.sol";

abstract contract MessagingAdapter is AccessManaged, IMessagingAdapter {

    struct PeerConfig {
        bytes32 peer;
        uint256 remoteId;
        uint64 messageGasLimit;
        uint64 minimumMessageGas;
        bool allowMessagesFrom;
        bool allowMessagesTo;
    }

    address public immutable endpoint;
    uint64 public immutable hubChainId;

    mapping(uint64 chainId => PeerConfig) public peers;
    mapping(uint256 remoteId => uint64 chainId) public chainIdForRemoteId;

    event PeerSet(
        uint64 indexed chainId,
        bytes32 peer,
        uint256 remoteId,
        uint64 messageGasLimit,
        uint64 minimumMessageGas,
        bool allowMessagesFrom,
        bool allowMessagesTo
    );
    event PeerRemoved(uint64 indexed chainId);
    event MessageSent(uint64 indexed chainId, bytes32 indexed messageId, bytes payload);
    event MessageReceived(uint64 indexed chainId, bytes32 sender, bytes payload);

    error OnlyEndpoint();
    error PeerNotSet(uint64 chainId);
    error UnauthorizedPeer(uint64 chainId, bytes32 sender);
    error ZeroMessageGasLimit();
    error GasLimitExceeded();
    error GasTooLow();
    error MessagesNotAllowedFrom(uint64 chainId);
    error MessagesNotAllowedTo(uint64 chainId);

    constructor(
        address _authority,
        address _endpoint,
        uint64 _hubChainId
    )
        AccessManaged(_authority)
    {
        endpoint = _endpoint;
        hubChainId = _hubChainId;
    }

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
        emit PeerSet(
            chainId, peer, remoteId, messageGasLimit, minimumMessageGas, allowMessagesFrom, allowMessagesTo
        );
    }

    function removePeer(uint64 chainId) external restricted {
        delete chainIdForRemoteId[peers[chainId].remoteId];
        delete peers[chainId];
        emit PeerRemoved(chainId);
    }

    function setAllowMessagesFromChain(uint64 chainId, bool allowed) external restricted {
        peers[chainId].allowMessagesFrom = allowed;
    }

    function setAllowMessagesToChain(uint64 chainId, bool allowed) external restricted {
        peers[chainId].allowMessagesTo = allowed;
    }

    function setChainGasLimit(uint64 chainId, uint64 messageGasLimit) external restricted {
        if (messageGasLimit == 0) revert ZeroMessageGasLimit();
        peers[chainId].messageGasLimit = messageGasLimit;
    }

    function send(
        uint64 chainId,
        uint64 gasLimit,
        bytes calldata payload
    )
        external
        payable
        returns (bytes32 messageId)
    {
        if (msg.sender != endpoint) revert OnlyEndpoint();

        PeerConfig memory peer = _peerOf(chainId);
        if (!peer.allowMessagesTo) revert MessagesNotAllowedTo(chainId);
        if (gasLimit > peer.messageGasLimit) revert GasLimitExceeded();
        if (gasLimit < peer.minimumMessageGas) revert GasTooLow();

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

        IMessagingReceiver(endpoint).receiveMessage(chainId, payload);
    }

    function _peerOf(uint64 chainId) internal view returns (PeerConfig memory peer) {
        peer = peers[chainId];
        if (peer.peer == bytes32(0)) revert PeerNotSet(chainId);
    }

}
