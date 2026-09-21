// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { ERC20 } from "solady/tokens/ERC20.sol";

contract WarehouseSpoke {

    /// TODO: Decide the deposit body. On a spoke there is no Terminal, so what credits the user here —
    /// a local mint, or a message to the hub?
    function deposit(ERC20 asset, uint256 amount) external virtual { }

}
