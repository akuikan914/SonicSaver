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
        bool active;
    }

    struct UserDeposit {
        uint256 principalWei;
        uint256 unlockAt;
        uint256 accruedRewardAtLock;
        uint256 rateBpsAtDeposit;
    }

    mapping(uint256 => PodConfig) public podConfig;
    mapping(uint256 => mapping(address => UserDeposit[])) public userDeposits;
    mapping(uint256 => mapping(address => uint256)) public userDepositCount;

    uint256 public totalFeesHarvestedWei;
    uint256 public totalPrincipalDepositedWei;
    uint256 public totalPrincipalWithdrawnWei;
    uint256 public totalRewardPaidWei;
    mapping(uint256 => uint256) public podCreatedAtBlock;
    mapping(uint256 => bytes32) public podNameHash;

    // -------------------------------------------------------------------------
    // CONSTRUCTOR
    // -------------------------------------------------------------------------

    constructor() {
        pulseCollector = 0x7E4a9c2B5d8F1e3A6b9C0d2E5f7A8b1c4D6e9F2a;
        deployer = 0x2F5b8c1D4e7A0b3C6d9E2f5a8B1c4D7e0F3a6b9C;
        guardian = 0x9A1b4C7d0E3f6a9B2c5D8e1F4a7b0C3d6E9f2A5b;
        feeBps = 75;
        nextPodId = 1;
    }

    // -------------------------------------------------------------------------
    // MODIFIERS
    // -------------------------------------------------------------------------

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert SSV_NotGuardian();
        _;
    }

    modifier whenNotPaused() {
        if (protocolPaused) revert SSV_ProtocolPaused();
        _;
    }

    modifier nonReentrant() {
        if (_reentrancyLock != 0) revert SSV_Reentrancy();
        _reentrancyLock = 1;
        _;
        _reentrancyLock = 0;
    }

    // -------------------------------------------------------------------------
    // EXTERNAL: DEPOSIT (users)
    // -------------------------------------------------------------------------

    function deposit(uint256 podId, uint256 amountWei) external payable whenNotPaused nonReentrant {
        if (msg.value != amountWei || amountWei == 0) revert SSV_ZeroAmount();
        PodConfig storage pod = podConfig[podId];
        if (!pod.active || pod.lockSeconds == 0) revert SSV_PodNotFound();
        if (pod.rateBps > MAX_RATE_BPS) revert SSV_InvalidRateBps();
        if (pod.totalDeposited + amountWei > pod.capWei) revert SSV_PodCapExceeded();

        uint256 feeWei = (amountWei * feeBps) / BPS_DENOM;
        uint256 netWei = amountWei - feeWei;
        if (feeWei > 0) {
            (bool feeOk,) = pulseCollector.call{value: feeWei}("");
            if (!feeOk) revert SSV_TransferFailed();
            totalFeesHarvestedWei += feeWei;
            emit FeeHarvested(pulseCollector, feeWei);
        }
        totalPrincipalDepositedWei += netWei;

        uint256 unlockAt = block.timestamp + pod.lockSeconds;
        UserDeposit memory dep = UserDeposit({
            principalWei: netWei,
            unlockAt: unlockAt,
            accruedRewardAtLock: 0,
            rateBpsAtDeposit: pod.rateBps
        });

        uint256 idx = userDepositCount[podId][msg.sender];
        if (idx >= userDeposits[podId][msg.sender].length) {
            userDeposits[podId][msg.sender].push(dep);
        } else {
            userDeposits[podId][msg.sender].push(dep);
        }
        userDepositCount[podId][msg.sender] = userDeposits[podId][msg.sender].length;
        pod.totalDeposited += netWei;

        emit DepositPlaced(msg.sender, podId, netWei, unlockAt);
    }

    // -------------------------------------------------------------------------
    // EXTERNAL: WITHDRAW (after lock)
    // -------------------------------------------------------------------------

    function withdraw(uint256 podId, uint256 depositIndex) external nonReentrant {
        PodConfig storage pod = podConfig[podId];
        if (!pod.active) revert SSV_PodNotFound();
        UserDeposit[] storage list = userDeposits[podId][msg.sender];
        if (depositIndex >= list.length) revert SSV_PodNotFound();

        UserDeposit storage dep = list[depositIndex];
        if (block.timestamp < dep.unlockAt) revert SSV_LockActive();

        uint256 principal = dep.principalWei;
        uint256 reward = _computeReward(dep);
        uint256 total = principal + reward;

        dep.principalWei = 0;
        dep.unlockAt = 0;
        dep.accruedRewardAtLock = 0;
        dep.rateBpsAtDeposit = 0;

        pod.totalDeposited -= principal;
        totalPrincipalWithdrawnWei += principal;
        totalRewardPaidWei += reward;

        (bool ok,) = msg.sender.call{value: total}("");
        if (!ok) revert SSV_TransferFailed();
        emit WithdrawalExecuted(msg.sender, podId, principal, reward);
    }

    // -------------------------------------------------------------------------
    // EXTERNAL: CLAIM REWARD (optional separate claim)
    // -------------------------------------------------------------------------

    function claimReward(uint256 podId, uint256 depositIndex) external nonReentrant {
        UserDeposit[] storage list = userDeposits[podId][msg.sender];
        if (depositIndex >= list.length) revert SSV_NothingToClaim();
        UserDeposit storage dep = list[depositIndex];
        if (dep.principalWei == 0) revert SSV_NothingToClaim();
        if (block.timestamp < dep.unlockAt) revert SSV_LockActive();

        uint256 reward = _computeReward(dep);
        if (reward == 0) revert SSV_NothingToClaim();
        dep.accruedRewardAtLock += reward;
        totalRewardPaidWei += reward;

        (bool ok,) = msg.sender.call{value: reward}("");
        if (!ok) revert SSV_TransferFailed();
        emit RewardClaimed(msg.sender, podId, reward);
    }

    // -------------------------------------------------------------------------
    // VIEW: REWARD FOR ONE DEPOSIT
    // -------------------------------------------------------------------------

    function _computeReward(UserDeposit storage dep) internal view returns (uint256) {
        if (dep.principalWei == 0 || block.timestamp <= dep.unlockAt) return 0;
        uint256 elapsed = block.timestamp - dep.unlockAt;
        uint256 rateBps = dep.rateBpsAtDeposit;
        uint256 accrued = dep.accruedRewardAtLock;
        uint256 fullReward = (dep.principalWei * rateBps * elapsed) / (BPS_DENOM * SECONDS_PER_YEAR);
        if (fullReward <= accrued) return 0;
        return fullReward - accrued;
    }

    function getRewardForDeposit(uint256 podId, address user, uint256 depositIndex) external view returns (uint256) {
        UserDeposit[] storage list = userDeposits[podId][user];
        if (depositIndex >= list.length) return 0;
        return _computeReward(list[depositIndex]);
    }

    // -------------------------------------------------------------------------
    // GUARDIAN: REGISTER POD
    // -------------------------------------------------------------------------

    function registerPod(uint256 lockSeconds, uint256 rateBps, uint256 capWei) external onlyGuardian whenNotPaused {
        if (lockSeconds < MIN_LOCK_SECONDS || lockSeconds > MAX_LOCK_SECONDS) revert SSV_InvalidLockSeconds();
        if (rateBps > MAX_RATE_BPS) revert SSV_InvalidRateBps();
        if (capWei < MIN_POD_CAP_WEI) revert SSV_InvalidCapWei();

        uint256 id = nextPodId++;
        podConfig[id] = PodConfig({
            lockSeconds: lockSeconds,
            rateBps: rateBps,
            capWei: capWei,
            totalDeposited: 0,
            active: true
        });
        podCreatedAtBlock[id] = block.number;
        emit PodRegistered(id, lockSeconds, rateBps, capWei);
    }

    function registerPodWithName(uint256 lockSeconds, uint256 rateBps, uint256 capWei, bytes32 nameHash) external onlyGuardian whenNotPaused {
        if (lockSeconds < MIN_LOCK_SECONDS || lockSeconds > MAX_LOCK_SECONDS) revert SSV_InvalidLockSeconds();
        if (rateBps > MAX_RATE_BPS) revert SSV_InvalidRateBps();
        if (capWei < MIN_POD_CAP_WEI) revert SSV_InvalidCapWei();
        uint256 id = nextPodId++;
        podConfig[id] = PodConfig({
            lockSeconds: lockSeconds,
            rateBps: rateBps,
            capWei: capWei,
            totalDeposited: 0,
            active: true
        });
        podCreatedAtBlock[id] = block.number;
        podNameHash[id] = nameHash;
        emit PodRegistered(id, lockSeconds, rateBps, capWei);
    }

    function registerPodsBatch(
        uint256[] calldata lockSecondsArr,
        uint256[] calldata rateBpsArr,
        uint256[] calldata capWeiArr
    ) external onlyGuardian whenNotPaused {
        uint256 n = lockSecondsArr.length;
        if (n != rateBpsArr.length || n != capWeiArr.length) revert SSV_ArrayLengthMismatch();
        for (uint256 i = 0; i < n; i++) {
            if (lockSecondsArr[i] < MIN_LOCK_SECONDS || lockSecondsArr[i] > MAX_LOCK_SECONDS) revert SSV_InvalidLockSeconds();
            if (rateBpsArr[i] > MAX_RATE_BPS) revert SSV_InvalidRateBps();
            if (capWeiArr[i] < MIN_POD_CAP_WEI) revert SSV_InvalidCapWei();
            uint256 id = nextPodId++;
            podConfig[id] = PodConfig({
                lockSeconds: lockSecondsArr[i],
                rateBps: rateBpsArr[i],
                capWei: capWeiArr[i],
                totalDeposited: 0,
                active: true
            });
            podCreatedAtBlock[id] = block.number;
            emit PodRegistered(id, lockSecondsArr[i], rateBpsArr[i], capWeiArr[i]);
        }
    }

    // -------------------------------------------------------------------------
    // GUARDIAN: UPDATE POD
    // -------------------------------------------------------------------------

    function setPodCap(uint256 podId, uint256 newCapWei) external onlyGuardian {
        PodConfig storage pod = podConfig[podId];
        if (!pod.active) revert SSV_PodNotFound();
        if (newCapWei < pod.totalDeposited || newCapWei < MIN_POD_CAP_WEI) revert SSV_InvalidCapWei();
        uint256 prev = pod.capWei;
        pod.capWei = newCapWei;
        emit PodCapUpdated(podId, prev, newCapWei);
    }

    function setPodRate(uint256 podId, uint256 newRateBps) external onlyGuardian {
        PodConfig storage pod = podConfig[podId];
        if (!pod.active) revert SSV_PodNotFound();
        if (newRateBps > MAX_RATE_BPS) revert SSV_InvalidRateBps();
        uint256 prev = pod.rateBps;
        pod.rateBps = newRateBps;
        emit RateUpdated(podId, prev, newRateBps);
    }

    function deactivatePod(uint256 podId) external onlyGuardian {
        PodConfig storage pod = podConfig[podId];
        if (!pod.active) revert SSV_PodNotFound();
        pod.active = false;
    }

    // -------------------------------------------------------------------------
    // GUARDIAN: FEE & PAUSE
    // -------------------------------------------------------------------------

    function setFeeBps(uint256 newFeeBps) external onlyGuardian {
        if (newFeeBps > MAX_FEE_BPS) revert SSV_InvalidRateBps();
        feeBps = newFeeBps;
    }

    function setGuardian(address newGuardian) external onlyGuardian {
        if (newGuardian == address(0)) revert SSV_ZeroAddress();
        address prev = guardian;
        guardian = newGuardian;
        emit GuardianSet(prev, newGuardian);
    }

    function pause() external onlyGuardian {
        if (protocolPaused) return;
        protocolPaused = true;
        emit ProtocolPaused(block.number);
    }

    function unpause() external onlyGuardian {
        if (!protocolPaused) return;
        protocolPaused = false;
        emit ProtocolUnpaused(block.number);
    }

    // -------------------------------------------------------------------------
    // GUARDIAN: EMERGENCY SWEEP (stuck ETH only; no user funds)
    // -------------------------------------------------------------------------

    function emergencySweepEth(uint256 amountWei) external onlyGuardian nonReentrant {
        uint256 balance = address(this).balance;
        uint256 reserved = _totalReservedWei();
        if (amountWei > balance || balance - amountWei < reserved) revert SSV_InsufficientBalance();
        (bool ok,) = pulseCollector.call{value: amountWei}("");
        if (!ok) revert SSV_TransferFailed();
        emit EmergencySweep(address(0), amountWei);
    }

    function _totalReservedWei() internal view returns (uint256) {
        uint256 total = 0;
        for (uint256 id = 1; id < nextPodId; id++) {
            total += podConfig[id].totalDeposited;
        }
        return total;
    }

    // -------------------------------------------------------------------------
    // VIEW: USER DEPOSITS
    // -------------------------------------------------------------------------

    function getUserDepositCount(uint256 podId, address user) external view returns (uint256) {
        return userDeposits[podId][user].length;
    }

    function getUserDeposit(uint256 podId, address user, uint256 index) external view returns (
        uint256 principalWei,
        uint256 unlockAt,
        uint256 accruedRewardAtLock,
        uint256 rateBpsAtDeposit
    ) {
        UserDeposit[] storage list = userDeposits[podId][user];
        if (index >= list.length) return (0, 0, 0, 0);
        UserDeposit storage d = list[index];
        return (d.principalWei, d.unlockAt, d.accruedRewardAtLock, d.rateBpsAtDeposit);
    }

    function getTotalReservedWei() external view returns (uint256) {
        return _totalReservedWei();
    }

    // -------------------------------------------------------------------------
    // VIEW: PROTOCOL STATS
    // -------------------------------------------------------------------------

    function getProtocolStats() external view returns (
        uint256 totalFeesWei_,
        uint256 totalDepositedWei_,
        uint256 totalWithdrawnWei_,
        uint256 totalRewardsPaidWei_,
        uint256 reservedWei_,
        uint256 podCount_,
        bool paused_
    ) {
        return (
            totalFeesHarvestedWei,
            totalPrincipalDepositedWei,
            totalPrincipalWithdrawnWei,
            totalRewardPaidWei,
            _totalReservedWei(),
            nextPodId - 1,
            protocolPaused
        );
    }

    function getPodInfo(uint256 podId) external view returns (
        uint256 lockSeconds,
        uint256 rateBps,
        uint256 capWei,
        uint256 totalDeposited,
        bool active,
        uint256 createdAtBlock,
        bytes32 nameHash
    ) {
        PodConfig storage p = podConfig[podId];
        return (
            p.lockSeconds,
            p.rateBps,
            p.capWei,
            p.totalDeposited,
            p.active,
            podCreatedAtBlock[podId],
            podNameHash[podId]
        );
    }

    function getActivePodIds(uint256 limit, uint256 offset) external view returns (uint256[] memory ids) {
        uint256 maxId = nextPodId == 0 ? 0 : nextPodId - 1;
        if (offset >= maxId) return new uint256[](0);
        uint256 remain = maxId - offset;
        uint256 size = limit > remain ? remain : limit;
        ids = new uint256[](size);
        uint256 count = 0;
        for (uint256 id = offset + 1; id <= maxId && count < size; id++) {
            if (podConfig[id].active) {
                ids[count] = id;
                count++;
            }
        }
        if (count < size) {
            uint256[] memory trimmed = new uint256[](count);
            for (uint256 i = 0; i < count; i++) trimmed[i] = ids[i];
            return trimmed;
        }
        return ids;
    }

    function getProjectedRewardAtTimestamp(uint256 podId, address user, uint256 depositIndex, uint256 atTimestamp) external view returns (uint256) {
        UserDeposit[] storage list = userDeposits[podId][user];
        if (depositIndex >= list.length) return 0;
        UserDeposit storage d = list[depositIndex];
