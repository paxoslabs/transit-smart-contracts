// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { Terminal } from "../src/Terminal.sol";
import { TransitAuthority } from "../src/TransitAuthority.sol";
import { Warehouse } from "../src/Warehouse.sol";
import { Hub } from "../src/Hub.sol";
import { TransitTokenLib } from "../src/helpers/TransitTokenLib.sol";
import { MessagingEndpoint } from "../src/messaging/MessagingEndpoint.sol";
import { IMessagingAdapter } from "../src/messaging/IMessagingAdapter.sol";
import { Turnstile } from "../src/Turnstile.sol";
import { MessagingAdapter } from "../src/messaging/MessagingAdapter.sol";
import { MockMessagingAdapter } from "./mocks/MockMessagingAdapter.sol";
import {
    ADMIN_ROLE,
    PAUSER_ROLE,
    MESSAGING_ADAPTER_ROLE,
    SOLVER_ROLE,
    TERMINAL_ROLE,
    EPOCH_ROLE
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
    Hub hub;
    Turnstile turnstile;
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
        terminal = new Terminal(
            address(authorities[hubID]), hub, TransitTokenLib.formatAccountId(hubID, surplusRecipient)
        );
        _grantTerminalRole();

        _wireChains();
        _approveVault();
    }

    function _deployCore(uint64 chain) internal {
        _selectChain(chain);

        TransitAuthority authority = new TransitAuthority(admin);
        if (chain == hubID) {
            hub = new Hub(address(authority), vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1));
            turnstile = new Turnstile(address(authority), hub);
        }
        Warehouse warehouse = new Warehouse(address(authority), vault);
        MockMessagingAdapter adapter = chain == hubID
            ? new MockMessagingAdapter(address(authority), address(turnstile), address(warehouse), hubID)
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
            _wireTurnstile(authority, receiveSels);


            bytes4[] memory withdrawSels = new bytes4[](2);
            withdrawSels[0] = Hub.facilitateWithdraw.selector;
            withdrawSels[1] = Hub.facilitateOrderCancellation.selector;
            authority.setTargetFunctionRole(address(hub), withdrawSels, SOLVER_ROLE);

            bytes4[] memory hubPauseSels = new bytes4[](2);
            hubPauseSels[0] = Hub.pause.selector;
            hubPauseSels[1] = Hub.unpause.selector;
            authority.setTargetFunctionRole(address(hub), hubPauseSels, PAUSER_ROLE);

            turnstile.setMessagingAdapter(adapters[chain]);
        }
        warehouse.setMessagingAdapter(adapters[chain]);
        vm.stopPrank();
    }

    function _wireTurnstile(TransitAuthority authority, bytes4[] memory receiveSels) internal {
        authority.setTargetFunctionRole(address(turnstile), receiveSels, MESSAGING_ADAPTER_ROLE);

        bytes4[] memory turnstileAdminSels = new bytes4[](2);
        turnstileAdminSels[0] = MessagingEndpoint.setMessagingAdapter.selector;
        turnstileAdminSels[1] = Turnstile.setRoutable.selector;
        authority.setTargetFunctionRole(address(turnstile), turnstileAdminSels, ADMIN_ROLE);

        bytes4[] memory turnstileSendSels = new bytes4[](1);
        turnstileSendSels[0] = Turnstile.send.selector;
        authority.setTargetFunctionRole(address(turnstile), turnstileSendSels, MESSAGING_ADAPTER_ROLE);

        bytes4[] memory receiveDepositSels = new bytes4[](1);
        receiveDepositSels[0] = Hub.receiveDeposit.selector;
        authority.setTargetFunctionRole(address(hub), receiveDepositSels, MESSAGING_ADAPTER_ROLE);

        authority.grantRole(MESSAGING_ADAPTER_ROLE, address(turnstile));
        authority.grantRole(MESSAGING_ADAPTER_ROLE, address(hub));

        bytes4[] memory routedSels = new bytes4[](5);
        routedSels[0] = Hub.preApprove.selector;
        routedSels[1] = Hub.requestOrderCancellation.selector;
        routedSels[2] = Hub.requestTransfer.selector;
        routedSels[3] = Hub.requestWithdrawal.selector;
        routedSels[4] = Hub.requestMint.selector;
        turnstile.setRoutable(address(hub), routedSels, true);
    }

    function _grantTerminalRole() internal {
        bytes4[] memory moveSels = new bytes4[](2);
        moveSels[0] = Hub.transferFrom.selector;
        moveSels[1] = Hub.facilitateFill.selector;

        bytes4[] memory epochSels = new bytes4[](1);
        epochSels[0] = Hub.advanceEpoch.selector;

        vm.startPrank(admin);
        authorities[hubID].setTargetFunctionRole(address(hub), moveSels, TERMINAL_ROLE);
        authorities[hubID].grantRole(TERMINAL_ROLE, address(terminal));
        authorities[hubID].setTargetFunctionRole(address(hub), epochSels, EPOCH_ROLE);
        authorities[hubID].grantRole(EPOCH_ROLE, address(terminal));

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
        return hub.balanceOf(TransitTokenLib.formatAccountId(hubID, user), TransitTokenLib.formatAssetId(assetChain, address(asset)));
    }

    function _depositOnChain(address user, uint256 amount, ERC20 asset, uint64 chain) internal {
        _selectChain(chain);
        deal(address(asset), user, amount);
        vm.startPrank(user);
        SafeTransferLib.safeApprove(address(asset), address(warehouses[chain]), amount);
        warehouses[chain].deposit(asset, amount, hubID, user, _messageGas(chain));
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
        Hub.WithdrawalRequest memory request = _withdrawalRequestFor(user, amount, asset, chain);
        bytes memory validSignature = _signWithdraw(request, userPk);

        Hub.WithdrawalRequest[] memory requests = new Hub.WithdrawalRequest[](1);
        requests[0] = request;
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = validSignature;
        uint256[] memory fees = new uint256[](1);

        vm.prank(solver);
        withdrawId = hub.facilitateWithdraw(requests, signatures, fees, _messageGas(hubID))[0];
    }

    function _withdrawalRequestFor(
        address user,
        uint256 amount,
        ERC20 asset,
        uint64 chain
    )
        internal
        returns (Hub.WithdrawalRequest memory)
    {
        return Hub.WithdrawalRequest({
            ownerChainId: hubID,
            owner: user,
            to: user,
            assetId: TransitTokenLib.formatAssetId(chain, address(asset)),
            amount: amount,
            maxFee: 0,
            nonce: ++withdrawNonce,
            deadline: type(uint256).max,
            partiallyFillable: true
        });
    }

    function _signWithdraw(Hub.WithdrawalRequest memory request, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = hub.hashWithdrawalRequest(request);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signOrder(Hub.Order memory order, uint256 pk) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, hub.hashOrder(order));
        return abi.encodePacked(r, s, v);
    }

}
