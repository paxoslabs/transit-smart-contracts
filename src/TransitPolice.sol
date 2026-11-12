// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IFreezable } from "@predicate/interfaces/IFreezable.sol";
import { FREEZE_MANAGER_ROLE as _FREEZE_MANAGER_ROLE } from "./helpers/Constants.sol";
import { TransitTokenLib } from "./helpers/TransitTokenLib.sol";

contract TransitPolice is IFreezable, AccessManaged {

    mapping(address account => bool) internal _isFrozen;

    constructor(address _authority) AccessManaged(_authority) { }

    function freeze(address account) external restricted {
        _freeze(account);
    }

    function freezeAccounts(address[] calldata accounts) external restricted {
        for (uint256 i; i < accounts.length; ++i) {
            _freeze(accounts[i]);
        }
    }

    function unfreeze(address account) external restricted {
        _unfreeze(account);
    }

    function unfreezeAccounts(address[] calldata accounts) external restricted {
        for (uint256 i; i < accounts.length; ++i) {
            _unfreeze(accounts[i]);
        }
    }

    function isFrozen(bytes32 accountId) external view returns (bool) {
        (, address account) = TransitTokenLib.parseAccountId(accountId);
        return _isFrozen[account];
    }

    function isFrozen(address account) external view returns (bool) {
        return _isFrozen[account];
    }

    function FREEZE_MANAGER_ROLE() external pure returns (bytes32) {
        return _FREEZE_MANAGER_ROLE;
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
