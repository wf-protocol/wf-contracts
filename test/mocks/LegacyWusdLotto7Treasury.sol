// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IUnifiedLedgerV2} from "../../src/wusd/IUnifiedLedgerV2.sol";

/// @dev Storage-compatible snapshot of WusdLotto7Treasury before Shared Carry.
contract LegacyWusdLotto7Treasury is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard
{
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    IUnifiedLedgerV2 public ledger;
    uint256 public pendingPrize;
    uint256 public opsAccrued;
    uint256 public dividendAccrued;
    uint256 public jackpot1;
    uint256 public jackpot2;
    uint256 public jackpot3;
    uint256 public unclaimedPrize;
    mapping(uint256 => bool) public salesCollected;

    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, IUnifiedLedgerV2 ledger_) external initializer {
        __AccessControl_init();
        __Pausable_init();
        ledger = ledger_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
    }

    function seedLegacyAccounting(uint256 unclaimed, uint256 j1, uint256 j2, uint256 j3, uint256 ops, uint256 dividend)
        external
        onlyRole(ADMIN_ROLE)
    {
        unclaimedPrize = unclaimed;
        jackpot1 = j1;
        jackpot2 = j2;
        jackpot3 = j3;
        opsAccrued = ops;
        dividendAccrued = dividend;
    }

    function _authorizeUpgrade(address) internal override onlyRole(ADMIN_ROLE) {}
}
