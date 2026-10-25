// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OGClubCreatorPool} from "../src/OGClubCreatorPool.sol";
import {MockOG} from "./support/MockOG.sol";
import {Merkle} from "./support/Merkle.sol";

contract OGClubCreatorPoolFuzzTest is Test {
    uint256 internal constant START = 1_800_000_000;
    uint256 internal constant MONTH = 202_703;
    uint256 internal constant MAX_GAMES = 12;

    MockOG internal og;
    OGClubCreatorPool internal pool;
    address internal owner = makeAddr("owner");

    bytes32[] internal gameIds;
    address[] internal payouts;

    function setUp() public {
        vm.warp(START);
        og = new MockOG();
        pool = new OGClubCreatorPool(IERC20(address(og)), owner);
        for (uint256 i; i < MAX_GAMES; ++i) {
            bytes32 id = pool.gameId(string.concat("game-", vm.toString(i)));
            address payout = makeAddr(string.concat("dev-", vm.toString(i)));
            gameIds.push(id);
            payouts.push(payout);
            vm.prank(owner);
            pool.listGame(id, payout);
        }
    }

    /// @notice Whatever the list says and however the claims are ordered, a month never pays more
    ///         than its total, and the pool's accounting always matches its balance.
    function testFuzz_paidPerMonthNeverExceedsTotal(uint256 seed, uint8 countRaw, uint256 total, uint256 extraFree)
        public
    {
        uint256 count = bound(countRaw, 1, MAX_GAMES);
        total = bound(total, 1, 1_000_000 ether);
        extraFree = bound(extraFree, 0, 1_000_000 ether);

        // Amounts may add up to more or less than `total`: the on-chain cap is what we are testing.
        bytes32[] memory leaves = new bytes32[](count);
        uint256[] memory amounts = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            amounts[i] = bound(uint256(keccak256(abi.encode(seed, i))), 1, total);
            leaves[i] = pool.leaf(MONTH, gameIds[i], amounts[i]);
        }
        bytes32 root = Merkle.root(leaves);

        og.mint(address(pool), total + extraFree);
        vm.prank(owner);
        pool.proposeMonth(MONTH, root, total);
        assertEq(pool.reserved(), total);
        assertEq(pool.free(), extraFree);

        skip(3 days);
        uint256 paid;
        uint256 order = uint256(keccak256(abi.encode(seed, "order")));
        for (uint256 step; step < count; ++step) {
            // Claim in a seed-dependent order.
            uint256 i = (order + step * 7) % count;
            if (pool.claimed(MONTH, gameIds[i])) continue;
            uint256 before = og.balanceOf(payouts[i]);
            (,, uint256 remaining,,,) = pool.months(MONTH);
            if (amounts[i] > remaining) {
                vm.expectRevert(
                    abi.encodeWithSelector(OGClubCreatorPool.ExceedsRemaining.selector, amounts[i], remaining)
                );
                pool.claim(MONTH, gameIds[i], amounts[i], Merkle.proof(leaves, i));
                continue;
            }
            pool.claim(MONTH, gameIds[i], amounts[i], Merkle.proof(leaves, i));
            paid += amounts[i];
            assertEq(og.balanceOf(payouts[i]) - before, amounts[i]);
        }

        assertLe(paid, total, "paid more than total");
        (,, uint256 left,,,) = pool.months(MONTH);
        assertEq(left, total - paid);
        assertEq(pool.reserved(), total - paid);
        assertEq(og.balanceOf(address(pool)), total + extraFree - paid);
        assertEq(pool.free(), extraFree, "free untouched by claims");
        assertGe(og.balanceOf(address(pool)), pool.reserved());
        assertEq(og.balanceOf(owner), 0);
    }

    /// @notice Any proof for a leaf not in the tree is refused, whatever the amount or game.
    function testFuzz_forgedLeafRejected(uint256 seed, uint256 amount, uint8 which) public {
        bytes32[] memory leaves = new bytes32[](3);
        uint256[3] memory amounts = [uint256(10 ether), 20 ether, 30 ether];
        for (uint256 i; i < 3; ++i) {
            leaves[i] = pool.leaf(MONTH, gameIds[i], amounts[i]);
        }
        og.mint(address(pool), 60 ether);
        bytes32 root = Merkle.root(leaves);
        vm.prank(owner);
        pool.proposeMonth(MONTH, root, 60 ether);
        skip(3 days);

        uint256 i = bound(which, 0, 2);
        amount = bound(amount, 1, type(uint128).max);
        vm.assume(amount != amounts[i]);
        bytes32[] memory proof = Merkle.proof(leaves, i);
        if (seed % 2 == 0 && proof.length > 0) proof[0] = bytes32(seed);
        vm.expectRevert(OGClubCreatorPool.InvalidProof.selector);
        pool.claim(MONTH, gameIds[i], amount, proof);
    }

    /// @notice Month ids outside YYYYMM with month 1..12 and year >= 2026 are refused.
    function testFuzz_monthIdValidation(uint256 month) public {
        og.mint(address(pool), 1 ether);
        uint256 mm = month % 100;
        uint256 year = month / 100;
        bool valid = mm >= 1 && mm <= 12 && year >= 2026 && year <= 9999;
        assertEq(pool.isValidMonth(month), valid);
        vm.prank(owner);
        if (!valid) {
            vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.InvalidMonth.selector, month));
        }
        pool.proposeMonth(month, bytes32(uint256(1)), 1 ether);
    }
}
