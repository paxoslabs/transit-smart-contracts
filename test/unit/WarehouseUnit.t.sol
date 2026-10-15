// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { TransitAuthority } from "../../src/TransitAuthority.sol";
import { Warehouse } from "../../src/Warehouse.sol";
import { Hub } from "../../src/Hub.sol";
import { MessagingEndpoint } from "../../src/messaging/MessagingEndpoint.sol";
import { MockMessagingAdapter } from "../mocks/MockMessagingAdapter.sol";
import { MessagingAdapter } from "../../src/messaging/MessagingAdapter.sol";
import { MockERC20 } from "../../lib/solady/test/utils/mocks/MockERC20.sol";
import { ADMIN_ROLE, MESSAGING_ADAPTER_ROLE, SOLVER_ROLE } from "../../src/helpers/Constants.sol";

contract WarehouseUnitTest is Test {

    uint64 constant HUB = 1;
    uint64 constant SPOKE = 4663;

    TransitAuthority authority;
    Warehouse warehouse;
    ERC20 usdc;
    Hub hub;
    MockMessagingAdapter local;

    address admin = makeAddr("admin");
    address vault = makeAddr("vault");
    address alice = makeAddr("alice");
    address mallory = makeAddr("mallory");

    address backend = makeAddr("backend");
    uint256 alicePk;
    uint256 withdrawNonce;

    function setUp() public {
        vm.chainId(HUB);
        (, alicePk) = makeAddrAndKey("alice");

        authority = new TransitAuthority(admin);
        hub = new Hub(address(authority));
        warehouse = new Warehouse(address(authority), vault);
        local = new MockMessagingAdapter(address(authority), address(hub), address(warehouse), HUB);
        usdc = _asset("USD Coin", "USDC", 6);

        bytes4[] memory adminSels = new bytes4[](2);
        adminSels[0] = MessagingEndpoint.setMessagingAdapter.selector;
        adminSels[1] = Warehouse.setAssetWhitelisted.selector;

        bytes4[] memory hubAdminSels = new bytes4[](1);
        hubAdminSels[0] = MessagingEndpoint.setMessagingAdapter.selector;

        bytes4[] memory withdrawSels = new bytes4[](1);
        withdrawSels[0] = Hub.withdrawWithSignature.selector;

        vm.startPrank(admin);
        authority.setTargetFunctionRole(address(warehouse), adminSels, ADMIN_ROLE);
        authority.setTargetFunctionRole(address(hub), hubAdminSels, ADMIN_ROLE);
        authority.setTargetFunctionRole(address(hub), withdrawSels, SOLVER_ROLE);
        authority.grantRole(SOLVER_ROLE, backend);
        warehouse.setAssetWhitelisted(_list(address(usdc)), true);
        vm.stopPrank();

        _authorizeHub();

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

    function _authorizeHub() internal {
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = MessagingEndpoint.receiveMessage.selector;
        vm.startPrank(admin);
        authority.setTargetFunctionRole(address(hub), sels, MESSAGING_ADAPTER_ROLE);
        authority.setTargetFunctionRole(address(warehouse), sels, MESSAGING_ADAPTER_ROLE);
        authority.grantRole(MESSAGING_ADAPTER_ROLE, address(local));
        hub.setMessagingAdapter(local);
        warehouse.setMessagingAdapter(local);
        vm.stopPrank();
    }

    function _deposit(address user, uint256 amount) internal {
        deal(address(usdc), user, amount);
        vm.startPrank(user);
        SafeTransferLib.safeApprove(address(usdc), address(warehouse), amount);
        warehouse.deposit(usdc, amount, user, 0);
        vm.stopPrank();
    }

    function _request(address owner, uint256 amount) internal returns (Hub.WithdrawRequest memory) {
        return Hub.WithdrawRequest({
            owner: owner,
            asset: usdc,
            assetChainId: HUB,
            amount: amount,
            to: owner,
            nonce: ++withdrawNonce
        });
    }

    function _withdraw(Hub.WithdrawRequest memory req, bytes memory sig) internal {
        Hub.WithdrawRequest[] memory reqs = new Hub.WithdrawRequest[](1);
        reqs[0] = req;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = sig;
        hub.withdrawWithSignature(reqs, sigs, 0);
    }

    function _sign(Hub.WithdrawRequest memory req, uint256 pk) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, hub.hashWithdrawRequest(req));
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

    function testDepositWhitelistedAssetCreditsHub() public {
        ERC20 other = _asset("Other", "OTH", 18);
        vm.prank(admin);
        warehouse.setAssetWhitelisted(_list(address(other)), true);
        deal(address(other), alice, 1e18);
        vm.startPrank(alice);
        SafeTransferLib.safeApprove(address(other), address(warehouse), 1e18);
        warehouse.deposit(other, 1e18, alice, 0);
        vm.stopPrank();

        assertEq(hub.balanceOf(alice, HUB, address(other)), 1e18, "deposit: arbitrary asset not credited on hub");
        assertEq(other.balanceOf(vault), 1e18, "deposit: vault did not receive arbitrary asset");
    }

    function testSpokeDepositCreditsHub() public {
        vm.chainId(SPOKE);
        Warehouse spokeWarehouse = new Warehouse(address(authority), vault);
        MockMessagingAdapter spokeAdapter = new MockMessagingAdapter(address(authority), address(spokeWarehouse), address(0), HUB);
        ERC20 usdg = _asset("Global Dollar", "USDG", 6);

        vm.chainId(HUB);
        MockMessagingAdapter hubAdapter = new MockMessagingAdapter(address(authority), address(hub), address(0), HUB);

        bytes4[] memory warehouseSels = new bytes4[](2);
        warehouseSels[0] = MessagingEndpoint.setMessagingAdapter.selector;
        warehouseSels[1] = Warehouse.setAssetWhitelisted.selector;

        bytes4[] memory peerSels = new bytes4[](1);
        peerSels[0] = MessagingAdapter.setPeer.selector;

        bytes4[] memory receiveSels = new bytes4[](1);
        receiveSels[0] = MessagingEndpoint.receiveMessage.selector;

        vm.startPrank(admin);
        authority.setTargetFunctionRole(address(spokeWarehouse), warehouseSels, ADMIN_ROLE);
        authority.setTargetFunctionRole(address(warehouse), warehouseSels, ADMIN_ROLE);
        authority.setTargetFunctionRole(address(spokeAdapter), peerSels, ADMIN_ROLE);
        authority.setTargetFunctionRole(address(hubAdapter), peerSels, ADMIN_ROLE);
        authority.setTargetFunctionRole(address(hub), receiveSels, MESSAGING_ADAPTER_ROLE);
        authority.grantRole(MESSAGING_ADAPTER_ROLE, address(hubAdapter));

        spokeWarehouse.setMessagingAdapter(spokeAdapter);
        spokeWarehouse.setAssetWhitelisted(_list(address(usdg)), true);
        spokeAdapter.setPeer(HUB, bytes32(uint256(uint160(address(hubAdapter)))), HUB, 200_000, 0, true, true);

        hubAdapter.setPeer(SPOKE, bytes32(uint256(uint160(address(spokeAdapter)))), SPOKE, 200_000, 0, true, true);
        vm.stopPrank();

        vm.chainId(SPOKE);
        deal(address(usdg), alice, 100e6);
        vm.startPrank(alice);
        SafeTransferLib.safeApprove(address(usdg), address(spokeWarehouse), 100e6);
        spokeWarehouse.deposit(
            usdg, 100e6, alice, 200_000
        );
        vm.stopPrank();

        assertEq(usdg.balanceOf(vault), 100e6, "spoke deposit: vault did not receive usdg");
        bytes[] memory queued = spokeAdapter.pending();
        assertEq(queued.length, 1, "spoke deposit: no Transfer message queued to hub");

        vm.chainId(HUB);
        hubAdapter.deliver(SPOKE, bytes32(uint256(uint160(address(spokeAdapter)))), queued[0]);

        assertEq(hub.balanceOf(alice, SPOKE, address(usdg)), 100e6, "spoke deposit: hub did not credit alice");
    }

    // ---------------------------------------------------------------- hub auth

    function testOnlyWarehouseCanMint() public {
        bytes memory payload = abi.encode(
            MessagingEndpoint.MessageType.Deposit,
            abi.encode(MessagingEndpoint.TransferMessage({ asset: address(usdc), nonce: 1, amount: 1e6, to: mallory }))
        );
        vm.prank(mallory);
        vm.expectRevert();
        hub.receiveMessage(HUB, payload);
    }

    // ---------------------------------------------------------------- withdraw

    function testWithdrawWithValidSignature() public {
        _deposit(alice, 100e6);
        Hub.WithdrawRequest memory req = _request(alice, 100e6);

        bytes memory sig = _sign(req, alicePk);

        vm.prank(backend);
        _withdraw(req, sig);

        assertEq(hub.balanceOf(alice, HUB, address(usdc)), 0, "withdraw: hub balance not burned");
        assertEq(usdc.balanceOf(alice), 100e6, "withdraw: alice did not receive usdc back");
        assertEq(usdc.balanceOf(vault), 0, "withdraw: vault did not release usdc");
    }

    function testWithdrawWithWrongSignerReverts() public {
        _deposit(alice, 100e6);
        Hub.WithdrawRequest memory req = _request(alice, 100e6);
        (, uint256 wrongPk) = makeAddrAndKey("notTheSigner");
        bytes memory sig = _sign(req, wrongPk);

        vm.prank(backend);
        vm.expectRevert(Hub.BadSignature.selector);
        _withdraw(req, sig);
    }

    function testWithdrawReplayReverts() public {
        _deposit(alice, 200e6);
        Hub.WithdrawRequest memory req = _request(alice, 100e6);
        bytes memory sig = _sign(req, alicePk);

        vm.prank(backend);
        _withdraw(req, sig);

        vm.prank(backend);
        vm.expectRevert(Hub.WithdrawReplay.selector);
        _withdraw(req, sig);
    }

    function testWithdrawBySomeoneElseReverts() public {
        _deposit(alice, 100e6);
        Hub.WithdrawRequest memory req = _request(alice, 100e6);

        bytes memory sig = _sign(req, alicePk);

        vm.prank(mallory);
        vm.expectRevert();
        _withdraw(req, sig);
    }

    // ---------------------------------------------------------------- messages

    function testReceiveMessageFromNonAdapterReverts() public {
        MessagingEndpoint.TransferMessage[] memory m = new MessagingEndpoint.TransferMessage[](1);
        m[0] = MessagingEndpoint.TransferMessage({ asset: address(usdc), nonce: ++withdrawNonce, amount: 1e6, to: alice });
        bytes memory payload = abi.encode(MessagingEndpoint.MessageType.Withdrawal, abi.encode(m));

        vm.prank(mallory);
        vm.expectRevert();
        warehouse.receiveMessage(SPOKE, payload);
    }

}
