// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";

contract Hub is AccessManaged {

    mapping(address user => mapping(uint64 assetChainId => mapping(address asset => uint256))) public balanceOf;

    event Enter(address indexed to, uint64 indexed assetChainId, address indexed asset, uint256 amount);
    event Exit(address indexed from, uint64 indexed assetChainId, address indexed asset, uint256 amount);
    event Move(address indexed from, address indexed to, uint64 assetChainId, address indexed asset, uint256 amount);

    constructor(address _authority) AccessManaged(_authority) { }

    function enter(address to, uint64 assetChainId, address asset, uint256 amount) external restricted {
        balanceOf[to][assetChainId][asset] += amount;
        emit Enter(to, assetChainId, asset, amount);
    }

    function exit(address from, uint64 assetChainId, address asset, uint256 amount) external restricted {
        balanceOf[from][assetChainId][asset] -= amount;
        emit Exit(from, assetChainId, asset, amount);
    }

    function move(address from, address to, uint64 assetChainId, address asset, uint256 amount) external restricted {
        balanceOf[from][assetChainId][asset] -= amount;
        balanceOf[to][assetChainId][asset] += amount;
        emit Move(from, to, assetChainId, asset, amount);
    }

}
