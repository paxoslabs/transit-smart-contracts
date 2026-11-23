// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

/// @title Transit Terminal MessagingReceiver
/// @notice Receiver of inbound cross-chain messages from a MessagingAdapter. Implemented by the Turnstile.
/// @custom:security-contact security@paxoslabs.com
interface IMessagingReceiver {

    /// @notice Delivers an inbound cross-chain message. Called by the MessagingAdapter.
    function handleReceivedMessage(uint64 chainId, bytes calldata payload) external;

}
