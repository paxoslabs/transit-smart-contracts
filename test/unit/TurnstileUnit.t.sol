// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { Turnstile } from "src/turnstile/Turnstile.sol";
import { FACILITATED_FLAG } from "src/conductor/ConductorGatedByTurnstile.sol";
import { ITurnstile } from "src/interfaces/ITurnstile.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { Roles } from "src/helpers/Roles.sol";
import { TransitAddressLib } from "src/helpers/TransitAddressLib.sol";
import {
    MockERC20,
    MockGasBurningERC20,
    MockMessagingAdapter,
    MockHubWarehouseConductor,
    MockTarget
} from "test/mocks/TurnstileMocks.sol";

contract TurnstileUnitTest is Test {

    uint256 constant USER_PK = 0xA11CE;
    uint256 constant USER2_PK = 0xB0B;
    uint64 constant REMOTE_CHAIN = 1;

    address user = vm.addr(USER_PK);
    address user2 = vm.addr(USER2_PK);
    address admin = makeAddr("admin");
    address pauser = makeAddr("pauser");
    address facilitator = makeAddr("facilitator");
    address stranger = makeAddr("stranger");
    address vault = makeAddr("vault");
    address recipient = makeAddr("recipient");

    AccessManager authority;
    MockMessagingAdapter adapter;
    MockHubWarehouseConductor conductor;
    MockERC20 token;
    MockTarget target;
    Turnstile turnstile;

    function setUp() public {
        authority = new AccessManager(admin);
        adapter = new MockMessagingAdapter(uint64(block.chainid));
        conductor = new MockHubWarehouseConductor();
        token = new MockERC20();
        target = new MockTarget();
        turnstile = _deployTurnstile();

        vm.startPrank(admin);
        turnstile.setHubWarehouseConductor(address(conductor));
        turnstile.setAssetWhitelisted(_addresses(address(token)), true);
        turnstile.setRoutable(address(target), _selectors(MockTarget.ping.selector), true);
        vm.stopPrank();

        token.mint(user, 1000);
        token.mint(vault, 1000);
        vm.prank(user);
        token.approve(address(turnstile), type(uint256).max);
        vm.prank(vault);
        token.approve(address(turnstile), type(uint256).max);
        vm.deal(user, 1 ether);
        vm.deal(facilitator, 1 ether);
    }

    function _deployTurnstile() internal returns (Turnstile t) {
        t = new Turnstile(address(authority), vault);

        bytes4[] memory adminSelectors = new bytes4[](5);
        adminSelectors[0] = Turnstile.setMessagingAdapter.selector;
        adminSelectors[1] = Turnstile.setHubWarehouseConductor.selector;
        adminSelectors[2] = Turnstile.setRoutable.selector;
        adminSelectors[3] = Turnstile.setAssetWhitelisted.selector;
        adminSelectors[4] = Turnstile.retry.selector;

        bytes4[] memory pauserSelectors = new bytes4[](2);
        pauserSelectors[0] = Turnstile.pause.selector;
        pauserSelectors[1] = Turnstile.unpause.selector;

        vm.startPrank(admin);
        authority.setTargetFunctionRole(address(t), adminSelectors, Roles.ADMIN);
        authority.setTargetFunctionRole(address(t), pauserSelectors, Roles.PAUSER);
        authority.setTargetFunctionRole(
            address(t), _selectors(Turnstile.handleReceivedMessage.selector), Roles.MESSAGING_ADAPTER
        );
        authority.setTargetFunctionRole(address(t), _selectors(Turnstile.facilitate.selector), Roles.SOLVER);
        authority.grantRole(Roles.PAUSER, pauser, 0);
        authority.grantRole(Roles.MESSAGING_ADAPTER, address(adapter), 0);
        authority.grantRole(Roles.SOLVER, facilitator, 0);
        t.setMessagingAdapter(address(adapter));
        vm.stopPrank();
    }

    function _addresses(address a) internal pure returns (address[] memory addresses) {
        addresses = new address[](1);
        addresses[0] = a;
    }

    function _selectors(bytes4 a) internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = a;
    }

    function _accountId(address account) internal view returns (bytes28) {
        return TransitAddressLib.formatTransitAddress(uint64(block.chainid), account);
    }

    function _suffix(bytes28 accountId, bool facilitated) internal pure returns (bytes memory) {
        return abi.encodePacked(accountId, facilitated ? FACILITATED_FLAG : bytes4(0));
    }

    function _lastBytes32(bytes memory data) internal pure returns (bytes32 result) {
        assembly {
            result := mload(add(data, mload(data)))
        }
    }

    function _status(bytes32 messageHash) internal view returns (uint8) {
        return uint8(turnstile.messageStatus(messageHash));
    }

    function _depositAction(uint256 amount) internal view returns (ITurnstile.DepositAction memory a) {
        a.ownerChainId = uint64(block.chainid);
        a.owner = user;
        a.asset = address(token);
        a.amount = amount;
        a.toChainId = uint64(block.chainid);
        a.to = user;
        a.deadline = block.timestamp + 1 hours;
        a.salt = bytes32(uint256(1));
    }

    function _withdrawalAction(uint64 assetChainId) internal view returns (ITurnstile.WithdrawalAction memory a) {
        a.ownerChainId = uint64(block.chainid);
        a.owner = user;
        a.to = recipient;
        a.assetChainId = assetChainId;
        a.asset = address(token);
        a.amount = 50;
        a.deadline = block.timestamp + 1 hours;
        a.partiallyFillable = true;
        a.salt = bytes32(uint256(2));
    }

    function _genericAction() internal view returns (ITurnstile.GenericAction memory a) {
        a.ownerChainId = uint64(block.chainid);
        a.owner = user;
        a.target = address(target);
        a.data = abi.encodeCall(MockTarget.ping, (42));
        a.deadline = block.timestamp + 1 hours;
        a.salt = bytes32(uint256(3));
    }

    function _depositBody(ITurnstile.DepositAction memory a, address from) internal view returns (bytes memory) {
        return abi.encode(
            ITurnstile.DepositMessage({
                asset: a.asset,
                amount: a.amount,
                fromAccountId: _accountId(from),
                toAccountId: TransitAddressLib.formatTransitAddress(a.toChainId, a.to),
                facilitationFee: a.facilitationFee,
                feeReceiverAccountId: TransitAddressLib.formatTransitAddress(a.feeReceiverChainId, a.feeReceiver),
                salt: a.salt
            })
        );
    }

    function _withdrawalBody(ITurnstile.WithdrawalAction memory a, uint256 amount)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(
            ITurnstile.WithdrawalMessage({
                asset: a.asset, amount: amount, to: a.to, salt: turnstile.hashWithdrawalAction(a)
            })
        );
    }

    function _genericBody(ITurnstile.GenericAction memory a, address sender) internal pure returns (bytes memory) {
        return abi.encode(
            ITurnstile.GenericMessage({
                sender: sender, target: a.target, data: a.data, deadline: a.deadline, salt: a.salt
            })
        );
    }

    function _withdrawalMessageBody(uint256 amount) internal view returns (bytes memory) {
        return abi.encode(
            ITurnstile.WithdrawalMessage({
                asset: address(token), amount: amount, to: recipient, salt: bytes32(uint256(4))
            })
        );
    }

    function _action(
        ITurnstile.ActionType actionType,
        bytes memory data,
        uint256 bridgeFee,
        uint64 messageGas
    )
        internal
        pure
        returns (ITurnstile.Action memory)
    {
        return ITurnstile.Action({ actionType: actionType, data: data, bridgeFee: bridgeFee, messageGas: messageGas });
    }

    function _depositAction(ITurnstile.DepositAction memory a) internal pure returns (ITurnstile.Action memory) {
        return _action(ITurnstile.ActionType.Deposit, abi.encode(a), 0, 0);
    }

    function _withdrawalAction(ITurnstile.WithdrawalAction memory a) internal pure returns (ITurnstile.Action memory) {
        return _action(ITurnstile.ActionType.Withdrawal, abi.encode(a), 0, 0);
    }

    function _genericAction(ITurnstile.GenericAction memory a) internal pure returns (ITurnstile.Action memory) {
        return _action(ITurnstile.ActionType.Generic, abi.encode(a), 0, 0);
    }

    function _actions(ITurnstile.Action memory a) internal pure returns (ITurnstile.Action[] memory actions) {
        actions = new ITurnstile.Action[](1);
        actions[0] = a;
    }

    function _actions(
        ITurnstile.Action memory a,
        ITurnstile.Action memory b
    )
        internal
        pure
        returns (ITurnstile.Action[] memory actions)
    {
        actions = new ITurnstile.Action[](2);
        actions[0] = a;
        actions[1] = b;
    }

    function _dispatch(ITurnstile.Action[] memory actions, uint256 value) internal returns (bytes32[] memory) {
        vm.prank(user);
        return turnstile.dispatch{ value: value }(actions);
    }

    function _facilitate(ITurnstile.Action[] memory actions, bytes[] memory signatures) internal {
        vm.prank(facilitator);
        turnstile.facilitate(actions, signatures);
    }

    function _receive(ITurnstile.ActionType actionType, bytes memory body) internal {
        vm.prank(address(adapter));
        turnstile.handleReceivedMessage(REMOTE_CHAIN, abi.encode(actionType, body));
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signatures(bytes memory a) internal pure returns (bytes[] memory signatures) {
        signatures = new bytes[](1);
        signatures[0] = a;
    }

    function _signatures(bytes memory a, bytes memory b) internal pure returns (bytes[] memory signatures) {
        signatures = new bytes[](2);
        signatures[0] = a;
        signatures[1] = b;
    }

    function _failGenericMessage() internal returns (bytes memory body) {
        body = _genericBody(_genericAction(), user);
        target.setShouldRevert(true);
        _receive(ITurnstile.ActionType.Generic, body);
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Transit Turnstile"),
                keccak256("1"),
                block.chainid,
                address(turnstile)
            )
        );
    }

    function _permitSignature(uint256 amount, uint256 deadline)
        internal
        view
        returns (ITurnstile.Permit memory permit)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                user,
                address(turnstile),
                amount,
                token.nonces(user),
                deadline
            )
        );
        (permit.v, permit.r, permit.s) =
            vm.sign(USER_PK, keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash)));
        permit.deadline = deadline;
    }

    function test_constructor_SetsAuthority() public view {
        assertEq(turnstile.authority(), address(authority), "authority not set");
    }

    function test_constructor_SetsVault() public view {
        assertEq(turnstile.VAULT(), vault, "VAULT not set");
    }

    function test_constructor_RevertIf_VaultIsZeroAddress() public {
        vm.expectRevert(ITurnstile.VaultUnset.selector);
        new Turnstile(address(authority), address(0));
    }

    function test_messagingAdapter_ReturnsMessagingAdapter() public view {
        assertEq(turnstile.messagingAdapter(), address(adapter), "messagingAdapter not returned");
    }

    function test_hubWarehouseConductor_ReturnsHubWarehouseConductor() public view {
        assertEq(turnstile.hubWarehouseConductor(), address(conductor), "hubWarehouseConductor not returned");
    }

    function test_messageStatus_ReturnsNoneForUnknownMessage() public view {
        assertEq(_status(keccak256("unknown")), uint8(ITurnstile.MessageStatus.None), "status not None");
    }

    function test_messageStatus_ReturnsStatusOfMessage() public {
        bytes32[] memory hashes = _dispatch(_actions(_depositAction(_depositAction(100))), 0);
        assertEq(_status(hashes[0]), uint8(ITurnstile.MessageStatus.Executed), "status not Executed");
    }

    function test_genericMessageWhitelist_ReturnsWhetherSelectorIsWhitelisted() public view {
        assertTrue(
            turnstile.genericMessageWhitelist(address(target), MockTarget.ping.selector), "whitelisted selector false"
        );
        assertFalse(
            turnstile.genericMessageWhitelist(address(target), MockTarget.spin.selector), "unlisted selector true"
        );
    }

    function test_assetWhitelisted_ReturnsWhetherAssetIsWhitelisted() public {
        assertTrue(turnstile.assetWhitelisted(address(token)), "whitelisted asset false");
        assertFalse(turnstile.assetWhitelisted(makeAddr("unlisted")), "unlisted asset true");
    }

    function test_setMessagingAdapter_SetsMessagingAdapter() public {
        MockMessagingAdapter newAdapter = new MockMessagingAdapter(uint64(block.chainid));
        vm.prank(admin);
        turnstile.setMessagingAdapter(address(newAdapter));
        assertEq(turnstile.messagingAdapter(), address(newAdapter), "messagingAdapter not set");
    }

    function test_setMessagingAdapter_EmitsMessagingAdapterUpdatedEvent() public {
        MockMessagingAdapter newAdapter = new MockMessagingAdapter(uint64(block.chainid));
        vm.expectEmit(address(turnstile));
        emit ITurnstile.MessagingAdapterUpdated(address(newAdapter));
        vm.prank(admin);
        turnstile.setMessagingAdapter(address(newAdapter));
    }

    function test_setMessagingAdapter_RevertIf_SenderIsUnauthorized() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vm.prank(stranger);
        turnstile.setMessagingAdapter(address(adapter));
    }

    function test_setMessagingAdapter_RevertIf_AddressHasNoCode() public {
        vm.expectRevert(ITurnstile.NoCode.selector);
        vm.prank(admin);
        turnstile.setMessagingAdapter(makeAddr("noCode"));
    }

    function test_setHubWarehouseConductor_SetsHubWarehouseConductor() public {
        MockHubWarehouseConductor newConductor = new MockHubWarehouseConductor();
        vm.prank(admin);
        turnstile.setHubWarehouseConductor(address(newConductor));
        assertEq(turnstile.hubWarehouseConductor(), address(newConductor), "hubWarehouseConductor not set");
    }

    function test_setHubWarehouseConductor_EmitsHubWarehouseConductorUpdatedEvent() public {
        MockHubWarehouseConductor newConductor = new MockHubWarehouseConductor();
        vm.expectEmit(address(turnstile));
        emit ITurnstile.HubWarehouseConductorUpdated(address(newConductor));
        vm.prank(admin);
        turnstile.setHubWarehouseConductor(address(newConductor));
    }

    function test_setHubWarehouseConductor_RevertIf_SenderIsUnauthorized() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vm.prank(stranger);
        turnstile.setHubWarehouseConductor(address(conductor));
    }

    function test_setHubWarehouseConductor_RevertIf_AddressHasNoCode() public {
        vm.expectRevert(ITurnstile.NoCode.selector);
        vm.prank(admin);
        turnstile.setHubWarehouseConductor(makeAddr("noCode"));
    }

    function test_setHubWarehouseConductor_RevertIf_ChainIsNotHubChain() public {
        adapter.setHubChainId(REMOTE_CHAIN);
        vm.expectRevert(ITurnstile.NotHubChain.selector);
        vm.prank(admin);
        turnstile.setHubWarehouseConductor(address(conductor));
    }

    function test_setRoutable_SetsWhitelistStatusOfEachSelector() public {
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = bytes4(keccak256("a()"));
        selectors[1] = bytes4(keccak256("b()"));
        vm.prank(admin);
        turnstile.setRoutable(address(target), selectors, true);
        assertTrue(turnstile.genericMessageWhitelist(address(target), selectors[0]), "first selector not whitelisted");
        assertTrue(turnstile.genericMessageWhitelist(address(target), selectors[1]), "second selector not whitelisted");
    }

    function test_setRoutable_RemovesSelectorsFromWhitelistWhenAllowedIsFalse() public {
        vm.prank(admin);
        turnstile.setRoutable(address(target), _selectors(MockTarget.ping.selector), false);
        assertFalse(
            turnstile.genericMessageWhitelist(address(target), MockTarget.ping.selector), "selector still whitelisted"
        );
    }

    function test_setRoutable_EmitsGenericMessageWhitelistUpdatedEvent() public {
        bytes4[] memory selectors = _selectors(MockTarget.spin.selector);
        vm.expectEmit(address(turnstile));
        emit ITurnstile.GenericMessageWhitelistUpdated(address(target), selectors, true);
        vm.prank(admin);
        turnstile.setRoutable(address(target), selectors, true);
    }

    function test_setRoutable_RevertIf_SenderIsUnauthorized() public {
        bytes4[] memory selectors = _selectors(MockTarget.spin.selector);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vm.prank(stranger);
        turnstile.setRoutable(address(target), selectors, true);
    }

    function test_setRoutable_RevertIf_TargetHasVaultAllowance() public {
        bytes4[] memory selectors = _selectors(IERC20.transferFrom.selector);
        vm.expectRevert(abi.encodeWithSelector(ITurnstile.VaultApprovedTarget.selector, address(token)));
        vm.prank(admin);
        turnstile.setRoutable(address(token), selectors, true);
    }

    function test_setRoutable_RevertIf_SelectorIsTurnstileOnly() public {
        bytes4[] memory selectors = _selectors(MockTarget.spin.selector);
        vm.startPrank(admin);
        authority.setTargetFunctionRole(address(target), selectors, Roles.TURNSTILE);
        vm.expectRevert(
            abi.encodeWithSelector(ITurnstile.TurnstileOnlySelector.selector, address(target), MockTarget.spin.selector)
        );
        turnstile.setRoutable(address(target), selectors, true);
        vm.stopPrank();
    }

    function test_setAssetWhitelisted_SetsWhitelistStatusOfEachAsset() public {
        address[] memory assets = new address[](2);
        assets[0] = makeAddr("assetA");
        assets[1] = makeAddr("assetB");
        vm.prank(admin);
        turnstile.setAssetWhitelisted(assets, true);
        assertTrue(turnstile.assetWhitelisted(assets[0]), "first asset not whitelisted");
        assertTrue(turnstile.assetWhitelisted(assets[1]), "second asset not whitelisted");
    }

    function test_setAssetWhitelisted_RemovesAssetsFromWhitelistWhenAllowedIsFalse() public {
        vm.prank(admin);
        turnstile.setAssetWhitelisted(_addresses(address(token)), false);
        assertFalse(turnstile.assetWhitelisted(address(token)), "asset still whitelisted");
    }

    function test_setAssetWhitelisted_EmitsAssetWhitelistUpdatedEvent() public {
        address[] memory assets = _addresses(makeAddr("asset"));

        vm.expectEmit(address(turnstile));
        emit ITurnstile.AssetWhitelistUpdated(assets, true);
        vm.prank(admin);
        turnstile.setAssetWhitelisted(assets, true);

        vm.expectEmit(address(turnstile));
        emit ITurnstile.AssetWhitelistUpdated(assets, false);
        vm.prank(admin);
        turnstile.setAssetWhitelisted(assets, false);
    }

    function test_setAssetWhitelisted_RevertIf_SenderIsUnauthorized() public {
        address[] memory assets = _addresses(makeAddr("asset"));
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vm.prank(stranger);
        turnstile.setAssetWhitelisted(assets, true);
    }

    function test_pause_SetsPausedStatusToTrue() public {
        vm.prank(pauser);
        turnstile.pause();
        assertTrue(turnstile.paused(), "not paused");
    }

    function test_pause_EmitsPausedEvent() public {
        vm.expectEmit(address(turnstile));
        emit Pausable.Paused(pauser);
        vm.prank(pauser);
        turnstile.pause();
    }

    function test_pause_RevertIf_SenderIsUnauthorized() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vm.prank(stranger);
        turnstile.pause();
    }

    function test_pause_RevertIf_ContractIsAlreadyPaused() public {
        vm.prank(pauser);
        turnstile.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(pauser);
        turnstile.pause();
    }

    function test_unpause_SetsPausedStatusToFalse() public {
        vm.startPrank(pauser);
        turnstile.pause();
        turnstile.unpause();
        vm.stopPrank();
        assertFalse(turnstile.paused(), "still paused");
    }

    function test_unpause_EmitsUnpausedEvent() public {
        vm.prank(pauser);
        turnstile.pause();
        vm.expectEmit(address(turnstile));
        emit Pausable.Unpaused(pauser);
        vm.prank(pauser);
        turnstile.unpause();
    }

    function test_unpause_RevertIf_SenderIsUnauthorized() public {
        vm.prank(pauser);
        turnstile.pause();
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vm.prank(stranger);
        turnstile.unpause();
    }

    function test_unpause_RevertIf_ContractIsNotPaused() public {
        vm.expectRevert(Pausable.ExpectedPause.selector);
        vm.prank(pauser);
        turnstile.unpause();
    }

    function test_dispatch_DispatchesEachActionInOrder() public {
        _dispatch(_actions(_depositAction(_depositAction(10)), _depositAction(_depositAction(20))), 0);
        assertEq(conductor.depositAmounts(0), 10, "first action not dispatched first");
        assertEq(conductor.depositAmounts(1), 20, "second action not dispatched second");
    }

    function test_dispatch_ReturnsMessageHashOfEachAction() public {
        ITurnstile.DepositAction memory a = _depositAction(10);
        ITurnstile.DepositAction memory b = _depositAction(20);
        bytes32[] memory hashes = _dispatch(_actions(_depositAction(a), _depositAction(b)), 0);
        assertEq(hashes.length, 2, "hash count wrong");
        assertEq(
            hashes[0],
            turnstile.digestMessage(uint64(block.chainid), ITurnstile.ActionType.Deposit, _depositBody(a, user)),
            "first hash wrong"
        );
        assertEq(
            hashes[1],
            turnstile.digestMessage(uint64(block.chainid), ITurnstile.ActionType.Deposit, _depositBody(b, user)),
            "second hash wrong"
        );
    }

    function test_dispatch_AcceptsEmptyActionsArray() public {
        bytes32[] memory hashes = _dispatch(new ITurnstile.Action[](0), 0);
        assertEq(hashes.length, 0, "hashes returned for empty actions");
    }

    function test_dispatch_TreatsSenderAsActorOfEachAction() public {
        _dispatch(_actions(_withdrawalAction(_withdrawalAction(REMOTE_CHAIN)), _genericAction(_genericAction())), 0);
        assertEq(
            _lastBytes32(conductor.lastCall()), bytes32(_suffix(_accountId(user), false)), "withdrawal actor not sender"
        );
        assertEq(_lastBytes32(target.lastCall()), bytes32(_suffix(_accountId(user), false)), "generic actor not sender");
    }

    function test_dispatch_RevertIf_ContractIsPaused() public {
        vm.prank(pauser);
        turnstile.pause();
        ITurnstile.Action[] memory actions = _actions(_depositAction(_depositAction(10)));
        vm.expectRevert(Pausable.EnforcedPause.selector);
        _dispatch(actions, 0);
    }

    function test_dispatch_RevertIf_BridgeFeeSumDoesNotEqualMsgValue() public {
        adapter.setHubChainId(REMOTE_CHAIN);
        ITurnstile.Action[] memory actions =
            _actions(_action(ITurnstile.ActionType.Deposit, abi.encode(_depositAction(10)), 1, 0));
        vm.expectRevert(ITurnstile.BridgeFeeMismatch.selector);
        _dispatch(actions, 2);
    }

    function test_dispatch_Deposit_TransfersAmountFromOwnerToVault() public {
        _dispatch(_actions(_depositAction(_depositAction(100))), 0);
        assertEq(token.balanceOf(user), 900, "owner balance wrong");
        assertEq(token.balanceOf(vault), 1100, "vault balance wrong");
    }

    function test_dispatch_Deposit_SendsDepositMessageToHubChainViaMessagingAdapter() public {
        adapter.setHubChainId(REMOTE_CHAIN);
        ITurnstile.DepositAction memory a = _depositAction(100);
        _dispatch(_actions(_action(ITurnstile.ActionType.Deposit, abi.encode(a), 5, 200_000)), 5);
        assertEq(adapter.lastChainId(), REMOTE_CHAIN, "message not sent to hub chain");
        assertEq(adapter.lastGasLimit(), 200_000, "message gas not passed");
        assertEq(adapter.lastValue(), 5, "bridge fee not passed");
        assertEq(
            adapter.lastPayload(), abi.encode(ITurnstile.ActionType.Deposit, _depositBody(a, user)), "payload wrong"
        );
    }

    function test_dispatch_Deposit_ExecutesDepositMessageLocallyOnHubChain() public {
        ITurnstile.DepositAction memory a = _depositAction(100);
        _dispatch(_actions(_depositAction(a)), 0);
        bytes memory expected = abi.encodePacked(
            abi.encodeCall(
                MockHubWarehouseConductor.receiveDeposit,
                (uint64(block.chainid), address(token), 100, _accountId(user), _accountId(user), 0, bytes28(0))
            ),
            _suffix(_accountId(user), false)
        );
        assertEq(conductor.lastCall(), expected, "receiveDeposit not called with expected calldata");
    }

    function test_dispatch_Deposit_SetsStatusOfMessageToExecuted() public {
        bytes32[] memory hashes = _dispatch(_actions(_depositAction(_depositAction(100))), 0);
        assertEq(_status(hashes[0]), uint8(ITurnstile.MessageStatus.Executed), "status not Executed");
    }

    function test_dispatch_Deposit_AppliesPermitIfPermitDeadlineIsNonzero() public {
        vm.prank(user);
        token.approve(address(turnstile), 0);
        ITurnstile.DepositAction memory a = _depositAction(100);
        a.permit = _permitSignature(100, block.timestamp + 1 hours);
        _dispatch(_actions(_depositAction(a)), 0);
        assertEq(token.balanceOf(vault), 1100, "deposit with permit not transferred");
    }

    function test_dispatch_Deposit_SucceedsIfPermitFailsAndAllowanceCoversAmount() public {
        ITurnstile.DepositAction memory a = _depositAction(100);
        a.permit = ITurnstile.Permit(block.timestamp + 1 hours, 27, bytes32(uint256(1)), bytes32(uint256(1)));
        _dispatch(_actions(_depositAction(a)), 0);
        assertEq(token.balanceOf(vault), 1100, "deposit with failed permit not transferred");
    }

    function test_dispatch_Deposit_SucceedsIfDependsOnMessageIsExecuted() public {
        bytes32[] memory hashes = _dispatch(_actions(_depositAction(_depositAction(100))), 0);
        ITurnstile.DepositAction memory a = _depositAction(100);
        a.salt = bytes32(uint256(99));
        a.dependsOn = hashes[0];
        bytes32[] memory dependentHashes = _dispatch(_actions(_depositAction(a)), 0);
        assertEq(
            _status(dependentHashes[0]), uint8(ITurnstile.MessageStatus.Executed), "dependent deposit not Executed"
        );
    }

    function test_dispatch_Deposit_EmitsDepositEvent() public {
        vm.expectEmit(address(turnstile));
        emit ITurnstile.Deposit(address(token), user, _accountId(user), 100);
        _dispatch(_actions(_depositAction(_depositAction(100))), 0);
    }

    function test_dispatch_Deposit_RevertIf_OwnerChainIsNotCurrentChain() public {
        ITurnstile.DepositAction memory a = _depositAction(100);
        a.ownerChainId = REMOTE_CHAIN;
        ITurnstile.Action[] memory actions = _actions(_depositAction(a));
        vm.expectRevert(ITurnstile.NotOwner.selector);
        _dispatch(actions, 0);
    }

    function test_dispatch_Deposit_RevertIf_OwnerIsNotSender() public {
        ITurnstile.DepositAction memory a = _depositAction(100);
        a.owner = user2;
        ITurnstile.Action[] memory actions = _actions(_depositAction(a));
        vm.expectRevert(ITurnstile.NotOwner.selector);
        _dispatch(actions, 0);
    }

    function test_dispatch_Deposit_RevertIf_DependsOnMessageIsNotExecuted() public {
        ITurnstile.DepositAction memory a = _depositAction(100);
        a.dependsOn = keccak256("unknown");
        ITurnstile.Action[] memory actions = _actions(_depositAction(a));
        vm.expectRevert(ITurnstile.DependencyNotExecuted.selector);
        _dispatch(actions, 0);
    }

    function test_dispatch_Deposit_RevertIf_DeadlineHasPassed() public {
        vm.warp(1000);
        ITurnstile.DepositAction memory a = _depositAction(100);
        a.deadline = block.timestamp - 1;
        ITurnstile.Action[] memory actions = _actions(_depositAction(a));
        vm.expectRevert(ITurnstile.Expired.selector);
        _dispatch(actions, 0);
    }

    function test_dispatch_Deposit_RevertIf_ToAccountIsInvalid() public {
        ITurnstile.DepositAction memory a = _depositAction(100);
        a.toChainId = 0;
        ITurnstile.Action[] memory actions = _actions(_depositAction(a));
        vm.expectRevert(ITurnstile.InvalidAccount.selector);
        _dispatch(actions, 0);
    }

    function test_dispatch_Deposit_RevertIf_AmountIsZero() public {
        ITurnstile.Action[] memory actions = _actions(_depositAction(_depositAction(0)));
        vm.expectRevert(ITurnstile.ZeroAssets.selector);
        _dispatch(actions, 0);
    }

    function test_dispatch_Deposit_RevertIf_FacilitationFeeExceedsAmount() public {
        ITurnstile.DepositAction memory a = _depositAction(100);
        a.facilitationFee = 101;
        a.feeReceiverChainId = uint64(block.chainid);
        a.feeReceiver = recipient;
        ITurnstile.Action[] memory actions = _actions(_depositAction(a));
        vm.expectRevert(ITurnstile.FeeExceedsAmount.selector);
        _dispatch(actions, 0);
    }

    function test_dispatch_Deposit_RevertIf_FeeReceiverIsInvalidAndFacilitationFeeIsNonzero() public {
        ITurnstile.DepositAction memory a = _depositAction(100);
        a.facilitationFee = 10;
        ITurnstile.Action[] memory actions = _actions(_depositAction(a));
        vm.expectRevert(ITurnstile.InvalidAccount.selector);
        _dispatch(actions, 0);
    }

    function test_dispatch_Deposit_RevertIf_AssetIsNotWhitelisted() public {
        ITurnstile.DepositAction memory a = _depositAction(100);
        a.asset = address(new MockERC20());
        ITurnstile.Action[] memory actions = _actions(_depositAction(a));
        vm.expectRevert(ITurnstile.AssetNotWhitelisted.selector);
        _dispatch(actions, 0);
    }

    function test_dispatch_Deposit_RevertIf_PermitFailsAndAllowanceIsTooLow() public {
        vm.prank(user);
        token.approve(address(turnstile), 0);
        ITurnstile.DepositAction memory a = _depositAction(100);
        a.permit = ITurnstile.Permit(block.timestamp + 1 hours, 27, bytes32(uint256(1)), bytes32(uint256(1)));
        ITurnstile.Action[] memory actions = _actions(_depositAction(a));
        vm.expectRevert(ITurnstile.PermitFailedAndAllowanceTooLow.selector);
        _dispatch(actions, 0);
    }

    function test_dispatch_Deposit_RevertIf_TransferFromOwnerFails() public {
        ITurnstile.Action[] memory actions = _actions(_depositAction(_depositAction(2000)));
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        _dispatch(actions, 0);
    }

    function test_dispatch_Deposit_RevertIf_MessageWasAlreadyDispatched() public {
        ITurnstile.Action[] memory actions = _actions(_depositAction(_depositAction(100)));
        _dispatch(actions, 0);
        vm.expectRevert(ITurnstile.MessageReplay.selector);
        _dispatch(actions, 0);
    }

    function test_dispatch_Deposit_RevertIf_BridgeFeeIsNonzeroOnHubChain() public {
        ITurnstile.Action[] memory actions =
            _actions(_action(ITurnstile.ActionType.Deposit, abi.encode(_depositAction(100)), 1, 0));
        vm.expectRevert(ITurnstile.NoBridgeFee.selector);
        _dispatch(actions, 1);
    }

    function test_dispatch_Deposit_RevertIf_LocalExecutionRevertsOnHubChain() public {
        conductor.setShouldRevert(true);
        ITurnstile.Action[] memory actions = _actions(_depositAction(_depositAction(100)));
        vm.expectRevert(MockHubWarehouseConductor.Boom.selector);
        _dispatch(actions, 0);
    }

    function test_dispatch_Withdrawal_CallsExecuteWithdrawalWithSenderAccountAndNoFacilitatedFlag() public {
        ITurnstile.WithdrawalAction memory a = _withdrawalAction(REMOTE_CHAIN);
        _dispatch(_actions(_withdrawalAction(a)), 0);
        bytes memory expected = abi.encodePacked(
            abi.encodeCall(MockHubWarehouseConductor.executeWithdrawal, (a)), _suffix(_accountId(user), false)
        );
        assertEq(conductor.lastCall(), expected, "executeWithdrawal not called with expected calldata");
    }

    function test_dispatch_Withdrawal_SendsWithdrawalMessageWithExecutedAmountToAssetChain() public {
        conductor.setWithdrawalAmount(30);
        ITurnstile.WithdrawalAction memory a = _withdrawalAction(REMOTE_CHAIN);
        _dispatch(_actions(_action(ITurnstile.ActionType.Withdrawal, abi.encode(a), 5, 200_000)), 5);
        assertEq(adapter.lastChainId(), REMOTE_CHAIN, "message not sent to asset chain");
        assertEq(adapter.lastGasLimit(), 200_000, "message gas not passed");
        assertEq(adapter.lastValue(), 5, "bridge fee not passed");
        assertEq(
            adapter.lastPayload(),
            abi.encode(ITurnstile.ActionType.Withdrawal, _withdrawalBody(a, 30)),
            "payload not carrying executed amount"
        );
    }

    function test_dispatch_Withdrawal_ExecutesWithdrawalMessageLocallyWhenAssetChainIsCurrentChain() public {
        conductor.setWithdrawalAmount(30);
        _dispatch(_actions(_withdrawalAction(_withdrawalAction(uint64(block.chainid)))), 0);
        assertEq(token.balanceOf(recipient), 30, "recipient not paid");
        assertEq(token.balanceOf(vault), 970, "vault not debited");
    }

    function test_dispatch_Withdrawal_UsesWithdrawalActionHashAsMessageSalt() public {
        conductor.setWithdrawalAmount(30);
        ITurnstile.WithdrawalAction memory a = _withdrawalAction(REMOTE_CHAIN);
        _dispatch(_actions(_withdrawalAction(a)), 0);
        (, bytes memory body) = abi.decode(adapter.lastPayload(), (ITurnstile.ActionType, bytes));
        ITurnstile.WithdrawalMessage memory message = abi.decode(body, (ITurnstile.WithdrawalMessage));
        assertEq(message.salt, turnstile.hashWithdrawalAction(a), "salt not withdrawal action hash");
    }

    function test_dispatch_Withdrawal_SendsNoMessageAndRefundsBridgeFeeIfExecutedAmountIsZero() public {
        ITurnstile.Action[] memory actions =
            _actions(_action(ITurnstile.ActionType.Withdrawal, abi.encode(_withdrawalAction(REMOTE_CHAIN)), 5, 0));
        _dispatch(actions, 5);
        assertEq(adapter.sendCount(), 0, "message sent for zero amount");
        assertEq(user.balance, 1 ether, "bridge fee not refunded");
    }

    function test_dispatch_Withdrawal_RevertIf_HubWarehouseConductorIsNotSet() public {
        turnstile = _deployTurnstile();
        ITurnstile.Action[] memory actions = _actions(_withdrawalAction(_withdrawalAction(REMOTE_CHAIN)));
        vm.expectRevert(ITurnstile.NoHandler.selector);
        _dispatch(actions, 0);
    }

    function test_dispatch_Withdrawal_RevertIf_HubWarehouseConductorReverts() public {
        conductor.setShouldRevert(true);
        ITurnstile.Action[] memory actions = _actions(_withdrawalAction(_withdrawalAction(REMOTE_CHAIN)));
        vm.expectRevert(MockHubWarehouseConductor.Boom.selector);
        _dispatch(actions, 0);
    }

    function test_dispatch_Withdrawal_RevertIf_BridgeFeeIsNonzeroWhenAssetChainIsCurrentChain() public {
        conductor.setWithdrawalAmount(30);
        ITurnstile.Action[] memory actions = _actions(
            _action(ITurnstile.ActionType.Withdrawal, abi.encode(_withdrawalAction(uint64(block.chainid))), 1, 0)
        );
        vm.expectRevert(ITurnstile.NoBridgeFee.selector);
        _dispatch(actions, 1);
    }

    function test_dispatch_Withdrawal_MarksMessageFailedIfVaultTransferFailsWhenAssetChainIsCurrentChain() public {
        conductor.setWithdrawalAmount(5000);
        ITurnstile.Action[] memory actions = _actions(_withdrawalAction(_withdrawalAction(uint64(block.chainid))));
        bytes32[] memory hashes = _dispatch(actions, 0);
        assertEq(
            uint8(turnstile.messageStatus(hashes[0])),
            uint8(ITurnstile.MessageStatus.Failed),
            "message not marked failed"
        );
    }

    function test_dispatch_Withdrawal_RevertIf_VaultTransferRunsOutOfGasWhenAssetChainIsCurrentChain() public {
        conductor.setWithdrawalAmount(30);
        ITurnstile.WithdrawalAction memory a = _withdrawalAction(uint64(block.chainid));
        a.asset = address(new MockGasBurningERC20());
        vm.expectRevert(ITurnstile.OutOfGas.selector);
        vm.prank(user);
        turnstile.dispatch{ gas: 10_000_000 }(_actions(_withdrawalAction(a)));
    }

    function test_dispatch_Generic_SendsGenericMessageToHubChainViaMessagingAdapter() public {
        adapter.setHubChainId(REMOTE_CHAIN);
        ITurnstile.GenericAction memory a = _genericAction();
        _dispatch(_actions(_action(ITurnstile.ActionType.Generic, abi.encode(a), 5, 200_000)), 5);
        assertEq(adapter.lastChainId(), REMOTE_CHAIN, "message not sent to hub chain");
        assertEq(adapter.lastGasLimit(), 200_000, "message gas not passed");
        assertEq(adapter.lastValue(), 5, "bridge fee not passed");
        assertEq(
            adapter.lastPayload(), abi.encode(ITurnstile.ActionType.Generic, _genericBody(a, user)), "payload wrong"
        );
    }

    function test_dispatch_Generic_ExecutesGenericMessageLocallyOnHubChain() public {
        ITurnstile.GenericAction memory a = _genericAction();
        _dispatch(_actions(_genericAction(a)), 0);
        assertEq(
            target.lastCall(),
            abi.encodePacked(a.data, _suffix(_accountId(user), false)),
            "target not called with expected calldata"
        );
    }

    function test_dispatch_Generic_SucceedsIfDependsOnIsZero() public {
        _dispatch(_actions(_genericAction(_genericAction())), 0);
        assertEq(target.callCount(), 1, "target not called");
    }

    function test_dispatch_Generic_SucceedsIfDependsOnMessageIsExecuted() public {
        bytes32[] memory hashes = _dispatch(_actions(_depositAction(_depositAction(100))), 0);
        ITurnstile.GenericAction memory a = _genericAction();
        a.dependsOn = hashes[0];
        _dispatch(_actions(_genericAction(a)), 0);
        assertEq(target.callCount(), 1, "target not called");
    }

    function test_dispatch_Generic_SucceedsIfDependsOnMessageIsExecutedEarlierInSameDispatch() public {
        ITurnstile.DepositAction memory d = _depositAction(100);
        ITurnstile.GenericAction memory a = _genericAction();
        a.dependsOn =
            turnstile.digestMessage(uint64(block.chainid), ITurnstile.ActionType.Deposit, _depositBody(d, user));
        _dispatch(_actions(_depositAction(d), _genericAction(a)), 0);
        assertEq(target.callCount(), 1, "target not called");
    }

    function test_dispatch_Generic_RevertIf_OwnerChainIsNotCurrentChain() public {
        ITurnstile.GenericAction memory a = _genericAction();
        a.ownerChainId = REMOTE_CHAIN;
        ITurnstile.Action[] memory actions = _actions(_genericAction(a));
        vm.expectRevert(ITurnstile.NotOwner.selector);
        _dispatch(actions, 0);
    }

    function test_dispatch_Generic_RevertIf_OwnerIsNotSender() public {
        ITurnstile.GenericAction memory a = _genericAction();
        a.owner = user2;
        ITurnstile.Action[] memory actions = _actions(_genericAction(a));
        vm.expectRevert(ITurnstile.NotOwner.selector);
        _dispatch(actions, 0);
    }

    function test_dispatch_Generic_RevertIf_DependsOnMessageIsNotExecuted() public {
        ITurnstile.GenericAction memory a = _genericAction();
        a.dependsOn = keccak256("unknown");
        ITurnstile.Action[] memory actions = _actions(_genericAction(a));
        vm.expectRevert(ITurnstile.DependencyNotExecuted.selector);
        _dispatch(actions, 0);
    }

    function test_dispatch_Generic_RevertIf_BridgeFeeIsNonzeroOnHubChain() public {
        ITurnstile.Action[] memory actions =
            _actions(_action(ITurnstile.ActionType.Generic, abi.encode(_genericAction()), 1, 0));
        vm.expectRevert(ITurnstile.NoBridgeFee.selector);
        _dispatch(actions, 1);
    }

    function test_dispatch_Generic_RevertIf_DeadlineHasPassedOnHubChain() public {
        vm.warp(1000);
        ITurnstile.GenericAction memory a = _genericAction();
        a.deadline = block.timestamp - 1;
        ITurnstile.Action[] memory actions = _actions(_genericAction(a));
        vm.expectRevert(ITurnstile.Expired.selector);
        _dispatch(actions, 0);
    }

    function test_dispatch_Generic_RevertIf_TargetAndSelectorAreNotWhitelistedOnHubChain() public {
        ITurnstile.GenericAction memory a = _genericAction();
        a.data = abi.encodeCall(MockTarget.spin, ());
        ITurnstile.Action[] memory actions = _actions(_genericAction(a));
        vm.expectRevert(ITurnstile.NotWhitelisted.selector);
        _dispatch(actions, 0);
    }

    function test_dispatch_Generic_RevertIf_LocalExecutionRevertsOnHubChain() public {
        target.setShouldRevert(true);
        ITurnstile.Action[] memory actions = _actions(_genericAction(_genericAction()));
        vm.expectRevert(MockTarget.Boom.selector);
        _dispatch(actions, 0);
    }

    function test_facilitate_TreatsSignerOfEachSignatureAsActorOfCorrespondingAction() public {
        ITurnstile.WithdrawalAction memory a = _withdrawalAction(REMOTE_CHAIN);
        ITurnstile.WithdrawalAction memory b = _withdrawalAction(REMOTE_CHAIN);
        b.owner = user2;
        bytes[] memory signatures = _signatures(
            _sign(USER_PK, turnstile.hashWithdrawalAction(a)), _sign(USER2_PK, turnstile.hashWithdrawalAction(b))
        );
        _facilitate(_actions(_withdrawalAction(a), _withdrawalAction(b)), signatures);
        assertEq(
            _lastBytes32(conductor.calls(0)), bytes32(_suffix(_accountId(user), true)), "first actor not first signer"
        );
        assertEq(
            _lastBytes32(conductor.calls(1)),
            bytes32(_suffix(_accountId(user2), true)),
            "second actor not second signer"
        );
    }

    function test_facilitate_RecoversDepositOwnerFromDepositActionSignature() public {
        ITurnstile.DepositAction memory a = _depositAction(100);
        bytes[] memory signatures = _signatures(_sign(USER_PK, turnstile.hashDepositAction(a)));
        _facilitate(_actions(_depositAction(a)), signatures);
        assertEq(token.balanceOf(user), 900, "deposit not taken from signer");
    }

    function test_facilitate_RecoversWithdrawalOwnerFromWithdrawalActionSignature() public {
        ITurnstile.WithdrawalAction memory a = _withdrawalAction(REMOTE_CHAIN);
        bytes[] memory signatures = _signatures(_sign(USER_PK, turnstile.hashWithdrawalAction(a)));
        _facilitate(_actions(_withdrawalAction(a)), signatures);
        assertEq(bytes28(_lastBytes32(conductor.lastCall())), _accountId(user), "withdrawal owner not recovered signer");
    }

    function test_facilitate_RecoversGenericSenderFromGenericActionSignature() public {
        ITurnstile.GenericAction memory a = _genericAction();
        bytes[] memory signatures = _signatures(_sign(USER_PK, turnstile.hashGenericAction(a)));
        _facilitate(_actions(_genericAction(a)), signatures);
        assertEq(bytes28(_lastBytes32(target.lastCall())), _accountId(user), "generic sender not recovered signer");
    }

    function test_facilitate_SetsFacilitatedFlagOnCallsToConductors() public {
        ITurnstile.WithdrawalAction memory a = _withdrawalAction(REMOTE_CHAIN);
        bytes[] memory signatures = _signatures(_sign(USER_PK, turnstile.hashWithdrawalAction(a)));
        _facilitate(_actions(_withdrawalAction(a)), signatures);
        assertEq(bytes4(_lastBytes32(conductor.lastCall()) << 224), FACILITATED_FLAG, "facilitated flag not set");
    }

    function test_facilitate_DoesNotIncludeFacilitatedFlagInCrossChainMessages() public {
        adapter.setHubChainId(REMOTE_CHAIN);
        ITurnstile.GenericAction memory a = _genericAction();
        bytes[] memory signatures = _signatures(_sign(USER_PK, turnstile.hashGenericAction(a)));
        _facilitate(_actions(_genericAction(a)), signatures);
        assertEq(
            adapter.lastPayload(),
            abi.encode(ITurnstile.ActionType.Generic, _genericBody(a, user)),
            "cross-chain payload differs from unfacilitated payload"
        );
    }

    function test_facilitate_RevertIf_SenderIsUnauthorized() public {
        ITurnstile.Action[] memory actions = new ITurnstile.Action[](0);
        bytes[] memory signatures = new bytes[](0);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vm.prank(stranger);
        turnstile.facilitate(actions, signatures);
    }

    function test_facilitate_RevertIf_ContractIsPaused() public {
        vm.prank(pauser);
        turnstile.pause();
        ITurnstile.Action[] memory actions = new ITurnstile.Action[](0);
        bytes[] memory signatures = new bytes[](0);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        _facilitate(actions, signatures);
    }

    function test_facilitate_RevertIf_ActionsAndSignaturesLengthsDiffer() public {
        ITurnstile.Action[] memory actions = _actions(_genericAction(_genericAction()));
        bytes[] memory signatures = new bytes[](0);
        vm.expectRevert(ITurnstile.LengthMismatch.selector);
        _facilitate(actions, signatures);
    }

    function test_facilitate_RevertIf_SignerIsNotActionOwner() public {
        ITurnstile.DepositAction memory a = _depositAction(100);
        bytes[] memory signatures = _signatures(_sign(USER2_PK, turnstile.hashDepositAction(a)));
        ITurnstile.Action[] memory actions = _actions(_depositAction(a));
        vm.expectRevert(ITurnstile.NotOwner.selector);
        _facilitate(actions, signatures);
    }

    function test_handleReceivedMessage_Generic_FormatsSenderAccountWithSourceChainId() public {
        bytes memory body = _genericBody(_genericAction(), user);
        _receive(ITurnstile.ActionType.Generic, body);
        assertEq(
            bytes28(_lastBytes32(target.lastCall())),
            TransitAddressLib.formatTransitAddress(REMOTE_CHAIN, user),
            "source chain not used for sender account"
        );
    }

    function test_handleReceivedMessage_SetsStatusOfMessageToExecuted() public {
        bytes memory body = _genericBody(_genericAction(), user);
        _receive(ITurnstile.ActionType.Generic, body);
        assertEq(
            _status(turnstile.digestMessage(REMOTE_CHAIN, ITurnstile.ActionType.Generic, body)),
            uint8(ITurnstile.MessageStatus.Executed),
            "status not Executed"
        );
    }

    function test_handleReceivedMessage_Deposit_CallsHubWarehouseConductorReceiveDeposit() public {
        bytes28 fromAccountId = TransitAddressLib.formatTransitAddress(REMOTE_CHAIN, user);
        bytes memory body = abi.encode(
            ITurnstile.DepositMessage({
                asset: address(token),
                amount: 100,
                fromAccountId: fromAccountId,
                toAccountId: _accountId(user2),
                facilitationFee: 0,
                feeReceiverAccountId: bytes28(0),
                salt: bytes32(uint256(1))
            })
        );
        _receive(ITurnstile.ActionType.Deposit, body);
        bytes memory expected = abi.encodePacked(
            abi.encodeCall(
                MockHubWarehouseConductor.receiveDeposit,
                (REMOTE_CHAIN, address(token), 100, fromAccountId, _accountId(user2), 0, bytes28(0))
            ),
            _suffix(fromAccountId, false)
        );
        assertEq(conductor.lastCall(), expected, "receiveDeposit not called with expected calldata");
    }

    function test_handleReceivedMessage_Withdrawal_TransfersAssetFromVaultToRecipient() public {
        _receive(ITurnstile.ActionType.Withdrawal, _withdrawalMessageBody(30));
        assertEq(token.balanceOf(recipient), 30, "recipient not paid");
        assertEq(token.balanceOf(vault), 970, "vault not debited");
    }

    function test_handleReceivedMessage_Withdrawal_EmitsWithdrawalReleasedEvent() public {
        bytes memory body = _withdrawalMessageBody(30);
        vm.expectEmit(address(turnstile));
        emit ITurnstile.WithdrawalReleased(recipient, address(token), 30);
        _receive(ITurnstile.ActionType.Withdrawal, body);
    }

    function test_handleReceivedMessage_Generic_CallsTargetWithMessageDataAndSenderAccountOnSourceChain() public {
        ITurnstile.GenericAction memory a = _genericAction();
        _receive(ITurnstile.ActionType.Generic, _genericBody(a, user));
        assertEq(
            target.lastCall(),
            abi.encodePacked(a.data, _suffix(TransitAddressLib.formatTransitAddress(REMOTE_CHAIN, user), false)),
            "target not called with expected calldata"
        );
    }

    function test_handleReceivedMessage_Deposit_AppendsSenderAccountWithoutFacilitatedFlagToCalldata() public {
        bytes28 fromAccountId = TransitAddressLib.formatTransitAddress(REMOTE_CHAIN, user);
        bytes memory body = abi.encode(
            ITurnstile.DepositMessage({
                asset: address(token),
                amount: 100,
                fromAccountId: fromAccountId,
                toAccountId: fromAccountId,
                facilitationFee: 0,
                feeReceiverAccountId: bytes28(0),
                salt: bytes32(uint256(1))
            })
        );
        _receive(ITurnstile.ActionType.Deposit, body);
        assertEq(_lastBytes32(conductor.lastCall()), bytes32(_suffix(fromAccountId, false)), "suffix wrong");
    }

    function test_handleReceivedMessage_SetsStatusOfMessageToFailedIfExecutionReverts() public {
        bytes memory body = _failGenericMessage();
        assertEq(
            _status(turnstile.digestMessage(REMOTE_CHAIN, ITurnstile.ActionType.Generic, body)),
            uint8(ITurnstile.MessageStatus.Failed),
            "status not Failed"
        );
    }

    function test_handleReceivedMessage_EmitsMessageFailedEventIfExecutionReverts() public {
        bytes memory body = _genericBody(_genericAction(), user);
        target.setShouldRevert(true);
        bytes32 messageHash = turnstile.digestMessage(REMOTE_CHAIN, ITurnstile.ActionType.Generic, body);
        vm.expectEmit(address(turnstile));
        emit ITurnstile.MessageFailed(REMOTE_CHAIN, ITurnstile.ActionType.Generic, messageHash, body);
        _receive(ITurnstile.ActionType.Generic, body);
    }

    function test_handleReceivedMessage_Withdrawal_SetsStatusOfMessageToFailedIfVaultTransferFails() public {
        bytes memory body = _withdrawalMessageBody(5000);
        _receive(ITurnstile.ActionType.Withdrawal, body);
        assertEq(
            _status(turnstile.digestMessage(REMOTE_CHAIN, ITurnstile.ActionType.Withdrawal, body)),
            uint8(ITurnstile.MessageStatus.Failed),
            "status not Failed"
        );
    }

    function test_handleReceivedMessage_Generic_SetsStatusOfMessageToFailedIfDeadlineHasPassed() public {
        vm.warp(1000);
        ITurnstile.GenericAction memory a = _genericAction();
        a.deadline = block.timestamp - 1;
        bytes memory body = _genericBody(a, user);
        _receive(ITurnstile.ActionType.Generic, body);
        assertEq(
            _status(turnstile.digestMessage(REMOTE_CHAIN, ITurnstile.ActionType.Generic, body)),
            uint8(ITurnstile.MessageStatus.Failed),
            "status not Failed"
        );
    }

    function test_handleReceivedMessage_Generic_SetsStatusOfMessageToFailedIfTargetAndSelectorAreNotWhitelisted()
        public
    {
        ITurnstile.GenericAction memory a = _genericAction();
        a.data = abi.encodeCall(MockTarget.spin, ());
        bytes memory body = _genericBody(a, user);
        _receive(ITurnstile.ActionType.Generic, body);
        assertEq(
            _status(turnstile.digestMessage(REMOTE_CHAIN, ITurnstile.ActionType.Generic, body)),
            uint8(ITurnstile.MessageStatus.Failed),
            "status not Failed"
        );
    }

    function test_handleReceivedMessage_Generic_SetsStatusOfMessageToFailedIfTargetHasVaultAllowance() public {
        MockERC20 approvedToken = new MockERC20();
        approvedToken.mint(vault, 100);
        vm.prank(admin);
        turnstile.setRoutable(address(approvedToken), _selectors(IERC20.transferFrom.selector), true);
        vm.prank(vault);
        approvedToken.approve(address(turnstile), type(uint256).max);
        ITurnstile.GenericAction memory a = _genericAction();
        a.target = address(approvedToken);
        a.data = abi.encodeCall(IERC20.transferFrom, (vault, stranger, 100));
        bytes memory body = _genericBody(a, user);
        _receive(ITurnstile.ActionType.Generic, body);
        assertEq(
            _status(turnstile.digestMessage(REMOTE_CHAIN, ITurnstile.ActionType.Generic, body)),
            uint8(ITurnstile.MessageStatus.Failed),
            "status not Failed"
        );
        assertEq(approvedToken.balanceOf(stranger), 0, "VAULT allowance spent");
    }

    function test_handleReceivedMessage_Generic_SetsStatusOfMessageToFailedIfSelectorIsTurnstileOnly() public {
        vm.prank(admin);
        authority.setTargetFunctionRole(address(target), _selectors(MockTarget.ping.selector), Roles.TURNSTILE);
        bytes memory body = _genericBody(_genericAction(), user);
        _receive(ITurnstile.ActionType.Generic, body);
        assertEq(
            _status(turnstile.digestMessage(REMOTE_CHAIN, ITurnstile.ActionType.Generic, body)),
            uint8(ITurnstile.MessageStatus.Failed),
            "status not Failed"
        );
        assertEq(target.callCount(), 0, "Turnstile-only selector called");
    }

    function test_handleReceivedMessage_RevertIf_SenderIsUnauthorized() public {
        bytes memory payload = abi.encode(ITurnstile.ActionType.Generic, _genericBody(_genericAction(), user));
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vm.prank(stranger);
        turnstile.handleReceivedMessage(REMOTE_CHAIN, payload);
    }

    function test_handleReceivedMessage_RevertIf_ContractIsPaused() public {
        vm.prank(pauser);
        turnstile.pause();
        bytes memory body = _genericBody(_genericAction(), user);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        _receive(ITurnstile.ActionType.Generic, body);
    }

    function test_handleReceivedMessage_RevertIf_MessageWasAlreadyReceived() public {
        bytes memory body = _genericBody(_genericAction(), user);
        _receive(ITurnstile.ActionType.Generic, body);
        vm.expectRevert(ITurnstile.MessageReplay.selector);
        _receive(ITurnstile.ActionType.Generic, body);
    }

    function test_handleReceivedMessage_Deposit_RevertIf_HubWarehouseConductorIsNotSet() public {
        turnstile = _deployTurnstile();
        bytes28 fromAccountId = TransitAddressLib.formatTransitAddress(REMOTE_CHAIN, user);
        bytes memory body = abi.encode(
            ITurnstile.DepositMessage({
                asset: address(token),
                amount: 100,
                fromAccountId: fromAccountId,
                toAccountId: fromAccountId,
                facilitationFee: 0,
                feeReceiverAccountId: bytes28(0),
                salt: bytes32(uint256(1))
            })
        );
        vm.expectRevert(ITurnstile.NoHandler.selector);
        _receive(ITurnstile.ActionType.Deposit, body);
    }

    function test_handleReceivedMessage_RevertIf_ExecutionRunsOutOfGas() public {
        vm.prank(admin);
        turnstile.setRoutable(address(target), _selectors(MockTarget.spin.selector), true);
        ITurnstile.GenericAction memory a = _genericAction();
        a.data = abi.encodeCall(MockTarget.spin, ());
        bytes memory payload = abi.encode(ITurnstile.ActionType.Generic, _genericBody(a, user));
        vm.expectRevert(ITurnstile.OutOfGas.selector);
        vm.prank(address(adapter));
        turnstile.handleReceivedMessage{ gas: 10_000_000 }(REMOTE_CHAIN, payload);
    }

    function test_retry_ExecutesFailedMessageAgain() public {
        bytes memory body = _failGenericMessage();
        target.setShouldRevert(false);
        vm.prank(admin);
        turnstile.retry(REMOTE_CHAIN, ITurnstile.ActionType.Generic, body);
        assertEq(target.callCount(), 1, "target not called on retry");
    }

    function test_retry_SetsStatusOfMessageToExecutedOnSuccess() public {
        bytes memory body = _failGenericMessage();
        target.setShouldRevert(false);
        vm.prank(admin);
        turnstile.retry(REMOTE_CHAIN, ITurnstile.ActionType.Generic, body);
        assertEq(
            _status(turnstile.digestMessage(REMOTE_CHAIN, ITurnstile.ActionType.Generic, body)),
            uint8(ITurnstile.MessageStatus.Executed),
            "status not Executed"
        );
    }

    function test_retry_SetsStatusOfMessageToFailedIfExecutionRevertsAgain() public {
        bytes memory body = _failGenericMessage();
        vm.prank(admin);
        turnstile.retry(REMOTE_CHAIN, ITurnstile.ActionType.Generic, body);
        assertEq(
            _status(turnstile.digestMessage(REMOTE_CHAIN, ITurnstile.ActionType.Generic, body)),
            uint8(ITurnstile.MessageStatus.Failed),
            "status not Failed"
        );
    }

    function test_retry_EmitsMessageRetriedEvent() public {
        bytes memory body = _failGenericMessage();
        target.setShouldRevert(false);
        bytes32 messageHash = turnstile.digestMessage(REMOTE_CHAIN, ITurnstile.ActionType.Generic, body);
        vm.expectEmit(address(turnstile));
        emit ITurnstile.MessageRetried(REMOTE_CHAIN, ITurnstile.ActionType.Generic, messageHash);
        vm.prank(admin);
        turnstile.retry(REMOTE_CHAIN, ITurnstile.ActionType.Generic, body);
    }

    function test_retry_RevertIf_SenderIsUnauthorized() public {
        bytes memory body = _failGenericMessage();
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vm.prank(stranger);
        turnstile.retry(REMOTE_CHAIN, ITurnstile.ActionType.Generic, body);
    }

    function test_retry_RevertIf_ContractIsPaused() public {
        bytes memory body = _failGenericMessage();
        vm.prank(pauser);
        turnstile.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(admin);
        turnstile.retry(REMOTE_CHAIN, ITurnstile.ActionType.Generic, body);
    }

    function test_retry_RevertIf_MessageStatusIsNotFailed() public {
        bytes memory body = _genericBody(_genericAction(), user);
        vm.expectRevert(ITurnstile.NotFailed.selector);
        vm.prank(admin);
        turnstile.retry(REMOTE_CHAIN, ITurnstile.ActionType.Generic, body);
    }

    function test_quote_ReturnsMessagingAdapterQuoteForEachAction() public {
        adapter.setHubChainId(REMOTE_CHAIN);
        ITurnstile.DepositAction memory d = _depositAction(100);
        ITurnstile.WithdrawalAction memory w = _withdrawalAction(REMOTE_CHAIN);
        ITurnstile.GenericAction memory g = _genericAction();
        ITurnstile.Action[] memory actions = new ITurnstile.Action[](3);
        actions[0] = _action(ITurnstile.ActionType.Deposit, abi.encode(d), 0, 100_000);
        actions[1] = _action(ITurnstile.ActionType.Withdrawal, abi.encode(w), 0, 200_000);
        actions[2] = _action(ITurnstile.ActionType.Generic, abi.encode(g), 0, 300_000);

        uint256[] memory fees = turnstile.quote(actions);

        assertEq(
            fees[0],
            adapter.quote(
                REMOTE_CHAIN, 100_000, abi.encode(ITurnstile.ActionType.Deposit, _depositBody(d, address(this)))
            ),
            "deposit quote wrong"
        );
        assertEq(
            fees[1],
            adapter.quote(
                REMOTE_CHAIN, 200_000, abi.encode(ITurnstile.ActionType.Withdrawal, _withdrawalBody(w, w.amount))
            ),
            "withdrawal quote wrong"
        );
        assertEq(
            fees[2],
            adapter.quote(
                REMOTE_CHAIN, 300_000, abi.encode(ITurnstile.ActionType.Generic, _genericBody(g, address(this)))
            ),
            "generic quote wrong"
        );
    }

    function test_quote_ReturnsZeroForActionWhoseDestinationIsCurrentChain() public view {
        uint256[] memory fees = turnstile.quote(
            _actions(_action(ITurnstile.ActionType.Deposit, abi.encode(_depositAction(100)), 0, 100_000))
        );
        assertEq(fees[0], 0, "same-chain quote not zero");
    }

    function test_hashDepositAction_ReturnsEip712DigestOfDepositAction() public view {
        ITurnstile.DepositAction memory a = _depositAction(100);
        a.permit = ITurnstile.Permit(5, 27, bytes32(uint256(6)), bytes32(uint256(7)));
        bytes32 permitHash = keccak256(
            abi.encode(
                keccak256("Permit(uint256 deadline,uint8 v,bytes32 r,bytes32 s)"),
                a.permit.deadline,
                a.permit.v,
                a.permit.r,
                a.permit.s
            )
        );
        bytes32 structHash = keccak256(
            bytes.concat(
                abi.encode(
                    keccak256(
                        "DepositAction(uint64 ownerChainId,address owner,address asset,uint256 amount,uint64 toChainId,address to,uint256 facilitationFee,uint64 feeReceiverChainId,address feeReceiver,uint256 deadline,bytes32 dependsOn,bytes32 salt,Permit permit)Permit(uint256 deadline,uint8 v,bytes32 r,bytes32 s)"
                    ),
                    a.ownerChainId,
                    a.owner,
                    a.asset,
                    a.amount,
                    a.toChainId,
                    a.to
                ),
                abi.encode(
                    a.facilitationFee, a.feeReceiverChainId, a.feeReceiver, a.deadline, a.dependsOn, a.salt, permitHash
                )
            )
        );
        assertEq(
            turnstile.hashDepositAction(a),
            keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash)),
            "deposit action digest wrong"
        );
    }

    function test_hashWithdrawalAction_ReturnsEip712DigestOfWithdrawalAction() public view {
        ITurnstile.WithdrawalAction memory a = _withdrawalAction(REMOTE_CHAIN);
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "WithdrawalAction(uint64 ownerChainId,address owner,address to,uint64 assetChainId,address asset,uint256 amount,uint256 deadline,bool partiallyFillable,bytes32 dependsOn,bytes32 salt)"
                ),
                a
            )
        );
        assertEq(
            turnstile.hashWithdrawalAction(a),
            keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash)),
            "withdrawal action digest wrong"
        );
    }

    function test_hashGenericAction_ReturnsEip712DigestOfGenericAction() public view {
        ITurnstile.GenericAction memory a = _genericAction();
        a.dependsOn = bytes32(uint256(8));
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "GenericAction(uint64 ownerChainId,address owner,address target,bytes data,uint256 deadline,bytes32 dependsOn,bytes32 salt)"
                ),
                a.ownerChainId,
                a.owner,
                a.target,
                keccak256(a.data),
                a.deadline,
                a.dependsOn,
                a.salt
            )
        );
        assertEq(
            turnstile.hashGenericAction(a),
            keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash)),
            "generic action digest wrong"
        );
    }

    function test_digestMessage_ReturnsHashOfChainIdActionTypeAndBody() public view {
        bytes memory body = hex"1234";
        assertEq(
            turnstile.digestMessage(REMOTE_CHAIN, ITurnstile.ActionType.Generic, body),
            keccak256(abi.encode(REMOTE_CHAIN, ITurnstile.ActionType.Generic, body)),
            "message digest wrong"
        );
    }

}
