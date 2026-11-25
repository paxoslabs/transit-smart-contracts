// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { Test, Vm } from "forge-std/Test.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Depot } from "src/depot/Depot.sol";
import { IDepot } from "src/interfaces/IDepot.sol";
import { AddressFreezeList } from "src/AddressFreezeList.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { Roles } from "src/helpers/Roles.sol";
import { Typehashes } from "src/helpers/Typehashes.sol";
import { TransitAddressLib } from "src/helpers/TransitAddressLib.sol";
import { SpotSwapConductor } from "src/conductor/SpotSwapConductor.sol";
import { ISpotSwapConductor } from "src/interfaces/ISpotSwapConductor.sol";
import { ISwapConductor } from "src/interfaces/ISwapConductor.sol";
import { FACILITATED_FLAG } from "src/conductor/ConductorGatedByTurnstile.sol";

contract SpotSwapConductorUnitTest is Test {

    uint256 constant OWNER_A_PK = 0xA11CE;
    uint256 constant OWNER_B_PK = 0xB0B;
    uint64 constant REMOTE_CHAIN = 1;

    address ownerA = vm.addr(OWNER_A_PK);
    address ownerB = vm.addr(OWNER_B_PK);
    address receiverA = makeAddr("receiverA");
    address receiverB = makeAddr("receiverB");
    address admin = makeAddr("admin");
    address turnstile = makeAddr("turnstile");
    address seeder = makeAddr("seeder");
    address solver = makeAddr("solver");
    address stranger = makeAddr("stranger");
    address freezeManager = makeAddr("freezeManager");
    address tokenA = makeAddr("tokenA");
    address tokenB = makeAddr("tokenB");

    AccessManager authority;
    AddressFreezeList freezeList;
    Depot depot;
    SpotSwapConductor conductor;

    bytes28 SURPLUS;
    bytes28 ACCOUNT_A;
    bytes28 ACCOUNT_B;
    bytes28 ASSET_A;
    bytes28 ASSET_B;

    function setUp() public {
        vm.warp(10_000);
        authority = new AccessManager(admin);
        freezeList = new AddressFreezeList(address(authority));
        depot = new Depot(address(authority), freezeList);

        SURPLUS = TransitAddressLib.formatTransitAddress(uint64(block.chainid), makeAddr("surplus"));
        ACCOUNT_A = TransitAddressLib.formatTransitAddress(uint64(block.chainid), ownerA);
        ACCOUNT_B = TransitAddressLib.formatTransitAddress(uint64(block.chainid), ownerB);
        ASSET_A = TransitAddressLib.formatTransitAddress(uint64(block.chainid), tokenA);
        ASSET_B = TransitAddressLib.formatTransitAddress(uint64(block.chainid), tokenB);

        conductor = new SpotSwapConductor(address(authority), address(depot), SURPLUS, turnstile);

        bytes4[] memory depotSelectors = new bytes4[](3);
        depotSelectors[0] = Depot.transferAmong.selector;
        depotSelectors[1] = Depot.mint.selector;
        depotSelectors[2] = Depot.advanceEpoch.selector;

        vm.startPrank(admin);
        authority.setTargetFunctionRole(address(depot), depotSelectors, Roles.CONDUCTOR);
        authority.setTargetFunctionRole(address(conductor), _selectors(SpotSwapConductor.settle.selector), Roles.SOLVER);
        authority.grantRole(Roles.CONDUCTOR, address(conductor), 0);
        authority.grantRole(Roles.CONDUCTOR, seeder, 0);
        authority.grantRole(Roles.SOLVER, solver, 0);
        authority.setTargetFunctionRole(
            address(freezeList), _selectors(AddressFreezeList.freeze.selector), Roles.FREEZE_MANAGER
        );
        authority.grantRole(Roles.FREEZE_MANAGER, freezeManager, 0);
        vm.stopPrank();
    }

    function _selectors(bytes4 a) internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = a;
    }

    function _seed(bytes28 accountId, bytes28 assetId, uint256 amount) internal {
        vm.prank(seeder);
        depot.mint(accountId, assetId, amount);
    }

    function _freeze(address account) internal {
        vm.prank(freezeManager);
        freezeList.freeze(account);
    }

    function _orderA() internal view returns (ISpotSwapConductor.Order memory o) {
        o.ownerChainId = uint64(block.chainid);
        o.owner = ownerA;
        o.sellTokenChainId = uint64(block.chainid);
        o.sellToken = tokenA;
        o.buyTokenChainId = uint64(block.chainid);
        o.buyToken = tokenB;
        o.sellAmount = 100;
        o.buyAmount = 50;
        o.receiverChainId = uint64(block.chainid);
        o.receiver = receiverA;
        o.expiresAt = block.timestamp + 1 hours;
        o.partiallyFillable = true;
        o.salt = bytes32(uint256(1));
    }

    function _orderB() internal view returns (ISpotSwapConductor.Order memory o) {
        o.ownerChainId = uint64(block.chainid);
        o.owner = ownerB;
        o.sellTokenChainId = uint64(block.chainid);
        o.sellToken = tokenB;
        o.buyTokenChainId = uint64(block.chainid);
        o.buyToken = tokenA;
        o.sellAmount = 50;
        o.buyAmount = 100;
        o.receiverChainId = uint64(block.chainid);
        o.receiver = receiverB;
        o.expiresAt = block.timestamp + 1 hours;
        o.partiallyFillable = true;
        o.salt = bytes32(uint256(2));
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _orderFill(
        ISpotSwapConductor.Order memory order,
        uint256 pk,
        uint256 sellFilled,
        uint256 buyFilled
    )
        internal
        view
        returns (ISpotSwapConductor.OrderFill memory f)
    {
        f.order = order;
        f.signature = pk == 0 ? bytes("") : _sign(pk, conductor.hashOrder(order));
        f.fill = ISpotSwapConductor.Fill(sellFilled, buyFilled);
    }

    function _fills(ISpotSwapConductor.OrderFill memory a)
        internal
        pure
        returns (ISpotSwapConductor.OrderFill[] memory fills)
    {
        fills = new ISpotSwapConductor.OrderFill[](1);
        fills[0] = a;
    }

    function _fills(
        ISpotSwapConductor.OrderFill memory a,
        ISpotSwapConductor.OrderFill memory b
    )
        internal
        pure
        returns (ISpotSwapConductor.OrderFill[] memory fills)
    {
        fills = new ISpotSwapConductor.OrderFill[](2);
        fills[0] = a;
        fills[1] = b;
    }

    function _noFees() internal pure returns (ISpotSwapConductor.Fee[] memory) {
        return new ISpotSwapConductor.Fee[](0);
    }

    function _fees(ISpotSwapConductor.Fee memory a) internal pure returns (ISpotSwapConductor.Fee[] memory fees) {
        fees = new ISpotSwapConductor.Fee[](1);
        fees[0] = a;
    }

    function _settle(ISpotSwapConductor.OrderFill[] memory fills, ISpotSwapConductor.Fee[] memory fees) internal {
        _settleAt(depot.settlementEpoch(), fills, fees);
    }

    function _settleAt(
        uint256 epoch,
        ISpotSwapConductor.OrderFill[] memory fills,
        ISpotSwapConductor.Fee[] memory fees
    )
        internal
    {
        vm.prank(solver);
        conductor.settle(epoch, fills, fees);
    }

    function _relay(bytes memory data, bytes28 accountId, bool facilitated) internal {
        vm.prank(turnstile);
        (bool ok, bytes memory result) =
            address(conductor).call(abi.encodePacked(data, accountId, facilitated ? FACILITATED_FLAG : bytes4(0)));
        if (!ok) {
            assembly { revert(add(result, 32), mload(result)) }
        }
    }

    function test_constructor_SetsAuthority() public view {
        assertEq(conductor.authority(), address(authority), "authority not set");
    }

    function test_constructor_SetsDepot() public view {
        assertEq(conductor.DEPOT(), address(depot), "DEPOT not set");
    }

    function test_constructor_SetsSurplusRecipientAccountId() public view {
        assertEq(conductor.SURPLUS_RECIPIENT_ACCOUNT_ID(), SURPLUS, "SURPLUS_RECIPIENT_ACCOUNT_ID not set");
    }

    function test_constructor_SetsTurnstile() public view {
        assertEq(conductor.TURNSTILE(), turnstile, "TURNSTILE not set");
    }

    function test_DOMAIN_SEPARATOR_ReturnsEip712DomainSeparator() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Transit SpotSwapConductor"),
                keccak256("1"),
                block.chainid,
                address(conductor)
            )
        );
        assertEq(conductor.DOMAIN_SEPARATOR(), expected, "domain separator wrong");
    }

    function test_DEPOT_ReturnsDepot() public view {
        assertEq(conductor.DEPOT(), address(depot), "DEPOT not returned");
    }

    function test_SURPLUS_RECIPIENT_ACCOUNT_ID_ReturnsSurplusRecipientAccountId() public view {
        assertEq(conductor.SURPLUS_RECIPIENT_ACCOUNT_ID(), SURPLUS, "surplus recipient not returned");
    }

    function test_filledAmount_ReturnsZeroForUnfilledOrder() public view {
        assertEq(conductor.filledAmount(conductor.hashOrder(_orderA())), 0, "unfilled order not zero");
    }

    function test_filledAmount_ReturnsSellAmountFilledSoFar() public {
        ISpotSwapConductor.Order memory a = _orderA();
        ISpotSwapConductor.Order memory b = _orderB();
        _seed(ACCOUNT_A, ASSET_A, 100);
        _seed(ACCOUNT_B, ASSET_B, 50);
        _settle(_fills(_orderFill(a, OWNER_A_PK, 40, 20), _orderFill(b, OWNER_B_PK, 20, 40)), _noFees());
        assertEq(conductor.filledAmount(conductor.hashOrder(a)), 40, "filled amount wrong");
    }

    function test_cancelledFrom_ReturnsZeroForUncancelledOrder() public view {
        assertEq(conductor.cancelledFrom(ACCOUNT_A, conductor.hashOrder(_orderA())), 0, "uncancelled order not zero");
    }

    function test_cancelledFrom_ReturnsCancellationEpoch() public {
        bytes32 orderHash = conductor.hashOrder(_orderA());
        vm.prank(ownerA);
        conductor.requestOrderCancellation(orderHash);
        assertEq(
            conductor.cancelledFrom(ACCOUNT_A, orderHash),
            depot.settlementEpoch() + 1,
            "cancellation epoch not returned"
        );
    }

    function test_preApproved_ReturnsFalseForOrderNotPreApproved() public view {
        assertFalse(conductor.preApproved(conductor.hashOrder(_orderA())), "order pre-approved");
    }

    function test_preApproved_ReturnsTrueForPreApprovedOrder() public {
        ISpotSwapConductor.Order memory a = _orderA();
        vm.prank(ownerA);
        conductor.preApprove(a);
        assertTrue(conductor.preApproved(conductor.hashOrder(a)), "order not pre-approved");
    }

    function test_requestOrderCancellation_SetsCancelledFromToNextSettlementEpoch() public {
        bytes32 orderHash = conductor.hashOrder(_orderA());
        vm.prank(ownerA);
        conductor.requestOrderCancellation(orderHash);
        assertEq(
            conductor.cancelledFrom(ACCOUNT_A, orderHash),
            depot.settlementEpoch() + 1,
            "cancelledFrom not settlementEpoch + 1"
        );
    }

    function test_requestOrderCancellation_SetsCancelledFromToCurrentEpochIfFacilitated() public {
        bytes32 orderHash = conductor.hashOrder(_orderA());
        _relay(abi.encodeCall(ISwapConductor.requestOrderCancellation, (orderHash)), ACCOUNT_A, true);
        assertEq(
            conductor.cancelledFrom(ACCOUNT_A, orderHash), depot.settlementEpoch(), "cancelledFrom not current epoch"
        );
    }

    function test_requestOrderCancellation_KeepsExistingCancellationIfEqual() public {
        bytes32 orderHash = conductor.hashOrder(_orderA());
        vm.startPrank(ownerA);
        conductor.requestOrderCancellation(orderHash);
        conductor.requestOrderCancellation(orderHash);
        vm.stopPrank();
        assertEq(
            conductor.cancelledFrom(ACCOUNT_A, orderHash), depot.settlementEpoch() + 1, "existing cancellation not kept"
        );
    }

    function test_requestOrderCancellation_KeepsExistingCancellationIfEarlier() public {
        bytes32 orderHash = conductor.hashOrder(_orderA());
        _relay(abi.encodeCall(ISwapConductor.requestOrderCancellation, (orderHash)), ACCOUNT_A, true);
        vm.prank(ownerA);
        conductor.requestOrderCancellation(orderHash);
        assertEq(
            conductor.cancelledFrom(ACCOUNT_A, orderHash), depot.settlementEpoch(), "earlier cancellation not kept"
        );
    }

    function test_requestOrderCancellation_OverwritesExistingCancellationIfLater() public {
        bytes32 orderHash = conductor.hashOrder(_orderA());
        vm.prank(ownerA);
        conductor.requestOrderCancellation(orderHash);
        _relay(abi.encodeCall(ISwapConductor.requestOrderCancellation, (orderHash)), ACCOUNT_A, true);
        assertEq(
            conductor.cancelledFrom(ACCOUNT_A, orderHash), depot.settlementEpoch(), "later cancellation not overwritten"
        );
    }

    function test_requestOrderCancellation_EmitsOrderCancellationRequestedEvent() public {
        bytes32 orderHash = conductor.hashOrder(_orderA());
        vm.expectEmit(address(conductor));
        emit ISwapConductor.OrderCancellationRequested(ACCOUNT_A, orderHash, depot.settlementEpoch() + 1);
        vm.prank(ownerA);
        conductor.requestOrderCancellation(orderHash);
    }

    function test_requestOrderCancellation_DoesNotEmitOrderCancellationRequestedEventIfExistingCancellationIsKept()
        public
    {
        bytes32 orderHash = conductor.hashOrder(_orderA());
        vm.prank(ownerA);
        conductor.requestOrderCancellation(orderHash);
        vm.recordLogs();
        vm.prank(ownerA);
        conductor.requestOrderCancellation(orderHash);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("OrderCancellationRequested(bytes28,bytes32,uint256)");
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != topic, "OrderCancellationRequested emitted");
        }
    }

    function test_preApprove_SetsPreApprovedForOrderHashToTrue() public {
        ISpotSwapConductor.Order memory a = _orderA();
        vm.prank(ownerA);
        conductor.preApprove(a);
        assertTrue(conductor.preApproved(conductor.hashOrder(a)), "preApproved not set");
    }

    function test_preApprove_AcceptsOwnerRelayedThroughTurnstile() public {
        ISpotSwapConductor.Order memory a = _orderA();
        a.ownerChainId = REMOTE_CHAIN;
        bytes28 remoteAccount = TransitAddressLib.formatTransitAddress(REMOTE_CHAIN, ownerA);
        _relay(abi.encodeCall(ISpotSwapConductor.preApprove, (a)), remoteAccount, false);
        assertTrue(conductor.preApproved(conductor.hashOrder(a)), "relayed pre-approval not set");
    }

    function test_preApprove_EmitsPreApprovedEvent() public {
        ISpotSwapConductor.Order memory a = _orderA();
        bytes32 orderHash = conductor.hashOrder(a);
        vm.expectEmit(address(conductor));
        emit ISpotSwapConductor.PreApproved(ACCOUNT_A, orderHash, a);
        vm.prank(ownerA);
        conductor.preApprove(a);
    }

    function test_preApprove_RevertIf_SenderIsNotOrderOwner() public {
        vm.expectRevert(ISwapConductor.NotOwner.selector);
        vm.prank(stranger);
        conductor.preApprove(_orderA());
    }

    function test_settle_DebitsSellTokenFromOwnersAndCreditsBuyTokenToReceivers() public {
        _seed(ACCOUNT_A, ASSET_A, 100);
        _seed(ACCOUNT_B, ASSET_B, 50);
        _settle(
            _fills(_orderFill(_orderA(), OWNER_A_PK, 100, 50), _orderFill(_orderB(), OWNER_B_PK, 50, 100)), _noFees()
        );
        bytes28 recvA = TransitAddressLib.formatTransitAddress(uint64(block.chainid), receiverA);
        bytes28 recvB = TransitAddressLib.formatTransitAddress(uint64(block.chainid), receiverB);
        assertEq(depot.balanceOf(ACCOUNT_A, ASSET_A), 0, "ownerA sell token not debited");
        assertEq(depot.balanceOf(ACCOUNT_B, ASSET_B), 0, "ownerB sell token not debited");
        assertEq(depot.balanceOf(recvA, ASSET_B), 50, "receiverA buy token not credited");
        assertEq(depot.balanceOf(recvB, ASSET_A), 100, "receiverB buy token not credited");
    }

    function test_settle_CreditsBuyTokenToFrozenReceiver() public {
        _seed(ACCOUNT_A, ASSET_A, 100);
        _seed(ACCOUNT_B, ASSET_B, 50);
        _freeze(receiverA);
        _settle(
            _fills(_orderFill(_orderA(), OWNER_A_PK, 100, 50), _orderFill(_orderB(), OWNER_B_PK, 50, 100)), _noFees()
        );
        bytes28 recvA = TransitAddressLib.formatTransitAddress(uint64(block.chainid), receiverA);
        assertEq(depot.balanceOf(recvA, ASSET_B), 50, "frozen receiver not credited");
    }

    function test_settle_CreditsFeesToSurplusRecipientAccount() public {
        ISpotSwapConductor.Order memory a = _orderA();
        ISpotSwapConductor.Order memory b = _orderB();
        b.sellAmount = 60;
        _seed(ACCOUNT_A, ASSET_A, 100);
        _seed(ACCOUNT_B, ASSET_B, 60);
        _settle(
            _fills(_orderFill(a, OWNER_A_PK, 100, 55), _orderFill(b, OWNER_B_PK, 60, 100)),
            _fees(ISpotSwapConductor.Fee(ASSET_B, 5))
        );
        assertEq(depot.balanceOf(SURPLUS, ASSET_B), 5, "fee not credited to surplus recipient");
    }

    function test_settle_AddsSellFilledToFilledAmountOfEachOrder() public {
        ISpotSwapConductor.Order memory a = _orderA();
        ISpotSwapConductor.Order memory b = _orderB();
        _seed(ACCOUNT_A, ASSET_A, 100);
        _seed(ACCOUNT_B, ASSET_B, 50);
        _settle(_fills(_orderFill(a, OWNER_A_PK, 100, 50), _orderFill(b, OWNER_B_PK, 50, 100)), _noFees());
        assertEq(conductor.filledAmount(conductor.hashOrder(a)), 100, "orderA filled amount wrong");
        assertEq(conductor.filledAmount(conductor.hashOrder(b)), 50, "orderB filled amount wrong");
    }

    function test_settle_AcceptsEmptyOrderFillsAndFeesArrays() public {
        uint256 epoch = depot.settlementEpoch();
        _settle(new ISpotSwapConductor.OrderFill[](0), _noFees());
        assertEq(depot.settlementEpoch(), epoch + 1, "epoch not advanced");
    }

    function test_settle_AcceptsPreApprovedOrderWithEmptySignature() public {
        ISpotSwapConductor.Order memory a = _orderA();
        ISpotSwapConductor.Order memory b = _orderB();
        vm.prank(ownerA);
        conductor.preApprove(a);
        _seed(ACCOUNT_A, ASSET_A, 100);
        _seed(ACCOUNT_B, ASSET_B, 50);
        _settle(_fills(_orderFill(a, 0, 100, 50), _orderFill(b, OWNER_B_PK, 50, 100)), _noFees());
        assertEq(conductor.filledAmount(conductor.hashOrder(a)), 100, "pre-approved order not filled");
    }

    function test_settle_AcceptsFillAtExactLimitPrice() public {
        ISpotSwapConductor.Order memory a = _orderA();
        ISpotSwapConductor.Order memory b = _orderB();
        _seed(ACCOUNT_A, ASSET_A, 100);
        _seed(ACCOUNT_B, ASSET_B, 50);
        _settle(_fills(_orderFill(a, OWNER_A_PK, 100, 50), _orderFill(b, OWNER_B_PK, 50, 100)), _noFees());
        assertEq(depot.balanceOf(ACCOUNT_A, ASSET_A), 0, "exact limit fill not settled");
    }

    function test_settle_AcceptsFillWithPriceImprovement() public {
        ISpotSwapConductor.Order memory a = _orderA();
        ISpotSwapConductor.Order memory b = _orderB();
        b.sellAmount = 60;
        _seed(ACCOUNT_A, ASSET_A, 100);
        _seed(ACCOUNT_B, ASSET_B, 60);
        _settle(_fills(_orderFill(a, OWNER_A_PK, 100, 60), _orderFill(b, OWNER_B_PK, 60, 100)), _noFees());
        bytes28 recvA = TransitAddressLib.formatTransitAddress(uint64(block.chainid), receiverA);
        assertEq(depot.balanceOf(recvA, ASSET_B), 60, "price improvement not paid to receiver");
    }

    function test_settle_FillsPartiallyFillableOrderAcrossSettlements() public {
        ISpotSwapConductor.Order memory a = _orderA();
        ISpotSwapConductor.Order memory b = _orderB();
        _seed(ACCOUNT_A, ASSET_A, 100);
        _seed(ACCOUNT_B, ASSET_B, 50);
        _settle(_fills(_orderFill(a, OWNER_A_PK, 40, 20), _orderFill(b, OWNER_B_PK, 20, 40)), _noFees());
        _settle(_fills(_orderFill(a, OWNER_A_PK, 60, 30), _orderFill(b, OWNER_B_PK, 30, 60)), _noFees());
        assertEq(conductor.filledAmount(conductor.hashOrder(a)), 100, "order not filled across settlements");
    }

    function test_settle_FillsOrderWhoseCancellationIsNotYetEffective() public {
        ISpotSwapConductor.Order memory a = _orderA();
        ISpotSwapConductor.Order memory b = _orderB();
        bytes32 orderHash = conductor.hashOrder(a);
        vm.prank(ownerA);
        conductor.requestOrderCancellation(orderHash);
        _seed(ACCOUNT_A, ASSET_A, 100);
        _seed(ACCOUNT_B, ASSET_B, 50);
        _settle(_fills(_orderFill(a, OWNER_A_PK, 100, 50), _orderFill(b, OWNER_B_PK, 50, 100)), _noFees());
        assertEq(conductor.filledAmount(orderHash), 100, "order not filled before cancellation effective");
    }

    function test_settle_AdvancesDepotSettlementEpoch() public {
        uint256 epoch = depot.settlementEpoch();
        _seed(ACCOUNT_A, ASSET_A, 100);
        _seed(ACCOUNT_B, ASSET_B, 50);
        _settle(
            _fills(_orderFill(_orderA(), OWNER_A_PK, 100, 50), _orderFill(_orderB(), OWNER_B_PK, 50, 100)), _noFees()
        );
        assertEq(depot.settlementEpoch(), epoch + 1, "epoch not advanced");
    }

    function test_settle_EmitsFilledEventForEachFill() public {
        ISpotSwapConductor.Order memory a = _orderA();
        ISpotSwapConductor.Order memory b = _orderB();
        bytes32 hashA = conductor.hashOrder(a);
        bytes32 hashB = conductor.hashOrder(b);
        _seed(ACCOUNT_A, ASSET_A, 100);
        _seed(ACCOUNT_B, ASSET_B, 50);
        vm.expectEmit(address(conductor));
        emit ISwapConductor.Filled(hashA, ACCOUNT_A, 100, 50);
        vm.expectEmit(address(conductor));
        emit ISwapConductor.Filled(hashB, ACCOUNT_B, 50, 100);
        _settle(_fills(_orderFill(a, OWNER_A_PK, 100, 50), _orderFill(b, OWNER_B_PK, 50, 100)), _noFees());
    }

    function test_settle_RevertIf_SenderIsUnauthorized() public {
        uint256 epoch = depot.settlementEpoch();
        ISpotSwapConductor.OrderFill[] memory fills =
            _fills(_orderFill(_orderA(), OWNER_A_PK, 100, 50), _orderFill(_orderB(), OWNER_B_PK, 50, 100));
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vm.prank(stranger);
        conductor.settle(epoch, fills, _noFees());
    }

    function test_settle_RevertIf_EpochIsNotCurrentSettlementEpoch() public {
        uint256 epoch = depot.settlementEpoch() + 1;
        ISpotSwapConductor.OrderFill[] memory fills =
            _fills(_orderFill(_orderA(), OWNER_A_PK, 100, 50), _orderFill(_orderB(), OWNER_B_PK, 50, 100));
        vm.expectRevert(abi.encodeWithSelector(ISwapConductor.BadEpoch.selector, epoch));
        _settleAt(epoch, fills, _noFees());
    }

    function test_settle_RevertIf_OrderIsExpired() public {
        uint256 epoch = depot.settlementEpoch();
        ISpotSwapConductor.Order memory a = _orderA();
        a.expiresAt = block.timestamp;
        bytes32 orderHash = conductor.hashOrder(a);
        ISpotSwapConductor.OrderFill[] memory fills = _fills(_orderFill(a, OWNER_A_PK, 100, 50));
        vm.expectRevert(abi.encodeWithSelector(ISwapConductor.Expired.selector, orderHash));
        _settleAt(epoch, fills, _noFees());
    }

    function test_settle_RevertIf_OrderIsNotFullyFilledAndNotPartiallyFillable() public {
        uint256 epoch = depot.settlementEpoch();
        ISpotSwapConductor.Order memory a = _orderA();
        a.partiallyFillable = false;
        bytes32 orderHash = conductor.hashOrder(a);
        ISpotSwapConductor.OrderFill[] memory fills = _fills(_orderFill(a, OWNER_A_PK, 99, 50));
        vm.expectRevert(abi.encodeWithSelector(ISwapConductor.NotPartiallyFillable.selector, orderHash));
        _settleAt(epoch, fills, _noFees());
    }

    function test_settle_RevertIf_SignatureIsNotFromOrderOwner() public {
        uint256 epoch = depot.settlementEpoch();
        ISpotSwapConductor.OrderFill[] memory fills = _fills(_orderFill(_orderA(), OWNER_B_PK, 100, 50));
        vm.expectRevert(ISwapConductor.BadSignature.selector);
        _settleAt(epoch, fills, _noFees());
    }

    function test_settle_RevertIf_SignatureIsEmptyAndOrderIsNotPreApproved() public {
        uint256 epoch = depot.settlementEpoch();
        ISpotSwapConductor.Order memory a = _orderA();
        bytes32 orderHash = conductor.hashOrder(a);
        ISpotSwapConductor.OrderFill[] memory fills = _fills(_orderFill(a, 0, 100, 50));
        vm.expectRevert(abi.encodeWithSelector(ISwapConductor.NotPreApproved.selector, orderHash));
        _settleAt(epoch, fills, _noFees());
    }

    function test_settle_RevertIf_FillWouldExceedSellAmountOfOrder() public {
        uint256 epoch = depot.settlementEpoch();
        ISpotSwapConductor.Order memory a = _orderA();
        bytes32 orderHash = conductor.hashOrder(a);
        ISpotSwapConductor.OrderFill[] memory fills =
            _fills(_orderFill(a, OWNER_A_PK, 100, 50), _orderFill(a, OWNER_A_PK, 1, 1));
        vm.expectRevert(abi.encodeWithSelector(ISwapConductor.Overfill.selector, orderHash));
        _settleAt(epoch, fills, _noFees());
    }

    function test_settle_RevertIf_CancellationOfOrderIsEffectiveAtSettlementEpoch() public {
        uint256 epoch = depot.settlementEpoch();
        ISpotSwapConductor.Order memory a = _orderA();
        bytes32 orderHash = conductor.hashOrder(a);
        _relay(abi.encodeCall(ISwapConductor.requestOrderCancellation, (orderHash)), ACCOUNT_A, true);
        ISpotSwapConductor.OrderFill[] memory fills = _fills(_orderFill(a, OWNER_A_PK, 100, 50));
        vm.expectRevert(abi.encodeWithSelector(ISwapConductor.Cancelled.selector, orderHash));
        _settleAt(epoch, fills, _noFees());
    }

    function test_settle_RevertIf_CancellationOfOrderBecameEffectiveAtEarlierEpoch() public {
        ISpotSwapConductor.Order memory a = _orderA();
        bytes32 orderHash = conductor.hashOrder(a);
        _relay(abi.encodeCall(ISwapConductor.requestOrderCancellation, (orderHash)), ACCOUNT_A, true);
        vm.prank(seeder);
        depot.advanceEpoch();
        uint256 epoch = depot.settlementEpoch();
        assertGt(epoch, conductor.cancelledFrom(ACCOUNT_A, orderHash), "cancellation not from earlier epoch");
        ISpotSwapConductor.OrderFill[] memory fills = _fills(_orderFill(a, OWNER_A_PK, 100, 50));
        vm.expectRevert(abi.encodeWithSelector(ISwapConductor.Cancelled.selector, orderHash));
        _settleAt(epoch, fills, _noFees());
    }

    function test_settle_RevertIf_FillIsBelowLimitPrice() public {
        uint256 epoch = depot.settlementEpoch();
        ISpotSwapConductor.Order memory a = _orderA();
        bytes32 orderHash = conductor.hashOrder(a);
        ISpotSwapConductor.OrderFill[] memory fills = _fills(_orderFill(a, OWNER_A_PK, 100, 49));
        vm.expectRevert(abi.encodeWithSelector(ISwapConductor.LimitPrice.selector, orderHash));
        _settleAt(epoch, fills, _noFees());
    }

    function test_settle_RevertIf_FillSellAmountIsZero() public {
        uint256 epoch = depot.settlementEpoch();
        ISpotSwapConductor.OrderFill[] memory fills = _fills(_orderFill(_orderA(), OWNER_A_PK, 0, 1));
        vm.expectRevert(IDepot.ZeroAmount.selector);
        _settleAt(epoch, fills, _noFees());
    }

    function test_settle_RevertIf_OwnerBalanceIsInsufficient() public {
        uint256 epoch = depot.settlementEpoch();
        _seed(ACCOUNT_A, ASSET_A, 50);
        _seed(ACCOUNT_B, ASSET_B, 50);
        ISpotSwapConductor.OrderFill[] memory fills =
            _fills(_orderFill(_orderA(), OWNER_A_PK, 100, 50), _orderFill(_orderB(), OWNER_B_PK, 50, 100));
        vm.expectRevert(IDepot.InsufficientBalance.selector);
        _settleAt(epoch, fills, _noFees());
    }

    function test_settle_RevertIf_OrderOwnerIsFrozen() public {
        uint256 epoch = depot.settlementEpoch();
        _seed(ACCOUNT_A, ASSET_A, 100);
        _seed(ACCOUNT_B, ASSET_B, 50);
        _freeze(ownerA);
        ISpotSwapConductor.OrderFill[] memory fills =
            _fills(_orderFill(_orderA(), OWNER_A_PK, 100, 50), _orderFill(_orderB(), OWNER_B_PK, 50, 100));
        vm.expectRevert(abi.encodeWithSelector(IDepot.AccountFrozen.selector, ACCOUNT_A));
        _settleAt(epoch, fills, _noFees());
    }

    function test_settle_RevertIf_DebitsAndCreditsDoNotNetToZero() public {
        uint256 epoch = depot.settlementEpoch();
        _seed(ACCOUNT_A, ASSET_A, 100);
        _seed(ACCOUNT_B, ASSET_B, 50);
        ISpotSwapConductor.OrderFill[] memory fills =
            _fills(_orderFill(_orderA(), OWNER_A_PK, 100, 50), _orderFill(_orderB(), OWNER_B_PK, 50, 100));
        vm.expectRevert(IDepot.NotZeroSum.selector);
        _settleAt(epoch, fills, _fees(ISpotSwapConductor.Fee(ASSET_A, 10)));
    }

    function test_hashOrder_ReturnsEip712DigestOfOrder() public view {
        ISpotSwapConductor.Order memory a = _orderA();
        bytes32 structHash = keccak256(abi.encode(Typehashes.ORDER, a));
        bytes32 expected = keccak256(abi.encodePacked("\x19\x01", conductor.DOMAIN_SEPARATOR(), structHash));
        assertEq(conductor.hashOrder(a), expected, "order digest wrong");
    }

}
