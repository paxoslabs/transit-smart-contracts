// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { IMessagingAdapter } from "./IMessagingAdapter.sol";
import { IMessagingReceiver } from "./IMessagingReceiver.sol";

interface IMessagingEndpoint is IMessagingReceiver {

    function messagingAdapter() external view returns (IMessagingAdapter);

    function messageConsumed(bytes32 messageHash) external view returns (bool);

    function setMessagingAdapter(IMessagingAdapter adapter) external;

    function pause() external;

    function unpause() external;

}
