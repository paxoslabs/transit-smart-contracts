// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { Hub } from "./Hub.sol";
import { TransitTokenLib } from "./helpers/TransitTokenLib.sol";

contract DelayedSettlementAssetRegistry {

    uint256 public constant COLLATERALIZATION_RATIO = 100;

    Hub public immutable HUB;

    constructor(Hub _hub) {
        HUB = _hub;
    }

    function mint(uint64 assetChainId, address asset, uint256 amount) external {
        bytes32 accountId = _hubAccountId(msg.sender);
        bytes32 assetId = TransitTokenLib.formatAssetId(assetChainId, asset);
        HUB.transferFrom(accountId, _hubAccountId(address(this)), assetId, amount);
        HUB.mint(accountId, TransitTokenLib.formatMarginAssetId(assetChainId, asset), amount * COLLATERALIZATION_RATIO);
    }

    function _hubAccountId(address account) internal view returns (bytes32) {
        return TransitTokenLib.formatAccountId(uint64(block.chainid), account);
    }

}
