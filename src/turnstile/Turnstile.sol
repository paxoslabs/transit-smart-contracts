// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";
import { EIP712 } from "solady/utils/EIP712.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { ITurnstile } from "src/interfaces/ITurnstile.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { Roles } from "src/helpers/Roles.sol";
import { Typehashes } from "src/helpers/Typehashes.sol";
import { HubWarehouseConductor } from "src/conductor/HubWarehouseConductor.sol";
import { TransitAddressLib } from "src/helpers/TransitAddressLib.sol";
import { IMessagingAdapter } from "src/interfaces/IMessagingAdapter.sol";
import { IMessagingReceiver } from "src/interfaces/IMessagingReceiver.sol";
import { FACILITATED_FLAG } from "src/conductor/ConductorGatedByTurnstile.sol";

/**
 * @title Turnstile
 * @notice The single entrypoint for Transit on each chain. Users dispatch actions (deposit, withdrawal, generic call)
 * directly or through a facilitator with signatures. It takes deposits into the chain's VAULT, releases withdrawals
 * from it, and routes messages: same-chain messages execute locally, cross-chain ones go through the MessagingAdapter.
 * @dev Inbound messages are replay-protected by hash. A failed message reverts: same-chain it reverts its action,
 * cross-chain it reverts the delivery for a bridge retry.
 * Calls into conductors carry the sender and facilitated flag as a calldata suffix (see _buildTurnstileCallData).
 * The VAULT approves this contract, so the generic message whitelist must never include token contracts.
 * @custom:security-contact security@paxoslabs.com
 */
