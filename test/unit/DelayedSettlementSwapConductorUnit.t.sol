// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { Test, stdError, Vm } from "forge-std/Test.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Depot } from "src/depot/Depot.sol";
import { IDepot } from "src/interfaces/IDepot.sol";
import { AddressFreezeList } from "src/AddressFreezeList.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { Roles } from "src/helpers/Roles.sol";
import { Typehashes } from "src/helpers/Typehashes.sol";
import { TransitAddressLib } from "src/helpers/TransitAddressLib.sol";
import { DelayedSettlementSwapConductor } from "src/conductor/DelayedSettlementSwapConductor.sol";
import { IDelayedSettlementSwapConductor } from "src/interfaces/IDelayedSettlementSwapConductor.sol";
import { ISwapConductor } from "src/interfaces/ISwapConductor.sol";
import { FACILITATED_FLAG } from "src/conductor/ConductorGatedByTurnstile.sol";

contract DelayedSettlementSwapConductorUnitTest is Test {

    uint256 constant OWNER_A_PK = 0xA11CE;
    uint256 constant OWNER_B_PK = 0xB0B;

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
    DelayedSettlementSwapConductor conductor;

    bytes28 SURPLUS;
    bytes28 PENALTY;
    bytes28 ACCOUNT_A;
    bytes28 ACCOUNT_B;
    bytes28 RECEIVER_A;
    bytes28 RECEIVER_B;
    bytes28 ASSET_A;
    bytes28 ASSET_B;
    bytes28 CONDUCTOR_ACCOUNT;

    function setUp() public {
        vm.warp(10_000);
        authority = new AccessManager(admin);
        freezeList = new AddressFreezeList(address(authority));
        depot = new Depot(address(authority), freezeList);

        SURPLUS = TransitAddressLib.formatTransitAddress(uint64(block.chainid), makeAddr("surplus"));
        PENALTY = TransitAddressLib.formatTransitAddress(uint64(block.chainid), makeAddr("penalty"));
        ACCOUNT_A = TransitAddressLib.formatTransitAddress(uint64(block.chainid), ownerA);
        ACCOUNT_B = TransitAddressLib.formatTransitAddress(uint64(block.chainid), ownerB);
        RECEIVER_A = TransitAddressLib.formatTransitAddress(uint64(block.chainid), receiverA);
        RECEIVER_B = TransitAddressLib.formatTransitAddress(uint64(block.chainid), receiverB);
        ASSET_A = TransitAddressLib.formatTransitAddress(uint64(block.chainid), tokenA);
        ASSET_B = TransitAddressLib.formatTransitAddress(uint64(block.chainid), tokenB);

        conductor = new DelayedSettlementSwapConductor(address(authority), address(depot), SURPLUS, PENALTY, turnstile);
        CONDUCTOR_ACCOUNT = TransitAddressLib.formatTransitAddress(uint64(block.chainid), address(conductor));

        bytes4[] memory depotSelectors = new bytes4[](4);
        depotSelectors[0] = Depot.transferFrom.selector;
        depotSelectors[1] = Depot.transferAmong.selector;
        depotSelectors[2] = Depot.mint.selector;
        depotSelectors[3] = Depot.advanceEpoch.selector;

        vm.startPrank(admin);
        authority.setTargetFunctionRole(address(depot), depotSelectors, Roles.CONDUCTOR);
        authority.setTargetFunctionRole(
            address(conductor), _selectors(DelayedSettlementSwapConductor.settle.selector), Roles.SOLVER
        );
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

    function _collateralizedOrderA()
        internal
        view
        returns (IDelayedSettlementSwapConductor.DelayedSettlementOrder memory o)
    {
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
        o.collateralized = true;
        o.settlementPeriod = 1 hours;
        o.salt = bytes32(uint256(1));
    }

    function _orderB() internal view returns (IDelayedSettlementSwapConductor.DelayedSettlementOrder memory o) {
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
        o.collateralized = false;
        o.settlementPeriod = 1 hours;
        o.salt = bytes32(uint256(2));
    }

    function _orderBCollateralized()
        internal
        view
        returns (IDelayedSettlementSwapConductor.DelayedSettlementOrder memory o)
    {
        o = _orderB();
        o.collateralized = true;
    }

    function _orderA() internal view returns (IDelayedSettlementSwapConductor.DelayedSettlementOrder memory o) {
        o = _collateralizedOrderA();
        o.collateralized = false;
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _orders(
        IDelayedSettlementSwapConductor.DelayedSettlementOrder memory a,
        IDelayedSettlementSwapConductor.DelayedSettlementOrder memory b
    )
        internal
        pure
        returns (IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders)
    {
        orders = new IDelayedSettlementSwapConductor.DelayedSettlementOrder[](2);
        orders[0] = a;
        orders[1] = b;
    }

    function _orders(
        IDelayedSettlementSwapConductor.DelayedSettlementOrder memory a,
        IDelayedSettlementSwapConductor.DelayedSettlementOrder memory b,
        IDelayedSettlementSwapConductor.DelayedSettlementOrder memory c,
        IDelayedSettlementSwapConductor.DelayedSettlementOrder memory d
    )
        internal
        pure
        returns (IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders)
    {
        orders = new IDelayedSettlementSwapConductor.DelayedSettlementOrder[](4);
        orders[0] = a;
        orders[1] = b;
        orders[2] = c;
        orders[3] = d;
    }

    function _signatures(IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders)
        internal
        view
        returns (bytes[] memory signatures)
    {
        signatures = new bytes[](orders.length);
        for (uint256 i; i < orders.length; i++) {
            uint256 pk = orders[i].owner == ownerA ? OWNER_A_PK : OWNER_B_PK;
            signatures[i] = _sign(pk, conductor.hashOrder(orders[i]));
        }
    }

    function _pairedFill(
        uint256 amount0,
        uint256 amount1
    )
        internal
        pure
        returns (IDelayedSettlementSwapConductor.PairedFill memory f)
    {
        f.orderIndexes = [uint256(0), uint256(1)];
        f.amounts = [amount0, amount1];
        f.fees = [uint256(0), uint256(0)];
    }

    function _pairedFills(IDelayedSettlementSwapConductor.PairedFill memory a)
        internal
        pure
        returns (IDelayedSettlementSwapConductor.PairedFill[] memory fills)
    {
        fills = new IDelayedSettlementSwapConductor.PairedFill[](1);
        fills[0] = a;
    }

    function _pairedFills(
        IDelayedSettlementSwapConductor.PairedFill memory a,
        IDelayedSettlementSwapConductor.PairedFill memory b
    )
        internal
        pure
        returns (IDelayedSettlementSwapConductor.PairedFill[] memory fills)
    {
        fills = new IDelayedSettlementSwapConductor.PairedFill[](2);
        fills[0] = a;
        fills[1] = b;
    }

    function _settle(
        IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders,
        bytes[] memory signatures,
        IDelayedSettlementSwapConductor.PairedFill[] memory fills
    )
        internal
    {
        _settleAt(depot.settlementEpoch(), orders, signatures, fills);
    }

    function _settleAt(
        uint256 epoch,
        IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders,
        bytes[] memory signatures,
        IDelayedSettlementSwapConductor.PairedFill[] memory fills
    )
        internal
    {
        vm.prank(solver);
        conductor.settle(epoch, orders, signatures, fills);
    }

    function _relay(bytes memory data, bytes28 accountId, bool facilitated) internal {
        vm.prank(turnstile);
        (bool ok, bytes memory result) =
            address(conductor).call(abi.encodePacked(data, accountId, facilitated ? FACILITATED_FLAG : bytes4(0)));
        if (!ok) {
            assembly { revert(add(result, 32), mload(result)) }
        }
    }

    /// @dev Settles the default pair (collateralized A vs non-collateralized B, amounts 100/50) and returns its escrow
    /// id.
    function _escrowed() internal returns (uint256 escrowId) {
        IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders =
            _orders(_collateralizedOrderA(), _orderB());
        _seed(ACCOUNT_A, ASSET_A, 101);
        _seed(ACCOUNT_B, ASSET_B, 50);
        escrowId = conductor.escrowCount() + 1;
        _settle(orders, _signatures(orders), _pairedFills(_pairedFill(100, 50)));
    }

    /// @dev Settles a pair of two collateralized orders (amounts 100/50) and returns its escrow id.
    function _escrowedBothCollateralized() internal returns (uint256 escrowId) {
        IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders =
            _orders(_collateralizedOrderA(), _orderBCollateralized());
        _seed(ACCOUNT_A, ASSET_A, 101);
        _seed(ACCOUNT_B, ASSET_B, 51);
        escrowId = conductor.escrowCount() + 1;
        _settle(orders, _signatures(orders), _pairedFills(_pairedFill(100, 50)));
    }

    function _assertEscrowDeleted(uint256 escrowId) internal view {
        (bytes28 accountId,,,,,,) = conductor.escrowLegs(escrowId, 0);
        assertEq(accountId, bytes28(0), "leg 0 not deleted");
        (accountId,,,,,,) = conductor.escrowLegs(escrowId, 1);
        assertEq(accountId, bytes28(0), "leg 1 not deleted");
        assertEq(conductor.escrowDeadline(escrowId), 0, "deadline not deleted");
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

    function test_constructor_SetsPenaltyRecipientAccountId() public view {
        assertEq(conductor.PENALTY_RECIPIENT_ACCOUNT_ID(), PENALTY, "PENALTY_RECIPIENT_ACCOUNT_ID not set");
    }

    function test_constructor_SetsTurnstile() public view {
        assertEq(conductor.TURNSTILE(), turnstile, "TURNSTILE not set");
    }

    function test_constructor_RevertIf_SurplusRecipientIsInvalid() public {
        vm.expectRevert(ISwapConductor.InvalidAccount.selector);
        new DelayedSettlementSwapConductor(address(authority), address(depot), bytes28(0), PENALTY, turnstile);
    }

    function test_constructor_RevertIf_PenaltyRecipientIsInvalid() public {
        vm.expectRevert(ISwapConductor.InvalidAccount.selector);
        new DelayedSettlementSwapConductor(address(authority), address(depot), SURPLUS, bytes28(0), turnstile);
    }

    function test_FILL_RATIO_Returns100() public view {
        assertEq(conductor.FILL_RATIO(), 100, "FILL_RATIO not 100");
    }

    function test_MAX_SETTLEMENT_PERIOD_Returns1Day() public view {
        assertEq(conductor.MAX_SETTLEMENT_PERIOD(), 1 days, "MAX_SETTLEMENT_PERIOD not 1 day");
    }

    function test_PENALTY_RECIPIENT_ACCOUNT_ID_ReturnsPenaltyRecipientAccountId() public view {
        assertEq(conductor.PENALTY_RECIPIENT_ACCOUNT_ID(), PENALTY, "penalty recipient not returned");
    }

    function test_escrowCount_ReturnsNumberOfEscrowsCreated() public {
        _escrowed();
        assertEq(conductor.escrowCount(), 1, "escrow count wrong");
    }

    function test_escrowLegs_ReturnsLegsOfGivenEscrow() public {
        uint256 escrowId = _escrowed();
        (bytes28 accountId, bytes28 receiverAccountId, bytes28 assetId, uint256 amount, uint256 debt,,) =
            conductor.escrowLegs(escrowId, 0);
        assertEq(accountId, ACCOUNT_A, "leg 0 account wrong");
        assertEq(receiverAccountId, RECEIVER_A, "leg 0 receiver wrong");
        assertEq(assetId, ASSET_A, "leg 0 asset wrong");
        assertEq(amount, 100, "leg 0 amount wrong");
        assertEq(debt, 100, "leg 0 debt wrong");
        (accountId,, assetId, amount, debt,,) = conductor.escrowLegs(escrowId, 1);
        assertEq(accountId, ACCOUNT_B, "leg 1 account wrong");
        assertEq(assetId, ASSET_B, "leg 1 asset wrong");
        assertEq(amount, 50, "leg 1 amount wrong");
        assertEq(debt, 0, "leg 1 debt wrong");
    }

    function test_escrowDeadline_ReturnsDeadlineOfGivenEscrow() public {
        uint256 escrowId = _escrowed();
        assertEq(conductor.escrowDeadline(escrowId), block.timestamp + 1 hours, "escrow deadline wrong");
    }

    function test_preApprove_SetsPreApprovedForOrderHashToTrue() public {
        IDelayedSettlementSwapConductor.DelayedSettlementOrder memory a = _collateralizedOrderA();
        vm.prank(ownerA);
        conductor.preApprove(a);
        assertTrue(conductor.preApproved(conductor.hashOrder(a)), "preApproved not set");
    }

    function test_preApprove_EmitsPreApprovedEvent() public {
        IDelayedSettlementSwapConductor.DelayedSettlementOrder memory a = _collateralizedOrderA();
        bytes32 orderHash = conductor.hashOrder(a);
        vm.expectEmit(address(conductor));
        emit IDelayedSettlementSwapConductor.PreApproved(ACCOUNT_A, orderHash, a);
        vm.prank(ownerA);
        conductor.preApprove(a);
    }

    function test_preApprove_RevertIf_SenderIsNotOrderOwner() public {
        vm.expectRevert(ISwapConductor.NotOwner.selector);
        vm.prank(stranger);
        conductor.preApprove(_collateralizedOrderA());
    }

    function test_settle_EscrowsFullAmountOfUncollateralizedSide() public {
        _escrowed();
        assertEq(depot.balanceOf(CONDUCTOR_ACCOUNT, ASSET_B), 50, "non-collateralized side not escrowed in full");
    }

    function test_settle_EscrowsRoundedUpCollateralOfCollateralizedSide() public {
        IDelayedSettlementSwapConductor.DelayedSettlementOrder memory a = _collateralizedOrderA();
        a.sellAmount = 101;
        a.buyAmount = 51;
        IDelayedSettlementSwapConductor.DelayedSettlementOrder memory b = _orderB();
        b.sellAmount = 51;
        b.buyAmount = 101;
        IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders = _orders(a, b);
        _seed(ACCOUNT_A, ASSET_A, 2);
        _seed(ACCOUNT_B, ASSET_B, 51);
        _settle(orders, _signatures(orders), _pairedFills(_pairedFill(101, 51)));
        (,,,,, uint256 collateral,) = conductor.escrowLegs(1, 0);
        assertEq(collateral, 2, "collateral not amount / FILL_RATIO rounded up");
        assertEq(depot.balanceOf(CONDUCTOR_ACCOUNT, ASSET_A), 2, "collateral not escrowed");
    }

    function test_settle_StoresBothLegsOfEachPairUnderNewEscrowId() public {
        uint256 escrowId = _escrowed();
        (bytes28 accountId0,,,,,,) = conductor.escrowLegs(escrowId, 0);
        (bytes28 accountId1,,,,,,) = conductor.escrowLegs(escrowId, 1);
        assertEq(accountId0, ACCOUNT_A, "leg 0 not stored");
        assertEq(accountId1, ACCOUNT_B, "leg 1 not stored");
    }

    function test_settle_SetsEscrowDeadlineToCurrentTimestampPlusSettlementPeriod() public {
        uint256 escrowId = _escrowed();
        assertEq(
            conductor.escrowDeadline(escrowId), block.timestamp + 1 hours, "deadline not now plus settlement period"
        );
    }

    function test_settle_AddsSellFilledToFilledAmountOfEachOrder() public {
        IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders =
            _orders(_collateralizedOrderA(), _orderB());
        _seed(ACCOUNT_A, ASSET_A, 101);
        _seed(ACCOUNT_B, ASSET_B, 50);
        _settle(orders, _signatures(orders), _pairedFills(_pairedFill(100, 50)));
        assertEq(conductor.filledAmount(conductor.hashOrder(orders[0])), 100, "orderA filled amount wrong");
        assertEq(conductor.filledAmount(conductor.hashOrder(orders[1])), 50, "orderB filled amount wrong");
    }

    function test_settle_UsesSettlementPeriodOfCollateralizedSide() public {
        IDelayedSettlementSwapConductor.DelayedSettlementOrder memory b = _orderB();
        b.settlementPeriod = 2 hours;
        IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders = _orders(_collateralizedOrderA(), b);
        _seed(ACCOUNT_A, ASSET_A, 101);
        _seed(ACCOUNT_B, ASSET_B, 50);
        _settle(orders, _signatures(orders), _pairedFills(_pairedFill(100, 50)));
        assertEq(conductor.escrowDeadline(1), block.timestamp + 1 hours, "collateralized order period not used");
    }

    function test_settle_FillsOrderWhoseCancellationIsNotYetEffective() public {
        IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders =
            _orders(_collateralizedOrderA(), _orderB());
        bytes32 orderHash = conductor.hashOrder(orders[0]);
        vm.prank(ownerA);
        conductor.requestOrderCancellation(orderHash);
        _seed(ACCOUNT_A, ASSET_A, 101);
        _seed(ACCOUNT_B, ASSET_B, 50);
        _settle(orders, _signatures(orders), _pairedFills(_pairedFill(100, 50)));
        assertEq(conductor.filledAmount(orderHash), 100, "order not filled before cancellation effective");
    }

    function test_settle_AdvancesDepotSettlementEpoch() public {
        uint256 epoch = depot.settlementEpoch();
        _escrowed();
        assertEq(depot.settlementEpoch(), epoch + 1, "epoch not advanced");
    }

    function test_settle_EmitsEscrowedEventForEachPairedFill() public {
        IDelayedSettlementSwapConductor.DelayedSettlementOrder memory a2 = _collateralizedOrderA();
        IDelayedSettlementSwapConductor.DelayedSettlementOrder memory b2 = _orderB();
        a2.salt = bytes32(uint256(3));
        b2.salt = bytes32(uint256(4));
        IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders =
            _orders(_collateralizedOrderA(), _orderB(), a2, b2);
        IDelayedSettlementSwapConductor.PairedFill memory secondPair = _pairedFill(100, 50);
        secondPair.orderIndexes = [uint256(2), uint256(3)];
        _seed(ACCOUNT_A, ASSET_A, 202);
        _seed(ACCOUNT_B, ASSET_B, 100);
        vm.expectEmit(address(conductor));
        emit IDelayedSettlementSwapConductor.Escrowed(1, conductor.hashOrder(orders[0]), conductor.hashOrder(orders[1]));
        vm.expectEmit(address(conductor));
        emit IDelayedSettlementSwapConductor.Escrowed(2, conductor.hashOrder(orders[2]), conductor.hashOrder(orders[3]));
        _settle(orders, _signatures(orders), _pairedFills(_pairedFill(100, 50), secondPair));
    }

    function test_settle_EmitsFilledEventForEachOrder() public {
        IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders =
            _orders(_collateralizedOrderA(), _orderB());
        bytes32 hashA = conductor.hashOrder(orders[0]);
        bytes32 hashB = conductor.hashOrder(orders[1]);
        _seed(ACCOUNT_A, ASSET_A, 101);
        _seed(ACCOUNT_B, ASSET_B, 50);
        vm.expectEmit(address(conductor));
        emit ISwapConductor.Filled(hashA, ACCOUNT_A, 100, 50);
        vm.expectEmit(address(conductor));
        emit ISwapConductor.Filled(hashB, ACCOUNT_B, 50, 100);
        _settle(orders, _signatures(orders), _pairedFills(_pairedFill(100, 50)));
    }

    function test_settle_ReleasesFundsToReceiversIfNeitherOrderIsCollateralized() public {
        IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders = _orders(_orderA(), _orderB());
        _seed(ACCOUNT_A, ASSET_A, 100);
        _seed(ACCOUNT_B, ASSET_B, 50);
        _settle(orders, _signatures(orders), _pairedFills(_pairedFill(100, 50)));
        assertEq(depot.balanceOf(RECEIVER_B, ASSET_A), 100, "counterparty receiver not paid");
        assertEq(depot.balanceOf(RECEIVER_A, ASSET_B), 50, "receiver not paid");
    }

    function test_settle_IgnoresSettlementPeriodsIfNeitherOrderIsCollateralized() public {
        IDelayedSettlementSwapConductor.DelayedSettlementOrder memory a = _orderA();
        a.settlementPeriod = 1 hours;
        IDelayedSettlementSwapConductor.DelayedSettlementOrder memory b = _orderB();
        b.settlementPeriod = 2 days;
        IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders = _orders(a, b);
        _seed(ACCOUNT_A, ASSET_A, 100);
        _seed(ACCOUNT_B, ASSET_B, 50);
        _settle(orders, _signatures(orders), _pairedFills(_pairedFill(100, 50)));
        assertEq(depot.balanceOf(RECEIVER_B, ASSET_A), 100, "counterparty receiver not paid");
        assertEq(depot.balanceOf(RECEIVER_A, ASSET_B), 50, "receiver not paid");
    }

    function test_settle_ReleasesFundsToFrozenReceiver() public {
        IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders = _orders(_orderA(), _orderB());
        _seed(ACCOUNT_A, ASSET_A, 100);
        _seed(ACCOUNT_B, ASSET_B, 50);
        _freeze(receiverA);
        _settle(orders, _signatures(orders), _pairedFills(_pairedFill(100, 50)));
        assertEq(depot.balanceOf(RECEIVER_A, ASSET_B), 50, "frozen receiver not paid");
    }

    function test_settle_DeletesEscrowIfNeitherOrderIsCollateralized() public {
        IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders = _orders(_orderA(), _orderB());
        _seed(ACCOUNT_A, ASSET_A, 100);
        _seed(ACCOUNT_B, ASSET_B, 50);
        _settle(orders, _signatures(orders), _pairedFills(_pairedFill(100, 50)));
        _assertEscrowDeleted(1);
    }

    function test_settle_EmitsReleasedEventForEachPairedFillIfNeitherOrderIsCollateralized() public {
        IDelayedSettlementSwapConductor.DelayedSettlementOrder memory a2 = _orderA();
        IDelayedSettlementSwapConductor.DelayedSettlementOrder memory b2 = _orderB();
        a2.salt = bytes32(uint256(3));
        b2.salt = bytes32(uint256(4));
        IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders = _orders(_orderA(), _orderB(), a2, b2);
        IDelayedSettlementSwapConductor.PairedFill memory secondPair = _pairedFill(100, 50);
        secondPair.orderIndexes = [uint256(2), uint256(3)];
        _seed(ACCOUNT_A, ASSET_A, 200);
        _seed(ACCOUNT_B, ASSET_B, 100);
        vm.expectEmit(address(conductor));
        emit IDelayedSettlementSwapConductor.Released(1);
        vm.expectEmit(address(conductor));
        emit IDelayedSettlementSwapConductor.Released(2);
        _settle(orders, _signatures(orders), _pairedFills(_pairedFill(100, 50), secondPair));
    }

    function test_settle_RevertIf_SenderIsUnauthorized() public {
        uint256 epoch = depot.settlementEpoch();
        IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders =
            _orders(_collateralizedOrderA(), _orderB());
        bytes[] memory signatures = _signatures(orders);
        IDelayedSettlementSwapConductor.PairedFill[] memory fills = _pairedFills(_pairedFill(100, 50));
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        vm.prank(stranger);
        conductor.settle(epoch, orders, signatures, fills);
    }

    function test_settle_RevertIf_EpochIsNotCurrentSettlementEpoch() public {
        uint256 epoch = depot.settlementEpoch() + 1;
        IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders =
            _orders(_collateralizedOrderA(), _orderB());
        bytes[] memory signatures = _signatures(orders);
        IDelayedSettlementSwapConductor.PairedFill[] memory fills = _pairedFills(_pairedFill(100, 50));
        vm.expectRevert(abi.encodeWithSelector(ISwapConductor.BadEpoch.selector, epoch));
        _settleAt(epoch, orders, signatures, fills);
    }

    function test_settle_RevertIf_OrdersAndSignaturesLengthsDiffer() public {
        uint256 epoch = depot.settlementEpoch();
        IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders =
            _orders(_collateralizedOrderA(), _orderB());
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _sign(OWNER_A_PK, conductor.hashOrder(orders[0]));
        vm.expectRevert(ISwapConductor.LengthMismatch.selector);
        _settleAt(epoch, orders, signatures, _pairedFills(_pairedFill(100, 50)));
    }

    function test_settle_RevertIf_OrderIsExpired() public {
        uint256 epoch = depot.settlementEpoch();
        IDelayedSettlementSwapConductor.DelayedSettlementOrder memory a = _collateralizedOrderA();
        a.expiresAt = block.timestamp;
        bytes32 orderHash = conductor.hashOrder(a);
        IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders = _orders(a, _orderB());
        bytes[] memory signatures = _signatures(orders);
        vm.expectRevert(abi.encodeWithSelector(ISwapConductor.Expired.selector, orderHash));
        _settleAt(epoch, orders, signatures, _pairedFills(_pairedFill(100, 50)));
    }

    function test_settle_RevertIf_SignatureIsNotFromOrderOwner() public {
        uint256 epoch = depot.settlementEpoch();
        IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders =
            _orders(_collateralizedOrderA(), _orderB());
        bytes[] memory signatures = _signatures(orders);
        signatures[0] = _sign(OWNER_B_PK, conductor.hashOrder(orders[0]));
        vm.expectRevert(ISwapConductor.BadSignature.selector);
        _settleAt(epoch, orders, signatures, _pairedFills(_pairedFill(100, 50)));
    }

    function test_settle_RevertIf_SignatureIsEmptyAndOrderIsNotPreApproved() public {
        uint256 epoch = depot.settlementEpoch();
        IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders =
            _orders(_collateralizedOrderA(), _orderB());
        bytes32 orderHash = conductor.hashOrder(orders[0]);
        bytes[] memory signatures = _signatures(orders);
        signatures[0] = bytes("");
        vm.expectRevert(abi.encodeWithSelector(ISwapConductor.NotPreApproved.selector, orderHash));
        _settleAt(epoch, orders, signatures, _pairedFills(_pairedFill(100, 50)));
    }

    function test_settle_RevertIf_PairReferencesSameOrderForBothSides() public {
        uint256 epoch = depot.settlementEpoch();
        IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders =
            _orders(_collateralizedOrderA(), _orderB());
        bytes[] memory signatures = _signatures(orders);
        IDelayedSettlementSwapConductor.PairedFill memory fill = _pairedFill(100, 50);
        fill.orderIndexes = [uint256(0), uint256(0)];
        vm.expectRevert(abi.encodeWithSelector(IDelayedSettlementSwapConductor.BadPair.selector, 0));
        _settleAt(epoch, orders, signatures, _pairedFills(fill));
    }

    function test_settle_RevertIf_SellTokenOfOneSideIsNotBuyTokenOfOther() public {
        uint256 epoch = depot.settlementEpoch();
        IDelayedSettlementSwapConductor.DelayedSettlementOrder memory b = _orderB();
        b.sellToken = makeAddr("tokenC");
        IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders = _orders(_collateralizedOrderA(), b);
        bytes[] memory signatures = _signatures(orders);
        vm.expectRevert(abi.encodeWithSelector(IDelayedSettlementSwapConductor.BadPair.selector, 0));
        _settleAt(epoch, orders, signatures, _pairedFills(_pairedFill(100, 50)));
    }

    function test_settle_RevertIf_FillAmountIsZeroOnFirstSide() public {
        uint256 epoch = depot.settlementEpoch();
        IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders =
            _orders(_collateralizedOrderA(), _orderB());
        bytes[] memory signatures = _signatures(orders);
        vm.expectRevert(abi.encodeWithSelector(IDelayedSettlementSwapConductor.BadPair.selector, 0));
        _settleAt(epoch, orders, signatures, _pairedFills(_pairedFill(0, 50)));
    }

    function test_settle_RevertIf_FillAmountIsZeroOnSecondSide() public {
        uint256 epoch = depot.settlementEpoch();
        IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders =
            _orders(_collateralizedOrderA(), _orderB());
        bytes[] memory signatures = _signatures(orders);
        vm.expectRevert(abi.encodeWithSelector(IDelayedSettlementSwapConductor.BadPair.selector, 0));
        _settleAt(epoch, orders, signatures, _pairedFills(_pairedFill(100, 0)));
    }

    function test_settle_RevertIf_SettlementPeriodExceedsMaximum() public {
        uint256 epoch = depot.settlementEpoch();
        IDelayedSettlementSwapConductor.DelayedSettlementOrder memory a = _collateralizedOrderA();
        a.settlementPeriod = 2 days;
        IDelayedSettlementSwapConductor.DelayedSettlementOrder memory b = _orderB();
        b.settlementPeriod = 2 days;
        IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders = _orders(a, b);
        bytes[] memory signatures = _signatures(orders);
        vm.expectRevert(abi.encodeWithSelector(IDelayedSettlementSwapConductor.BadPair.selector, 0));
        _settleAt(epoch, orders, signatures, _pairedFills(_pairedFill(100, 50)));
    }

    function test_settle_RevertIf_SettlementPeriodsOfCollateralizedSidesDiffer() public {
        uint256 epoch = depot.settlementEpoch();
        IDelayedSettlementSwapConductor.DelayedSettlementOrder memory b = _orderBCollateralized();
        b.settlementPeriod = 2 hours;
        IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders = _orders(_collateralizedOrderA(), b);
        bytes[] memory signatures = _signatures(orders);
        vm.expectRevert(abi.encodeWithSelector(IDelayedSettlementSwapConductor.BadPair.selector, 0));
        _settleAt(epoch, orders, signatures, _pairedFills(_pairedFill(100, 50)));
    }

    function test_settle_RevertIf_CollateralizedSideHasLongerSettlementPeriod() public {
        uint256 epoch = depot.settlementEpoch();
        IDelayedSettlementSwapConductor.DelayedSettlementOrder memory a = _collateralizedOrderA();
        a.settlementPeriod = 2 hours;
        IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders = _orders(a, _orderB());
        bytes[] memory signatures = _signatures(orders);
        vm.expectRevert(abi.encodeWithSelector(IDelayedSettlementSwapConductor.BadPair.selector, 0));
        _settleAt(epoch, orders, signatures, _pairedFills(_pairedFill(100, 50)));
    }

    function test_settle_RevertIf_CounterpartyAmountLessFeesIsBelowLimitPrice() public {
        uint256 epoch = depot.settlementEpoch();
        IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders =
            _orders(_collateralizedOrderA(), _orderB());
        bytes32 orderHash = conductor.hashOrder(orders[0]);
        bytes[] memory signatures = _signatures(orders);
        IDelayedSettlementSwapConductor.PairedFill memory fill = _pairedFill(100, 50);
        fill.fees = [uint256(0), uint256(1)];
        vm.expectRevert(abi.encodeWithSelector(ISwapConductor.LimitPrice.selector, orderHash));
        _settleAt(epoch, orders, signatures, _pairedFills(fill));
    }

    function test_settle_RevertIf_OrderIsNotFullyFilledAndNotPartiallyFillable() public {
        uint256 epoch = depot.settlementEpoch();
        IDelayedSettlementSwapConductor.DelayedSettlementOrder memory b = _orderB();
        b.partiallyFillable = false;
        bytes32 orderHash = conductor.hashOrder(b);
        IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders = _orders(_collateralizedOrderA(), b);
        bytes[] memory signatures = _signatures(orders);
        vm.expectRevert(abi.encodeWithSelector(ISwapConductor.NotPartiallyFillable.selector, orderHash));
        _settleAt(epoch, orders, signatures, _pairedFills(_pairedFill(80, 40)));
    }

    function test_settle_RevertIf_FillWouldExceedSellAmountOfOrder() public {
        uint256 epoch = depot.settlementEpoch();
        IDelayedSettlementSwapConductor.DelayedSettlementOrder memory b = _orderB();
        b.sellAmount = 60;
        IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders = _orders(_collateralizedOrderA(), b);
        bytes32 orderHash = conductor.hashOrder(orders[0]);
        bytes[] memory signatures = _signatures(orders);
        vm.expectRevert(abi.encodeWithSelector(ISwapConductor.Overfill.selector, orderHash));
        _settleAt(epoch, orders, signatures, _pairedFills(_pairedFill(101, 51)));
    }

    function test_settle_RevertIf_CancellationOfOrderIsEffectiveAtSettlementEpoch() public {
        uint256 epoch = depot.settlementEpoch();
        IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders =
            _orders(_collateralizedOrderA(), _orderB());
        bytes32 orderHash = conductor.hashOrder(orders[0]);
        bytes[] memory signatures = _signatures(orders);
        _relay(abi.encodeCall(ISwapConductor.requestOrderCancellation, (orderHash)), ACCOUNT_A, true);
        vm.expectRevert(abi.encodeWithSelector(ISwapConductor.Cancelled.selector, orderHash));
        _settleAt(epoch, orders, signatures, _pairedFills(_pairedFill(100, 50)));
    }

    function test_settle_RevertIf_CancellationOfOrderBecameEffectiveAtEarlierEpoch() public {
        IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders =
            _orders(_collateralizedOrderA(), _orderB());
        bytes32 orderHash = conductor.hashOrder(orders[0]);
        bytes[] memory signatures = _signatures(orders);
        _relay(abi.encodeCall(ISwapConductor.requestOrderCancellation, (orderHash)), ACCOUNT_A, true);
        vm.prank(seeder);
        depot.advanceEpoch();
        uint256 epoch = depot.settlementEpoch();
        assertGt(epoch, conductor.cancelledFrom(ACCOUNT_A, orderHash), "cancellation not from earlier epoch");
        vm.expectRevert(abi.encodeWithSelector(ISwapConductor.Cancelled.selector, orderHash));
        _settleAt(epoch, orders, signatures, _pairedFills(_pairedFill(100, 50)));
    }

    function test_settle_RevertIf_OwnerBalanceIsInsufficient() public {
        uint256 epoch = depot.settlementEpoch();
        IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders =
            _orders(_collateralizedOrderA(), _orderB());
        bytes[] memory signatures = _signatures(orders);
        _seed(ACCOUNT_B, ASSET_B, 50);
        vm.expectRevert(IDepot.InsufficientBalance.selector);
        _settleAt(epoch, orders, signatures, _pairedFills(_pairedFill(100, 50)));
    }

    function test_settle_RevertIf_OrderOwnerIsFrozen() public {
        uint256 epoch = depot.settlementEpoch();
        IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders =
            _orders(_collateralizedOrderA(), _orderB());
        bytes[] memory signatures = _signatures(orders);
        _seed(ACCOUNT_A, ASSET_A, 101);
        _seed(ACCOUNT_B, ASSET_B, 50);
        _freeze(ownerA);
        vm.expectRevert(abi.encodeWithSelector(IDepot.AccountFrozen.selector, ACCOUNT_A));
        _settleAt(epoch, orders, signatures, _pairedFills(_pairedFill(100, 50)));
    }

    function test_repay_TransfersDebtAmountFromLegAccountToConductorAccount() public {
        uint256 escrowId = _escrowedBothCollateralized();
        vm.prank(ownerA);
        conductor.repay(escrowId, 0);
        assertEq(depot.balanceOf(CONDUCTOR_ACCOUNT, ASSET_A), 101, "debt amount not transferred");
    }

    function test_repay_SetsDebtOfLegToZero() public {
        uint256 escrowId = _escrowedBothCollateralized();
        vm.prank(ownerA);
        conductor.repay(escrowId, 0);
        (,,,, uint256 debt,,) = conductor.escrowLegs(escrowId, 0);
        assertEq(debt, 0, "debt not zeroed");
    }

    function test_repay_DoesNotReleaseEscrowWhileCounterpartyLegIsUnpaid() public {
        uint256 escrowId = _escrowedBothCollateralized();
        vm.recordLogs();
        vm.prank(ownerA);
        conductor.repay(escrowId, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 releasedTopic = keccak256("Released(uint256)");
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != releasedTopic, "Released emitted");
        }
        (bytes28 accountId,,,,,,) = conductor.escrowLegs(escrowId, 0);
        assertEq(accountId, ACCOUNT_A, "escrow released");
    }

    function test_repay_ReleasesEscrowWhenBothLegsArePaid() public {
        uint256 escrowId = _escrowed();
        vm.prank(ownerA);
        conductor.repay(escrowId, 0);
        assertEq(depot.balanceOf(RECEIVER_B, ASSET_A), 100, "counterparty receiver not paid");
        assertEq(depot.balanceOf(RECEIVER_A, ASSET_B), 50, "receiver not paid");
    }

    function test_repay_PaysCounterpartyReceiverAmountLessFeeOnRelease() public {
        IDelayedSettlementSwapConductor.DelayedSettlementOrder memory a = _collateralizedOrderA();
        a.sellAmount = 110;
        IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders = _orders(a, _orderB());
        _seed(ACCOUNT_A, ASSET_A, 112);
        _seed(ACCOUNT_B, ASSET_B, 50);
        IDelayedSettlementSwapConductor.PairedFill memory fill = _pairedFill(110, 50);
        fill.fees = [uint256(10), uint256(0)];
        _settle(orders, _signatures(orders), _pairedFills(fill));
        vm.prank(ownerA);
        conductor.repay(1, 0);
        assertEq(depot.balanceOf(RECEIVER_B, ASSET_A), 100, "receiver paid without fee deducted");
        assertEq(depot.balanceOf(RECEIVER_A, ASSET_B), 50, "receiver not paid in full");
    }

    function test_repay_PaysFeeToSurplusRecipientAccountOnRelease() public {
        IDelayedSettlementSwapConductor.DelayedSettlementOrder memory a = _collateralizedOrderA();
        a.sellAmount = 110;
        IDelayedSettlementSwapConductor.DelayedSettlementOrder[] memory orders = _orders(a, _orderB());
        _seed(ACCOUNT_A, ASSET_A, 112);
        _seed(ACCOUNT_B, ASSET_B, 50);
        IDelayedSettlementSwapConductor.PairedFill memory fill = _pairedFill(110, 50);
        fill.fees = [uint256(10), uint256(0)];
        _settle(orders, _signatures(orders), _pairedFills(fill));
        vm.prank(ownerA);
        conductor.repay(1, 0);
        assertEq(depot.balanceOf(SURPLUS, ASSET_A), 10, "fee not paid to surplus recipient");
    }

    function test_repay_ReturnsCollateralToLegAccountOnRelease() public {
        uint256 escrowId = _escrowed();
        vm.prank(ownerA);
        conductor.repay(escrowId, 0);
        assertEq(depot.balanceOf(ACCOUNT_A, ASSET_A), 1, "collateral not returned");
    }

    function test_repay_DeletesEscrowLegsAndDeadlineOnRelease() public {
        uint256 escrowId = _escrowed();
        vm.prank(ownerA);
        conductor.repay(escrowId, 0);
        _assertEscrowDeleted(escrowId);
    }

    function test_repay_EmitsRepaidEvent() public {
        uint256 escrowId = _escrowed();
        vm.expectEmit(address(conductor));
        emit IDelayedSettlementSwapConductor.Repaid(escrowId, 0);
        vm.prank(ownerA);
        conductor.repay(escrowId, 0);
    }

    function test_repay_EmitsReleasedEventWhenBothLegsArePaid() public {
        uint256 escrowId = _escrowed();
        vm.expectEmit(address(conductor));
        emit IDelayedSettlementSwapConductor.Released(escrowId);
        vm.prank(ownerA);
        conductor.repay(escrowId, 0);
    }

    function test_repay_RevertIf_EscrowDeadlineHasPassed() public {
        uint256 escrowId = _escrowed();
        vm.warp(conductor.escrowDeadline(escrowId) + 1);
        vm.expectRevert(IDelayedSettlementSwapConductor.SettlementPeriodOver.selector);
        vm.prank(ownerA);
        conductor.repay(escrowId, 0);
    }

    function test_repay_RevertIf_EscrowDoesNotExist() public {
        vm.expectRevert(IDelayedSettlementSwapConductor.SettlementPeriodOver.selector);
        vm.prank(ownerA);
        conductor.repay(999, 0);
    }

    function test_repay_RevertIf_SenderIsNotLegOwner() public {
        uint256 escrowId = _escrowed();
        vm.expectRevert(ISwapConductor.NotOwner.selector);
        vm.prank(stranger);
        conductor.repay(escrowId, 0);
    }

    function test_repay_RevertIf_LegAccountIsFrozen() public {
        uint256 escrowId = _escrowed();
        _freeze(ownerA);
        vm.expectRevert(abi.encodeWithSelector(IDepot.AccountFrozen.selector, ACCOUNT_A));
        vm.prank(ownerA);
        conductor.repay(escrowId, 0);
    }

    function test_repay_RevertIf_LegHasNothingOwed() public {
        uint256 escrowId = _escrowed();
        vm.expectRevert(IDelayedSettlementSwapConductor.NothingOwed.selector);
        vm.prank(ownerB);
        conductor.repay(escrowId, 1);
    }

    function test_repay_RevertIf_SideIsOutOfBounds() public {
        uint256 escrowId = _escrowed();
        vm.expectRevert(stdError.indexOOBError);
        vm.prank(ownerA);
        conductor.repay(escrowId, 2);
    }

    function test_reclaim_ReturnsAmountAndCollateralToPaidLegAccount() public {
        uint256 escrowId = _escrowedBothCollateralized();
        vm.prank(ownerA);
        conductor.repay(escrowId, 0);
        vm.warp(conductor.escrowDeadline(escrowId) + 1);
        uint256[] memory escrowIds = new uint256[](1);
        escrowIds[0] = escrowId;
        conductor.reclaim(escrowIds);
        assertEq(depot.balanceOf(ACCOUNT_A, ASSET_A), 101, "paid leg not refunded amount and collateral");
    }

    function test_reclaim_ReturnsAmountAndCollateralToFrozenPaidLegAccount() public {
        uint256 escrowId = _escrowedBothCollateralized();
        vm.prank(ownerA);
        conductor.repay(escrowId, 0);
        _freeze(ownerA);
        vm.warp(conductor.escrowDeadline(escrowId) + 1);
        uint256[] memory escrowIds = new uint256[](1);
        escrowIds[0] = escrowId;
        conductor.reclaim(escrowIds);
        assertEq(depot.balanceOf(ACCOUNT_A, ASSET_A), 101, "frozen paid leg not refunded amount and collateral");
    }

    function test_reclaim_SendsCollateralOfUnpaidLegToPenaltyRecipientAccount() public {
        uint256 escrowId = _escrowedBothCollateralized();
        vm.warp(conductor.escrowDeadline(escrowId) + 1);
        uint256[] memory escrowIds = new uint256[](1);
        escrowIds[0] = escrowId;
        conductor.reclaim(escrowIds);
        assertEq(depot.balanceOf(PENALTY, ASSET_A), 1, "leg 0 collateral not penalized");
        assertEq(depot.balanceOf(PENALTY, ASSET_B), 1, "leg 1 collateral not penalized");
    }

    function test_reclaim_DeletesEscrowLegsAndDeadline() public {
        uint256 escrowId = _escrowedBothCollateralized();
        vm.warp(conductor.escrowDeadline(escrowId) + 1);
        uint256[] memory escrowIds = new uint256[](1);
        escrowIds[0] = escrowId;
        conductor.reclaim(escrowIds);
        _assertEscrowDeleted(escrowId);
    }

    function test_reclaim_AcceptsEmptyEscrowIdsArray() public {
        conductor.reclaim(new uint256[](0));
    }

    function test_reclaim_EmitsReclaimedEvent() public {
        uint256 escrowId = _escrowedBothCollateralized();
        vm.warp(conductor.escrowDeadline(escrowId) + 1);
        uint256[] memory escrowIds = new uint256[](1);
        escrowIds[0] = escrowId;
        vm.expectEmit(address(conductor));
        emit IDelayedSettlementSwapConductor.Reclaimed(escrowId);
        conductor.reclaim(escrowIds);
    }

    function test_reclaim_RevertIf_SettlementPeriodIsStillActive() public {
        uint256 escrowId = _escrowedBothCollateralized();
        uint256[] memory escrowIds = new uint256[](1);
        escrowIds[0] = escrowId;
        vm.expectRevert(IDelayedSettlementSwapConductor.SettlementPeriodActive.selector);
        conductor.reclaim(escrowIds);
    }

    function test_hashOrder_ReturnsEip712DigestOfOrder() public view {
        IDelayedSettlementSwapConductor.DelayedSettlementOrder memory a = _collateralizedOrderA();
        bytes32 structHash = keccak256(abi.encode(Typehashes.DELAYED_SETTLEMENT_ORDER, a));
        bytes32 expected = keccak256(abi.encodePacked("\x19\x01", conductor.DOMAIN_SEPARATOR(), structHash));
        assertEq(conductor.hashOrder(a), expected, "order digest wrong");
    }

}
