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
import { IMessagingAdapter } from "../src/messaging/IMessagingAdapter.sol";
import { ITurnstile } from "../src/ITurnstile.sol";
import { Turnstile } from "../src/Turnstile.sol";
import { MessagingAdapter } from "../src/messaging/MessagingAdapter.sol";
import { MockMessagingAdapter } from "./mocks/MockMessagingAdapter.sol";
import {
    ADMIN_ROLE,
    PAUSER_ROLE,
    MESSAGING_ADAPTER_ROLE,
    SOLVER_ROLE,
    TERMINAL_ROLE,
    EPOCH_ROLE,
    TURNSTILE_ROLE
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
    uint64 hubChainId;
    uint256 withdrawNonce;

    Terminal terminal;
    Hub hub;
    Turnstile turnstile;
    mapping(uint64 => TransitAuthority) authorities;
    mapping(uint64 => Warehouse) warehouses;
    mapping(uint64 => Turnstile) turnstiles;
    mapping(uint64 => MockMessagingAdapter) adapters;

    mapping(uint64 => uint256) forkOf;

    function setUp() public virtual {
        uint64[] memory _spokeIDs = new uint64[](1);
        _spokeIDs[0] = ROBINHOOD_CHAIN_ID;
        _initTransit(ETH_CHAIN_ID, _spokeIDs);
    }

    function _initTransit(uint64 _hubID, uint64[] memory _spokeIDs) internal {
        hubChainId = _hubID;
        spokeIDs = _spokeIDs;

        _initChainConfigs();
        _initUsers();

        _createFork(hubChainId);
        for (uint256 i; i < spokeIDs.length; i++) {
            _createFork(spokeIDs[i]);
        }

        _deployCore(hubChainId);
        for (uint256 i; i < spokeIDs.length; i++) {
            _deployCore(spokeIDs[i]);
        }

        _selectChain(hubChainId);
        terminal = new Terminal(
            address(authorities[hubChainId]), hub, TransitTokenLib.formatAccountId(hubChainId, surplusRecipient)
        );
        _grantTerminalRole();

        _wireChains();
        _approveVault();
    }

    function _deployCore(uint64 chain) internal {
        _selectChain(chain);

        TransitAuthority authority = new TransitAuthority(admin);
        uint256 nonce = vm.getNonce(address(this));
        Turnstile chainTurnstile;
        if (chain == hubChainId) {
            chainTurnstile = new Turnstile(
                address(authority),
                vm.computeCreateAddress(address(this), nonce + 1),
                vm.computeCreateAddress(address(this), nonce + 2)
            );
            hub = new Hub(address(authority), address(chainTurnstile));
            turnstile = chainTurnstile;
        } else {
            chainTurnstile =
                new Turnstile(address(authority), address(0), vm.computeCreateAddress(address(this), nonce + 1));
        }
        Warehouse warehouse = new Warehouse(address(authority), vault, address(chainTurnstile), hubChainId);
        MockMessagingAdapter adapter = new MockMessagingAdapter(address(authority), address(chainTurnstile), hubChainId);

        authorities[chain] = authority;
        warehouses[chain] = warehouse;
        turnstiles[chain] = chainTurnstile;
        adapters[chain] = adapter;

        _grantRoles(chain);
    }

    function _wireChains() internal {
        for (uint256 i; i < spokeIDs.length; i++) {
            uint64 spoke = spokeIDs[i];
            _addRoute(spoke, hubChainId, address(adapters[hubChainId]));
            _addRoute(hubChainId, spoke, address(adapters[spoke]));
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

        bytes4[] memory adminSels = new bytes4[](1);
        adminSels[0] = Warehouse.setAssetWhitelisted.selector;

        bytes4[] memory pauseSels = new bytes4[](2);
        pauseSels[0] = Turnstile.pause.selector;
        pauseSels[1] = Turnstile.unpause.selector;

        bytes4[] memory receiveWithdrawalSels = new bytes4[](1);
        receiveWithdrawalSels[0] = Warehouse.receiveWithdrawal.selector;

        bytes4[] memory peerSels = new bytes4[](5);
        peerSels[0] = MessagingAdapter.setPeer.selector;
        peerSels[1] = MessagingAdapter.setChainGasLimit.selector;
        peerSels[2] = MessagingAdapter.removePeer.selector;
        peerSels[3] = MessagingAdapter.setAllowMessagesFromChain.selector;
        peerSels[4] = MessagingAdapter.setAllowMessagesToChain.selector;

        vm.startPrank(admin);
        authority.setTargetFunctionRole(address(warehouse), adminSels, ADMIN_ROLE);
        authority.setTargetFunctionRole(address(turnstiles[chain]), pauseSels, PAUSER_ROLE);
        authority.setTargetFunctionRole(address(warehouse), receiveWithdrawalSels, TURNSTILE_ROLE);
        authority.setTargetFunctionRole(address(adapters[chain]), peerSels, ADMIN_ROLE);

        authority.grantRole(MESSAGING_ADAPTER_ROLE, address(adapters[chain]));
        authority.grantRole(MESSAGING_ADAPTER_ROLE, address(warehouse));
        authority.grantRole(PAUSER_ROLE, admin);
        authority.grantRole(SOLVER_ROLE, solver);

        _wireTurnstile(chain);

        if (chain == hubChainId) {
            _wireHub(authority);

            bytes4[] memory withdrawSels = new bytes4[](1);
            withdrawSels[0] = Hub.facilitateOrderCancellation.selector;
            authority.setTargetFunctionRole(address(hub), withdrawSels, SOLVER_ROLE);

            bytes4[] memory facilitateSels = new bytes4[](1);
            facilitateSels[0] = Turnstile.facilitate.selector;
            authority.setTargetFunctionRole(address(turnstile), facilitateSels, SOLVER_ROLE);

            bytes4[] memory hubPauseSels = new bytes4[](2);
            hubPauseSels[0] = Hub.pause.selector;
            hubPauseSels[1] = Hub.unpause.selector;
            authority.setTargetFunctionRole(address(hub), hubPauseSels, PAUSER_ROLE);
        }
        vm.stopPrank();
    }

    function _wireTurnstile(uint64 chain) internal {
        TransitAuthority authority = authorities[chain];
        Turnstile chainTurnstile = turnstiles[chain];

        bytes4[] memory receiveSels = new bytes4[](1);
        receiveSels[0] = Turnstile.receiveMessage.selector;
        authority.setTargetFunctionRole(address(chainTurnstile), receiveSels, MESSAGING_ADAPTER_ROLE);

        bytes4[] memory turnstileAdminSels = new bytes4[](2);
        turnstileAdminSels[0] = Turnstile.setMessagingAdapter.selector;
        turnstileAdminSels[1] = Turnstile.setRoutable.selector;
        authority.setTargetFunctionRole(address(chainTurnstile), turnstileAdminSels, ADMIN_ROLE);

        bytes4[] memory turnstileSendSels = new bytes4[](2);
        turnstileSendSels[0] = Turnstile.sendDepositMessage.selector;
        turnstileSendSels[1] = Turnstile.sendWithdrawalMessage.selector;
        authority.setTargetFunctionRole(address(chainTurnstile), turnstileSendSels, MESSAGING_ADAPTER_ROLE);

        authority.grantRole(TURNSTILE_ROLE, address(chainTurnstile));
        chainTurnstile.setMessagingAdapter(adapters[chain]);
    }

    function _wireHub(TransitAuthority authority) internal {
        bytes4[] memory receiveDepositSels = new bytes4[](1);
        receiveDepositSels[0] = Hub.receiveDeposit.selector;
        authority.setTargetFunctionRole(address(hub), receiveDepositSels, TURNSTILE_ROLE);

        authority.grantRole(MESSAGING_ADAPTER_ROLE, address(hub));

        bytes4[] memory routedSels = new bytes4[](4);
        routedSels[0] = Hub.preApprove.selector;
        routedSels[1] = Hub.requestOrderCancellation.selector;
        routedSels[2] = Hub.reserve.selector;
        routedSels[3] = Hub.reserveAndRequest.selector;
        turnstile.setRoutable(address(hub), routedSels, true);

        bytes4[] memory executeSels = new bytes4[](1);
        executeSels[0] = Hub.executeWithdrawal.selector;
        turnstile.setRoutable(address(hub), executeSels, true);
    }

    function _grantTerminalRole() internal {
        bytes4[] memory moveSels = new bytes4[](2);
        moveSels[0] = Hub.transferFrom.selector;
        moveSels[1] = Hub.facilitateFill.selector;

        bytes4[] memory epochSels = new bytes4[](1);
        epochSels[0] = Hub.advanceEpoch.selector;

        vm.startPrank(admin);
        authorities[hubChainId].setTargetFunctionRole(address(hub), moveSels, TERMINAL_ROLE);
        authorities[hubChainId].grantRole(TERMINAL_ROLE, address(terminal));
        authorities[hubChainId].setTargetFunctionRole(address(hub), epochSels, EPOCH_ROLE);
        authorities[hubChainId].grantRole(EPOCH_ROLE, address(terminal));

        bytes4[] memory settleSels = new bytes4[](1);
        settleSels[0] = Terminal.settle.selector;
        authorities[hubChainId].setTargetFunctionRole(address(terminal), settleSels, SOLVER_ROLE);
        vm.stopPrank();
    }

    function _approveVault() internal {
        _approveVaultOn(hubChainId);
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
        return hub.balanceOf(TransitTokenLib.formatAccountId(hubChainId, user), TransitTokenLib.formatAssetId(assetChain, address(asset)));
    }

    function _depositOnChain(address user, uint256 amount, ERC20 asset, uint64 chain) internal {
        _selectChain(chain);
        deal(address(asset), user, amount);
        vm.startPrank(user);
        SafeTransferLib.safeApprove(address(asset), address(warehouses[chain]), amount);
        warehouses[chain].deposit(address(asset), amount, hubChainId, user, _messageGas(chain));
        vm.stopPrank();
    }

    function _messageGas(uint64 chain) internal view returns (uint64) {
        return chain == hubChainId ? 0 : 200_000;
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
        require(chain == hubChainId, "can only atomically withdraw on Hub");

        _selectChain(hubChainId);
        Hub.WithdrawalRequest memory request = _withdrawalRequestFor(user, amount, asset, chain);
        bytes memory validSignature = _signWithdraw(request, userPk);

        ITurnstile.FacilitatedCall[] memory calls = new ITurnstile.FacilitatedCall[](1);
        calls[0] = _facilitatedWithdrawal(request);
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = validSignature;
        uint256[] memory values = new uint256[](1);

        vm.prank(solver);
        turnstile.facilitate(calls, signatures, values);
        withdrawId = hub.hashWithdrawalRequest(request);
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
            ownerChainId: hubChainId,
            owner: user,
            to: user,
            assetId: TransitTokenLib.formatAssetId(chain, address(asset)),
            amount: amount,
            nonce: ++withdrawNonce,
            deadline: type(uint256).max,
            partiallyFillable: true
        });
    }

    function _facilitatedWithdrawal(Hub.WithdrawalRequest memory request)
        internal
        view
        returns (ITurnstile.FacilitatedCall memory)
    {
        return ITurnstile.FacilitatedCall({
            sender: request.owner,
            target: address(hub),
            data: abi.encodeCall(Hub.executeWithdrawal, (request, _messageGas(hubChainId))),
            feeAssetId: bytes32(0),
            fee: 0,
            nonce: request.nonce,
            deadline: request.deadline
        });
    }

    function _signWithdraw(Hub.WithdrawalRequest memory request, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = turnstile.hashFacilitatedCall(_facilitatedWithdrawal(request));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signOrder(Hub.Order memory order, uint256 pk) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, hub.hashOrder(order));
        return abi.encodePacked(r, s, v);
    }

}
