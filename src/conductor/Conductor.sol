// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { TransitAddressLib } from "src/helpers/TransitAddressLib.sol";
import { IConductor } from "src/interfaces/IConductor.sol";

bytes4 constant FACILITATED_FLAG = 0x00000001;

/**
 * @title Conductor
 * @notice Base for all conductors: holds the Depot they act on, and resolves the real sender of calls users make
 * directly, via a facilitator, or cross-chain through the Turnstile, as a bytes28 account (chainId + address), like
 * ERC-2771's _msgSender.
 * @dev When msg.sender is the Turnstile, the last 32 bytes of calldata are a suffix it appended: the 28-byte sender
 * account followed by 4 bytes of flags (FACILITATED_FLAG). Otherwise the sender is msg.sender on this chain. The
 * Turnstile builds all such calldata with _buildTurnstileCallData so the suffix is always present.
 * @custom:security-contact security@paxoslabs.com
 */
abstract contract Conductor is IConductor {

    /// @inheritdoc IConductor
    address public immutable DEPOT;
    /// @inheritdoc IConductor
    address public immutable TURNSTILE;

    constructor(address _depot, address _turnstile) {
        DEPOT = _depot;
        TURNSTILE = _turnstile;
    }

    function _senderAccountId() internal view returns (bytes28 accountId) {
        if (msg.sender != TURNSTILE) return TransitAddressLib.formatTransitAddress(uint64(block.chainid), msg.sender);
        (accountId,) = _appended();
    }

    /// @dev True only when called by the Turnstile for an action a trusted facilitator submitted with the user's
    /// signature.
    function _facilitated() internal view returns (bool) {
        if (msg.sender != TURNSTILE) return false;
        (, bytes4 flags) = _appended();
        return flags & FACILITATED_FLAG != 0;
    }

    function _appended() private pure returns (bytes28 accountId, bytes4 flags) {
        bytes32 suffix = bytes32(msg.data[msg.data.length - 32:]);
        accountId = bytes28(suffix);
        flags = bytes4(suffix << 224);
    }

}
