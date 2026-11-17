// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { ITurnstile } from "src/interfaces/ITurnstile.sol";

/// @title Transit Terminal SpokeWarehouse
/// @notice Custody of the real tokens backing Depot balances on a chain.
interface ISpokeWarehouse {

    /// @notice Asset whitelist entries have been updated.
    /// @param assets Assets updated.
    /// @param allowed Whether the assets may be deposited.
    event AssetWhitelistUpdated(address[] assets, bool allowed);

    /// @notice Deposited tokens were moved into the VAULT.
    /// @param from Depositor.
    /// @param asset Asset deposited.
    /// @param amount Amount deposited.
    event Custodied(address indexed from, address indexed asset, uint256 amount);

    /// @notice Withdrawn tokens were released from the VAULT.
    /// @param to Recipient.
    /// @param asset Asset withdrawn.
    /// @param amount Amount withdrawn.
    event WithdrawalReleased(address indexed to, address indexed asset, uint256 amount);

    /// @notice The VAULT address is zero.
    error VaultUnset();

    /// @notice A deposit amount is zero.
    error ZeroAssets();

    /// @notice The asset is not whitelisted for deposit.
    error AssetNotWhitelisted();

    /// @notice A permit failed and the existing allowance does not cover the amount.
    error PermitFailedAndAllowanceTooLow();

    /// @notice Address holding the custodied tokens.
    /// @return Vault address.
    function VAULT() external view returns (address);

    /// @notice Whether an asset may be deposited.
    /// @param asset Asset to query.
    /// @return Whether whitelisted.
    function assetWhitelisted(address asset) external view returns (bool);

    /// @notice Set whether assets may be deposited.
    /// @param assets Assets to update.
    /// @param allowed Whether the assets may be deposited.
    function setAssetWhitelisted(address[] calldata assets, bool allowed) external;

    /// @notice Apply an EIP-2612 permit for this contract. If the permit fails (e.g. front-run), succeeds as long as
    /// the existing allowance covers the amount.
    /// @param from Token owner.
    /// @param asset Token.
    /// @param amount Allowance to grant.
    /// @param permit_ Permit signature fields.
    function permit(address from, address asset, uint256 amount, ITurnstile.Permit calldata permit_) external;

    /// @notice Pull deposited tokens from the depositor into the VAULT.
    /// @param from Depositor.
    /// @param asset Whitelisted asset.
    /// @param amount Nonzero amount.
    function custody(address from, address asset, uint256 amount) external;

    /// @notice Release withdrawn tokens from the VAULT to the recipient.
    /// @param asset Asset withdrawn.
    /// @param amount Amount withdrawn.
    /// @param to Recipient.
    function receiveWithdrawal(address asset, uint256 amount, address to) external;

}
