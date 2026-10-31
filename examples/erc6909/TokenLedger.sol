// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Record} from "pagepack/PagePack.sol";
import {TokenFacade} from "./TokenFacade.sol";

/// @title TokenLedger
/// @notice An ERC-6909 multi-token ledger where anyone can create a fixed-supply token. Each token
///         also gets an ERC-20 facade, so existing ERC-20 integrations can use it unchanged.
///
/// All per-account state (balances, allowances and operator approvals) is stored as one-word
/// records addressed by a bytes32 key. Where a record lives is left to {_locate}, so the PagePack
/// and plain-mapping versions share every line of token logic below, and benchmarks comparing
/// them measure storage layout and nothing else.
abstract contract TokenLedger {
    struct Token {
        string name;
        string symbol;
        uint8 decimals;
        uint256 totalSupply;
    }

    /// One balance movement in a batch.
    struct Move {
        address from;
        address to;
        uint256 id;
        uint256 amount;
    }

    /// Optional PagePack hints for one move: the sender's balance, the receiver's balance, and the
    /// caller's operator approval or allowance from the sender.
    struct MoveHints {
        uint256 from;
        uint256 to;
        uint256 permission;
    }

    event Transfer(
        address caller,
        address indexed sender,
        address indexed receiver,
        uint256 indexed id,
        uint256 amount
    );
    event OperatorSet(address indexed owner, address indexed spender, bool approved);
    event Approval(
        address indexed owner, address indexed spender, uint256 indexed id, uint256 amount
    );
    event TokenCreated(uint256 indexed id, address indexed facade, string name, string symbol);

    error InsufficientBalance(address owner, uint256 id);
    error InsufficientPermission(address spender, uint256 id);
    error NotFacade(uint256 id);
    error HintsLengthMismatch();

    /// Facades are deployed with CREATE2 and no constructor arguments, so a facade's address
    /// follows from its token id alone. Checking a caller is a facade then costs a hash instead
    /// of a storage read.
    bytes32 private immutable FACADE_CODE_HASH = keccak256(type(TokenFacade).creationCode);

    uint256 public tokenCount;

    mapping(uint256 id => Token) private _tokens;

    modifier onlyFacade(uint256 id) {
        if (msg.sender != facadeOf(id)) revert NotFacade(id);
        _;
    }

    // ------------------------------------------------------------------------------------------
    // Token creation
    // ------------------------------------------------------------------------------------------

    /// @notice Creates a token, mints its whole supply to `recipient` and deploys its ERC-20
    ///         facade.
    function createToken(
        string calldata name_,
        string calldata symbol_,
        uint8 decimals_,
        uint256 supply,
        address recipient
    ) external returns (uint256 id, address facade) {
        // The facade reads tokenCount in its constructor to learn its id, so increment first.
        id = tokenCount++;
        _tokens[id] = Token(name_, symbol_, decimals_, supply);

        Record balance = _locate(balanceKey(recipient, id), 0);
        balance.write(0, balance.read(0) + supply);

        facade = address(new TokenFacade{salt: bytes32(id)}());

        emit Transfer(msg.sender, address(0), recipient, id, supply);
        emit TokenCreated(id, facade, name_, symbol_);
    }

    /// @notice The ERC-20 facade for `id`. Only that address can call the facade entry points.
    function facadeOf(uint256 id) public view returns (address) {
        bytes32 hash =
            keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(id), FACADE_CODE_HASH));

        return address(uint160(uint256(hash)));
    }

    // ------------------------------------------------------------------------------------------
    // ERC-6909
    // ------------------------------------------------------------------------------------------

    function balanceOf(address owner, uint256 id) public view returns (uint256) {
        return _locate(balanceKey(owner, id), 0).read(0);
    }

    function allowance(address owner, address spender, uint256 id) public view returns (uint256) {
        return _locate(allowanceKey(owner, spender, id), 0).read(0);
    }

    function isOperator(address owner, address spender) public view returns (bool) {
        return _locate(operatorKey(owner, spender), 0).read(0) != 0;
    }

    function transfer(address receiver, uint256 id, uint256 amount) external returns (bool) {
        _move(msg.sender, receiver, id, amount, 0, 0);

        emit Transfer(msg.sender, msg.sender, receiver, id, amount);
        return true;
    }

    function transferFrom(address sender, address receiver, uint256 id, uint256 amount)
        external
        returns (bool)
    {
        if (sender != msg.sender) _spendPermission(sender, msg.sender, id, amount, 0);
        _move(sender, receiver, id, amount, 0, 0);

        emit Transfer(msg.sender, sender, receiver, id, amount);
        return true;
    }

    function approve(address spender, uint256 id, uint256 amount) external returns (bool) {
        _approve(msg.sender, spender, id, amount);
        return true;
    }

    function setOperator(address spender, bool approved) external returns (bool) {
        _locate(operatorKey(msg.sender, spender), 0).write(0, approved ? 1 : 0);

        emit OperatorSet(msg.sender, spender, approved);
        return true;
    }

    // ------------------------------------------------------------------------------------------
    // Metadata and supply (ERC-6909 extensions)
    // ------------------------------------------------------------------------------------------

    function name(uint256 id) external view returns (string memory) {
        return _tokens[id].name;
    }

    function symbol(uint256 id) external view returns (string memory) {
        return _tokens[id].symbol;
    }

    function decimals(uint256 id) external view returns (uint8) {
        return _tokens[id].decimals;
    }

    function totalSupply(uint256 id) external view returns (uint256) {
        return _tokens[id].totalSupply;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7 // ERC-165
            || interfaceId == 0x0f632fb3; // ERC-6909
    }

    // ------------------------------------------------------------------------------------------
    // Batch settlement
    // ------------------------------------------------------------------------------------------

    /// @notice Applies a batch of moves, e.g. the fills from one off-chain matching round. The
    ///         caller needs the same permission for each sender as {transferFrom} requires.
    /// @dev `hints` is either empty or one entry per move. A settlement engine that knows the
    ///      current layout passes hints and skips every directory search; anyone else can pass
    ///      an empty array.
    function batchTransferFrom(Move[] calldata moves, MoveHints[] calldata hints) external {
        bool hinted = hints.length != 0;
        if (hinted && hints.length != moves.length) revert HintsLengthMismatch();

        for (uint256 i; i < moves.length; ++i) {
            Move calldata m = moves[i];
            MoveHints memory h = hinted ? hints[i] : MoveHints(0, 0, 0);

            if (m.from != msg.sender) {
                _spendPermission(m.from, msg.sender, m.id, m.amount, h.permission);
            }
            _move(m.from, m.to, m.id, m.amount, h.from, h.to);

            emit Transfer(msg.sender, m.from, m.to, m.id, m.amount);
        }
    }

    // ------------------------------------------------------------------------------------------
    // Facade entry points
    // ------------------------------------------------------------------------------------------

    // Each facade forwards its ERC-20 calls here along with the original caller. These still
    // emit ERC-6909 events, so the ledger's own log stays a complete record of every transfer.

    function facadeTransfer(uint256 id, address sender, address receiver, uint256 amount)
        external
        onlyFacade(id)
    {
        _move(sender, receiver, id, amount, 0, 0);

        emit Transfer(sender, sender, receiver, id, amount);
    }

    function facadeTransferFrom(
        uint256 id,
        address spender,
        address sender,
        address receiver,
        uint256 amount
    ) external onlyFacade(id) {
        if (sender != spender) _spendPermission(sender, spender, id, amount, 0);
        _move(sender, receiver, id, amount, 0, 0);

        emit Transfer(spender, sender, receiver, id, amount);
    }

    function facadeApprove(uint256 id, address owner, address spender, uint256 amount)
        external
        onlyFacade(id)
    {
        _approve(owner, spender, id, amount);
    }

    // ------------------------------------------------------------------------------------------
    // Record keys
    // ------------------------------------------------------------------------------------------

    // Public so off-chain tools can derive the same keys when choosing a layout and building
    // hints.

    /// Token ids are sequential, so they fit beside the owner's address without hashing.
    function balanceKey(address owner, uint256 id) public pure returns (bytes32) {
        return bytes32((id << 160) | uint160(owner));
    }

    /// Allowance and operator keys hash inputs of different lengths, so they can never collide
    /// with each other.
    function allowanceKey(address owner, address spender, uint256 id)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(owner, spender, id));
    }

    function operatorKey(address owner, address spender) public pure returns (bytes32) {
        return keccak256(abi.encode(owner, spender));
    }

    // ------------------------------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------------------------------

    /// Returns where the record for `key` is stored. `hint` is a PagePack hint, or 0 for none.
    function _locate(bytes32 key, uint256 hint) internal view virtual returns (Record);

    function _move(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        uint256 fromHint,
        uint256 toHint
    ) internal {
        Record fromBalance = _locate(balanceKey(from, id), fromHint);
        uint256 balance = fromBalance.read(0);

        if (balance < amount) revert InsufficientBalance(from, id);

        unchecked {
            fromBalance.write(0, balance - amount);
        }

        // Read the receiver after writing the sender, so a self-transfer nets to zero.
        Record toBalance = _locate(balanceKey(to, id), toHint);
        toBalance.write(0, toBalance.read(0) + amount);
    }

    /// Lets `spender` move `amount` of `owner`'s `id`. Operators can move anything. Otherwise the
    /// allowance is spent, unless it is unlimited (type(uint256).max).
    ///
    /// One hint serves both records: a settlement engine is usually an operator, so its hint
    /// points at the operator record, and the allowance lookup only runs when that check fails.
    function _spendPermission(
        address owner,
        address spender,
        uint256 id,
        uint256 amount,
        uint256 hint
    ) internal {
        if (_locate(operatorKey(owner, spender), hint).read(0) != 0) return;

        Record allowed = _locate(allowanceKey(owner, spender, id), hint);
        uint256 remaining = allowed.read(0);

        if (remaining == type(uint256).max) return;
        if (remaining < amount) revert InsufficientPermission(spender, id);

        unchecked {
            allowed.write(0, remaining - amount);
        }
    }

    function _approve(address owner, address spender, uint256 id, uint256 amount) internal {
        _locate(allowanceKey(owner, spender, id), 0).write(0, amount);

        emit Approval(owner, spender, id, amount);
    }
}
