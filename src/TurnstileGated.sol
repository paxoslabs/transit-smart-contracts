// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { TransitTokenLib } from "./helpers/TransitTokenLib.sol";

abstract contract TurnstileGated is AccessManaged {

    address public turnstile;

    constructor(address _turnstile) {
        turnstile = _turnstile;
    }

    function setTurnstile(address _turnstile) external restricted {
        turnstile = _turnstile;
    }

    function _senderAccountId() internal view returns (bytes32) {
        if (msg.sender == turnstile) return TransitTokenLib.clearFlags(_appendedAccountId());
        return TransitTokenLib.formatAccountId(uint64(block.chainid), msg.sender);
    }

    function _facilitated() internal view returns (bool) {
        return msg.sender == turnstile && TransitTokenLib.hasFlags(_appendedAccountId());
    }

    function _appendedAccountId() private pure returns (bytes32) {
        return bytes32(msg.data[msg.data.length - 32:]);
    }

}
