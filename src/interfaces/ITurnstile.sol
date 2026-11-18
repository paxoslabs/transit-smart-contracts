// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { IMessagingReceiver } from "src/interfaces/IMessagingReceiver.sol";

/// @title Transit Terminal Turnstile
/// @notice The local-chain entrypoint for Transit Terminal actions.  Functions as a meta-transaction orchestrator for
/// Conductor contracts, and custodies deposits into and releases withdrawals from the chain's VAULT.
/// @custom:security-contact security@paxoslabs.com
interface ITurnstile is IMessagingReceiver {

    /// @notice Type of executable action within the Transit Terminal system.  Determines how action calldata and
    /// cross-chain payloads are encoded and decoded.  Deposit and Withdrawal require special handling due to the need
    /// to manage custody of funds; all other actions are Generic.
    enum ActionType {
        Deposit,
        Withdrawal,
        Generic
    }

    /// @notice Execution status of messages.
    enum MessageStatus {
        None,
        Failed,
        Executed
    }

    /// @notice Body of a Deposit message, sent from a spoke chain to the hub chain.
    /// @param asset Address of the ERC20 asset being deposited.
    /// @param amount Amount of asset being deposited, denominated in native units.
    /// @param fromAccountId AccountId of depositor, credited before transfer to recipient.
    /// @param toAccountId AccountId of deposit recipient.
    /// @param facilitationFee Part of amount transferred from the recipient to feeReceiverAccountId once credited.
    /// @param feeReceiverAccountId AccountId receiving the facilitation fee; ignored if facilitationFee is 0.
    /// @param salt User-set salt used to disambiguate hashes of otherwise identical messages.
    struct DepositMessage {
        address asset;
        uint256 amount;
        bytes28 fromAccountId;
        bytes28 toAccountId;
        uint256 facilitationFee;
        bytes28 feeReceiverAccountId;
        bytes32 salt;
    }

    /// @notice Body of a Generic message.
    /// @param sender Message's sender.
    /// @param target Message's target address.
    /// @param data Message's calldata.
    /// @param deadline Action execution deadline.
    /// @param salt User-set salt used to disambiguate hashes of otherwise identical messages.
    struct GenericMessage {
        address sender;
        address target;
        bytes data;
        uint256 deadline;
        bytes32 salt;
    }

    /// @notice Body of a Withdrawal message, sent from the hub chain to the asset's spoke chain.
    /// @param asset Address of the ERC20 asset being withdrawn.
    /// @param amount Amount of asset being withdrawn, denominated in native units.
    /// @param to Recipient of withdrawn asset.  Bare address rather than composite accountId because chainId is implied
    /// by the message's destination chain.
    /// @param salt Hash of the originating WithdrawalAction, used to disambiguate hashes of otherwise identical
    /// messages.  A user-set salt could allow a griefing attack because WithdrawalMessage does not include any
    /// ownership information.
    struct WithdrawalMessage {
        address asset;
        uint256 amount;
        address to;
        bytes32 salt;
    }

    /// @notice Deposit request encoded as an action.
    /// @param ownerChainId Owner's account chainId. Must be this chain.
    /// @param owner Owner's account address. Must be the sender, or the signer when facilitated.
    /// @param asset Address of the ERC20 asset being deposited.
    /// @param amount Amount of asset being deposited, denominated in native units.
    /// @param toChainId ChainId element of accountId of deposit recipient.
    /// @param to Address element of accountId of deposit recipient.
    /// @param facilitationFee Part of amount the recipient pays feeReceiver on the hub once the deposit is credited, or
    /// 0 for none. At most amount.
    /// @param feeReceiverChainId ChainId element of accountId of the facilitation fee receiver.
    /// @param feeReceiver Address element of accountId of the facilitation fee receiver.
    /// @param deadline Deposit request submission deadline.
    /// @param dependsOn Hash of a message (see digestMessage) that must already be in this Turnstile's messageStatus
    /// as Executed (dispatched from, or received and executed on, this chain), or 0 for none.
    /// @param salt User-set salt used to disambiguate hashes of otherwise identical actions.
    /// @param permit Permit struct (ignored if `Permit.deadline` field is 0).
    struct DepositAction {
        uint64 ownerChainId;
        address owner;
        address asset;
        uint256 amount;
        uint64 toChainId;
        address to;
        uint256 facilitationFee;
        uint64 feeReceiverChainId;
        address feeReceiver;
        uint256 deadline;
        bytes32 dependsOn;
        bytes32 salt;
        Permit permit;
    }

