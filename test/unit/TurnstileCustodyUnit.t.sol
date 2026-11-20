// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { dispatchOne } from "../helpers/DispatchOne.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { ITurnstile } from "../../src/interfaces/ITurnstile.sol";
import { Turnstile } from "../../src/turnstile/Turnstile.sol";
import { HubWarehouseConductor } from "../../src/conductor/HubWarehouseConductor.sol";
import { MockMessagingAdapter } from "../mocks/MockMessagingAdapter.sol";
import { MessagingAdapter } from "../../src/messaging/MessagingAdapter.sol";
import { Roles } from "../../src/helpers/Roles.sol";
import { TransitAddressLib } from "../../src/helpers/TransitAddressLib.sol";
import { WarehouseConductorUnitBase } from "./WarehouseConductorUnitBase.t.sol";

contract TurnstileCustodyUnitTest is WarehouseConductorUnitBase {

    // ---------------------------------------------------------------- deposit

    function testDepositCreditsUserAndVault() public {
        _deposit(alice, 100e6);

        assertEq(
            depot.balanceOf(
                TransitAddressLib.formatTransitAddress(HUB_CHAIN_ID, alice),
                TransitAddressLib.formatTransitAddress(HUB_CHAIN_ID, address(usdc))
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
                    facilitationFee: 0,
                    feeReceiverChainId: 0,
                    feeReceiver: address(0),
                    deadline: type(uint256).max,
                    dependsOn: bytes32(0),
                    salt: bytes32(0),
                    permit: ITurnstile.Permit({ deadline: 0, v: 0, r: bytes32(0), s: bytes32(0) })
                })
            ),
            0
        );
        vm.stopPrank();

        assertEq(
            depot.balanceOf(
                TransitAddressLib.formatTransitAddress(HUB_CHAIN_ID, alice),
                TransitAddressLib.formatTransitAddress(HUB_CHAIN_ID, address(other))
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
        receiveSels[0] = Turnstile.handleReceivedMessage.selector;

        vm.startPrank(admin);
        authority.setTargetFunctionRole(address(spokeTurnstile), turnstileAdminSels, Roles.ADMIN);
        authority.setTargetFunctionRole(address(spokeAdapter), peerSels, Roles.ADMIN);
        authority.setTargetFunctionRole(address(hubAdapter), peerSels, Roles.ADMIN);
        authority.setTargetFunctionRole(address(turnstile), receiveSels, Roles.MESSAGING_ADAPTER);
        authority.grantRole(Roles.MESSAGING_ADAPTER, address(hubAdapter), 0);

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
                    facilitationFee: 0,
                    feeReceiverChainId: 0,
                    feeReceiver: address(0),
                    deadline: type(uint256).max,
                    dependsOn: bytes32(0),
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
                TransitAddressLib.formatTransitAddress(SPOKE_CHAIN_ID, alice),
                TransitAddressLib.formatTransitAddress(SPOKE_CHAIN_ID, address(usdg))
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

    // ---------------------------------------------------------------- dependsOn

    function _depositActions(
        address user,
        uint256 amount,
        bytes32 dependsOn,
        bytes32 salt
    )
        internal
        view
        returns (ITurnstile.Action[] memory actions)
    {
        actions = new ITurnstile.Action[](1);
        actions[0] = ITurnstile.Action({
            actionType: ITurnstile.ActionType.Deposit,
            data: abi.encode(
                ITurnstile.DepositAction({
                    ownerChainId: HUB_CHAIN_ID,
                    owner: user,
                    asset: address(usdc),
                    amount: amount,
                    toChainId: HUB_CHAIN_ID,
                    to: user,
                    facilitationFee: 0,
                    feeReceiverChainId: 0,
                    feeReceiver: address(0),
                    deadline: type(uint256).max,
                    dependsOn: dependsOn,
                    salt: salt,
                    permit: ITurnstile.Permit({ deadline: 0, v: 0, r: bytes32(0), s: bytes32(0) })
                })
            ),
            bridgeFee: 0,
            messageGas: 0
        });
    }

    function testDepositRevertsOnUnexecutedDependency() public {
        deal(address(usdc), alice, 1e6);
        vm.startPrank(alice);
        SafeTransferLib.safeApprove(address(usdc), address(turnstile), 1e6);
        ITurnstile.Action[] memory actions = _depositActions(alice, 1e6, keccak256("unexecuted"), bytes32(0));
        vm.expectRevert(ITurnstile.DependencyNotExecuted.selector);
        turnstile.dispatch(actions);
        vm.stopPrank();
    }

    function testDepositSucceedsOnExecutedDependency() public {
        deal(address(usdc), alice, 2e6);
        vm.startPrank(alice);
        SafeTransferLib.safeApprove(address(usdc), address(turnstile), 2e6);
        bytes32 firstHash = turnstile.dispatch(_depositActions(alice, 1e6, bytes32(0), bytes32(0)))[0];
        turnstile.dispatch(_depositActions(alice, 1e6, firstHash, bytes32(uint256(1))));
        vm.stopPrank();

        assertEq(
            depot.balanceOf(
                TransitAddressLib.formatTransitAddress(HUB_CHAIN_ID, alice),
                TransitAddressLib.formatTransitAddress(HUB_CHAIN_ID, address(usdc))
            ),
            2e6,
            "dependsOn: dependent deposit not credited after its dependency executed"
        );
    }

    function testWithdrawalRevertsOnUnexecutedDependency() public {
        ITurnstile.Action[] memory actions = new ITurnstile.Action[](1);
        actions[0] = ITurnstile.Action({
            actionType: ITurnstile.ActionType.Withdrawal,
            data: abi.encode(
                ITurnstile.WithdrawalAction({
                    ownerChainId: HUB_CHAIN_ID,
                    owner: alice,
                    to: alice,
                    assetChainId: HUB_CHAIN_ID,
                    asset: address(usdc),
                    amount: 1e6,
                    deadline: type(uint256).max,
                    partiallyFillable: false,
                    dependsOn: keccak256("unexecuted"),
                    salt: bytes32(0)
                })
            ),
            bridgeFee: 0,
            messageGas: 0
        });
        vm.prank(alice);
        vm.expectRevert(ITurnstile.DependencyNotExecuted.selector);
        turnstile.dispatch(actions);
    }

    // ---------------------------------------------------------------- facilitation fee

    function _feeDepositActions(
        address user,
        uint256 amount,
        uint256 fee,
        address feeReceiver
    )
        internal
        view
        returns (ITurnstile.Action[] memory actions)
    {
        actions = _depositActions(user, amount, bytes32(0), bytes32(0));
        ITurnstile.DepositAction memory action = abi.decode(actions[0].data, (ITurnstile.DepositAction));
        action.facilitationFee = fee;
        action.feeReceiverChainId = HUB_CHAIN_ID;
        action.feeReceiver = feeReceiver;
        actions[0].data = abi.encode(action);
    }

    function testDepositFacilitationFeePaidToReceiver() public {
        deal(address(usdc), alice, 100e6);
        vm.startPrank(alice);
        SafeTransferLib.safeApprove(address(usdc), address(turnstile), 100e6);
        turnstile.dispatch(_feeDepositActions(alice, 100e6, 1e6, backend));
        vm.stopPrank();

        bytes28 usdcId = TransitAddressLib.formatTransitAddress(HUB_CHAIN_ID, address(usdc));
        assertEq(
            depot.balanceOf(TransitAddressLib.formatTransitAddress(HUB_CHAIN_ID, alice), usdcId),
            99e6,
            "fee: recipient not credited amount minus fee"
        );
        assertEq(
            depot.balanceOf(TransitAddressLib.formatTransitAddress(HUB_CHAIN_ID, backend), usdcId),
            1e6,
            "fee: fee receiver not paid"
        );
        assertEq(usdc.balanceOf(vault), 100e6, "fee: vault should custody the full amount");
    }

    function testDepositFeeExceedingAmountReverts() public {
        deal(address(usdc), alice, 1e6);
        vm.startPrank(alice);
        SafeTransferLib.safeApprove(address(usdc), address(turnstile), 1e6);
        ITurnstile.Action[] memory actions = _feeDepositActions(alice, 1e6, 1e6 + 1, backend);
        vm.expectRevert(ITurnstile.FeeExceedsAmount.selector);
        turnstile.dispatch(actions);
        vm.stopPrank();
    }

    function testDepositFeeToInvalidReceiverReverts() public {
        deal(address(usdc), alice, 1e6);
        vm.startPrank(alice);
        SafeTransferLib.safeApprove(address(usdc), address(turnstile), 1e6);
        ITurnstile.Action[] memory actions = _feeDepositActions(alice, 1e6, 1, address(0));
        vm.expectRevert(ITurnstile.InvalidAccount.selector);
        turnstile.dispatch(actions);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- whitelist guards

    function testSetRoutableRejectsTurnstileOnlySelector() public {
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = HubWarehouseConductor.receiveDeposit.selector;
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(ITurnstile.TurnstileOnlySelector.selector, address(hubWarehouseConductor), sels[0])
        );
        turnstile.setRoutable(address(hubWarehouseConductor), sels, true);
    }

    function testSetRoutableRejectsVaultApprovedTarget() public {
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = ERC20.transferFrom.selector;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ITurnstile.VaultApprovedTarget.selector, address(usdc)));
        turnstile.setRoutable(address(usdc), sels, true);
    }

    function testGenericCallBlockedOnceSelectorBecomesTurnstileOnly() public {
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = HubWarehouseConductor.requestWithdrawal.selector;
        vm.prank(admin);
        authority.setTargetFunctionRole(address(hubWarehouseConductor), sels, Roles.TURNSTILE);

        ITurnstile.Action[] memory actions = new ITurnstile.Action[](1);
        actions[0] = ITurnstile.Action({
            actionType: ITurnstile.ActionType.Generic,
            data: abi.encode(
                ITurnstile.GenericAction({
                    ownerChainId: HUB_CHAIN_ID,
                    owner: mallory,
                    target: address(hubWarehouseConductor),
                    data: abi.encodePacked(sels[0]),
                    deadline: type(uint256).max,
                    dependsOn: bytes32(0),
                    salt: bytes32(0)
                })
            ),
            bridgeFee: 0,
            messageGas: 0
        });
        vm.prank(mallory);
        vm.expectRevert(ITurnstile.NotWhitelisted.selector);
        turnstile.dispatch(actions);
    }

    function testGenericCallBlockedOnceTargetGainsVaultAllowance() public {
        ERC20 token = _asset("Late", "LATE", 18);
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = ERC20.transferFrom.selector;
        vm.prank(admin);
        turnstile.setRoutable(address(token), sels, true);

        deal(address(token), vault, 1e18);
        vm.prank(vault);
        SafeTransferLib.safeApprove(address(token), address(turnstile), type(uint256).max);

        ITurnstile.Action[] memory actions = new ITurnstile.Action[](1);
        actions[0] = ITurnstile.Action({
            actionType: ITurnstile.ActionType.Generic,
            data: abi.encode(
                ITurnstile.GenericAction({
                    ownerChainId: HUB_CHAIN_ID,
                    owner: mallory,
                    target: address(token),
                    data: abi.encodeCall(ERC20.transferFrom, (vault, mallory, 1e18)),
                    deadline: type(uint256).max,
                    dependsOn: bytes32(0),
                    salt: bytes32(0)
                })
            ),
            bridgeFee: 0,
            messageGas: 0
        });
        vm.prank(mallory);
        vm.expectRevert(ITurnstile.NotWhitelisted.selector);
        turnstile.dispatch(actions);
        assertEq(token.balanceOf(vault), 1e18, "generic: vault-approved target was callable");
    }

    function testSetRoutableAllowsDisallowingTurnstileOnlySelector() public {
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = HubWarehouseConductor.executeWithdrawal.selector;
        vm.prank(admin);
        turnstile.setRoutable(address(hubWarehouseConductor), sels, false);
        assertFalse(
            turnstile.genericMessageWhitelist(address(hubWarehouseConductor), sels[0]),
            "setRoutable: disallowing a turnstile-only selector should succeed"
        );
    }

    // ---------------------------------------------------------------- delayed admin

    function testDelayedAdminMustScheduleThenWait() public {
        address delayedAdmin = makeAddr("delayedAdmin");
        vm.prank(admin);
        authority.grantRole(Roles.ADMIN, delayedAdmin, 1 days);
        ERC20 other = _asset("Other", "OTH", 18);
        bytes memory data = abi.encodeCall(Turnstile.setAssetWhitelisted, (_list(address(other)), true));

        vm.prank(delayedAdmin);
        vm.expectRevert();
        turnstile.setAssetWhitelisted(_list(address(other)), true);

        vm.prank(delayedAdmin);
        authority.schedule(address(turnstile), data, 0);
        vm.warp(block.timestamp + 1 days);
        vm.prank(delayedAdmin);
        turnstile.setAssetWhitelisted(_list(address(other)), true);

        assertTrue(
            turnstile.assetWhitelisted(address(other)), "delayed admin: scheduled call did not apply after delay"
        );
    }

    // ---------------------------------------------------------------- messages

    function testReceiveMessageFromNonAdapterReverts() public {
        ITurnstile.WithdrawalMessage memory m = ITurnstile.WithdrawalMessage({
            asset: address(usdc), amount: 1e6, to: alice, salt: bytes32(++withdrawSalt)
        });
        bytes memory payload = abi.encode(ITurnstile.ActionType.Withdrawal, abi.encode(m));

        vm.prank(mallory);
        vm.expectRevert();
        turnstile.handleReceivedMessage(SPOKE_CHAIN_ID, payload);
    }

}
