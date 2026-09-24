// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { ERC721Holder } from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import { ERC1155Holder } from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { BeforeTransferHook } from "./interfaces/BeforeTransferHook.sol";
import { IFallbackHook } from "./interfaces/IFallbackHook.sol";

contract WarehouseToken is ERC20, AccessManaged, ERC721Holder, ERC1155Holder {

    using Address for address;

    address public immutable vault;

    BeforeTransferHook public hook;

    IFallbackHook public fallbackHook;

    string internal _name;
    string internal _symbol;
    uint8 internal immutable _decimals;

    event Enter(address indexed from, address indexed asset, uint256 amount, address indexed to, uint256 shares);
    event Exit(address indexed to, address indexed asset, uint256 amount, address indexed from, uint256 shares);
    event BeforeTransferHookUpdated(address indexed hook);
    event FallbackHookUpdated(address indexed fallbackHook);
    event NameAndSymbolUpdated(string name, string symbol);

    constructor(
        address _authority,
        address _vault,
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    )
        AccessManaged(_authority)
    {
        vault = _vault;
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function manage(address target, bytes calldata data, uint256 value) external restricted returns (bytes memory) {
        return target.functionCallWithValue(data, value);
    }

    function enter(
        address from,
        ERC20 asset,
        uint256 assetAmount,
        address to,
        uint256 shareAmount
    )
        external
        restricted
    {
        if (assetAmount > 0) SafeTransferLib.safeTransferFrom(address(asset), from, vault, assetAmount);

        _mint(to, shareAmount);

        emit Enter(from, address(asset), assetAmount, to, shareAmount);
    }

    function exit(address to, ERC20 asset, uint256 assetAmount, address from, uint256 shareAmount) external restricted {
        _burn(from, shareAmount);

        if (assetAmount > 0) SafeTransferLib.safeTransferFrom(address(asset), vault, to, assetAmount);

        emit Exit(to, address(asset), assetAmount, from, shareAmount);
    }

    function setBeforeTransferHook(address _hook) external restricted {
        hook = BeforeTransferHook(_hook);
        emit BeforeTransferHookUpdated(_hook);
    }

    function setFallbackHook(address _fallbackHook) external restricted {
        fallbackHook = IFallbackHook(_fallbackHook);
        emit FallbackHookUpdated(_fallbackHook);
    }

    function setNameAndSymbol(string memory name_, string memory symbol_) external restricted {
        _name = name_;
        _symbol = symbol_;
        emit NameAndSymbolUpdated(name_, symbol_);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _callBeforeTransfer(msg.sender, to, amount);
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _callBeforeTransfer(from, to, amount);
        return super.transferFrom(from, to, amount);
    }

    function _callBeforeTransfer(address from, address to, uint256 amount) internal view {
        if (address(hook) != address(0)) hook.beforeTransfer(from, to, msg.sender, amount);
    }

    receive() external payable { }

    fallback(bytes calldata data) external payable returns (bytes memory result) {
        if (address(fallbackHook) == address(0)) revert();
        result = fallbackHook.onFallback{ value: msg.value }(msg.sender, data);
    }

}
