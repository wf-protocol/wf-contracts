// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {IUnifiedLedgerV2} from "./IUnifiedLedgerV2.sol";

/// @title UnifiedLedgerV2
contract UnifiedLedgerV2 is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    IUnifiedLedgerV2
{
    bytes32 public constant RESERVE_ROLE = keccak256("RESERVE_ROLE");
    bytes32 public constant OPERATOR_MANAGER_ROLE = keccak256("OPERATOR_MANAGER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    uint8 public constant WUSD_DECIMALS = 6;
    mapping(address account => uint256 amount) internal _balances;
    mapping(address owner => mapping(address operator => uint256 amount)) internal _operatorAllowances;
    mapping(address operator => bool enabled) public operators;

    uint256 public totalWusdLiability;
    mapping(address operator => bool enabled) public directOperators;

    event ReserveCredit(address indexed reserve, address indexed account, uint256 amount, uint256 newBalance);
    event ReserveDebit(address indexed reserve, address indexed account, uint256 amount, uint256 newBalance);
    event OperatorApproval(address indexed owner, address indexed operator, uint256 amount);
    event OperatorRegistered(address indexed operator);
    event OperatorRemoved(address indexed operator);
    event DirectOperatorSet(address indexed operator, bool enabled);
    event OperatorTransfer(
        address indexed operator,
        address indexed from,
        address indexed to,
        uint256 amount,
        uint256 fromNewBalance,
        uint256 toNewBalance
    );

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientBalance();
    error OperatorNotRegistered();
    error DirectOperatorNotEnabled();
    error ExceedsOperatorAllowance();
    error InvalidTransfer();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin) external initializer {
        if (admin == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_MANAGER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function operatorAllowances(address owner, address operator) external view returns (uint256) {
        return _operatorAllowances[owner][operator];
    }

    function creditFromReserve(address account, uint256 amount)
        external
        onlyRole(RESERVE_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (account == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        totalWusdLiability += amount;
        uint256 newBalance = _balances[account] + amount;
        _balances[account] = newBalance;

        emit ReserveCredit(msg.sender, account, amount, newBalance);
    }

    function debitToReserve(address account, uint256 amount) external onlyRole(RESERVE_ROLE) nonReentrant {
        if (account == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint256 currentBalance = _balances[account];
        if (currentBalance < amount) revert InsufficientBalance();

        uint256 newBalance = currentBalance - amount;
        _balances[account] = newBalance;
        totalWusdLiability -= amount;

        emit ReserveDebit(msg.sender, account, amount, newBalance);
    }

    function approveOperator(address operator, uint256 amount) external {
        _approveOperator(msg.sender, operator, amount);
    }

    function _approveOperator(address owner, address operator, uint256 amount) internal {
        if (operator == address(0)) revert ZeroAddress();
        _operatorAllowances[owner][operator] = amount;
        emit OperatorApproval(owner, operator, amount);
    }

    function operatorTransfer(address from, address to, uint256 amount) external whenNotPaused nonReentrant {
        _operatorTransfer(from, to, amount);
    }

    function directOperatorTransfer(address from, address to, uint256 amount)
        public
        virtual
        whenNotPaused
        nonReentrant
    {
        if (!operators[msg.sender]) revert OperatorNotRegistered();
        if (!directOperators[msg.sender]) revert DirectOperatorNotEnabled();
        _moveBalance(msg.sender, from, to, amount);
    }

    function _operatorTransfer(address from, address to, uint256 amount) internal {
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        if (from == to) revert InvalidTransfer();
        if (amount == 0) revert ZeroAmount();
        if (!operators[msg.sender]) revert OperatorNotRegistered();

        uint256 currentAllowance = _operatorAllowances[from][msg.sender];
        if (currentAllowance < amount) revert ExceedsOperatorAllowance();

        _operatorAllowances[from][msg.sender] = currentAllowance - amount;
        _moveBalance(msg.sender, from, to, amount);
    }

    function _moveBalance(address operator, address from, address to, uint256 amount) internal {
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        if (from == to) revert InvalidTransfer();
        if (amount == 0) revert ZeroAmount();

        uint256 fromBalance = _balances[from];
        if (fromBalance < amount) revert InsufficientBalance();

        uint256 fromNewBalance = fromBalance - amount;
        uint256 toNewBalance = _balances[to] + amount;
        _balances[from] = fromNewBalance;
        _balances[to] = toNewBalance;

        emit OperatorTransfer(operator, from, to, amount, fromNewBalance, toNewBalance);
    }

    function registerOperator(address operator) external onlyRole(OPERATOR_MANAGER_ROLE) {
        if (operator == address(0)) revert ZeroAddress();
        operators[operator] = true;
        emit OperatorRegistered(operator);
    }

    function removeOperator(address operator) external onlyRole(OPERATOR_MANAGER_ROLE) {
        operators[operator] = false;
        directOperators[operator] = false;
        emit OperatorRemoved(operator);
        emit DirectOperatorSet(operator, false);
    }

    function setDirectOperator(address operator, bool enabled) external onlyRole(OPERATOR_MANAGER_ROLE) {
        if (operator == address(0)) revert ZeroAddress();
        if (enabled && !operators[operator]) revert OperatorNotRegistered();
        directOperators[operator] = enabled;
        emit DirectOperatorSet(operator, enabled);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}
}
