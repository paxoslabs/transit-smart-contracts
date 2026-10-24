// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { ITurnstile } from "./ITurnstile.sol";
import { TransitTokenLib } from "./helpers/TransitTokenLib.sol";

abstract contract TurnstileGated {

    address public immutable TURNSTILE;

    constructor(address _turnstile) {
        TURNSTILE = _turnstile;
    }

    function _senderAccountId() internal view returns (bytes32) {
        if (msg.sender == TURNSTILE) return bytes32(msg.data[msg.data.length - 32:]);
        return TransitTokenLib.formatAccountId(uint64(block.chainid), msg.sender);
    }

    function _facilitated() internal view returns (bool) {
        return msg.sender == TURNSTILE && ITurnstile(TURNSTILE).facilitating();
    }

}
