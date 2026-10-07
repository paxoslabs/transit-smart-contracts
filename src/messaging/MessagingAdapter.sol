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
    }

    address public immutable endpoint;
    address public immutable localEndpoint;

    mapping(uint64 chainId => PeerConfig) public peers;
    mapping(uint256 remoteId => uint64 chainId) public chainIdForRemoteId;

    event PeerSet(
        uint64 indexed chainId, bytes32 peer, uint256 remoteId, uint64 messageGasLimit, uint64 minimumMessageGas
    );
    event MessageSent(uint64 indexed chainId, bytes32 indexed messageId, bytes payload);
    event MessageReceived(uint64 indexed chainId, bytes32 sender, bytes payload);

    error OnlyEndpoint();
    error PeerNotSet(uint64 chainId);
    error UnauthorizedPeer(uint64 chainId, bytes32 sender);
    error ZeroMessageGasLimit();
    error GasLimitExceeded();
    error GasTooLow();
    error NoFee();

    constructor(address _authority, address _endpoint, address _localEndpoint) AccessManaged(_authority) {
        endpoint = _endpoint;
        localEndpoint = _localEndpoint;
    }

    function setPeer(
        uint64 chainId,
        bytes32 peer,
        uint256 remoteId,
        uint64 messageGasLimit,
        uint64 minimumMessageGas
    )
        external
        restricted
    {
        if (messageGasLimit == 0) revert ZeroMessageGasLimit();
        peers[chainId] = PeerConfig(peer, remoteId, messageGasLimit, minimumMessageGas);
        chainIdForRemoteId[remoteId] = chainId;
        emit PeerSet(chainId, peer, remoteId, messageGasLimit, minimumMessageGas);
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
        if (chainId == block.chainid) {
            if (msg.value != 0) revert NoFee();

            address target;
            if (msg.sender == endpoint) target = localEndpoint;
            else if (msg.sender == localEndpoint) target = endpoint;
            else revert OnlyEndpoint();

            messageId = keccak256(payload);
            IMessagingReceiver(target).receiveMessage(chainId, payload);
        } else {
            if (msg.sender != endpoint) revert OnlyEndpoint();

            PeerConfig memory peer = _peerOf(chainId);
            if (gasLimit > peer.messageGasLimit) revert GasLimitExceeded();
            if (gasLimit < peer.minimumMessageGas) revert GasTooLow();

            messageId = _send(chainId, gasLimit, peer, payload);
        }

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

        emit MessageReceived(chainId, sender, payload);

        IMessagingReceiver(endpoint).receiveMessage(chainId, payload);
    }

    function _peerOf(uint64 chainId) internal view returns (PeerConfig memory peer) {
        peer = peers[chainId];
        if (peer.peer == bytes32(0)) revert PeerNotSet(chainId);
    }

}
