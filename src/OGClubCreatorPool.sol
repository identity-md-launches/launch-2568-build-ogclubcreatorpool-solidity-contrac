// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title OGClubCreatorPool
/// @notice Pays $OG each month to the developers of the games listed in OG Club World.
///
/// Money comes in as plain ERC-20 transfers (the OGClubFarmVault pays this contract when the pool's
/// address is one account of a vault season) or through {fund}. Every month the owner proposes a
/// Merkle root of `(month, game, amount)` leaves together with the month's total, which is reserved
/// from the pool's free balance. Claims open three days later and stay open for ninety days. Anyone
/// may push a claim, but the tokens always go to the game's payout wallet, never to the caller.
/// Whatever a month does not pay out is swept back into the free balance once the window closes.
///
/// The owner lists games, proposes and cancels months (only before a month opens) and nothing else:
/// it can never withdraw, change a game's payout wallet, change the token, be a payout wallet
/// itself, or touch money owed to a month once its three-day delay has passed. A month only ever
/// pays games that were already listed when it was proposed, so the set of wallets a month can pay
/// is fixed when its public review starts. $OG only ever leaves this contract as claims to game
/// payout wallets.
///
/// Trust assumption: the owner publishes honest Merkle roots and totals. The contract cannot tell a
/// game wallet the owner secretly controls from any other wallet; the three-day review of the
/// published list against the listed games is the safeguard against a dishonest root.
contract OGClubCreatorPool is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────────── types ──

    struct Game {
        /// @dev Wallet that receives this game's claims. Zero means the id was never listed.
        address payout;
        /// @dev Whether the game is currently listed. Only informs the off-chain monthly draft;
        ///      claims of months already proposed keep working when a game is delisted.
        bool listed;
    }

    struct Month {
        /// @dev Merkle root of `keccak256(bytes.concat(keccak256(abi.encode(month, game, amount))))` leaves.
        bytes32 root;
        /// @dev Amount reserved for the month when it was proposed.
        uint256 total;
        /// @dev Amount still owed to the month: total minus claims. Zero after a cancel or a sweep.
        uint256 remaining;
        /// @dev Claims open at this timestamp and close `CLAIM_PERIOD` later. Zero means never proposed.
        uint64 opensAt;
        /// @dev Set when the owner cancelled the month before it opened.
        bool cancelled;
        /// @dev Set when the unclaimed remainder was swept back to the free balance.
        bool swept;
    }

    enum MonthStatus {
        None, // never proposed
        Pending, // proposed, claims not open yet (cancellable)
        Open, // claims accepted
        Closed, // claim window over, sweep pending
        Swept, // remainder returned to free()
        Cancelled // cancelled before it opened
    }

    // ─────────────────────────────────────────────────────────────────────────── constants ──

    /// @notice Delay between a month being proposed and its claims opening.
    uint256 public constant CLAIM_DELAY = 3 days;
    /// @notice Length of the claim window once it opens.
    uint256 public constant CLAIM_PERIOD = 90 days;
    /// @notice Earliest year a month id may belong to.
    uint256 public constant FIRST_YEAR = 2026;

    /// @notice The $OG token paid out by this pool.
    IERC20 public immutable token;

    // ───────────────────────────────────────────────────────────────────────────── storage ──

    /// @notice Listed games by id, where id = keccak256(bytes(kitId)).
    mapping(bytes32 id => Game) public games;
    /// @notice When a game was listed. A month only pays games listed no later than it was proposed.
    mapping(bytes32 id => uint64) public listedAt;
    /// @notice Proposed months by id (YYYYMM).
    mapping(uint256 month => Month) public months;
    /// @notice Whether a game has already claimed for a month.
    mapping(uint256 month => mapping(bytes32 game => bool)) public claimed;
    /// @notice Highest live (proposed and not cancelled) month id, or 0. Cancelling the last month
    ///         restores the previous one, so a mistyped id can be undone within its three days.
    uint256 public lastMonth;
    /// @notice The value of {lastMonth} just before each month was proposed, for {cancelMonth}.
    mapping(uint256 month => uint256) public lastMonthBefore;
    /// @notice Tokens owed to months that are pending or open. Never exceeds the token balance.
    uint256 public reserved;

    // ────────────────────────────────────────────────────────────────────────────── events ──

    event GameListed(bytes32 indexed id, address indexed payout);
    event GameDelisted(bytes32 indexed id);
    event GameRelisted(bytes32 indexed id);
    event PayoutChanged(bytes32 indexed id, address indexed from, address indexed to);
    event Funded(address indexed from, uint256 amount);
    event MonthProposed(uint256 indexed month, bytes32 root, uint256 total, uint64 opensAt);
    event MonthCancelled(uint256 indexed month, uint256 released);
    event Claimed(uint256 indexed month, bytes32 indexed game, address indexed payout, uint256 amount, address caller);
    event MonthSwept(uint256 indexed month, uint256 released);

    // ────────────────────────────────────────────────────────────────────────────── errors ──

    error ZeroAddress();
    error ZeroAmount();
    error GameAlreadyListed(bytes32 id);
    error GameUnknown(bytes32 id);
    error GameListedAfterProposal(bytes32 id, uint256 month);
    error GameNotListed(bytes32 id);
    error GameAlreadyActive(bytes32 id);
    error NotPayout(bytes32 id, address caller);
    error InvalidPayout(address payout);
    error InvalidMonth(uint256 month);
    error MonthNotAfterLast(uint256 month, uint256 lastMonth);
    error ZeroRoot();
    error InsufficientFree(uint256 requested, uint256 free);
    error MonthNotProposed(uint256 month);
    error MonthWasCancelled(uint256 month);
    error MonthAlreadyOpen(uint256 month, uint64 opensAt);
    error ClaimNotOpen(uint256 month, uint64 opensAt);
    error ClaimClosed(uint256 month, uint256 closedAt);
    error ClaimWindowStillOpen(uint256 month, uint256 closesAt);
    error AlreadyClaimed(uint256 month, bytes32 game);
    error InvalidProof();
    error ExceedsRemaining(uint256 amount, uint256 remaining);
    error NothingToSweep(uint256 month);
    error BalanceMismatch(uint256 expected, uint256 actual);
    error RenounceDisabled();

    // ─────────────────────────────────────────────────────────────────────────────── setup ──

    /// @param token_ The $OG token. Stored as-is: the constructor never calls it.
    /// @param owner_ The launch owner. Never msg.sender, which is the deploying factory.
    constructor(IERC20 token_, address owner_) Ownable(owner_) {
        if (address(token_) == address(0)) revert ZeroAddress();
        token = token_;
    }

    /// @notice Disabled: without an owner nobody could ever propose a month, so the free balance
    ///         and every later vault payment would be stuck. Hand over with {transferOwnership}.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ─────────────────────────────────────────────────────────────────────────────── games ──

    /// @notice Game id of a kit id, e.g. gameId("coin-dash").
    function gameId(string memory kitId) public pure returns (bytes32) {
        return keccak256(bytes(kitId));
    }

    /// @notice Lists a game with its payout wallet. An id can only ever be listed once; use
    ///         {delistGame} and {relistGame} afterwards. A game listed after a month was proposed
    ///         cannot claim from that month, only from months proposed later.
    function listGame(bytes32 id, address payout) external onlyOwner {
        if (games[id].payout != address(0)) revert GameAlreadyListed(id);
        _checkPayout(payout);
        games[id] = Game({payout: payout, listed: true});
        listedAt[id] = uint64(block.timestamp);
        emit GameListed(id, payout);
    }

    /// @notice Delists a game. Does not stop claims of months already proposed.
    function delistGame(bytes32 id) external onlyOwner {
        Game storage game = _existing(id);
        if (!game.listed) revert GameNotListed(id);
        game.listed = false;
        emit GameDelisted(id);
    }

    /// @notice Relists a delisted game under its current payout wallet.
    function relistGame(bytes32 id) external onlyOwner {
        Game storage game = _existing(id);
        if (game.listed) revert GameAlreadyActive(id);
        game.listed = true;
        emit GameRelisted(id);
    }

    /// @notice Moves a game's payout wallet. Only the game's current payout wallet may call this;
    ///         the owner never can. Works for delisted games too.
    function changePayout(bytes32 id, address to) external {
        Game storage game = _existing(id);
        if (msg.sender != game.payout) revert NotPayout(id, msg.sender);
        _checkPayout(to);
        if (to == msg.sender) revert InvalidPayout(to);
        game.payout = to;
        emit PayoutChanged(id, msg.sender, to);
    }

    // ──────────────────────────────────────────────────────────────────────────── money in ──

    /// @notice Pulls `amount` $OG from the caller into the free balance. Plain transfers to this
    ///         contract count as well; this is just the allowance-based path.
    function fund(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - before;
        if (received != amount) revert BalanceMismatch(amount, received);
        emit Funded(msg.sender, amount);
    }

    /// @notice Tokens not owed to any pending or open month.
    function free() public view returns (uint256) {
        return token.balanceOf(address(this)) - reserved;
    }

    // ────────────────────────────────────────────────────────────────────────────── months ──

    /// @notice Proposes a month's payout list. Reserves `total` from the free balance; claims open
    ///         after `CLAIM_DELAY`. A month may only be proposed once, unless it was cancelled, in
    ///         which case proposing it again overwrites it. The month must be later than
    ///         {lastMonth}, the highest live month.
    function proposeMonth(uint256 month, bytes32 root, uint256 total) external onlyOwner {
        if (!isValidMonth(month)) revert InvalidMonth(month);
        if (root == bytes32(0)) revert ZeroRoot();
        if (total == 0) revert ZeroAmount();
        uint256 available = free();
        if (total > available) revert InsufficientFree(total, available);
        uint256 last = lastMonth;
        if (month < last || (month == last && !months[month].cancelled)) {
            revert MonthNotAfterLast(month, last);
        }

        uint64 opensAt = uint64(block.timestamp + CLAIM_DELAY);
        months[month] =
            Month({root: root, total: total, remaining: total, opensAt: opensAt, cancelled: false, swept: false});
        if (month != last) lastMonthBefore[month] = last;
        lastMonth = month;
        reserved += total;
        emit MonthProposed(month, root, total, opensAt);
    }

    /// @notice Cancels a month before it opens and releases its reservation back to the free balance.
    ///         Cancelling the highest month also moves {lastMonth} back to the highest live month, so
    ///         a mistyped month id does not block the ids below it.
    function cancelMonth(uint256 month) external onlyOwner {
        Month storage m = months[month];
        if (m.opensAt == 0) revert MonthNotProposed(month);
        if (m.cancelled) revert MonthWasCancelled(month);
        if (block.timestamp >= m.opensAt) revert MonthAlreadyOpen(month, m.opensAt);

        uint256 released = m.remaining;
        m.remaining = 0;
        m.cancelled = true;
        reserved -= released;
        if (month == lastMonth) {
            // Walk back over months that were cancelled while a later one was still live.
            uint256 prev = lastMonthBefore[month];
            while (prev != 0 && months[prev].cancelled) {
                prev = lastMonthBefore[prev];
            }
            lastMonth = prev;
        }
        emit MonthCancelled(month, released);
    }

    /// @notice Pays a game's share of a month to the game's payout wallet. Anyone may call it; the
    ///         caller never receives anything. Once per game per month, within the claim window.
    ///         The game must have been listed no later than the month was proposed (delisted since
    ///         is fine), and its payout wallet may not be the owner.
    function claim(uint256 month, bytes32 game, uint256 amount, bytes32[] calldata proof) external nonReentrant {
        Month storage m = months[month];
        if (m.opensAt == 0) revert MonthNotProposed(month);
        if (m.cancelled) revert MonthWasCancelled(month);
        if (block.timestamp < m.opensAt) revert ClaimNotOpen(month, m.opensAt);
        uint256 closesAt = m.opensAt + CLAIM_PERIOD;
        if (block.timestamp >= closesAt) revert ClaimClosed(month, closesAt);
        if (claimed[month][game]) revert AlreadyClaimed(month, game);
        if (amount == 0) revert ZeroAmount();
        address payout = games[game].payout;
        if (payout == address(0)) revert GameUnknown(game);
        // Recipients are fixed when the review starts: a game listed after the proposal waits for
        // the next month, so the owner cannot pick a leaf's wallet once the month is out of reach.
        if (listedAt[game] > m.opensAt - CLAIM_DELAY) revert GameListedAfterProposal(game, month);
        if (payout == owner()) revert InvalidPayout(payout);
        if (!MerkleProof.verifyCalldata(proof, m.root, leaf(month, game, amount))) revert InvalidProof();
        if (amount > m.remaining) revert ExceedsRemaining(amount, m.remaining);

        claimed[month][game] = true;
        m.remaining -= amount;
        reserved -= amount;

        uint256 poolBefore = token.balanceOf(address(this));
        uint256 payoutBefore = token.balanceOf(payout);
        token.safeTransfer(payout, amount);
        uint256 sent = poolBefore - token.balanceOf(address(this));
        if (sent != amount) revert BalanceMismatch(amount, sent);
        uint256 received = token.balanceOf(payout) - payoutBefore;
        if (received != amount) revert BalanceMismatch(amount, received);
        emit Claimed(month, game, payout, amount, msg.sender);
    }

    /// @notice Returns a month's unclaimed remainder to the free balance once its window has closed.
    ///         Anyone may call it. Nothing goes to the caller or the owner.
    function sweep(uint256 month) external {
        Month storage m = months[month];
        if (m.opensAt == 0) revert MonthNotProposed(month);
        if (m.cancelled) revert MonthWasCancelled(month);
        uint256 closesAt = m.opensAt + CLAIM_PERIOD;
        if (block.timestamp < closesAt) revert ClaimWindowStillOpen(month, closesAt);
        if (m.swept) revert NothingToSweep(month);

        uint256 released = m.remaining;
        m.remaining = 0;
        m.swept = true;
        reserved -= released;
        emit MonthSwept(month, released);
    }

    // ─────────────────────────────────────────────────────────────────────────────── views ──

    /// @notice Leaf of a month's Merkle tree for one game.
    function leaf(uint256 month, bytes32 game, uint256 amount) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(month, game, amount))));
    }

    /// @notice A month id is YYYYMM with month 1..12 and year >= FIRST_YEAR.
    function isValidMonth(uint256 month) public pure returns (bool) {
        uint256 mm = month % 100;
        uint256 year = month / 100;
        return mm >= 1 && mm <= 12 && year >= FIRST_YEAR && year <= 9999;
    }

    /// @notice Where a month is in its life cycle.
    function status(uint256 month) external view returns (MonthStatus) {
        Month storage m = months[month];
        if (m.opensAt == 0) return MonthStatus.None;
        if (m.cancelled) return MonthStatus.Cancelled;
        if (m.swept) return MonthStatus.Swept;
        if (block.timestamp < m.opensAt) return MonthStatus.Pending;
        if (block.timestamp < m.opensAt + CLAIM_PERIOD) return MonthStatus.Open;
        return MonthStatus.Closed;
    }

    /// @notice Whether claims for a month are being accepted right now.
    function isOpen(uint256 month) external view returns (bool) {
        Month storage m = months[month];
        return m.opensAt != 0 && !m.cancelled && !m.swept && block.timestamp >= m.opensAt
            && block.timestamp < m.opensAt + CLAIM_PERIOD;
    }

    // ──────────────────────────────────────────────────────────────────────────── internal ──

    function _existing(bytes32 id) private view returns (Game storage game) {
        game = games[id];
        if (game.payout == address(0)) revert GameUnknown(id);
    }

    /// @dev A payout wallet may not be zero, the pool, the owner or the pending owner. {claim}
    ///      re-checks the owner, since ownership can move after a game is listed.
    function _checkPayout(address payout) private view {
        if (payout == address(0)) revert ZeroAddress();
        if (payout == address(this) || payout == owner() || payout == pendingOwner()) revert InvalidPayout(payout);
    }
}
