// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { Test } from "forge-std/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IRouterClient } from "@chainlink/contracts-ccip/interfaces/IRouterClient.sol";
import { CCIPMessagingAdapter } from "src/messaging/CCIPMessagingAdapter.sol";

contract CCIPFinalityTest is Test {

    address constant ETH_CCIP_ROUTER = 0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D;
    uint64 constant ARBITRUM_SELECTOR = 4_949_039_107_694_359_620;
    uint64 constant ARBITRUM_CHAIN_ID = 42_161;
    uint64 constant MESSAGE_GAS = 200_000;

    function testForkLiveRouterAcceptsAdapterMessage() public {
        string memory rpc = vm.envOr("ETH_RPC", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);
        assertTrue(IRouterClient(ETH_CCIP_ROUTER).isChainSupported(ARBITRUM_SELECTOR), "router supports arbitrum");

        AccessManager accessManager = new AccessManager(address(this));
        CCIPMessagingAdapter adapter =
            new CCIPMessagingAdapter(address(accessManager), address(this), 1, ETH_CCIP_ROUTER);
        adapter.setPeer(
            ARBITRUM_CHAIN_ID, bytes32(uint256(uint160(makeAddr("peer")))), ARBITRUM_SELECTOR, 1_000_000, 0, true, true
        );
        bytes memory payload = abi.encode(uint8(0), bytes(""));

        uint256 fee = adapter.quote(ARBITRUM_CHAIN_ID, MESSAGE_GAS, payload);
        vm.deal(address(this), fee);
        bytes32 messageId = adapter.send{ value: fee }(ARBITRUM_CHAIN_ID, MESSAGE_GAS, payload);

        assertTrue(messageId != bytes32(0), "live router accepts the adapter message");
    }

}
