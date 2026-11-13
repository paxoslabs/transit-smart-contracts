// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { dispatchOne } from "../helpers/DispatchOne.sol";
import { Test } from "forge-std/Test.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { TransitAuthority } from "../../src/TransitAuthority.sol";
import { RequestConductor } from "../../src/conductor/RequestConductor.sol";
import { HubWarehouseConductor } from "../../src/conductor/HubWarehouseConductor.sol";
import { SpokeWarehouse } from "../../src/SpokeWarehouse.sol";
import { Depot } from "../../src/depot/Depot.sol";
import { UserConductor } from "../../src/conductor/UserConductor.sol";
import { ITurnstile } from "../../src/turnstile/ITurnstile.sol";
import { Turnstile } from "../../src/turnstile/Turnstile.sol";
import { MockMessagingAdapter } from "../mocks/MockMessagingAdapter.sol";
import { MockERC20 } from "../../lib/solady/test/utils/mocks/MockERC20.sol";
import { Roles } from "../../src/helpers/Roles.sol";

abstract contract WarehouseConductorUnitBase is Test {

    uint64 constant HUB_CHAIN_ID = 1;
    uint64 constant SPOKE_CHAIN_ID = 4663;

    TransitAuthority authority;
    SpokeWarehouse warehouse;
    ERC20 usdc;
    Depot depot;
    UserConductor userConductor;
    HubWarehouseConductor hubWarehouseConductor;
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
        warehouse = new SpokeWarehouse(address(authority), vault);
        turnstile = new Turnstile(address(authority), address(warehouse));
        depot = new Depot(address(authority));
        local = new MockMessagingAdapter(address(authority), address(turnstile), HUB_CHAIN_ID);
        userConductor = new UserConductor(address(depot), address(turnstile));
        hubWarehouseConductor = new HubWarehouseConductor(address(authority), address(depot), address(turnstile));
        usdc = _asset("USD Coin", "USDC", 6);

        bytes4[] memory adminSels = new bytes4[](1);
        adminSels[0] = SpokeWarehouse.setAssetWhitelisted.selector;

        bytes4[] memory facilitateSels = new bytes4[](1);
        facilitateSels[0] = Turnstile.facilitate.selector;

        vm.startPrank(admin);
        authority.setTargetFunctionRole(address(warehouse), adminSels, Roles.ADMIN);
        authority.setTargetFunctionRole(address(turnstile), facilitateSels, Roles.SOLVER);
        authority.grantRole(Roles.SOLVER, backend);
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
        turnstileAdminSels[2] = Turnstile.setHubWarehouseConductor.selector;

        bytes4[] memory warehouseTurnstileSels = new bytes4[](3);
        warehouseTurnstileSels[0] = SpokeWarehouse.receiveWithdrawal.selector;
        warehouseTurnstileSels[1] = SpokeWarehouse.custody.selector;
        warehouseTurnstileSels[2] = SpokeWarehouse.permit.selector;

        bytes4[] memory routedSels = new bytes4[](1);
        routedSels[0] = UserConductor.requestTransfer.selector;
        vm.startPrank(admin);
        authority.setTargetFunctionRole(address(turnstile), sels, Roles.MESSAGING_ADAPTER);
        authority.setTargetFunctionRole(address(warehouse), warehouseTurnstileSels, Roles.TURNSTILE);
        authority.grantRole(Roles.MESSAGING_ADAPTER, address(local));
        authority.setTargetFunctionRole(address(turnstile), turnstileAdminSels, Roles.ADMIN);
        authority.grantRole(Roles.TURNSTILE, address(turnstile));
        bytes4[] memory userConductorSels = new bytes4[](6);
        userConductorSels[0] = Depot.reserve.selector;
        userConductorSels[1] = Depot.release.selector;
        userConductorSels[2] = Depot.transferFrom.selector;
        userConductorSels[3] = Depot.burn.selector;
        userConductorSels[4] = Depot.mint.selector;
        userConductorSels[5] = Depot.priorityTransferFrom.selector;
        authority.setTargetFunctionRole(address(depot), userConductorSels, Roles.CONDUCTOR);
        authority.grantRole(Roles.CONDUCTOR, address(userConductor));
        authority.grantRole(Roles.CONDUCTOR, address(hubWarehouseConductor));
        bytes4[] memory hubWarehouseTurnstileSels = new bytes4[](2);
        hubWarehouseTurnstileSels[0] = HubWarehouseConductor.receiveDeposit.selector;
        hubWarehouseTurnstileSels[1] = HubWarehouseConductor.executeWithdrawal.selector;
        authority.setTargetFunctionRole(address(hubWarehouseConductor), hubWarehouseTurnstileSels, Roles.TURNSTILE);
        turnstile.setHubWarehouseConductor(address(hubWarehouseConductor));
        turnstile.setRoutable(address(userConductor), routedSels, true);
        bytes4[] memory hubWarehouseRoutedSels = new bytes4[](1);
        hubWarehouseRoutedSels[0] = HubWarehouseConductor.requestWithdrawal.selector;
        turnstile.setRoutable(address(hubWarehouseConductor), hubWarehouseRoutedSels, true);
        turnstile.setMessagingAdapter(address(local));
        vm.stopPrank();
    }

    function _deposit(address user, uint256 amount) internal {
        deal(address(usdc), user, amount);
        vm.startPrank(user);
        SafeTransferLib.safeApprove(address(usdc), address(warehouse), amount);
        dispatchOne(
            turnstile,
            ITurnstile.ActionType.Deposit,
            abi.encode(
                ITurnstile.DepositAction({
                    asset: address(usdc),
                    amount: amount,
                    toChainId: HUB_CHAIN_ID,
                    to: user,
                    deadline: type(uint256).max,
                    salt: bytes32(0),
                    permit: ITurnstile.Permit({ deadline: 0, v: 0, r: bytes32(0), s: bytes32(0) })
                })
            ),
            0
        );
        vm.stopPrank();
    }

}
