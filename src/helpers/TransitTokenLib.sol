// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

library TransitTokenLib {

    function formatAccountId(uint64 chainId, address account) internal pure returns (bytes32) {
        return bytes32(uint256(chainId) << 160 | uint160(account));
    }

    function parseAccountId(bytes32 accountId) internal pure returns (uint64 chainId, address account) {
        chainId = uint64(uint256(accountId) >> 160);
        account = address(uint160(uint256(accountId)));
    }

    function formatAssetId(uint64 chainId, address asset) internal pure returns (bytes32) {
        return bytes32(uint256(chainId) << 160 | uint160(asset));
    }

    function formatFacilitatedAccountId(bytes32 accountId) internal pure returns (bytes32) {
        return accountId | bytes32(uint256(1) << 224);
    }

    function clearFlags(bytes32 id) internal pure returns (bytes32) {
        return bytes32(uint256(id) & type(uint224).max);
    }

    function hasFlags(bytes32 assetId) internal pure returns (bool) {
        return uint256(assetId) >> 224 != 0;
    }

    function parseAssetId(bytes32 assetId) internal pure returns (uint64 chainId, address asset) {
        chainId = uint64(uint256(assetId) >> 160);
        asset = address(uint160(uint256(assetId)));
    }

}
