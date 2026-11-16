// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { TransitAccountLib } from "../helpers/TransitAccountLib.sol";

bytes4 constant FACILITATED_FLAG = 0x00000001;

abstract contract TurnstileGated {

    address public immutable TURNSTILE;

    constructor(address _turnstile) {
        TURNSTILE = _turnstile;
    }

    function _senderAccountId() internal view returns (bytes28 accountId) {
        if (msg.sender != TURNSTILE) return TransitAccountLib.formatAccountId(uint64(block.chainid), msg.sender);
        (accountId,) = _appended();
    }

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
