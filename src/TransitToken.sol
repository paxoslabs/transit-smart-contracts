// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { ERC20 } from "solady/tokens/ERC20.sol";

contract TransitToken is ERC20 {

    string internal _nameAndSymbol;
    uint8 internal _decimals;

    constructor(string memory nameAndSymbol_, uint8 decimals_) {
        _nameAndSymbol = nameAndSymbol_;
        _decimals = decimals_;
    }

    function name() public view override returns (string memory) {
        return _nameAndSymbol;
    }

    function symbol() public view override returns (string memory) {
        return _nameAndSymbol;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// TODO: Decide access control for mint and burn. They are unguarded until we pick an auth system,
    /// so anyone can mint transit tokens or burn someone else's.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

}
