// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {IUnifiedLedgerV2} from "./IUnifiedLedgerV2.sol";

/// @title StablecoinReserve
contract StablecoinReserve is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    EIP712Upgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    bytes32 public constant TOKEN_MANAGER_ROLE = keccak256("TOKEN_MANAGER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    uint256 public constant BPS = 10_000;
    uint8 public constant WUSD_DECIMALS = 6;
    uint256 private constant DAILY_WINDOW = 1 days;

    bytes32 private constant DEPOSIT_AUTH_TYPEHASH = keccak256(
        "DepositAuthorization(address user,address token,uint256 authorizedAmount,uint256 deadline,uint256 nonce)"
    );

    struct AssetConfig {
        bool exists;
        bool depositEnabled;
        bool withdrawalEnabled;
        uint8 decimals;
        uint16 wusdRateBps;
        uint128 singleDepositLimit;
        uint128 dailyDepositLimit;
        uint128 dailyWithdrawLimit;
    }

    struct DailyWindow {
        uint64 windowStart;
        uint192 accumulated;
    }

    IUnifiedLedgerV2 public ledger;
    address public signer;

    mapping(address token => AssetConfig config) public assetConfigs;
    mapping(address token => uint256 amount) public accountedReserve;
    mapping(address user => mapping(uint256 nonce => bool used)) public usedNonces;
    mapping(address user => mapping(address token => DailyWindow window)) public depositWindows;
    mapping(address user => mapping(address token => DailyWindow window)) public withdrawalWindows;

    address[] private _assets;

    event AssetAdded(
        address indexed token,
        uint8 decimals,
        uint16 wusdRateBps,
        uint128 singleDepositLimit,
        uint128 dailyDepositLimit,
        uint128 dailyWithdrawLimit
    );
    event AssetStatusUpdated(address indexed token, bool depositEnabled, bool withdrawalEnabled);
    event AssetRiskUpdated(
        address indexed token,
        uint16 wusdRateBps,
        uint128 singleDepositLimit,
        uint128 dailyDepositLimit,
        uint128 dailyWithdrawLimit
    );
    event SignerUpdated(address indexed oldSigner, address indexed newSigner);
    event Deposited(
        address indexed user,
        address indexed token,
        uint256 requestedAmount,
        uint256 receivedAmount,
        uint256 wusdCredited,
        uint256 nonce
    );
    event Withdrawn(
        address indexed user, address indexed token, address indexed recipient, uint256 wusdDebited, uint256 tokenAmount
    );

    error ZeroAddress();
    error ZeroAmount();
    error InvalidSignature();
    error SignatureExpired();
    error NonceAlreadyUsed();
    error ExceedsAuthorizedAmount();
    error AssetAlreadyExists();
    error AssetNotSupported();
    error DepositDisabled();
    error WithdrawalDisabled();
    error InvalidDecimals();
    error InvalidRate();
    error SlippageExceeded();
    error ExceedsSingleDepositLimit();
    error ExceedsDailyDepositLimit();
    error ExceedsDailyWithdrawLimit();
    error InsufficientReserve();
    error AmountOverflow();
    error UnsupportedTransferSemantics();
    error UnsafeRateChange();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, IUnifiedLedgerV2 ledger_, address signer_) external initializer {
        if (admin == address(0) || address(ledger_) == address(0) || signer_ == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __EIP712_init("WUSDStablecoinReserve", "1");
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        ledger = ledger_;
        signer = signer_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(TOKEN_MANAGER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
    }

    function deposit(
        address token,
        uint256 amount,
        uint256 authorizedAmount,
        uint256 minWusdOut,
        uint256 deadline,
        uint256 nonce,
        bytes calldata signature
    ) external whenNotPaused nonReentrant returns (uint256 received, uint256 wusdCredited) {
        AssetConfig memory config = assetConfigs[token];
        if (!config.exists) revert AssetNotSupported();
        if (!config.depositEnabled) revert DepositDisabled();
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp > deadline) revert SignatureExpired();
        if (usedNonces[msg.sender][nonce]) revert NonceAlreadyUsed();
        if (amount > authorizedAmount) revert ExceedsAuthorizedAmount();

        bytes32 structHash =
            keccak256(abi.encode(DEPOSIT_AUTH_TYPEHASH, msg.sender, token, authorizedAmount, deadline, nonce));
        if (ECDSA.recover(_hashTypedDataV4(structHash), signature) != signer) revert InvalidSignature();

        usedNonces[msg.sender][nonce] = true;

        uint256 beforeBalance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        received = IERC20(token).balanceOf(address(this)) - beforeBalance;
        if (received == 0) revert ZeroAmount();

        wusdCredited = _tokenToWusd(received, config.decimals, config.wusdRateBps);
        if (wusdCredited == 0) revert ZeroAmount();
        if (wusdCredited < minWusdOut) revert SlippageExceeded();
        if (config.singleDepositLimit != 0 && wusdCredited > config.singleDepositLimit) {
            revert ExceedsSingleDepositLimit();
        }
        _consumeWindow(depositWindows[msg.sender][token], wusdCredited, config.dailyDepositLimit, true);

        accountedReserve[token] += received;
        ledger.creditFromReserve(msg.sender, wusdCredited);

        emit Deposited(msg.sender, token, amount, received, wusdCredited, nonce);
    }

    function withdraw(address token, uint256 wusdAmount, uint256 minTokenOut, address recipient)
        external
        nonReentrant
        returns (uint256 tokenAmount)
    {
        AssetConfig memory config = assetConfigs[token];
        if (!config.exists) revert AssetNotSupported();
        if (!config.withdrawalEnabled) revert WithdrawalDisabled();
        if (recipient == address(0)) revert ZeroAddress();
        if (wusdAmount == 0) revert ZeroAmount();

        tokenAmount = _wusdToToken(wusdAmount, config.decimals, config.wusdRateBps);
        if (tokenAmount == 0) revert ZeroAmount();
        if (IERC20(token).balanceOf(address(this)) < tokenAmount) {
            revert InsufficientReserve();
        }
        _consumeWindow(withdrawalWindows[msg.sender][token], wusdAmount, config.dailyWithdrawLimit, false);

        uint256 reserveBefore = IERC20(token).balanceOf(address(this));
        uint256 recipientBefore = IERC20(token).balanceOf(recipient);
        ledger.debitToReserve(msg.sender, wusdAmount);
        IERC20(token).safeTransfer(recipient, tokenAmount);
        uint256 reserveSpent = reserveBefore - IERC20(token).balanceOf(address(this));
        if (reserveSpent != tokenAmount) revert UnsupportedTransferSemantics();
        uint256 received = IERC20(token).balanceOf(recipient) - recipientBefore;
        if (received < minTokenOut) revert SlippageExceeded();

        uint256 accounted = accountedReserve[token];
        accountedReserve[token] = accounted > reserveSpent ? accounted - reserveSpent : 0;
        tokenAmount = received;

        emit Withdrawn(msg.sender, token, recipient, wusdAmount, tokenAmount);
    }

    function addAsset(
        address token,
        uint16 wusdRateBps,
        uint128 singleDepositLimit,
        uint128 dailyDepositLimit,
        uint128 dailyWithdrawLimit
    ) external onlyRole(TOKEN_MANAGER_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (assetConfigs[token].exists) revert AssetAlreadyExists();
        if (wusdRateBps == 0 || wusdRateBps > BPS) revert InvalidRate();

        uint8 decimals = IERC20Metadata(token).decimals();
        if (decimals > 18) revert InvalidDecimals();

        assetConfigs[token] = AssetConfig({
            exists: true,
            depositEnabled: true,
            withdrawalEnabled: true,
            decimals: decimals,
            wusdRateBps: wusdRateBps,
            singleDepositLimit: singleDepositLimit,
            dailyDepositLimit: dailyDepositLimit,
            dailyWithdrawLimit: dailyWithdrawLimit
        });
        _assets.push(token);

        emit AssetAdded(token, decimals, wusdRateBps, singleDepositLimit, dailyDepositLimit, dailyWithdrawLimit);
    }

    function setAssetStatus(address token, bool depositEnabled, bool withdrawalEnabled)
        external
        onlyRole(TOKEN_MANAGER_ROLE)
    {
        AssetConfig storage config = assetConfigs[token];
        if (!config.exists) revert AssetNotSupported();
        config.depositEnabled = depositEnabled;
        config.withdrawalEnabled = withdrawalEnabled;
        emit AssetStatusUpdated(token, depositEnabled, withdrawalEnabled);
    }

    function setAssetRisk(
        address token,
        uint16 wusdRateBps,
        uint128 singleDepositLimit,
        uint128 dailyDepositLimit,
        uint128 dailyWithdrawLimit
    ) external onlyRole(TOKEN_MANAGER_ROLE) {
        AssetConfig storage config = assetConfigs[token];
        if (!config.exists) revert AssetNotSupported();
        if (wusdRateBps == 0 || wusdRateBps > BPS) revert InvalidRate();
        if (
            wusdRateBps != config.wusdRateBps
                && (config.depositEnabled || config.withdrawalEnabled || IERC20(token).balanceOf(address(this)) != 0)
        ) revert UnsafeRateChange();

        config.wusdRateBps = wusdRateBps;
        config.singleDepositLimit = singleDepositLimit;
        config.dailyDepositLimit = dailyDepositLimit;
        config.dailyWithdrawLimit = dailyWithdrawLimit;

        emit AssetRiskUpdated(token, wusdRateBps, singleDepositLimit, dailyDepositLimit, dailyWithdrawLimit);
    }

    function setSigner(address newSigner) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newSigner == address(0)) revert ZeroAddress();
        address oldSigner = signer;
        signer = newSigner;
        emit SignerUpdated(oldSigner, newSigner);
    }

    function pauseDeposits() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpauseDeposits() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function assetCount() external view returns (uint256) {
        return _assets.length;
    }

    function assetAt(uint256 index) external view returns (address) {
        return _assets[index];
    }

    function previewDeposit(address token, uint256 tokenAmount) external view returns (uint256) {
        AssetConfig memory config = assetConfigs[token];
        if (!config.exists) revert AssetNotSupported();
        return _tokenToWusd(tokenAmount, config.decimals, config.wusdRateBps);
    }

    function previewWithdraw(address token, uint256 wusdAmount) external view returns (uint256) {
        AssetConfig memory config = assetConfigs[token];
        if (!config.exists) revert AssetNotSupported();
        return _wusdToToken(wusdAmount, config.decimals, config.wusdRateBps);
    }

    function totalRecognizedReserve() public view returns (uint256 total) {
        for (uint256 i = 0; i < _assets.length; i++) {
            address token = _assets[i];
            AssetConfig memory config = assetConfigs[token];
            total += _tokenToWusd(IERC20(token).balanceOf(address(this)), config.decimals, config.wusdRateBps);
        }
    }

    function isSolvent() external view returns (bool) {
        return totalRecognizedReserve() >= ledger.totalWusdLiability();
    }

    function domainSeparatorV4() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function _tokenToWusd(uint256 tokenAmount, uint8 decimals, uint16 rateBps) internal pure returns (uint256) {
        uint256 normalized;
        if (decimals == WUSD_DECIMALS) normalized = tokenAmount;
        else if (decimals > WUSD_DECIMALS) normalized = tokenAmount / (10 ** (decimals - WUSD_DECIMALS));
        else normalized = tokenAmount * (10 ** (WUSD_DECIMALS - decimals));
        return Math.mulDiv(normalized, rateBps, BPS);
    }

    function _wusdToToken(uint256 wusdAmount, uint8 decimals, uint16 rateBps) internal pure returns (uint256) {
        uint256 normalized = Math.mulDiv(wusdAmount, BPS, rateBps);
        if (decimals == WUSD_DECIMALS) return normalized;
        if (decimals > WUSD_DECIMALS) return normalized * (10 ** (decimals - WUSD_DECIMALS));
        return normalized / (10 ** (WUSD_DECIMALS - decimals));
    }

    function _consumeWindow(DailyWindow storage window, uint256 amount, uint128 limit, bool isDeposit) private {
        if (limit == 0) return;
        if (amount > type(uint192).max) revert AmountOverflow();

        if (block.timestamp >= uint256(window.windowStart) + DAILY_WINDOW) {
            if (amount > limit) {
                if (isDeposit) revert ExceedsDailyDepositLimit();
                revert ExceedsDailyWithdrawLimit();
            }
            window.windowStart = uint64(block.timestamp);
            window.accumulated = uint192(amount);
            return;
        }

        uint256 accumulated = uint256(window.accumulated) + amount;
        if (accumulated > limit) {
            if (isDeposit) revert ExceedsDailyDepositLimit();
            revert ExceedsDailyWithdrawLimit();
        }
        window.accumulated = uint192(accumulated);
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}
}
