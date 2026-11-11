// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { TransitTokenLib } from "../helpers/TransitTokenLib.sol";

abstract contract TurnstileGated {

    address public immutable TURNSTILE;

    constructor(address _turnstile) {
        TURNSTILE = _turnstile;
    }

    function _senderAccountId() internal view returns (bytes32) {
        if (msg.sender == TURNSTILE) return TransitTokenLib.clearFlags(_appendedAccountId());
        return TransitTokenLib.formatAccountId(uint64(block.chainid), msg.sender, false);
    }

    function _facilitated() internal view returns (bool) {
        return msg.sender == TURNSTILE && TransitTokenLib.hasFlags(_appendedAccountId());
    }

    function _appendedAccountId() private pure returns (bytes32) {
        return bytes32(msg.data[msg.data.length - 32:]);
    }

}
