// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { Test } from "forge-std/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { CCIPReceiver } from "@chainlink/contracts-ccip/applications/CCIPReceiver.sol";
import { IAny2EVMMessageReceiver } from "@chainlink/contracts-ccip/interfaces/IAny2EVMMessageReceiver.sol";
import { IAny2EVMMessageReceiverV2 } from "@chainlink/contracts-ccip/interfaces/IAny2EVMMessageReceiverV2.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Client } from "@chainlink/contracts-ccip/libraries/Client.sol";
import { ExtraArgsCodec } from "@chainlink/contracts-ccip/libraries/ExtraArgsCodec.sol";
import { FinalityCodec } from "@chainlink/contracts-ccip/libraries/FinalityCodec.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";
import { IMessagingAdapter } from "src/interfaces/IMessagingAdapter.sol";
import { MessagingAdapter } from "src/messaging/MessagingAdapter.sol";
import { CCIPMessagingAdapter } from "src/messaging/CCIPMessagingAdapter.sol";
import { Roles } from "src/helpers/Roles.sol";
import { MockCCIPRouter, MockMessagingReceiver } from "test/mocks/MessagingAdapterMocks.sol";

contract CCIPMessagingAdapterUnitTest is Test {

    uint64 constant HUB_CHAIN = 1;
    uint64 constant REMOTE_CHAIN = 10;
    uint64 constant REMOTE_SELECTOR = 5_009_297_550_715_157_269;
    uint64 constant GAS_LIMIT = 500_000;
    uint64 constant MIN_GAS = 100_000;

    address admin = makeAddr("admin");
    address stranger = makeAddr("stranger");
    address peerAddress = makeAddr("peer");
    bytes32 peer = bytes32(uint256(uint160(peerAddress)));

    AccessManager authority;
    MockMessagingReceiver turnstile;
    MockCCIPRouter router;
    CCIPMessagingAdapter adapter;

    bytes payload = abi.encode("payload");

    function setUp() public {
        authority = new AccessManager(admin);
        turnstile = new MockMessagingReceiver();
        router = new MockCCIPRouter();
        adapter = new CCIPMessagingAdapter(address(authority), address(turnstile), HUB_CHAIN, address(router));

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = MessagingAdapter.setPeer.selector;
        selectors[1] = CCIPMessagingAdapter.setRequestedFinality.selector;

        vm.startPrank(admin);
        authority.setTargetFunctionRole(address(adapter), selectors, Roles.ADMIN);
        adapter.setPeer(REMOTE_CHAIN, peer, REMOTE_SELECTOR, GAS_LIMIT, MIN_GAS, true, true);
        vm.stopPrank();

        vm.deal(address(turnstile), 1 ether);
    }

    function _send(uint64 gasLimit) internal returns (bytes32) {
        vm.prank(address(turnstile));
        return adapter.send{ value: 0.1 ether }(REMOTE_CHAIN, gasLimit, payload);
    }

    function _message(uint64 sourceChainSelector, address sender) internal view returns (Client.Any2EVMMessage memory) {
        return Client.Any2EVMMessage({
            messageId: keccak256("incoming"),
            sourceChainSelector: sourceChainSelector,
            sender: abi.encode(sender),
            data: payload,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
    }

    function _ccipReceive(Client.Any2EVMMessage memory message) internal {
        vm.prank(address(router));
        adapter.ccipReceive(message);
    }

    function _requestedFinality(bytes memory extraArgs) internal pure returns (bytes4 finality) {
        assembly {
            finality := and(mload(add(extraArgs, 40)), shl(224, 0xffffffff))
        }
    }

    function test_constructor_SetsRouter() public view {
        assertEq(adapter.getRouter(), address(router), "router not set");
    }

    function test_constructor_RevertIf_RouterIsZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(CCIPReceiver.InvalidRouter.selector, address(0)));
        new CCIPMessagingAdapter(address(authority), address(turnstile), HUB_CHAIN, address(0));
    }

    function test_setRequestedFinality_SetsRequestedFinality() public {
        vm.prank(admin);
        adapter.setRequestedFinality(REMOTE_CHAIN, FinalityCodec.WAIT_FOR_SAFE_FLAG);
        assertEq(
            adapter.requestedFinality(REMOTE_CHAIN), FinalityCodec.WAIT_FOR_SAFE_FLAG, "requested finality not stored"
        );
    }

    function test_setRequestedFinality_RevertIf_CallerIsUnauthorized() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vm.prank(stranger);
        adapter.setRequestedFinality(REMOTE_CHAIN, FinalityCodec.WAIT_FOR_SAFE_FLAG);
    }

    function test_send_CallsCcipSendWithRemoteIdAsDestinationChainSelector() public {
        _send(GAS_LIMIT);
        assertEq(router.lastDestinationChainSelector(), REMOTE_SELECTOR, "destination chain selector not remoteId");
    }

    function test_send_ForwardsMsgValueToRouter() public {
        _send(GAS_LIMIT);
        assertEq(router.lastValue(), 0.1 ether, "msg.value not forwarded");
        assertEq(address(router).balance, 0.1 ether, "router balance not increased");
    }

    function test_send_SetsPeerAsReceiver() public {
        _send(GAS_LIMIT);
        assertEq(router.lastReceiver(), abi.encode(peer), "receiver not abi-encoded peer");
    }

    function test_send_SetsPayloadAsData() public {
        _send(GAS_LIMIT);
        assertEq(router.lastData(), payload, "data not payload");
    }

    function test_send_SetsNoTokensAndNativeFeeToken() public {
        _send(GAS_LIMIT);
        assertEq(router.lastTokenAmountsLength(), 0, "token amounts not empty");
        assertEq(router.lastFeeToken(), address(0), "fee token not native");
    }

    function test_send_SetsExtraArgsV3WithFullFinality() public {
        _send(GAS_LIMIT);
        assertEq(
            router.lastExtraArgs(),
            ExtraArgsCodec._getBasicEncodedExtraArgsV3(uint32(GAS_LIMIT), FinalityCodec.WAIT_FOR_FINALITY_FLAG),
            "extraArgs not V3 with gas limit and full finality"
        );
    }

    function test_send_SetsExtraArgsV3WithRequestedFinality() public {
        vm.prank(admin);
        adapter.setRequestedFinality(REMOTE_CHAIN, FinalityCodec.WAIT_FOR_SAFE_FLAG);
        _send(GAS_LIMIT);
        assertEq(
            router.lastExtraArgs(),
            ExtraArgsCodec._getBasicEncodedExtraArgsV3(uint32(GAS_LIMIT), FinalityCodec.WAIT_FOR_SAFE_FLAG),
            "extraArgs not V3 with gas limit and requested finality"
        );
    }

    function test_send_ReturnsRouterMessageId() public {
        assertEq(_send(GAS_LIMIT), router.MESSAGE_ID(), "router message id not returned");
    }

    function test_send_RevertIf_GasLimitExceedsUint32Max() public {
        vm.prank(admin);
        adapter.setPeer(REMOTE_CHAIN, peer, REMOTE_SELECTOR, type(uint64).max, MIN_GAS, true, true);
        vm.expectRevert(SafeCastLib.Overflow.selector);
        _send(uint64(type(uint32).max) + 1);
    }

    function test_send_RevertIf_RemoteIdExceedsUint64Max() public {
        vm.prank(admin);
        adapter.setPeer(REMOTE_CHAIN, peer, uint256(type(uint64).max) + 1, GAS_LIMIT, MIN_GAS, true, true);
        vm.expectRevert(SafeCastLib.Overflow.selector);
        _send(GAS_LIMIT);
    }

    function test_send_BubblesUpRevertFromRouter() public {
        router.setShouldRevert(true);
        vm.expectRevert(MockCCIPRouter.Boom.selector);
        _send(GAS_LIMIT);
    }

    function test_quote_ReturnsRouterFeeForBuiltMessage() public {
        router.setFee(1 ether);
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(peer),
            data: payload,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: address(0),
            extraArgs: ExtraArgsCodec._getBasicEncodedExtraArgsV3(
                uint32(GAS_LIMIT), FinalityCodec.WAIT_FOR_FINALITY_FLAG
            )
        });
        assertEq(
            adapter.quote(REMOTE_CHAIN, GAS_LIMIT, payload),
            router.getFee(REMOTE_SELECTOR, message),
            "fee not router fee for built message"
        );
    }

    function test_quote_ReturnsRouterFeeForRequestedFinality() public {
        vm.prank(admin);
        adapter.setRequestedFinality(REMOTE_CHAIN, FinalityCodec.WAIT_FOR_SAFE_FLAG);
        router.setFee(1 ether);
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(peer),
            data: payload,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: address(0),
            extraArgs: ExtraArgsCodec._getBasicEncodedExtraArgsV3(uint32(GAS_LIMIT), FinalityCodec.WAIT_FOR_SAFE_FLAG)
        });
        assertEq(
            adapter.quote(REMOTE_CHAIN, GAS_LIMIT, payload),
            router.getFee(REMOTE_SELECTOR, message),
            "fee not router fee for message with requested finality"
        );
    }

    function test_quote_RevertIf_RemoteIdExceedsUint64Max() public {
        vm.prank(admin);
        adapter.setPeer(REMOTE_CHAIN, peer, uint256(type(uint64).max) + 1, GAS_LIMIT, MIN_GAS, true, true);
        vm.expectRevert(SafeCastLib.Overflow.selector);
        adapter.quote(REMOTE_CHAIN, GAS_LIMIT, payload);
    }

    function test_ccipReceive_DeliversDataToLocalTurnstile() public {
        _ccipReceive(_message(REMOTE_SELECTOR, peerAddress));
        assertEq(turnstile.callCount(), 1, "turnstile not called once");
        assertEq(turnstile.lastChainId(), REMOTE_CHAIN, "chain id not mapped from source chain selector");
        assertEq(turnstile.lastPayload(), payload, "data not delivered");
    }

    function test_ccipReceive_RevertIf_SenderIsNotRouter() public {
        vm.expectRevert(abi.encodeWithSelector(CCIPReceiver.InvalidRouter.selector, stranger));
        vm.prank(stranger);
        adapter.ccipReceive(_message(REMOTE_SELECTOR, peerAddress));
    }

    function test_ccipReceive_RevertIf_SourceChainSelectorIsNotMapped() public {
        vm.expectRevert(abi.encodeWithSelector(IMessagingAdapter.PeerNotSet.selector, 0));
        _ccipReceive(_message(1234, peerAddress));
    }

    function test_ccipReceive_RevertIf_MessageSenderIsNotPeer() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IMessagingAdapter.UnauthorizedPeer.selector, REMOTE_CHAIN, bytes32(uint256(uint160(stranger)))
            )
        );
        _ccipReceive(_message(REMOTE_SELECTOR, stranger));
    }

    function test_getCCVsAndFinalityConfig_AllowsFinalityRequestedBySend() public {
        _send(GAS_LIMIT);
        (,,, bytes4 allowedFinality) = adapter.getCCVsAndFinalityConfig(REMOTE_SELECTOR, abi.encode(peerAddress));
        bytes4 requestedFinality = _requestedFinality(router.lastExtraArgs());
        assertEq(
            requestedFinality, FinalityCodec.WAIT_FOR_FINALITY_FLAG, "requested finality not WAIT_FOR_FINALITY_FLAG"
        );
        assertTrue(
            requestedFinality == FinalityCodec.WAIT_FOR_FINALITY_FLAG
                || (requestedFinality & allowedFinality) == requestedFinality,
            "requested finality not allowed by receiver"
        );
    }

    function test_getCCVsAndFinalityConfig_AllowsSafeRequestedBySend() public {
        vm.prank(admin);
        adapter.setRequestedFinality(REMOTE_CHAIN, FinalityCodec.WAIT_FOR_SAFE_FLAG);
        _send(GAS_LIMIT);
        (,,, bytes4 allowedFinality) = adapter.getCCVsAndFinalityConfig(REMOTE_SELECTOR, abi.encode(peerAddress));
        bytes4 requestedFinality = _requestedFinality(router.lastExtraArgs());
        assertEq(requestedFinality, FinalityCodec.WAIT_FOR_SAFE_FLAG, "requested finality not WAIT_FOR_SAFE_FLAG");
        assertTrue(
            (requestedFinality & allowedFinality) == requestedFinality, "requested finality not allowed by receiver"
        );
    }

    function test_supportsInterface_ReturnsTrueForSupportedInterfaces() public view {
        assertTrue(
            adapter.supportsInterface(type(IAny2EVMMessageReceiver).interfaceId),
            "IAny2EVMMessageReceiver not supported"
        );
        assertTrue(
            adapter.supportsInterface(type(IAny2EVMMessageReceiverV2).interfaceId),
            "IAny2EVMMessageReceiverV2 not supported"
        );
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId), "IERC165 not supported");
    }

    function test_supportsInterface_ReturnsFalseForUnsupportedInterface() public view {
        assertFalse(adapter.supportsInterface(0xffffffff), "unsupported interface reported as supported");
    }

}
