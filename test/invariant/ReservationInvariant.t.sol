// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { Test } from "forge-std/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { AddressFreezeList } from "src/AddressFreezeList.sol";
import { Depot } from "src/depot/Depot.sol";
import { IDepot } from "src/interfaces/IDepot.sol";
import { Roles } from "src/helpers/Roles.sol";
import { TransitAddressLib } from "src/helpers/TransitAddressLib.sol";

/// @dev Acts as a conductor on the Depot with random mints, debits, reservations, releases and epoch
/// advances, and keeps a model of each account's balance and effective/pending reservation. Any call whose outcome
/// disagrees with the model is counted as a violation.
contract ReservationHandler is Test {

    struct Model {
        uint256 balance;
        uint256 effective;
        uint256 pending;
        uint256 pendingEpoch;
    }

    Depot depot;
    bytes28 asset;
    bytes28[3] accounts;
    mapping(uint256 => Model) models;

    uint256 public debitViolations;
    uint256 public reserveViolations;
    uint256 public releaseViolations;
    uint256 public blockedDebits;
    uint256 public epochsAdvanced;

    constructor(Depot _depot, bytes28 _asset, bytes28[3] memory _accounts) {
        depot = _depot;
        asset = _asset;
        accounts = _accounts;
    }

    function mint(uint256 i, uint256 amount) external {
        i %= 3;
        amount = bound(amount, 1, 1e36);
        depot.mint(accounts[i], asset, amount);
        models[i].balance += amount;
    }

    function debit(uint256 from, uint256 to, uint256 amount) external {
        from %= 3;
        to %= 3;
        uint256 free = modelFree(from);
        amount = bound(amount, 0, models[from].balance + 1);
        try depot.transferFrom(accounts[from], accounts[to], asset, amount) {
            if (amount > free) debitViolations++;
            models[from].balance -= amount;
            models[to].balance += amount;
        } catch (bytes memory err) {
            if (amount <= free || bytes4(err) != IDepot.InsufficientBalance.selector) debitViolations++;
            blockedDebits++;
        }
    }

    function reserve(uint256 i, uint256 amount) external {
        i %= 3;
        amount = bound(amount, 0, 2 ** 113);
        uint256 freeBefore = depot.freeBalanceOf(accounts[i], asset);
        Model storage m = _roll(i);
        bool fits = m.effective + m.pending + amount <= type(uint112).max;
        try depot.reserve(accounts[i], asset, amount) {
            if (!fits) reserveViolations++;
            m.pending += amount;
            m.pendingEpoch = depot.settlementEpoch() + 1;
            if (depot.freeBalanceOf(accounts[i], asset) != freeBefore) reserveViolations++;
        } catch {
            if (fits) reserveViolations++;
        }
    }

    function release(uint256 i, uint256 amount) external {
        i %= 3;
        Model storage m = _roll(i);
        amount = bound(amount, 0, m.effective + m.pending + 1);
        try depot.release(accounts[i], asset, amount) {
            if (amount > m.effective) releaseViolations++;
            m.effective -= amount;
        } catch (bytes memory err) {
            if (amount <= m.effective || bytes4(err) != IDepot.ReleaseExceedsReserved.selector) releaseViolations++;
        }
    }

    function advanceEpoch() external {
        depot.advanceEpoch();
        epochsAdvanced++;
    }

    function modelBalance(uint256 i) external view returns (uint256) {
        return models[i].balance;
    }

    function modelFree(uint256 i) public view returns (uint256) {
        Model storage m = models[i];
        uint256 reserved = m.effective + (m.pendingEpoch <= depot.settlementEpoch() ? m.pending : 0);
        return m.balance > reserved ? m.balance - reserved : 0;
    }

    function _roll(uint256 i) internal returns (Model storage m) {
        m = models[i];
        if (m.pendingEpoch <= depot.settlementEpoch()) {
            m.effective += m.pending;
            m.pending = 0;
        }
    }

}

/// @dev Reservation invariants: free balance is always balance minus effective reservations (floored at 0); a
/// reservation never changes free balance in the epoch it is made, so the solver's funds for an epoch are fixed when it
/// starts; once effective, reserved funds can never be debited; only effective amounts can be released; and the
/// uint112 cap is enforced.
contract ReservationInvariant is Test {

    Depot depot;
    ReservationHandler handler;
    bytes28 asset = TransitAddressLib.formatTransitAddress(1, makeAddr("asset"));
    bytes28[3] accounts;

    function setUp() public {
        accounts[0] = TransitAddressLib.formatTransitAddress(1, makeAddr("account0"));
        accounts[1] = TransitAddressLib.formatTransitAddress(1, makeAddr("account1"));
        accounts[2] = TransitAddressLib.formatTransitAddress(4663, makeAddr("account2"));

        AccessManager accessManager = new AccessManager(address(this));
        depot = new Depot(address(accessManager), new AddressFreezeList(address(accessManager)));
        handler = new ReservationHandler(depot, asset, accounts);

        bytes4[] memory sels = new bytes4[](5);
        sels[0] = Depot.mint.selector;
        sels[1] = Depot.transferFrom.selector;
        sels[2] = Depot.reserve.selector;
        sels[3] = Depot.release.selector;
        sels[4] = Depot.advanceEpoch.selector;
        accessManager.setTargetFunctionRole(address(depot), sels, Roles.CONDUCTOR);
        accessManager.grantRole(Roles.CONDUCTOR, address(handler), 0);

        targetContract(address(handler));
    }

    function invariant_freeBalanceMatchesModel() public view {
        for (uint256 i; i < 3; i++) {
            assertEq(depot.balanceOf(accounts[i], asset), handler.modelBalance(i), "balance matches model");
            assertEq(depot.freeBalanceOf(accounts[i], asset), handler.modelFree(i), "free balance matches model");
        }
    }

    function invariant_effectiveReservationsNeverDebited() public view {
        assertEq(handler.debitViolations(), 0, "debit allowed beyond free balance, or blocked within it");
    }

    function invariant_reservingNeverChangesFreeBalanceThisEpoch() public view {
        assertEq(handler.reserveViolations(), 0, "reserve changed free balance or mishandled the uint112 cap");
    }

    function invariant_onlyEffectiveReservationsReleased() public view {
        assertEq(handler.releaseViolations(), 0, "release allowed beyond effective, or blocked within it");
    }

}
