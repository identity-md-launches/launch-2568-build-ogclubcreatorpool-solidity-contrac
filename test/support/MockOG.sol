// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Stand-in $OG for tests and the Sepolia rehearsal. Anyone can mint; never deploy on mainnet.
contract MockOG is ERC20 {
    constructor() ERC20("Mock OG", "OG") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
