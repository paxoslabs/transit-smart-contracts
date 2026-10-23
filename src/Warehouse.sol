// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { ITurnstile } from "./ITurnstile.sol";
import { Turnstile } from "./Turnstile.sol";
import { TransitTokenLib } from "./helpers/TransitTokenLib.sol";

contract Warehouse is AccessManaged, Pausable, ReentrancyGuard {

    address public immutable vault;
    Turnstile public immutable TURNSTILE;
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
        Turnstile _turnstile,
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

    function pause() external restricted {
        _pause();
    }

    function unpause() external restricted {
        _unpause();
    }

    // ========================================= USER =========================================

    function deposit(
        ERC20 asset,
        uint256 amount,
        uint64 toChainId,
        address to,
        uint64 messageGas
    )
        external
        payable
        nonReentrant
    {
        _requireNotPaused();
        if (amount == 0) revert ZeroAssets();
        if (!assetWhitelisted[address(asset)]) revert AssetNotWhitelisted();

        SafeTransferLib.safeTransferFrom(address(asset), msg.sender, vault, amount);

        bytes32 toAccountId = TransitTokenLib.formatAccountId(toChainId, to);
        TURNSTILE.send{ value: msg.value }(
            HUB_CHAIN_ID,
            messageGas,
            ITurnstile.MessageType.Deposit,
            abi.encode(
                ITurnstile.DepositMessage({ asset: address(asset), nonce: ++outboundNonce, amount: amount, toAccountId: toAccountId })
            )
        );

        emit Deposit(address(asset), msg.sender, toAccountId, amount);
    }

    // ========================================= TURNSTILE ========================================

    function receiveWithdrawal(ITurnstile.WithdrawalMessage[] calldata messages) external restricted {
        _requireNotPaused();
        for (uint256 i; i < messages.length; i++) {
            SafeTransferLib.safeTransferFrom(messages[i].asset, vault, messages[i].to, messages[i].amount);
        }
    }

}
