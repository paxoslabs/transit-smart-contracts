// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { ERC20 } from "solady/tokens/ERC20.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { SpokeWarehouse } from "../../src/SpokeWarehouse.sol";
import { ITurnstile } from "../../src/turnstile/ITurnstile.sol";
import { Turnstile } from "../../src/turnstile/Turnstile.sol";
import { MockMessagingAdapter } from "../mocks/MockMessagingAdapter.sol";
import { MessagingAdapter } from "../../src/messaging/MessagingAdapter.sol";
import { ADMIN_ROLE, MESSAGING_ADAPTER_ROLE, TURNSTILE_ROLE } from "../../src/helpers/Constants.sol";
import { TransitTokenLib } from "../../src/helpers/TransitTokenLib.sol";
import { WarehouseConductorUnitBase } from "./WarehouseConductorUnitBase.t.sol";

contract SpokeWarehouseUnitTest is WarehouseConductorUnitBase {

    // ---------------------------------------------------------------- deposit

    function testDepositCreditsUserAndVault() public {
        _deposit(alice, 100e6);

        assertEq(
            depot.balanceOf(
                TransitTokenLib.formatAccountId(HUB_CHAIN_ID, alice),
                TransitTokenLib.formatAssetId(HUB_CHAIN_ID, address(usdc))
            ),
            100e6,
            "deposit: alice not credited depot balance"
        );
        assertEq(usdc.balanceOf(vault), 100e6, "deposit: vault did not receive usdc");
        assertEq(usdc.balanceOf(alice), 0, "deposit: alice usdc not taken");
        assertEq(usdc.balanceOf(address(warehouse)), 0, "deposit: warehouse must never hold funds");
    }

    function testDepositWhitelistedAssetCreditsDepot() public {
        ERC20 other = _asset("Other", "OTH", 18);
        vm.prank(admin);
        warehouse.setAssetWhitelisted(_list(address(other)), true);
        deal(address(other), alice, 1e18);
        vm.startPrank(alice);
        SafeTransferLib.safeApprove(address(other), address(warehouse), 1e18);
        turnstile.deposit(address(other), 1e18, HUB_CHAIN_ID, alice, 0);
        vm.stopPrank();

        assertEq(
            depot.balanceOf(
                TransitTokenLib.formatAccountId(HUB_CHAIN_ID, alice),
                TransitTokenLib.formatAssetId(HUB_CHAIN_ID, address(other))
            ),
            1e18,
            "deposit: arbitrary asset not credited on depot"
        );
        assertEq(other.balanceOf(vault), 1e18, "deposit: vault did not receive arbitrary asset");
    }

    function testSpokeDepositCreditsDepot() public {
        vm.chainId(SPOKE_CHAIN_ID);
        SpokeWarehouse spokeWarehouse = new SpokeWarehouse(address(authority), vault);
        Turnstile spokeTurnstile = new Turnstile(address(authority), address(spokeWarehouse));
        MockMessagingAdapter spokeAdapter =
            new MockMessagingAdapter(address(authority), address(spokeTurnstile), HUB_CHAIN_ID);
        ERC20 usdg = _asset("Global Dollar", "USDG", 6);

        vm.chainId(HUB_CHAIN_ID);
        MockMessagingAdapter hubAdapter = new MockMessagingAdapter(address(authority), address(turnstile), HUB_CHAIN_ID);

        bytes4[] memory warehouseSels = new bytes4[](1);
        warehouseSels[0] = SpokeWarehouse.setAssetWhitelisted.selector;

        bytes4[] memory turnstileAdminSels = new bytes4[](1);
        turnstileAdminSels[0] = Turnstile.setMessagingAdapter.selector;

        bytes4[] memory custodySels = new bytes4[](1);
        custodySels[0] = SpokeWarehouse.custody.selector;

        bytes4[] memory peerSels = new bytes4[](1);
        peerSels[0] = MessagingAdapter.setPeer.selector;

        bytes4[] memory receiveSels = new bytes4[](1);
        receiveSels[0] = Turnstile.receiveMessage.selector;

        vm.startPrank(admin);
        authority.setTargetFunctionRole(address(spokeWarehouse), warehouseSels, ADMIN_ROLE);
        authority.setTargetFunctionRole(address(warehouse), warehouseSels, ADMIN_ROLE);
        authority.setTargetFunctionRole(address(spokeTurnstile), turnstileAdminSels, ADMIN_ROLE);
        authority.setTargetFunctionRole(address(spokeWarehouse), custodySels, TURNSTILE_ROLE);
        authority.grantRole(TURNSTILE_ROLE, address(spokeTurnstile));
        authority.setTargetFunctionRole(address(spokeAdapter), peerSels, ADMIN_ROLE);
        authority.setTargetFunctionRole(address(hubAdapter), peerSels, ADMIN_ROLE);
        authority.setTargetFunctionRole(address(turnstile), receiveSels, MESSAGING_ADAPTER_ROLE);
        authority.grantRole(MESSAGING_ADAPTER_ROLE, address(hubAdapter));

        spokeTurnstile.setMessagingAdapter(address(spokeAdapter));
        spokeWarehouse.setAssetWhitelisted(_list(address(usdg)), true);
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
        SafeTransferLib.safeApprove(address(usdg), address(spokeWarehouse), 100e6);
        spokeTurnstile.deposit(address(usdg), 100e6, SPOKE_CHAIN_ID, alice, 200_000);
        vm.stopPrank();

        assertEq(usdg.balanceOf(vault), 100e6, "spoke deposit: vault did not receive usdg");
        bytes[] memory queued = spokeAdapter.pending();
        assertEq(queued.length, 1, "spoke deposit: no Transfer message queued to depot");

        vm.chainId(HUB_CHAIN_ID);
        hubAdapter.deliver(SPOKE_CHAIN_ID, bytes32(uint256(uint160(address(spokeAdapter)))), queued[0]);

        assertEq(
            depot.balanceOf(
                TransitTokenLib.formatAccountId(SPOKE_CHAIN_ID, alice),
                TransitTokenLib.formatAssetId(SPOKE_CHAIN_ID, address(usdg))
            ),
            100e6,
            "spoke deposit: depot did not credit alice"
        );
    }

    // ---------------------------------------------------------------- messages

    function testReceiveMessageFromNonAdapterReverts() public {
        ITurnstile.WithdrawalMessage memory m = ITurnstile.WithdrawalMessage({
            asset: address(usdc), amount: 1e6, to: alice, salt: bytes32(++withdrawSalt)
        });
        bytes memory payload = abi.encode(ITurnstile.MessageType.Withdrawal, abi.encode(m));

        vm.prank(mallory);
        vm.expectRevert();
        turnstile.receiveMessage(SPOKE_CHAIN_ID, payload);

        vm.prank(mallory);
        vm.expectRevert();
        warehouse.receiveWithdrawal(m.asset, m.amount, m.to);
    }

}
