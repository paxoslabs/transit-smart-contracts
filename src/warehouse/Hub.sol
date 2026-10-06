// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";
import { EIP712 } from "solady/utils/EIP712.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SignatureCheckerLib } from "solady/utils/SignatureCheckerLib.sol";
import { Warehouse } from "./Warehouse.sol";
import { CrosschainAdapter } from "./crosschain/CrosschainAdapter.sol";

contract Hub is AccessManaged, EIP712, ReentrancyGuard {

    /// TODO: Decide the final WithdrawRequest fields. owner + nonce + deadline are what close the
    /// replay hole; requiring msg.sender == owner blocks gasless relayers.
    struct WithdrawRequest {
        address owner;
        ERC20 asset;
        uint64 assetChainId;
        uint256 amount;
        address to;
        uint256 nonce;
        uint256 deadline;
    }

    bytes32 public constant WITHDRAW_REQUEST_TYPEHASH = keccak256(
        "WithdrawRequest(address owner,address asset,uint64 assetChainId,uint256 amount,address to,uint256 nonce,uint256 deadline)"
    );

    Warehouse public warehouse;
    address public withdrawSigner;
    bool public isPaused;
    uint256 public outboundNonce;

    CrosschainAdapter public sendModule;

    mapping(address user => mapping(uint64 assetChainId => mapping(address asset => uint256))) public balanceOf;
    mapping(uint64 chainId => Warehouse.Chain) public chains;
    mapping(uint64 sourceChainId => mapping(uint256 nonce => bool)) public messageConsumed;
    mapping(bytes32 withdrawId => bool) public withdrawUsed;

    event Enter(address indexed to, uint64 indexed assetChainId, address indexed asset, uint256 amount);
    event Exit(address indexed from, uint64 indexed assetChainId, address indexed asset, uint256 amount);
    event Move(address indexed from, address indexed to, uint64 assetChainId, address indexed asset, uint256 amount);
    event WarehouseUpdated(address indexed warehouse);
    event WithdrawSignerUpdated(address indexed withdrawSigner);
    event SendModuleUpdated(address indexed module);
    event PauseSet(bool isPaused);
    event ChainAdded(uint64 indexed chainId, Warehouse.Chain chain);
    event ChainRemoved(uint64 indexed chainId);
    event Withdraw(bytes32 indexed withdrawId, address indexed asset, address indexed to, uint256 amount);
    event MessageSent(bytes32 messageId, uint256 shareAmount, address to);
    event MessageReceived(bytes32 messageId, uint256 shareAmount, address to);

    error Paused();
    error UnknownSourceChain(uint64 chainId);
    error BadSignature();
    error Expired();
    error WithdrawReplay();
    error MessageReplay();
    error UnknownModule();
    error MessagesNotAllowedFrom(uint64 chainId);
    error MessagesNotAllowedTo(uint64 chainId);
    error ZeroMessageGasLimit();
    error GasLimitExceeded();
    error GasTooLow();

    constructor(address _authority) AccessManaged(_authority) { }

    /// TODO: Decide the EIP712 domain name and version. Currently "Transit Hub" and "1".
    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return ("Transit Hub", "1");
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparator();
    }

    // ========================================= ADMIN =========================================

    function setWarehouse(Warehouse _warehouse) external restricted {
        warehouse = _warehouse;
        emit WarehouseUpdated(address(_warehouse));
    }

    function setWithdrawSigner(address _withdrawSigner) external restricted {
        withdrawSigner = _withdrawSigner;
        emit WithdrawSignerUpdated(_withdrawSigner);
    }

    function setSendModule(CrosschainAdapter module) external restricted {
        sendModule = module;
        emit SendModuleUpdated(address(module));
    }

    function setPaused(bool paused) external restricted {
        isPaused = paused;
        emit PauseSet(paused);
    }

    function addChain(
        uint64 chainId,
        bool allowMessagesFrom,
        bool allowMessagesTo,
        uint64 messageGasLimit,
        uint64 minimumMessageGas
    )
        external
        restricted
    {
        if (chainId == 0) revert UnknownSourceChain(chainId);
        if (allowMessagesTo && messageGasLimit == 0) revert ZeroMessageGasLimit();
        Warehouse.Chain memory chain =
            Warehouse.Chain(allowMessagesFrom, allowMessagesTo, messageGasLimit, minimumMessageGas, true);
        chains[chainId] = chain;
        emit ChainAdded(chainId, chain);
    }

    function removeChain(uint64 chainId) external restricted {
        delete chains[chainId];
        emit ChainRemoved(chainId);
    }

    function setAllowMessagesFromChain(uint64 chainId, bool allowed) external restricted {
        chains[chainId].allowMessagesFrom = allowed;
    }

    function setAllowMessagesToChain(uint64 chainId, bool allowed) external restricted {
        chains[chainId].allowMessagesTo = allowed;
    }

    function setChainGasLimit(uint64 chainId, uint64 messageGasLimit) external restricted {
        if (messageGasLimit == 0) revert ZeroMessageGasLimit();
        chains[chainId].messageGasLimit = messageGasLimit;
    }

    // ========================================= LEDGER =========================================

    function enter(address to, uint64 assetChainId, address asset, uint256 amount) external restricted {
        _enter(to, assetChainId, asset, amount);
    }

    /// TODO: exit has no caller now that withdraws burn inside Hub. Remove?
    function exit(address from, uint64 assetChainId, address asset, uint256 amount) external restricted {
        _exit(from, assetChainId, asset, amount);
    }

    function move(address from, address to, uint64 assetChainId, address asset, uint256 amount) external restricted {
        balanceOf[from][assetChainId][asset] -= amount;
        balanceOf[to][assetChainId][asset] += amount;
        emit Move(from, to, assetChainId, asset, amount);
    }

    // ========================================= USER =========================================

    /// TODO: Be batches
    function withdrawWithSignature(
        WithdrawRequest calldata request,
        bytes calldata signature,
        Warehouse.BridgeData calldata data
    )
        external
        payable
        nonReentrant
        returns (bytes32 withdrawId)
    {
        if (isPaused) revert Paused();
        if (block.timestamp > request.deadline) revert Expired();
        if (msg.sender != request.owner) revert BadSignature();

        withdrawId = hashWithdrawRequest(request);
        if (withdrawUsed[withdrawId]) revert WithdrawReplay();
        if (!SignatureCheckerLib.isValidSignatureNowCalldata(withdrawSigner, withdrawId, signature)) {
            revert BadSignature();
        }
        withdrawUsed[withdrawId] = true;

        _exit(request.owner, request.assetChainId, address(request.asset), request.amount);

        if (request.assetChainId == uint64(block.chainid)) {
            warehouse.release(request.asset, request.to, request.amount);
        } else {
            _checkRoute(request.assetChainId, data.messageGas);

            bytes memory payload = abi.encode(
                Warehouse.MessageType.Transfer,
                abi.encode(
                    Warehouse.TransferMessage({
                        asset: address(request.asset),
                        nonce: ++outboundNonce,
                        amount: request.amount,
                        to: request.to
                    })
                )
            );

            CrosschainAdapter module = sendModule;
            if (address(module) == address(0)) revert UnknownModule();
            bytes32 messageId = module.send{ value: msg.value }(request.assetChainId, data.messageGas, payload);

            emit MessageSent(messageId, request.amount, request.to);
        }

        emit Withdraw(withdrawId, address(request.asset), request.to, request.amount);
    }

    // ========================================= MODULE =========================================

    function receiveMessage(uint64 chainId, bytes calldata payload) external restricted nonReentrant {
        Warehouse.Chain memory chain = chains[chainId];
        if (!chain.registered) revert UnknownSourceChain(chainId);
        if (!chain.allowMessagesFrom) revert MessagesNotAllowedFrom(chainId);

        (Warehouse.MessageType messageType, bytes memory body) = abi.decode(payload, (Warehouse.MessageType, bytes));

        if (messageType == Warehouse.MessageType.Transfer) {
            _receiveTransfer(chainId, abi.decode(body, (Warehouse.TransferMessage)));
        } else {
            assert(false);
        }
    }

    function _receiveTransfer(uint64 sourceChainId, Warehouse.TransferMessage memory message) internal {
        _consume(sourceChainId, message.nonce);

        if (isPaused) revert Paused();

        _enter(message.to, sourceChainId, message.asset, message.amount);

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
                    request.nonce,
                    request.deadline
                )
            )
        );
    }

    // ========================================= INTERNAL =========================================

    function _enter(address to, uint64 assetChainId, address asset, uint256 amount) internal {
        balanceOf[to][assetChainId][asset] += amount;
        emit Enter(to, assetChainId, asset, amount);
    }

    function _exit(address from, uint64 assetChainId, address asset, uint256 amount) internal {
        balanceOf[from][assetChainId][asset] -= amount;
        emit Exit(from, assetChainId, asset, amount);
    }

    function _consume(uint64 sourceChainId, uint256 nonce) internal {
        if (messageConsumed[sourceChainId][nonce]) revert MessageReplay();
        messageConsumed[sourceChainId][nonce] = true;
    }

    function _checkRoute(uint64 chainId, uint64 messageGas) internal view {
        Warehouse.Chain memory chain = chains[chainId];
        if (!chain.allowMessagesTo) revert MessagesNotAllowedTo(chainId);
        if (messageGas > chain.messageGasLimit) revert GasLimitExceeded();
        if (messageGas < chain.minimumMessageGas) revert GasTooLow();
    }

}
