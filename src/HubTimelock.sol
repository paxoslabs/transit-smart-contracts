// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { Hub } from "./Hub.sol";

contract HubTimelock is TimelockController {

    Hub public immutable HUB;

    constructor(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address admin,
        Hub _hub
    )
        TimelockController(minDelay, proposers, executors, admin)
    {
        HUB = _hub;
    }

    function execute(
        address target,
        uint256 value,
        bytes calldata payload,
        bytes32 predecessor,
        bytes32 salt
    )
        public
        payable
        override
    {
        super.execute(target, value, payload, predecessor, salt);
        HUB.advanceEpoch(HUB.settlementEpoch());
    }

    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt
    )
        public
        payable
        override
    {
        super.executeBatch(targets, values, payloads, predecessor, salt);
        HUB.advanceEpoch(HUB.settlementEpoch());
    }

}
