// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { TransitAuthority } from "../../src/TransitAuthority.sol";
import { Warehouse } from "../../src/Warehouse.sol";
import { Hub } from "../../src/Hub.sol";
import { UserTerminal } from "../../src/UserTerminal.sol";
import { IMessagingAdapter } from "../../src/messaging/IMessagingAdapter.sol";
import { ITurnstile } from "../../src/ITurnstile.sol";
import { Turnstile } from "../../src/Turnstile.sol";
import { MockMessagingAdapter } from "../mocks/MockMessagingAdapter.sol";
import { MessagingAdapter } from "../../src/messaging/MessagingAdapter.sol";
import { MockERC20 } from "../../lib/solady/test/utils/mocks/MockERC20.sol";
import { ADMIN_ROLE, MESSAGING_ADAPTER_ROLE, SOLVER_ROLE, TURNSTILE_ROLE, TERMINAL_ROLE } from "../../src/helpers/Constants.sol";
import { TransitTokenLib } from "../../src/helpers/TransitTokenLib.sol";

contract WarehouseUnitTest is Test {

    uint64 constant HUB_CHAIN_ID = 1;
    uint64 constant SPOKE_CHAIN_ID = 4663;

    TransitAuthority authority;
    Warehouse warehouse;
    ERC20 usdc;
    Hub hub;
    UserTerminal userTerminal;
    Turnstile turnstile;
    MockMessagingAdapter local;

    address admin = makeAddr("admin");
    address vault = makeAddr("vault");
    address alice = makeAddr("alice");
    address mallory = makeAddr("mallory");

    address backend = makeAddr("backend");
    uint256 alicePk;
    uint256 withdrawNonce;

    function setUp() public {
        vm.chainId(HUB_CHAIN_ID);
        (, alicePk) = makeAddrAndKey("alice");

        authority = new TransitAuthority(admin);
        uint256 nonce = vm.getNonce(address(this));
        turnstile = new Turnstile(
            address(authority),
            vm.computeCreateAddress(address(this), nonce + 1),
            vm.computeCreateAddress(address(this), nonce + 2)
        );
        hub = new Hub(address(authority));
        warehouse = new Warehouse(address(authority), vault, address(turnstile), HUB_CHAIN_ID);
        local = new MockMessagingAdapter(address(authority), address(turnstile), HUB_CHAIN_ID);
        userTerminal = new UserTerminal(hub, address(turnstile));
        usdc = _asset("USD Coin", "USDC", 6);

        bytes4[] memory adminSels = new bytes4[](1);
        adminSels[0] = Warehouse.setAssetWhitelisted.selector;


        bytes4[] memory facilitateSels = new bytes4[](1);
        facilitateSels[0] = Turnstile.facilitate.selector;

        vm.startPrank(admin);
        authority.setTargetFunctionRole(address(warehouse), adminSels, ADMIN_ROLE);
        authority.setTargetFunctionRole(address(turnstile), facilitateSels, SOLVER_ROLE);
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
        sels[0] = Turnstile.receiveMessage.selector;

        bytes4[] memory turnstileAdminSels = new bytes4[](2);
        turnstileAdminSels[0] = Turnstile.setMessagingAdapter.selector;
        turnstileAdminSels[1] = Turnstile.setRoutable.selector;

        bytes4[] memory turnstileSendSels = new bytes4[](2);
        turnstileSendSels[0] = Turnstile.sendDepositMessage.selector;
        turnstileSendSels[1] = Turnstile.sendWithdrawalMessage.selector;

        bytes4[] memory receiveDepositSels = new bytes4[](1);
        receiveDepositSels[0] = Hub.receiveDeposit.selector;

        bytes4[] memory receiveWithdrawalSels = new bytes4[](1);
        receiveWithdrawalSels[0] = Warehouse.receiveWithdrawal.selector;

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
        authority.setTargetFunctionRole(address(hub), receiveDepositSels, TURNSTILE_ROLE);
        authority.grantRole(TURNSTILE_ROLE, address(turnstile));
        authority.grantRole(MESSAGING_ADAPTER_ROLE, address(userTerminal));
        bytes4[] memory userTerminalSels = new bytes4[](4);
        userTerminalSels[0] = Hub.reserve.selector;
        userTerminalSels[1] = Hub.release.selector;
        userTerminalSels[2] = Hub.transferFrom.selector;
        userTerminalSels[3] = Hub.burn.selector;
        authority.setTargetFunctionRole(address(hub), userTerminalSels, TERMINAL_ROLE);
        authority.grantRole(TERMINAL_ROLE, address(userTerminal));
        turnstile.setRoutable(address(userTerminal), routedSels, true);
        bytes4[] memory executeSels = new bytes4[](1);
        executeSels[0] = UserTerminal.executeWithdrawal.selector;
        turnstile.setRoutable(address(userTerminal), executeSels, true);
        turnstile.setMessagingAdapter(local);
        vm.stopPrank();
    }

    function _deposit(address user, uint256 amount) internal {
        deal(address(usdc), user, amount);
        vm.startPrank(user);
        SafeTransferLib.safeApprove(address(usdc), address(warehouse), amount);
        warehouse.deposit(address(usdc), amount, HUB_CHAIN_ID, user, 0);
        vm.stopPrank();
    }

    function _request(address owner, uint256 amount) internal returns (UserTerminal.WithdrawalRequest memory) {
        return UserTerminal.WithdrawalRequest({
            ownerChainId: HUB_CHAIN_ID,
            owner: owner,
            to: owner,
            assetId: TransitTokenLib.formatAssetId(HUB_CHAIN_ID, address(usdc)),
            amount: amount,
            nonce: ++withdrawNonce,
            deadline: type(uint256).max,
            partiallyFillable: true
        });
    }

    function _facilitatedCall(UserTerminal.WithdrawalRequest memory req) internal view returns (ITurnstile.FacilitatedCall memory) {
        return ITurnstile.FacilitatedCall({
            sender: req.owner,
            target: address(userTerminal),
            data: abi.encodeCall(UserTerminal.executeWithdrawal, (req, 0)),
            feeAssetId: bytes32(0),
            fee: 0,
            nonce: req.nonce,
            deadline: req.deadline
        });
    }

    function _withdraw(UserTerminal.WithdrawalRequest memory req, bytes memory sig) internal {
        ITurnstile.FacilitatedCall[] memory calls = new ITurnstile.FacilitatedCall[](1);
        calls[0] = _facilitatedCall(req);
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = sig;
        uint256[] memory values = new uint256[](1);
        turnstile.facilitate(calls, sigs, values);
    }

    function _sign(UserTerminal.WithdrawalRequest memory req, uint256 pk) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, turnstile.hashFacilitatedCall(_facilitatedCall(req)));
        return abi.encodePacked(r, s, v);
    }

    // ---------------------------------------------------------------- deposit

    function testDepositCreditsUserAndVault() public {
        _deposit(alice, 100e6);

        assertEq(hub.balanceOf(TransitTokenLib.formatAccountId(HUB_CHAIN_ID, alice), TransitTokenLib.formatAssetId(HUB_CHAIN_ID, address(usdc))), 100e6, "deposit: alice not credited hub balance");
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
        warehouse.deposit(address(other), 1e18, HUB_CHAIN_ID, alice, 0);
        vm.stopPrank();

        assertEq(hub.balanceOf(TransitTokenLib.formatAccountId(HUB_CHAIN_ID, alice), TransitTokenLib.formatAssetId(HUB_CHAIN_ID, address(other))), 1e18, "deposit: arbitrary asset not credited on hub");
        assertEq(other.balanceOf(vault), 1e18, "deposit: vault did not receive arbitrary asset");
    }

    function testSpokeDepositCreditsHub() public {
        vm.chainId(SPOKE_CHAIN_ID);
        Turnstile spokeTurnstile = new Turnstile(
            address(authority), address(0), vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1)
        );
        Warehouse spokeWarehouse = new Warehouse(address(authority), vault, address(spokeTurnstile), HUB_CHAIN_ID);
        MockMessagingAdapter spokeAdapter = new MockMessagingAdapter(address(authority), address(spokeTurnstile), HUB_CHAIN_ID);
        ERC20 usdg = _asset("Global Dollar", "USDG", 6);

        vm.chainId(HUB_CHAIN_ID);
        MockMessagingAdapter hubAdapter = new MockMessagingAdapter(address(authority), address(turnstile), HUB_CHAIN_ID);

        bytes4[] memory warehouseSels = new bytes4[](1);
        warehouseSels[0] = Warehouse.setAssetWhitelisted.selector;

        bytes4[] memory turnstileAdminSels = new bytes4[](1);
        turnstileAdminSels[0] = Turnstile.setMessagingAdapter.selector;

        bytes4[] memory turnstileSendSels = new bytes4[](2);
        turnstileSendSels[0] = Turnstile.sendDepositMessage.selector;
        turnstileSendSels[1] = Turnstile.sendWithdrawalMessage.selector;

        bytes4[] memory peerSels = new bytes4[](1);
        peerSels[0] = MessagingAdapter.setPeer.selector;

        bytes4[] memory receiveSels = new bytes4[](1);
        receiveSels[0] = Turnstile.receiveMessage.selector;

        vm.startPrank(admin);
        authority.setTargetFunctionRole(address(spokeWarehouse), warehouseSels, ADMIN_ROLE);
        authority.setTargetFunctionRole(address(warehouse), warehouseSels, ADMIN_ROLE);
        authority.setTargetFunctionRole(address(spokeTurnstile), turnstileAdminSels, ADMIN_ROLE);
        authority.setTargetFunctionRole(address(spokeTurnstile), turnstileSendSels, MESSAGING_ADAPTER_ROLE);
        authority.grantRole(MESSAGING_ADAPTER_ROLE, address(spokeWarehouse));
        authority.setTargetFunctionRole(address(spokeAdapter), peerSels, ADMIN_ROLE);
        authority.setTargetFunctionRole(address(hubAdapter), peerSels, ADMIN_ROLE);
        authority.setTargetFunctionRole(address(turnstile), receiveSels, MESSAGING_ADAPTER_ROLE);
        authority.grantRole(MESSAGING_ADAPTER_ROLE, address(hubAdapter));

        spokeTurnstile.setMessagingAdapter(spokeAdapter);
        spokeWarehouse.setAssetWhitelisted(_list(address(usdg)), true);
        spokeAdapter.setPeer(HUB_CHAIN_ID, bytes32(uint256(uint160(address(hubAdapter)))), HUB_CHAIN_ID, 200_000, 0, true, true);

        hubAdapter.setPeer(SPOKE_CHAIN_ID, bytes32(uint256(uint160(address(spokeAdapter)))), SPOKE_CHAIN_ID, 200_000, 0, true, true);
        vm.stopPrank();

        vm.chainId(SPOKE_CHAIN_ID);
        deal(address(usdg), alice, 100e6);
        vm.startPrank(alice);
        SafeTransferLib.safeApprove(address(usdg), address(spokeWarehouse), 100e6);
        spokeWarehouse.deposit(
            address(usdg), 100e6, SPOKE_CHAIN_ID, alice, 200_000
        );
        vm.stopPrank();

        assertEq(usdg.balanceOf(vault), 100e6, "spoke deposit: vault did not receive usdg");
        bytes[] memory queued = spokeAdapter.pending();
        assertEq(queued.length, 1, "spoke deposit: no Transfer message queued to hub");

        vm.chainId(HUB_CHAIN_ID);
        hubAdapter.deliver(SPOKE_CHAIN_ID, bytes32(uint256(uint160(address(spokeAdapter)))), queued[0]);

        assertEq(hub.balanceOf(TransitTokenLib.formatAccountId(SPOKE_CHAIN_ID, alice), TransitTokenLib.formatAssetId(SPOKE_CHAIN_ID, address(usdg))), 100e6, "spoke deposit: hub did not credit alice");
    }

    // ---------------------------------------------------------------- hub auth

    function testOnlyWarehouseCanMint() public {
        ITurnstile.DepositMessage memory message = ITurnstile.DepositMessage({ asset: address(usdc), nonce: 1, amount: 1e6, toAccountId: TransitTokenLib.formatAccountId(HUB_CHAIN_ID, mallory) });
        bytes memory payload = abi.encode(ITurnstile.MessageType.Deposit, abi.encode(message));
        vm.prank(mallory);
        vm.expectRevert();
        turnstile.receiveMessage(HUB_CHAIN_ID, payload);

        vm.prank(mallory);
        vm.expectRevert();
        hub.receiveDeposit(HUB_CHAIN_ID, message.asset, message.amount, message.toAccountId);
    }

    // ---------------------------------------------------------------- withdraw

    function testWithdrawWithValidSignature() public {
        _deposit(alice, 100e6);
        UserTerminal.WithdrawalRequest memory req = _request(alice, 100e6);

        bytes memory sig = _sign(req, alicePk);

        vm.prank(backend);
        _withdraw(req, sig);

        assertEq(hub.balanceOf(TransitTokenLib.formatAccountId(HUB_CHAIN_ID, alice), TransitTokenLib.formatAssetId(HUB_CHAIN_ID, address(usdc))), 0, "withdraw: hub balance not burned");
        assertEq(usdc.balanceOf(alice), 100e6, "withdraw: alice did not receive usdc back");
        assertEq(usdc.balanceOf(vault), 0, "withdraw: vault did not release usdc");
    }

    function testWithdrawWithWrongSignerReverts() public {
        _deposit(alice, 100e6);
        UserTerminal.WithdrawalRequest memory req = _request(alice, 100e6);
        (, uint256 wrongPk) = makeAddrAndKey("notTheSigner");
        bytes memory sig = _sign(req, wrongPk);

        vm.prank(backend);
        vm.expectRevert(ITurnstile.BadSignature.selector);
        _withdraw(req, sig);
    }

    function testWithdrawReplayReverts() public {
        _deposit(alice, 200e6);
        UserTerminal.WithdrawalRequest memory req = _request(alice, 100e6);
        bytes memory sig = _sign(req, alicePk);

        vm.prank(backend);
        _withdraw(req, sig);

        vm.prank(backend);
        vm.expectRevert(ITurnstile.MessageReplay.selector);
        _withdraw(req, sig);
    }

    function testWithdrawBySomeoneElseReverts() public {
        _deposit(alice, 100e6);
        UserTerminal.WithdrawalRequest memory req = _request(alice, 100e6);

        bytes memory sig = _sign(req, alicePk);

        vm.prank(mallory);
        vm.expectRevert();
        _withdraw(req, sig);
    }

    // ---------------------------------------------------------------- messages

    function testReceiveMessageFromNonAdapterReverts() public {
        ITurnstile.WithdrawalMessage memory m =
            ITurnstile.WithdrawalMessage({ asset: address(usdc), nonce: ++withdrawNonce, amount: 1e6, to: alice });
        bytes memory payload = abi.encode(ITurnstile.MessageType.Withdrawal, abi.encode(m));

        vm.prank(mallory);
        vm.expectRevert();
        turnstile.receiveMessage(SPOKE_CHAIN_ID, payload);

        vm.prank(mallory);
        vm.expectRevert();
        warehouse.receiveWithdrawal(m.asset, m.amount, m.to);
    }

}