    /// @notice ERC-2612 permit fields.
    /// @param deadline Permit deadline.
    /// @param v Permit `v` value.
    /// @param r Permit `r` value.
    /// @param s Permit `s` value.
    struct Permit {
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /// @notice Withdrawal request encoded as an action.
    /// @param ownerChainId Owner's account chainId.
    /// @param owner Owner's account address.
    /// @param to Recipient address.
    /// @param assetChainId Chain of the asset to withdraw; the withdrawal is paid out there.
    /// @param asset Address of the asset to withdraw.
    /// @param amount Amount of asset being withdrawn, denominated in native units.
    /// @param deadline Withdrawal request submission deadline.
    /// @param partiallyFillable Whether withdrawal may be partially executed if owner's balance is insufficient for
    /// full amount.
    /// @param dependsOn Hash of a message (see digestMessage) that must already be in this Turnstile's messageStatus
    /// as Executed (dispatched from, or received and executed on, this chain), or 0 for none.
    /// @param salt User-set salt used to disambiguate hashes of otherwise identical actions.
    struct WithdrawalAction {
        uint64 ownerChainId;
        address owner;
        address to;
        uint64 assetChainId;
        address asset;
        uint256 amount;
        uint256 deadline;
        bool partiallyFillable;
        bytes32 dependsOn;
        bytes32 salt;
    }

    /// @notice Generic contract call encoded as an action.
    /// @param ownerChainId Owner's account chainId. Must be this chain.
    /// @param owner Owner's account address. Must be the sender, or the signer when facilitated.
    /// @param target Action call target address.
    /// @param data Action calldata.
    /// @param deadline Action execution deadline.
    /// @param dependsOn Hash of a message (see digestMessage) that must already be in this Turnstile's messageStatus
    /// as Executed (dispatched from, or received and executed on, this chain), or 0 for none.
    /// @param salt User-set salt used to disambiguate hashes of otherwise identical actions.
    struct GenericAction {
        uint64 ownerChainId;
        address owner;
        address target;
        bytes data;
        uint256 deadline;
        bytes32 dependsOn;
        bytes32 salt;
    }

    /// @notice A single action to execute within a batch.
    /// @param actionType Type of the action.
    /// @param data ABI-encoded DepositAction, WithdrawalAction, or GenericAction.
    /// @param bridgeFee Cross-chain bridge fee (ignored by `quote`).
    /// @param messageGas Cross-chain destination message execution gas limit.
    struct Action {
        ActionType actionType;
        bytes data;
        uint256 bridgeFee;
        uint64 messageGas;
    }

    /// @notice A DepositAction was initiated and custody taken of underlying assets.
    /// @param asset Address of the ERC20 asset being deposited.
    /// @param from Address of the depositor.
    /// @param toAccountId Account id of deposit recipient.
    /// @param amount Amount of asset deposited, denominated in native units.
    event Deposit(address indexed asset, address indexed from, bytes28 indexed toAccountId, uint256 amount);

    /// @notice Withdrawn tokens were released from the VAULT.
    /// @param to Recipient.
    /// @param asset Asset withdrawn.
    /// @param amount Amount withdrawn.
    event WithdrawalReleased(address indexed to, address indexed asset, uint256 amount);

    /// @notice Asset whitelist entries have been updated.
    /// @param assets Assets updated.
    /// @param allowed Whether the assets may be deposited.
    event AssetWhitelistUpdated(address[] assets, bool allowed);

