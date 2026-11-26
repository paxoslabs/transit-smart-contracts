// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { Test } from "forge-std/Test.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IMessagingAdapter } from "src/interfaces/IMessagingAdapter.sol";
import { MessagingAdapter } from "src/messaging/MessagingAdapter.sol";
import { Roles } from "src/helpers/Roles.sol";
import { ETHRejecter, MessagingAdapterHarness, MockMessagingReceiver } from "test/mocks/MessagingAdapterMocks.sol";

contract MessagingAdapterUnitTest is Test {

    uint64 constant HUB_CHAIN = 1;
    uint64 constant REMOTE_CHAIN = 10;
    uint256 constant REMOTE_ID = 5_009_297_550_715_157_269;
    uint64 constant GAS_LIMIT = 500_000;
    uint64 constant MIN_GAS = 100_000;
    bytes32 constant PEER = bytes32(uint256(0xbeef));

    address admin = makeAddr("admin");
    address stranger = makeAddr("stranger");
    address recipient = makeAddr("recipient");

    AccessManager authority;
    MockMessagingReceiver turnstile;
    MessagingAdapterHarness adapter;

    bytes payload = abi.encode("payload");

    function setUp() public {
        authority = new AccessManager(admin);
        turnstile = new MockMessagingReceiver();
        adapter = new MessagingAdapterHarness(address(authority), address(turnstile), HUB_CHAIN);

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = MessagingAdapter.withdrawETH.selector;
        selectors[1] = MessagingAdapter.setPeer.selector;
        selectors[2] = MessagingAdapter.removePeer.selector;
        selectors[3] = MessagingAdapter.setAllowMessagesFromChain.selector;
        selectors[4] = MessagingAdapter.setAllowMessagesToChain.selector;
        selectors[5] = MessagingAdapter.setPeerGasLimit.selector;

        vm.prank(admin);
        authority.setTargetFunctionRole(address(adapter), selectors, Roles.ADMIN);

        _setPeer(REMOTE_CHAIN, PEER, REMOTE_ID, GAS_LIMIT, MIN_GAS, true, true);
        vm.deal(address(turnstile), 1 ether);
    }

    function _setPeer(
        uint64 chainId,
        bytes32 peer,
        uint256 remoteId,
        uint64 messageGasLimit,
        uint64 minimumMessageGas,
        bool allowMessagesFrom,
        bool allowMessagesTo
    )
        internal
    {
        vm.prank(admin);
        adapter.setPeer(chainId, peer, remoteId, messageGasLimit, minimumMessageGas, allowMessagesFrom, allowMessagesTo);
    }

    function _peer(uint64 chainId) internal view returns (IMessagingAdapter.PeerConfig memory p) {
        (p.peer, p.remoteId, p.messageGasLimit, p.minimumMessageGas, p.allowMessagesFrom, p.allowMessagesTo) =
            adapter.peers(chainId);
    }

    function _send(uint64 gasLimit) internal returns (bytes32) {
        vm.prank(address(turnstile));
        return adapter.send{ value: 0.1 ether }(REMOTE_CHAIN, gasLimit, payload);
    }

    function _unauthorized() internal view returns (bytes memory) {
        return abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger);
    }

    function test_constructor_SetsAuthority() public view {
        assertEq(adapter.authority(), address(authority), "authority not set");
    }

    function test_constructor_SetsLocalTurnstile() public view {
        assertEq(adapter.LOCAL_TURNSTILE(), address(turnstile), "LOCAL_TURNSTILE not set");
    }

    function test_constructor_SetsHubChainId() public view {
        assertEq(adapter.HUB_CHAIN_ID(), HUB_CHAIN, "HUB_CHAIN_ID not set");
    }

    function test_receive_AcceptsETH() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool success,) = address(adapter).call{ value: 1 ether }("");
        assertTrue(success, "ETH transfer failed");
        assertEq(address(adapter).balance, 1 ether, "adapter balance not increased");
    }

    function test_withdrawETH_TransfersEntireBalance() public {
        vm.deal(address(adapter), 1 ether);
        vm.prank(admin);
        adapter.withdrawETH(recipient);
        assertEq(recipient.balance, 1 ether, "recipient balance not increased");
        assertEq(address(adapter).balance, 0, "adapter balance not zero");
    }

    function test_withdrawETH_EmitsETHWithdrawnEvent() public {
        vm.deal(address(adapter), 1 ether);
        vm.expectEmit(address(adapter));
        emit IMessagingAdapter.ETHWithdrawn(recipient, 1 ether);
        vm.prank(admin);
        adapter.withdrawETH(recipient);
    }

    function test_withdrawETH_RevertIf_SenderIsUnauthorized() public {
        vm.expectRevert(_unauthorized());
        vm.prank(stranger);
        adapter.withdrawETH(stranger);
    }

    function test_withdrawETH_RevertIf_TransferFails() public {
        vm.deal(address(adapter), 1 ether);
        address rejecter = address(new ETHRejecter());
        vm.expectRevert(SafeTransferLib.ETHTransferFailed.selector);
        vm.prank(admin);
        adapter.withdrawETH(rejecter);
    }

    function test_setPeer_SetsPeerConfig() public {
        _setPeer(20, bytes32(uint256(0xcafe)), 77, 300_000, 50_000, true, false);
        IMessagingAdapter.PeerConfig memory p = _peer(20);
        assertEq(p.peer, bytes32(uint256(0xcafe)), "peer not set");
        assertEq(p.remoteId, 77, "remoteId not set");
        assertEq(p.messageGasLimit, 300_000, "messageGasLimit not set");
        assertEq(p.minimumMessageGas, 50_000, "minimumMessageGas not set");
        assertTrue(p.allowMessagesFrom, "allowMessagesFrom not set");
        assertFalse(p.allowMessagesTo, "allowMessagesTo not set");
    }

    function test_setPeer_MapsRemoteIdToChainId() public {
        _setPeer(20, bytes32(uint256(0xcafe)), 77, 300_000, 50_000, true, true);
        assertEq(adapter.chainIdForRemoteId(77), 20, "remoteId not mapped to chain id");
    }

    function test_setPeer_EmitsPeerSetEvent() public {
        vm.expectEmit(address(adapter));
        emit IMessagingAdapter.PeerSet(20, PEER, 77, 300_000, 50_000, true, false);
        _setPeer(20, PEER, 77, 300_000, 50_000, true, false);
    }

    function test_setPeer_EmitsPeerGasLimitSetEvent() public {
        vm.expectEmit(address(adapter));
        emit IMessagingAdapter.PeerGasLimitSet(20, 300_000);
        _setPeer(20, PEER, 77, 300_000, 50_000, true, false);
    }

    function test_setPeer_EmitsAllowMessagesFromChainSetEvent() public {
        vm.expectEmit(address(adapter));
        emit IMessagingAdapter.AllowMessagesFromChainSet(20, true);
        _setPeer(20, PEER, 77, 300_000, 50_000, true, false);
    }

    function test_setPeer_EmitsAllowMessagesToChainSetEvent() public {
        vm.expectEmit(address(adapter));
        emit IMessagingAdapter.AllowMessagesToChainSet(20, false);
        _setPeer(20, PEER, 77, 300_000, 50_000, true, false);
    }

    function test_setPeer_RevertIf_SenderIsUnauthorized() public {
        vm.expectRevert(_unauthorized());
        vm.prank(stranger);
        adapter.setPeer(20, PEER, 77, 300_000, 50_000, true, true);
    }

    function test_setPeer_RevertIf_MessageGasLimitIsZero() public {
        vm.expectRevert(IMessagingAdapter.ZeroMessageGasLimit.selector);
        _setPeer(20, PEER, 77, 0, 0, true, true);
    }

    function test_removePeer_DeletesPeerConfig() public {
        vm.prank(admin);
        adapter.removePeer(REMOTE_CHAIN);
        IMessagingAdapter.PeerConfig memory p = _peer(REMOTE_CHAIN);
        assertEq(p.peer, bytes32(0), "peer not deleted");
        assertEq(p.remoteId, 0, "remoteId not deleted");
        assertEq(p.messageGasLimit, 0, "messageGasLimit not deleted");
        assertEq(p.minimumMessageGas, 0, "minimumMessageGas not deleted");
        assertFalse(p.allowMessagesFrom, "allowMessagesFrom not deleted");
        assertFalse(p.allowMessagesTo, "allowMessagesTo not deleted");
    }

    function test_removePeer_DeletesRemoteIdMapping() public {
        vm.prank(admin);
        adapter.removePeer(REMOTE_CHAIN);
        assertEq(adapter.chainIdForRemoteId(REMOTE_ID), 0, "remoteId mapping not deleted");
    }

    function test_removePeer_EmitsPeerRemovedEvent() public {
        vm.expectEmit(address(adapter));
        emit IMessagingAdapter.PeerRemoved(REMOTE_CHAIN);
        vm.prank(admin);
        adapter.removePeer(REMOTE_CHAIN);
    }

    function test_removePeer_RevertIf_SenderIsUnauthorized() public {
        vm.expectRevert(_unauthorized());
        vm.prank(stranger);
        adapter.removePeer(REMOTE_CHAIN);
    }

    function test_setAllowMessagesFromChain_SetsAllowMessagesFrom() public {
        vm.prank(admin);
        adapter.setAllowMessagesFromChain(REMOTE_CHAIN, false);
        assertFalse(_peer(REMOTE_CHAIN).allowMessagesFrom, "allowMessagesFrom not set");
    }

    function test_setAllowMessagesFromChain_EmitsAllowMessagesFromChainSetEvent() public {
        vm.expectEmit(address(adapter));
        emit IMessagingAdapter.AllowMessagesFromChainSet(REMOTE_CHAIN, false);
        vm.prank(admin);
        adapter.setAllowMessagesFromChain(REMOTE_CHAIN, false);
    }

    function test_setAllowMessagesFromChain_RevertIf_SenderIsUnauthorized() public {
        vm.expectRevert(_unauthorized());
        vm.prank(stranger);
        adapter.setAllowMessagesFromChain(REMOTE_CHAIN, false);
    }

    function test_setAllowMessagesToChain_SetsAllowMessagesTo() public {
        vm.prank(admin);
        adapter.setAllowMessagesToChain(REMOTE_CHAIN, false);
        assertFalse(_peer(REMOTE_CHAIN).allowMessagesTo, "allowMessagesTo not set");
    }

    function test_setAllowMessagesToChain_EmitsAllowMessagesToChainSetEvent() public {
        vm.expectEmit(address(adapter));
        emit IMessagingAdapter.AllowMessagesToChainSet(REMOTE_CHAIN, false);
        vm.prank(admin);
        adapter.setAllowMessagesToChain(REMOTE_CHAIN, false);
    }

    function test_setAllowMessagesToChain_RevertIf_SenderIsUnauthorized() public {
        vm.expectRevert(_unauthorized());
        vm.prank(stranger);
        adapter.setAllowMessagesToChain(REMOTE_CHAIN, false);
    }

    function test_setPeerGasLimit_SetsMessageGasLimit() public {
        vm.prank(admin);
        adapter.setPeerGasLimit(REMOTE_CHAIN, 900_000);
        assertEq(_peer(REMOTE_CHAIN).messageGasLimit, 900_000, "messageGasLimit not set");
    }

    function test_setPeerGasLimit_EmitsPeerGasLimitSetEvent() public {
        vm.expectEmit(address(adapter));
        emit IMessagingAdapter.PeerGasLimitSet(REMOTE_CHAIN, 900_000);
        vm.prank(admin);
        adapter.setPeerGasLimit(REMOTE_CHAIN, 900_000);
    }

    function test_setPeerGasLimit_RevertIf_SenderIsUnauthorized() public {
        vm.expectRevert(_unauthorized());
        vm.prank(stranger);
        adapter.setPeerGasLimit(REMOTE_CHAIN, 900_000);
    }

    function test_setPeerGasLimit_RevertIf_MessageGasLimitIsZero() public {
        vm.expectRevert(IMessagingAdapter.ZeroMessageGasLimit.selector);
        vm.prank(admin);
        adapter.setPeerGasLimit(REMOTE_CHAIN, 0);
    }

    function test_send_SendsPayloadToPeer() public {
        _send(GAS_LIMIT - 1);
        assertEq(adapter.sendCount(), 1, "bridge send not called once");
        assertEq(adapter.lastChainId(), REMOTE_CHAIN, "chain id not forwarded");
        assertEq(adapter.lastGasLimit(), GAS_LIMIT - 1, "gas limit not forwarded");
        assertEq(adapter.lastPeer(), PEER, "peer not forwarded");
        assertEq(adapter.lastPayload(), payload, "payload not forwarded");
        assertEq(adapter.lastValue(), 0.1 ether, "msg.value not forwarded");
    }

    function test_send_ReturnsMessageId() public {
        assertEq(_send(GAS_LIMIT), keccak256(abi.encode(uint256(1))), "message id not returned");
    }

    function test_send_EmitsMessageSentEvent() public {
        vm.expectEmit(address(adapter));
        emit IMessagingAdapter.MessageSent(REMOTE_CHAIN, keccak256(abi.encode(uint256(1))), payload);
        _send(GAS_LIMIT);
    }

    function test_send_AcceptsGasLimitEqualToMessageGasLimit() public {
        _send(GAS_LIMIT);
        assertEq(adapter.lastGasLimit(), GAS_LIMIT, "gas limit at messageGasLimit not sent");
    }

    function test_send_AcceptsGasLimitEqualToMinimumMessageGas() public {
        _send(MIN_GAS);
        assertEq(adapter.lastGasLimit(), MIN_GAS, "gas limit at minimumMessageGas not sent");
    }

    function test_send_RevertIf_SenderIsNotLocalTurnstile() public {
        vm.expectRevert(IMessagingAdapter.OnlyLocalTurnstile.selector);
        vm.prank(stranger);
        adapter.send(REMOTE_CHAIN, GAS_LIMIT, payload);
    }

    function test_send_RevertIf_PeerIsNotSet() public {
        vm.expectRevert(abi.encodeWithSelector(IMessagingAdapter.PeerNotSet.selector, 20));
        vm.prank(address(turnstile));
        adapter.send(20, GAS_LIMIT, payload);
    }

    function test_send_RevertIf_MessagesToChainAreNotAllowed() public {
        vm.prank(admin);
        adapter.setAllowMessagesToChain(REMOTE_CHAIN, false);
        vm.expectRevert(abi.encodeWithSelector(IMessagingAdapter.MessagesNotAllowedTo.selector, REMOTE_CHAIN));
        _send(GAS_LIMIT);
    }

    function test_send_RevertIf_GasLimitExceedsMessageGasLimit() public {
        vm.expectRevert(IMessagingAdapter.GasLimitExceeded.selector);
        _send(GAS_LIMIT + 1);
    }

    function test_send_RevertIf_GasLimitIsBelowMinimumMessageGas() public {
        vm.expectRevert(IMessagingAdapter.GasTooLow.selector);
        _send(MIN_GAS - 1);
    }

    function test_quote_ReturnsBridgeFee() public view {
        assertEq(
            adapter.quote(REMOTE_CHAIN, GAS_LIMIT, payload),
            uint256(keccak256(abi.encode(REMOTE_CHAIN, GAS_LIMIT, PEER, payload))) >> 128,
            "bridge fee not returned"
        );
    }

    function test_quote_RevertIf_PeerIsNotSet() public {
        vm.expectRevert(abi.encodeWithSelector(IMessagingAdapter.PeerNotSet.selector, 20));
        adapter.quote(20, GAS_LIMIT, payload);
    }

    function test_quote_RevertIf_MessagesToChainAreNotAllowed() public {
        vm.prank(admin);
        adapter.setAllowMessagesToChain(REMOTE_CHAIN, false);
        vm.expectRevert(abi.encodeWithSelector(IMessagingAdapter.MessagesNotAllowedTo.selector, REMOTE_CHAIN));
        adapter.quote(REMOTE_CHAIN, GAS_LIMIT, payload);
    }

    function test_quote_RevertIf_GasLimitExceedsMessageGasLimit() public {
        vm.expectRevert(IMessagingAdapter.GasLimitExceeded.selector);
        adapter.quote(REMOTE_CHAIN, GAS_LIMIT + 1, payload);
    }

    function test_quote_RevertIf_GasLimitIsBelowMinimumMessageGas() public {
        vm.expectRevert(IMessagingAdapter.GasTooLow.selector);
        adapter.quote(REMOTE_CHAIN, MIN_GAS - 1, payload);
    }

    function test__receive_DeliversPayloadToLocalTurnstile() public {
        adapter.$_receive(REMOTE_CHAIN, PEER, payload);
        assertEq(turnstile.callCount(), 1, "turnstile not called once");
        assertEq(turnstile.lastChainId(), REMOTE_CHAIN, "source chain id not delivered");
        assertEq(turnstile.lastPayload(), payload, "payload not delivered");
    }

    function test__receive_EmitsMessageReceivedEvent() public {
        vm.expectEmit(address(adapter));
        emit IMessagingAdapter.MessageReceived(REMOTE_CHAIN, PEER, payload);
        adapter.$_receive(REMOTE_CHAIN, PEER, payload);
    }

    function test__receive_RevertIf_PeerIsNotSet() public {
        vm.expectRevert(abi.encodeWithSelector(IMessagingAdapter.PeerNotSet.selector, 20));
        adapter.$_receive(20, PEER, payload);
    }

    function test__receive_RevertIf_SenderIsNotPeer() public {
        bytes32 impostor = bytes32(uint256(0xbad));
        vm.expectRevert(abi.encodeWithSelector(IMessagingAdapter.UnauthorizedPeer.selector, REMOTE_CHAIN, impostor));
        adapter.$_receive(REMOTE_CHAIN, impostor, payload);
    }

    function test__receive_RevertIf_MessagesFromChainAreNotAllowed() public {
        vm.prank(admin);
        adapter.setAllowMessagesFromChain(REMOTE_CHAIN, false);
        vm.expectRevert(abi.encodeWithSelector(IMessagingAdapter.MessagesNotAllowedFrom.selector, REMOTE_CHAIN));
        adapter.$_receive(REMOTE_CHAIN, PEER, payload);
    }

    function test__receive_BubblesUpRevertFromLocalTurnstile() public {
        turnstile.setShouldRevert(true);
        vm.expectRevert(MockMessagingReceiver.Boom.selector);
        adapter.$_receive(REMOTE_CHAIN, PEER, payload);
    }

}
