// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { SharedSetup } from "test/integration/SharedSetup.sol";
import { MockERC20 } from "lib/solady/test/utils/mocks/MockERC20.sol";
import { ITurnstile } from "src/interfaces/ITurnstile.sol";
import { IUserConductor } from "src/interfaces/IUserConductor.sol";
import { UserConductor } from "src/conductor/UserConductor.sol";

/// @dev A solver is paid for facilitating in one of two ways: a facilitationFee inside a DepositAction, or a separate
/// signed fee transfer whose dependsOn is the message hash of the action the user wants, so the fee can only execute
/// once that action has.
contract FacilitationFees is SharedSetup {

    uint64 constant SPOKE = ROBINHOOD_CHAIN_ID;
    uint256 constant AMOUNT = 100e6;
    uint256 constant FEE = 1e6;

    address alice;
    uint256 alicePk;
    address bob = makeAddr("bob");
    MockERC20 robinhoodUsdg;

    function setUp() public override {
        super.setUp();
        (alice, alicePk) = makeAddrAndKey("alice");
        robinhoodUsdg = spokeUsdg[SPOKE];
        _deposit(alice, SPOKE, robinhoodUsdg, HUB_CHAIN_ID, AMOUNT);
        _relayMessages();
        vm.chainId(HUB_CHAIN_ID);
    }

    // ========================================= DEPENDENT FEE =========================================

    function testWithdrawalWithDependentFee() public {
        (bytes memory withdrawal, bytes memory withdrawalSig, bytes32 withdrawalHash) = _withdrawal();
        (bytes memory fee, bytes memory feeSig) = _feeDependingOn(withdrawalHash);

        _facilitateTwo(ITurnstile.ActionType.Withdrawal, withdrawal, withdrawalSig, fee, feeSig);
        _relayMessages();

        assertEq(robinhoodUsdg.balanceOf(alice), AMOUNT - FEE, "alice withdrew to robinhood");
        assertEq(_balance(HUB_CHAIN_ID, alice, SPOKE), 0, "alice depot balance spent");
        assertEq(_balance(HUB_CHAIN_ID, SOLVER_ADDRESS, SPOKE), FEE, "solver paid fee");
    }

    function testTransferWithDependentFee() public {
        (bytes memory transfer, bytes memory transferSig, bytes32 transferHash) = _transferToBob();
        (bytes memory fee, bytes memory feeSig) = _feeDependingOn(transferHash);

        _facilitateTwo(ITurnstile.ActionType.Generic, transfer, transferSig, fee, feeSig);

        assertEq(_balance(HUB_CHAIN_ID, bob, SPOKE), AMOUNT - FEE, "bob received transfer");
        assertEq(_balance(HUB_CHAIN_ID, alice, SPOKE), 0, "alice depot balance spent");
        assertEq(_balance(HUB_CHAIN_ID, SOLVER_ADDRESS, SPOKE), FEE, "solver paid fee");
    }

    function testDependentFeeAloneReverts() public {
        (,, bytes32 withdrawalHash) = _withdrawal();
        (bytes memory fee, bytes memory feeSig) = _feeDependingOn(withdrawalHash);

        vm.expectRevert(ITurnstile.DependencyNotExecuted.selector);
        _facilitate(HUB_CHAIN_ID, ITurnstile.ActionType.Generic, fee, feeSig);
    }

    function testDependentFeeBeforeActionReverts() public {
        (bytes memory withdrawal, bytes memory withdrawalSig, bytes32 withdrawalHash) = _withdrawal();
        (bytes memory fee, bytes memory feeSig) = _feeDependingOn(withdrawalHash);

        ITurnstile.Action[] memory actions = new ITurnstile.Action[](2);
        actions[0] = _action(ITurnstile.ActionType.Generic, fee);
        actions[1] = _action(ITurnstile.ActionType.Withdrawal, withdrawal);
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = feeSig;
        signatures[1] = withdrawalSig;
        vm.prank(SOLVER_ADDRESS);
        vm.expectRevert(ITurnstile.DependencyNotExecuted.selector);
        turnstile.facilitate(actions, signatures);
    }

    function testDependentFeeCannotBeTakenTwice() public {
        (bytes memory withdrawal, bytes memory withdrawalSig, bytes32 withdrawalHash) = _withdrawal();
        (bytes memory fee, bytes memory feeSig) = _feeDependingOn(withdrawalHash);
        _deposit(alice, SPOKE, robinhoodUsdg, HUB_CHAIN_ID, FEE);
        _relayMessages();
        vm.chainId(HUB_CHAIN_ID);

        _facilitateTwo(ITurnstile.ActionType.Withdrawal, withdrawal, withdrawalSig, fee, feeSig);

        vm.expectRevert(ITurnstile.MessageReplay.selector);
        _facilitate(HUB_CHAIN_ID, ITurnstile.ActionType.Generic, fee, feeSig);
        assertEq(_balance(HUB_CHAIN_ID, SOLVER_ADDRESS, SPOKE), FEE, "fee taken once");
    }

    // ========================================= DEPOSIT FEE =========================================

    function testDepositFeeExceedingAmountReverts() public {
        ITurnstile.DepositAction memory action = _depositWithFee(AMOUNT + 1, SOLVER_ADDRESS);
        bytes memory signature = _signDeposit(action);
        vm.expectRevert(ITurnstile.FeeExceedsAmount.selector);
        _facilitate(SPOKE, ITurnstile.ActionType.Deposit, abi.encode(action), signature);
    }

    function testDepositFeeWithoutReceiverReverts() public {
        ITurnstile.DepositAction memory action = _depositWithFee(FEE, address(0));
        bytes memory signature = _signDeposit(action);
        vm.expectRevert(ITurnstile.InvalidAccount.selector);
        _facilitate(SPOKE, ITurnstile.ActionType.Deposit, abi.encode(action), signature);
    }

    // ========================================= HELPERS =========================================

    function _withdrawal() internal view returns (bytes memory data, bytes memory signature, bytes32 messageHash) {
        ITurnstile.WithdrawalAction memory action = ITurnstile.WithdrawalAction({
            ownerChainId: HUB_CHAIN_ID,
            owner: alice,
            to: alice,
            assetChainId: SPOKE,
            asset: address(robinhoodUsdg),
            amount: AMOUNT - FEE,
            deadline: type(uint256).max,
            partiallyFillable: false,
            dependsOn: bytes32(0),
            salt: bytes32(0)
        });
        bytes32 actionHash = turnstile.hashWithdrawalAction(action);
        bytes memory body = abi.encode(
            ITurnstile.WithdrawalMessage({
                asset: address(robinhoodUsdg), amount: AMOUNT - FEE, to: alice, salt: actionHash
            })
        );
        data = abi.encode(action);
        signature = _sign(alicePk, actionHash);
        messageHash = turnstile.digestMessage(HUB_CHAIN_ID, ITurnstile.ActionType.Withdrawal, body);
    }

    function _transferToBob() internal view returns (bytes memory data, bytes memory signature, bytes32 messageHash) {
        return _transferGeneric(bob, AMOUNT - FEE, bytes32(0));
    }

    function _feeDependingOn(bytes32 dependsOn) internal view returns (bytes memory data, bytes memory signature) {
        (data, signature,) = _transferGeneric(SOLVER_ADDRESS, FEE, dependsOn);
    }

    function _transferGeneric(
        address to,
        uint256 amount,
        bytes32 dependsOn
    )
        internal
        view
        returns (bytes memory data, bytes memory signature, bytes32 messageHash)
    {
        IUserConductor.TransferRequest memory request = IUserConductor.TransferRequest({
            ownerChainId: HUB_CHAIN_ID,
            owner: alice,
            toChainId: HUB_CHAIN_ID,
            to: to,
            assetChainId: SPOKE,
            asset: address(robinhoodUsdg),
            amount: amount,
            deadline: type(uint256).max,
            partiallyFillable: false,
            salt: bytes32(0)
        });
        ITurnstile.GenericAction memory action = ITurnstile.GenericAction({
            ownerChainId: HUB_CHAIN_ID,
            owner: alice,
            target: address(userConductor),
            data: abi.encodeCall(UserConductor.executeTransfer, (request)),
            deadline: type(uint256).max,
            dependsOn: dependsOn,
            salt: bytes32(0)
        });
        bytes memory body = abi.encode(
            ITurnstile.GenericMessage({
                sender: alice, target: action.target, data: action.data, deadline: action.deadline, salt: action.salt
            })
        );
        data = abi.encode(action);
        signature = _sign(alicePk, turnstile.hashGenericAction(action));
        messageHash = turnstile.digestMessage(HUB_CHAIN_ID, ITurnstile.ActionType.Generic, body);
    }

    function _facilitateTwo(
        ITurnstile.ActionType firstType,
        bytes memory first,
        bytes memory firstSig,
        bytes memory fee,
        bytes memory feeSig
    )
        internal
    {
        ITurnstile.Action[] memory actions = new ITurnstile.Action[](2);
        actions[0] = _action(firstType, first);
        actions[1] = _action(ITurnstile.ActionType.Generic, fee);
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = firstSig;
        signatures[1] = feeSig;
        vm.chainId(HUB_CHAIN_ID);
        vm.prank(SOLVER_ADDRESS);
        turnstile.facilitate(actions, signatures);
    }

    function _action(
        ITurnstile.ActionType actionType,
        bytes memory data
    )
        internal
        pure
        returns (ITurnstile.Action memory)
    {
        return ITurnstile.Action({ actionType: actionType, data: data, bridgeFee: 0, messageGas: MESSAGE_GAS });
    }

    function _depositWithFee(uint256 fee, address feeReceiver) internal returns (ITurnstile.DepositAction memory) {
        robinhoodUsdg.mint(alice, AMOUNT);
        vm.prank(alice);
        robinhoodUsdg.approve(address(spokeTurnstile[SPOKE]), AMOUNT);
        return ITurnstile.DepositAction({
            ownerChainId: SPOKE,
            owner: alice,
            asset: address(robinhoodUsdg),
            amount: AMOUNT,
            toChainId: HUB_CHAIN_ID,
            to: alice,
            facilitationFee: fee,
            feeReceiverChainId: HUB_CHAIN_ID,
            feeReceiver: feeReceiver,
            deadline: type(uint256).max,
            dependsOn: bytes32(0),
            salt: bytes32(0),
            permit: ITurnstile.Permit({ deadline: 0, v: 0, r: bytes32(0), s: bytes32(0) })
        });
    }

    function _signDeposit(ITurnstile.DepositAction memory action) internal returns (bytes memory) {
        vm.chainId(SPOKE);
        return _sign(alicePk, spokeTurnstile[SPOKE].hashDepositAction(action));
    }

}
