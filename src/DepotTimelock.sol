// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { Depot } from "./Depot.sol";

contract DepotTimelock is TimelockController {

    Depot public immutable DEPOT;

    constructor(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address admin,
        Depot _depot
    )
        TimelockController(minDelay, proposers, executors, admin)
    {
        DEPOT = _depot;
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
        DEPOT.advanceEpoch(DEPOT.settlementEpoch());
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
        DEPOT.advanceEpoch(DEPOT.settlementEpoch());
    }

}
