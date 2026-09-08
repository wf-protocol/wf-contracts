// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import {IGameRegistry} from "./IGameRegistry.sol";
import {IGameModuleV4} from "./IGameModuleV4.sol";

/// @title GameRegistry
/// @notice Canonical registry for games that UnifiedLedger V4 may execute.
contract GameRegistry is Initializable, UUPSUpgradeable, AccessControlUpgradeable, IGameRegistry {
    bytes32 public constant REGISTRY_MANAGER_ROLE = keccak256("REGISTRY_MANAGER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    mapping(address game => GameConfig config) private _games;
    mapping(address treasury => address game) public override gameForTreasury;

    event GameRegistered(
        address indexed game,
        address indexed treasury,
        address indexed oracleAdapter,
        bytes32 implementationHash,
        bytes32 rulesHash,
        bool verified,
        bool sponsored
    );
    event GameStatusChanged(address indexed game, GameStatus previousStatus, GameStatus newStatus);
    event GameReviewChanged(
        address indexed game, bytes32 implementationHash, bytes32 rulesHash, bool verified, bool sponsored
    );

    error ZeroAddress();
    error GameAlreadyRegistered();
    error GameNotRegistered();
    error TreasuryAlreadyRegistered(address game);
    error InvalidStatusTransition();
    error ImplementationHashUnavailable();
    error ImplementationHashMismatch(bytes32 expected, bytes32 actual);
    error InvalidRulesHash();
    error NotAContract(address target);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin) external initializer {
        if (admin == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(REGISTRY_MANAGER_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
    }

    function registerGame(
        address game,
        address treasury,
        address oracleAdapter,
        bytes32 implementationHash,
        bytes32 rulesHash,
        bool verified,
        bool sponsored
    ) external onlyRole(REGISTRY_MANAGER_ROLE) {
        _registerGame(game, treasury, oracleAdapter, implementationHash, rulesHash, verified, sponsored);
    }

    function _registerGame(
        address game,
        address treasury,
        address oracleAdapter,
        bytes32 implementationHash,
        bytes32 rulesHash,
        bool verified,
        bool sponsored
    ) internal {
        if (game == address(0) || treasury == address(0)) revert ZeroAddress();
        if (treasury.code.length == 0) revert NotAContract(treasury);
        if (oracleAdapter != address(0) && oracleAdapter.code.length == 0) revert NotAContract(oracleAdapter);
        if (rulesHash == bytes32(0)) revert InvalidRulesHash();
        if (_games[game].status != GameStatus.None) revert GameAlreadyRegistered();
        if (gameForTreasury[treasury] != address(0)) revert TreasuryAlreadyRegistered(gameForTreasury[treasury]);
        _requireImplementationHash(game, implementationHash);

        _games[game] = GameConfig({
            treasury: treasury,
            oracleAdapter: oracleAdapter,
            implementationHash: implementationHash,
            rulesHash: rulesHash,
            status: GameStatus.Active,
            verified: verified,
            sponsored: sponsored
        });
        gameForTreasury[treasury] = game;

        emit GameRegistered(game, treasury, oracleAdapter, implementationHash, rulesHash, verified, sponsored);
        emit GameStatusChanged(game, GameStatus.None, GameStatus.Active);
    }

    function setGameStatus(address game, GameStatus newStatus) external onlyRole(REGISTRY_MANAGER_ROLE) {
        GameConfig storage config = _requireGame(game);
        if (newStatus == GameStatus.None || config.status == newStatus) revert InvalidStatusTransition();

        GameStatus previousStatus = config.status;
        config.status = newStatus;
        emit GameStatusChanged(game, previousStatus, newStatus);
    }

    /// @notice Emergency guardians may only reduce permissions by suspending a game.
    function suspendGame(address game) external onlyRole(GUARDIAN_ROLE) {
        GameConfig storage config = _requireGame(game);
        if (config.status != GameStatus.Active) revert InvalidStatusTransition();

        config.status = GameStatus.Suspended;
        emit GameStatusChanged(game, GameStatus.Active, GameStatus.Suspended);
    }

    function setGameReview(address game, bytes32 implementationHash, bytes32 rulesHash, bool verified, bool sponsored)
        external
        onlyRole(REGISTRY_MANAGER_ROLE)
    {
        GameConfig storage config = _requireGame(game);
        if (rulesHash == bytes32(0)) revert InvalidRulesHash();
        _requireImplementationHash(game, implementationHash);
        config.implementationHash = implementationHash;
        config.rulesHash = rulesHash;
        config.verified = verified;
        config.sponsored = sponsored;

        emit GameReviewChanged(game, implementationHash, rulesHash, verified, sponsored);
    }

    function getGameConfig(address game) external view returns (GameConfig memory config) {
        config = _games[game];
        if (config.status != GameStatus.None && !_implementationMatches(game, config.implementationHash)) {
            config.status = GameStatus.Suspended;
            config.verified = false;
            config.sponsored = false;
        }
    }

    function isActive(address game) external view returns (bool) {
        GameConfig storage config = _games[game];
        return config.status == GameStatus.Active && _implementationMatches(game, config.implementationHash);
    }

    function _requireImplementationHash(address game, bytes32 expectedHash) internal view {
        (bytes32 currentHash, bool available) = _currentImplementationHash(game);
        if (!available) revert ImplementationHashUnavailable();
        if (currentHash != expectedHash) revert ImplementationHashMismatch(expectedHash, currentHash);
    }

    function _implementationMatches(address game, bytes32 expectedHash) internal view returns (bool) {
        (bytes32 currentHash, bool available) = _currentImplementationHash(game);
        return available && currentHash == expectedHash;
    }

    function _currentImplementationHash(address game) internal view returns (bytes32 currentHash, bool available) {
        if (game.code.length == 0) return (bytes32(0), false);

        (bool success, bytes memory returnData) =
            game.staticcall(abi.encodeWithSelector(IGameModuleV4.protocolImplementationHash.selector));
        if (!success || returnData.length != 32) return (bytes32(0), false);

        currentHash = abi.decode(returnData, (bytes32));
        return (currentHash, currentHash != bytes32(0));
    }

    function _requireGame(address game) internal view returns (GameConfig storage config) {
        config = _games[game];
        if (config.status == GameStatus.None) revert GameNotRegistered();
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}
}
