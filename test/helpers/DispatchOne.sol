// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { ITurnstile } from "../../src/turnstile/ITurnstile.sol";

function dispatchOne(
    ITurnstile turnstile,
    ITurnstile.ActionType actionType,
    bytes memory actionData,
    uint64 messageGas
) {
    ITurnstile.ActionType[] memory actionTypes = new ITurnstile.ActionType[](1);
    actionTypes[0] = actionType;
    bytes[] memory data = new bytes[](1);
    data[0] = actionData;
    uint256[] memory fares = new uint256[](1);
    uint64[] memory gas = new uint64[](1);
    gas[0] = messageGas;
    turnstile.dispatch(actionTypes, data, fares, gas);
}
