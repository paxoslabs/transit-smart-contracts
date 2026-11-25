// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

/**
 * @title TransitAddressLib
 * @notice Encodes an address on a chain as a bytes28 transit address: the uint64 chainId in the top 8 bytes and the
 * address in the bottom 20. Neutral encoding used for both account ids and asset ids throughout Transit.
 * @dev 28 rather than 32 bytes leaves 4 bytes of a word free for metadata, e.g. Conductor packs an
 * account and 4 bytes of flags into one 32-byte calldata suffix. bytes28(0) is reserved by the Depot as the mint/burn
 * sentinel and is never valid.
 * @custom:security-contact security@paxoslabs.com
 */
library TransitAddressLib {

    function formatTransitAddress(uint64 chainId, address addr) internal pure returns (bytes28) {
        return bytes28(uint224(chainId) << 160 | uint160(addr));
    }

    function parseTransitAddress(bytes28 transitAddress) internal pure returns (uint64 chainId, address addr) {
        chainId = uint64(uint224(transitAddress) >> 160);
        addr = address(uint160(uint224(transitAddress)));
    }

    /// @dev Whether a transit address can hold or move a balance: both chainId and address must be nonzero. Rejects the
    /// Depot's bytes28(0) mint/burn sentinel and transit addresses with only one half set.
    function isValid(bytes28 transitAddress) internal pure returns (bool) {
        (uint64 chainId, address addr) = parseTransitAddress(transitAddress);
        return chainId != 0 && addr != address(0);
    }

}
