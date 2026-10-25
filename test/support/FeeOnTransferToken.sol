// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice ERC-20 that burns 1% on every transfer. Used to prove the pool's exact balance checks.
///         With `chargeSender == false` the recipient receives 1% less than sent (the usual
///         fee-on-transfer shape, caught by {OGClubCreatorPool.fund}). With `chargeSender == true`
///         the sender is debited 1% more than the amount (caught by {OGClubCreatorPool.claim}).
contract FeeOnTransferToken is ERC20 {
    uint256 public constant FEE_BPS = 100;
    bool public immutable chargeSender;

    constructor(bool chargeSender_) ERC20("Fee Token", "FEE") {
        chargeSender = chargeSender_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = (value * FEE_BPS) / 10_000;
            super._update(from, address(0), fee);
            if (!chargeSender) value -= fee;
        }
        super._update(from, to, value);
    }
}
