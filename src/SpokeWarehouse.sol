// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { ITurnstile } from "src/turnstile/ITurnstile.sol";

contract SpokeWarehouse is AccessManaged {

    address public immutable VAULT;

    mapping(address asset => bool) public assetWhitelisted;

    error VaultUnset();
    error ZeroAssets();
    error AssetNotWhitelisted();
    error PermitFailedAndAllowanceTooLow();

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

    function permit(
        address from,
        address asset,
        uint256 amount,
        ITurnstile.Permit calldata permit_
    )
        external
        restricted
    {
        try IERC20Permit(asset)
            .permit(from, address(this), amount, permit_.deadline, permit_.v, permit_.r, permit_.s) { }
        catch {
            if (IERC20(asset).allowance(from, address(this)) < amount) {
                revert PermitFailedAndAllowanceTooLow();
            }
        }
    }

    function custody(address from, address asset, uint256 amount) external restricted {
        if (amount == 0) revert ZeroAssets();
        if (!assetWhitelisted[asset]) revert AssetNotWhitelisted();
        SafeTransferLib.safeTransferFrom(asset, from, VAULT, amount);
    }

    function receiveWithdrawal(address asset, uint256 amount, address to) external restricted {
        SafeTransferLib.safeTransferFrom(asset, VAULT, to, amount);
    }

}
