// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

contract SpokeWarehouse is AccessManaged {

    address public immutable VAULT;

    mapping(address asset => bool) public assetWhitelisted;

    error VaultUnset();
    error ZeroAssets();
    error AssetNotWhitelisted();

    constructor(address _authority, address _vault) AccessManaged(_authority) {
        if (_vault == address(0)) revert VaultUnset();
        VAULT = _vault;
    }

    // ========================================= ADMIN =========================================

    function setAssetWhitelisted(address[] calldata assets, bool allowed) external restricted {
        for (uint256 i; i < assets.length; i++) {
            assetWhitelisted[assets[i]] = allowed;
        }
    }

    // ========================================= TURNSTILE ========================================

    function custody(address from, address asset, uint256 amount) external restricted {
        _custody(from, asset, amount);
    }

    /// TODO: Decide permit front-run grief handling: try native permit + allowance check, or skip permit when allowance
    /// covers amount.
    function custodyWithPermit(
        address from,
        address asset,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
        restricted
    {
        SafeTransferLib.permit2(asset, from, address(this), amount, deadline, v, r, s);
        _custody(from, asset, amount);
    }

    function receiveWithdrawal(address asset, uint256 amount, address to) external restricted {
        SafeTransferLib.safeTransferFrom(asset, VAULT, to, amount);
    }

    function _custody(address from, address asset, uint256 amount) internal {
        if (amount == 0) revert ZeroAssets();
        if (!assetWhitelisted[asset]) revert AssetNotWhitelisted();
        SafeTransferLib.safeTransferFrom2(asset, from, VAULT, amount);
    }

}
