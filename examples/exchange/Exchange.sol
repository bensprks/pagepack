// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {PagePack} from "pagepack/PagePack.sol";
import {Account, Market, Order, Position} from "./ExchangeMap.sol";

/// @title Exchange
/// @notice The account side of an order-book perpetuals exchange: collateral, positions and
///         resting orders, with cross-margin checks. Matching is out of scope. `settle` applies
///         the fills a match produced, whether that match ran on-chain against a resting book
///         (like Perpl) or off-chain in an operator's engine.
///
/// This is a storage benchmark, not a production exchange. It trusts its operator as the
/// matching and risk engine: see {settle} and the trust assumptions in the README.
///
/// Every piece of state is a one-slot record struct (see ExchangeMap.sol), and where a record
/// lives is left to the storage hooks, which return the struct in place. The PagePack version
/// answers them from a typed map and the plain-mapping baseline from Solidity mappings. Both share
/// all of the logic below, so benchmarks comparing them measure storage layout and nothing else.
abstract contract Exchange {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;

    /// One change to a resting order. Size 0 cancels the order at that index.
    struct QuoteUpdate {
        uint8 index;
        uint8 market;
        bool isAsk;
        uint64 price;
        uint64 size;
    }

    /// Part of a maker's resting order taken by the taker.
    struct Fill {
        address maker;
        uint8 index;
        uint64 size;
    }

    event Deposited(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event OrderUpdated(
        address indexed account, uint8 index, uint8 market, bool isAsk, uint64 price, uint64 size
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
    error InvalidOrderIndex(uint8 index);
    error InvalidPrice();
    error InvalidFill();
    error InsufficientBalance(address account);
    error InsufficientMargin(address account);

    uint256 public constant MAX_MARKETS = 64;

    /// Each account reuses this many order slots rather than a fresh storage entry per order.
    uint256 public constant ORDER_SLOTS = 16;

    uint256 private constant BPS = 10_000;

    IERC20 public immutable collateral;
    address public immutable admin;
    address public immutable operator;
    address public immutable feeRecipient;

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    /// Hands the caller's hints to the storage backend before the function body runs.
    modifier withHints(PagePack.Hint[] calldata hints) {
        _useHints(hints);
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

        Market storage record = _market(market);
        if (record.markPrice != 0) revert MarketExists(market);

        record.markPrice = markPrice;
        record.marginBps = marginBps;
        record.takerFeeBps = takerFeeBps;
    }

    /// @notice Stand-in for an oracle update.
    function setMarkPrice(uint8 market, uint64 markPrice) external onlyAdmin {
        // A zero mark price would let every position in the market go without margin.
        if (markPrice == 0) revert InvalidPrice();

        _listedMarket(_market(market), market).markPrice = markPrice;
    }

    // ------------------------------------------------------------------------------------------
    // Collateral
    // ------------------------------------------------------------------------------------------

    function deposit(uint256 amount) external {
        collateral.safeTransferFrom(msg.sender, address(this), amount);

        Account storage account = _account(msg.sender);
        account.balance = (account.balance + amount).toUint128();

        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 amount, PagePack.Hint[] calldata hints) external withHints(hints) {
        Account storage account = _account(msg.sender);
        (uint256 balance, uint256 locked, uint256 markets) =
            (account.balance, account.locked, account.markets);

        if (amount > balance) revert InsufficientBalance(msg.sender);
        balance -= amount;

        account.balance = uint128(balance);
        _requireMargin(_newLocated(msg.sender), int256(balance), locked, markets);

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
    function requote(QuoteUpdate[] calldata updates, PagePack.Hint[] calldata hints)
        external
        withHints(hints)
    {
        Account storage account = _account(msg.sender);
        (uint256 balance, uint256 locked, uint256 markets) =
            (account.balance, account.locked, account.markets);
        Located memory located = _newLocated(msg.sender);

        for (uint256 i; i < updates.length; ++i) {
            QuoteUpdate memory u = updates[i];
            if (u.index >= ORDER_SLOTS) revert InvalidOrderIndex(u.index);

            // A live order needs a nonzero price: cancelling keeps only the price, market and side,
            // so a zero-price bid in market 0 would empty its slot to zero and lose slot reuse.
            if (u.size != 0 && u.price == 0) revert InvalidPrice();

            Order storage order = _order(msg.sender, u.index);
            locked = locked - _orderMargin(located, order.price, order.size, order.market)
                + _orderMargin(located, u.price, u.size, u.market);

            if (u.size == 0) {
                order.size = 0;
            } else {
                order.price = u.price;
                order.size = u.size;
                order.market = u.market;
                order.isAsk = u.isAsk;
            }

            emit OrderUpdated(msg.sender, u.index, u.market, u.isAsk, u.price, u.size);
        }

        account.locked = locked.toUint64();
        _requireMargin(located, int256(balance), locked, markets);
    }

    // ------------------------------------------------------------------------------------------
    // Settlement
    // ------------------------------------------------------------------------------------------

    /// @notice Applies one taker's fills against resting maker orders, charges the taker fee and
    ///         checks the taker's margin.
    /// @dev Trusts the operator, which stands in for the matching and risk engine:
    ///      - It names the taker. Nothing here checks that the taker agreed to the trade.
    ///      - A fill names a maker's order index and size, not an expected price or order
    ///        version. If the maker re-quotes that order slot first, the fill takes the new order.
    ///      - Only the taker's margin is checked. A fill can leave a maker under-margined, e.g.
    ///        an ask far below the mark price; a real exchange checks the maker or liquidates.
    function settle(address taker, Fill[] calldata fills, PagePack.Hint[] calldata hints)
        external
        withHints(hints)
    {
        if (msg.sender != operator) revert NotOperator();

        Account storage account = _account(taker);
        (uint256 balance, uint256 locked, uint256 markets) =
            (account.balance, account.locked, account.markets);

        // The taker's account is written once after the whole batch rather than once per fill.
        Located memory located = _newLocated(taker);
        (int256 realized, uint256 fees, uint256 newMarkets) = _settleFills(located, fills, markets);

        int256 cash = int256(balance) + realized - int256(fees);
        if (cash < 0) revert InsufficientBalance(taker);

        account.balance = uint256(cash).toUint128();
        account.markets = uint64(newMarkets);
        _credit(feeRecipient, fees);

        _requireMargin(located, cash, locked, newMarkets);
    }

    // ------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------

    function accountOf(address account)
        external
        view
        returns (uint256 balance, uint256 locked, uint256 markets)
    {
        Account storage record = _account(account);
        return (record.balance, record.locked, record.markets);
    }

    function positionOf(address account, uint8 market)
        external
        view
        returns (int256 size, int256 cost)
    {
        Position storage record = _position(account, market);
        return (record.size, record.cost);
    }

    function orderOf(address account, uint8 index)
        external
        view
        returns (uint256 price, uint256 size, uint8 market, bool isAsk)
    {
        Order storage record = _order(account, index);
        return (record.price, record.size, record.market, record.isAsk);
    }

    function marketOf(uint8 market)
        external
        view
        returns (uint256 markPrice, uint256 marginBps, uint256 feeBps, uint256 last, uint256 volume)
    {
        Market storage record = _market(market);
        return
            (
                record.markPrice,
                record.marginBps,
                record.takerFeeBps,
                record.lastPrice,
                record.volume
            );
    }

    // ------------------------------------------------------------------------------------------
    // Storage hooks
    // ------------------------------------------------------------------------------------------

    // Each returns a record's struct wherever the record is stored. A struct pointer goes stale
    // when its record moves: none is held across the collateral transfers, the only external calls
    // that could reach a rebalance.

    function _account(address trader) internal view virtual returns (Account storage);

    function _position(address trader, uint8 market)
        internal
        view
        virtual
        returns (Position storage);

    function _order(address trader, uint8 index) internal view virtual returns (Order storage);

    function _market(uint8 market) internal view virtual returns (Market storage);

    /// Makes `hints` available to every lookup in this transaction.
    function _useHints(PagePack.Hint[] calldata hints) internal virtual;

    // ------------------------------------------------------------------------------------------
    // Records located once per call
    // ------------------------------------------------------------------------------------------

    /// The market a call is working in, with the slots of its record and `account`'s position
    /// there, each zero until located. Without a hint every lookup searches pagepack's directory,
    /// and a call can need these many times: a settlement updates the market and the taker's
    /// position on every fill, and a re-quote reads the market's margin rate for each order.
    /// Fills and quote updates nearly always share a market, so keeping one market's records saves
    /// most repeat lookups. `account` is the caller in a re-quote or withdrawal, and the taker in a
    /// settlement. Memory can't hold storage pointers, so this keeps slots and lays the structs
    /// back over them. Like the struct pointers, these are never held across the collateral
    /// transfers.
    struct Located {
        address account;
        uint8 market;
        uint256 record;
        uint256 position;
    }

    function _newLocated(address account) private pure returns (Located memory located) {
        located.account = account;
    }

    /// The record of `market`, located once while the call stays in that market.
    function _locateMarket(Located memory located, uint8 market)
        private
        view
        returns (Market storage record)
    {
        _switchMarket(located, market);

        uint256 slot = located.record;
        if (slot == 0) {
            Market storage found = _market(market);
            assembly ("memory-safe") {
                slot := found.slot
            }
            located.record = slot;
        }

        assembly ("memory-safe") {
            record.slot := slot
        }
    }

    /// The account's position in `market`, located once while the call stays in that market.
    function _locatePosition(Located memory located, uint8 market)
        private
        view
        returns (Position storage position)
    {
        _switchMarket(located, market);

        uint256 slot = located.position;
        if (slot == 0) {
            Position storage found = _position(located.account, market);
            assembly ("memory-safe") {
                slot := found.slot
            }
            located.position = slot;
        }

        assembly ("memory-safe") {
            position.slot := slot
        }
    }

    function _switchMarket(Located memory located, uint8 market) private pure {
        if (located.market == market) return;

        located.market = market;
        located.record = 0;
        located.position = 0;
    }

    // ------------------------------------------------------------------------------------------
    // Settlement internals
    // ------------------------------------------------------------------------------------------

    function _settleFills(Located memory taker, Fill[] calldata fills, uint256 takerMarkets)
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
    function _settleFill(Located memory taker, Fill calldata f, uint256 takerMarkets)
        private
        returns (int256 realized, uint256 fee, uint256)
    {
        if (f.maker == taker.account || f.size == 0) revert InvalidFill();

        (uint8 market, uint256 price, int256 makerDelta, uint256 feeBps) = _fillMaker(taker, f);

        Position storage position = _locatePosition(taker, market);
        (realized, takerMarkets) =
            _applyToPosition(position, market, -makerDelta, price, takerMarkets);
        fee = uint256(f.size) * price * feeBps / BPS;

        emit Filled(market, f.maker, taker.account, f.size, price.toUint64());
        return (realized, fee, takerMarkets);
    }

    /// Settles the maker's side of a fill: the order slot, the market's trade stats, the
    /// maker's position and the release of the filled part's locked margin. Returns what the
    /// taker's side needs. The market's record is located through `taker`, where the taker's
    /// side and later fills find it.
    function _fillMaker(Located memory taker, Fill calldata f)
        private
        returns (uint8 market, uint256 price, int256 makerDelta, uint256 feeBps)
    {
        bool makerSold;
        uint256 remaining;
        (market, price, makerSold, remaining) = _takeFromOrder(f);

        uint256 marginBps;
        (marginBps, feeBps) =
            _recordTrade(_listedMarket(_locateMarket(taker, market), market), price, f.size);

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
        Order storage order = _order(f.maker, f.index);

        (market, price, makerSold, size) = (order.market, order.price, order.isAsk, order.size);
        if (f.size > size) revert InvalidFill();

        // The slot keeps its other fields when emptied, so reusing it later overwrites a nonzero
        // word and avoids MIP-8's 17,000 gas charge for growing state.
        order.size -= f.size;
    }

    /// Updates the market's last price and volume, and returns its margin and fee rates.
    function _recordTrade(Market storage record, uint256 price, uint256 size)
        private
        returns (uint256 marginBps, uint256 feeBps)
    {
        record.lastPrice = price.toUint64();
        record.volume = (record.volume + size).toUint96();

        return (record.marginBps, record.takerFeeBps);
    }

    function _settleMaker(
        address maker,
        uint8 market,
        int256 delta,
        uint256 price,
        uint256 releasedMargin
    ) private {
        Account storage account = _account(maker);
        (uint256 balance, uint256 locked, uint256 markets) =
            (account.balance, account.locked, account.markets);

        Position storage position = _position(maker, market);

        int256 realized;
        (realized, markets) = _applyToPosition(position, market, delta, price, markets);
        locked -= releasedMargin;

        int256 cash = int256(balance) + realized;
        if (cash < 0) revert InsufficientBalance(maker);

        account.balance = uint256(cash).toUint128();
        account.locked = uint64(locked);
        account.markets = uint64(markets);
    }

    /// Adds `delta` lots at `price` to a position. A position that closes realizes its profit
    /// or loss into the account's cash and leaves the market bitmap.
    function _applyToPosition(
        Position storage position,
        uint8 market,
        int256 delta,
        uint256 price,
        uint256 markets
    ) private returns (int256 realized, uint256) {
        (int256 size, int256 cost) = (position.size, position.cost);

        size += delta;
        cost += delta * int256(price);

        if (size == 0) {
            realized = -cost;
            cost = 0;
            markets &= ~(uint256(1) << market);
        } else {
            markets |= uint256(1) << market;
        }

        (position.size, position.cost) = (size.toInt128(), cost.toInt128());
        return (realized, markets);
    }

    function _credit(address account, uint256 amount) private {
        Account storage record = _account(account);
        record.balance = (record.balance + amount).toUint128();
    }

    // ------------------------------------------------------------------------------------------
    // Margin
    // ------------------------------------------------------------------------------------------

    /// Cross-margin: equity across every open position must cover the margin those positions
    /// need plus the margin locked by resting orders. Reads a position and a market record for
    /// each market the account is in.
    function _requireMargin(Located memory located, int256 cash, uint256 locked, uint256 markets)
        private
        view
    {
        int256 equity = cash;
        uint256 required = locked;

        for (uint256 market; markets != 0; ++market) {
            if (markets & 1 != 0) {
                (Position storage position, Market storage record) =
                    _marginRecords(located, uint8(market));

                (int256 size, int256 cost) = (position.size, position.cost);
                (uint256 markPrice, uint256 marginBps) = (record.markPrice, record.marginBps);

                equity += size * int256(markPrice) - cost;
                required += _abs(size) * markPrice * marginBps / BPS;
            }

            markets >>= 1;
        }

        if (equity < int256(required)) revert InsufficientMargin(located.account);
    }

    /// The account's position in `market` and the market's record. The market the call worked in
    /// is located already; any other is only read here, so it doesn't replace that one.
    function _marginRecords(Located memory located, uint8 market)
        private
        view
        returns (Position storage position, Market storage record)
    {
        if (market == located.market) {
            position = _locatePosition(located, market);
            record = _locateMarket(located, market);
        } else {
            position = _position(located.account, market);
            record = _market(market);
        }
    }

    /// Margin an order locks while it rests.
    function _orderMargin(Located memory located, uint256 price, uint256 size, uint8 market)
        private
        view
        returns (uint256)
    {
        if (size == 0) return 0;

        Market storage record = _listedMarket(_locateMarket(located, market), market);
        return _margin(size, price, record.marginBps);
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

    /// The market's record, reverting if the market was never listed. Listing and {setMarkPrice}
    /// keep a listed market's mark price nonzero.
    function _listedMarket(Market storage record, uint8 market)
        private
        view
        returns (Market storage)
    {
        if (record.markPrice == 0) revert UnknownMarket(market);
        return record;
    }

    function _abs(int256 x) private pure returns (uint256) {
        return uint256(x < 0 ? -x : x);
    }
}
