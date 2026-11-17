// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { dispatchOne } from "../helpers/DispatchOne.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { ITurnstile } from "../../src/interfaces/ITurnstile.sol";
import { Turnstile } from "../../src/turnstile/Turnstile.sol";
import { MockMessagingAdapter } from "../mocks/MockMessagingAdapter.sol";
import { MessagingAdapter } from "../../src/messaging/MessagingAdapter.sol";
import { Roles } from "../../src/helpers/Roles.sol";
import { TransitAccountLib } from "../../src/helpers/TransitAccountLib.sol";
import { WarehouseConductorUnitBase } from "./WarehouseConductorUnitBase.t.sol";

contract TurnstileCustodyUnitTest is WarehouseConductorUnitBase {

    // ---------------------------------------------------------------- deposit

    function testDepositCreditsUserAndVault() public {
        _deposit(alice, 100e6);

        assertEq(
            depot.balanceOf(
                TransitAccountLib.formatAccountId(HUB_CHAIN_ID, alice),
                TransitAccountLib.formatAccountId(HUB_CHAIN_ID, address(usdc))
            ),
            100e6,
            "deposit: alice not credited depot balance"
        );
        assertEq(usdc.balanceOf(vault), 100e6, "deposit: vault did not receive usdc");
        assertEq(usdc.balanceOf(alice), 0, "deposit: alice usdc not taken");
        assertEq(usdc.balanceOf(address(turnstile)), 0, "deposit: turnstile must never hold funds");
    }

    function testDepositWhitelistedAssetCreditsDepot() public {
        ERC20 other = _asset("Other", "OTH", 18);
        vm.prank(admin);
        turnstile.setAssetWhitelisted(_list(address(other)), true);
        deal(address(other), alice, 1e18);
        vm.startPrank(alice);
        SafeTransferLib.safeApprove(address(other), address(turnstile), 1e18);
        dispatchOne(
            turnstile,
            ITurnstile.ActionType.Deposit,
            abi.encode(
                ITurnstile.DepositAction({
                    ownerChainId: HUB_CHAIN_ID,
                    owner: alice,
                    asset: address(other),
                    amount: 1e18,
                    toChainId: HUB_CHAIN_ID,
                    to: alice,
                    deadline: type(uint256).max,
                    salt: bytes32(0),
                    permit: ITurnstile.Permit({ deadline: 0, v: 0, r: bytes32(0), s: bytes32(0) })
                })
            ),
            0
        );
        vm.stopPrank();

        assertEq(
            depot.balanceOf(
                TransitAccountLib.formatAccountId(HUB_CHAIN_ID, alice),
                TransitAccountLib.formatAccountId(HUB_CHAIN_ID, address(other))
            ),
            1e18,
            "deposit: arbitrary asset not credited on depot"
        );
        assertEq(other.balanceOf(vault), 1e18, "deposit: vault did not receive arbitrary asset");
    }

    function testSpokeDepositCreditsDepot() public {
        vm.chainId(SPOKE_CHAIN_ID);
        Turnstile spokeTurnstile = new Turnstile(address(authority), vault);
        MockMessagingAdapter spokeAdapter =
            new MockMessagingAdapter(address(authority), address(spokeTurnstile), HUB_CHAIN_ID);
        ERC20 usdg = _asset("Global Dollar", "USDG", 6);

        vm.chainId(HUB_CHAIN_ID);
        MockMessagingAdapter hubAdapter = new MockMessagingAdapter(address(authority), address(turnstile), HUB_CHAIN_ID);

        bytes4[] memory turnstileAdminSels = new bytes4[](2);
        turnstileAdminSels[0] = Turnstile.setMessagingAdapter.selector;
        turnstileAdminSels[1] = Turnstile.setAssetWhitelisted.selector;

        bytes4[] memory peerSels = new bytes4[](1);
        peerSels[0] = MessagingAdapter.setPeer.selector;

        bytes4[] memory receiveSels = new bytes4[](1);
        receiveSels[0] = Turnstile.receiveMessage.selector;

        vm.startPrank(admin);
        authority.setTargetFunctionRole(address(spokeTurnstile), turnstileAdminSels, Roles.ADMIN);
        authority.setTargetFunctionRole(address(spokeAdapter), peerSels, Roles.ADMIN);
        authority.setTargetFunctionRole(address(hubAdapter), peerSels, Roles.ADMIN);
        authority.setTargetFunctionRole(address(turnstile), receiveSels, Roles.MESSAGING_ADAPTER);
        authority.grantRole(Roles.MESSAGING_ADAPTER, address(hubAdapter));

        spokeTurnstile.setMessagingAdapter(address(spokeAdapter));
        spokeTurnstile.setAssetWhitelisted(_list(address(usdg)), true);
        spokeAdapter.setPeer(
            HUB_CHAIN_ID, bytes32(uint256(uint160(address(hubAdapter)))), HUB_CHAIN_ID, 200_000, 0, true, true
        );

        hubAdapter.setPeer(
            SPOKE_CHAIN_ID, bytes32(uint256(uint160(address(spokeAdapter)))), SPOKE_CHAIN_ID, 200_000, 0, true, true
        );
        vm.stopPrank();

        vm.chainId(SPOKE_CHAIN_ID);
        deal(address(usdg), alice, 100e6);
        vm.startPrank(alice);
        SafeTransferLib.safeApprove(address(usdg), address(spokeTurnstile), 100e6);
        dispatchOne(
            spokeTurnstile,
            ITurnstile.ActionType.Deposit,
            abi.encode(
                ITurnstile.DepositAction({
                    ownerChainId: SPOKE_CHAIN_ID,
                    owner: alice,
                    asset: address(usdg),
                    amount: 100e6,
                    toChainId: SPOKE_CHAIN_ID,
                    to: alice,
                    deadline: type(uint256).max,
                    salt: bytes32(0),
                    permit: ITurnstile.Permit({ deadline: 0, v: 0, r: bytes32(0), s: bytes32(0) })
                })
            ),
            200_000
        );
        vm.stopPrank();

        assertEq(usdg.balanceOf(vault), 100e6, "spoke deposit: vault did not receive usdg");
        bytes[] memory queued = spokeAdapter.pending();
        assertEq(queued.length, 1, "spoke deposit: no Transfer message queued to depot");

        vm.chainId(HUB_CHAIN_ID);
        hubAdapter.deliver(SPOKE_CHAIN_ID, bytes32(uint256(uint160(address(spokeAdapter)))), queued[0]);

        assertEq(
            depot.balanceOf(
                TransitAccountLib.formatAccountId(SPOKE_CHAIN_ID, alice),
                TransitAccountLib.formatAccountId(SPOKE_CHAIN_ID, address(usdg))
            ),
            100e6,
            "spoke deposit: depot did not credit alice"
        );
    }

    // ---------------------------------------------------------------- admin

    function testSetHubWarehouseConductorRevertsOffHub() public {
        vm.chainId(SPOKE_CHAIN_ID);
        Turnstile spokeTurnstile = new Turnstile(address(authority), vault);
        MockMessagingAdapter spokeAdapter =
            new MockMessagingAdapter(address(authority), address(spokeTurnstile), HUB_CHAIN_ID);

        bytes4[] memory turnstileAdminSels = new bytes4[](2);
        turnstileAdminSels[0] = Turnstile.setMessagingAdapter.selector;
        turnstileAdminSels[1] = Turnstile.setHubWarehouseConductor.selector;

        vm.startPrank(admin);
        authority.setTargetFunctionRole(address(spokeTurnstile), turnstileAdminSels, Roles.ADMIN);
        spokeTurnstile.setMessagingAdapter(address(spokeAdapter));
        vm.expectRevert(ITurnstile.NotHubChain.selector);
        spokeTurnstile.setHubWarehouseConductor(address(hubWarehouseConductor));
        vm.stopPrank();

        assertEq(spokeTurnstile.hubWarehouseConductor(), address(0), "spoke: hub warehouse conductor was set");
    }

    // ---------------------------------------------------------------- messages

    function testReceiveMessageFromNonAdapterReverts() public {
        ITurnstile.WithdrawalMessage memory m = ITurnstile.WithdrawalMessage({
            asset: address(usdc), amount: 1e6, to: alice, salt: bytes32(++withdrawSalt)
        });
        bytes memory payload = abi.encode(ITurnstile.ActionType.Withdrawal, abi.encode(m));

        vm.prank(mallory);
        vm.expectRevert();
        turnstile.receiveMessage(SPOKE_CHAIN_ID, payload);
    }

}
