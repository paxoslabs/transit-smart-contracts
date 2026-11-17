// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

interface IMessagingReceiver {

    /// @notice Delivers an inbound cross-chain message. Called by the MessagingAdapter.
    function receiveMessage(uint64 chainId, bytes calldata payload) external;

}
