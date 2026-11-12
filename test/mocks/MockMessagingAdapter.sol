// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { MessagingAdapter } from "../../src/messaging/MessagingAdapter.sol";

contract MockMessagingAdapter is MessagingAdapter {

    bytes[] public sent;
    uint256 public fare;

    constructor(
        address _authority,
        address _endpoint,
        uint64 _hubChainId
    )
        MessagingAdapter(_authority, _endpoint, _hubChainId)
    { }

    function quote(uint64, uint64, bytes calldata) external view override returns (uint256) {
        return fare;
    }

    function setFare(uint256 _fare) external {
        fare = _fare;
    }

    function pending() external view returns (bytes[] memory) {
        return sent;
    }

    function clearPending() external {
        delete sent;
    }

    function deliver(uint64 chainId, bytes32 sender, bytes calldata payload) external {
        _receive(chainId, sender, payload);
    }

    function _send(uint64, uint64, PeerConfig memory, bytes calldata payload) internal override returns (bytes32) {
        sent.push(payload);
        return keccak256(payload);
    }

}
