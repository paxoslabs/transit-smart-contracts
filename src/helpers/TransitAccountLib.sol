// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

library TransitAccountLib {

    function formatAccountId(uint64 chainId, address account) internal pure returns (bytes28) {
        return bytes28(uint224(chainId) << 160 | uint160(account));
    }

    function parseAccountId(bytes28 accountId) internal pure returns (uint64 chainId, address account) {
        chainId = uint64(uint224(accountId) >> 160);
        account = address(uint160(uint224(accountId)));
    }

    function isValid(bytes28 accountId) internal pure returns (bool) {
        (uint64 chainId, address account) = parseAccountId(accountId);
        return chainId != 0 && account != address(0);
    }

}
