// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { ICrosschainReceiver } from "./ICrosschainReceiver.sol";

abstract contract CrosschainAdapter is AccessManaged {

    struct PeerConfig {
        bytes32 peer;
        uint256 remoteId;
        uint64 messageGasLimit;
        uint64 minimumMessageGas;
    }

    address public immutable endpoint;

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

    constructor(address _authority, address _endpoint) AccessManaged(_authority) {
        endpoint = _endpoint;
    }

    modifier onlyEndpoint() {
        if (msg.sender != endpoint) revert OnlyEndpoint();
        _;
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

    function quote(uint64 chainId, uint64 gasLimit, bytes calldata payload) external view virtual returns (uint256 fee);

    function send(
        uint64 chainId,
        uint64 gasLimit,
        bytes calldata payload
    )
        external
        payable
        onlyEndpoint
        returns (bytes32 messageId)
    {
        PeerConfig memory peer = _peerOf(chainId);
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

        emit MessageReceived(chainId, sender, payload);

        ICrosschainReceiver(endpoint).receiveMessage(chainId, payload);
    }

    function _peerOf(uint64 chainId) internal view returns (PeerConfig memory peer) {
        peer = peers[chainId];
        if (peer.peer == bytes32(0)) revert PeerNotSet(chainId);
    }

}
