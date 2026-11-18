// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

/// @title Transit Terminal DepotTimelock
/// @notice OZ TimelockController that advances the Depot epoch after every execution.
/// @custom:security-contact security@paxoslabs.com
interface IDepotTimelock {

    /// @notice The Depot whose epoch is advanced on every execution.
    /// @return Depot address.
    function DEPOT() external view returns (address);

}
