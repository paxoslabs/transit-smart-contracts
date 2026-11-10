// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { IMessagingReceiver } from "../messaging/IMessagingReceiver.sol";

/// @title Transit Terminal Turnstile
/// @notice The local-chain entrypoint for Transit Terminal actions.  Functions as a meta-transaction orchestrator for
/// Conductor contracts.
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
        Expired,
        Executed
    }

    /// @notice Body of a Deposit message, sent from a spoke chain to the hub chain.
    /// @param asset Address of the ERC20 asset being deposited.
    /// @param amount Amount of asset being deposited, denominated in native units.
    /// @param toAccountId AccountId of deposit recipient.
    /// @param salt Internally generated salt used to disambiguate hashes of otherwise identical messages.
    struct DepositMessage {
        address asset;
        uint256 amount;
        bytes32 toAccountId;
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
    /// @param salt Internally generated salt used to disambiguate hashes of otherwise identical messages.
    struct WithdrawalMessage {
        address asset;
        uint256 amount;
        address to;
        bytes32 salt;
    }

    /// @notice Deposit request encoded as an action.
    /// @param asset Address of the ERC20 asset being deposited.
    /// @param amount Amount of asset being deposited, denominated in native units.
    /// @param toChainId ChainId element of accountId of deposit recipient (address element cannot be specified and must
    /// match sender).
    /// @param deadline Deposit request submission deadline.
    /// @param salt User-set salt used to disambiguate hashes of otherwise identical actions (ignored for
    /// non-facilitated actions).
    /// @param permit Permit struct (ignored if `Permit.deadline` field is 0).
    struct DepositAction {
        address asset;
        uint256 amount;
        uint64 toChainId;
        uint256 deadline;
        bytes32 salt;
        Permit permit;
    }

    /// @notice ERC-2612 or Uniswap Permit2 fields.
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
    /// @param assetId Composite id of asset to withdraw.
    /// @param amount Amount of asset being withdrawn, denominated in native units.
    /// @param deadline Withdrawal request submission deadline.
    /// @param partiallyFillable Whether withdrawal may be partially executed if owner's balance is insufficient for
    /// full amount.
    /// @param salt User-set salt used to disambiguate hashes of otherwise identical actions.
    struct WithdrawalAction {
        uint64 ownerChainId;
        address owner;
        address to;
        bytes32 assetId;
        uint256 amount;
        uint256 deadline;
        bool partiallyFillable;
        bytes32 salt;
    }

    /// @notice Generic contract call encoded as an action.
    /// @param target Action call target address.
    /// @param data Action calldata.
    /// @param deadline Action execution deadline.
    /// @param salt User-set salt used to disambiguate hashes of otherwise identical actions.
    struct GenericAction {
        address target;
        bytes data;
        uint256 deadline;
        bytes32 salt;
    }

    /// @notice A DepositAction was initiated and custody taken of underlying assets.
    /// @param asset Address of the ERC20 asset being deposited.
    /// @param from Address of the depositor.
    /// @param toAccountId Account id of deposit recipient.
    /// @param amount Amount of asset deposited, denominated in native units.
    event Deposit(address indexed asset, address indexed from, bytes32 indexed toAccountId, uint256 amount);

    /// @notice The MessagingAdapter contract address has been updated.
    /// @param adapter New MessagingAdapter address.
    event MessagingAdapterUpdated(address indexed adapter);

    /// @notice The HubWarehouseConductor contract address has been updated.
    /// @param hubWarehouseConductor New HubWarehouseConductor address.
    event HubWarehouseConductorUpdated(address indexed hubWarehouseConductor);

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

    /// @notice Message execution failed because its deadline has passed.
    /// @param sourceChainId Message's source EVM chainId.
    /// @param actionType Message's ActionType.
    /// @param messageHash Message's hash.
    event MessageExpired(uint64 indexed sourceChainId, ActionType indexed actionType, bytes32 messageHash);

    /// @notice A message with an identical hash has already been processed.
    error MessageReplay();

    /// @notice The MessagingAdapter has not been set.
    error NoAdapter();

    /// @notice An encoded call ran out of gas.
    error OutOfGas();

    /// @notice Message encodes a call which has not been authorized.
    error NotRoutable();

    /// @notice A retry was attempted of a message that had not failed.
    error NotFailed();

    /// @notice A contract required to process a message or action has not been set.
    error NoHandler();

    /// @notice Cross-chain fee was included for a same-chain action.
    error NoFare();

    /// @notice Lengths of parallel arrays do not match.
    error LengthMismatch();

    /// @notice Incorrect cross-chain fee amount was sent.
    error FareMismatch();

    /// @notice An action's deadline has already passed.
    error Expired();

    /// @notice Query the EIP-712 type hash for the Deposit action.
    /// @return EIP-712 Deposit type hash.
    function DEPOSIT_ACTION_TYPEHASH() external view returns (bytes32);

    /// @notice Query the EIP-712 type hash for the Permit struct nested within the Deposit action.
    /// @return EIP-712 Permit type hash.
    function PERMIT_TYPEHASH() external view returns (bytes32);

    /// @notice Query the EIP-712 type hash for the Withdrawal action.
    /// @return EIP-712 Withdrawal type hash.
    function WITHDRAWAL_ACTION_TYPEHASH() external view returns (bytes32);

    /// @notice Query the EIP-712 type hash for a Generic action.
    /// @return EIP-712 Generic type hash.
    function GENERIC_ACTION_TYPEHASH() external view returns (bytes32);

    /// @notice Query the SpokeWarehouse contract address.
    /// @return SpokeWarehouse contract address.
    function SPOKE_WAREHOUSE() external view returns (address);

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

    /// @notice Query whether an address-selector combination is routable by generic messages.
    /// @param target Call target.
    /// @param selector Call function selector.
    /// @return Whether calldata is routable.
    function routable(address target, bytes4 selector) external view returns (bool);

    /// @notice Set the MessagingAdapter contract address.
    /// @param adapter MessagingAdapter contract address.
    function setMessagingAdapter(address adapter) external;

    /// @notice Set the HubWarehouseConductor contract address.
    /// @param _hubWarehouseConductor HubWarehouseConductor address.
    function setHubWarehouseConductor(address _hubWarehouseConductor) external;

    /// @notice Set the routability of an address-selector combination by generic messages.
    /// @param target Call target.
    /// @param selectors Call function selectors.
    /// @param allowed Whether calldata is routable.
    function setRoutable(address target, bytes4[] calldata selectors, bool allowed) external;

    /// @notice Disable sensitive functions in an emergency.
    function pause() external;

    /// @notice Enable sensitive functions.
    function unpause() external;

    /// @notice Execute a batch of actions.
    /// @param actionTypes List of action types.
    /// @param actionData List of action data.
    /// @param fares List of cross-chain bridge fees.
    /// @param messageGas List of cross-chain destination message execution gas limits.
    /// @return messageHashes List of hashes of dispatched messages.
    function dispatch(
        ActionType[] calldata actionTypes,
        bytes[] calldata actionData,
        uint256[] calldata fares,
        uint64[] calldata messageGas
    )
        external
        payable
        returns (bytes32[] memory messageHashes);

    /// @notice Execute a batch of actions on behalf of users using ECDSA signature authorization.
    /// @param actionTypes List of action types.
    /// @param actionData List of action data.
    /// @param signatures List of signatures for action sender authentication.
    /// @param fares List of cross-chain bridge fees.
    /// @param messageGas List of cross-chain destination message execution gas limits.
    function facilitate(
        ActionType[] calldata actionTypes,
        bytes[] calldata actionData,
        bytes[] calldata signatures,
        uint256[] calldata fares,
        uint64[] calldata messageGas
    )
        external
        payable;

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

    /// @notice Calculate the hash of a message.
    /// @param chainId Message's source EVM chainId.
    /// @param actionType Message's ActionType.
    /// @param body Message's body.
    /// @return The message's hash.
    function digestMessage(uint64 chainId, ActionType actionType, bytes memory body) external pure returns (bytes32);

    /// @notice Quote cross-chain bridge fees for a batch of actions.
    /// @param actionTypes List of action types.
    /// @param actionData List of action data.
    /// @param messageGas List of cross-chain destination message execution gas limits.
    /// @return fares List of cross-chain bridge fees.
    function quote(
        ActionType[] calldata actionTypes,
        bytes[] calldata actionData,
        uint64[] calldata messageGas
    )
        external
        view
        returns (uint256[] memory fares);

    /// @notice Retry a previously failed message.
    /// @param sourceChainId Message's source EVM chainId.
    /// @param actionType Message's ActionType.
    /// @param body Message's body.
    function retry(uint64 sourceChainId, ActionType actionType, bytes calldata body) external;

}
