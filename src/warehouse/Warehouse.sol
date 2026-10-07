// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { Hub } from "./Hub.sol";
import { CrosschainAdapter } from "./crosschain/CrosschainAdapter.sol";

contract Warehouse is AccessManaged, ReentrancyGuard, Pausable {

    struct BridgeData {
        uint64 chainId;
        address destinationChainReceiver;
        ERC20 bridgeFeeToken;
        uint64 messageGas;
        bytes data;
    }

    struct Chain {
        bool allowMessagesFrom;
        bool allowMessagesTo;
        bool registered;
    }

    enum MessageType {
        Deposit,
        Withdrawal,
        BatchWithdrawal
    }

    struct TransferMessage {
        address asset;
        uint256 nonce;
        uint256 amount;
        address to;
    }

    uint64 public immutable hubChainId;

    address public immutable vault;
    Hub public immutable hub;
    uint256 public outboundNonce;

    CrosschainAdapter public sendModule;

    mapping(uint64 chainId => Chain) public chains;
    mapping(uint64 sourceChainId => mapping(uint256 nonce => bool)) public messageConsumed;

    event SendModuleUpdated(address indexed module);
    event ChainAdded(uint64 indexed chainId, Chain chain);
    event ChainRemoved(uint64 indexed chainId);
    event Deposit(address indexed asset, address indexed from, address indexed to, uint256 amount);
    event Release(address indexed asset, address indexed to, uint256 amount);
    event MessageSent(bytes32 messageId, uint256 shareAmount, address to);
    event MessageReceived(bytes32 messageId, uint256 shareAmount, address to);

    error UnknownSourceChain(uint64 chainId);
    error VaultUnset();
    error ZeroAssets();
    error MessageReplay();
    error UnknownModule();
    error MessagesNotAllowedFrom(uint64 chainId);
    error MessagesNotAllowedTo(uint64 chainId);
    error DestinationNotHub();

    /// TODO: Decide how the hub is wired. Currently an immutable constructor arg, address(0) on spokes.
    constructor(address _authority, uint64 _hubChainId, address _vault, Hub _hub) AccessManaged(_authority) {
        if (_vault == address(0)) revert VaultUnset();
        hubChainId = _hubChainId;
        vault = _vault;
        hub = _hub;
    }

    // ========================================= ADMIN =========================================

    function setSendModule(CrosschainAdapter module) external restricted {
        sendModule = module;
        emit SendModuleUpdated(address(module));
    }

    function pause() external restricted {
        _pause();
    }

    function unpause() external restricted {
        _unpause();
    }

    function addChain(
        uint64 chainId,
        bool allowMessagesFrom,
        bool allowMessagesTo
    )
        external
        restricted
    {
        if (chainId == 0) revert UnknownSourceChain(chainId);
        Chain memory chain = Chain(allowMessagesFrom, allowMessagesTo, true);
        chains[chainId] = chain;
        emit ChainAdded(chainId, chain);
    }

    function removeChain(uint64 chainId) external restricted {
        delete chains[chainId];
        emit ChainRemoved(chainId);
    }

    function setAllowMessagesFromChain(uint64 chainId, bool allowed) external restricted {
        chains[chainId].allowMessagesFrom = allowed;
    }

    function setAllowMessagesToChain(uint64 chainId, bool allowed) external restricted {
        chains[chainId].allowMessagesTo = allowed;
    }

    // ========================================= USER =========================================

    /// TODO: Decide whether admins need a per-asset deny-list now that any ERC20 is accepted.
    /// TODO: Only data.chainId and data.messageGas are read; destinationChainReceiver (`to` is used instead),
    /// bridgeFeeToken and data are ignored. Slim BridgeData or pass messageGas directly?
    function deposit(
        ERC20 asset,
        uint256 amount,
        address to,
        BridgeData calldata data
    )
        external
        payable
        nonReentrant
        returns (uint256 shares)
    {
        _requireNotPaused();
        if (amount == 0) revert ZeroAssets();

        uint64 assetChainId = uint64(block.chainid);

        shares = amount;
        SafeTransferLib.safeTransferFrom(address(asset), msg.sender, vault, amount);

        bytes memory payload = abi.encode(
            MessageType.Deposit,
            abi.encode(
                TransferMessage({
                    asset: address(asset),
                    nonce: ++outboundNonce,
                    amount: shares,
                    to: to
                })
            )
        );

        if (assetChainId == hubChainId) {
            hub.receiveMessage(assetChainId, payload);
        } else {
            if (data.chainId != hubChainId) revert DestinationNotHub();
            _checkRoute(data);

            CrosschainAdapter module = sendModule;
            if (address(module) == address(0)) revert UnknownModule();
            bytes32 messageId = module.send{ value: msg.value }(hubChainId, data.messageGas, payload);

            emit MessageSent(messageId, shares, to);
        }

        emit Deposit(address(asset), msg.sender, to, amount);
    }

    function quoteBridge(BridgeData calldata data, bytes calldata payload) external view returns (uint256 fee) {
        CrosschainAdapter module = sendModule;
        if (address(module) == address(0)) revert UnknownModule();
        return module.quote(data.chainId, data.messageGas, payload);
    }

    // ========================================= HUB =========================================

    function release(ERC20 asset, address to, uint256 amount) external restricted nonReentrant {
        _release(address(asset), to, amount);
    }

    // ========================================= MODULE =========================================

    function receiveMessage(uint64 chainId, bytes calldata payload) external restricted nonReentrant {
        Chain memory chain = chains[chainId];
        if (!chain.registered) revert UnknownSourceChain(chainId);
        if (!chain.allowMessagesFrom) revert MessagesNotAllowedFrom(chainId);

        (MessageType messageType, bytes memory body) = abi.decode(payload, (MessageType, bytes));

        if (messageType == MessageType.Withdrawal) {
            _receiveTransfer(chainId, abi.decode(body, (TransferMessage)));
        } else if (messageType == MessageType.BatchWithdrawal) {
            TransferMessage[] memory messages = abi.decode(body, (TransferMessage[]));
            for (uint256 i; i < messages.length; i++) {
                _receiveTransfer(chainId, messages[i]);
            }
        } else {
            assert(false);
        }
    }

    function _receiveTransfer(uint64 sourceChainId, TransferMessage memory message) internal {
        _consume(sourceChainId, message.nonce);

        _release(message.asset, message.to, message.amount);

        _afterReceive(message.amount, message.to, bytes32(message.nonce));
    }

    // ========================================= INTERNAL =========================================

    function _release(address asset, address to, uint256 amount) internal {
        _requireNotPaused();
        SafeTransferLib.safeTransferFrom(asset, vault, to, amount);
        emit Release(asset, to, amount);
    }

    function _consume(uint64 sourceChainId, uint256 nonce) internal {
        /// TODO: Decide whether a duplicate should revert or no-op. Reverting strands the losing
        /// protocol's delivery in its retry queue forever when both modules deliver the same message,
        /// which is the expected steady state.
        if (messageConsumed[sourceChainId][nonce]) revert MessageReplay();
        messageConsumed[sourceChainId][nonce] = true;
    }

    function _checkRoute(BridgeData calldata data) internal view returns (Chain memory chain) {
        chain = chains[data.chainId];
        if (!chain.allowMessagesTo) revert MessagesNotAllowedTo(data.chainId);
    }

    function _afterReceive(uint256 shareAmount, address destinationChainReceiver, bytes32 messageId) internal {
        emit MessageReceived(messageId, shareAmount, destinationChainReceiver);
    }

}
