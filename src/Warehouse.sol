// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IMessagingAdapter } from "./messaging/IMessagingAdapter.sol";
import { ITurnstile } from "./ITurnstile.sol";
import { Turnstile } from "./Turnstile.sol";
import { TransitTokenLib } from "./helpers/TransitTokenLib.sol";

contract Warehouse is AccessManaged, Pausable, ReentrancyGuard {

    address public immutable vault;
    Turnstile public immutable TURNSTILE;

    uint256 public outboundNonce;

    mapping(address asset => bool) public assetWhitelisted;

    event Deposit(address indexed asset, address indexed from, bytes32 indexed toAccountId, uint256 amount);

    error VaultUnset();
    error ZeroAssets();
    error AssetNotWhitelisted();
    error UnknownAdapter();

    constructor(address _authority, address _vault, Turnstile _turnstile) AccessManaged(_authority) {
        if (_vault == address(0)) revert VaultUnset();
        vault = _vault;
        TURNSTILE = _turnstile;
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
        returns (uint256 shares)
    {
        _requireNotPaused();
        if (amount == 0) revert ZeroAssets();
        if (!assetWhitelisted[address(asset)]) revert AssetNotWhitelisted();

        shares = amount;
        SafeTransferLib.safeTransferFrom(address(asset), msg.sender, vault, amount);

        bytes32 toAccountId = TransitTokenLib.formatAccountId(toChainId, to);
        TURNSTILE.send{ value: msg.value }(
            _hubChainId(),
            messageGas,
            ITurnstile.MessageType.Deposit,
            abi.encode(
                ITurnstile.DepositMessage({ asset: address(asset), nonce: ++outboundNonce, amount: shares, toAccountId: toAccountId })
            )
        );

        emit Deposit(address(asset), msg.sender, toAccountId, amount);
    }

    function relay(address target, bytes calldata data, uint64 messageGas) external payable nonReentrant {
        _requireNotPaused();
        TURNSTILE.send{ value: msg.value }(
            _hubChainId(),
            messageGas,
            ITurnstile.MessageType.Generic,
            abi.encode(ITurnstile.GenericMessage({ nonce: ++outboundNonce, sender: msg.sender, target: target, data: data }))
        );
    }

    function quoteBridge(uint64 messageGas, bytes calldata payload) external view returns (uint256 fee) {
        return TURNSTILE.messagingAdapter().quote(_hubChainId(), messageGas, payload);
    }

    function _hubChainId() internal view returns (uint64) {
        IMessagingAdapter adapter = TURNSTILE.messagingAdapter();
        if (address(adapter) == address(0)) revert UnknownAdapter();
        return adapter.hubChainId();
    }

    // ========================================= TURNSTILE ========================================

    function receiveWithdrawal(ITurnstile.WithdrawalMessage[] calldata messages) external restricted {
        _requireNotPaused();
        for (uint256 i; i < messages.length; i++) {
            SafeTransferLib.safeTransferFrom(messages[i].asset, vault, messages[i].to, messages[i].amount);
        }
    }

}
