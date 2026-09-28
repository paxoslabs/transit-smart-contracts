// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";
import { EIP712 } from "solady/utils/EIP712.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";
import { LibString } from "solady/utils/LibString.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { SignatureCheckerLib } from "solady/utils/SignatureCheckerLib.sol";
import { WarehouseToken } from "./WarehouseToken.sol";
import { CrosschainAdapter } from "./crosschain/CrosschainAdapter.sol";
import { BeforeTransferHook } from "./interfaces/BeforeTransferHook.sol";

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

    struct TokenConfig {
        ERC20 asset;
        uint64 assetChainId;
        uint8 decimals;
        bool depositEnabled;
        bool withdrawEnabled;
        bool bridgeEnabled;
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
        Transfer,
        Launch
    }

    /// TODO: Both sides resolve a token by address, and the hub mirror is deployed with the same CREATE3
    /// salt as the spoke token. That only yields the same address if the Warehouse itself is deployed at
    /// the same address on every chain, since CREATE3 derives the address from the deployer.
    struct TransferMessage {
        address token;
        uint256 nonce;
        uint256 amount;
        address to;
    }

    struct LaunchMessage {
        address asset;
        string symbol;
        uint8 decimals;
        uint256 nonce;
    }

    bytes32 public constant WITHDRAW_REQUEST_TYPEHASH = keccak256(
        "WithdrawRequest(address owner,address asset,uint64 assetChainId,uint256 amount,address to,uint256 nonce,uint256 deadline)"
    );

    uint64 public immutable hubChainId;

    address public immutable vault;
    address public withdrawSigner;
    bool public isPaused;
    uint256 public outboundNonce;

    CrosschainAdapter public sendModule;

    mapping(address token => TokenConfig) public configOf;
    mapping(ERC20 asset => WarehouseToken) public tokenForAsset;
    mapping(uint64 chainId => Chain) public chains;
    mapping(uint64 sourceChainId => mapping(uint256 nonce => bool)) public messageConsumed;
    mapping(bytes32 withdrawId => bool) public withdrawUsed;

    event TokenLaunched(address indexed token, address indexed asset, uint64 indexed assetChainId, uint8 decimals);
    event TokenConfigUpdated(address indexed token, TokenConfig config);
    event WithdrawSignerUpdated(address indexed withdrawSigner);
    event SendModuleUpdated(address indexed module);
    event PauseSet(bool isPaused);
    event ChainAdded(uint64 indexed chainId, Chain chain);
    event ChainRemoved(uint64 indexed chainId);
    event Deposit(address indexed token, address indexed from, address indexed to, uint256 amount);
    event Withdraw(bytes32 indexed withdrawId, address indexed token, address indexed to, uint256 amount);
    event MessageSent(bytes32 messageId, uint256 shareAmount, address to);
    event MessageReceived(bytes32 messageId, uint256 shareAmount, address to);

    error Paused();
    error NotRegistered();
    error AlreadyLaunched();
    error LaunchMustTargetHub();
    error LaunchMustBeLocal();
    error UnknownSourceChain(uint64 chainId);
    error DecimalsMismatch();
    error DepositDisabled();
    error WithdrawDisabled();
    error BridgeDisabled();
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

    constructor(address _authority, uint64 _hubChainId, address _vault) AccessManaged(_authority) {
        if (_vault == address(0)) revert VaultUnset();
        hubChainId = _hubChainId;
        vault = _vault;
    }

    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return ("Transit Warehouse", "1");
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparator();
    }

    // ========================================= ADMIN =========================================

    function launchToken(
        ERC20 asset,
        string calldata symbol,
        uint8 decimals,
        BridgeData calldata data
    )
        external
        payable
        restricted
        returns (WarehouseToken token)
    {
        if (address(asset) == address(0)) revert NotRegistered();
        if (address(tokenForAsset[asset]) != address(0)) revert AlreadyLaunched();
        if (asset.decimals() != decimals) revert DecimalsMismatch();

        uint64 assetChainId = uint64(block.chainid);
        token = _deployToken(assetChainId, asset, symbol, decimals);
        tokenForAsset[asset] = token;

        if (assetChainId == hubChainId) {
            if (configOf[address(token)].assetChainId != hubChainId) revert LaunchMustBeLocal();
        } else {
            _sendLaunch(asset, symbol, decimals, data);
        }
    }

    function setTokenConfig(address token, TokenConfig calldata config) external restricted {
        configOf[token] = config;
        emit TokenConfigUpdated(token, config);
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

    function deposit(ERC20 asset, uint256 amount, address to) external nonReentrant returns (uint256 shares) {
        if (isPaused) revert Paused();
        if (amount == 0) revert ZeroAssets();

        WarehouseToken token = tokenForAsset[asset];
        TokenConfig memory config = _configured(address(token));
        if (!config.depositEnabled) revert DepositDisabled();

        shares = amount;
        token.enter(msg.sender, asset, amount, to, shares);

        emit Deposit(address(token), msg.sender, to, amount);
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

        withdrawId = hashWithdrawRequest(request);
        if (withdrawUsed[withdrawId]) revert WithdrawReplay();
        if (!SignatureCheckerLib.isValidSignatureNowCalldata(withdrawSigner, withdrawId, signature)) {
            revert BadSignature();
        }
        withdrawUsed[withdrawId] = true;

        WarehouseToken token = tokenForAsset[request.asset];
        TokenConfig memory config = _configured(address(token));
        if (!config.withdrawEnabled) revert WithdrawDisabled();
        if (request.assetChainId != uint64(block.chainid)) revert NotLocalAsset();

        token.exit(request.to, request.asset, request.amount, request.owner, request.amount);

        emit Withdraw(withdrawId, address(token), request.to, request.amount);
    }

    /// NOTE: Add deposit and bridge
    function bridge(
        address token,
        uint256 shareAmount,
        BridgeData calldata data
    )
        external
        payable
        nonReentrant
        returns (bytes32 messageId)
    {
        if (isPaused) revert Paused();
        TokenConfig memory config = _configured(token);
        if (!config.bridgeEnabled) revert BridgeDisabled();

        _beforeBridge(data);

        BeforeTransferHook hook = WarehouseToken(payable(token)).hook();
        if (address(hook) != address(0)) hook.beforeBridge(msg.sender, shareAmount, data);

        WarehouseToken(payable(token)).exit(address(0), ERC20(address(0)), 0, msg.sender, shareAmount);

        uint256 nonce = ++outboundNonce;
        bytes memory payload = abi.encode(
            MessageType.Transfer,
            abi.encode(
                TransferMessage({ token: token, nonce: nonce, amount: shareAmount, to: data.destinationChainReceiver })
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
        } else if (messageType == MessageType.Launch) {
            _receiveLaunch(chainId, abi.decode(body, (LaunchMessage)));
        } else {
            assert(false);
        }
    }

    function _receiveTransfer(uint64 sourceChainId, TransferMessage memory message) internal {
        WarehouseToken token = WarehouseToken(payable(message.token));
        _configured(address(token));
        _consume(sourceChainId, message.nonce);

        _beforeReceive(token, message.amount, message.to);

        token.enter(address(0), ERC20(address(0)), 0, message.to, message.amount);

        _afterReceive(message.amount, message.to, bytes32(message.nonce));
    }

    function _receiveLaunch(uint64 sourceChainId, LaunchMessage memory message) internal {
        if (uint64(block.chainid) != hubChainId) revert LaunchMustTargetHub();
        _consume(sourceChainId, message.nonce);

        _deployToken(sourceChainId, ERC20(message.asset), message.symbol, message.decimals);
    }

    // ========================================= VIEWS =========================================

    function predictToken(uint64 assetChainId, ERC20 asset) external view returns (address) {
        return CREATE3.predictDeterministicAddress(_saltFor(assetChainId, asset), address(this));
    }

    function getToken(ERC20 asset) external view returns (WarehouseToken token) {
        token = tokenForAsset[asset];
        if (address(token) == address(0)) revert NotRegistered();
    }

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

    function _deployToken(
        uint64 assetChainId,
        ERC20 asset,
        string memory symbol,
        uint8 decimals
    )
        internal
        returns (WarehouseToken token)
    {
        string memory fullName = string.concat("transit_", LibString.toString(assetChainId), "_", symbol);
        bytes memory initCode = abi.encodePacked(
            type(WarehouseToken).creationCode, abi.encode(authority(), vault, fullName, fullName, decimals)
        );

        token = WarehouseToken(payable(CREATE3.deployDeterministic(initCode, _saltFor(assetChainId, asset))));

        bool isLocal = assetChainId == uint64(block.chainid);
        configOf[address(token)] = TokenConfig({
            asset: asset,
            assetChainId: assetChainId,
            decimals: decimals,
            depositEnabled: isLocal,
            withdrawEnabled: isLocal,
            bridgeEnabled: !isLocal || uint64(block.chainid) != hubChainId,
            registered: true
        });

        emit TokenLaunched(address(token), address(asset), assetChainId, decimals);
    }

    function _sendLaunch(ERC20 asset, string calldata symbol, uint8 decimals, BridgeData calldata data) internal {
        _checkRoute(data);

        uint256 nonce = ++outboundNonce;
        bytes memory payload = abi.encode(
            MessageType.Launch,
            abi.encode(LaunchMessage({ asset: address(asset), symbol: symbol, decimals: decimals, nonce: nonce }))
        );

        CrosschainAdapter module = sendModule;
        if (address(module) == address(0)) revert UnknownModule();
        module.send{ value: msg.value }(data.chainId, data.messageGas, payload);
    }

    function _consume(uint64 sourceChainId, uint256 nonce) internal {
        /// TODO: Decide whether a duplicate should revert or no-op. Reverting strands the losing
        /// protocol's delivery in its retry queue forever when both modules deliver the same message,
        /// which is the expected steady state.
        if (messageConsumed[sourceChainId][nonce]) revert MessageReplay();
        messageConsumed[sourceChainId][nonce] = true;
    }

    function _saltFor(uint64 assetChainId, ERC20 asset) internal pure returns (bytes32) {
        return keccak256(abi.encode(assetChainId, asset));
    }

    function _configured(address token) internal view returns (TokenConfig memory config) {
        config = configOf[token];
        if (!config.registered) revert NotRegistered();
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

    function _beforeReceive(WarehouseToken token, uint256 shareAmount, address destinationChainReceiver) internal view {
        if (isPaused) revert Paused();
        BeforeTransferHook hook = token.hook();
        if (address(hook) != address(0)) hook.beforeReceiveBridge(shareAmount, destinationChainReceiver);
    }

    function _afterReceive(uint256 shareAmount, address destinationChainReceiver, bytes32 messageId) internal {
        emit MessageReceived(messageId, shareAmount, destinationChainReceiver);
    }

}
