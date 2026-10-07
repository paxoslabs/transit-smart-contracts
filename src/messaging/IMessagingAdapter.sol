// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

interface IMessagingAdapter {

    function hubChainId() external view returns (uint64);

    function quote(uint64 chainId, uint64 gasLimit, bytes calldata payload) external view returns (uint256 fee);

    function send(uint64 chainId, uint64 gasLimit, bytes calldata payload) external payable returns (bytes32 messageId);

}
