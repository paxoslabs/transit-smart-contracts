// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { Test } from "forge-std/Test.sol";
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
import { Client } from "@chainlink/contracts-ccip/libraries/Client.sol";

abstract contract SharedSetup is Test {

    uint64 constant HUB_CHAIN_ID = 1;
    uint64 constant ROBINHOOD_CHAIN_ID = 4663;
    uint64 constant ARBITRUM_CHAIN_ID = 42_161;
    uint32 constant ADMIN_DELAY = 48 hours;
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

    function setUp() public virtual {
        vm.chainId(HUB_CHAIN_ID);
        _deploy();
        vm.startPrank(DEPLOYER);
        _setFunctionRoles();
        _grantRoles();
        _wire();
        _handOffAdmin();
        vm.stopPrank();
        _approveVault();
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

        bytes4[] memory pauseSels = new bytes4[](1);
        pauseSels[0] = Depot.pause.selector;
        accessManager.setTargetFunctionRole(address(depot), pauseSels, Roles.PAUSER);
        pauseSels[0] = Turnstile.pause.selector;
        accessManager.setTargetFunctionRole(address(turnstile), pauseSels, Roles.PAUSER);

        bytes4[] memory unpauseSels = new bytes4[](1);
        unpauseSels[0] = Depot.unpause.selector;
        accessManager.setTargetFunctionRole(address(depot), unpauseSels, Roles.UNPAUSER);
        unpauseSels[0] = Turnstile.unpause.selector;
        accessManager.setTargetFunctionRole(address(turnstile), unpauseSels, Roles.UNPAUSER);

        bytes4[] memory depotConductorSels = new bytes4[](7);
        depotConductorSels[0] = Depot.transferFrom.selector;
        depotConductorSels[1] = Depot.transferAmong.selector;
        depotConductorSels[2] = Depot.mint.selector;
        depotConductorSels[3] = Depot.burn.selector;
        depotConductorSels[4] = Depot.reserve.selector;
        depotConductorSels[5] = Depot.release.selector;
        depotConductorSels[6] = Depot.advanceEpoch.selector;
        accessManager.setTargetFunctionRole(address(depot), depotConductorSels, Roles.CONDUCTOR);

        bytes4[] memory facilitateSels = new bytes4[](1);
        facilitateSels[0] = Turnstile.facilitate.selector;
        accessManager.setTargetFunctionRole(address(turnstile), facilitateSels, Roles.SOLVER);

        bytes4[] memory receiveSels = new bytes4[](1);
        receiveSels[0] = Turnstile.handleReceivedMessage.selector;
        accessManager.setTargetFunctionRole(address(turnstile), receiveSels, Roles.MESSAGING_ADAPTER);

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
        accessManager.grantRole(Roles.PAUSER, PAUSER_ADDRESS, 0);
        accessManager.grantRole(Roles.UNPAUSER, ADMIN_MULTISIG, 0);
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
        _setSpokePeer(ROBINHOOD_CHAIN_ID);
        _setSpokePeer(ARBITRUM_CHAIN_ID);
        turnstile.setHubWarehouseConductor(address(hubWarehouseConductor));

        address[] memory assets = new address[](2);
        assets[0] = address(usdc);
        assets[1] = address(usdg);
        turnstile.setAssetWhitelisted(assets, true);

        bytes4[] memory warehouseSels = new bytes4[](1);
        warehouseSels[0] = HubWarehouseConductor.requestWithdrawal.selector;
        turnstile.setRoutable(address(hubWarehouseConductor), warehouseSels, true);

        bytes4[] memory userSels = new bytes4[](1);
        userSels[0] = UserConductor.requestTransfer.selector;
        turnstile.setRoutable(address(userConductor), userSels, true);

        bytes4[] memory spotSels = new bytes4[](2);
        spotSels[0] = SpotSwapConductor.preApprove.selector;
        spotSels[1] = SwapConductor.requestOrderCancellation.selector;
        turnstile.setRoutable(address(spotSwapConductor), spotSels, true);

        bytes4[] memory delayedSels = new bytes4[](2);
        delayedSels[0] = DelayedSettlementSwapConductor.preApprove.selector;
        delayedSels[1] = SwapConductor.requestOrderCancellation.selector;
        turnstile.setRoutable(address(delayedSettlementSwapConductor), delayedSels, true);
    }

    function _handOffAdmin() internal {
        accessManager.grantRole(Roles.ADMIN, ADMIN_MULTISIG, ADMIN_DELAY);
        accessManager.renounceRole(Roles.ADMIN, DEPLOYER);
    }

    function _approveVault() internal {
        vm.startPrank(VAULT);
        usdc.approve(address(turnstile), type(uint256).max);
        usdg.approve(address(turnstile), type(uint256).max);
        vm.stopPrank();
    }

    function _setSpokePeer(uint64 spokeChainId) internal {
        messagingAdapter.setPeer(
            spokeChainId,
            bytes32(uint256(uint160(_spokeMessagingAdapter(spokeChainId)))),
            spokeChainId,
            1_000_000,
            0,
            true,
            true
        );
    }

    function _spokeMessagingAdapter(uint64 spokeChainId) internal returns (address) {
        return makeAddr(string.concat("SPOKE_MESSAGING_ADAPTER_", vm.toString(spokeChainId)));
    }

    function _receiveFromSpoke(uint64 spokeChainId, ITurnstile.ActionType actionType, bytes memory body) internal {
        bytes memory payload = abi.encode(actionType, body);
        vm.prank(CCIP_ROUTER);
        messagingAdapter.ccipReceive(
            Client.Any2EVMMessage({
                messageId: keccak256(payload),
                sourceChainSelector: spokeChainId,
                sender: abi.encode(_spokeMessagingAdapter(spokeChainId)),
                data: payload,
                destTokenAmounts: new Client.EVMTokenAmount[](0)
            })
        );
    }

    function _hubAccount(address account) internal pure returns (bytes28) {
        return TransitAddressLib.formatTransitAddress(HUB_CHAIN_ID, account);
    }

}
