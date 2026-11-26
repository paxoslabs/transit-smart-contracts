// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { Ownable } from "solady/auth/Ownable.sol";

contract Multicall is Ownable {

    constructor(address _owner) {
        _initializeOwner(_owner);
    }

    function multicall(address[] calldata targets, bytes[] calldata data) external onlyOwner {
        for (uint256 i; i < targets.length; i++) {
            (bool ok, bytes memory result) = targets[i].call(data[i]);
            if (!ok) {
                assembly {
                    revert(add(result, 0x20), mload(result))
                }
            }
        }
    }

}
