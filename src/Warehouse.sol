// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { ITurnstile } from "./ITurnstile.sol";
import { TransitTokenLib } from "./helpers/TransitTokenLib.sol";

contract Warehouse is AccessManaged, ReentrancyGuard {

    address public immutable vault;
    address public immutable TURNSTILE;
    uint64 public immutable HUB_CHAIN_ID;

    uint256 public outboundNonce;

    mapping(address asset => bool) public assetWhitelisted;

    event Deposit(address indexed asset, address indexed from, bytes32 indexed toAccountId, uint256 amount);

    error VaultUnset();
    error ZeroAssets();
    error AssetNotWhitelisted();

    constructor(
        address _authority,
        address _vault,
        address _turnstile,
        uint64 _hubChainId
    )
        AccessManaged(_authority)
    {
        if (_vault == address(0)) revert VaultUnset();
        vault = _vault;
        TURNSTILE = _turnstile;
        HUB_CHAIN_ID = _hubChainId;
    }

    // ========================================= ADMIN =========================================

    function setAssetWhitelisted(address[] calldata assets, bool allowed) external restricted {
        for (uint256 i; i < assets.length; i++) {
            assetWhitelisted[assets[i]] = allowed;
        }
    }

    // ========================================= USER =========================================

    function deposit(
        address asset,
        uint256 amount,
        uint64 toChainId,
        address to,
        uint64 messageGas
    )
        external
        payable
        nonReentrant
    {
        if (amount == 0) revert ZeroAssets();
        if (!assetWhitelisted[asset]) revert AssetNotWhitelisted();

        SafeTransferLib.safeTransferFrom(asset, msg.sender, vault, amount);

        bytes32 toAccountId = TransitTokenLib.formatAccountId(toChainId, to);
        ITurnstile(TURNSTILE).send{ value: msg.value }(
            HUB_CHAIN_ID,
            messageGas,
            ITurnstile.MessageType.Deposit,
            abi.encode(
                ITurnstile.DepositMessage({ asset: asset, nonce: ++outboundNonce, amount: amount, toAccountId: toAccountId })
            )
        );

        emit Deposit(asset, msg.sender, toAccountId, amount);
    }

    // ========================================= TURNSTILE ========================================

    function receiveWithdrawal(ITurnstile.WithdrawalMessage[] calldata messages) external restricted {
        for (uint256 i; i < messages.length; i++) {
            SafeTransferLib.safeTransferFrom(messages[i].asset, vault, messages[i].to, messages[i].amount);
        }
    }

}
