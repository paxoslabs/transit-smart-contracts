// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { ERC20 } from "solady/tokens/ERC20.sol";
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

        assertEq(_hubBalance(alice, hubID, usdc), amount, "deposit: alice not credited hub balance");
        assertEq(usdc.balanceOf(_vaultOf(hubID)), amount, "deposit: vault did not receive usdc");
        assertEq(usdc.balanceOf(alice), 0, "deposit: alice usdc not taken");

        _withdrawOnChain(alice, alicePk, amount, usdc, hubID, true);

        assertEq(_hubBalance(alice, hubID, usdc), 0, "withdraw: alice hub balance not burned");
        assertEq(usdc.balanceOf(_vaultOf(hubID)), 0, "withdraw: vault did not release usdc");
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

        Terminal.Fill memory aliceOrder = _signOrder(
            Terminal.Order(
                hubID, address(usdc), hubID, address(usdg), amount, amount, alice, block.timestamp, bytes32(uint256(1)), false
            ),
            alicePk
        );
        Terminal.Fill memory bobOrder = _signOrder(
            Terminal.Order(
                hubID, address(usdg), hubID, address(usdc), amount, amount, bob, block.timestamp, bytes32(uint256(2)), false
            ),
            bobPk
        );

        Terminal.Fill[] memory orders = new Terminal.Fill[](2);
        orders[0] = aliceOrder;
        orders[1] = bobOrder;

        vm.startPrank(solver);
        terminal.settle(hub.settlementEpoch(), orders);
        vm.stopPrank();

        assertEq(_hubBalance(alice, hubID, usdg), amount, "settle: alice did not receive usdg");
        assertEq(_hubBalance(bob, hubID, usdc), amount, "settle: bob did not receive usdc");
        assertEq(_hubBalance(alice, hubID, usdc), 0, "settle: alice usdc not taken");
        assertEq(_hubBalance(bob, hubID, usdg), 0, "settle: bob usdg not taken");

        _withdrawOnChain(alice, alicePk, amount, usdg, hubID, true);
        _withdrawOnChain(bob, bobPk, amount, usdc, hubID, true);

        assertEq(_hubBalance(alice, hubID, usdg), 0, "withdraw: alice hub usdg not burned");
        assertEq(_hubBalance(bob, hubID, usdc), 0, "withdraw: bob hub usdc not burned");
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
