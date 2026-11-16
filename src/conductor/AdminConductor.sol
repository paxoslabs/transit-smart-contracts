// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IDepot } from "../depot/IDepot.sol";

contract AdminConductor is AccessManaged {

    address public immutable DEPOT;

    constructor(address _authority, address _depot) AccessManaged(_authority) {
        DEPOT = _depot;
    }

    function forceTransferFrom(
        bytes28 fromAccountId,
        bytes28 toAccountId,
        bytes28 assetId,
        uint256 amount
    )
        external
        restricted
    {
        IDepot(DEPOT).forceTransferFrom(fromAccountId, toAccountId, assetId, amount);
    }

    function forceBurn(bytes28 fromAccountId, bytes28 assetId, uint256 amount) external restricted {
        IDepot(DEPOT).forceBurn(fromAccountId, assetId, amount);
    }

}
