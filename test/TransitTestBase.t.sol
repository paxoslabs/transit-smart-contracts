// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { Terminal } from "../src/Terminal.sol";
import { Warehouse } from "../src/Warehouse.sol";
import { WarehouseSpoke } from "../src/WarehouseSpoke.sol";

contract TransitTestBase is Test {

    uint64 constant ETH_CHAIN_ID = 1;
    uint64 constant ROBINHOOD_CHAIN_ID = 4663;

    struct ChainConfig {
        string rpcAlias;
        uint256 forkBlock;
        ERC20 usdc;
        ERC20 usdg;
        ERC20 usdt;
    }

    mapping(uint64 => ChainConfig) chainConfig;

    address alice;
    uint256 alicePk;
    address bob;
    uint256 bobPk;
    address withdrawSigner;
    uint256 withdrawSignerPk;
    address admin;
    uint256 adminPk;
    address solver;
    uint256 solverPk;

    uint64[] spokeIDs;
    uint64 hubID;

    Terminal terminal;
    Warehouse warehouse;
    mapping(uint64 => WarehouseSpoke) warehouses;

    mapping(uint64 => uint256) forkOf;

    function setUp() public virtual {
        uint64[] memory _spokeIDs = new uint64[](1);
        _spokeIDs[0] = ROBINHOOD_CHAIN_ID;
        _initTransit(ETH_CHAIN_ID, _spokeIDs);
    }

    function _initTransit(uint64 _hubID, uint64[] memory _spokeIDs) internal {
        // created so that we can potentially change tests to have different hub/spokes and other
        // configurations to test other ones
        hubID = _hubID;
        spokeIDs = _spokeIDs;

        _initChainConfigs();
        _initUsers();

        _createFork(hubID);
        warehouse = new Warehouse(admin);
        terminal = new Terminal();

        for (uint256 i; i < spokeIDs.length; i++) {
            _createFork(spokeIDs[i]);
            warehouses[spokeIDs[i]] = new WarehouseSpoke();
        }

        _launchTransitTokens();
        _approveVault();
    }

    function _approveVault() internal {
        _selectChain(hubID);
        ChainConfig storage config = chainConfig[hubID];
        ERC20[3] memory assets = [config.usdc, config.usdg, config.usdt];
        vm.startPrank(admin);
        for (uint256 i; i < assets.length; i++) {
            if (address(assets[i]) == address(0)) continue;
            SafeTransferLib.safeApprove(address(assets[i]), address(warehouse), type(uint256).max);
        }
        vm.stopPrank();
    }

    function _launchTransitTokens() internal {
        _launchTokensFor(hubID);
        for (uint256 i; i < spokeIDs.length; i++) {
            _launchTokensFor(spokeIDs[i]);
        }
    }

    function _launchTokensFor(uint64 chain) internal {
        ChainConfig storage config = chainConfig[chain];
        _launchToken(chain, config.usdc);
        _launchToken(chain, config.usdg);
        _launchToken(chain, config.usdt);
    }

    function _launchToken(uint64 chain, ERC20 asset) internal {
        if (address(asset) == address(0)) return;
        _selectChain(chain);
        string memory symbol = asset.symbol();
        uint8 decimals = asset.decimals();
        _selectChain(hubID);
        warehouse.launchToken(chain, asset, symbol, decimals);
    }

    // eth forkBlock pinned near tip at 2026-09-17T21:41Z; this RPC only serves state by block hash within ~128
    // blocks of tip, so it goes stale in ~25 min. rh serves by hash at any depth.
    function _initChainConfigs() internal {
        chainConfig[ETH_CHAIN_ID] = ChainConfig({
            rpcAlias: "eth",
            forkBlock: 25_999_956,
            usdc: ERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48),
            usdg: ERC20(0xe343167631d89B6Ffc58B88d6b7fB0228795491D),
            usdt: ERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7)
        });

        chainConfig[ROBINHOOD_CHAIN_ID] = ChainConfig({
            rpcAlias: "rh",
            forkBlock: 64_892_201,
            usdc: ERC20(address(0)),
            usdg: ERC20(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168),
            usdt: ERC20(address(0))
        });
    }

    function _createFork(uint64 chain) internal {
        ChainConfig storage config = chainConfig[chain];

        forkOf[chain] = config.forkBlock == 0
            ? vm.createSelectFork(config.rpcAlias)
            : vm.createSelectFork(config.rpcAlias, config.forkBlock);
    }

    function _selectChain(uint64 chain) internal {
        vm.selectFork(forkOf[chain]);
    }

    function _initUsers() internal {
        (alice, alicePk) = makeAddrAndKey("alice");
        (bob, bobPk) = makeAddrAndKey("bob");
        (withdrawSigner, withdrawSignerPk) = makeAddrAndKey("withdrawSigner");
        (admin, adminPk) = makeAddrAndKey("admin");
        (solver, solverPk) = makeAddrAndKey("solver");
    }

    function _depositOnChain(address user, uint256 amount, ERC20 asset, uint64 chain) internal {
        _selectChain(chain);
        deal(address(asset), user, amount);
        vm.startPrank(user);
        if (chain == hubID) {
            SafeTransferLib.safeApprove(address(asset), address(warehouse), amount);
            warehouse.deposit(asset, amount);
        } else {
            SafeTransferLib.safeApprove(address(asset), address(warehouses[chain]), amount);
            warehouses[chain].deposit(asset, amount);
        }
        vm.stopPrank();
    }

    function _withdrawOnChain(
        address user,
        uint256 amount,
        ERC20 asset,
        uint64 chain,
        bool shouldBeAtomic
    )
        internal
        returns (bytes32 withdrawId)
    {
        _selectChain(hubID);
        Warehouse.WithdrawRequest memory withdrawRequest = Warehouse.WithdrawRequest(asset, amount, chain, user);

        vm.startPrank(user);
        if (shouldBeAtomic) {
            require(chain == hubID, "can only atomically withdraw on Hub");
            bytes memory validSignature = _signWithdraw(withdrawRequest, withdrawSignerPk);
            withdrawId = warehouse.withdrawInstant(withdrawRequest, validSignature);
        } else {
            withdrawId = warehouse.requestWithdraw(withdrawRequest);
        }
        vm.stopPrank();
    }

    function _signWithdraw(Warehouse.WithdrawRequest memory request, uint256 pk) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                warehouse.WITHDRAW_REQUEST_TYPEHASH(), request.localAsset, request.amount, request.chain, request.to
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", warehouse.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signOrder(Terminal.Order memory order, uint256 pk) internal view returns (Terminal.SignedOrder memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                terminal.ORDER_TYPEHASH(),
                order.sellToken,
                order.buyToken,
                order.sellAmount,
                order.buyAmount,
                order.receiver
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", terminal.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return Terminal.SignedOrder(order, abi.encodePacked(r, s, v));
    }

}
