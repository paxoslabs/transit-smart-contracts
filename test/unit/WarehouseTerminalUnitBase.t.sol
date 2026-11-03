// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { TransitAuthority } from "../../src/TransitAuthority.sol";
import { HubWarehouseTerminal } from "../../src/terminal/HubWarehouseTerminal.sol";
import { SpokeWarehouseTerminal } from "../../src/terminal/SpokeWarehouseTerminal.sol";
import { Depot } from "../../src/depot/Depot.sol";
import { UserTerminal } from "../../src/terminal/UserTerminal.sol";
import { Turnstile } from "../../src/Turnstile.sol";
import { MockMessagingAdapter } from "../mocks/MockMessagingAdapter.sol";
import { MockERC20 } from "../../lib/solady/test/utils/mocks/MockERC20.sol";
import { ADMIN_ROLE, MESSAGING_ADAPTER_ROLE, SOLVER_ROLE, TURNSTILE_ROLE, TERMINAL_ROLE } from "../../src/helpers/Constants.sol";

abstract contract WarehouseTerminalUnitBase is Test {

    uint64 constant HUB_CHAIN_ID = 1;
    uint64 constant SPOKE_CHAIN_ID = 4663;

    TransitAuthority authority;
    SpokeWarehouseTerminal warehouse;
    ERC20 usdc;
    Depot depot;
    UserTerminal userTerminal;
    HubWarehouseTerminal hubWarehouseTerminal;
    Turnstile turnstile;
    MockMessagingAdapter local;

    address admin = makeAddr("admin");
    address vault = makeAddr("vault");
    address alice = makeAddr("alice");
    address mallory = makeAddr("mallory");

    address backend = makeAddr("backend");
    uint256 alicePk;
    uint256 withdrawSalt;

    function setUp() public {
        vm.chainId(HUB_CHAIN_ID);
        (, alicePk) = makeAddrAndKey("alice");

        authority = new TransitAuthority(admin);
        uint256 nonce = vm.getNonce(address(this));
        turnstile = new Turnstile(address(authority), vm.computeCreateAddress(address(this), nonce + 2));
        depot = new Depot(address(authority));
        warehouse = new SpokeWarehouseTerminal(address(authority), vault, address(turnstile), HUB_CHAIN_ID);
        local = new MockMessagingAdapter(address(authority), address(turnstile), HUB_CHAIN_ID);
        userTerminal = new UserTerminal(address(depot), address(turnstile));
        hubWarehouseTerminal = new HubWarehouseTerminal(address(authority), address(depot), address(userTerminal), address(turnstile));
        usdc = _asset("USD Coin", "USDC", 6);

        bytes4[] memory adminSels = new bytes4[](1);
        adminSels[0] = SpokeWarehouseTerminal.setAssetWhitelisted.selector;


        bytes4[] memory facilitateSels = new bytes4[](1);
        facilitateSels[0] = Turnstile.facilitate.selector;

        vm.startPrank(admin);
        authority.setTargetFunctionRole(address(warehouse), adminSels, ADMIN_ROLE);
        authority.setTargetFunctionRole(address(turnstile), facilitateSels, SOLVER_ROLE);
        authority.grantRole(SOLVER_ROLE, backend);
        warehouse.setAssetWhitelisted(_list(address(usdc)), true);
        vm.stopPrank();

        _authorizeDepot();

        vm.prank(vault);
        SafeTransferLib.safeApprove(address(usdc), address(warehouse), type(uint256).max);
    }

    function _asset(string memory name_, string memory symbol_, uint8 decimals_) internal returns (ERC20) {
        return ERC20(address(new MockERC20(name_, symbol_, decimals_)));
    }

    function _list(address asset) internal pure returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = asset;
    }

    function _authorizeDepot() internal {
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = Turnstile.receiveMessage.selector;

        bytes4[] memory turnstileAdminSels = new bytes4[](3);
        turnstileAdminSels[0] = Turnstile.setMessagingAdapter.selector;
        turnstileAdminSels[1] = Turnstile.setRoutable.selector;
        turnstileAdminSels[2] = Turnstile.setHubWarehouseTerminal.selector;

        bytes4[] memory turnstileSendSels = new bytes4[](2);
        turnstileSendSels[0] = Turnstile.sendDepositMessage.selector;
        turnstileSendSels[1] = Turnstile.sendWithdrawalMessage.selector;

        bytes4[] memory receiveWithdrawalSels = new bytes4[](1);
        receiveWithdrawalSels[0] = SpokeWarehouseTerminal.receiveWithdrawal.selector;

        bytes4[] memory routedSels = new bytes4[](2);
        routedSels[0] = UserTerminal.reserve.selector;
        routedSels[1] = UserTerminal.reserveAndRequest.selector;
        vm.startPrank(admin);
        authority.setTargetFunctionRole(address(turnstile), sels, MESSAGING_ADAPTER_ROLE);
        authority.setTargetFunctionRole(address(warehouse), receiveWithdrawalSels, TURNSTILE_ROLE);
        authority.grantRole(MESSAGING_ADAPTER_ROLE, address(warehouse));
        authority.grantRole(MESSAGING_ADAPTER_ROLE, address(local));
        authority.setTargetFunctionRole(address(turnstile), turnstileAdminSels, ADMIN_ROLE);
        authority.setTargetFunctionRole(address(turnstile), turnstileSendSels, MESSAGING_ADAPTER_ROLE);
        authority.grantRole(TURNSTILE_ROLE, address(turnstile));
        authority.grantRole(MESSAGING_ADAPTER_ROLE, address(hubWarehouseTerminal));
        bytes4[] memory userTerminalSels = new bytes4[](5);
        userTerminalSels[0] = Depot.reserve.selector;
        userTerminalSels[1] = Depot.release.selector;
        userTerminalSels[2] = Depot.transferFrom.selector;
        userTerminalSels[3] = Depot.burn.selector;
        userTerminalSels[4] = Depot.mint.selector;
        authority.setTargetFunctionRole(address(depot), userTerminalSels, TERMINAL_ROLE);
        authority.grantRole(TERMINAL_ROLE, address(userTerminal));
        authority.grantRole(TERMINAL_ROLE, address(hubWarehouseTerminal));
        bytes4[] memory receiveDepositSels = new bytes4[](1);
        receiveDepositSels[0] = HubWarehouseTerminal.receiveDeposit.selector;
        authority.setTargetFunctionRole(address(hubWarehouseTerminal), receiveDepositSels, TURNSTILE_ROLE);
        turnstile.setHubWarehouseTerminal(address(hubWarehouseTerminal));
        turnstile.setRoutable(address(userTerminal), routedSels, true);
        bytes4[] memory executeSels = new bytes4[](1);
        executeSels[0] = HubWarehouseTerminal.executeWithdrawal.selector;
        turnstile.setRoutable(address(hubWarehouseTerminal), executeSels, true);
        turnstile.setMessagingAdapter(address(local));
        vm.stopPrank();
    }

    function _deposit(address user, uint256 amount) internal {
        deal(address(usdc), user, amount);
        vm.startPrank(user);
        SafeTransferLib.safeApprove(address(usdc), address(warehouse), amount);
        warehouse.deposit(address(usdc), amount, HUB_CHAIN_ID, user, 0);
        vm.stopPrank();
    }

}
