// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IFreezable } from "@predicate/interfaces/IFreezable.sol";
import { IAddressFreezeList } from "src/interfaces/IAddressFreezeList.sol";
import { Roles } from "src/helpers/Roles.sol";
import { TransitAddressLib } from "src/helpers/TransitAddressLib.sol";

/**
 * @title AddressFreezeList
 * @notice Compliance freeze list checked by the Depot on every debit. Frozen accounts can still receive funds but
 * cannot move them out; admins may seize them with Depot.forceTransferFrom.
 * @dev Implements Predicate's IFreezable so Predicate's freeze manager can enforce Asset Compliance freezes. Freezes
 * are keyed by address only, so freezing an address freezes it on every chain. Freeze functions must be mapped to
 * Roles.FREEZE_MANAGER in TransitAuthority.
 * @custom:security-contact security@paxoslabs.com
 */
contract AddressFreezeList is IAddressFreezeList, AccessManaged {

    mapping(address account => bool) internal _isFrozen;

    constructor(address _authority) AccessManaged(_authority) { }

    /// @inheritdoc IFreezable
    function freeze(address account) external restricted {
        _freeze(account);
    }

    /// @inheritdoc IFreezable
    function freezeAccounts(address[] calldata accounts) external restricted {
        for (uint256 i; i < accounts.length; ++i) {
            _freeze(accounts[i]);
        }
    }

    /// @inheritdoc IFreezable
    function unfreeze(address account) external restricted {
        _unfreeze(account);
    }

    /// @inheritdoc IFreezable
    function unfreezeAccounts(address[] calldata accounts) external restricted {
        for (uint256 i; i < accounts.length; ++i) {
            _unfreeze(accounts[i]);
        }
    }

    /// @inheritdoc IAddressFreezeList
    function isFrozen(bytes28 accountId) external view returns (bool) {
        (, address account) = TransitAddressLib.parseTransitAddress(accountId);
        return _isFrozen[account];
    }

    /// @inheritdoc IFreezable
    function isFrozen(address account) external view returns (bool) {
        return _isFrozen[account];
    }

    /// @inheritdoc IFreezable
    function FREEZE_MANAGER_ROLE() external pure returns (bytes32) {
        return Roles.FREEZE_MANAGER;
    }

    function _freeze(address account) internal {
        if (_isFrozen[account]) return;
        _isFrozen[account] = true;
        emit Frozen(account, block.timestamp);
    }

    function _unfreeze(address account) internal {
        if (!_isFrozen[account]) return;
        _isFrozen[account] = false;
        emit Unfrozen(account, block.timestamp);
    }

}
