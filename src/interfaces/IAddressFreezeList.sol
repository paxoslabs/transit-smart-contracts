// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { IFreezable } from "@predicate/interfaces/IFreezable.sol";

/// @title Transit Terminal AddressFreezeList
/// @notice Predicate IFreezable freeze list, extended to check Transit bytes28 accounts.
interface IAddressFreezeList is IFreezable {

    /// @notice Whether an account's address is frozen. The chainId is ignored: freezes apply on every chain.
    /// @param accountId Account to check.
    /// @return True if frozen.
    function isFrozen(bytes28 accountId) external view returns (bool);

}
