// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { ITurnstile } from "../ITurnstile.sol";
import { TurnstileGated } from "../TurnstileGated.sol";
import { TransitTokenLib } from "../helpers/TransitTokenLib.sol";

contract SpokeWarehouseConductor is AccessManaged, TurnstileGated {

    address public immutable VAULT;
    uint64 public immutable HUB_CHAIN_ID;

    mapping(address asset => bool) public assetWhitelisted;

    event Deposit(address indexed asset, address indexed from, bytes32 indexed toAccountId, uint256 amount);

    error VaultUnset();
    error ZeroAssets();
    error AssetNotWhitelisted();
    error ForeignAccount();

    constructor(
        address _authority,
        address _vault,
        address _turnstile,
        uint64 _hubChainId
    )
        AccessManaged(_authority)
        TurnstileGated(_turnstile)
    {
        if (_vault == address(0)) revert VaultUnset();
        VAULT = _vault;
        HUB_CHAIN_ID = _hubChainId;
    }

    // ========================================= ADMIN =========================================

    function setAssetWhitelisted(address[] calldata assets, bool allowed) external restricted {
        for (uint256 i; i < assets.length; i++) {
            assetWhitelisted[assets[i]] = allowed;
        }
    }

    // ========================================= USER =========================================

    function deposit(address asset, uint256 amount, uint64 toChainId, address to, uint64 messageGas) external payable {
        (uint64 chainId, address from) = TransitTokenLib.parseAccountId(_senderAccountId());
        if (chainId != block.chainid) revert ForeignAccount();
        _deposit(from, asset, amount, toChainId, to, messageGas);
    }

    /// TODO: Decide permit front-run grief handling: try native permit + allowance check, or skip permit when allowance
    /// covers amount.
    function depositWithPermit(
        address asset,
        uint256 amount,
        uint64 toChainId,
        address to,
        uint64 messageGas,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
        payable
    {
        (uint64 chainId, address from) = TransitTokenLib.parseAccountId(_senderAccountId());
        if (chainId != block.chainid) revert ForeignAccount();
        SafeTransferLib.permit2(asset, from, address(this), amount, deadline, v, r, s);
        _deposit(from, asset, amount, toChainId, to, messageGas);
    }

    function _deposit(
        address from,
        address asset,
        uint256 amount,
        uint64 toChainId,
        address to,
        uint64 messageGas
    )
        internal
    {
        if (amount == 0) revert ZeroAssets();
        if (!assetWhitelisted[asset]) revert AssetNotWhitelisted();

        SafeTransferLib.safeTransferFrom2(asset, from, VAULT, amount);

        bytes32 toAccountId = TransitTokenLib.formatAccountId(toChainId, to);
        ITurnstile(TURNSTILE).sendDepositMessage{ value: msg.value }(
            HUB_CHAIN_ID, messageGas, asset, amount, toAccountId
        );

        emit Deposit(asset, from, toAccountId, amount);
    }

    // ========================================= TURNSTILE ========================================

    function receiveWithdrawal(address asset, uint256 amount, address to) external restricted {
        SafeTransferLib.safeTransferFrom(asset, VAULT, to, amount);
    }

}
