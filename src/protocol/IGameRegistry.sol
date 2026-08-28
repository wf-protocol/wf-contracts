// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IGameRegistry {
    enum GameStatus {
        None,
        Active,
        Suspended,
        Retired
    }

    struct GameConfig {
        address treasury;
        address oracleAdapter;
        bytes32 implementationHash;
        bytes32 rulesHash;
        GameStatus status;
        bool verified;
        bool sponsored;
    }

    function getGameConfig(address game) external view returns (GameConfig memory);
    function isActive(address game) external view returns (bool);
    function gameForTreasury(address treasury) external view returns (address game);
}
