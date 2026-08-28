// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {IProtocolRevenueRouter} from "./IProtocolRevenueRouter.sol";

/// @title ProtocolRevenueRouter
/// @notice Versioned revenue allocation shared by official lottery games.
contract ProtocolRevenueRouter is AccessControl, IProtocolRevenueRouter {
    uint256 public constant BPS_DENOMINATOR = 10_000;
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    uint32 public override activeVersion;
    mapping(uint32 version => RevenueAllocation value) private _allocations;

    event RevenueAllocationUpdated(
        uint32 indexed version,
        uint16 prizeBps,
        uint16 datBps,
        uint16 partnerBps,
        uint16 opsBps,
        address indexed executor
    );

    error ZeroAddress();
    error InvalidAllocationTotal();
    error AllocationNotFound();

    constructor(address governance, uint16 prizeBps, uint16 datBps, uint16 partnerBps, uint16 opsBps) {
        if (governance == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, governance);
        _grantRole(GOVERNANCE_ROLE, governance);
        _setRevenueAllocation(prizeBps, datBps, partnerBps, opsBps);
    }

    function setRevenueAllocation(uint16 prizeBps, uint16 datBps, uint16 partnerBps, uint16 opsBps)
        external
        onlyRole(GOVERNANCE_ROLE)
        returns (uint32 newVersion)
    {
        return _setRevenueAllocation(prizeBps, datBps, partnerBps, opsBps);
    }

    function activeAllocation() external view override returns (RevenueAllocation memory) {
        return _allocations[activeVersion];
    }

    function allocation(uint32 version) external view override returns (RevenueAllocation memory value) {
        value = _allocations[version];
        if (value.version == 0) revert AllocationNotFound();
    }

    function _setRevenueAllocation(uint16 prizeBps, uint16 datBps, uint16 partnerBps, uint16 opsBps)
        internal
        returns (uint32 newVersion)
    {
        if (uint256(prizeBps) + datBps + partnerBps + opsBps != BPS_DENOMINATOR) {
            revert InvalidAllocationTotal();
        }

        newVersion = activeVersion + 1;
        activeVersion = newVersion;
        _allocations[newVersion] = RevenueAllocation({
            prizeBps: prizeBps, datBps: datBps, partnerBps: partnerBps, opsBps: opsBps, version: newVersion
        });

        emit RevenueAllocationUpdated(newVersion, prizeBps, datBps, partnerBps, opsBps, msg.sender);
    }
}