    /// @notice The MessagingAdapter contract address has been updated.
    /// @param adapter New MessagingAdapter address.
    event MessagingAdapterUpdated(address indexed adapter);

    /// @notice The HubWarehouseConductor contract address has been updated.
    /// @param hubWarehouseConductor New HubWarehouseConductor address.
    event HubWarehouseConductorUpdated(address indexed hubWarehouseConductor);

    /// @notice Generic message whitelist entries have been updated.
    /// @param target Call target.
    /// @param selectors Call function selectors.
    /// @param allowed Whether calldata is whitelisted.
    event GenericMessageWhitelistUpdated(address indexed target, bytes4[] selectors, bool allowed);

    /// @notice Message execution failed.
    /// @param sourceChainId Message's source EVM chainId.
    /// @param actionType Message's ActionType.
    /// @param messageHash Message's hash.
    /// @param body Message's body.
    event MessageFailed(uint64 indexed sourceChainId, ActionType indexed actionType, bytes32 messageHash, bytes body);

    /// @notice Message has been retried after previous failure.
    /// @param sourceChainId Message's source EVM chainId.
    /// @param actionType Message's ActionType.
    /// @param messageHash Message's hash.
    event MessageRetried(uint64 indexed sourceChainId, ActionType indexed actionType, bytes32 messageHash);

    /// @notice A message with an identical hash has already been processed.
    error MessageReplay();

    /// @notice The address has no code.
    error NoCode();

    /// @notice The function may only be used on the hub chain.
    error NotHubChain();

    /// @notice The VAULT address is zero.
    error VaultUnset();

    /// @notice A deposit amount is zero.
    error ZeroAssets();

    /// @notice A deposit's facilitation fee exceeds its amount.
    error FeeExceedsAmount();

    /// @notice The asset is not whitelisted for deposit.
    error AssetNotWhitelisted();

    /// @notice A permit failed and the existing allowance does not cover the amount.
    error PermitFailedAndAllowanceTooLow();

    /// @notice Releasing a withdrawal from the VAULT failed.
    error WithdrawalFailed();

    /// @notice An encoded call ran out of gas.
    error OutOfGas();

    /// @notice Message encodes a call which has not been authorized.
    error NotWhitelisted();

    /// @notice A retry was attempted of a message that had not failed.
    error NotFailed();

    /// @notice A contract required to process a message or action has not been set.
    error NoHandler();

    /// @notice Cross-chain fee was included for a same-chain action.
    error NoBridgeFee();

    /// @notice Lengths of parallel arrays do not match.
    error LengthMismatch();

    /// @notice Incorrect cross-chain fee amount was sent.
    error BridgeFeeMismatch();

    /// @notice An action's deadline has already passed.
    error Expired();

    /// @notice An account id is not a valid chainId and address pair.
    error InvalidAccount();

    /// @notice An action's owner is not its sender or signer.
    error NotOwner();

    /// @notice An action's dependsOn message has not executed.
    error DependencyNotExecuted();

    /// @notice Address holding the custodied tokens. It must approve this Turnstile for every whitelisted asset so
    /// withdrawals can be released.
    /// @return Vault address.
    function VAULT() external view returns (address);

    /// @notice Whether an asset may be deposited.
    /// @param asset Asset to query.
    /// @return Whether whitelisted.
    function assetWhitelisted(address asset) external view returns (bool);

    /// @notice Query the MessagingAdapter contract address.
    /// @return MessagingAdapter contract address.
    function messagingAdapter() external view returns (address);

    /// @notice Query the HubWarehouseConductor contract address.
    /// @return HubWarehouseConductor contract address.
    function hubWarehouseConductor() external view returns (address);

    /// @notice Query the execution status of a message.
    /// @param messageHash Message's hash.
    /// @return Message's execution status.
    function messageStatus(bytes32 messageHash) external view returns (MessageStatus);

