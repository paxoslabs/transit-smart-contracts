// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

interface IFallbackHook {

    function onFallback(address sender, bytes calldata data) external payable returns (bytes memory);

}
