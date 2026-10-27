// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { ERC20 } from "solady/tokens/ERC20.sol";
import { Hub } from "../../src/Hub.sol";
import { SwapTerminal } from "../../src/SwapTerminal.sol";
import { TransitTestBase } from "../TransitTestBase.t.sol";
import { TransitTokenLib } from "../../src/helpers/TransitTokenLib.sol";

contract HappyPaths is TransitTestBase {

    function testDepositSpokeAndWithdraw() public {
        // user deposits on a spoke chain and can withdraw on that spoke chain
    }

    function testDepositHubAndWithdraw() public {
        // default hub is ETH
        uint256 amount = 100e6;
        ERC20 usdc = chainConfig[hubChainId].usdc;

        _depositOnChain(alice, amount, usdc, hubChainId);

        _selectChain(hubChainId);

        assertEq(_hubBalance(alice, hubChainId, usdc), amount, "deposit: alice not credited hub balance");
        assertEq(usdc.balanceOf(_vaultOf(hubChainId)), amount, "deposit: vault did not receive usdc");
        assertEq(usdc.balanceOf(alice), 0, "deposit: alice usdc not taken");

        _withdrawOnChain(alice, alicePk, amount, usdc, hubChainId, true);

        assertEq(_hubBalance(alice, hubChainId, usdc), 0, "withdraw: alice hub balance not burned");
        assertEq(usdc.balanceOf(_vaultOf(hubChainId)), 0, "withdraw: vault did not release usdc");
        assertEq(usdc.balanceOf(alice), amount, "withdraw: alice did not receive usdc back");
    }

    // Alice and Bob deposit and trade eth_USDC <> eth_UDSG 1:1 and withdraw.
    function testAliceBobHappyPathOneToOneSameChain() public {
        // default hub is ETH
        uint256 amount = 100e6;
        ERC20 usdc = chainConfig[hubChainId].usdc;
        ERC20 usdg = chainConfig[hubChainId].usdg;
        _depositOnChain(alice, amount, usdc, hubChainId);
        _depositOnChain(bob, amount, usdg, hubChainId);
        _selectChain(hubChainId);

        SwapTerminal.Order[] memory orders = new SwapTerminal.Order[](2);
        orders[0] = SwapTerminal.Order(
            hubChainId,
            alice,
            TransitTokenLib.formatAssetId(hubChainId, address(usdc)),
            TransitTokenLib.formatAssetId(hubChainId, address(usdg)),
            amount,
            amount,
            hubChainId,
            alice,
            block.timestamp,
            bytes32(uint256(1)),
            false
        );
        orders[1] = SwapTerminal.Order(
            hubChainId,
            bob,
            TransitTokenLib.formatAssetId(hubChainId, address(usdg)),
            TransitTokenLib.formatAssetId(hubChainId, address(usdc)),
            amount,
            amount,
            hubChainId,
            bob,
            block.timestamp,
            bytes32(uint256(2)),
            false
        );

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = _signOrder(orders[0], alicePk);
        signatures[1] = _signOrder(orders[1], bobPk);

        SwapTerminal.Fill[] memory fills = new SwapTerminal.Fill[](2);
        fills[0] = SwapTerminal.Fill(amount, amount);
        fills[1] = SwapTerminal.Fill(amount, amount);

        vm.startPrank(solver);
        swapTerminal.settle(hub.settlementEpoch(), orders, signatures, fills, new SwapTerminal.Fee[](0));
        vm.stopPrank();

        assertEq(_hubBalance(alice, hubChainId, usdg), amount, "settle: alice did not receive usdg");
        assertEq(_hubBalance(bob, hubChainId, usdc), amount, "settle: bob did not receive usdc");
        assertEq(_hubBalance(alice, hubChainId, usdc), 0, "settle: alice usdc not taken");
        assertEq(_hubBalance(bob, hubChainId, usdg), 0, "settle: bob usdg not taken");

        _withdrawOnChain(alice, alicePk, amount, usdg, hubChainId, true);
        _withdrawOnChain(bob, bobPk, amount, usdc, hubChainId, true);

        assertEq(_hubBalance(alice, hubChainId, usdg), 0, "withdraw: alice hub usdg not burned");
        assertEq(_hubBalance(bob, hubChainId, usdc), 0, "withdraw: bob hub usdc not burned");
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
