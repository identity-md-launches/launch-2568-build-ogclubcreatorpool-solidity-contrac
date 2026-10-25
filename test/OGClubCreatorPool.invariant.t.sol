// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OGClubCreatorPool} from "../src/OGClubCreatorPool.sol";
import {MockOG} from "./support/MockOG.sol";
import {Merkle} from "./support/Merkle.sol";

/// @notice Drives the pool through every public action, as owner, funder, game wallet and stranger.
contract PoolHandler is Test {
    uint256 internal constant GAMES = 6;

    MockOG public og;
    OGClubCreatorPool public pool;
    address public owner;
    address public funder = makeAddr("funder");
    address public stranger = makeAddr("stranger");

    bytes32[] public gameIds;
    address[] public payouts;

    uint256[] public proposedMonths;
    mapping(uint256 => bool) internal seen;
    mapping(uint256 => bytes32[]) internal leavesOf;
    mapping(uint256 => uint256[]) internal amountsOf;
    uint256 public nextMonth = 202_601;

    uint256 public ghostPaid;
    uint256 public ghostFunded;

    constructor(MockOG og_, OGClubCreatorPool pool_, address owner_) {
        og = og_;
        pool = pool_;
        owner = owner_;
        for (uint256 i; i < GAMES; ++i) {
            bytes32 id = pool.gameId(string.concat("g", vm.toString(i)));
            address payout = makeAddr(string.concat("payout", vm.toString(i)));
            gameIds.push(id);
            payouts.push(payout);
            vm.prank(owner);
            pool.listGame(id, payout);
        }
        og.mint(funder, type(uint128).max);
    }

    function monthsCount() external view returns (uint256) {
        return proposedMonths.length;
    }

    // ───────────────────────────────────────────────────────────────────────── actions ──

    function fund(uint256 amount) external {
        amount = bound(amount, 1, 1_000_000 ether);
        vm.startPrank(funder);
        og.approve(address(pool), amount);
        pool.fund(amount);
        vm.stopPrank();
        ghostFunded += amount;
    }

    function transferIn(uint256 amount) external {
        amount = bound(amount, 1, 1_000_000 ether);
        vm.prank(funder);
        og.transfer(address(pool), amount);
        ghostFunded += amount;
    }

    function propose(uint256 seed, uint8 countRaw, uint256 total) external {
        uint256 count = bound(countRaw, 1, GAMES);
        uint256 free = pool.free();
        if (free == 0) return;
        total = bound(total, 1, free);
        uint256 month = nextMonth;
        bytes32[] memory leaves = new bytes32[](count);
        uint256[] memory amounts = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            // Roughly share `total`, sometimes oversubscribing, sometimes leaving dust.
            amounts[i] = bound(uint256(keccak256(abi.encode(seed, i))), 1, total / count + 1);
            leaves[i] = pool.leaf(month, gameIds[i], amounts[i]);
        }
        vm.prank(owner);
        pool.proposeMonth(month, Merkle.root(leaves), total);
        if (!seen[month]) {
            seen[month] = true;
            proposedMonths.push(month);
        }
        delete leavesOf[month];
        delete amountsOf[month];
        for (uint256 i; i < count; ++i) {
            leavesOf[month].push(leaves[i]);
            amountsOf[month].push(amounts[i]);
        }
        // Advance the calendar: next id, rolling over December.
        uint256 mm = month % 100;
        nextMonth = mm == 12 ? (month / 100 + 1) * 100 + 1 : month + 1;
    }

    function cancel(uint256 idx) external {
        if (proposedMonths.length == 0) return;
        uint256 month = proposedMonths[bound(idx, 0, proposedMonths.length - 1)];
        (,,, uint64 opensAt, bool cancelled,) = pool.months(month);
        if (cancelled || block.timestamp >= opensAt) return;
        vm.prank(owner);
        pool.cancelMonth(month);
        // A cancelled last month may be proposed again under the same id.
        if (month == pool.lastMonth()) nextMonth = month;
    }

    function claim(uint256 idx, uint8 gameRaw, bool asOwner) external {
        if (proposedMonths.length == 0) return;
        uint256 month = proposedMonths[bound(idx, 0, proposedMonths.length - 1)];
        bytes32[] storage leaves = leavesOf[month];
        if (leaves.length == 0) return;
        uint256 g = bound(gameRaw, 0, leaves.length - 1);
        (,, uint256 remaining, uint64 opensAt, bool cancelled, bool swept) = pool.months(month);
        if (cancelled || swept || block.timestamp < opensAt || block.timestamp >= opensAt + 90 days) return;
        if (pool.claimed(month, gameIds[g])) return;
        uint256 amount = amountsOf[month][g];
        if (amount > remaining) return;
        bytes32[] memory proof = Merkle.proof(leaves, g);
        vm.prank(asOwner ? owner : stranger);
        pool.claim(month, gameIds[g], amount, proof);
        ghostPaid += amount;
    }

    function sweep(uint256 idx) external {
        if (proposedMonths.length == 0) return;
        uint256 month = proposedMonths[bound(idx, 0, proposedMonths.length - 1)];
        (,,, uint64 opensAt, bool cancelled, bool swept) = pool.months(month);
        if (cancelled || swept || block.timestamp < opensAt + 90 days) return;
        vm.prank(stranger);
        pool.sweep(month);
    }

    function changePayout(uint8 gameRaw, uint256 salt) external {
        uint256 g = bound(gameRaw, 0, GAMES - 1);
        address to = makeAddr(string.concat("moved", vm.toString(salt)));
        if (to == owner || to == payouts[g]) return;
        vm.prank(payouts[g]);
        pool.changePayout(gameIds[g], to);
        payouts[g] = to;
    }

    function toggleListing(uint8 gameRaw) external {
        uint256 g = bound(gameRaw, 0, GAMES - 1);
        (, bool listed) = pool.games(gameIds[g]);
        vm.prank(owner);
        if (listed) pool.delistGame(gameIds[g]);
        else pool.relistGame(gameIds[g]);
    }

    function warp(uint256 secs) external {
        skip(bound(secs, 1, 30 days));
    }
}

contract OGClubCreatorPoolInvariantTest is Test {
    MockOG internal og;
    OGClubCreatorPool internal pool;
    PoolHandler internal handler;
    address internal owner = makeAddr("owner");

    function setUp() public {
        vm.warp(1_800_000_000);
        og = new MockOG();
        pool = new OGClubCreatorPool(IERC20(address(og)), owner);
        handler = new PoolHandler(og, pool, owner);
        targetContract(address(handler));
    }

    function invariant_balanceCoversReserved() public view {
        assertGe(og.balanceOf(address(pool)), pool.reserved());
    }

    function invariant_reservedIsSumOfRemaining() public view {
        uint256 sum;
        uint256 n = handler.monthsCount();
        for (uint256 i; i < n; ++i) {
            (,, uint256 remaining,,,) = pool.months(handler.proposedMonths(i));
            sum += remaining;
        }
        assertEq(pool.reserved(), sum);
    }

    function invariant_ownerNeverGainsOG() public view {
        assertEq(og.balanceOf(owner), 0);
    }

    function invariant_conservation() public view {
        assertEq(og.balanceOf(address(pool)), handler.ghostFunded() - handler.ghostPaid());
    }
}
