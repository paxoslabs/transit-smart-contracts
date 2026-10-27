// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { Depot } from "./Depot.sol";
import { TransitTokenLib } from "./helpers/TransitTokenLib.sol";

contract DelayedSettlementAssetRegistry is AccessManaged {

    uint256 public constant COLLATERALIZATION_RATIO = 100;

    Depot public immutable DEPOT;

    error FlaggedAssetId();

    constructor(address _authority, Depot _depot) AccessManaged(_authority) {
        DEPOT = _depot;
    }

    function mint(bytes32 accountId, bytes32 assetId, uint256 amount) external restricted {
        _mint(accountId, assetId, amount);
    }

    function _mint(bytes32 accountId, bytes32 assetId, uint256 amount) internal {
        if (TransitTokenLib.hasFlags(assetId)) revert FlaggedAssetId();
        DEPOT.transferFrom(accountId, _depotAccountId(address(this)), assetId, amount);
        DEPOT.mint(accountId, TransitTokenLib.formatMarginAssetId(assetId), amount * COLLATERALIZATION_RATIO);
    }

    function _depotAccountId(address account) internal view returns (bytes32) {
        return TransitTokenLib.formatAccountId(uint64(block.chainid), account);
    }

}
