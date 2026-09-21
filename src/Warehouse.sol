// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { ERC20 } from "solady/tokens/ERC20.sol";
import { LibString } from "solady/utils/LibString.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { WarehouseSpoke } from "./WarehouseSpoke.sol";
import { TransitToken } from "./TransitToken.sol";

contract Warehouse is WarehouseSpoke {

    address public vault;

    constructor(address vault_) {
        vault = vault_;
    }

    mapping(ERC20 => mapping(uint64 => TransitToken)) transitTokenByLocalAddressAndChainID;

    /// TODO: Decide the WithdrawRequest fields. A signed request with no nonce and no deadline replays,
    /// so one backend signature can be resubmitted until the warehouse drains. If you add them, tell me
    /// and I'll match the typehash and the test base's _signWithdraw.
    struct WithdrawRequest {
        ERC20 localAsset;
        uint256 amount;
        uint64 chain;
        address to;
    }

    bytes32 public constant WITHDRAW_REQUEST_TYPEHASH =
        keccak256("WithdrawRequest(address asset,uint256 amount,uint64 chain,address to)");

    // Will be owner ownly
    // Worth considering how this puts a lot of trust on owner to get this right with decimals and symbol, getting it
    // right. But if this warehouse is say on ETH, and the localAddress is on Arbitrum, then this contract has no way to
    // confirm this so we have to take it optimistically We could message this info with launchToken being triggered on
    // local chain, but for now lets not worry about building a whole flow for that
    /// TODO: Decide access control for launchToken. Your comment says owner only, but we have not picked
    /// an auth approach yet, so it is currently callable by anyone.
    function launchToken(uint64 chainID, ERC20 localAddress, string calldata symbol, uint8 decimals) external {
        require(chainID != 0, "chain");
        require(address(localAddress) != address(0), "asset");
        TransitToken token = transitTokenByLocalAddressAndChainID[localAddress][chainID];
        require(address(token) == address(0), "launched");
        transitTokenByLocalAddressAndChainID[localAddress][chainID] =
            new TransitToken(string.concat("transit_", LibString.toString(chainID), "_", symbol), decimals);
    }

    function deposit(ERC20 asset, uint256 amount) external override {
        // since this deposit is on the hub chain no messaging is required.
        TransitToken transitToken = transitTokenByLocalAddressAndChainID[asset][uint64(block.chainid)];
        SafeTransferLib.safeTransferFrom(address(asset), msg.sender, vault, amount);
        transitToken.mint(msg.sender, amount);
    }

    function getToken(uint64 chainID, ERC20 localAddress) external view returns (ERC20) {
        require(chainID != 0, "chain");
        require(address(localAddress) != address(0), "asset");
        TransitToken token = transitTokenByLocalAddressAndChainID[localAddress][chainID];
        require(address(token) != address(0), "not launched");
        return token;
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) { }

    function withdrawInstant(
        WithdrawRequest calldata request,
        bytes calldata signature
    )
        external
        returns (bytes32 withdrawId)
    {
        /// TODO: Decide what withdrawId is and where it comes from. It is currently never assigned, so this
        /// always returns bytes32(0).
        TransitToken transitToken = transitTokenByLocalAddressAndChainID[request.localAsset][request.chain];
        transitToken.burn(msg.sender, request.amount);
        if (request.chain == block.chainid) {
            SafeTransferLib.safeTransferFrom(address(request.localAsset), vault, request.to, request.amount);
        } else {
            // TODO: Set this up with crosschain messaging
        }
    }

    function requestWithdraw(WithdrawRequest calldata request) external returns (bytes32 withdrawId) { }

}
