// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title OGClubFarmVault (test reference)
/// @notice TEST SUPPORT ONLY. The workspace this pool was built in did not contain the deployed
///         OGClubFarmVault source, so the integration test runs against this reconstruction of the
///         vault's season interface as the brief describes it: the owner opens a season with a Merkle
///         root of `(season, account, amount)` leaves, and `claim(season, account, amount, proof)`
///         pays `account` in $OG. The creator pool is just one such account. Nothing in src/ depends
///         on this file. Replace the import in the integration test with the real vault when its
///         source is in the repository; the pool-side flow is unchanged.
contract OGClubFarmVault is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Season {
        bytes32 root;
        uint256 total;
        uint256 remaining;
        bool open;
    }

    IERC20 public immutable token;
    mapping(uint256 season => Season) public seasons;
    mapping(uint256 season => mapping(address account => bool)) public claimed;
    uint256 public reserved;

    event SeasonOpened(uint256 indexed season, bytes32 root, uint256 total);
    event Claimed(uint256 indexed season, address indexed account, uint256 amount);

    error ZeroAddress();
    error SeasonExists(uint256 season);
    error SeasonNotOpen(uint256 season);
    error InsufficientFree(uint256 requested, uint256 free);
    error AlreadyClaimed(uint256 season, address account);
    error InvalidProof();
    error ExceedsRemaining(uint256 amount, uint256 remaining);

    constructor(IERC20 token_, address owner_) Ownable(owner_) {
        if (address(token_) == address(0)) revert ZeroAddress();
        token = token_;
    }

    function free() public view returns (uint256) {
        return token.balanceOf(address(this)) - reserved;
    }

    function openSeason(uint256 season, bytes32 root, uint256 total) external onlyOwner {
        if (seasons[season].open) revert SeasonExists(season);
        uint256 available = free();
        if (total > available) revert InsufficientFree(total, available);
        seasons[season] = Season({root: root, total: total, remaining: total, open: true});
        reserved += total;
        emit SeasonOpened(season, root, total);
    }

    function leaf(uint256 season, address account, uint256 amount) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(season, account, amount))));
    }

    /// @notice Pays `account` its share of `season`. Anyone may push a claim for any account.
    function claim(uint256 season, address account, uint256 amount, bytes32[] calldata proof) external nonReentrant {
        Season storage s = seasons[season];
        if (!s.open) revert SeasonNotOpen(season);
        if (claimed[season][account]) revert AlreadyClaimed(season, account);
        if (!MerkleProof.verifyCalldata(proof, s.root, leaf(season, account, amount))) revert InvalidProof();
        if (amount > s.remaining) revert ExceedsRemaining(amount, s.remaining);
        claimed[season][account] = true;
        s.remaining -= amount;
        reserved -= amount;
        token.safeTransfer(account, amount);
        emit Claimed(season, account, amount);
    }
}
