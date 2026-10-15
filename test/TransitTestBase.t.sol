// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { Terminal } from "../src/Terminal.sol";
import { OrderRegistry } from "../src/OrderRegistry.sol";
import { TransitAuthority } from "../src/TransitAuthority.sol";
import { Warehouse } from "../src/Warehouse.sol";
import { Hub } from "../src/Hub.sol";
import { MessagingEndpoint } from "../src/messaging/MessagingEndpoint.sol";
import { MessagingAdapter } from "../src/messaging/MessagingAdapter.sol";
import { MockMessagingAdapter } from "./mocks/MockMessagingAdapter.sol";
import {
    ADMIN_ROLE,
    PAUSER_ROLE,
    MESSAGING_ADAPTER_ROLE,
    SOLVER_ROLE,
    TERMINAL_ROLE,
    HUB_ROLE
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
    address admin;
    uint256 adminPk;
    address solver;
    uint256 solverPk;
    address vault;
    uint256 vaultPk;
    address surplusRecipient;

    uint64[] spokeIDs;
    uint64 hubID;
    uint256 withdrawNonce;

    Terminal terminal;
    OrderRegistry orderRegistry;
    Hub hub;
    mapping(uint64 => TransitAuthority) authorities;
    mapping(uint64 => Warehouse) warehouses;
    mapping(uint64 => MockMessagingAdapter) adapters;

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
        orderRegistry = new OrderRegistry(address(authorities[hubID]), hub);
        terminal = new Terminal(address(authorities[hubID]), hub, orderRegistry, surplusRecipient);
        _grantTerminalRole();

        _wireChains();
        _approveVault();
    }

    function _deployCore(uint64 chain) internal {
        _selectChain(chain);

        TransitAuthority authority = new TransitAuthority(admin);
        if (chain == hubID) hub = new Hub(address(authority));
        Warehouse warehouse = new Warehouse(address(authority), vault);
        MockMessagingAdapter adapter = chain == hubID
            ? new MockMessagingAdapter(address(authority), address(hub), address(warehouse), hubID)
            : new MockMessagingAdapter(address(authority), address(warehouse), address(0), hubID);

        authorities[chain] = authority;
        warehouses[chain] = warehouse;
        adapters[chain] = adapter;

        _grantRoles(chain);
    }

    function _wireChains() internal {
        for (uint256 i; i < spokeIDs.length; i++) {
            uint64 spoke = spokeIDs[i];
            _addRoute(spoke, hubID, address(adapters[hubID]));
            _addRoute(hubID, spoke, address(adapters[spoke]));
        }
    }

    function _addRoute(uint64 onChain, uint64 remoteChain, address remoteAdapter) internal {
        _selectChain(onChain);
        vm.startPrank(admin);
        adapters[onChain].setPeer(
            remoteChain, bytes32(uint256(uint160(remoteAdapter))), remoteChain, 200_000, 0, true, true
        );
        vm.stopPrank();
    }

    function _grantRoles(uint64 chain) internal {
        TransitAuthority authority = authorities[chain];
        Warehouse warehouse = warehouses[chain];

        bytes4[] memory adminSels = new bytes4[](2);
        adminSels[0] = MessagingEndpoint.setMessagingAdapter.selector;
        adminSels[1] = Warehouse.setAssetWhitelisted.selector;

        bytes4[] memory pauseSels = new bytes4[](2);
        pauseSels[0] = MessagingEndpoint.pause.selector;
        pauseSels[1] = MessagingEndpoint.unpause.selector;

        bytes4[] memory receiveSels = new bytes4[](1);
        receiveSels[0] = MessagingEndpoint.receiveMessage.selector;

        bytes4[] memory peerSels = new bytes4[](5);
        peerSels[0] = MessagingAdapter.setPeer.selector;
        peerSels[1] = MessagingAdapter.setChainGasLimit.selector;
        peerSels[2] = MessagingAdapter.removePeer.selector;
        peerSels[3] = MessagingAdapter.setAllowMessagesFromChain.selector;
        peerSels[4] = MessagingAdapter.setAllowMessagesToChain.selector;

        vm.startPrank(admin);
        authority.setTargetFunctionRole(address(warehouse), adminSels, ADMIN_ROLE);
        authority.setTargetFunctionRole(address(warehouse), pauseSels, PAUSER_ROLE);
        authority.setTargetFunctionRole(address(warehouse), receiveSels, MESSAGING_ADAPTER_ROLE);
        authority.setTargetFunctionRole(address(adapters[chain]), peerSels, ADMIN_ROLE);

        authority.grantRole(MESSAGING_ADAPTER_ROLE, address(adapters[chain]));
        authority.grantRole(PAUSER_ROLE, admin);
        authority.grantRole(SOLVER_ROLE, solver);

        if (chain == hubID) {
            authority.setTargetFunctionRole(address(hub), receiveSels, MESSAGING_ADAPTER_ROLE);

            bytes4[] memory hubAdminSels = new bytes4[](1);
            hubAdminSels[0] = MessagingEndpoint.setMessagingAdapter.selector;
            authority.setTargetFunctionRole(address(hub), hubAdminSels, ADMIN_ROLE);

            bytes4[] memory withdrawSels = new bytes4[](1);
            withdrawSels[0] = Hub.withdrawWithSignature.selector;
            authority.setTargetFunctionRole(address(hub), withdrawSels, SOLVER_ROLE);

            bytes4[] memory hubPauseSels = new bytes4[](2);
            hubPauseSels[0] = MessagingEndpoint.pause.selector;
            hubPauseSels[1] = MessagingEndpoint.unpause.selector;
            authority.setTargetFunctionRole(address(hub), hubPauseSels, PAUSER_ROLE);

            hub.setMessagingAdapter(adapters[chain]);

            bytes4[] memory registrySels = new bytes4[](1);
            registrySels[0] = Hub.setOrderRegistry.selector;
            authority.setTargetFunctionRole(address(hub), registrySels, ADMIN_ROLE);
        }
        warehouse.setMessagingAdapter(adapters[chain]);
        vm.stopPrank();
    }

    function _grantTerminalRole() internal {
        bytes4[] memory moveSels = new bytes4[](2);
        moveSels[0] = Hub.transferFrom.selector;
        moveSels[1] = Hub.advanceEpoch.selector;

        vm.startPrank(admin);
        authorities[hubID].setTargetFunctionRole(address(hub), moveSels, TERMINAL_ROLE);
        authorities[hubID].grantRole(TERMINAL_ROLE, address(terminal));

        bytes4[] memory fillSels = new bytes4[](1);
        fillSels[0] = OrderRegistry.fill.selector;
        authorities[hubID].setTargetFunctionRole(address(orderRegistry), fillSels, TERMINAL_ROLE);

        bytes4[] memory preApproveSels = new bytes4[](1);
        preApproveSels[0] = OrderRegistry.preApproveFor.selector;
        authorities[hubID].setTargetFunctionRole(address(orderRegistry), preApproveSels, HUB_ROLE);
        authorities[hubID].grantRole(HUB_ROLE, address(hub));
        hub.setOrderRegistry(orderRegistry);

        bytes4[] memory settleSels = new bytes4[](1);
        settleSels[0] = Terminal.settle.selector;
        authorities[hubID].setTargetFunctionRole(address(terminal), settleSels, SOLVER_ROLE);
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

        vm.startPrank(admin);
        for (uint256 i; i < assets.length; i++) {
            if (address(assets[i]) == address(0)) continue;
            address[] memory list = new address[](1);
            list[0] = address(assets[i]);
            warehouses[chain].setAssetWhitelisted(list, true);
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
        (admin, adminPk) = makeAddrAndKey("admin");
        (solver, solverPk) = makeAddrAndKey("solver");
        (vault, vaultPk) = makeAddrAndKey("vault");
        surplusRecipient = makeAddr("surplusRecipient");
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
        warehouses[chain].deposit(asset, amount, user, _messageGas(chain));
        vm.stopPrank();
    }

    function _messageGas(uint64 chain) internal view returns (uint64) {
        return chain == hubID ? 0 : 200_000;
    }

    function _withdrawOnChain(
        address user,
        uint256 userPk,
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
        Hub.WithdrawRequest memory request = _withdrawRequestFor(user, amount, asset, chain);
        bytes memory validSignature = _signWithdraw(request, userPk);

        Hub.WithdrawRequest[] memory requests = new Hub.WithdrawRequest[](1);
        requests[0] = request;
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = validSignature;
        uint256[] memory fees = new uint256[](1);

        vm.prank(solver);
        withdrawId = hub.withdrawWithSignature(requests, signatures, fees, _messageGas(hubID))[0];
    }

    function _withdrawRequestFor(
        address user,
        uint256 amount,
        ERC20 asset,
        uint64 chain
    )
        internal
        returns (Hub.WithdrawRequest memory)
    {
        return Hub.WithdrawRequest({
            owner: user,
            asset: asset,
            assetChainId: chain,
            amount: amount,
            maxFee: 0,
            to: user,
            nonce: ++withdrawNonce
        });
    }

    function _signWithdraw(Hub.WithdrawRequest memory request, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = hub.hashWithdrawRequest(request);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signOrder(OrderRegistry.Order memory order, uint256 pk) internal view returns (Terminal.Fill memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                orderRegistry.ORDER_TYPEHASH(),
                order.sellTokenChainId,
                order.sellToken,
                order.buyTokenChainId,
                order.buyToken,
                order.sellAmount,
                order.buyAmount,
                order.receiver,
                order.expiresAt,
                order.salt,
                order.partiallyFillable
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", orderRegistry.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return Terminal.Fill(order, abi.encodePacked(r, s, v), order.sellAmount, order.buyAmount);
    }

}
