// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { Hub } from "./Hub.sol";
import { TransitTokenLib } from "./helpers/TransitTokenLib.sol";

contract DelayedSettlementAssetRegistry is AccessManaged {

    uint256 public constant COLLATERALIZATION_RATIO = 100;

    Hub public immutable HUB;

    error FlaggedAssetId();

    constructor(address _authority, Hub _hub) AccessManaged(_authority) {
        HUB = _hub;
    }

    function mint(bytes32 accountId, bytes32 assetId, uint256 amount) external restricted {
        _mint(accountId, assetId, amount);
    }

    function _mint(bytes32 accountId, bytes32 assetId, uint256 amount) internal {
        if (TransitTokenLib.hasFlags(assetId)) revert FlaggedAssetId();
        HUB.transferFrom(accountId, _hubAccountId(address(this)), assetId, amount);
        HUB.mint(accountId, TransitTokenLib.formatMarginAssetId(assetId), amount * COLLATERALIZATION_RATIO);
    }

    function _hubAccountId(address account) internal view returns (bytes32) {
        return TransitTokenLib.formatAccountId(uint64(block.chainid), account);
    }

}
