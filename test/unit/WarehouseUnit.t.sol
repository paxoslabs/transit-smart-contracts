// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { TransitAuthority } from "../../src/warehouse/TransitAuthority.sol";
import { Warehouse } from "../../src/warehouse/Warehouse.sol";
import { WarehouseHub } from "../../src/warehouse/WarehouseHub.sol";
import { MockCrosschainModule } from "../mocks/MockCrosschainModule.sol";
import { CrosschainAdapter } from "../../src/warehouse/crosschain/CrosschainAdapter.sol";
import { MockERC20 } from "../../lib/solady/test/utils/mocks/MockERC20.sol";
import { ADMIN_ROLE, WAREHOUSE_ROLE, CROSSCHAIN_MODULE_ROLE } from "../../src/helpers/Constants.sol";

contract WarehouseUnitTest is Test {

    uint64 constant HUB = 1;
    uint64 constant SPOKE = 4663;

    TransitAuthority authority;
    Warehouse warehouse;
    ERC20 usdc;
    WarehouseHub hub;

    address admin = makeAddr("admin");
    address vault = makeAddr("vault");
    address alice = makeAddr("alice");
    address mallory = makeAddr("mallory");

    address signer;
    uint256 signerPk;
    uint256 withdrawNonce;

    function setUp() public {
        vm.chainId(HUB);
        (signer, signerPk) = makeAddrAndKey("withdrawSigner");

        authority = new TransitAuthority(admin);
        hub = new WarehouseHub(address(authority));
        warehouse = new Warehouse(address(authority), HUB, vault, hub);
        usdc = _asset("USD Coin", "USDC", 6);

        bytes4[] memory adminSels = new bytes4[](2);
        adminSels[0] = Warehouse.setWithdrawSigner.selector;
        adminSels[1] = Warehouse.setSendModule.selector;

        vm.startPrank(admin);
        authority.setTargetFunctionRole(address(warehouse), adminSels, ADMIN_ROLE);
        authority.grantRole(WAREHOUSE_ROLE, address(warehouse));
        warehouse.setWithdrawSigner(signer);
        vm.stopPrank();

        _authorizeHub();

        vm.prank(vault);
        SafeTransferLib.safeApprove(address(usdc), address(warehouse), type(uint256).max);
    }

    function _asset(string memory name_, string memory symbol_, uint8 decimals_) internal returns (ERC20) {
        return ERC20(address(new MockERC20(name_, symbol_, decimals_)));
    }

    function _authorizeHub() internal {
        bytes4[] memory sels = new bytes4[](2);
        sels[0] = WarehouseHub.enter.selector;
        sels[1] = WarehouseHub.exit.selector;
        vm.prank(admin);
        authority.setTargetFunctionRole(address(hub), sels, WAREHOUSE_ROLE);
    }

    function _noBridge() internal pure returns (Warehouse.BridgeData memory) {
        return Warehouse.BridgeData(0, address(0), ERC20(address(0)), 0, "");
    }

    function _deposit(address user, uint256 amount) internal {
        deal(address(usdc), user, amount);
        vm.startPrank(user);
        SafeTransferLib.safeApprove(address(usdc), address(warehouse), amount);
        warehouse.deposit(usdc, amount, user, _noBridge());
        vm.stopPrank();
    }

    function _request(address owner, uint256 amount) internal returns (Warehouse.WithdrawRequest memory) {
        return Warehouse.WithdrawRequest({
            owner: owner,
            asset: usdc,
            assetChainId: HUB,
            amount: amount,
            to: owner,
            nonce: ++withdrawNonce,
            deadline: block.timestamp + 1 days
        });
    }

    function _sign(Warehouse.WithdrawRequest memory req, uint256 pk) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, warehouse.hashWithdrawRequest(req));
        return abi.encodePacked(r, s, v);
    }

    // ---------------------------------------------------------------- deposit

    function testDepositCreditsUserAndVault() public {
        _deposit(alice, 100e6);

        assertEq(hub.balanceOf(alice, HUB, address(usdc)), 100e6, "deposit: alice not credited hub balance");
        assertEq(usdc.balanceOf(vault), 100e6, "deposit: vault did not receive usdc");
        assertEq(usdc.balanceOf(alice), 0, "deposit: alice usdc not taken");
        assertEq(usdc.balanceOf(address(warehouse)), 0, "deposit: warehouse must never hold funds");
    }

    function testDepositAnyAssetCreditsHub() public {
        ERC20 other = _asset("Other", "OTH", 18);
        deal(address(other), alice, 1e18);
        vm.startPrank(alice);
        SafeTransferLib.safeApprove(address(other), address(warehouse), 1e18);
        warehouse.deposit(other, 1e18, alice, _noBridge());
        vm.stopPrank();

        assertEq(hub.balanceOf(alice, HUB, address(other)), 1e18, "deposit: arbitrary asset not credited on hub");
        assertEq(other.balanceOf(vault), 1e18, "deposit: vault did not receive arbitrary asset");
    }

    function testSpokeDepositCreditsHub() public {
        vm.chainId(SPOKE);
        Warehouse spokeWarehouse = new Warehouse(address(authority), HUB, vault, WarehouseHub(address(0)));
        MockCrosschainModule spokeModule = new MockCrosschainModule(address(authority), address(spokeWarehouse));
        ERC20 usdg = _asset("Global Dollar", "USDG", 6);

        vm.chainId(HUB);
        MockCrosschainModule hubModule = new MockCrosschainModule(address(authority), address(warehouse));

        bytes4[] memory warehouseSels = new bytes4[](2);
        warehouseSels[0] = Warehouse.setSendModule.selector;
        warehouseSels[1] = Warehouse.addChain.selector;

        bytes4[] memory peerSels = new bytes4[](1);
        peerSels[0] = CrosschainAdapter.setPeer.selector;

        bytes4[] memory receiveSels = new bytes4[](1);
        receiveSels[0] = Warehouse.receiveMessage.selector;

        vm.startPrank(admin);
        authority.setTargetFunctionRole(address(spokeWarehouse), warehouseSels, ADMIN_ROLE);
        authority.setTargetFunctionRole(address(warehouse), warehouseSels, ADMIN_ROLE);
        authority.setTargetFunctionRole(address(spokeModule), peerSels, ADMIN_ROLE);
        authority.setTargetFunctionRole(address(hubModule), peerSels, ADMIN_ROLE);
        authority.setTargetFunctionRole(address(warehouse), receiveSels, CROSSCHAIN_MODULE_ROLE);
        authority.grantRole(CROSSCHAIN_MODULE_ROLE, address(hubModule));

        spokeWarehouse.setSendModule(spokeModule);
        spokeWarehouse.addChain(HUB, true, true, 200_000, 0);
        spokeModule.setPeer(HUB, bytes32(uint256(uint160(address(hubModule)))), HUB);

        warehouse.addChain(SPOKE, true, true, 200_000, 0);
        hubModule.setPeer(SPOKE, bytes32(uint256(uint160(address(spokeModule)))), SPOKE);
        vm.stopPrank();

        vm.chainId(SPOKE);
        deal(address(usdg), alice, 100e6);
        vm.startPrank(alice);
        SafeTransferLib.safeApprove(address(usdg), address(spokeWarehouse), 100e6);
        spokeWarehouse.deposit(
            usdg, 100e6, alice, Warehouse.BridgeData(HUB, address(0), ERC20(address(0)), 200_000, "")
        );
        vm.stopPrank();

        assertEq(usdg.balanceOf(vault), 100e6, "spoke deposit: vault did not receive usdg");
        bytes[] memory queued = spokeModule.pending();
        assertEq(queued.length, 1, "spoke deposit: no Transfer message queued to hub");

        vm.chainId(HUB);
        hubModule.deliver(SPOKE, bytes32(uint256(uint160(address(spokeModule)))), queued[0]);

        assertEq(hub.balanceOf(alice, SPOKE, address(usdg)), 100e6, "spoke deposit: hub did not credit alice");
    }

    function testSpokeDepositToNonHubReverts() public {
        vm.chainId(SPOKE);
        Warehouse spokeWarehouse = new Warehouse(address(authority), HUB, vault, WarehouseHub(address(0)));

        deal(address(usdc), alice, 1e6);
        vm.startPrank(alice);
        SafeTransferLib.safeApprove(address(usdc), address(spokeWarehouse), 1e6);
        vm.expectRevert(Warehouse.DestinationNotHub.selector);
        spokeWarehouse.deposit(
            usdc, 1e6, alice, Warehouse.BridgeData(SPOKE, address(0), ERC20(address(0)), 200_000, "")
        );
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- hub auth

    function testOnlyWarehouseCanMint() public {
        vm.prank(mallory);
        vm.expectRevert();
        hub.enter(mallory, HUB, address(usdc), 1e6);
    }

    function testOnlyWarehouseCanBurn() public {
        _deposit(alice, 100e6);
        vm.prank(mallory);
        vm.expectRevert();
        hub.exit(alice, HUB, address(usdc), 100e6);
    }

    // ---------------------------------------------------------------- withdraw

    function testWithdrawWithValidSignature() public {
        _deposit(alice, 100e6);
        Warehouse.WithdrawRequest memory req = _request(alice, 100e6);

        bytes memory sig = _sign(req, signerPk);

        vm.prank(alice);
        warehouse.withdrawWithSignature(req, sig);

        assertEq(hub.balanceOf(alice, HUB, address(usdc)), 0, "withdraw: hub balance not burned");
        assertEq(usdc.balanceOf(alice), 100e6, "withdraw: alice did not receive usdc back");
        assertEq(usdc.balanceOf(vault), 0, "withdraw: vault did not release usdc");
    }

    function testWithdrawWithWrongSignerReverts() public {
        _deposit(alice, 100e6);
        Warehouse.WithdrawRequest memory req = _request(alice, 100e6);
        (, uint256 wrongPk) = makeAddrAndKey("notTheSigner");
        bytes memory sig = _sign(req, wrongPk);

        vm.prank(alice);
        vm.expectRevert(Warehouse.BadSignature.selector);
        warehouse.withdrawWithSignature(req, sig);
    }

    function testWithdrawReplayReverts() public {
        _deposit(alice, 200e6);
        Warehouse.WithdrawRequest memory req = _request(alice, 100e6);
        bytes memory sig = _sign(req, signerPk);

        vm.prank(alice);
        warehouse.withdrawWithSignature(req, sig);

        vm.prank(alice);
        vm.expectRevert(Warehouse.WithdrawReplay.selector);
        warehouse.withdrawWithSignature(req, sig);
    }

    function testWithdrawExpiredReverts() public {
        _deposit(alice, 100e6);
        Warehouse.WithdrawRequest memory req = _request(alice, 100e6);
        bytes memory sig = _sign(req, signerPk);

        vm.warp(req.deadline + 1);
        vm.prank(alice);
        vm.expectRevert(Warehouse.Expired.selector);
        warehouse.withdrawWithSignature(req, sig);
    }

    function testWithdrawBySomeoneElseReverts() public {
        _deposit(alice, 100e6);
        Warehouse.WithdrawRequest memory req = _request(alice, 100e6);

        bytes memory sig = _sign(req, signerPk);

        vm.prank(mallory);
        vm.expectRevert(Warehouse.BadSignature.selector);
        warehouse.withdrawWithSignature(req, sig);
    }

    // ---------------------------------------------------------------- messages

    function testReceiveMessageFromNonModuleReverts() public {
        Warehouse.TransferMessage memory m = Warehouse.TransferMessage({
            assetChainId: HUB, asset: address(usdc), nonce: ++withdrawNonce, amount: 1e6, to: alice
        });
        bytes memory payload = abi.encode(Warehouse.MessageType.Transfer, abi.encode(m));

        vm.prank(mallory);
        vm.expectRevert();
        warehouse.receiveMessage(SPOKE, payload);
    }

}