contract Turnstile is AccessManaged, Pausable, EIP712, ITurnstile {

    /// @inheritdoc ITurnstile
    address public immutable VAULT;

    /// @inheritdoc ITurnstile
    address public messagingAdapter;
    /// @inheritdoc ITurnstile
    address public hubWarehouseConductor;

    /// @inheritdoc ITurnstile
    mapping(bytes32 messageHash => bool) public messageExecuted;
    /// @inheritdoc ITurnstile
    mapping(address target => mapping(bytes4 selector => bool)) public genericMessageWhitelist;
    /// @inheritdoc ITurnstile
    mapping(address asset => bool) public assetWhitelisted;

    constructor(address _authority, address _vault) AccessManaged(_authority) {
        if (_vault == address(0)) revert VaultUnset();
        VAULT = _vault;
        /// NOTE: messagingAdapter is not set here because MessagingAdapter takes this Turnstile as its immutable
        /// LOCAL_TURNSTILE, making constructor wiring circular. We could instead check !=0 on every call as was done
        /// before but this only provides a more convinient error. And the window between deploy and setting still
        /// reverts.
    }

    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return ("Transit Turnstile", "1");
    }

    // ========================================= ADMIN =========================================

    /// @inheritdoc ITurnstile
    function setMessagingAdapter(address adapter) external restricted {
        if (adapter.code.length == 0) revert NoCode();
        messagingAdapter = adapter;
        emit MessagingAdapterUpdated(adapter);
    }

    /// @inheritdoc ITurnstile
    function setHubWarehouseConductor(address _hubWarehouseConductor) external restricted {
        if (_hubWarehouseConductor.code.length == 0) revert NoCode();
        if (block.chainid != IMessagingAdapter(messagingAdapter).HUB_CHAIN_ID()) revert NotHubChain();
        hubWarehouseConductor = _hubWarehouseConductor;
        emit HubWarehouseConductorUpdated(_hubWarehouseConductor);
    }

    /// @inheritdoc ITurnstile
    function setRoutable(address target, bytes4[] calldata selectors, bool allowed) external restricted {
        // The VAULT has approved this Turnstile for its assets. If generic calls could reach a contract holding such an
        // approval, anyone could spend it (e.g. transferFrom(VAULT, attacker, amount)). Also checked at execution.
        if (allowed && _hasVaultAllowance(target)) revert VaultApprovedTarget(target);
        for (uint256 i; i < selectors.length; i++) {
            // Turnstile-only functions are callable only by the Turnstile because they rely on the Turnstile calling
            // them in a particular way (e.g. executeWithdrawal() must be followed by a message to release tokens).
            if (allowed && _isTurnstileOnly(target, selectors[i])) {
                revert TurnstileOnlySelector(target, selectors[i]);
            }
            if (allowed && selectors[i] == IERC20.transferFrom.selector) revert TransferFromSelector(target);
            genericMessageWhitelist[target][selectors[i]] = allowed;
        }
        emit GenericMessageWhitelistUpdated(target, selectors, allowed);
    }

    /// @inheritdoc ITurnstile
    function setAssetWhitelisted(address[] calldata assets, bool allowed) external restricted {
        for (uint256 i; i < assets.length; i++) {
            assetWhitelisted[assets[i]] = allowed;
        }
        emit AssetWhitelistUpdated(assets, allowed);
    }

    /// @inheritdoc ITurnstile
    function pause() external restricted {
        _pause();
    }

    /// @inheritdoc ITurnstile
    function unpause() external restricted {
        _unpause();
    }

    /// @inheritdoc ITurnstile
    function dispatch(Action[] calldata actions) external payable returns (bytes32[] memory messageHashes) {
        messageHashes = _dispatch(actions, new bytes[](0), false);
    }

    /// @inheritdoc ITurnstile
    function facilitate(
        Action[] calldata actions,
        bytes[] calldata signatures
    )
        external
        payable
        restricted
        returns (bytes32[] memory messageHashes)
    {
        messageHashes = _dispatch(actions, signatures, true);
    }

    /// @inheritdoc ITurnstile
    function hashDepositAction(DepositAction memory action) public view returns (bytes32) {
        // Permit is all-static, so it hashes whole. The outer encoding is split in two because a single abi.encode of
        // every field is stack too deep; concatenated static encodings equal the single encoding.
        bytes32 permitHash = keccak256(abi.encode(Typehashes.PERMIT, action.permit));
        return _hashTypedData(
            keccak256(
                bytes.concat(
                    abi.encode(
                        Typehashes.DEPOSIT_ACTION,
                        action.ownerChainId,
                        action.owner,
                        action.asset,
                        action.amount,
                        action.toChainId,
                        action.to
                    ),
                    abi.encode(
                        action.facilitationFee,
                        action.feeReceiverChainId,
                        action.feeReceiver,
                        action.deadline,
                        action.dependsOn,
                        action.salt,
                        permitHash
                    )
                )
            )
        );
    }

    /// @inheritdoc ITurnstile
    function hashWithdrawalAction(WithdrawalAction memory action) public view returns (bytes32) {
        return _hashTypedData(keccak256(abi.encode(Typehashes.WITHDRAWAL_ACTION, action)));
    }

    /// @inheritdoc ITurnstile
    function hashGenericAction(GenericAction memory action) public view returns (bytes32) {
        return _hashTypedData(
            keccak256(
                abi.encode(
                    Typehashes.GENERIC_ACTION,
                    action.ownerChainId,
                    action.owner,
                    action.target,
                    keccak256(action.data),
                    action.deadline,
                    action.dependsOn,
                    action.salt
                )
            )
        );
    }

    /// @inheritdoc ITurnstile
    function digestMessage(uint64 chainId, ActionType actionType, bytes memory body) public pure returns (bytes32) {
        return keccak256(abi.encode(chainId, actionType, body));
    }

    /// @inheritdoc ITurnstile
    function quote(Action[] calldata actions) external view returns (uint256[] memory bridgeFees) {
        bridgeFees = new uint256[](actions.length);
        for (uint256 i; i < actions.length; i++) {
            if (actions[i].actionType == ActionType.Deposit) {
                DepositAction memory action = abi.decode(actions[i].data, (DepositAction));
                bridgeFees[i] = _quote(
                    IMessagingAdapter(messagingAdapter).HUB_CHAIN_ID(),
                    actions[i].messageGas,
                    ActionType.Deposit,
                    abi.encode(
                        DepositMessage({
                            asset: action.asset,
                            amount: action.amount,
                            fromAccountId: TransitAddressLib.formatTransitAddress(uint64(block.chainid), msg.sender),
                            toAccountId: TransitAddressLib.formatTransitAddress(action.toChainId, action.to),
                            facilitationFee: action.facilitationFee,
                            feeReceiverAccountId: TransitAddressLib.formatTransitAddress(
                                action.feeReceiverChainId, action.feeReceiver
                            ),
                            salt: action.salt
                        })
                    )
                );
            } else if (actions[i].actionType == ActionType.Withdrawal) {
                WithdrawalAction memory action = abi.decode(actions[i].data, (WithdrawalAction));
                bridgeFees[i] = _quote(
                    action.assetChainId,
                    actions[i].messageGas,
                    ActionType.Withdrawal,
                    abi.encode(
                        WithdrawalMessage({
                            asset: action.asset,
                            amount: action.amount,
                            to: action.to,
                            salt: hashWithdrawalAction(action)
                        })
                    )
                );
            } else {
                GenericAction memory action = abi.decode(actions[i].data, (GenericAction));
                bridgeFees[i] = _quote(
                    IMessagingAdapter(messagingAdapter).HUB_CHAIN_ID(),
                    actions[i].messageGas,
                    ActionType.Generic,
                    abi.encode(
                        GenericMessage({
                            sender: msg.sender,
                            target: action.target,
                            data: action.data,
                            deadline: action.deadline,
                            salt: action.salt
                        })
                    )
                );
            }
        }
    }

    // ========================================= ADAPTER ========================================

    /// @inheritdoc IMessagingReceiver
    function handleReceivedMessage(uint64 chainId, bytes calldata payload) external restricted {
        (ActionType actionType, bytes memory body) = abi.decode(payload, (ActionType, bytes));
        _handleMessage(chainId, uint64(block.chainid), 0, actionType, body, 0, false);
    }

    function _dispatch(
        Action[] calldata actions,
        bytes[] memory signatures,
        bool facilitated
    )
        internal
        whenNotPaused
        returns (bytes32[] memory messageHashes)
    {
        // facilitated: a trusted facilitator submits actions signed by users. Each action's actor is then the
        // signature's signer rather than msg.sender, and downstream conductors may grant it privileges (e.g. skipping
        // the one epoch request delay). Unfacilitated actions carry no signatures.
        if (facilitated && actions.length != signatures.length) revert LengthMismatch();
        messageHashes = new bytes32[](actions.length);
        uint256 totalBridgeFee;
        for (uint256 i; i < actions.length; i++) {
            totalBridgeFee += actions[i].bridgeFee;
            messageHashes[i] = _dispatchAction(actions[i], facilitated ? signatures[i] : bytes(""), facilitated);
        }
        if (totalBridgeFee != msg.value) revert BridgeFeeMismatch();
    }

    function _dispatchAction(
        Action calldata action,
        bytes memory signature,
        bool facilitated
    )
        internal
        returns (bytes32 messageHash)
    {
        ActionType actionType = action.actionType;
        uint64 chainId;
        bytes memory body;
        if (actionType == ActionType.Deposit) {
            (chainId, body) = _dispatchDeposit(action.data, signature, facilitated);
        } else if (actionType == ActionType.Withdrawal) {
            (chainId, body) = _dispatchWithdraw(action.data, signature, facilitated);
        } else {
            (chainId, body) = _dispatchGeneric(action.data, signature, facilitated);
        }
        if (body.length != 0) {
            messageHash = _handleMessage(
                uint64(block.chainid), chainId, action.messageGas, actionType, body, action.bridgeFee, facilitated
            );
        } else if (action.bridgeFee != 0) {
            // Only a withdrawal returns an empty body: executeWithdrawal returned 0 because the action expired, or the
            // owner's free balance was 0 or short of a non-partially-fillable amount. By now executeWithdrawal has
            // already consumed the request and released its reservation, and that must stand. Reverting would roll it
            // back,
            // and an expired request could then never be consumed, leaving its reservation (which only _consume
            // releases) reserving the owner's funds forever. It would also revert every other action in the batch.
            // With no message sent, this action's bridgeFee was not spent; it is refunded to whoever paid it.
            SafeTransferLib.forceSafeTransferETH(msg.sender, action.bridgeFee);
        }
    }

    function _dispatchDeposit(
        bytes calldata actionData,
        bytes memory signature,
        bool facilitated
    )
        private
        returns (uint64 chainId, bytes memory body)
    {
        DepositAction memory action = abi.decode(actionData, (DepositAction));
        // For deposits, facilitation only determines who `from` is. It is not propagated in the message.
        address from = facilitated ? ECDSA.recover(hashDepositAction(action), signature) : msg.sender;
        if (action.ownerChainId != block.chainid || from != action.owner) revert NotOwner();
        _requireDependency(action.dependsOn);
        if (block.timestamp > action.deadline) revert Expired();
        bytes28 toAccountId = TransitAddressLib.formatTransitAddress(action.toChainId, action.to);
        if (!TransitAddressLib.isValid(toAccountId)) revert InvalidAccount();
        if (action.amount == 0) revert ZeroAssets();
        if (action.facilitationFee > action.amount) revert FeeExceedsAmount();
        bytes28 feeReceiverAccountId =
            TransitAddressLib.formatTransitAddress(action.feeReceiverChainId, action.feeReceiver);
        if (action.facilitationFee != 0 && !TransitAddressLib.isValid(feeReceiverAccountId)) revert InvalidAccount();
        if (!assetWhitelisted[action.asset]) revert AssetNotWhitelisted();
        if (action.permit.deadline != 0) _permit(from, action.asset, action.amount, action.permit);
        SafeTransferLib.safeTransferFrom(action.asset, from, VAULT, action.amount);
        bytes28 fromAccountId = TransitAddressLib.formatTransitAddress(uint64(block.chainid), from);
        chainId = IMessagingAdapter(messagingAdapter).HUB_CHAIN_ID();
        body = abi.encode(
            DepositMessage({
                asset: action.asset,
                amount: action.amount,
                fromAccountId: fromAccountId,
                toAccountId: toAccountId,
                facilitationFee: action.facilitationFee,
                feeReceiverAccountId: feeReceiverAccountId,
                salt: action.salt
            })
        );
        emit Deposit(action.asset, from, toAccountId, action.amount);
    }

    function _dispatchWithdraw(
        bytes calldata actionData,
        bytes memory signature,
        bool facilitated
    )
        private
        returns (uint64 chainId, bytes memory body)
    {
        WithdrawalAction memory action = abi.decode(actionData, (WithdrawalAction));
        _requireDependency(action.dependsOn);
        bytes28 accountId;
        {
            // Withdrawals are dispatched on the hub, so the owner is always an account on this chain.
            address owner = facilitated ? ECDSA.recover(hashWithdrawalAction(action), signature) : msg.sender;
            accountId = TransitAddressLib.formatTransitAddress(uint64(block.chainid), owner);
        }
        uint256 amount;
        {
            address handler = hubWarehouseConductor;
            if (handler == address(0)) revert NoHandler();
            // A facilitated owner may withdraw without a prior request; otherwise the request must be effective.
            (bool ok, bytes memory result) = handler.call(
                _buildTurnstileCallData(
                    abi.encodeCall(HubWarehouseConductor.executeWithdrawal, (action)), accountId, facilitated
                )
            );
            if (!ok) {
                assembly {
                    revert(add(result, 0x20), mload(result))
                }
            }
            amount = abi.decode(result, (uint256));
        }
        if (amount == 0) return (0, "");
        chainId = action.assetChainId;
        body = abi.encode(
            WithdrawalMessage({
                asset: action.asset, amount: amount, to: action.to, salt: hashWithdrawalAction(action)
            })
        );
    }

    function _dispatchGeneric(
        bytes calldata actionData,
        bytes memory signature,
        bool facilitated
    )
        private
        returns (uint64 chainId, bytes memory body)
    {
        GenericAction memory action = abi.decode(actionData, (GenericAction));
        address sender = facilitated ? ECDSA.recover(hashGenericAction(action), signature) : msg.sender;
        if (action.ownerChainId != block.chainid || sender != action.owner) revert NotOwner();
        _requireDependency(action.dependsOn);
        chainId = IMessagingAdapter(messagingAdapter).HUB_CHAIN_ID();
        body = abi.encode(
            GenericMessage({
                sender: sender, target: action.target, data: action.data, deadline: action.deadline, salt: action.salt
            })
        );
    }

    /// @dev Reverts unless dependsOn is 0 or a message already marked in this Turnstile's messageExecuted. A
    /// partially fillable withdrawal cannot be depended on: its message body holds the executed amount,
    /// min(requested, free balance), which is unknown until execution, so its hash cannot be computed in advance.
    function _requireDependency(bytes32 dependsOn) private view {
        if (dependsOn != 0 && !messageExecuted[dependsOn]) revert DependencyNotExecuted();
    }

    function _handleMessage(
        uint64 sourceChainId,
        uint64 destinationChainId,
        uint64 messageGas,
        ActionType actionType,
        bytes memory body,
        uint256 bridgeFee,
        bool facilitated
    )
        internal
        returns (bytes32 messageHash)
    {
        messageHash = digestMessage(sourceChainId, actionType, body);

        if (messageExecuted[messageHash]) revert MessageReplay();
        messageExecuted[messageHash] = true;

        if (destinationChainId == block.chainid) {
            // Same-chain messages bypass the MessagingAdapter and are executed by the Turnstile directly.
            if (bridgeFee != 0) revert NoBridgeFee();
            _executeMessageLocally(sourceChainId, actionType, body, facilitated);
        } else {
            // Cross-chain messages are encoded and forwarded to the MessagingAdapter.
            IMessagingAdapter(messagingAdapter).send{ value: bridgeFee }(
                destinationChainId, messageGas, abi.encode(actionType, body)
            );
        }
    }

    function _quote(
        uint64 chainId,
        uint64 messageGas,
        ActionType actionType,
        bytes memory body
    )
        internal
        view
        returns (uint256)
    {
        if (chainId == block.chainid) return 0;
        return IMessagingAdapter(messagingAdapter).quote(chainId, messageGas, abi.encode(actionType, body));
    }

    /// @notice Atempt to execute a message on the local chain.
    /// @param chainId Message's source chainId.
    /// @param actionType Message's ActionType.
    /// @param body Message's body.
    /// @param facilitated Whether the message was facilitated. Only set on same-chain messages; the flag does not
    /// travel cross-chain.
    function _executeMessageLocally(
        uint64 chainId,
        ActionType actionType,
        bytes memory body,
        bool facilitated
    )
        internal
        whenNotPaused
    {
        address target;
        bytes memory data;

        if (actionType == ActionType.Deposit) {
            DepositMessage memory message = abi.decode(body, (DepositMessage));
            target = hubWarehouseConductor;
            data = _buildTurnstileCallData(
                abi.encodeCall(
                    HubWarehouseConductor.receiveDeposit,
                    (
                        chainId,
                        message.asset,
                        message.amount,
                        message.fromAccountId,
                        message.toAccountId,
                        message.facilitationFee,
                        message.feeReceiverAccountId
                    )
                ),
                message.fromAccountId,
                false
            );
        } else if (actionType == ActionType.Withdrawal) {
            WithdrawalMessage memory message = abi.decode(body, (WithdrawalMessage));
            // Released directly from the VAULT, which has approved this Turnstile.
            SafeTransferLib.safeTransferFrom(message.asset, VAULT, message.to, message.amount);
            emit WithdrawalReleased(message.to, message.asset, message.amount);
            return;
        } else {
            GenericMessage memory message = abi.decode(body, (GenericMessage));

            if (block.timestamp > message.deadline) revert Expired();
            if (message.data.length < 4 || !_isRoutable(message.target, bytes4(message.data))) {
                revert NotWhitelisted();
            }
            target = message.target;
            // The chainId comes from the bridge, not the message, so a spoke cannot spoof another chain's accounts.
            data = _buildTurnstileCallData(
                message.data, TransitAddressLib.formatTransitAddress(chainId, message.sender), facilitated
            );
        }

        if (target == address(0)) revert NoHandler();
        (bool ok, bytes memory result) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }
    }

    /// @dev Applies an EIP-2612 permit for this Turnstile. If the permit fails (e.g. front-run), succeeds as long as
    /// the existing allowance covers the amount.
    function _permit(address from, address asset, uint256 amount, Permit memory permit_) private {
        try IERC20Permit(asset)
            .permit(from, address(this), amount, permit_.deadline, permit_.v, permit_.r, permit_.s) { }
        catch {
            if (IERC20(asset).allowance(from, address(this)) < amount) revert PermitFailedAndAllowanceTooLow();
        }
    }

    /// @dev Whether a generic message may call target.selector: whitelisted, not restricted to the TURNSTILE role, and
    /// target holds no VAULT allowance for this Turnstile. Checked at execution so a role change or approval made
    /// after whitelisting still blocks the call.
    function _isRoutable(address target, bytes4 selector) internal view returns (bool) {
        return
            genericMessageWhitelist[target][selector] && !_isTurnstileOnly(target, selector)
                && !_hasVaultAllowance(target);
    }

    /// @dev Whether the authority restricts target.selector to the TURNSTILE role.
    function _isTurnstileOnly(address target, bytes4 selector) internal view returns (bool) {
        return IAccessManager(authority()).getTargetFunctionRole(target, selector) == Roles.TURNSTILE;
    }

    /// @dev Whether target reports a nonzero allowance(VAULT, this). Only allowances are covered, as this Turnstile
    /// holds no token balance. A failed call or short return counts as no allowance (target is not an ERC20). Only 32
    /// bytes of return data are copied, so a large return cannot waste gas.
    function _hasVaultAllowance(address target) internal view returns (bool approved) {
        address vault = VAULT;
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0xdd62ed3e00000000000000000000000000000000000000000000000000000000) // allowance(address,address)
            mstore(add(m, 0x04), vault)
            mstore(add(m, 0x24), address())
            let ok := staticcall(gas(), target, m, 0x44, m, 0x20)
            approved := and(and(ok, gt(returndatasize(), 0x1f)), iszero(iszero(mload(m))))
        }
    }

    /// @dev Every message-execution or conductor call must build its calldata here. ConductorGatedByTurnstile reads
    /// the sender from the last 32 bytes whenever msg.sender is the Turnstile, so a call without this suffix would
    /// have its trailing arguments misread as the sender. Token calls and typed calls to the MessagingAdapter (not
    /// ConductorGatedByTurnstile) are exempt.
    function _buildTurnstileCallData(
        bytes memory data,
        bytes28 accountId,
        bool facilitated
    )
        private
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(data, accountId, facilitated ? FACILITATED_FLAG : bytes4(0));
    }

}
