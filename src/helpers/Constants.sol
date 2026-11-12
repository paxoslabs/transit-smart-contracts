// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

bytes32 constant ADMIN_ROLE = bytes32(uint256(0x01));
bytes32 constant PAUSER_ROLE = bytes32(uint256(0x02));
bytes32 constant WAREHOUSE_CONDUCTOR_ROLE = bytes32(uint256(0x03));
bytes32 constant MANAGER_ROLE = bytes32(uint256(0x04));
bytes32 constant MESSAGING_ADAPTER_ROLE = bytes32(uint256(0x05));
bytes32 constant SOLVER_ROLE = bytes32(uint256(0x06));
bytes32 constant CONDUCTOR_ROLE = bytes32(uint256(0x07));
bytes32 constant EPOCH_ROLE = bytes32(uint256(0x08));
bytes32 constant TURNSTILE_ROLE = bytes32(uint256(0x09));
bytes32 constant FREEZE_MANAGER_ROLE = bytes32(uint256(0x0a));

/// @dev EIP-712 type hash for the Deposit action.
bytes32 constant DEPOSIT_ACTION_TYPEHASH = keccak256(
    "DepositAction(address asset,uint256 amount,uint64 toChainId,address to,uint256 deadline,bytes32 salt,Permit permit)Permit(uint256 deadline,uint8 v,bytes32 r,bytes32 s)"
);
/// @dev EIP-712 type hash for the Permit struct nested within the Deposit action.
bytes32 constant PERMIT_TYPEHASH = keccak256("Permit(uint256 deadline,uint8 v,bytes32 r,bytes32 s)");
/// @dev EIP-712 type hash for the Withdrawal action.
bytes32 constant WITHDRAWAL_ACTION_TYPEHASH = keccak256(
    "WithdrawalAction(uint64 ownerChainId,address owner,address to,bytes32 assetId,uint256 amount,uint256 deadline,bool partiallyFillable,bytes32 salt)"
);
/// @dev EIP-712 type hash for a Generic action.
bytes32 constant GENERIC_ACTION_TYPEHASH =
    keccak256("GenericAction(address target,bytes data,uint256 deadline,bytes32 salt)");
/// @dev EIP-712 type hash for a UserConductor transfer request.
bytes32 constant TRANSFER_REQUEST_TYPEHASH = keccak256(
    "TransferRequest(uint64 ownerChainId,address owner,uint64 toChainId,address to,bytes32 assetId,uint256 amount,uint256 deadline,bool partiallyFillable,bytes32 salt)"
);
/// @dev EIP-712 type hash for a SpotSwapConductor order.
bytes32 constant ORDER_TYPEHASH = keccak256(
    "Order(uint64 ownerChainId,address owner,bytes32 sellTokenId,bytes32 buyTokenId,uint256 sellAmount,uint256 buyAmount,uint64 receiverChainId,address receiver,uint256 expiresAt,bool partiallyFillable,bytes32 salt)"
);
/// @dev EIP-712 type hash for a DelayedSettlementSwapConductor order.
bytes32 constant DELAYED_SETTLEMENT_ORDER_TYPEHASH = keccak256(
    "DelayedSettlementOrder(uint64 ownerChainId,address owner,bytes32 sellTokenId,bytes32 buyTokenId,uint256 sellAmount,uint256 buyAmount,uint64 receiverChainId,address receiver,uint256 expiresAt,bool partiallyFillable,bool delayedSettlement,uint256 settlementPeriod,bytes32 salt)"
);
