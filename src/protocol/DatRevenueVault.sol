// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IUnifiedLedgerV4} from "../wusd/IUnifiedLedgerV4.sol";
import {IDatRevenueVault} from "./IDatRevenueVault.sol";

/// @title DatRevenueVault
/// @notice Holds finalized DAT revenue in WUSD until the DAT beneficiary claims it.
contract DatRevenueVault is AccessControl, ReentrancyGuard, IDatRevenueVault {
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    IUnifiedLedgerV4 public immutable ledger;
    address public override beneficiary;
    address public proposedBeneficiary;
    bool public beneficiaryChangeApproved;

    event DatRevenueClaimed(address indexed beneficiary, uint256 amount);
    event DatBeneficiaryChangeProposed(address indexed current, address indexed proposed);
    event DatBeneficiaryChangeApproved(address indexed proposed);
    event DatBeneficiaryChanged(address indexed previous, address indexed current);

    error ZeroAddress();
    error ZeroAmount();
    error UnauthorizedBeneficiary();
    error InvalidBeneficiaryChange();

    constructor(address governance, IUnifiedLedgerV4 ledger_, address beneficiary_) {
        if (governance == address(0) || address(ledger_) == address(0) || beneficiary_ == address(0)) {
            revert ZeroAddress();
        }
        if (address(ledger_).code.length == 0) revert ZeroAddress();

        ledger = ledger_;
        beneficiary = beneficiary_;
        _grantRole(DEFAULT_ADMIN_ROLE, governance);
        _grantRole(GOVERNANCE_ROLE, governance);
    }

    function claim(uint256 amount) external override nonReentrant {
        if (msg.sender != beneficiary) revert UnauthorizedBeneficiary();
        if (amount == 0) revert ZeroAmount();
        ledger.protocolTransfer(beneficiary, amount);
        emit DatRevenueClaimed(beneficiary, amount);
    }

    function claimAll() external override nonReentrant {
        if (msg.sender != beneficiary) revert UnauthorizedBeneficiary();
        uint256 amount = ledger.balanceOf(address(this));
        if (amount == 0) revert ZeroAmount();
        ledger.protocolTransfer(beneficiary, amount);
        emit DatRevenueClaimed(beneficiary, amount);
    }

    function proposeBeneficiary(address proposed) external {
        if (msg.sender != beneficiary) revert UnauthorizedBeneficiary();
        if (proposed == address(0) || proposed == beneficiary) revert InvalidBeneficiaryChange();
        proposedBeneficiary = proposed;
        beneficiaryChangeApproved = false;
        emit DatBeneficiaryChangeProposed(beneficiary, proposed);
    }

    function approveBeneficiaryChange(address proposed) external onlyRole(GOVERNANCE_ROLE) {
        if (proposed == address(0) || proposed != proposedBeneficiary) revert InvalidBeneficiaryChange();
        beneficiaryChangeApproved = true;
        emit DatBeneficiaryChangeApproved(proposed);
    }

    function acceptBeneficiary() external {
        if (msg.sender != proposedBeneficiary || !beneficiaryChangeApproved) revert InvalidBeneficiaryChange();
        address previous = beneficiary;
        beneficiary = msg.sender;
        proposedBeneficiary = address(0);
        beneficiaryChangeApproved = false;
        emit DatBeneficiaryChanged(previous, msg.sender);
    }
}
