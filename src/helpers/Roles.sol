// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

library Roles {

    bytes32 internal constant ADMIN = bytes32(uint256(0x01));
    bytes32 internal constant PAUSER = bytes32(uint256(0x02));
    bytes32 internal constant WAREHOUSE_CONDUCTOR = bytes32(uint256(0x03));
    bytes32 internal constant MANAGER = bytes32(uint256(0x04));
    bytes32 internal constant MESSAGING_ADAPTER = bytes32(uint256(0x05));
    bytes32 internal constant SOLVER = bytes32(uint256(0x06));
    bytes32 internal constant CONDUCTOR = bytes32(uint256(0x07));
    bytes32 internal constant EPOCH = bytes32(uint256(0x08));
    bytes32 internal constant TURNSTILE = bytes32(uint256(0x09));
    bytes32 internal constant FREEZE_MANAGER = bytes32(uint256(0x0a));

}
