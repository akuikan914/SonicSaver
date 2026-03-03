// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title SonicSaver
/// @notice High-velocity DeFi savings protocol: lock ETH into time-bound pods for yield; rewards accrue by block and are claimable at unlock. Pulse collector receives protocol fees; guardian can pause in emergencies.
/// @dev Pods are created by guardian with lock duration, APR (bps), and capacity cap. Users deposit ETH (minus fee) and receive principal plus reward at unlock.

contract SonicSaver {

    // =========================================================================
    // EVENTS — emitted on state changes for indexing and off-chain analytics
    // =========================================================================

    event PodRegistered(uint256 indexed podId, uint256 lockSeconds, uint256 rateBps, uint256 capWei);
    event DepositPlaced(address indexed user, uint256 indexed podId, uint256 amountWei, uint256 unlockAt);
    event WithdrawalExecuted(address indexed user, uint256 indexed podId, uint256 principalWei, uint256 rewardWei);
    event RewardClaimed(address indexed user, uint256 indexed podId, uint256 amountWei);
    event FeeHarvested(address indexed collector, uint256 amountWei);
    event GuardianSet(address indexed previousGuardian, address indexed newGuardian);
    event ProtocolPaused(uint256 atBlock);
    event ProtocolUnpaused(uint256 atBlock);
    event PodCapUpdated(uint256 indexed podId, uint256 previousCap, uint256 newCapWei);
    event RateUpdated(uint256 indexed podId, uint256 previousRateBps, uint256 newRateBps);
    event EmergencySweep(address indexed tokenOrZero, uint256 amountWei);

    // -------------------------------------------------------------------------
    // ERRORS
    // -------------------------------------------------------------------------

    error SSV_NotGuardian();
    error SSV_ZeroAddress();
    error SSV_ZeroAmount();
    error SSV_PodNotFound();
    error SSV_LockActive();
    error SSV_LockExpired();
    error SSV_TransferFailed();
    error SSV_Reentrancy();
    error SSV_ProtocolPaused();
    error SSV_PodCapExceeded();
    error SSV_InvalidRateBps();
    error SSV_InvalidLockSeconds();
    error SSV_InvalidCapWei();
    error SSV_InsufficientBalance();
    error SSV_NothingToClaim();
    error SSV_ArrayLengthMismatch();

    // -------------------------------------------------------------------------
    // CONSTANTS
    // -------------------------------------------------------------------------

    uint256 public constant BPS_DENOM = 10_000;
    uint256 public constant MAX_FEE_BPS = 500;
    uint256 public constant MIN_LOCK_SECONDS = 7 days;
    uint256 public constant MAX_LOCK_SECONDS = 730 days;
    uint256 public constant MIN_POD_CAP_WEI = 0.01 ether;
    uint256 public constant MAX_RATE_BPS = 2000;
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    // -------------------------------------------------------------------------
    // IMMUTABLES
    // -------------------------------------------------------------------------

    address public immutable pulseCollector;
    address public immutable deployer;

    // -------------------------------------------------------------------------
    // STATE
    // -------------------------------------------------------------------------

    address public guardian;
    bool public protocolPaused;
    uint256 public feeBps;
    uint256 public nextPodId;
    uint256 private _reentrancyLock;

    struct PodConfig {
        uint256 lockSeconds;
        uint256 rateBps;
        uint256 capWei;
        uint256 totalDeposited;
