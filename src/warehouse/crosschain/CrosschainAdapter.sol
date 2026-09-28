// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { Warehouse } from "../Warehouse.sol";

abstract contract CrosschainAdapter is AccessManaged {

    struct PeerConfig {
        bytes32 peer;
        uint256 remoteId;
    }

    address public immutable warehouse;

    mapping(uint64 chainId => PeerConfig) public peers;
    mapping(uint256 remoteId => uint64 chainId) public chainIdForRemoteId;

    event PeerSet(uint64 indexed chainId, bytes32 peer, uint256 remoteId);
    event MessageSent(uint64 indexed chainId, bytes32 indexed messageId, bytes payload);
    event MessageReceived(uint64 indexed chainId, bytes32 sender, bytes payload);

    error OnlyWarehouse();
    error PeerNotSet(uint64 chainId);
    error UnauthorizedPeer(uint64 chainId, bytes32 sender);

    constructor(address _authority, address _warehouse) AccessManaged(_authority) {
        warehouse = _warehouse;
    }

    modifier onlyWarehouse() {
        if (msg.sender != warehouse) revert OnlyWarehouse();
        _;
    }

    function setPeer(uint64 chainId, bytes32 peer, uint256 remoteId) external restricted {
        peers[chainId] = PeerConfig(peer, remoteId);
        chainIdForRemoteId[remoteId] = chainId;
        emit PeerSet(chainId, peer, remoteId);
    }

    function quote(uint64 chainId, uint64 gasLimit, bytes calldata payload) external view virtual returns (uint256 fee);

    function send(
        uint64 chainId,
        uint64 gasLimit,
        bytes calldata payload
    )
        external
        payable
        onlyWarehouse
        returns (bytes32 messageId)
    {
        PeerConfig memory peer = _peerOf(chainId);

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

        Warehouse(payable(warehouse)).receiveMessage(chainId, payload);
    }

    function _peerOf(uint64 chainId) internal view returns (PeerConfig memory peer) {
        peer = peers[chainId];
        if (peer.peer == bytes32(0)) revert PeerNotSet(chainId);
    }

}
