// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";
import { EIP712 } from "solady/utils/EIP712.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { SignatureCheckerLib } from "solady/utils/SignatureCheckerLib.sol";
import { WarehouseHub } from "./WarehouseHub.sol";
import { CrosschainAdapter } from "./crosschain/CrosschainAdapter.sol";

contract Warehouse is AccessManaged, EIP712, ReentrancyGuard {

    struct BridgeData {
        uint64 chainId;
        address destinationChainReceiver;
        ERC20 bridgeFeeToken;
        uint64 messageGas;
        bytes data;
    }

    struct Chain {
        bool allowMessagesFrom;
        bool allowMessagesTo;
        uint64 messageGasLimit;
        uint64 minimumMessageGas;
        bool registered;
    }

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

    enum MessageType {
        Transfer
    }

    struct TransferMessage {
        uint64 assetChainId;
        address asset;
        uint256 nonce;
        uint256 amount;
        address to;
    }

    bytes32 public constant WITHDRAW_REQUEST_TYPEHASH = keccak256(
        "WithdrawRequest(address owner,address asset,uint64 assetChainId,uint256 amount,address to,uint256 nonce,uint256 deadline)"
    );

    uint64 public immutable hubChainId;

    address public immutable vault;
    WarehouseHub public immutable hub;
    address public withdrawSigner;
    bool public isPaused;
    uint256 public outboundNonce;

    CrosschainAdapter public sendModule;

    mapping(uint64 chainId => Chain) public chains;
    mapping(uint64 sourceChainId => mapping(uint256 nonce => bool)) public messageConsumed;
    mapping(bytes32 withdrawId => bool) public withdrawUsed;

    event WithdrawSignerUpdated(address indexed withdrawSigner);
    event SendModuleUpdated(address indexed module);
    event PauseSet(bool isPaused);
    event ChainAdded(uint64 indexed chainId, Chain chain);
    event ChainRemoved(uint64 indexed chainId);
    event Deposit(address indexed asset, address indexed from, address indexed to, uint256 amount);
    event Withdraw(bytes32 indexed withdrawId, address indexed asset, address indexed to, uint256 amount);
    event MessageSent(bytes32 messageId, uint256 shareAmount, address to);
    event MessageReceived(bytes32 messageId, uint256 shareAmount, address to);

    error Paused();
    error UnknownSourceChain(uint64 chainId);
    error NotLocalAsset();
    error VaultUnset();
    error ZeroAssets();
    error BadSignature();
    error Expired();
    error WithdrawReplay();
    error MessageReplay();
    error UnknownModule();
    error MessagesNotAllowedFrom(uint64 chainId);
    error MessagesNotAllowedTo(uint64 chainId);
    error DestinationChainReceiverIsZeroAddress();
    error ZeroMessageGasLimit();
    error GasLimitExceeded();
    error GasTooLow();

    /// TODO: Decide how the hub is wired. Currently an immutable constructor arg, address(0) on spokes.
    constructor(address _authority, uint64 _hubChainId, address _vault, WarehouseHub _hub) AccessManaged(_authority) {
        if (_vault == address(0)) revert VaultUnset();
        hubChainId = _hubChainId;
        vault = _vault;
        hub = _hub;
    }

    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return ("Transit Warehouse", "1");
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparator();
    }

    // ========================================= ADMIN =========================================

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
        Chain memory chain = Chain(allowMessagesFrom, allowMessagesTo, messageGasLimit, minimumMessageGas, true);
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

    // ========================================= USER =========================================

    /// TODO: Decide whether admins need a per-asset deny-list now that any ERC20 is accepted.
    function deposit(ERC20 asset, uint256 amount, address to) external nonReentrant returns (uint256 shares) {
        if (isPaused) revert Paused();
        if (amount == 0) revert ZeroAssets();
        /// TODO: Stopgap. Spoke deposits must send a Transfer message to the hub, which needs BridgeData and
        /// msg.value for the fee. Decide the spoke deposit signature; until then spokes revert here.
        if (uint64(block.chainid) != hubChainId) revert();

        uint64 assetChainId = uint64(block.chainid);

        shares = amount;
        SafeTransferLib.safeTransferFrom(address(asset), msg.sender, vault, amount);
        hub.enter(to, assetChainId, address(asset), shares);

        emit Deposit(address(asset), msg.sender, to, amount);
    }

    /// TODO: Be batches
    function withdrawWithSignature(
        WithdrawRequest calldata request,
        bytes calldata signature
    )
        external
        nonReentrant
        returns (bytes32 withdrawId)
    {
        if (isPaused) revert Paused();
        if (block.timestamp > request.deadline) revert Expired();
        if (msg.sender != request.owner) revert BadSignature();
        /// TODO: Stopgap. Balances live on the hub, so a spoke cannot burn locally. Decide the spoke withdraw
        /// flow; until then spokes revert here.
        if (uint64(block.chainid) != hubChainId) revert();

        withdrawId = hashWithdrawRequest(request);
        if (withdrawUsed[withdrawId]) revert WithdrawReplay();
        if (!SignatureCheckerLib.isValidSignatureNowCalldata(withdrawSigner, withdrawId, signature)) {
            revert BadSignature();
        }
        withdrawUsed[withdrawId] = true;

        if (request.assetChainId != uint64(block.chainid)) revert NotLocalAsset();

        hub.exit(request.owner, request.assetChainId, address(request.asset), request.amount);
        SafeTransferLib.safeTransferFrom(address(request.asset), vault, request.to, request.amount);

        emit Withdraw(withdrawId, address(request.asset), request.to, request.amount);
    }

    /// NOTE: Add deposit and bridge
    /// TODO: Decide what bridge means with a single hub. Spokes hold no balances, so this only works on the
    /// hub, and the receiving spoke has no hub to credit.
    function bridge(
        uint64 assetChainId,
        ERC20 asset,
        uint256 shareAmount,
        BridgeData calldata data
    )
        external
        payable
        nonReentrant
        returns (bytes32 messageId)
    {
        if (isPaused) revert Paused();

        _beforeBridge(data);

        hub.exit(msg.sender, assetChainId, address(asset), shareAmount);

        uint256 nonce = ++outboundNonce;
        bytes memory payload = abi.encode(
            MessageType.Transfer,
            abi.encode(
                TransferMessage({
                    assetChainId: assetChainId,
                    asset: address(asset),
                    nonce: nonce,
                    amount: shareAmount,
                    to: data.destinationChainReceiver
                })
            )
        );

        CrosschainAdapter module = sendModule;
        if (address(module) == address(0)) revert UnknownModule();
        messageId = module.send{ value: msg.value }(data.chainId, data.messageGas, payload);

        _afterBridge(shareAmount, data, messageId);
    }

    function quoteBridge(BridgeData calldata data, bytes calldata payload) external view returns (uint256 fee) {
        CrosschainAdapter module = sendModule;
        if (address(module) == address(0)) revert UnknownModule();
        return module.quote(data.chainId, data.messageGas, payload);
    }

    // ========================================= MODULE =========================================

    function receiveMessage(uint64 chainId, bytes calldata payload) external restricted nonReentrant {
        Chain memory chain = chains[chainId];
        if (!chain.registered) revert UnknownSourceChain(chainId);
        if (!chain.allowMessagesFrom) revert MessagesNotAllowedFrom(chainId);

        (MessageType messageType, bytes memory body) = abi.decode(payload, (MessageType, bytes));

        if (messageType == MessageType.Transfer) {
            _receiveTransfer(chainId, abi.decode(body, (TransferMessage)));
        } else {
            assert(false);
        }
    }

    /// TODO: Decide what a spoke does on receiving a Transfer. There is no hub to credit there, so it reverts.
    function _receiveTransfer(uint64 sourceChainId, TransferMessage memory message) internal {
        _consume(sourceChainId, message.nonce);

        if (isPaused) revert Paused();

        hub.enter(message.to, message.assetChainId, message.asset, message.amount);

        _afterReceive(message.amount, message.to, bytes32(message.nonce));
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

    function _consume(uint64 sourceChainId, uint256 nonce) internal {
        /// TODO: Decide whether a duplicate should revert or no-op. Reverting strands the losing
        /// protocol's delivery in its retry queue forever when both modules deliver the same message,
        /// which is the expected steady state.
        if (messageConsumed[sourceChainId][nonce]) revert MessageReplay();
        messageConsumed[sourceChainId][nonce] = true;
    }

    function _checkRoute(BridgeData calldata data) internal view returns (Chain memory chain) {
        chain = chains[data.chainId];
        if (!chain.allowMessagesTo) revert MessagesNotAllowedTo(data.chainId);
        if (data.messageGas > chain.messageGasLimit) revert GasLimitExceeded();
        if (data.messageGas < chain.minimumMessageGas) revert GasTooLow();
    }

    function _beforeBridge(BridgeData calldata data) internal view returns (Chain memory chain) {
        chain = _checkRoute(data);
        if (data.destinationChainReceiver == address(0)) revert DestinationChainReceiverIsZeroAddress();
    }

    function _afterBridge(uint256 shareAmount, BridgeData calldata data, bytes32 messageId) internal {
        emit MessageSent(messageId, shareAmount, data.destinationChainReceiver);
    }

    function _afterReceive(uint256 shareAmount, address destinationChainReceiver, bytes32 messageId) internal {
        emit MessageReceived(messageId, shareAmount, destinationChainReceiver);
    }

}
