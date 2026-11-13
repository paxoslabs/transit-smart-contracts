// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { dispatchOne } from "./helpers/DispatchOne.sol";
import { Test } from "forge-std/Test.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { RequestConductor } from "../src/conductor/RequestConductor.sol";
import { SpotSwapConductor } from "../src/conductor/SpotSwapConductor.sol";
import { SwapConductor } from "../src/conductor/SwapConductor.sol";
import { TransitAuthority } from "../src/TransitAuthority.sol";
import { HubWarehouseConductor } from "../src/conductor/HubWarehouseConductor.sol";
import { SpokeWarehouse } from "../src/SpokeWarehouse.sol";
import { Depot } from "../src/depot/Depot.sol";
import { UserConductor } from "../src/conductor/UserConductor.sol";
import { TransitTokenLib } from "../src/helpers/TransitTokenLib.sol";
import { IMessagingAdapter } from "../src/messaging/IMessagingAdapter.sol";
import { ITurnstile } from "../src/turnstile/ITurnstile.sol";
import { Turnstile } from "../src/turnstile/Turnstile.sol";
import { MessagingAdapter } from "../src/messaging/MessagingAdapter.sol";
import { MockMessagingAdapter } from "./mocks/MockMessagingAdapter.sol";
import { Roles } from "../src/helpers/Roles.sol";

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
    uint256 withdrawSalt;

    SpotSwapConductor spotSwapConductor;
    Depot depot;
    UserConductor userConductor;
    HubWarehouseConductor hubWarehouseConductor;
    Turnstile turnstile;
    mapping(uint64 => TransitAuthority) authorities;
    mapping(uint64 => SpokeWarehouse) warehouses;
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
        spotSwapConductor = new SpotSwapConductor(
            address(authorities[hubChainId]),
            address(depot),
            TransitTokenLib.formatAccountId(hubChainId, surplusRecipient, false),
            address(turnstile)
        );
        _grantSpotSwapConductorRole();

        _wireChains();
        _approveVault();
    }

    function _deployCore(uint64 chain) internal {
        _selectChain(chain);

        TransitAuthority authority = new TransitAuthority(admin);
        SpokeWarehouse warehouse = new SpokeWarehouse(address(authority), vault);
        Turnstile chainTurnstile = new Turnstile(address(authority), address(warehouse));
        if (chain == hubChainId) {
            depot = new Depot(address(authority));
            turnstile = chainTurnstile;
        }
        MockMessagingAdapter adapter = new MockMessagingAdapter(address(authority), address(chainTurnstile), hubChainId);
        if (chain == hubChainId) {
            userConductor = new UserConductor(address(depot), address(chainTurnstile));
            hubWarehouseConductor =
                new HubWarehouseConductor(address(authority), address(depot), address(chainTurnstile));
        }

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
        SpokeWarehouse warehouse = warehouses[chain];

        bytes4[] memory adminSels = new bytes4[](1);
        adminSels[0] = SpokeWarehouse.setAssetWhitelisted.selector;

        bytes4[] memory pauseSels = new bytes4[](2);
        pauseSels[0] = Turnstile.pause.selector;
        pauseSels[1] = Turnstile.unpause.selector;

        bytes4[] memory warehouseTurnstileSels = new bytes4[](3);
        warehouseTurnstileSels[0] = SpokeWarehouse.receiveWithdrawal.selector;
        warehouseTurnstileSels[1] = SpokeWarehouse.custody.selector;
        warehouseTurnstileSels[2] = SpokeWarehouse.permit.selector;

        bytes4[] memory peerSels = new bytes4[](5);
        peerSels[0] = MessagingAdapter.setPeer.selector;
        peerSels[1] = MessagingAdapter.setChainGasLimit.selector;
        peerSels[2] = MessagingAdapter.removePeer.selector;
        peerSels[3] = MessagingAdapter.setAllowMessagesFromChain.selector;
        peerSels[4] = MessagingAdapter.setAllowMessagesToChain.selector;

        vm.startPrank(admin);
        authority.setTargetFunctionRole(address(warehouse), adminSels, Roles.ADMIN);
        authority.setTargetFunctionRole(address(turnstiles[chain]), pauseSels, Roles.PAUSER);
        authority.setTargetFunctionRole(address(warehouse), warehouseTurnstileSels, Roles.TURNSTILE);
        authority.setTargetFunctionRole(address(adapters[chain]), peerSels, Roles.ADMIN);

        authority.grantRole(Roles.MESSAGING_ADAPTER, address(adapters[chain]));
        authority.grantRole(Roles.PAUSER, admin);
        authority.grantRole(Roles.SOLVER, solver);

        _wireTurnstile(chain);

        if (chain == hubChainId) {
            _wireDepot(authority);

            bytes4[] memory facilitateSels = new bytes4[](1);
            facilitateSels[0] = Turnstile.facilitate.selector;
            authority.setTargetFunctionRole(address(turnstile), facilitateSels, Roles.SOLVER);

            bytes4[] memory depotPauseSels = new bytes4[](2);
            depotPauseSels[0] = Depot.pause.selector;
            depotPauseSels[1] = Depot.unpause.selector;
            authority.setTargetFunctionRole(address(depot), depotPauseSels, Roles.PAUSER);
        }
        vm.stopPrank();
    }

    function _wireTurnstile(uint64 chain) internal {
        TransitAuthority authority = authorities[chain];
        Turnstile chainTurnstile = turnstiles[chain];

        bytes4[] memory receiveSels = new bytes4[](1);
        receiveSels[0] = Turnstile.receiveMessage.selector;
        authority.setTargetFunctionRole(address(chainTurnstile), receiveSels, Roles.MESSAGING_ADAPTER);

        bytes4[] memory turnstileAdminSels = new bytes4[](3);
        turnstileAdminSels[0] = Turnstile.setMessagingAdapter.selector;
        turnstileAdminSels[1] = Turnstile.setRoutable.selector;
        turnstileAdminSels[2] = Turnstile.setHubWarehouseConductor.selector;
        authority.setTargetFunctionRole(address(chainTurnstile), turnstileAdminSels, Roles.ADMIN);

        authority.grantRole(Roles.TURNSTILE, address(chainTurnstile));
        chainTurnstile.setMessagingAdapter(address(adapters[chain]));
    }

    function _wireDepot(TransitAuthority authority) internal {
        bytes4[] memory userConductorSels = new bytes4[](5);
        userConductorSels[0] = Depot.reserve.selector;
        userConductorSels[1] = Depot.release.selector;
        userConductorSels[2] = Depot.transferFrom.selector;
        userConductorSels[3] = Depot.burn.selector;
        userConductorSels[4] = Depot.mint.selector;
        authority.setTargetFunctionRole(address(depot), userConductorSels, Roles.CONDUCTOR);
        authority.grantRole(Roles.CONDUCTOR, address(userConductor));
        authority.grantRole(Roles.CONDUCTOR, address(hubWarehouseConductor));
        bytes4[] memory hubWarehouseTurnstileSels = new bytes4[](2);
        hubWarehouseTurnstileSels[0] = HubWarehouseConductor.receiveDeposit.selector;
        hubWarehouseTurnstileSels[1] = HubWarehouseConductor.executeWithdrawal.selector;
        authority.setTargetFunctionRole(address(hubWarehouseConductor), hubWarehouseTurnstileSels, Roles.TURNSTILE);
        turnstile.setHubWarehouseConductor(address(hubWarehouseConductor));

        bytes4[] memory routedSels = new bytes4[](2);
        routedSels[0] = UserConductor.reserve.selector;
        routedSels[1] = UserConductor.requestTransfer.selector;
        turnstile.setRoutable(address(userConductor), routedSels, true);

        bytes4[] memory hubWarehouseRoutedSels = new bytes4[](1);
        hubWarehouseRoutedSels[0] = HubWarehouseConductor.requestWithdrawal.selector;
        turnstile.setRoutable(address(hubWarehouseConductor), hubWarehouseRoutedSels, true);
    }

    function _grantSpotSwapConductorRole() internal {
        bytes4[] memory moveSels = new bytes4[](2);
        moveSels[0] = Depot.transferFrom.selector;
        moveSels[1] = Depot.transferAmong.selector;

        bytes4[] memory epochSels = new bytes4[](1);
        epochSels[0] = Depot.advanceEpoch.selector;

        vm.startPrank(admin);
        authorities[hubChainId].setTargetFunctionRole(address(depot), moveSels, Roles.CONDUCTOR);
        authorities[hubChainId].grantRole(Roles.CONDUCTOR, address(spotSwapConductor));
        authorities[hubChainId].setTargetFunctionRole(address(depot), epochSels, Roles.EPOCH);
        authorities[hubChainId].grantRole(Roles.EPOCH, address(spotSwapConductor));

        bytes4[] memory settleSels = new bytes4[](1);
        settleSels[0] = SpotSwapConductor.settle.selector;
        authorities[hubChainId].setTargetFunctionRole(address(spotSwapConductor), settleSels, Roles.SOLVER);

        bytes4[] memory routedSels = new bytes4[](2);
        routedSels[0] = SpotSwapConductor.preApprove.selector;
        routedSels[1] = SwapConductor.requestOrderCancellation.selector;
        turnstile.setRoutable(address(spotSwapConductor), routedSels, true);
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

    function _depotBalance(address user, uint64 assetChain, ERC20 asset) internal view returns (uint256) {
        return depot.balanceOf(
            TransitTokenLib.formatAccountId(hubChainId, user, false),
            TransitTokenLib.formatAssetId(assetChain, address(asset))
        );
    }

    function _depositOnChain(address user, uint256 amount, ERC20 asset, uint64 chain) internal {
        _selectChain(chain);
        deal(address(asset), user, amount);
        vm.startPrank(user);
        SafeTransferLib.safeApprove(address(asset), address(warehouses[chain]), amount);
        dispatchOne(
            turnstiles[chain],
            ITurnstile.ActionType.Deposit,
            abi.encode(
                ITurnstile.DepositAction({
                    asset: address(asset),
                    amount: amount,
                    toChainId: hubChainId,
                    to: user,
                    deadline: type(uint256).max,
                    salt: bytes32(0),
                    permit: ITurnstile.Permit({ deadline: 0, v: 0, r: bytes32(0), s: bytes32(0) })
                })
            ),
            _messageGas(chain)
        );
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
        require(chain == hubChainId, "can only atomically withdraw on Depot");

        _selectChain(hubChainId);
        ITurnstile.WithdrawalAction memory request = _withdrawalActionFor(user, amount, asset, chain);
        bytes memory validSignature = _signWithdraw(request, userPk);

        ITurnstile.ActionType[] memory actionTypes = new ITurnstile.ActionType[](1);
        actionTypes[0] = ITurnstile.ActionType.Withdrawal;
        bytes[] memory actionData = new bytes[](1);
        actionData[0] = abi.encode(request);
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = validSignature;
        uint256[] memory fares = new uint256[](1);
        uint64[] memory messageGas = new uint64[](1);
        messageGas[0] = _messageGas(hubChainId);

        vm.prank(solver);
        turnstile.facilitate(actionTypes, actionData, signatures, fares, messageGas);
        withdrawId = hubWarehouseConductor.hashWithdrawalAction(request);
    }

    function _withdrawalActionFor(
        address user,
        uint256 amount,
        ERC20 asset,
        uint64 chain
    )
        internal
        returns (ITurnstile.WithdrawalAction memory)
    {
        return ITurnstile.WithdrawalAction({
            ownerChainId: hubChainId,
            owner: user,
            to: user,
            assetId: TransitTokenLib.formatAssetId(chain, address(asset)),
            amount: amount,
            deadline: type(uint256).max,
            partiallyFillable: true,
            salt: bytes32(++withdrawSalt)
        });
    }

    function _signWithdraw(ITurnstile.WithdrawalAction memory request, uint256 pk)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = turnstile.hashWithdrawalAction(request);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signOrder(SpotSwapConductor.Order memory order, uint256 pk) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, spotSwapConductor.hashOrder(order));
        return abi.encodePacked(r, s, v);
    }

}
