// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { SharedSetup } from "test/integration/SharedSetup.sol";
import { MockERC20 } from "lib/solady/test/utils/mocks/MockERC20.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { IDepot } from "src/interfaces/IDepot.sol";
import { ITurnstile } from "src/interfaces/ITurnstile.sol";
import { Turnstile } from "src/turnstile/Turnstile.sol";

contract MessageFailures is SharedSetup {

    uint64 constant SPOKE = ROBINHOOD_CHAIN_ID;
    uint256 constant AMOUNT = 100e6;

    address alice;
    uint256 alicePk;
    address bob = makeAddr("bob");

    function setUp() public override {
        super.setUp();
        (alice, alicePk) = makeAddrAndKey("alice");
    }

    function test_dispatch_KeepsRequestPendingIfHubChainReleaseReverts() public {
        ITurnstile.WithdrawalAction memory action = _requestHubChainWithdrawal(type(uint256).max);
        bytes32 requestId = hubWarehouseConductor.hashWithdrawalAction(action);
        uint256 effectiveAtEpoch = hubWarehouseConductor.requestEffectiveAtEpoch(_hubAccount(alice), requestId);

        vm.prank(alice);
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        _dispatchOne(turnstile, ITurnstile.ActionType.Withdrawal, abi.encode(action));

        assertEq(
            hubWarehouseConductor.requestEffectiveAtEpoch(_hubAccount(alice), requestId),
            effectiveAtEpoch,
            "request not left pending"
        );
        assertEq(depot.freeBalanceOf(_hubAccount(alice), _asset(HUB_CHAIN_ID)), 0, "reservation released");
        assertEq(_balance(HUB_CHAIN_ID, alice, HUB_CHAIN_ID), AMOUNT, "burned on hub");
        assertEq(usdg.balanceOf(VAULT), AMOUNT, "vault released funds");
        assertEq(usdg.balanceOf(alice), 0, "alice paid while vault allowance is missing");
    }

    function test_dispatch_ReleasesReservationAfterDeadlineIfHubChainReleaseReverts() public {
        ITurnstile.WithdrawalAction memory action = _requestHubChainWithdrawal(block.timestamp + 48 hours);

        vm.prank(alice);
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        _dispatchOne(turnstile, ITurnstile.ActionType.Withdrawal, abi.encode(action));

        vm.warp(block.timestamp + 48 hours);
        vm.prank(alice);
        _dispatchOne(turnstile, ITurnstile.ActionType.Withdrawal, abi.encode(action));

        assertEq(
            hubWarehouseConductor.requestEffectiveAtEpoch(
                _hubAccount(alice), hubWarehouseConductor.hashWithdrawalAction(action)
            ),
            hubWarehouseConductor.EXECUTED(),
            "request not consumed"
        );
        (uint256 effective, uint256 pending,) = depot.reservation(_hubAccount(alice), _asset(HUB_CHAIN_ID));
        assertEq(effective, 0, "effective reservation not released");
        assertEq(pending, 0, "pending reservation not released");
        assertEq(_balance(HUB_CHAIN_ID, alice, HUB_CHAIN_ID), AMOUNT, "burned on hub");
        assertEq(usdg.balanceOf(VAULT), AMOUNT, "vault released funds");
    }

    function test_dispatch_ReleasesHubChainWithdrawalOnRedispatch() public {
        ITurnstile.WithdrawalAction memory action = _requestHubChainWithdrawal(type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        _dispatchOne(turnstile, ITurnstile.ActionType.Withdrawal, abi.encode(action));

        vm.prank(VAULT);
        usdg.approve(address(turnstile), type(uint256).max);
        vm.prank(alice);
        _dispatchOne(turnstile, ITurnstile.ActionType.Withdrawal, abi.encode(action));

        assertEq(usdg.balanceOf(alice), AMOUNT, "not released on redispatch");
        assertEq(_balance(HUB_CHAIN_ID, alice, HUB_CHAIN_ID), 0, "not burned on hub");
        assertEq(
            hubWarehouseConductor.requestEffectiveAtEpoch(
                _hubAccount(alice), hubWarehouseConductor.hashWithdrawalAction(action)
            ),
            hubWarehouseConductor.EXECUTED(),
            "request not consumed"
        );
    }

    function test_handleReceivedMessage_ReleasesSpokeWithdrawalOnRedelivery() public {
        MockERC20 token = spokeUsdg[SPOKE];
        Turnstile spoke = spokeTurnstile[SPOKE];
        _deposit(alice, SPOKE, token, HUB_CHAIN_ID, AMOUNT);
        _relayMessages();

        vm.prank(VAULT);
        token.approve(address(spoke), 0);

        vm.chainId(HUB_CHAIN_ID);
        ITurnstile.WithdrawalAction memory action = ITurnstile.WithdrawalAction({
            ownerChainId: HUB_CHAIN_ID,
            owner: alice,
            to: alice,
            assetChainId: SPOKE,
            asset: address(token),
            amount: AMOUNT,
            deadline: type(uint256).max,
            partiallyFillable: false,
            dependsOn: bytes32(0),
            salt: bytes32(0)
        });
        _facilitate(
            HUB_CHAIN_ID,
            ITurnstile.ActionType.Withdrawal,
            abi.encode(action),
            _sign(alicePk, turnstile.hashWithdrawalAction(action))
        );
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        _relayMessages();

        assertEq(_balance(HUB_CHAIN_ID, alice, SPOKE), 0, "not burned on hub");
        assertEq(token.balanceOf(alice), 0, "released while vault allowance is missing");

        vm.prank(VAULT);
        token.approve(address(spoke), type(uint256).max);
        bytes memory body = abi.encode(
            ITurnstile.WithdrawalMessage({
                asset: address(token), amount: AMOUNT, to: alice, salt: turnstile.hashWithdrawalAction(action)
            })
        );
        _deliver(HUB_CHAIN_ID, SPOKE, abi.encode(ITurnstile.ActionType.Withdrawal, body));

        assertEq(token.balanceOf(alice), AMOUNT, "not released on redelivery");
    }

    function test_handleReceivedMessage_CreditsDepositOnRedeliveryAfterDepotUnpause() public {
        MockERC20 token = spokeUsdg[SPOKE];
        vm.prank(PAUSER_ADDRESS);
        depot.pause();

        _deposit(alice, SPOKE, token, HUB_CHAIN_ID, AMOUNT);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        _relayMessages();

        assertEq(token.balanceOf(VAULT), AMOUNT, "spoke vault does not hold deposit");
        assertEq(_balance(HUB_CHAIN_ID, alice, SPOKE), 0, "credited while paused");

        vm.prank(ADMIN_MULTISIG);
        depot.unpause();
        _receiveFromSpoke(
            SPOKE,
            ITurnstile.ActionType.Deposit,
            abi.encode(
                ITurnstile.DepositMessage({
                    asset: address(token),
                    amount: AMOUNT,
                    fromAccountId: _account(SPOKE, alice),
                    toAccountId: _account(HUB_CHAIN_ID, alice),
                    facilitationFee: 0,
                    feeReceiverAccountId: bytes28(0),
                    salt: bytes32(0)
                })
            )
        );

        assertEq(_balance(HUB_CHAIN_ID, alice, SPOKE), AMOUNT, "not credited on redelivery");
    }

    function test_handleReceivedMessage_CreditsDepositAndFeeIfRecipientIsFrozen() public {
        uint256 fee = 1e6;
        MockERC20 token = spokeUsdg[SPOKE];
        vm.prank(PREDICATE_FREEZE_MANAGER);
        addressFreezeList.freeze(bob);

        vm.chainId(SPOKE);
        token.mint(alice, AMOUNT);
        vm.startPrank(alice);
        token.approve(address(spokeTurnstile[SPOKE]), AMOUNT);
        _dispatchOne(
            spokeTurnstile[SPOKE],
            ITurnstile.ActionType.Deposit,
            abi.encode(
                ITurnstile.DepositAction({
                    ownerChainId: SPOKE,
                    owner: alice,
                    asset: address(token),
                    amount: AMOUNT,
                    toChainId: HUB_CHAIN_ID,
                    to: bob,
                    facilitationFee: fee,
                    feeReceiverChainId: HUB_CHAIN_ID,
                    feeReceiver: SOLVER_ADDRESS,
                    deadline: type(uint256).max,
                    dependsOn: bytes32(0),
                    salt: bytes32(0),
                    permit: ITurnstile.Permit({ deadline: 0, v: 0, r: bytes32(0), s: bytes32(0) })
                })
            )
        );
        vm.stopPrank();
        _relayMessages();

        assertEq(_balance(HUB_CHAIN_ID, bob, SPOKE), AMOUNT - fee, "frozen recipient not credited less fee");
        assertEq(_balance(HUB_CHAIN_ID, SOLVER_ADDRESS, SPOKE), fee, "fee not paid to frozen recipient's facilitator");
    }

    function _requestHubChainWithdrawal(uint256 deadline) internal returns (ITurnstile.WithdrawalAction memory action) {
        _deposit(alice, HUB_CHAIN_ID, usdg, HUB_CHAIN_ID, AMOUNT);
        action = ITurnstile.WithdrawalAction({
            ownerChainId: HUB_CHAIN_ID,
            owner: alice,
            to: alice,
            assetChainId: HUB_CHAIN_ID,
            asset: address(usdg),
            amount: AMOUNT,
            deadline: deadline,
            partiallyFillable: false,
            dependsOn: bytes32(0),
            salt: bytes32(0)
        });
        vm.prank(alice);
        hubWarehouseConductor.requestWithdrawal(action);
        _advanceEpoch();

        vm.prank(VAULT);
        usdg.approve(address(turnstile), 0);
    }

}
