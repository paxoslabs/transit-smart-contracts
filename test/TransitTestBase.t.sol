// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { Terminal } from "../src/Terminal.sol";
import { TransitAuthority } from "../src/warehouse/TransitAuthority.sol";
import { Warehouse } from "../src/warehouse/Warehouse.sol";
import { WarehouseHub } from "../src/warehouse/WarehouseHub.sol";
import { CrosschainAdapter } from "../src/warehouse/crosschain/CrosschainAdapter.sol";
import { MockCrosschainModule } from "./mocks/MockCrosschainModule.sol";
import {
    ADMIN_ROLE,
    PAUSER_ROLE,
    WAREHOUSE_ROLE,
    CROSSCHAIN_MODULE_ROLE,
    SOLVER_ROLE,
    TERMINAL_ROLE
} from "../src/helpers/Constants.sol";

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
    address vault;
    uint256 vaultPk;

    uint64[] spokeIDs;
    uint64 hubID;
    uint256 withdrawNonce;

    Terminal terminal;
    WarehouseHub hub;
    mapping(uint64 => TransitAuthority) authorities;
    mapping(uint64 => Warehouse) warehouses;
    mapping(uint64 => MockCrosschainModule) modules;

    mapping(uint64 => uint256) forkOf;

    function setUp() public virtual {
        uint64[] memory _spokeIDs = new uint64[](1);
        _spokeIDs[0] = ROBINHOOD_CHAIN_ID;
        _initTransit(ETH_CHAIN_ID, _spokeIDs);
    }

    function _initTransit(uint64 _hubID, uint64[] memory _spokeIDs) internal {
        hubID = _hubID;
        spokeIDs = _spokeIDs;

        _initChainConfigs();
        _initUsers();

        _createFork(hubID);
        for (uint256 i; i < spokeIDs.length; i++) {
            _createFork(spokeIDs[i]);
        }

        _deployCore(hubID);
        for (uint256 i; i < spokeIDs.length; i++) {
            _deployCore(spokeIDs[i]);
        }

        _selectChain(hubID);
        terminal = new Terminal(hub);
        _grantTerminalRole();

        _wireChains();
        _approveVault();
    }

    function _deployCore(uint64 chain) internal {
        _selectChain(chain);

        TransitAuthority authority = new TransitAuthority(admin);
        if (chain == hubID) hub = new WarehouseHub(address(authority));
        Warehouse warehouse =
            new Warehouse(address(authority), hubID, vault, chain == hubID ? hub : WarehouseHub(address(0)));
        MockCrosschainModule module = new MockCrosschainModule(address(authority), address(warehouse));

        authorities[chain] = authority;
        warehouses[chain] = warehouse;
        modules[chain] = module;

        _grantRoles(chain);
    }

    function _wireChains() internal {
        for (uint256 i; i < spokeIDs.length; i++) {
            uint64 spoke = spokeIDs[i];
            _addRoute(spoke, hubID, address(modules[hubID]));
            _addRoute(hubID, spoke, address(modules[spoke]));
        }
    }

    function _addRoute(uint64 onChain, uint64 remoteChain, address remoteModule) internal {
        _selectChain(onChain);
        vm.startPrank(admin);
        warehouses[onChain].addChain(remoteChain, true, true, 200_000, 0);
        modules[onChain].setPeer(remoteChain, bytes32(uint256(uint160(remoteModule))), remoteChain);
        vm.stopPrank();
    }

    function _grantRoles(uint64 chain) internal {
        TransitAuthority authority = authorities[chain];
        Warehouse warehouse = warehouses[chain];

        bytes4[] memory adminSels = new bytes4[](6);
        adminSels[0] = Warehouse.setWithdrawSigner.selector;
        adminSels[1] = Warehouse.setSendModule.selector;
        adminSels[2] = Warehouse.addChain.selector;
        adminSels[3] = Warehouse.setChainGasLimit.selector;
        adminSels[4] = Warehouse.setAllowMessagesFromChain.selector;
        adminSels[5] = Warehouse.setAllowMessagesToChain.selector;

        bytes4[] memory pauseSels = new bytes4[](1);
        pauseSels[0] = Warehouse.setPaused.selector;

        bytes4[] memory receiveSels = new bytes4[](1);
        receiveSels[0] = Warehouse.receiveMessage.selector;

        bytes4[] memory peerSels = new bytes4[](1);
        peerSels[0] = CrosschainAdapter.setPeer.selector;

        vm.startPrank(admin);
        authority.setTargetFunctionRole(address(warehouse), adminSels, ADMIN_ROLE);
        authority.setTargetFunctionRole(address(warehouse), pauseSels, PAUSER_ROLE);
        authority.setTargetFunctionRole(address(warehouse), receiveSels, CROSSCHAIN_MODULE_ROLE);
        authority.setTargetFunctionRole(address(modules[chain]), peerSels, ADMIN_ROLE);

        authority.grantRole(WAREHOUSE_ROLE, address(warehouse));
        authority.grantRole(CROSSCHAIN_MODULE_ROLE, address(modules[chain]));
        authority.grantRole(PAUSER_ROLE, admin);
        authority.grantRole(SOLVER_ROLE, solver);

        warehouse.setSendModule(modules[chain]);
        warehouse.setWithdrawSigner(withdrawSigner);

        if (chain == hubID) {
            bytes4[] memory hubSels = new bytes4[](2);
            hubSels[0] = WarehouseHub.enter.selector;
            hubSels[1] = WarehouseHub.exit.selector;
            authority.setTargetFunctionRole(address(hub), hubSels, WAREHOUSE_ROLE);
        }
        vm.stopPrank();
    }

    function _grantTerminalRole() internal {
        bytes4[] memory moveSels = new bytes4[](1);
        moveSels[0] = WarehouseHub.move.selector;

        vm.startPrank(admin);
        authorities[hubID].setTargetFunctionRole(address(hub), moveSels, TERMINAL_ROLE);
        authorities[hubID].grantRole(TERMINAL_ROLE, address(terminal));
        vm.stopPrank();
    }

    function _approveVault() internal {
        _approveVaultOn(hubID);
        for (uint256 i; i < spokeIDs.length; i++) {
            _approveVaultOn(spokeIDs[i]);
        }
    }

    function _approveVaultOn(uint64 chain) internal {
        _selectChain(chain);
        ChainConfig storage config = chainConfig[chain];
        ERC20[3] memory assets = [config.usdc, config.usdg, config.usdt];

        vm.startPrank(vault);
        for (uint256 i; i < assets.length; i++) {
            if (address(assets[i]) == address(0)) continue;
            SafeTransferLib.safeApprove(address(assets[i]), address(warehouses[chain]), type(uint256).max);
        }
        vm.stopPrank();
    }

    // eth forkBlock pinned near tip; this RPC only serves state by block hash within ~128 blocks of
    // tip, so it goes stale in ~25 min. rh serves by hash at any depth.
    function _initChainConfigs() internal {
        chainConfig[ETH_CHAIN_ID] = ChainConfig({
            rpcAlias: "eth",
            forkBlock: 0,
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
        (vault, vaultPk) = makeAddrAndKey("vault");
    }

    function _vaultOf(uint64) internal view returns (address) {
        return vault;
    }

    function _hubBalance(address user, uint64 assetChain, ERC20 asset) internal view returns (uint256) {
        return hub.balanceOf(user, assetChain, address(asset));
    }

    function _depositOnChain(address user, uint256 amount, ERC20 asset, uint64 chain) internal {
        _selectChain(chain);
        deal(address(asset), user, amount);
        vm.startPrank(user);
        SafeTransferLib.safeApprove(address(asset), address(warehouses[chain]), amount);
        warehouses[chain].deposit(asset, amount, user);
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
        require(shouldBeAtomic, "only signed withdraws are supported");
        require(chain == hubID, "can only atomically withdraw on Hub");

        _selectChain(hubID);
        Warehouse.WithdrawRequest memory request = _withdrawRequestFor(user, amount, asset, chain);
        bytes memory validSignature = _signWithdraw(request, withdrawSignerPk);

        vm.prank(user);
        withdrawId = warehouses[hubID].withdrawWithSignature(request, validSignature);
    }

    function _withdrawRequestFor(
        address user,
        uint256 amount,
        ERC20 asset,
        uint64 chain
    )
        internal
        returns (Warehouse.WithdrawRequest memory)
    {
        return Warehouse.WithdrawRequest({
            owner: user,
            asset: asset,
            assetChainId: chain,
            amount: amount,
            to: user,
            nonce: ++withdrawNonce,
            deadline: block.timestamp + 1 days
        });
    }

    function _signWithdraw(Warehouse.WithdrawRequest memory request, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = warehouses[hubID].hashWithdrawRequest(request);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signOrder(Terminal.Order memory order, uint256 pk) internal view returns (Terminal.SignedOrder memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                terminal.ORDER_TYPEHASH(),
                order.sellTokenChainId,
                order.sellToken,
                order.buyTokenChainId,
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
