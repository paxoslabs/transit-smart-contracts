// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { SharedSetup } from "test/integration/SharedSetup.sol";
import { MockERC20 } from "lib/solady/test/utils/mocks/MockERC20.sol";
import { ITurnstile } from "src/interfaces/ITurnstile.sol";
import { IUserConductor } from "src/interfaces/IUserConductor.sol";
import { Turnstile } from "src/turnstile/Turnstile.sol";
import { UserConductor } from "src/conductor/UserConductor.sol";

contract MessageRetry is SharedSetup {

    uint64 constant SPOKE = ROBINHOOD_CHAIN_ID;
    uint256 constant AMOUNT = 100e6;

    address alice;
    uint256 alicePk;
    address bob = makeAddr("bob");

    function setUp() public override {
        super.setUp();
        (alice, alicePk) = makeAddrAndKey("alice");
    }

    function testWithdrawalFailedOnSpokeIsRetried() public {
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
        bytes memory body = abi.encode(
            ITurnstile.WithdrawalMessage({
                asset: address(token), amount: AMOUNT, to: alice, salt: turnstile.hashWithdrawalAction(action)
            })
        );
        // Fails on the spoke: withdrawals are released via transferFrom(VAULT), whose allowance was revoked above.
        _relayMessages();

        bytes32 messageHash = spoke.digestMessage(HUB_CHAIN_ID, ITurnstile.ActionType.Withdrawal, body);
        assertEq(_balance(HUB_CHAIN_ID, alice, SPOKE), 0, "burned on hub");
        assertEq(token.balanceOf(alice), 0, "nothing released while vault allowance is missing");
        assertEq(uint8(spoke.messageStatus(messageHash)), uint8(ITurnstile.MessageStatus.Failed), "marked failed");

        vm.prank(VAULT);
        token.approve(address(spoke), type(uint256).max);
        vm.chainId(SPOKE);
        _adminCall(
            spokeAccessManager[SPOKE],
            address(spoke),
            abi.encodeCall(Turnstile.retry, (HUB_CHAIN_ID, ITurnstile.ActionType.Withdrawal, body))
        );

        assertEq(token.balanceOf(alice), AMOUNT, "released on retry");
        assertEq(uint8(spoke.messageStatus(messageHash)), uint8(ITurnstile.MessageStatus.Executed), "marked executed");
    }

    function testHubChainWithdrawalFailedReleaseConsumesRequest() public {
        (bytes memory body, bytes32 requestId) = _failHubChainWithdrawal();

        bytes32 messageHash = turnstile.digestMessage(HUB_CHAIN_ID, ITurnstile.ActionType.Withdrawal, body);
        assertEq(
            hubWarehouseConductor.requestEffectiveAtEpoch(_hubAccount(alice), requestId),
            hubWarehouseConductor.EXECUTED(),
            "request not consumed"
        );
        (uint256 effective, uint256 pending,) = depot.reservation(_hubAccount(alice), _asset(HUB_CHAIN_ID));
        assertEq(effective, 0, "effective reservation not released");
        assertEq(pending, 0, "pending reservation not released");
        assertEq(_balance(HUB_CHAIN_ID, alice, HUB_CHAIN_ID), 0, "not burned on hub");
        assertEq(usdg.balanceOf(VAULT), AMOUNT, "vault released funds");
        assertEq(usdg.balanceOf(alice), 0, "alice paid while vault allowance is missing");
        assertEq(
            uint8(turnstile.messageStatus(messageHash)), uint8(ITurnstile.MessageStatus.Failed), "not marked failed"
        );
    }

    function testHubChainWithdrawalFailedReleaseIsRetried() public {
        (bytes memory body,) = _failHubChainWithdrawal();

        vm.prank(VAULT);
        usdg.approve(address(turnstile), type(uint256).max);
        _adminCall(
            accessManager,
            address(turnstile),
            abi.encodeCall(Turnstile.retry, (HUB_CHAIN_ID, ITurnstile.ActionType.Withdrawal, body))
        );

        bytes32 messageHash = turnstile.digestMessage(HUB_CHAIN_ID, ITurnstile.ActionType.Withdrawal, body);
        assertEq(usdg.balanceOf(alice), AMOUNT, "not released on retry");
        assertEq(
            uint8(turnstile.messageStatus(messageHash)), uint8(ITurnstile.MessageStatus.Executed), "not marked executed"
        );
    }

    function testDepositArrivingWhileDepotPausedIsRetried() public {
        MockERC20 token = spokeUsdg[SPOKE];
        vm.prank(PAUSER_ADDRESS);
        depot.pause();

        _deposit(alice, SPOKE, token, HUB_CHAIN_ID, AMOUNT);
        _relayMessages();

        bytes memory body = abi.encode(
            ITurnstile.DepositMessage({
                asset: address(token),
                amount: AMOUNT,
                fromAccountId: _account(SPOKE, alice),
                toAccountId: _account(HUB_CHAIN_ID, alice),
                facilitationFee: 0,
                feeReceiverAccountId: bytes28(0),
                salt: bytes32(0)
            })
        );
        bytes32 messageHash = turnstile.digestMessage(SPOKE, ITurnstile.ActionType.Deposit, body);
        assertEq(token.balanceOf(VAULT), AMOUNT, "spoke vault holds deposit");
        assertEq(_balance(HUB_CHAIN_ID, alice, SPOKE), 0, "not credited while paused");
        assertEq(uint8(turnstile.messageStatus(messageHash)), uint8(ITurnstile.MessageStatus.Failed), "marked failed");

        vm.chainId(HUB_CHAIN_ID);
        vm.prank(ADMIN_MULTISIG);
        depot.unpause();
        _adminCall(
            accessManager,
            address(turnstile),
            abi.encodeCall(Turnstile.retry, (SPOKE, ITurnstile.ActionType.Deposit, body))
        );

        assertEq(_balance(HUB_CHAIN_ID, alice, SPOKE), AMOUNT, "credited on retry");
    }

    function testDepositFeeFromFrozenRecipientIsRetried() public {
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

        bytes memory body = abi.encode(
            ITurnstile.DepositMessage({
                asset: address(token),
                amount: AMOUNT,
                fromAccountId: _account(SPOKE, alice),
                toAccountId: _account(HUB_CHAIN_ID, bob),
                facilitationFee: fee,
                feeReceiverAccountId: _account(HUB_CHAIN_ID, SOLVER_ADDRESS),
                salt: bytes32(0)
            })
        );
        bytes32 messageHash = turnstile.digestMessage(SPOKE, ITurnstile.ActionType.Deposit, body);
        assertEq(_balance(HUB_CHAIN_ID, bob, SPOKE), 0, "frozen recipient not credited");
        assertEq(uint8(turnstile.messageStatus(messageHash)), uint8(ITurnstile.MessageStatus.Failed), "marked failed");

        vm.prank(PREDICATE_FREEZE_MANAGER);
        addressFreezeList.unfreeze(bob);
        _adminCall(
            accessManager,
            address(turnstile),
            abi.encodeCall(Turnstile.retry, (SPOKE, ITurnstile.ActionType.Deposit, body))
        );

        assertEq(_balance(HUB_CHAIN_ID, bob, SPOKE), AMOUNT - fee, "recipient credited less fee on retry");
        assertEq(_balance(HUB_CHAIN_ID, SOLVER_ADDRESS, SPOKE), fee, "fee paid on retry");
    }

    function testExpiredGenericStaysFailedAfterRetry() public {
        IUserConductor.TransferRequest memory request = IUserConductor.TransferRequest({
            ownerChainId: SPOKE,
            owner: alice,
            toChainId: HUB_CHAIN_ID,
            to: bob,
            assetChainId: SPOKE,
            asset: address(spokeUsdg[SPOKE]),
            amount: AMOUNT,
            deadline: type(uint256).max,
            partiallyFillable: false,
            salt: bytes32(0)
        });
        ITurnstile.GenericMessage memory message = ITurnstile.GenericMessage({
            sender: alice,
            target: address(userConductor),
            data: abi.encodeCall(UserConductor.requestTransfer, (request)),
            deadline: block.timestamp + 1 hours,
            salt: bytes32(0)
        });

        vm.chainId(SPOKE);
        vm.prank(alice);
        _dispatchOne(
            spokeTurnstile[SPOKE],
            ITurnstile.ActionType.Generic,
            abi.encode(
                ITurnstile.GenericAction({
                    ownerChainId: SPOKE,
                    owner: alice,
                    target: message.target,
                    data: message.data,
                    deadline: message.deadline,
                    dependsOn: bytes32(0),
                    salt: bytes32(0)
                })
            )
        );
        vm.warp(block.timestamp + 2 hours);
        _relayMessages();

        bytes memory body = abi.encode(message);
        bytes32 messageHash = turnstile.digestMessage(SPOKE, ITurnstile.ActionType.Generic, body);
        bytes32 requestId = userConductor.digestTransferRequest(request);
        assertEq(uint8(turnstile.messageStatus(messageHash)), uint8(ITurnstile.MessageStatus.Failed), "marked failed");

        vm.chainId(HUB_CHAIN_ID);
        _adminCall(
            accessManager,
            address(turnstile),
            abi.encodeCall(Turnstile.retry, (SPOKE, ITurnstile.ActionType.Generic, body))
        );

        assertEq(uint8(turnstile.messageStatus(messageHash)), uint8(ITurnstile.MessageStatus.Failed), "still failed");
        assertEq(userConductor.requestEffectiveAtEpoch(_account(SPOKE, alice), requestId), 0, "request never recorded");
    }

    function _failHubChainWithdrawal() internal returns (bytes memory body, bytes32 requestId) {
        _deposit(alice, HUB_CHAIN_ID, usdg, HUB_CHAIN_ID, AMOUNT);
        ITurnstile.WithdrawalAction memory action = ITurnstile.WithdrawalAction({
            ownerChainId: HUB_CHAIN_ID,
            owner: alice,
            to: alice,
            assetChainId: HUB_CHAIN_ID,
            asset: address(usdg),
            amount: AMOUNT,
            deadline: type(uint256).max,
            partiallyFillable: false,
            dependsOn: bytes32(0),
            salt: bytes32(0)
        });
        vm.prank(alice);
        hubWarehouseConductor.requestWithdrawal(action);
        _advanceEpoch();

        vm.prank(VAULT);
        usdg.approve(address(turnstile), 0);
        vm.prank(alice);
        _dispatchOne(turnstile, ITurnstile.ActionType.Withdrawal, abi.encode(action));

        requestId = hubWarehouseConductor.hashWithdrawalAction(action);
        body = abi.encode(
            ITurnstile.WithdrawalMessage({
                asset: address(usdg), amount: AMOUNT, to: alice, salt: turnstile.hashWithdrawalAction(action)
            })
        );
    }

}
