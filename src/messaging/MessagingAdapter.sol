// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IMessagingAdapter } from "src/interfaces/IMessagingAdapter.sol";
import { IMessagingReceiver } from "src/interfaces/IMessagingReceiver.sol";

/**
 * @title MessagingAdapter
 * @notice Bridge-agnostic base for sending the local Turnstile's messages to peer adapters on other chains and
 * delivering inbound messages to it. Holds per-chain peer config: allowed directions and message gas bounds.
 * @dev Each bridge implements _send and _quote, and calls _receive from its own inbound hook.
 * @custom:security-contact security@paxoslabs.com
 */
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

    /// @notice Accepts ETH so a bridge that refunds fee overpayment to its caller cannot make sends revert. Received
    /// ETH is not forwarded by later sends (each forwards only its own msg.value); an admin recovers it with
    /// withdrawETH.
    receive() external payable { }

    /// @inheritdoc IMessagingAdapter
    function withdrawETH(address to) external restricted {
        uint256 amount = address(this).balance;
        SafeTransferLib.safeTransferETH(to, amount);
        emit ETHWithdrawn(to, amount);
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
        emit PeerGasLimitSet(chainId, messageGasLimit);
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
    function setPeerGasLimit(uint64 chainId, uint64 messageGasLimit) external restricted {
        if (messageGasLimit == 0) revert ZeroMessageGasLimit();
        peers[chainId].messageGasLimit = messageGasLimit;
        emit PeerGasLimitSet(chainId, messageGasLimit);
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

    /// @inheritdoc IMessagingAdapter
    function quote(uint64 chainId, uint64 gasLimit, bytes calldata payload) external view returns (uint256 bridgeFee) {
        PeerConfig memory peer = _validateOutboundAndGetPeer(chainId, gasLimit);
        bridgeFee = _quote(chainId, gasLimit, peer, payload);
    }

    /// @dev Bridge-specific send, called by send after the peer and gas checks. msg.value is the bridge fee.
    function _send(
        uint64 chainId,
        uint64 gasLimit,
        PeerConfig memory peer,
        bytes calldata payload
    )
        internal
        virtual
        returns (bytes32 messageId);

    /// @dev Bridge-specific fee quote, called by quote after the same peer and gas checks as send.
    function _quote(
        uint64 chainId,
        uint64 gasLimit,
        PeerConfig memory peer,
        bytes calldata payload
    )
        internal
        view
        virtual
        returns (uint256 bridgeFee);

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
