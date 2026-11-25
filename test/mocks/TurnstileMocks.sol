// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { ERC20 } from "solady/tokens/ERC20.sol";
import { ITurnstile } from "src/interfaces/ITurnstile.sol";

contract MockERC20 is ERC20 {

    function name() public pure override returns (string memory) {
        return "Mock";
    }

    function symbol() public pure override returns (string memory) {
        return "MOCK";
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

}

contract MockMessagingAdapter {

    uint64 public HUB_CHAIN_ID;
    uint256 public sendCount;
    uint64 public lastChainId;
    uint64 public lastGasLimit;
    bytes public lastPayload;
    uint256 public lastValue;

    constructor(uint64 hubChainId) {
        HUB_CHAIN_ID = hubChainId;
    }

    function setHubChainId(uint64 hubChainId) external {
        HUB_CHAIN_ID = hubChainId;
    }

    function quote(uint64 chainId, uint64 gasLimit, bytes calldata payload) external pure returns (uint256) {
        return uint256(keccak256(abi.encode(chainId, gasLimit, payload))) >> 128;
    }

    function send(uint64 chainId, uint64 gasLimit, bytes calldata payload) external payable returns (bytes32) {
        sendCount++;
        lastChainId = chainId;
        lastGasLimit = gasLimit;
        lastPayload = payload;
        lastValue = msg.value;
        return keccak256(abi.encode(sendCount));
    }

}

contract MockHubWarehouseConductor {

    error Boom();

    bool public shouldRevert;
    uint256 public withdrawalAmount;
    bytes[] public calls;
    uint256[] public depositAmounts;

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function setWithdrawalAmount(uint256 amount) external {
        withdrawalAmount = amount;
    }

    function callCount() external view returns (uint256) {
        return calls.length;
    }

    function lastCall() external view returns (bytes memory) {
        return calls[calls.length - 1];
    }

    function receiveDeposit(uint64, address, uint256 amount, bytes28, bytes28, uint256, bytes28) external {
        if (shouldRevert) revert Boom();
        calls.push(msg.data);
        depositAmounts.push(amount);
    }

    function executeWithdrawal(ITurnstile.WithdrawalAction calldata) external returns (uint256) {
        if (shouldRevert) revert Boom();
        calls.push(msg.data);
        return withdrawalAmount;
    }

}

contract MockTarget {

    error Boom();

    bool public shouldRevert;
    uint256 public callCount;
    bytes public lastCall;

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function ping(uint256) external {
        if (shouldRevert) revert Boom();
        callCount++;
        lastCall = msg.data;
    }

    function spin() external pure {
        while (true) { }
    }

}
