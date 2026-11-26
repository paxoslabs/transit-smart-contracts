// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { IRequestConductor } from "src/interfaces/IRequestConductor.sol";

/// @title Transit Terminal UserConductor
/// @notice Requested transfers of a user's own Depot balance between accounts.
/// @custom:security-contact security@paxoslabs.com
interface IUserConductor is IRequestConductor {

    /// @notice A user's signed transfer request.
    /// @param ownerChainId Owner's account chainId.
    /// @param owner Owner's account address.
    /// @param toChainId Recipient's account chainId.
    /// @param to Recipient's account address.
    /// @param assetChainId Chain of the asset transferred.
    /// @param asset Address of the asset transferred.
    /// @param amount Amount to transfer.
    /// @param deadline Timestamp after which execution consumes the request without moving funds.
    /// @param partiallyFillable Whether a short balance may be partially transferred.
    /// @param salt User-set salt to disambiguate otherwise identical requests.
    struct TransferRequest {
        uint64 ownerChainId;
        address owner;
        uint64 toChainId;
        address to;
        uint64 assetChainId;
        address asset;
        uint256 amount;
        uint256 deadline;
        bool partiallyFillable;
        bytes32 salt;
    }

    /// @notice A transfer request was executed.
    /// @param requestId Request id.
    /// @param amount Amount transferred.
    event TransferExecuted(bytes32 indexed requestId, uint256 amount);

    /// @notice Request a transfer, reserving the funds from the next epoch. The sender must be the owner.
    /// @param request Transfer request.
    function requestTransfer(TransferRequest calldata request) external;

    /// @notice Execute an effective transfer request. Callable by anyone.
    /// @param request Transfer request.
    function executeTransfer(TransferRequest calldata request) external;

    /// @notice Cancel an effective transfer request, releasing its reservation. The sender must be the owner.
    /// @param request Transfer request.
    function cancelTransfer(TransferRequest calldata request) external;

    /// @notice Hash of a transfer request, used as its request id.
    /// @param request Transfer request.
    /// @return Request id.
    function transferRequestId(TransferRequest memory request) external pure returns (bytes32);

}
