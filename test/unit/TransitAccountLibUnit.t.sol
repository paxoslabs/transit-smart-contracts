// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { Test } from "forge-std/Test.sol";
import { TransitAccountLib } from "src/helpers/TransitAccountLib.sol";

contract TransitAccountLibUnitTest is Test {

    function test_formatAccountId_ReturnsLiteralEncodingForKnownInputs() public pure {
        assertEq(
            TransitAccountLib.formatAccountId(1, 0x1111111111111111111111111111111111111111),
            bytes28(0x00000000000000011111111111111111111111111111111111111111),
            "account id does not match literal encoding"
        );
    }

    function test_formatAccountId_PlacesChainIdInTopEightBytes(uint64 chainId, address account) public pure {
        bytes28 accountId = TransitAccountLib.formatAccountId(chainId, account);
        assertEq(uint64(uint224(accountId) >> 160), chainId, "chain id not in top 8 bytes");
    }

    function test_formatAccountId_PlacesAddressInBottomTwentyBytes(uint64 chainId, address account) public pure {
        bytes28 accountId = TransitAccountLib.formatAccountId(chainId, account);
        assertEq(address(uint160(uint224(accountId))), account, "address not in bottom 20 bytes");
    }

    function test_formatAccountId_ReturnsZeroForZeroChainIdAndZeroAddress() public pure {
        assertEq(TransitAccountLib.formatAccountId(0, address(0)), bytes28(0), "account id not zero");
    }

    function test_parseAccountId_ReturnsChainIdFromTopEightBytes(bytes28 accountId) public pure {
        (uint64 chainId,) = TransitAccountLib.parseAccountId(accountId);
        assertEq(chainId, uint64(uint224(accountId) >> 160), "chain id not from top 8 bytes");
    }

    function test_parseAccountId_ReturnsAddressFromBottomTwentyBytes(bytes28 accountId) public pure {
        (, address account) = TransitAccountLib.parseAccountId(accountId);
        assertEq(account, address(uint160(uint224(accountId))), "address not from bottom 20 bytes");
    }

    function test_parseAccountId_InvertsFormatAccountId(uint64 chainId, address account) public pure {
        (uint64 parsedChainId, address parsedAccount) =
            TransitAccountLib.parseAccountId(TransitAccountLib.formatAccountId(chainId, account));
        assertEq(parsedChainId, chainId, "chain id not recovered");
        assertEq(parsedAccount, account, "address not recovered");
    }

    function test_isValid_ReturnsTrueIfChainIdAndAddressAreNonzero(uint64 chainId, address account) public pure {
        vm.assume(chainId != 0 && account != address(0));
        assertTrue(
            TransitAccountLib.isValid(TransitAccountLib.formatAccountId(chainId, account)), "nonzero account id invalid"
        );
    }

    function test_isValid_ReturnsFalseIfChainIdIsZero(address account) public pure {
        assertFalse(TransitAccountLib.isValid(TransitAccountLib.formatAccountId(0, account)), "zero chain id valid");
    }

    function test_isValid_ReturnsFalseIfAddressIsZero(uint64 chainId) public pure {
        assertFalse(
            TransitAccountLib.isValid(TransitAccountLib.formatAccountId(chainId, address(0))), "zero address valid"
        );
    }

    function test_isValid_ReturnsFalseForZeroAccountId() public pure {
        assertFalse(TransitAccountLib.isValid(bytes28(0)), "zero account id valid");
    }

}
