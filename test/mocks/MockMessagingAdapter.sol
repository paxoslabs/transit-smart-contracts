// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { MessagingAdapter } from "../../src/messaging/MessagingAdapter.sol";

contract MockMessagingAdapter is MessagingAdapter {

    bytes[] public sent;
    uint256 public bridgeFee;

    constructor(
        address _authority,
        address _localTurnstile,
        uint64 _hubChainId
    )
        MessagingAdapter(_authority, _localTurnstile, _hubChainId)
    { }

    function quote(uint64, uint64, bytes calldata) external view override returns (uint256) {
        return bridgeFee;
    }

    function setBridgeFee(uint256 _bridgeFee) external {
        bridgeFee = _bridgeFee;
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
