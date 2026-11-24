// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { Test } from "forge-std/Test.sol";
import { TransitAddressLib } from "src/helpers/TransitAddressLib.sol";

contract TransitAddressLibUnitTest is Test {

    function test_formatTransitAddress_ReturnsLiteralEncodingForKnownInputs() public pure {
        assertEq(
            TransitAddressLib.formatTransitAddress(1, 0x1111111111111111111111111111111111111111),
            bytes28(0x00000000000000011111111111111111111111111111111111111111),
            "transit address does not match literal encoding"
        );
    }

    function test_formatTransitAddress_PlacesChainIdInTopEightBytes(uint64 chainId, address account) public pure {
        bytes28 transitAddress = TransitAddressLib.formatTransitAddress(chainId, account);
        assertEq(uint64(uint224(transitAddress) >> 160), chainId, "chain id not in top 8 bytes");
    }

    function test_formatTransitAddress_PlacesAddressInBottomTwentyBytes(uint64 chainId, address account) public pure {
        bytes28 transitAddress = TransitAddressLib.formatTransitAddress(chainId, account);
        assertEq(address(uint160(uint224(transitAddress))), account, "address not in bottom 20 bytes");
    }

    function test_formatTransitAddress_ReturnsZeroForZeroChainIdAndZeroAddress() public pure {
        assertEq(TransitAddressLib.formatTransitAddress(0, address(0)), bytes28(0), "transit address not zero");
    }

    function test_parseTransitAddress_ReturnsChainIdFromTopEightBytes(bytes28 transitAddress) public pure {
        (uint64 chainId,) = TransitAddressLib.parseTransitAddress(transitAddress);
        assertEq(chainId, uint64(uint224(transitAddress) >> 160), "chain id not from top 8 bytes");
    }

    function test_parseTransitAddress_ReturnsAddressFromBottomTwentyBytes(bytes28 transitAddress) public pure {
        (, address account) = TransitAddressLib.parseTransitAddress(transitAddress);
        assertEq(account, address(uint160(uint224(transitAddress))), "address not from bottom 20 bytes");
    }

    function test_parseTransitAddress_InvertsFormatTransitAddress(uint64 chainId, address account) public pure {
        (uint64 parsedChainId, address parsedAccount) =
            TransitAddressLib.parseTransitAddress(TransitAddressLib.formatTransitAddress(chainId, account));
        assertEq(parsedChainId, chainId, "chain id not recovered");
        assertEq(parsedAccount, account, "address not recovered");
    }

    function test_isValid_ReturnsTrueIfChainIdAndAddressAreNonzero(uint64 chainId, address account) public pure {
        vm.assume(chainId != 0 && account != address(0));
        assertTrue(
            TransitAddressLib.isValid(TransitAddressLib.formatTransitAddress(chainId, account)),
            "nonzero transit address invalid"
        );
    }

    function test_isValid_ReturnsFalseIfChainIdIsZero(address account) public pure {
        assertFalse(
            TransitAddressLib.isValid(TransitAddressLib.formatTransitAddress(0, account)), "zero chain id valid"
        );
    }

    function test_isValid_ReturnsFalseIfAddressIsZero(uint64 chainId) public pure {
        assertFalse(
            TransitAddressLib.isValid(TransitAddressLib.formatTransitAddress(chainId, address(0))), "zero address valid"
        );
    }

    function test_isValid_ReturnsFalseForZeroTransitAddress() public pure {
        assertFalse(TransitAddressLib.isValid(bytes28(0)), "zero transit address valid");
    }

}
