// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOptimisticOracleV3} from "../../src/games/lotto7uma/interfaces/IOptimisticOracleV3.sol";

interface IUmaCallback {
    function assertionResolvedCallback(bytes32 id, bool truthful) external;
    function assertionDisputedCallback(bytes32 id) external;
}

/// @notice Local tests only. Dispute resolution is intentionally test-controlled.
contract MockUmaOracle is IOptimisticOracleV3 {
    struct Assertion {
        address callback;
        IERC20 currency;
        uint256 bond;
        uint256 expires;
        bool disputed;
        bool settled;
        bool truthful;
    }
    uint256 public nonce;
    bytes public lastClaim;
    mapping(bytes32 => Assertion) public assertions;

    function defaultIdentifier() external pure returns (bytes32) {
        return bytes32("ASSERT_TRUTH");
    }

    function getMinimumBond(IERC20) external pure returns (uint256) {
        return 1e6;
    }

    function assertTruth(
        bytes memory claim,
        address,
        address callback,
        address,
        uint64 liveness,
        IERC20 currency,
        uint256 bond,
        bytes32,
        bytes32
    ) external returns (bytes32 id) {
        require(currency.transferFrom(msg.sender, address(this), bond));
        id = keccak256(abi.encode(++nonce, claim));
        assertions[id] = Assertion(callback, currency, bond, block.timestamp + liveness, false, false, true);
        lastClaim = claim;
    }

    function dispute(bytes32 id) external {
        Assertion storage a = assertions[id];
        require(a.callback != address(0) && !a.settled && block.timestamp < a.expires);
        a.disputed = true;
        IUmaCallback(a.callback).assertionDisputedCallback(id);
    }

    function resolveDispute(bytes32 id, bool truthful) external {
        Assertion storage a = assertions[id];
        require(a.disputed);
        a.disputed = false;
        a.truthful = truthful;
    }

    function settleAndGetAssertionResult(bytes32 id) external returns (bool) {
        Assertion storage a = assertions[id];
        require(a.callback != address(0) && !a.settled && !a.disputed && block.timestamp >= a.expires);
        a.settled = true;
        if (a.truthful) require(a.currency.transfer(a.callback, a.bond));
        IUmaCallback(a.callback).assertionResolvedCallback(id, a.truthful);
        return a.truthful;
    }
}
