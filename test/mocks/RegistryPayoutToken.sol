// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Fault injection for registry payouts, not a claim about the live Sepolia token.
/// Pulls and approvals are ordinary ERC-20 operations. Each payout recipient can independently
/// refuse transfer(), or accept it without return data. Failed transfers never move tokens.
contract RegistryPayoutToken is ERC20 {
    enum Mode {
        Standard,
        Revert,
        False,
        NoReturn
    }

    error RecipientRefused(address recipient);

    mapping(address => Mode) public mode;

    constructor() ERC20("Registry payout test asset", "RPT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setMode(address recipient, Mode next) external {
        mode[recipient] = next;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        Mode response = mode[to];
        if (response == Mode.Revert) revert RecipientRefused(to);
        if (response == Mode.False) return false;
        super.transfer(to, amount);
        if (response == Mode.NoReturn) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return true;
    }
}
