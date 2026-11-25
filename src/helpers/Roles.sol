// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

/**
 * @title Roles
 * @notice Role ids for the OZ AccessManager authority. Each AccessManaged function is mapped to one role with
 * setTargetFunctionRole, and an account may call it if it holds that role. ADMIN is AccessManager's ADMIN_ROLE, which
 * also governs every unmapped function.
 * @custom:security-contact security@paxoslabs.com
 */
library Roles {

    uint64 internal constant ADMIN = 0;
    uint64 internal constant PAUSER = 1;
    uint64 internal constant MESSAGING_ADAPTER = 2;
    uint64 internal constant SOLVER = 3;
    uint64 internal constant CONDUCTOR = 4;
    uint64 internal constant EPOCH = 5;
    uint64 internal constant TURNSTILE = 6;
    uint64 internal constant FREEZE_MANAGER = 7;
    uint64 internal constant UNPAUSER = 8;

}
