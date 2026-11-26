// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { Test, Vm } from "forge-std/Test.sol";
import { MockERC20 } from "lib/solady/test/utils/mocks/MockERC20.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { AddressFreezeList } from "src/AddressFreezeList.sol";
import { Depot } from "src/depot/Depot.sol";
import { Turnstile } from "src/turnstile/Turnstile.sol";
import { ITurnstile } from "src/interfaces/ITurnstile.sol";
import { HubWarehouseConductor } from "src/conductor/HubWarehouseConductor.sol";
import { UserConductor } from "src/conductor/UserConductor.sol";
import { SwapConductor } from "src/conductor/SwapConductor.sol";
import { SpotSwapConductor } from "src/conductor/SpotSwapConductor.sol";
import { DelayedSettlementSwapConductor } from "src/conductor/DelayedSettlementSwapConductor.sol";
import { TransitAddressLib } from "src/helpers/TransitAddressLib.sol";
import { Roles } from "src/helpers/Roles.sol";
import { CCIPMessagingAdapter } from "src/messaging/CCIPMessagingAdapter.sol";
import { IMessagingAdapter } from "src/interfaces/IMessagingAdapter.sol";
import { IRouterClient } from "@chainlink/contracts-ccip/interfaces/IRouterClient.sol";
import { Client } from "@chainlink/contracts-ccip/libraries/Client.sol";

