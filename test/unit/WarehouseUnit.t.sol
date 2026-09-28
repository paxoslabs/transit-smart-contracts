// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { TransitAuthority } from "../../src/warehouse/TransitAuthority.sol";
import { Warehouse } from "../../src/warehouse/Warehouse.sol";
import { WarehouseToken } from "../../src/warehouse/WarehouseToken.sol";
import { MockCrosschainModule } from "../mocks/MockCrosschainModule.sol";
import { CrosschainAdapter } from "../../src/warehouse/crosschain/CrosschainAdapter.sol";
import { ADMIN_ROLE, WAREHOUSE_ROLE } from "../../src/helpers/Constants.sol";

contract WarehouseUnitTest is Test {

    uint64 constant HUB = 1;
    uint64 constant SPOKE = 4663;

    TransitAuthority authority;
    Warehouse warehouse;
    ERC20 usdc;
    WarehouseToken token;

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
        warehouse = new Warehouse(address(authority), HUB, vault);
        usdc = _asset("USD Coin", "USDC", 6);

        bytes4[] memory adminSels = new bytes4[](3);
        adminSels[0] = Warehouse.launchToken.selector;
        adminSels[1] = Warehouse.setWithdrawSigner.selector;
        adminSels[2] = Warehouse.setSendModule.selector;

        vm.startPrank(admin);
        authority.setTargetFunctionRole(address(warehouse), adminSels, ADMIN_ROLE);
        authority.grantRole(WAREHOUSE_ROLE, address(warehouse));
        warehouse.setWithdrawSigner(signer);
        token = warehouse.launchToken(usdc, "USDC", 6, _noBridge());
        vm.stopPrank();

        _authorizeToken(token);

        vm.prank(vault);
        SafeTransferLib.safeApprove(address(usdc), address(token), type(uint256).max);
    }

    function _asset(string memory name_, string memory symbol_, uint8 decimals_) internal returns (ERC20) {
        return ERC20(address(new WarehouseToken(address(authority), vault, name_, symbol_, decimals_)));
    }

    function _authorizeToken(WarehouseToken t) internal {
        bytes4[] memory sels = new bytes4[](2);
        sels[0] = WarehouseToken.enter.selector;
        sels[1] = WarehouseToken.exit.selector;
        vm.prank(admin);
        authority.setTargetFunctionRole(address(t), sels, WAREHOUSE_ROLE);
    }

    function _noBridge() internal pure returns (Warehouse.BridgeData memory) {
        return Warehouse.BridgeData(0, address(0), ERC20(address(0)), 0, "");
    }

    function _deposit(address user, uint256 amount) internal {
        deal(address(usdc), user, amount);
        vm.startPrank(user);
        SafeTransferLib.safeApprove(address(usdc), address(token), amount);
        warehouse.deposit(usdc, amount, user);
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

    // ---------------------------------------------------------------- launch

    function testLaunchCopiesDecimalsAndNamespacesSymbol() public view {
        assertEq(token.decimals(), 6, "launch: warehouse token decimals do not match underlying");
        assertEq(token.symbol(), "transit_1_USDC", "launch: symbol not namespaced by chain id");
        assertEq(token.name(), "transit_1_USDC", "launch: name should match symbol");
    }

    function testLaunchRejectsDecimalsMismatch() public {
        ERC20 weird = _asset("Weird", "WRD", 18);
        vm.prank(admin);
        vm.expectRevert(Warehouse.DecimalsMismatch.selector);
        warehouse.launchToken(weird, "WRD", 6, _noBridge());
    }

    function testRelaunchReverts() public {
        vm.prank(admin);
        vm.expectRevert(Warehouse.AlreadyLaunched.selector);
        warehouse.launchToken(usdc, "USDC", 6, _noBridge());
    }

    function testLaunchByNonAdminReverts() public {
        ERC20 other = _asset("Other", "OTH", 6);
        vm.prank(mallory);
        vm.expectRevert();
        warehouse.launchToken(other, "OTH", 6, _noBridge());
    }

    // ---------------------------------------------------------------- deposit

    function testDepositCreditsUserAndVault() public {
        _deposit(alice, 100e6);

        assertEq(token.balanceOf(alice), 100e6, "deposit: alice not credited transit token");
        assertEq(usdc.balanceOf(vault), 100e6, "deposit: vault did not receive usdc");
        assertEq(usdc.balanceOf(alice), 0, "deposit: alice usdc not taken");
        assertEq(usdc.balanceOf(address(warehouse)), 0, "deposit: warehouse must never hold funds");
    }

    function testDepositUnregisteredAssetReverts() public {
        ERC20 other = _asset("Other", "OTH", 6);
        deal(address(other), alice, 1e6);
        vm.startPrank(alice);
        SafeTransferLib.safeApprove(address(other), address(warehouse), 1e6);
        vm.expectRevert(Warehouse.NotRegistered.selector);
        warehouse.deposit(other, 1e6, alice);
        vm.stopPrank();
    }

    function testSpokeLaunchQueuesHubMirrorMessage() public {
        vm.chainId(SPOKE);
        Warehouse spokeWarehouse = new Warehouse(address(authority), HUB, vault);
        MockCrosschainModule spokeModule = new MockCrosschainModule(address(authority), address(spokeWarehouse));

        bytes4[] memory sels = new bytes4[](3);
        sels[0] = Warehouse.launchToken.selector;
        sels[1] = Warehouse.setSendModule.selector;
        sels[2] = Warehouse.addChain.selector;

        bytes4[] memory peerSels = new bytes4[](1);
        peerSels[0] = CrosschainAdapter.setPeer.selector;

        vm.startPrank(admin);
        authority.setTargetFunctionRole(address(spokeWarehouse), sels, ADMIN_ROLE);
        authority.setTargetFunctionRole(address(spokeModule), peerSels, ADMIN_ROLE);
        authority.grantRole(WAREHOUSE_ROLE, address(spokeWarehouse));
        spokeWarehouse.setSendModule(spokeModule);
        spokeWarehouse.addChain(HUB, true, true, 200_000, 0);
        spokeModule.setPeer(HUB, bytes32(uint256(uint160(address(warehouse)))), HUB);

        ERC20 usdg = _asset("Global Dollar", "USDG", 6);
        spokeWarehouse.launchToken(
            usdg, "USDG", 6, Warehouse.BridgeData(HUB, address(0), ERC20(address(0)), 200_000, "")
        );
        vm.stopPrank();

        bytes[] memory queued = spokeModule.pending();
        assertEq(queued.length, 1, "launch: spoke did not queue a hub mirror message");

        (Warehouse.MessageType messageType, bytes memory body) = abi.decode(queued[0], (Warehouse.MessageType, bytes));
        assertEq(uint8(messageType), uint8(Warehouse.MessageType.Launch), "launch: queued message is not a Launch");

        Warehouse.LaunchMessage memory m = abi.decode(body, (Warehouse.LaunchMessage));
        assertEq(m.asset, address(usdg), "launch: message carries the wrong asset");
        assertEq(m.decimals, 6, "launch: message carries the wrong decimals");
    }

    function testHubLaunchQueuesNothing() public {
        assertEq(address(warehouse.tokenForAsset(usdc)), address(token), "launch: hub token not registered locally");
    }

    // ---------------------------------------------------------------- token auth

    function testOnlyWarehouseCanMint() public {
        vm.prank(mallory);
        vm.expectRevert();
        token.enter(address(0), ERC20(address(0)), 0, mallory, 1e6);
    }

    function testOnlyWarehouseCanBurn() public {
        _deposit(alice, 100e6);
        vm.prank(mallory);
        vm.expectRevert();
        token.exit(mallory, usdc, 100e6, alice, 100e6);
    }

    // ---------------------------------------------------------------- withdraw

    function testWithdrawWithValidSignature() public {
        _deposit(alice, 100e6);
        Warehouse.WithdrawRequest memory req = _request(alice, 100e6);

        bytes memory sig = _sign(req, signerPk);

        vm.prank(alice);
        warehouse.withdrawWithSignature(req, sig);

        assertEq(token.balanceOf(alice), 0, "withdraw: transit token not burned");
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
        Warehouse.TransferMessage memory m =
            Warehouse.TransferMessage({ token: address(token), nonce: ++withdrawNonce, amount: 1e6, to: alice });
        bytes memory payload = abi.encode(Warehouse.MessageType.Transfer, abi.encode(m));

        vm.prank(mallory);
        vm.expectRevert();
        warehouse.receiveMessage(SPOKE, payload);
    }

}
