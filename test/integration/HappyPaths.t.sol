// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { ERC20 } from "solady/tokens/ERC20.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { Terminal } from "../../src/Terminal.sol";
import { TransitTestBase } from "../TransitTestBase.t.sol";

contract HappyPaths is TransitTestBase {

    function testDepositSpokeAndWithdraw() public {
        // user deposits on a spoke chain and can withdraw on that spoke chain
    }

    function testDepositHubAndWithdraw() public {
        // default hub is ETH
        uint256 amount = 100e6;
        ERC20 usdc = chainConfig[hubID].usdc;

        _depositOnChain(alice, amount, usdc, hubID);

        _selectChain(hubID);

        ERC20 transit_eth_USDC = warehouse.getToken(hubID, usdc);
        assertEq(transit_eth_USDC.balanceOf(alice), amount, "deposit: alice not credited transit token");
        assertEq(usdc.balanceOf(warehouse.vault()), amount, "deposit: vault did not receive usdc");
        assertEq(usdc.balanceOf(alice), 0, "deposit: alice usdc not taken");

        _withdrawOnChain(alice, amount, usdc, hubID, true);

        assertEq(transit_eth_USDC.balanceOf(alice), 0, "withdraw: alice transit token not burned");
        assertEq(usdc.balanceOf(warehouse.vault()), 0, "withdraw: vault did not release usdc");
        assertEq(usdc.balanceOf(alice), amount, "withdraw: alice did not receive usdc back");
    }

    // Alice and Bob deposit and trade eth_USDC <> eth_UDSG 1:1 and withdraw.
    function testAliceBobHappyPathOneToOneSameChain() public {
        // default hub is ETH
        uint256 amount = 100e6;
        ERC20 usdc = chainConfig[hubID].usdc;
        ERC20 usdg = chainConfig[hubID].usdg;
        _depositOnChain(alice, amount, usdc, hubID);
        _depositOnChain(bob, amount, usdg, hubID);
        _selectChain(hubID);

        ERC20 transit_eth_USDC = warehouse.getToken(hubID, usdc);
        ERC20 transit_eth_USDG = warehouse.getToken(hubID, usdg);

        Terminal.SignedOrder memory aliceOrder =
            _signOrder(Terminal.Order(transit_eth_USDC, transit_eth_USDG, amount, amount, alice), alicePk);
        Terminal.SignedOrder memory bobOrder =
            _signOrder(Terminal.Order(transit_eth_USDG, transit_eth_USDC, amount, amount, bob), bobPk);

        Terminal.SignedOrder[] memory orders = new Terminal.SignedOrder[](2);
        orders[0] = aliceOrder;
        orders[1] = bobOrder;

        vm.prank(alice);
        SafeTransferLib.safeApprove(address(transit_eth_USDC), address(terminal), amount);
        vm.prank(bob);
        SafeTransferLib.safeApprove(address(transit_eth_USDG), address(terminal), amount);

        vm.startPrank(solver);
        terminal.settle(orders);
        vm.stopPrank();

        assertEq(transit_eth_USDG.balanceOf(alice), amount, "settle: alice did not receive usdg");
        assertEq(transit_eth_USDC.balanceOf(bob), amount, "settle: bob did not receive usdc");
        assertEq(transit_eth_USDC.balanceOf(alice), 0, "settle: alice usdc not taken");
        assertEq(transit_eth_USDG.balanceOf(bob), 0, "settle: bob usdg not taken");

        _withdrawOnChain(alice, amount, usdg, hubID, true);
        _withdrawOnChain(bob, amount, usdc, hubID, true);

        assertEq(transit_eth_USDG.balanceOf(alice), 0, "withdraw: alice transit usdg not burned");
        assertEq(transit_eth_USDC.balanceOf(bob), 0, "withdraw: bob transit usdc not burned");
        assertEq(usdg.balanceOf(alice), amount, "withdraw: alice did not receive usdg");
        assertEq(usdc.balanceOf(bob), amount, "withdraw: bob did not receive usdc");
    }

    // Alice and Bob deposit and trade eth_USDC <> robinhood_UDSG 1:1 and withdraw.
    function testAliceBobHappyPathOneToOneCrosschain() public { }

    // Alice and Bob deposit and trade eth_USDC <> robinhood_USDG at a price of 1.0005 (5bps) USDC per USDG
    // and withdraw
    function testAliceBobHappyPath5BpsPrice() public { }

    // Alice deposits and withdraws once. Making repeated trades with the same pool of capital. Bob deposits,
    // trades, and withdraws each time at various prices between 1 - 5 bps with the same pairs
    function testAliceBobHappyPathMarketMaking() public { }

}