abstract contract SharedSetup is Test {

    uint64 constant HUB_CHAIN_ID = 1;
    uint64 constant ROBINHOOD_CHAIN_ID = 4663;
    uint64 constant ARBITRUM_CHAIN_ID = 42_161;
    uint32 constant ADMIN_DELAY = 48 hours;
    uint64 constant MESSAGE_GAS = 500_000;
    address constant PREDICATE_FREEZE_MANAGER = 0x363c256D368277BBFaf6EaF65beE123a7AdbA464;

    address DEPLOYER = makeAddr("DEPLOYER");
    address ADMIN_MULTISIG = makeAddr("ADMIN_MULTISIG");
    address PAUSER_ADDRESS = makeAddr("PAUSER_ADDRESS");
    address SOLVER_ADDRESS = makeAddr("SOLVER_ADDRESS");
    address VAULT = makeAddr("VAULT");
    address SURPLUS_RECIPIENT = makeAddr("SURPLUS_RECIPIENT");
    address PENALTY_RECIPIENT = makeAddr("PENALTY_RECIPIENT");
    address CCIP_ROUTER = makeAddr("CCIP_ROUTER");

    AccessManager accessManager;
    AddressFreezeList addressFreezeList;
    Depot depot;
    Turnstile turnstile;
    CCIPMessagingAdapter messagingAdapter;
    HubWarehouseConductor hubWarehouseConductor;
    UserConductor userConductor;
    SpotSwapConductor spotSwapConductor;
    DelayedSettlementSwapConductor delayedSettlementSwapConductor;
    MockERC20 usdc;
    MockERC20 usdg;

    mapping(uint64 => AccessManager) spokeAccessManager;
    mapping(uint64 => Turnstile) spokeTurnstile;
    mapping(uint64 => CCIPMessagingAdapter) spokeMessagingAdapter;
    mapping(uint64 => MockERC20) spokeUsdg;
    mapping(address => uint64) chainIdOfAdapter;

    function setUp() public virtual {
        vm.chainId(HUB_CHAIN_ID);
        _deploy();
        _deploySpoke(ROBINHOOD_CHAIN_ID);
        _deploySpoke(ARBITRUM_CHAIN_ID);
        vm.startPrank(DEPLOYER);
        _setFunctionRoles();
        _grantRoles();
        _wire();
        _handOffAdmin(accessManager);
        vm.stopPrank();
        _approveVault();
        _mockCcipRouter();
        vm.recordLogs();
    }

    function _deploy() internal {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        accessManager = new AccessManager(DEPLOYER);
        address authority = address(accessManager);
        addressFreezeList = new AddressFreezeList(authority);
        depot = new Depot(authority, addressFreezeList);
        turnstile = new Turnstile(authority, VAULT);
        messagingAdapter = new CCIPMessagingAdapter(authority, address(turnstile), HUB_CHAIN_ID, CCIP_ROUTER);
        chainIdOfAdapter[address(messagingAdapter)] = HUB_CHAIN_ID;
        hubWarehouseConductor = new HubWarehouseConductor(authority, address(depot), address(turnstile));
        userConductor = new UserConductor(address(depot), address(turnstile));
        spotSwapConductor =
            new SpotSwapConductor(authority, address(depot), _hubAccount(SURPLUS_RECIPIENT), address(turnstile));
        delayedSettlementSwapConductor = new DelayedSettlementSwapConductor(
            authority,
            address(depot),
            _hubAccount(SURPLUS_RECIPIENT),
            _hubAccount(PENALTY_RECIPIENT),
            address(turnstile)
        );
    }

    function _setFunctionRoles() internal {
        bytes4[] memory freezeSels = new bytes4[](4);
        freezeSels[0] = AddressFreezeList.freeze.selector;
        freezeSels[1] = AddressFreezeList.freezeAccounts.selector;
        freezeSels[2] = AddressFreezeList.unfreeze.selector;
        freezeSels[3] = AddressFreezeList.unfreezeAccounts.selector;
        accessManager.setTargetFunctionRole(address(addressFreezeList), freezeSels, Roles.FREEZE_MANAGER);

        _setPauseRoles(accessManager, address(depot));
        _setPauseRoles(accessManager, address(turnstile));

        bytes4[] memory depotConductorSels = new bytes4[](7);
        depotConductorSels[0] = Depot.transferFrom.selector;
        depotConductorSels[1] = Depot.transferAmong.selector;
        depotConductorSels[2] = Depot.mint.selector;
        depotConductorSels[3] = Depot.burn.selector;
        depotConductorSels[4] = Depot.reserve.selector;
        depotConductorSels[5] = Depot.release.selector;
        depotConductorSels[6] = Depot.advanceEpoch.selector;
        accessManager.setTargetFunctionRole(address(depot), depotConductorSels, Roles.CONDUCTOR);

        _setFacilitateRole(accessManager, address(turnstile));

        _setReceiveRole(accessManager, address(turnstile));

        bytes4[] memory warehouseSels = new bytes4[](2);
        warehouseSels[0] = HubWarehouseConductor.receiveDeposit.selector;
        warehouseSels[1] = HubWarehouseConductor.executeWithdrawal.selector;
        accessManager.setTargetFunctionRole(address(hubWarehouseConductor), warehouseSels, Roles.TURNSTILE);

        bytes4[] memory spotSettleSels = new bytes4[](1);
        spotSettleSels[0] = SpotSwapConductor.settle.selector;
        accessManager.setTargetFunctionRole(address(spotSwapConductor), spotSettleSels, Roles.SOLVER);

        bytes4[] memory delayedSettleSels = new bytes4[](1);
        delayedSettleSels[0] = DelayedSettlementSwapConductor.settle.selector;
        accessManager.setTargetFunctionRole(address(delayedSettlementSwapConductor), delayedSettleSels, Roles.SOLVER);
    }

    function _grantRoles() internal {
        _grantPauseRoles(accessManager);
        accessManager.grantRole(Roles.FREEZE_MANAGER, PREDICATE_FREEZE_MANAGER, 0);
        accessManager.grantRole(Roles.SOLVER, SOLVER_ADDRESS, 0);
        accessManager.grantRole(Roles.MESSAGING_ADAPTER, address(messagingAdapter), 0);
        accessManager.grantRole(Roles.TURNSTILE, address(turnstile), 0);
        accessManager.grantRole(Roles.CONDUCTOR, address(hubWarehouseConductor), 0);
        accessManager.grantRole(Roles.CONDUCTOR, address(userConductor), 0);
        accessManager.grantRole(Roles.CONDUCTOR, address(spotSwapConductor), 0);
        accessManager.grantRole(Roles.CONDUCTOR, address(delayedSettlementSwapConductor), 0);
    }

    function _wire() internal {
        turnstile.setMessagingAdapter(address(messagingAdapter));
        _setPeer(messagingAdapter, ROBINHOOD_CHAIN_ID, address(spokeMessagingAdapter[ROBINHOOD_CHAIN_ID]));
        _setPeer(messagingAdapter, ARBITRUM_CHAIN_ID, address(spokeMessagingAdapter[ARBITRUM_CHAIN_ID]));
        turnstile.setHubWarehouseConductor(address(hubWarehouseConductor));

        address[] memory assets = new address[](2);
        assets[0] = address(usdc);
        assets[1] = address(usdg);
        turnstile.setAssetWhitelisted(assets, true);

        bytes4[] memory warehouseSels = new bytes4[](1);
        warehouseSels[0] = HubWarehouseConductor.requestWithdrawal.selector;
        turnstile.setRoutable(address(hubWarehouseConductor), warehouseSels, true);

        bytes4[] memory userSels = new bytes4[](2);
        userSels[0] = UserConductor.requestTransfer.selector;
        userSels[1] = UserConductor.executeTransfer.selector;
        turnstile.setRoutable(address(userConductor), userSels, true);

        bytes4[] memory spotSels = new bytes4[](2);
        spotSels[0] = SpotSwapConductor.preApprove.selector;
        spotSels[1] = SwapConductor.requestOrderCancellation.selector;
        turnstile.setRoutable(address(spotSwapConductor), spotSels, true);

        bytes4[] memory delayedSels = new bytes4[](3);
        delayedSels[0] = DelayedSettlementSwapConductor.preApprove.selector;
        delayedSels[1] = SwapConductor.requestOrderCancellation.selector;
        delayedSels[2] = DelayedSettlementSwapConductor.repay.selector;
        turnstile.setRoutable(address(delayedSettlementSwapConductor), delayedSels, true);
    }

    function _deploySpoke(uint64 spokeChainId) internal {
        MockERC20 token = new MockERC20("Global Dollar", "USDG", 6);
        AccessManager manager = new AccessManager(DEPLOYER);
        Turnstile spoke = new Turnstile(address(manager), VAULT);
        CCIPMessagingAdapter adapter =
            new CCIPMessagingAdapter(address(manager), address(spoke), HUB_CHAIN_ID, CCIP_ROUTER);
        spokeUsdg[spokeChainId] = token;
        spokeAccessManager[spokeChainId] = manager;
        spokeTurnstile[spokeChainId] = spoke;
        spokeMessagingAdapter[spokeChainId] = adapter;
        chainIdOfAdapter[address(adapter)] = spokeChainId;

        vm.startPrank(DEPLOYER);
        _setPauseRoles(manager, address(spoke));
        _setReceiveRole(manager, address(spoke));
        _setFacilitateRole(manager, address(spoke));
        _grantPauseRoles(manager);
        manager.grantRole(Roles.SOLVER, SOLVER_ADDRESS, 0);
        manager.grantRole(Roles.MESSAGING_ADAPTER, address(adapter), 0);
        spoke.setMessagingAdapter(address(adapter));
        _setPeer(adapter, HUB_CHAIN_ID, address(messagingAdapter));
        address[] memory assets = new address[](1);
        assets[0] = address(token);
        spoke.setAssetWhitelisted(assets, true);
        _handOffAdmin(manager);
        vm.stopPrank();

        vm.prank(VAULT);
        token.approve(address(spoke), type(uint256).max);
    }

    function _handOffAdmin(AccessManager manager) internal {
        manager.grantRole(Roles.ADMIN, ADMIN_MULTISIG, ADMIN_DELAY);
        manager.renounceRole(Roles.ADMIN, DEPLOYER);
    }

    function _setPauseRoles(AccessManager manager, address target) internal {
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = Turnstile.pause.selector;
        manager.setTargetFunctionRole(target, sels, Roles.PAUSER);
        sels[0] = Turnstile.unpause.selector;
        manager.setTargetFunctionRole(target, sels, Roles.UNPAUSER);
    }

    function _setReceiveRole(AccessManager manager, address target) internal {
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = Turnstile.handleReceivedMessage.selector;
        manager.setTargetFunctionRole(target, sels, Roles.MESSAGING_ADAPTER);
    }

    function _setFacilitateRole(AccessManager manager, address target) internal {
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = Turnstile.facilitate.selector;
        manager.setTargetFunctionRole(target, sels, Roles.SOLVER);
    }

    function _grantPauseRoles(AccessManager manager) internal {
        manager.grantRole(Roles.PAUSER, PAUSER_ADDRESS, 0);
        manager.grantRole(Roles.UNPAUSER, ADMIN_MULTISIG, 0);
    }

    function _approveVault() internal {
        vm.startPrank(VAULT);
        usdc.approve(address(turnstile), type(uint256).max);
        usdg.approve(address(turnstile), type(uint256).max);
        vm.stopPrank();
    }

    function _setPeer(CCIPMessagingAdapter adapter, uint64 peerChainId, address peerAdapter) internal {
        adapter.setPeer(peerChainId, bytes32(uint256(uint160(peerAdapter))), peerChainId, 1_000_000, 0, true, true);
    }

    function _mockCcipRouter() internal {
        vm.mockCall(CCIP_ROUTER, abi.encodeWithSelector(IRouterClient.getFee.selector), abi.encode(uint256(0)));
        vm.mockCall(CCIP_ROUTER, abi.encodeWithSelector(IRouterClient.ccipSend.selector), abi.encode(bytes32(0)));
    }

    function _adapterOf(uint64 chainId) internal view returns (CCIPMessagingAdapter) {
        return chainId == HUB_CHAIN_ID ? messagingAdapter : spokeMessagingAdapter[chainId];
    }

    function _relayMessages() internal {
        uint64 chainId = uint64(vm.getChainId());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] != IMessagingAdapter.MessageSent.selector) continue;
            _deliver(
                chainIdOfAdapter[logs[i].emitter], uint64(uint256(logs[i].topics[1])), abi.decode(logs[i].data, (bytes))
            );
        }
        vm.chainId(chainId);
    }

    function _deliver(uint64 sourceChainId, uint64 destinationChainId, bytes memory payload) internal {
        vm.chainId(destinationChainId);
        vm.prank(CCIP_ROUTER);
        _adapterOf(destinationChainId)
            .ccipReceive(
                Client.Any2EVMMessage({
                    messageId: keccak256(payload),
                    sourceChainSelector: sourceChainId,
                    sender: abi.encode(address(_adapterOf(sourceChainId))),
                    data: payload,
                    destTokenAmounts: new Client.EVMTokenAmount[](0)
                })
            );
    }

    function _receiveFromSpoke(uint64 spokeChainId, ITurnstile.ActionType actionType, bytes memory body) internal {
        _deliver(spokeChainId, HUB_CHAIN_ID, abi.encode(actionType, body));
    }

    function _advanceEpoch() internal {
        vm.warp(block.timestamp + 24 hours);
        depot.advanceEpoch();
    }

    function _dispatchOne(Turnstile chainTurnstile, ITurnstile.ActionType actionType, bytes memory data) internal {
        ITurnstile.Action[] memory actions = new ITurnstile.Action[](1);
        actions[0] = ITurnstile.Action({ actionType: actionType, data: data, bridgeFee: 0, messageGas: MESSAGE_GAS });
        chainTurnstile.dispatch(actions);
    }

    function _facilitate(
        uint64 chainId,
        ITurnstile.ActionType actionType,
        bytes memory data,
        bytes memory signature
    )
        internal
    {
        vm.chainId(chainId);
        ITurnstile.Action[] memory actions = new ITurnstile.Action[](1);
        actions[0] = ITurnstile.Action({ actionType: actionType, data: data, bridgeFee: 0, messageGas: MESSAGE_GAS });
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = signature;
        vm.prank(SOLVER_ADDRESS);
        _turnstile(chainId).facilitate(actions, signatures);
    }

    function _token(uint64 chainId) internal view returns (MockERC20) {
        return chainId == HUB_CHAIN_ID ? usdg : spokeUsdg[chainId];
    }

    function _turnstile(uint64 chainId) internal view returns (Turnstile) {
        return chainId == HUB_CHAIN_ID ? turnstile : spokeTurnstile[chainId];
    }

    function _account(uint64 chainId, address account) internal pure returns (bytes28) {
        return TransitAddressLib.formatTransitAddress(chainId, account);
    }

    function _asset(uint64 assetChainId) internal view returns (bytes28) {
        return _account(assetChainId, address(_token(assetChainId)));
    }

    function _balance(uint64 accountChainId, address account, uint64 assetChainId) internal view returns (uint256) {
        return depot.balanceOf(_account(accountChainId, account), _asset(assetChainId));
    }

    function _deposit(address user, uint64 chainId, MockERC20 token, uint64 toChainId, uint256 amount) internal {
        vm.chainId(chainId);
        Turnstile chainTurnstile = _turnstile(chainId);
        token.mint(user, amount);
        vm.startPrank(user);
        token.approve(address(chainTurnstile), amount);
        _dispatchOne(
            chainTurnstile,
            ITurnstile.ActionType.Deposit,
            abi.encode(
                ITurnstile.DepositAction({
                    ownerChainId: chainId,
                    owner: user,
                    asset: address(token),
                    amount: amount,
                    toChainId: toChainId,
                    to: user,
                    facilitationFee: 0,
                    feeReceiverChainId: 0,
                    feeReceiver: address(0),
                    deadline: type(uint256).max,
                    dependsOn: bytes32(0),
                    salt: bytes32(0),
                    permit: ITurnstile.Permit({ deadline: 0, v: 0, r: bytes32(0), s: bytes32(0) })
                })
            )
        );
        vm.stopPrank();
    }

    function _sign(uint256 privateKey, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _adminCall(AccessManager manager, address target, bytes memory data) internal {
        vm.prank(ADMIN_MULTISIG);
        manager.schedule(target, data, 0);
        vm.warp(block.timestamp + ADMIN_DELAY);
        vm.prank(ADMIN_MULTISIG);
        manager.execute(target, data);
    }

    function _hubAccount(address account) internal pure returns (bytes28) {
        return TransitAddressLib.formatTransitAddress(HUB_CHAIN_ID, account);
    }

}
