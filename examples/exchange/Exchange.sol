// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Record} from "pagepack/PagePack.sol";

/// @title Exchange
/// @notice The account side of an order-book perpetuals exchange: collateral, positions and
///         resting orders, with cross-margin checks. Matching is out of scope. `settle` applies
///         the fills a match produced, whether that match ran on-chain against a resting book
///         (like Perpl) or off-chain in an operator's engine (like Tiny).
///
/// Every piece of state is a one-word record addressed by a bytes32 key, and where a record
/// lives is left to {_locate}. The PagePack version and the plain-mapping baseline share all of
/// the logic below, so benchmarks comparing them measure storage layout and nothing else.
///
/// Records, one word each:
///
///   account    balance u128 | locked order margin u64 | bitmap of markets with a position u64
///   position   size int128 | cost int128, the signed sum of size × price, so a position's
///              equity is size × mark − cost
///   order      price u64 | size u64 | market u8 | isAsk bit. Each account has ORDER_SLOTS
///              reusable slots instead of a fresh storage entry per order.
///   market     mark price u64 | margin bps u16 | taker fee bps u16 | last price u64 | volume u96
abstract contract Exchange {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;

    /// One change to a resting order. Size 0 cancels the order in that slot.
    struct QuoteUpdate {
        uint8 slot;
        uint8 market;
        bool isAsk;
        uint64 price;
        uint64 size;
    }

    /// Part of a maker's resting order taken by the taker.
    struct Fill {
        address maker;
        uint8 slot;
        uint64 size;
    }

    /// A PagePack hint for one record, from {hintOf} on the packed exchange.
    struct Hint {
        bytes32 key;
        uint256 hint;
    }

    event Deposited(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event OrderUpdated(
        address indexed account, uint8 slot, uint8 market, bool isAsk, uint64 price, uint64 size
    );
    event Filled(
        uint8 indexed market,
        address indexed maker,
        address indexed taker,
        uint64 size,
        uint64 price
    );

    error NotAdmin();
    error NotOperator();
    error UnknownMarket(uint8 market);
    error MarketExists(uint8 market);
    error InvalidSlot(uint8 slot);
    error InvalidFill();
    error InsufficientBalance(address account);
    error InsufficientMargin(address account);

    uint256 public constant MAX_MARKETS = 64;
    uint256 public constant ORDER_SLOTS = 16;
    uint256 private constant BPS = 10_000;

    // Record kinds live in the top byte of a key, so keys never collide across kinds.
    uint256 private constant ACCOUNT = 1 << 248;
    uint256 private constant POSITION = 2 << 248;
    uint256 private constant ORDER = 3 << 248;
    uint256 private constant MARKET = 4 << 248;

    uint256 private constant U64 = type(uint64).max;
    uint256 private constant U128 = type(uint128).max;

    IERC20 public immutable collateral;
    address public immutable admin;
    address public immutable operator;
    address public immutable feeRecipient;

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    /// Stores the caller's hints for this transaction before the function body runs.
    modifier withHints(Hint[] calldata hints) {
        _loadHints(hints);
        _;
    }

    constructor(IERC20 collateral_, address admin_, address operator_, address feeRecipient_) {
        collateral = collateral_;
        admin = admin_;
        operator = operator_;
        feeRecipient = feeRecipient_;
    }

    // ------------------------------------------------------------------------------------------
    // Markets
    // ------------------------------------------------------------------------------------------

    /// @notice Lists a market. A market's margin rate is fixed once listed: resting orders lock
    ///         margin at that rate, and changing it would break releasing that margin later.
    function listMarket(uint8 market, uint64 markPrice, uint16 marginBps, uint16 takerFeeBps)
        external
        onlyAdmin
    {
        if (market >= MAX_MARKETS || markPrice == 0) revert UnknownMarket(market);

        Record record = _locate(marketKey(market));
        if (record.read(0) != 0) revert MarketExists(market);

        record.write(0, _packMarket(markPrice, marginBps, takerFeeBps, 0, 0));
    }

    /// @notice Stand-in for an oracle update.
    function setMarkPrice(uint8 market, uint64 markPrice) external onlyAdmin {
        Record record = _locate(marketKey(market));
        (, uint256 marginBps, uint256 feeBps, uint256 last, uint256 volume) =
            _unpackMarket(_readMarket(record, market));

        record.write(0, _packMarket(markPrice, marginBps, feeBps, last, volume));
    }

    // ------------------------------------------------------------------------------------------
    // Collateral
    // ------------------------------------------------------------------------------------------

    function deposit(uint256 amount) external {
        collateral.safeTransferFrom(msg.sender, address(this), amount);

        Record account = _locate(accountKey(msg.sender));
        (uint256 balance, uint256 locked, uint256 markets) = _unpackAccount(account.read(0));
        account.write(0, _packAccount(balance + amount, locked, markets));

        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 amount, Hint[] calldata hints) external withHints(hints) {
        Record account = _locate(accountKey(msg.sender));
        (uint256 balance, uint256 locked, uint256 markets) = _unpackAccount(account.read(0));

        if (amount > balance) revert InsufficientBalance(msg.sender);
        balance -= amount;

        account.write(0, _packAccount(balance, locked, markets));
        _requireMargin(msg.sender, int256(balance), locked, markets);

        collateral.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    // ------------------------------------------------------------------------------------------
    // Quoting
    // ------------------------------------------------------------------------------------------

    /// @notice Places, changes or cancels the caller's resting orders, then checks margin across
    ///         every market the caller holds a position in.
    /// @dev This is the hot path on Perpl's mainnet: almost every transaction is a market maker
    ///      moving one to a few quotes.
    function requote(QuoteUpdate[] calldata updates, Hint[] calldata hints)
        external
        withHints(hints)
    {
        Record account = _locate(accountKey(msg.sender));
        (uint256 balance, uint256 locked, uint256 markets) = _unpackAccount(account.read(0));

        for (uint256 i; i < updates.length; ++i) {
            QuoteUpdate calldata u = updates[i];
            if (u.slot >= ORDER_SLOTS) revert InvalidSlot(u.slot);

            Record order = _locate(orderKey(msg.sender, u.slot));
            uint256 previous = order.read(0);
            uint256 next = u.size == 0
                ? _withSize(previous, 0)
                : _packOrder(u.price, u.size, u.market, u.isAsk);

            locked = locked - _orderMargin(previous) + _orderMargin(next);
            order.write(0, next);

            emit OrderUpdated(msg.sender, u.slot, u.market, u.isAsk, u.price, u.size);
        }

        account.write(0, _packAccount(balance, locked, markets));
        _requireMargin(msg.sender, int256(balance), locked, markets);
    }

    // ------------------------------------------------------------------------------------------
    // Settlement
    // ------------------------------------------------------------------------------------------

    /// @notice Applies one taker's fills against resting maker orders, charges the taker fee and
    ///         checks the taker's margin.
    function settle(address taker, Fill[] calldata fills, Hint[] calldata hints)
        external
        withHints(hints)
    {
        if (msg.sender != operator) revert NotOperator();

        Record account = _locate(accountKey(taker));
        (uint256 balance, uint256 locked, uint256 markets) = _unpackAccount(account.read(0));

        // The taker's account is written once after the whole batch rather than once per fill.
        (int256 realized, uint256 fees, uint256 newMarkets) = _settleFills(taker, fills, markets);

        int256 cash = int256(balance) + realized - int256(fees);
        if (cash < 0) revert InsufficientBalance(taker);

        account.write(0, _packAccount(uint256(cash), locked, newMarkets));
        _credit(feeRecipient, fees);

        _requireMargin(taker, cash, locked, newMarkets);
    }

    // ------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------

    function accountOf(address account)
        external
        view
        returns (uint256 balance, uint256 locked, uint256 markets)
    {
        return _unpackAccount(_locate(accountKey(account)).read(0));
    }

    function positionOf(address account, uint8 market)
        external
        view
        returns (int256 size, int256 cost)
    {
        return _unpackPosition(_locate(positionKey(account, market)).read(0));
    }

    function orderOf(address account, uint8 slot)
        external
        view
        returns (uint256 price, uint256 size, uint8 market, bool isAsk)
    {
        return _unpackOrder(_locate(orderKey(account, slot)).read(0));
    }

    function marketOf(uint8 market)
        external
        view
        returns (uint256 markPrice, uint256 marginBps, uint256 feeBps, uint256 last, uint256 volume)
    {
        return _unpackMarket(_locate(marketKey(market)).read(0));
    }

    // ------------------------------------------------------------------------------------------
    // Record keys
    // ------------------------------------------------------------------------------------------

    // Public so off-chain tools derive the same keys when choosing a layout and building hints.

    function accountKey(address account) public pure returns (bytes32) {
        return bytes32(ACCOUNT | uint160(account));
    }

    function positionKey(address account, uint8 market) public pure returns (bytes32) {
        return bytes32(POSITION | (uint256(market) << 160) | uint160(account));
    }

    function orderKey(address account, uint8 slot) public pure returns (bytes32) {
        return bytes32(ORDER | (uint256(slot) << 160) | uint160(account));
    }

    function marketKey(uint8 market) public pure returns (bytes32) {
        return bytes32(MARKET | market);
    }

    // ------------------------------------------------------------------------------------------
    // Storage hooks
    // ------------------------------------------------------------------------------------------

    /// Returns where the record for `key` is stored.
    function _locate(bytes32 key) internal view virtual returns (Record);

    /// Hints live in transient storage under their record key, so callers can pass them in any
    /// order and a lookup costs one TLOAD. They vanish when the transaction ends.
    function _loadHints(Hint[] calldata hints) private {
        for (uint256 i; i < hints.length; ++i) {
            bytes32 key = hints[i].key;
            uint256 hint = hints[i].hint;

            assembly ("memory-safe") {
                tstore(key, hint)
            }
        }
    }

    function _hintFor(bytes32 key) internal view returns (uint256 hint) {
        assembly ("memory-safe") {
            hint := tload(key)
        }
    }

    // ------------------------------------------------------------------------------------------
    // Settlement internals
    // ------------------------------------------------------------------------------------------

    function _settleFills(address taker, Fill[] calldata fills, uint256 takerMarkets)
        private
        returns (int256 realized, uint256 fees, uint256)
    {
        for (uint256 i; i < fills.length; ++i) {
            (int256 fillRealized, uint256 fee, uint256 markets) =
                _settleFill(taker, fills[i], takerMarkets);

            realized += fillRealized;
            fees += fee;
            takerMarkets = markets;
        }

        return (realized, fees, takerMarkets);
    }

    /// Settles one fill for both sides. Returns the taker's realized profit or loss, the taker's
    /// fee and the taker's updated market bitmap.
    function _settleFill(address taker, Fill calldata f, uint256 takerMarkets)
        private
        returns (int256 realized, uint256 fee, uint256)
    {
        if (f.maker == taker || f.size == 0) revert InvalidFill();

        (uint8 market, uint256 price, int256 makerDelta, uint256 feeBps) = _fillMaker(f);

        (realized, takerMarkets) = _applyToPosition(taker, market, -makerDelta, price, takerMarkets);
        fee = uint256(f.size) * price * feeBps / BPS;

        emit Filled(market, f.maker, taker, f.size, price.toUint64());
        return (realized, fee, takerMarkets);
    }

    /// Settles the maker's side of a fill: the order slot, the market's trade stats, the
    /// maker's position and the release of the filled part's locked margin. Returns what the
    /// taker's side needs.
    function _fillMaker(Fill calldata f)
        private
        returns (uint8 market, uint256 price, int256 makerDelta, uint256 feeBps)
    {
        bool makerSold;
        uint256 remaining;
        (market, price, makerSold, remaining) = _takeFromOrder(f);

        uint256 marginBps;
        (marginBps, feeBps) = _recordTrade(market, price, f.size);

        makerDelta = makerSold ? -int256(uint256(f.size)) : int256(uint256(f.size));
        _settleMaker(
            f.maker, market, makerDelta, price, _released(remaining, f.size, price, marginBps)
        );
    }

    /// Takes the fill out of the maker's order slot. Returns the order's size before the fill.
    function _takeFromOrder(Fill calldata f)
        private
        returns (uint8 market, uint256 price, bool makerSold, uint256 size)
    {
        Record order = _locate(orderKey(f.maker, f.slot));
        uint256 word = order.read(0);

        (price, size, market, makerSold) = _unpackOrder(word);
        if (f.size > size) revert InvalidFill();

        // The slot keeps its other fields when emptied, so reusing it later overwrites a nonzero
        // word and avoids MIP-8's 17,000 gas charge for growing state.
        order.write(0, _withSize(word, size - f.size));
    }

    /// Updates the market's last price and volume, and returns its margin and fee rates.
    function _recordTrade(uint8 market, uint256 price, uint256 size)
        private
        returns (uint256 marginBps, uint256 feeBps)
    {
        Record record = _locate(marketKey(market));
        uint256 markPrice;
        uint256 volume;
        (markPrice, marginBps, feeBps,, volume) = _unpackMarket(_readMarket(record, market));

        record.write(0, _packMarket(markPrice, marginBps, feeBps, price, volume + size));
    }

    function _settleMaker(
        address maker,
        uint8 market,
        int256 delta,
        uint256 price,
        uint256 releasedMargin
    ) private {
        Record account = _locate(accountKey(maker));
        (uint256 balance, uint256 locked, uint256 markets) = _unpackAccount(account.read(0));

        int256 realized;
        (realized, markets) = _applyToPosition(maker, market, delta, price, markets);

        int256 cash = int256(balance) + realized;
        if (cash < 0) revert InsufficientBalance(maker);

        account.write(0, _packAccount(uint256(cash), locked - releasedMargin, markets));
    }

    /// Adds `delta` lots at `price` to a position. A position that closes realizes its profit
    /// or loss into the account's cash and leaves the market bitmap.
    function _applyToPosition(
        address account,
        uint8 market,
        int256 delta,
        uint256 price,
        uint256 markets
    ) private returns (int256 realized, uint256) {
        Record position = _locate(positionKey(account, market));
        (int256 size, int256 cost) = _unpackPosition(position.read(0));

        size += delta;
        cost += delta * int256(price);

        if (size == 0) {
            realized = -cost;
            cost = 0;
            markets &= ~(uint256(1) << market);
        } else {
            markets |= uint256(1) << market;
        }

        position.write(0, _packPosition(size, cost));
        return (realized, markets);
    }

    function _credit(address account, uint256 amount) private {
        Record record = _locate(accountKey(account));
        (uint256 balance, uint256 locked, uint256 markets) = _unpackAccount(record.read(0));

        record.write(0, _packAccount(balance + amount, locked, markets));
    }

    // ------------------------------------------------------------------------------------------
    // Margin
    // ------------------------------------------------------------------------------------------

    /// Cross-margin: equity across every open position must cover the margin those positions
    /// need plus the margin locked by resting orders. Reads a position and a market record for
    /// each market the account is in.
    function _requireMargin(address account, int256 cash, uint256 locked, uint256 markets)
        private
        view
    {
        int256 equity = cash;
        uint256 required = locked;

        for (uint256 market; markets != 0; ++market) {
            if (markets & 1 != 0) {
                (int256 size, int256 cost) =
                    _unpackPosition(_locate(positionKey(account, uint8(market))).read(0));
                (uint256 markPrice, uint256 marginBps,,,) =
                    _unpackMarket(_locate(marketKey(uint8(market))).read(0));

                equity += size * int256(markPrice) - cost;
                required += _abs(size) * markPrice * marginBps / BPS;
            }

            markets >>= 1;
        }

        if (equity < int256(required)) revert InsufficientMargin(account);
    }

    /// Margin an order locks while it rests.
    function _orderMargin(uint256 order) private view returns (uint256) {
        (uint256 price, uint256 size, uint8 market,) = _unpackOrder(order);
        if (size == 0) return 0;

        (, uint256 marginBps,,,) = _unpackMarket(_readMarket(_locate(marketKey(market)), market));

        return _margin(size, price, marginBps);
    }

    /// Margin freed by filling `filled` of an order with `remaining` left: what the order
    /// required before the fill minus what the rest still requires. Rounding each fill's own
    /// share instead would leave dust locked once the order empties.
    function _released(uint256 remaining, uint256 filled, uint256 price, uint256 marginBps)
        private
        pure
        returns (uint256)
    {
        return _margin(remaining, price, marginBps) - _margin(remaining - filled, price, marginBps);
    }

    /// An order's notional at the market's margin rate, rounded down. Every lock and release goes
    /// through this, so the amounts released over an order's fills add up to what it locked.
    function _margin(uint256 size, uint256 price, uint256 marginBps)
        private
        pure
        returns (uint256)
    {
        return size * price * marginBps / BPS;
    }

    function _readMarket(Record record, uint8 market) private view returns (uint256 word) {
        word = record.read(0);
        if (word == 0) revert UnknownMarket(market);
    }

    // ------------------------------------------------------------------------------------------
    // Packing
    // ------------------------------------------------------------------------------------------

    function _packAccount(uint256 balance, uint256 locked, uint256 markets)
        private
        pure
        returns (uint256)
    {
        return uint256(balance.toUint128()) | (uint256(locked.toUint64()) << 128) | (markets << 192);
    }

    function _unpackAccount(uint256 word)
        private
        pure
        returns (uint256 balance, uint256 locked, uint256 markets)
    {
        return (word & U128, (word >> 128) & U64, word >> 192);
    }

    function _packPosition(int256 size, int256 cost) private pure returns (uint256) {
        return uint256(uint128(size.toInt128())) | (uint256(uint128(cost.toInt128())) << 128);
    }

    function _unpackPosition(uint256 word) private pure returns (int256 size, int256 cost) {
        return (int128(uint128(word)), int128(uint128(word >> 128)));
    }

    function _packOrder(uint256 price, uint256 size, uint8 market, bool isAsk)
        private
        pure
        returns (uint256)
    {
        return price | (size << 64) | (uint256(market) << 128) | (isAsk ? uint256(1) << 136 : 0);
    }

    function _unpackOrder(uint256 word)
        private
        pure
        returns (uint256 price, uint256 size, uint8 market, bool isAsk)
    {
        return (word & U64, (word >> 64) & U64, uint8(word >> 128), (word >> 136) & 1 == 1);
    }

    function _withSize(uint256 order, uint256 size) private pure returns (uint256) {
        return (order & ~(U64 << 64)) | (size << 64);
    }

    function _packMarket(
        uint256 markPrice,
        uint256 marginBps,
        uint256 feeBps,
        uint256 last,
        uint256 volume
    ) private pure returns (uint256) {
        return uint256(markPrice.toUint64()) | (uint256(marginBps.toUint16()) << 64)
            | (uint256(feeBps.toUint16()) << 80) | (uint256(last.toUint64()) << 96)
            | (uint256(volume.toUint96()) << 160);
    }

    function _unpackMarket(uint256 word)
        private
        pure
        returns (uint256 markPrice, uint256 marginBps, uint256 feeBps, uint256 last, uint256 volume)
    {
        return
            (
                word & U64,
                (word >> 64) & 0xffff,
                (word >> 80) & 0xffff,
                (word >> 96) & U64,
                word >> 160
            );
    }

    function _abs(int256 x) private pure returns (uint256) {
        return uint256(x < 0 ? -x : x);
    }
}
