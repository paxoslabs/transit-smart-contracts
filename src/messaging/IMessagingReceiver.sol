// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

interface IMessagingReceiver {

    function receiveMessage(uint64 chainId, bytes calldata payload) external;

}
