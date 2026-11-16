// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { IDepot } from "src/depot/IDepot.sol";

/**
 * @title DepotTimelock
 * @notice Timelock intended to hold admin power over the Depot system (e.g. the AccessManager admin), proposed and
 * executed by the admin multisig. Delayed execution gives users a window to exit before governance changes apply.
 * @dev Every execution advances the settlement epoch, so an in-flight settle tx reverts BadEpoch and the solver must
 * observe the change before resubmitting. Signed orders are unaffected and remain valid under the new rules; users who
 * object must cancel during the delay. Requires a role permitting advanceEpoch. Side effect: actions waiting on the
 * next epoch (reservations, requests, cancellations) take effect one batch early.
 */
contract DepotTimelock is TimelockController {

    /// @notice The Depot whose epoch is advanced on every execution.
    address public immutable DEPOT;

    constructor(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address admin,
        address _depot
    )
        TimelockController(minDelay, proposers, executors, admin)
    {
        DEPOT = _depot;
    }

    /// @notice Executes a ready operation, then advances the Depot epoch.
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
        IDepot(DEPOT).advanceEpoch();
    }

    /// @notice Executes a ready batch operation, then advances the Depot epoch.
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
        IDepot(DEPOT).advanceEpoch();
    }

}
