// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";
import { EIP712 } from "solady/utils/EIP712.sol";
import { Hub } from "./Hub.sol";
import { TransitTokenLib } from "./helpers/TransitTokenLib.sol";

contract DelayedSettlementAssetRegistry is AccessManaged, EIP712 {

    struct MintRequest {
        uint64 ownerChainId;
        address owner;
        bytes32 assetId;
        uint256 amount;
        uint256 maxFee;
        uint256 nonce;
        uint256 deadline;
    }

    uint256 public constant COLLATERALIZATION_RATIO = 100;

    bytes32 public constant MINT_REQUEST_TYPEHASH = keccak256(
        "MintRequest(uint64 ownerChainId,address owner,bytes32 assetId,uint256 amount,uint256 maxFee,uint256 nonce,uint256 deadline)"
    );

    Hub public immutable HUB;

    mapping(bytes32 requestId => bool) public requestExecuted;

    error BadSignature();
    error RequestReplay();
    error LengthMismatch();
    error EmptyBatch();
    error ExceedsMaxFee();
    error Expired(bytes32 id);
    error FlaggedAssetId();

    constructor(address _authority, Hub _hub) AccessManaged(_authority) {
        HUB = _hub;
    }

    /// TODO: Decide the EIP712 domain name and version. Currently "Transit Delayed Settlement" and "1".
    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return ("Transit Delayed Settlement", "1");
    }

    function mint(bytes32 accountId, bytes32 assetId, uint256 amount) external restricted {
        _mint(accountId, assetId, amount);
    }

    function facilitateMint(
        MintRequest[] calldata requests,
        bytes[] calldata signatures,
        uint256[] calldata fees
    )
        external
        restricted
    {
        if (requests.length == 0) revert EmptyBatch();
        if (requests.length != signatures.length || requests.length != fees.length) revert LengthMismatch();

        for (uint256 i; i < requests.length; i++) {
            MintRequest calldata request = requests[i];

            bytes32 requestId = hashMintRequest(request);
            if (requestExecuted[requestId]) revert RequestReplay();
            if (ECDSA.recoverCalldata(requestId, signatures[i]) != request.owner) revert BadSignature();
            requestExecuted[requestId] = true;

            if (block.timestamp > request.deadline) revert Expired(requestId);
            if (fees[i] > request.maxFee) revert ExceedsMaxFee();

            bytes32 ownerAccountId = TransitTokenLib.formatAccountId(request.ownerChainId, request.owner);
            /// TODO: Decide fee recipient. Currently msg.sender.
            if (fees[i] != 0) {
                HUB.transferFrom(ownerAccountId, _hubAccountId(msg.sender), request.assetId, fees[i]);
            }
            _mint(ownerAccountId, request.assetId, request.amount - fees[i]);
        }
    }

    function _mint(bytes32 accountId, bytes32 assetId, uint256 amount) internal {
        if (TransitTokenLib.hasFlags(assetId)) revert FlaggedAssetId();
        HUB.transferFrom(accountId, _hubAccountId(address(this)), assetId, amount);
        HUB.mint(accountId, TransitTokenLib.formatMarginAssetId(assetId), amount * COLLATERALIZATION_RATIO);
    }

    function _hubAccountId(address account) internal view returns (bytes32) {
        return TransitTokenLib.formatAccountId(uint64(block.chainid), account);
    }

    function hashMintRequest(MintRequest memory request) public view returns (bytes32) {
        return _hashTypedData(
            keccak256(
                abi.encode(
                    MINT_REQUEST_TYPEHASH,
                    request.ownerChainId,
                    request.owner,
                    request.assetId,
                    request.amount,
                    request.maxFee,
                    request.nonce,
                    request.deadline
                )
            )
        );
    }

}
