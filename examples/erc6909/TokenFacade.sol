// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// The parts of TokenLedger a facade calls.
interface ITokenLedger {
    function tokenCount() external view returns (uint256);
    function name(uint256 id) external view returns (string memory);
    function symbol(uint256 id) external view returns (string memory);
    function decimals(uint256 id) external view returns (uint8);
    function totalSupply(uint256 id) external view returns (uint256);
    function balanceOf(address owner, uint256 id) external view returns (uint256);
    function allowance(address owner, address spender, uint256 id) external view returns (uint256);
    function facadeTransfer(uint256 id, address sender, address receiver, uint256 amount) external;
    function facadeTransferFrom(
        uint256 id,
        address spender,
        address sender,
        address receiver,
        uint256 amount
    ) external;
    function facadeApprove(uint256 id, address owner, address spender, uint256 amount) external;
}

/// @title TokenFacade
/// @notice An ERC-20 view of one TokenLedger token. Holds no state of its own: every call is
///         forwarded to the ledger, where balances live alongside every other token's.
///
/// ERC-20 events are emitted here for transfers made through this facade. Transfers made directly
/// on the ledger only emit ERC-6909 events, so the ledger's log is the complete record.
contract TokenFacade {
    ITokenLedger public immutable ledger;
    uint256 public immutable id;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor() {
        ledger = ITokenLedger(msg.sender);

        // No constructor arguments keeps the creation code identical for every token, so the
        // ledger can derive this address from the id. The ledger has already counted this token.
        id = ITokenLedger(msg.sender).tokenCount() - 1;
    }

    function name() external view returns (string memory) {
        return ledger.name(id);
    }

    function symbol() external view returns (string memory) {
        return ledger.symbol(id);
    }

    function decimals() external view returns (uint8) {
        return ledger.decimals(id);
    }

    function totalSupply() external view returns (uint256) {
        return ledger.totalSupply(id);
    }

    function balanceOf(address owner) external view returns (uint256) {
        return ledger.balanceOf(owner, id);
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return ledger.allowance(owner, spender, id);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        ledger.facadeTransfer(id, msg.sender, to, amount);

        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        ledger.facadeTransferFrom(id, msg.sender, from, to, amount);

        emit Transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        ledger.facadeApprove(id, msg.sender, spender, amount);

        emit Approval(msg.sender, spender, amount);
        return true;
    }
}