    /// @notice Query whether an address-selector combination is whitelisted for generic messages.
    /// @param target Call target.
    /// @param selector Call function selector.
    /// @return Whether calldata is whitelisted.
    function genericMessageWhitelist(address target, bytes4 selector) external view returns (bool);

    /// @notice Set the MessagingAdapter contract address.
    /// @param adapter MessagingAdapter contract address.
    function setMessagingAdapter(address adapter) external;

    /// @notice Set the HubWarehouseConductor contract address. Only on the hub chain; the MessagingAdapter, which
    /// defines the hub chain, must be set first.
    /// @param _hubWarehouseConductor HubWarehouseConductor address.
    function setHubWarehouseConductor(address _hubWarehouseConductor) external;

    /// @notice Set the routability of an address-selector combination by generic messages.
    /// @dev Routable targets must use the `ConductorGatedByTurnstile` meta-transaction implementation in order to
    /// properly attribute a message to its sender.
    /// @param target Call target.
    /// @param selectors Call function selectors.
    /// @param allowed Whether calldata is whitelisted.
    function setRoutable(address target, bytes4[] calldata selectors, bool allowed) external;

    /// @notice Set whether assets may be deposited.
    /// @param assets Assets to update.
    /// @param allowed Whether the assets may be deposited.
    function setAssetWhitelisted(address[] calldata assets, bool allowed) external;

    /// @notice Disable sensitive functions in an emergency, including inbound message handling.
    function pause() external;

    /// @notice Enable sensitive functions.
    function unpause() external;

    /// @notice Execute a batch of actions.
    /// @dev `msg.value` must exactly equal the sum of action `bridgeFee`s.
    /// Same-chain actions must have a bridgeFee of 0.
    /// @param actions List of actions.
    /// @return messageHashes List of hashes of dispatched messages (zero hash if no message is sent).
    function dispatch(Action[] calldata actions) external payable returns (bytes32[] memory messageHashes);

    /// @notice Execute a batch of actions on behalf of users using ECDSA signature authorization.
    /// @dev `msg.value` must exactly equal the sum of action `bridgeFee`s.
    /// Same-chain actions must have a bridgeFee of 0.
    /// @param actions List of actions.
    /// @param signatures List of signatures for action sender authentication.
    /// @return messageHashes List of hashes of dispatched messages (zero hash if no message is sent).
    function facilitate(
        Action[] calldata actions,
        bytes[] calldata signatures
    )
        external
        payable
        returns (bytes32[] memory messageHashes);

    /// @notice Generate EIP-712 hash for Deposit action.
    /// @param action DepositAction to hash.
    /// @return Hash.
    function hashDepositAction(DepositAction memory action) external view returns (bytes32);

    /// @notice Generate EIP-712 hash for Withdrawal action.
    /// @param action WithdrawalAction to hash.
    /// @return Hash.
    function hashWithdrawalAction(WithdrawalAction memory action) external view returns (bytes32);

    /// @notice Generate EIP-712 hash for Generic action.
    /// @param action GenericAction to hash.
    /// @return Hash.
    function hashGenericAction(GenericAction memory action) external view returns (bytes32);

    /// @notice Calculate the hash of a message for use as a unique id and replay protection key.
    /// @param chainId Message's source EVM chainId.
    /// @param actionType Message's ActionType.
    /// @param body Message's body.
    /// @return The message's hash.
    function digestMessage(uint64 chainId, ActionType actionType, bytes memory body) external pure returns (bytes32);

    /// @notice Quote cross-chain bridge fees for a batch of actions.
    /// @param actions List of actions (`bridgeFee` is ignored).
    /// @return bridgeFees List of cross-chain bridge fees.
    function quote(Action[] calldata actions) external view returns (uint256[] memory bridgeFees);

    /// @notice Retry a previously failed message.
    /// @param sourceChainId Message's source EVM chainId.
    /// @param actionType Message's ActionType.
    /// @param body Message's body.
    function retry(uint64 sourceChainId, ActionType actionType, bytes calldata body) external;

}
