// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { SharedSetup } from "test/integration/SharedSetup.sol";
import { MockERC20 } from "lib/solady/test/utils/mocks/MockERC20.sol";
import { ITurnstile } from "src/interfaces/ITurnstile.sol";
import { ISpotSwapConductor } from "src/interfaces/ISpotSwapConductor.sol";
import { ISwapConductor } from "src/interfaces/ISwapConductor.sol";
import { Turnstile } from "src/turnstile/Turnstile.sol";
import { SpotSwapConductor } from "src/conductor/SpotSwapConductor.sol";
import { SwapConductor } from "src/conductor/SwapConductor.sol";

contract SpotSwapHappyPaths is SharedSetup {

    uint64 constant SPOKE = ROBINHOOD_CHAIN_ID;
    uint256 constant AMOUNT = 100e6;
    uint256 constant HUB_CONTRACT_AMOUNT = 350e6;

    address[6] eoas;
    uint256[6] eoaPks;
    address hubContract0 = makeAddr("hubContract0");
    address hubContract1 = makeAddr("hubContract1");
    address spokeContract0 = makeAddr("spokeContract0");
    address spokeContract1 = makeAddr("spokeContract1");

    function setUp() public override {
        super.setUp();
        (eoas[0], eoaPks[0]) = makeAddrAndKey("eoa0");
        (eoas[1], eoaPks[1]) = makeAddrAndKey("eoa1");
        (eoas[2], eoaPks[2]) = makeAddrAndKey("eoa2");
        (eoas[3], eoaPks[3]) = makeAddrAndKey("eoa3");
        (eoas[4], eoaPks[4]) = makeAddrAndKey("eoa4");
        (eoas[5], eoaPks[5]) = makeAddrAndKey("eoa5");
    }

    /// @dev Scenario: 10 users trade USDG <> USDC 1:1 in one solver batch. USDG is deposited on Robinhood, USDC on
    /// the hub.
    /// - 6 EOAs deposit 100 USDG on Robinhood into their hub accounts and sell it for USDC. They act only through
    ///   signatures: signed orders, and a cancellation the solver facilitates. Hub accounts are used because a
    ///   facilitated action is attributed to the signer's hub account.
    /// - 2 spoke contract users never sign. They deposit 100 USDG on Robinhood into Robinhood accounts, pre-approve
    ///   with a Generic message from Robinhood, and sell it for USDC.
    /// - 2 hub contract users never sign. They deposit 350 USDC on the hub, pre-approve directly, and sell it for USDG.
    /// Cancellation timeline: eoa5 cancels at t2, the solver locks the batch at t3, and hubContract0 cancels at t4.
    /// The solver decides which cancels to respect; here it respects eoa5's, made before the lock, and leaves the
    /// order out. eoa5's cancel goes through the solver, so it is effective immediately and the order cannot be
    /// settled in the next epoch either. hubContract0's cancel comes after the lock and is not facilitated, so it only
    /// takes effect from the next epoch and cannot pull the order out of the locked batch; the order is still filled.
    /// The batch trades 700 USDG (5 EOAs + 2 spoke contracts) for 700 USDC (2 hub contracts).
    function testSolverSettlesBatchDespiteLateCancellation() public {
        MockERC20 robinhoodUsdg = spokeUsdg[SPOKE];

        _deposit(eoas[0], SPOKE, robinhoodUsdg, HUB_CHAIN_ID, AMOUNT);
        _deposit(eoas[1], SPOKE, robinhoodUsdg, HUB_CHAIN_ID, AMOUNT);
        _deposit(eoas[2], SPOKE, robinhoodUsdg, HUB_CHAIN_ID, AMOUNT);
        _deposit(eoas[3], SPOKE, robinhoodUsdg, HUB_CHAIN_ID, AMOUNT);
        _deposit(eoas[4], SPOKE, robinhoodUsdg, HUB_CHAIN_ID, AMOUNT);
        _deposit(eoas[5], SPOKE, robinhoodUsdg, HUB_CHAIN_ID, AMOUNT);
        _deposit(spokeContract0, SPOKE, robinhoodUsdg, SPOKE, AMOUNT);
        _deposit(spokeContract1, SPOKE, robinhoodUsdg, SPOKE, AMOUNT);
        _deposit(hubContract0, HUB_CHAIN_ID, usdc, HUB_CHAIN_ID, HUB_CONTRACT_AMOUNT);
        _deposit(hubContract1, HUB_CHAIN_ID, usdc, HUB_CHAIN_ID, HUB_CONTRACT_AMOUNT);
        _relayMessages();

        ISpotSwapConductor.OrderFill[] memory orderFills = new ISpotSwapConductor.OrderFill[](9);
        orderFills[0] = _signedUsdgForUsdc(0);
        orderFills[1] = _signedUsdgForUsdc(1);
        orderFills[2] = _signedUsdgForUsdc(2);
        orderFills[3] = _signedUsdgForUsdc(3);
        orderFills[4] = _signedUsdgForUsdc(4);
        orderFills[5] = _preApprovedFromSpoke(spokeContract0);
        orderFills[6] = _preApprovedFromSpoke(spokeContract1);
        orderFills[7] = _preApprovedOnHub(hubContract0);
        orderFills[8] = _preApprovedOnHub(hubContract1);
        _relayMessages();

        ISpotSwapConductor.OrderFill memory cancelledFill = _signedUsdgForUsdc(5);
        bytes32 cancelledHash = spotSwapConductor.hashOrder(cancelledFill.order);
        _facilitatedCancel(5, cancelledHash);

        uint256 epoch = depot.settlementEpoch();
        bytes32 lateCancelHash = spotSwapConductor.hashOrder(orderFills[7].order);
        vm.prank(hubContract0);
        spotSwapConductor.requestOrderCancellation(lateCancelHash);
        assertEq(
            spotSwapConductor.cancelledFrom(_account(HUB_CHAIN_ID, hubContract0), lateCancelHash),
            epoch + 1,
            "late cancellation only effective next epoch"
        );

        vm.prank(SOLVER_ADDRESS);
        spotSwapConductor.settle(epoch, orderFills, new ISpotSwapConductor.Fee[](0));

        bytes28 usdgId = _account(SPOKE, address(robinhoodUsdg));
        bytes28 usdcId = _account(HUB_CHAIN_ID, address(usdc));
        assertEq(depot.balanceOf(_account(HUB_CHAIN_ID, eoas[0]), usdgId), 0, "eoa0 sold usdg");
        assertEq(depot.balanceOf(_account(HUB_CHAIN_ID, eoas[0]), usdcId), AMOUNT, "eoa0 bought usdc");
        assertEq(depot.balanceOf(_account(HUB_CHAIN_ID, eoas[1]), usdgId), 0, "eoa1 sold usdg");
        assertEq(depot.balanceOf(_account(HUB_CHAIN_ID, eoas[1]), usdcId), AMOUNT, "eoa1 bought usdc");
        assertEq(depot.balanceOf(_account(HUB_CHAIN_ID, eoas[2]), usdgId), 0, "eoa2 sold usdg");
        assertEq(depot.balanceOf(_account(HUB_CHAIN_ID, eoas[2]), usdcId), AMOUNT, "eoa2 bought usdc");
        assertEq(depot.balanceOf(_account(HUB_CHAIN_ID, eoas[3]), usdgId), 0, "eoa3 sold usdg");
        assertEq(depot.balanceOf(_account(HUB_CHAIN_ID, eoas[3]), usdcId), AMOUNT, "eoa3 bought usdc");
        assertEq(depot.balanceOf(_account(HUB_CHAIN_ID, eoas[4]), usdgId), 0, "eoa4 sold usdg");
        assertEq(depot.balanceOf(_account(HUB_CHAIN_ID, eoas[4]), usdcId), AMOUNT, "eoa4 bought usdc");
        assertEq(depot.balanceOf(_account(SPOKE, spokeContract0), usdgId), 0, "spokeContract0 sold usdg");
        assertEq(depot.balanceOf(_account(SPOKE, spokeContract0), usdcId), AMOUNT, "spokeContract0 bought usdc");
        assertEq(depot.balanceOf(_account(SPOKE, spokeContract1), usdgId), 0, "spokeContract1 sold usdg");
        assertEq(depot.balanceOf(_account(SPOKE, spokeContract1), usdcId), AMOUNT, "spokeContract1 bought usdc");
        assertEq(depot.balanceOf(_account(HUB_CHAIN_ID, hubContract0), usdcId), 0, "hubContract0 sold usdc");
        assertEq(
            depot.balanceOf(_account(HUB_CHAIN_ID, hubContract0), usdgId),
            HUB_CONTRACT_AMOUNT,
            "hubContract0 bought usdg despite late cancellation"
        );
        assertEq(depot.balanceOf(_account(HUB_CHAIN_ID, hubContract1), usdcId), 0, "hubContract1 sold usdc");
        assertEq(
            depot.balanceOf(_account(HUB_CHAIN_ID, hubContract1), usdgId),
            HUB_CONTRACT_AMOUNT,
            "hubContract1 bought usdg"
        );

        assertEq(depot.balanceOf(_account(HUB_CHAIN_ID, eoas[5]), usdgId), AMOUNT, "cancelled eoa5 kept usdg");
        assertEq(depot.balanceOf(_account(HUB_CHAIN_ID, eoas[5]), usdcId), 0, "cancelled eoa5 bought nothing");
        assertEq(spotSwapConductor.filledAmount(cancelledHash), 0, "cancelled order unfilled");

        ISpotSwapConductor.OrderFill[] memory retry = new ISpotSwapConductor.OrderFill[](1);
        retry[0] = cancelledFill;
        uint256 nextEpoch = depot.settlementEpoch();
        vm.prank(SOLVER_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(ISwapConductor.Cancelled.selector, cancelledHash));
        spotSwapConductor.settle(nextEpoch, retry, new ISpotSwapConductor.Fee[](0));
    }

    function _deposit(address user, uint64 chainId, MockERC20 token, uint64 toChainId, uint256 amount) internal {
        vm.chainId(chainId);
        Turnstile chainTurnstile = _turnstile(chainId);
        token.mint(user, amount);
        vm.startPrank(user);
        token.approve(address(chainTurnstile), amount);
        _dispatchOne(
            chainTurnstile,
            ITurnstile.ActionType.Deposit,
            abi.encode(
                ITurnstile.DepositAction({
                    ownerChainId: chainId,
                    owner: user,
                    asset: address(token),
                    amount: amount,
                    toChainId: toChainId,
                    to: user,
                    facilitationFee: 0,
                    feeReceiverChainId: 0,
                    feeReceiver: address(0),
                    deadline: type(uint256).max,
                    dependsOn: bytes32(0),
                    salt: bytes32(0),
                    permit: ITurnstile.Permit({ deadline: 0, v: 0, r: bytes32(0), s: bytes32(0) })
                })
            )
        );
        vm.stopPrank();
    }

    function _signedUsdgForUsdc(uint256 i) internal returns (ISpotSwapConductor.OrderFill memory) {
        vm.chainId(HUB_CHAIN_ID);
        ISpotSwapConductor.Order memory order = _usdgForUsdc(HUB_CHAIN_ID, eoas[i]);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(eoaPks[i], spotSwapConductor.hashOrder(order));
        return _orderFill(order, abi.encodePacked(r, s, v));
    }

    function _preApprovedFromSpoke(address user) internal returns (ISpotSwapConductor.OrderFill memory) {
        ISpotSwapConductor.Order memory order = _usdgForUsdc(SPOKE, user);
        vm.chainId(SPOKE);
        vm.prank(user);
        _dispatchOne(
            spokeTurnstile[SPOKE],
            ITurnstile.ActionType.Generic,
            abi.encode(
                ITurnstile.GenericAction({
                    ownerChainId: SPOKE,
                    owner: user,
                    target: address(spotSwapConductor),
                    data: abi.encodeCall(SpotSwapConductor.preApprove, (order)),
                    deadline: type(uint256).max,
                    dependsOn: bytes32(0),
                    salt: bytes32(0)
                })
            )
        );
        vm.chainId(HUB_CHAIN_ID);
        return _orderFill(order, "");
    }

    function _preApprovedOnHub(address user) internal returns (ISpotSwapConductor.OrderFill memory) {
        vm.chainId(HUB_CHAIN_ID);
        ISpotSwapConductor.Order memory order = ISpotSwapConductor.Order({
            ownerChainId: HUB_CHAIN_ID,
            owner: user,
            sellTokenChainId: HUB_CHAIN_ID,
            sellToken: address(usdc),
            buyTokenChainId: SPOKE,
            buyToken: address(spokeUsdg[SPOKE]),
            sellAmount: HUB_CONTRACT_AMOUNT,
            buyAmount: HUB_CONTRACT_AMOUNT,
            receiverChainId: HUB_CHAIN_ID,
            receiver: user,
            expiresAt: type(uint256).max,
            partiallyFillable: false,
            salt: bytes32(0)
        });
        vm.prank(user);
        spotSwapConductor.preApprove(order);
        return _orderFill(order, "");
    }

    function _facilitatedCancel(uint256 i, bytes32 orderHash) internal {
        vm.chainId(HUB_CHAIN_ID);
        ITurnstile.GenericAction memory action = ITurnstile.GenericAction({
            ownerChainId: HUB_CHAIN_ID,
            owner: eoas[i],
            target: address(spotSwapConductor),
            data: abi.encodeCall(SwapConductor.requestOrderCancellation, (orderHash)),
            deadline: type(uint256).max,
            dependsOn: bytes32(0),
            salt: bytes32(0)
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(eoaPks[i], turnstile.hashGenericAction(action));
        _facilitate(HUB_CHAIN_ID, ITurnstile.ActionType.Generic, abi.encode(action), abi.encodePacked(r, s, v));
    }

    function _usdgForUsdc(uint64 ownerChainId, address owner) internal view returns (ISpotSwapConductor.Order memory) {
        return ISpotSwapConductor.Order({
            ownerChainId: ownerChainId,
            owner: owner,
            sellTokenChainId: SPOKE,
            sellToken: address(spokeUsdg[SPOKE]),
            buyTokenChainId: HUB_CHAIN_ID,
            buyToken: address(usdc),
            sellAmount: AMOUNT,
            buyAmount: AMOUNT,
            receiverChainId: ownerChainId,
            receiver: owner,
            expiresAt: type(uint256).max,
            partiallyFillable: false,
            salt: bytes32(0)
        });
    }

    function _orderFill(
        ISpotSwapConductor.Order memory order,
        bytes memory signature
    )
        internal
        pure
        returns (ISpotSwapConductor.OrderFill memory)
    {
        return ISpotSwapConductor.OrderFill({
            order: order,
            signature: signature,
            fill: ISpotSwapConductor.Fill({ sellFilled: order.sellAmount, buyFilled: order.buyAmount })
        });
    }

}
