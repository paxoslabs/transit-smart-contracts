// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

/// @title Transit Terminal MessagingAdapter
/// @notice Bridge-agnostic messaging between Turnstiles on different chains. Each bridge implements one adapter.
/// @custom:security-contact security@paxoslabs.com
interface IMessagingAdapter {

    /// @notice Configuration of a remote chain's adapter.
    /// @param peer Remote adapter address, as bytes32.
    /// @param remoteId The bridge's own id for the remote chain (e.g. a CCIP chain selector).
    /// @param messageGasLimit Maximum gas a message to the chain may request.
    /// @param minimumMessageGas Minimum gas a message to the chain must request.
    /// @param allowMessagesFrom Whether messages from the chain are accepted.
    /// @param allowMessagesTo Whether messages to the chain may be sent.
    struct PeerConfig {
        bytes32 peer;
        uint256 remoteId;
        uint64 messageGasLimit;
        uint64 minimumMessageGas;
        bool allowMessagesFrom;
        bool allowMessagesTo;
    }

    /// @notice A peer was configured.
    /// @param chainId Remote chainId.
    /// @param peer See PeerConfig.
    /// @param remoteId See PeerConfig.
    /// @param messageGasLimit See PeerConfig.
    /// @param minimumMessageGas See PeerConfig.
    /// @param allowMessagesFrom See PeerConfig.
    /// @param allowMessagesTo See PeerConfig.
    event PeerSet(
        uint64 indexed chainId,
        bytes32 peer,
        uint256 remoteId,
        uint64 messageGasLimit,
        uint64 minimumMessageGas,
        bool allowMessagesFrom,
        bool allowMessagesTo
    );

    /// @notice Whether messages from a chain are accepted was set.
    /// @param chainId Remote chainId.
    /// @param allowed Whether accepted.
    event AllowMessagesFromChainSet(uint64 indexed chainId, bool allowed);

    /// @notice Whether messages to a chain may be sent was set.
    /// @param chainId Remote chainId.
    /// @param allowed Whether allowed.
    event AllowMessagesToChainSet(uint64 indexed chainId, bool allowed);

    /// @notice A peer's messageGasLimit was set.
    /// @param chainId Remote chainId.
    /// @param messageGasLimit New limit.
    event PeerGasLimitSet(uint64 indexed chainId, uint64 messageGasLimit);

    /// @notice The adapter's ETH balance was withdrawn.
    /// @param to Recipient.
    /// @param amount Amount withdrawn.
    event ETHWithdrawn(address indexed to, uint256 amount);

    /// @notice A peer was removed.
    /// @param chainId Remote chainId.
    event PeerRemoved(uint64 indexed chainId);

    /// @notice A message was sent.
    /// @param chainId Destination chainId.
    /// @param messageId Bridge message id.
    /// @param payload Message payload.
    event MessageSent(uint64 indexed chainId, bytes32 indexed messageId, bytes payload);

    /// @notice A message was received and forwarded to the LOCAL_TURNSTILE.
    /// @param chainId Source chainId.
    /// @param sender Remote adapter.
    /// @param payload Message payload.
    event MessageReceived(uint64 indexed chainId, bytes32 sender, bytes payload);

    /// @notice The caller is not the LOCAL_TURNSTILE.
    error OnlyLocalTurnstile();

    /// @notice No peer is configured for the chain.
    error PeerNotSet(uint64 chainId);

    /// @notice A message came from an address other than the chain's peer.
    error UnauthorizedPeer(uint64 chainId, bytes32 sender);

    /// @notice A peer's messageGasLimit is zero.
    error ZeroMessageGasLimit();

    /// @notice A message requested more gas than the peer's messageGasLimit.
    error GasLimitExceeded();

    /// @notice A message requested less gas than the peer's minimumMessageGas.
    error GasTooLow();

    /// @notice Messages from the chain are not allowed.
    error MessagesNotAllowedFrom(uint64 chainId);

    /// @notice Messages to the chain are not allowed.
    error MessagesNotAllowedTo(uint64 chainId);

    /// @notice The local Turnstile, the only sender and the receiver of messages.
    /// @return Local Turnstile address.
    function LOCAL_TURNSTILE() external view returns (address);

    /// @notice The chainId of the hub chain.
    /// @return Hub chainId.
    function HUB_CHAIN_ID() external view returns (uint64);

    /// @notice Configuration of a remote chain.
    /// @param chainId Remote chainId.
    /// @return peer See PeerConfig.
    /// @return remoteId See PeerConfig.
    /// @return messageGasLimit See PeerConfig.
    /// @return minimumMessageGas See PeerConfig.
    /// @return allowMessagesFrom See PeerConfig.
    /// @return allowMessagesTo See PeerConfig.
    function peers(uint64 chainId)
        external
        view
        returns (
            bytes32 peer,
            uint256 remoteId,
            uint64 messageGasLimit,
            uint64 minimumMessageGas,
            bool allowMessagesFrom,
            bool allowMessagesTo
        );

    /// @notice chainId for a bridge remote id.
    /// @param remoteId The bridge's id for the chain.
    /// @return chainId Remote chainId.
    function chainIdForRemoteId(uint256 remoteId) external view returns (uint64 chainId);

    /// @notice Configure a remote chain.
    /// @param chainId Remote chainId.
    /// @param peer See PeerConfig.
    /// @param remoteId See PeerConfig.
    /// @param messageGasLimit See PeerConfig; must be nonzero.
    /// @param minimumMessageGas See PeerConfig.
    /// @param allowMessagesFrom See PeerConfig.
    /// @param allowMessagesTo See PeerConfig.
    function setPeer(
        uint64 chainId,
        bytes32 peer,
        uint256 remoteId,
        uint64 messageGasLimit,
        uint64 minimumMessageGas,
        bool allowMessagesFrom,
        bool allowMessagesTo
    )
        external;

    /// @notice Remove a remote chain's configuration.
    /// @param chainId Remote chainId.
    function removePeer(uint64 chainId) external;

    /// @notice Set whether messages from a chain are accepted.
    /// @param chainId Remote chainId.
    /// @param allowed Whether accepted.
    function setAllowMessagesFromChain(uint64 chainId, bool allowed) external;

    /// @notice Set whether messages to a chain may be sent.
    /// @param chainId Remote chainId.
    /// @param allowed Whether allowed.
    function setAllowMessagesToChain(uint64 chainId, bool allowed) external;

    /// @notice Send the adapter's entire ETH balance. Useful if refunds or leftover fees collect in contract
    /// @param to Recipient.
    function withdrawETH(address to) external;

    /// @notice Set a peer's messageGasLimit.
    /// @param chainId Remote chainId.
    /// @param messageGasLimit New limit; must be nonzero.
    function setPeerGasLimit(uint64 chainId, uint64 messageGasLimit) external;

    /// @notice Bridge fee to send a message.
    /// @param chainId Destination chainId.
    /// @param gasLimit Gas the message requests on the destination.
    /// @param payload Message payload.
    /// @return bridgeFee Fee in native token.
    function quote(uint64 chainId, uint64 gasLimit, bytes calldata payload) external view returns (uint256 bridgeFee);

    /// @notice Send a message to a remote chain. Only callable by the LOCAL_TURNSTILE; msg.value pays the bridge fee.
    /// @param chainId Destination chainId.
    /// @param gasLimit Gas the message requests on the destination.
    /// @param payload Message payload.
    /// @return messageId Bridge message id.
    function send(uint64 chainId, uint64 gasLimit, bytes calldata payload) external payable returns (bytes32 messageId);

}
