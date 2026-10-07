// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { ERC20 } from "solady/tokens/ERC20.sol";
import { EIP712 } from "solady/utils/EIP712.sol";
import { SignatureCheckerLib } from "solady/utils/SignatureCheckerLib.sol";
import { MessagingEndpoint } from "./messaging/MessagingEndpoint.sol";

contract Hub is MessagingEndpoint, EIP712 {

    struct WithdrawRequest {
        address owner;
        ERC20 asset;
        uint64 assetChainId;
        uint256 amount;
        address to;
        uint256 nonce;
    }

    bytes32 public constant WITHDRAW_REQUEST_TYPEHASH = keccak256(
        "WithdrawRequest(address owner,address asset,uint64 assetChainId,uint256 amount,address to,uint256 nonce)"
    );

    mapping(address user => mapping(uint64 assetChainId => mapping(address asset => uint256))) public balanceOf;
    mapping(bytes32 withdrawId => bool) public withdrawUsed;

    event Transfer(address indexed from, address indexed to, uint64 assetChainId, address indexed asset, uint256 amount);
    event Withdraw(bytes32 indexed withdrawId, address indexed asset, address indexed to, uint256 amount);

    error BadSignature();
    error WithdrawReplay();
    error ZeroAddress();
    error LengthMismatch();
    error ChainMismatch(uint64 chainId);

    constructor(address _authority) MessagingEndpoint(_authority) { }

    /// TODO: Decide the EIP712 domain name and version. Currently "Transit Hub" and "1".
    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return ("Transit Hub", "1");
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparator();
    }

    // ========================================= LEDGER =========================================

    function transferFrom(
        address from,
        address to,
        uint64 assetChainId,
        address asset,
        uint256 amount
    )
        external
        restricted
    {
        _requireNotPaused();
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        _transfer(from, to, assetChainId, asset, amount);
    }

    // ========================================= USER =========================================

    function withdrawWithSignature(
        WithdrawRequest[] calldata requests,
        bytes[] calldata signatures,
        BridgeData calldata data
    )
        external
        payable
        restricted
        nonReentrant
        returns (bytes32[] memory withdrawIds)
    {
        _requireNotPaused();
        if (requests.length != signatures.length) revert LengthMismatch();

        uint64 assetChainId = requests[0].assetChainId;
        withdrawIds = new bytes32[](requests.length);
        TransferMessage[] memory messages = new TransferMessage[](requests.length);

        for (uint256 i; i < requests.length; i++) {
            WithdrawRequest calldata request = requests[i];
            if (request.assetChainId != assetChainId) revert ChainMismatch(request.assetChainId);

            bytes32 withdrawId = hashWithdrawRequest(request);
            if (withdrawUsed[withdrawId]) revert WithdrawReplay();
            if (!SignatureCheckerLib.isValidSignatureNowCalldata(request.owner, withdrawId, signatures[i])) {
                revert BadSignature();
            }
            withdrawUsed[withdrawId] = true;
            withdrawIds[i] = withdrawId;

            _transfer(request.owner, address(0), assetChainId, address(request.asset), request.amount);

            messages[i] = TransferMessage({
                asset: address(request.asset),
                nonce: ++outboundNonce,
                amount: request.amount,
                to: request.to
            });

            emit Withdraw(withdrawId, address(request.asset), request.to, request.amount);
        }

        bytes32 messageId =
            _sendMessage(assetChainId, data.messageGas, MessageType.Withdrawal, abi.encode(messages));

        for (uint256 i; i < messages.length; i++) {
            emit MessageSent(messageId, messages[i].amount, messages[i].to);
        }
    }

    // ========================================= ADAPTER ========================================

    function _handleMessage(uint64 chainId, MessageType messageType, bytes memory body) internal override {
        if (messageType == MessageType.Deposit) {
            _receiveTransfer(chainId, abi.decode(body, (TransferMessage)));
        } else {
            assert(false);
        }
    }

    function _receiveTransfer(uint64 sourceChainId, TransferMessage memory message) internal {
        _consume(sourceChainId, message.nonce);

        _requireNotPaused();

        _transfer(address(0), message.to, sourceChainId, message.asset, message.amount);

        emit MessageReceived(bytes32(message.nonce), message.amount, message.to);
    }

    // ========================================= VIEWS =========================================

    function hashWithdrawRequest(WithdrawRequest calldata request) public view returns (bytes32) {
        return _hashTypedData(
            keccak256(
                abi.encode(
                    WITHDRAW_REQUEST_TYPEHASH,
                    request.owner,
                    address(request.asset),
                    request.assetChainId,
                    request.amount,
                    request.to,
                    request.nonce
                )
            )
        );
    }

    // ========================================= INTERNAL =========================================

    function _transfer(address from, address to, uint64 assetChainId, address asset, uint256 amount) internal {
        if (from != address(0)) balanceOf[from][assetChainId][asset] -= amount;
        if (to != address(0)) balanceOf[to][assetChainId][asset] += amount;
        emit Transfer(from, to, assetChainId, asset, amount);
    }

}
