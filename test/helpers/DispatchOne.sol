// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { ITurnstile } from "../../src/turnstile/ITurnstile.sol";

function dispatchOne(
    ITurnstile turnstile,
    ITurnstile.ActionType actionType,
    bytes memory actionData,
    uint64 messageGas
) {
    ITurnstile.Action[] memory actions = new ITurnstile.Action[](1);
    actions[0] = ITurnstile.Action({ actionType: actionType, data: actionData, fare: 0, messageGas: messageGas });
    turnstile.dispatch(actions);
}
