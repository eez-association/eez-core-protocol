// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IEEZ} from "../../interfaces/IEEZ.sol";

/// @notice The EEZ registry is the authority for identifying remote callers.
interface IEEZTokenRegistry is IEEZ {
    function authorizedProxies(address proxy)
        external
        view
        returns (bool isProxy, address originalAddress, uint64 originalRollupId);
}

/// @title EEZToken
/// @notice Experimental ERC20 with address translation for authorized EEZ proxy callers.
/// @dev A remote call interprets every explicit address argument in the source chain's
/// namespace. msg.sender already represents the remote caller on this chain and is
/// not translated again. Local callers retain standard ERC20 behavior.
/// Events contain the canonical addresses where balances and allowances are stored.
/// This test token has a fixed initial supply and no external mint authority.
contract EEZToken is ERC20 {
    IEEZTokenRegistry public immutable EEZContract;

    error InvalidEEZContract();

    constructor(
        address eezContract_,
        string memory name_,
        string memory symbol_,
        address initialHolder,
        uint256 initialSupply
    )
        ERC20(name_, symbol_)
    {
        if (eezContract_.code.length == 0) revert InvalidEEZContract();
        EEZContract = IEEZTokenRegistry(eezContract_);
        if (initialSupply != 0) _mint(initialHolder, initialSupply);
    }

    /// @dev EEZ is the authority: inspect msg.sender in its proxy registry, then
    /// interpret address arguments in that proxy's source-rollup namespace.
    /// Ordinary callers and the zero address are left unchanged.
    function _translateAddress(address account) internal view returns (address) {
        (bool isProxy,, uint64 sourceRollupId) = EEZContract.authorizedProxies(msg.sender);
        if (!isProxy || account == address(0)) return account;
        return EEZContract.computeCrossChainProxyAddress(account, sourceRollupId);
    }

    function balanceOf(address account) public view override returns (uint256) {
        return super.balanceOf(_translateAddress(account));
    }

    function allowance(address owner, address spender) public view override returns (uint256) {
        return super.allowance(_translateAddress(owner), _translateAddress(spender));
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _transfer(msg.sender, _translateAddress(to), amount);
        return true;
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(msg.sender, _translateAddress(spender), amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        address canonicalOwner = _translateAddress(from);
        _spendAllowance(canonicalOwner, msg.sender, amount);
        _transfer(canonicalOwner, _translateAddress(to), amount);
        return true;
    }

    /// @dev Internal addresses are already canonical. The base implementation calls
    /// the virtual allowance getter, which would translate them a second time.
    function _spendAllowance(address owner, address spender, uint256 amount) internal override {
        uint256 currentAllowance = super.allowance(owner, spender);
        if (currentAllowance == type(uint256).max) return;
        if (currentAllowance < amount) {
            revert ERC20InsufficientAllowance(spender, currentAllowance, amount);
        }
        _approve(owner, spender, currentAllowance - amount, false);
    }
}
