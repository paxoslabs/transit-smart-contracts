// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { Warehouse } from "../Warehouse.sol";

interface BeforeTransferHook {

    function beforeTransfer(address from, address to, address msgSender, uint256 amount) external view;
    function beforeWithdraw(address from, address to, address msgSender, uint256 amount) external view;
    function beforeBridge(address msgSender, uint256 shareAmount, Warehouse.BridgeData calldata data) external view;
    function beforeReceiveBridge(uint256 shareAmount, address destinationChainReceiver) external view;

}
