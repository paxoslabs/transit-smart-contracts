// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

/**
 * @title TransitAccountLib
 * @notice Encodes an address on a chain as a bytes28 id: the uint64 chainId in the top 8 bytes and the address in the
 * bottom 20. Used for both accounts and assets throughout Transit.
 * @dev 28 rather than 32 bytes leaves 4 bytes of a word free for metadata, e.g. TurnstileGated packs an account and
 * 4 bytes of flags into one 32-byte calldata suffix. bytes28(0) is reserved by the Depot as the mint/burn sentinel and
 * is never valid.
 */
library TransitAccountLib {

    function formatAccountId(uint64 chainId, address account) internal pure returns (bytes28) {
        return bytes28(uint224(chainId) << 160 | uint160(account));
    }

    function parseAccountId(bytes28 accountId) internal pure returns (uint64 chainId, address account) {
        chainId = uint64(uint224(accountId) >> 160);
        account = address(uint160(uint224(accountId)));
    }

    /// @dev Whether an id can hold or move a balance: both chainId and address must be nonzero. Rejects the Depot's
    /// bytes28(0) mint/burn sentinel and ids with only one half set.
    function isValid(bytes28 accountId) internal pure returns (bool) {
        (uint64 chainId, address account) = parseAccountId(accountId);
        return chainId != 0 && account != address(0);
    }

}
