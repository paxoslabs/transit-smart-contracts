// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { AccessControlEnumerable } from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { ADMIN_ROLE } from "../helpers/Constants.sol";

contract TransitAuthority is AccessControlEnumerable {

    using Address for address;

    mapping(address target => mapping(bytes4 selector => bytes32 role)) public roleOf;

    event TargetFunctionRoleSet(address indexed target, bytes4 indexed selector, bytes32 indexed role);
    event Executed(address indexed target, bytes data, bytes result);

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
    }

    function canCall(address caller, address target, bytes4 selector) external view returns (bool) {
        bytes32 role = roleOf[target][selector];
        if (role == bytes32(0)) return false;
        return hasRole(role, caller);
    }

    function setTargetFunctionRole(
        address target,
        bytes4[] calldata selectors,
        bytes32 role
    )
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        for (uint256 i; i < selectors.length; ++i) {
            roleOf[target][selectors[i]] = role;
            emit TargetFunctionRoleSet(target, selectors[i], role);
        }
    }

    function execute(
        address target,
        bytes calldata data
    )
        external
        payable
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (bytes memory result)
    {
        result = target.functionCallWithValue(data, msg.value);
        emit Executed(target, data, result);
    }

}
