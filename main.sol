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
        if (d.principalWei == 0 || atTimestamp <= d.unlockAt) return 0;
        uint256 elapsed = atTimestamp - d.unlockAt;
        uint256 fullReward = (d.principalWei * d.rateBpsAtDeposit * elapsed) / (BPS_DENOM * SECONDS_PER_YEAR);
        if (fullReward <= d.accruedRewardAtLock) return 0;
        return fullReward - d.accruedRewardAtLock;
    }

    function getUserTotalPrincipalInPod(uint256 podId, address user) external view returns (uint256) {
        UserDeposit[] storage list = userDeposits[podId][user];
        uint256 sum = 0;
        for (uint256 i = 0; i < list.length; i++) {
            sum += list[i].principalWei;
        }
        return sum;
    }

    function getUserTotalClaimableRewardInPod(uint256 podId, address user) external view returns (uint256) {
        UserDeposit[] storage list = userDeposits[podId][user];
        uint256 sum = 0;
        for (uint256 i = 0; i < list.length; i++) {
            sum += _computeReward(list[i]);
        }
        return sum;
    }

    function getUserDepositsBatch(uint256 podId, address user, uint256 fromIndex, uint256 count) external view returns (
        uint256[] memory principalWeiArr,
        uint256[] memory unlockAtArr,
        uint256[] memory accruedRewardAtLockArr,
        uint256[] memory rateBpsArr
    ) {
        UserDeposit[] storage list = userDeposits[podId][user];
        uint256 len = list.length;
        if (fromIndex >= len) {
            principalWeiArr = new uint256[](0);
            unlockAtArr = new uint256[](0);
            accruedRewardAtLockArr = new uint256[](0);
            rateBpsArr = new uint256[](0);
            return (principalWeiArr, unlockAtArr, accruedRewardAtLockArr, rateBpsArr);
        }
        uint256 toIndex = fromIndex + count;
        if (toIndex > len) toIndex = len;
        uint256 size = toIndex - fromIndex;
        principalWeiArr = new uint256[](size);
        unlockAtArr = new uint256[](size);
        accruedRewardAtLockArr = new uint256[](size);
        rateBpsArr = new uint256[](size);
        for (uint256 i = 0; i < size; i++) {
            UserDeposit storage d = list[fromIndex + i];
            principalWeiArr[i] = d.principalWei;
            unlockAtArr[i] = d.unlockAt;
            accruedRewardAtLockArr[i] = d.accruedRewardAtLock;
            rateBpsArr[i] = d.rateBpsAtDeposit;
        }
        return (principalWeiArr, unlockAtArr, accruedRewardAtLockArr, rateBpsArr);
    }

    function getPodsBatch(uint256 fromId, uint256 count) external view returns (
        uint256[] memory ids,
        uint256[] memory lockSecondsArr,
        uint256[] memory rateBpsArr,
        uint256[] memory capWeiArr,
        uint256[] memory totalDepositedArr,
        bool[] memory activeArr
    ) {
        uint256 maxId = nextPodId == 0 ? 0 : nextPodId - 1;
        if (fromId < 1) fromId = 1;
        if (fromId > maxId) {
            ids = new uint256[](0);
            lockSecondsArr = new uint256[](0);
            rateBpsArr = new uint256[](0);
            capWeiArr = new uint256[](0);
            totalDepositedArr = new uint256[](0);
            activeArr = new bool[](0);
            return (ids, lockSecondsArr, rateBpsArr, capWeiArr, totalDepositedArr, activeArr);
        }
        uint256 toId = fromId + count;
        if (toId > maxId + 1) toId = maxId + 1;
        uint256 size = toId - fromId;
        ids = new uint256[](size);
        lockSecondsArr = new uint256[](size);
        rateBpsArr = new uint256[](size);
        capWeiArr = new uint256[](size);
        totalDepositedArr = new uint256[](size);
        activeArr = new bool[](size);
        for (uint256 i = 0; i < size; i++) {
            uint256 id = fromId + i;
            PodConfig storage p = podConfig[id];
            ids[i] = id;
            lockSecondsArr[i] = p.lockSeconds;
            rateBpsArr[i] = p.rateBps;
            capWeiArr[i] = p.capWei;
            totalDepositedArr[i] = p.totalDeposited;
            activeArr[i] = p.active;
        }
        return (ids, lockSecondsArr, rateBpsArr, capWeiArr, totalDepositedArr, activeArr);
    }

    function getEffectiveAprBps(uint256 podId) external view returns (uint256) {
        PodConfig storage p = podConfig[podId];
        if (!p.active) return 0;
        return p.rateBps;
    }

    function getRemainingLockSeconds(uint256 podId, address user, uint256 depositIndex) external view returns (uint256) {
        UserDeposit[] storage list = userDeposits[podId][user];
        if (depositIndex >= list.length) return type(uint256).max;
        UserDeposit storage d = list[depositIndex];
        if (d.principalWei == 0) return type(uint256).max;
        if (block.timestamp >= d.unlockAt) return 0;
        return d.unlockAt - block.timestamp;
    }

    /// @notice Returns lock end timestamp for a deposit.
    function getUnlockTimestamp(uint256 podId, address user, uint256 depositIndex) external view returns (uint256) {
        UserDeposit[] storage list = userDeposits[podId][user];
        if (depositIndex >= list.length) return 0;
        return list[depositIndex].unlockAt;
    }

    /// @notice Returns principal for a deposit (zero if already withdrawn).
    function getDepositPrincipal(uint256 podId, address user, uint256 depositIndex) external view returns (uint256) {
        UserDeposit[] storage list = userDeposits[podId][user];
        if (depositIndex >= list.length) return 0;
        return list[depositIndex].principalWei;
    }

    /// @notice Returns rate in bps at time of deposit.
    function getDepositRateBps(uint256 podId, address user, uint256 depositIndex) external view returns (uint256) {
        UserDeposit[] storage list = userDeposits[podId][user];
        if (depositIndex >= list.length) return 0;
        return list[depositIndex].rateBpsAtDeposit;
    }

    /// @notice Sum of all principals across all pods for a user (expensive).
    function getUserGlobalPrincipal(address user) external view returns (uint256) {
        uint256 sum = 0;
        for (uint256 id = 1; id < nextPodId; id++) {
            UserDeposit[] storage list = userDeposits[id][user];
            for (uint256 i = 0; i < list.length; i++) {
                sum += list[i].principalWei;
            }
        }
        return sum;
    }

    /// @notice Sum of all claimable rewards across all pods for a user (expensive).
    function getUserGlobalClaimableReward(address user) external view returns (uint256) {
        uint256 sum = 0;
        for (uint256 id = 1; id < nextPodId; id++) {
            UserDeposit[] storage list = userDeposits[id][user];
            for (uint256 i = 0; i < list.length; i++) {
                sum += _computeReward(list[i]);
            }
        }
        return sum;
    }

    /// @notice Pod lock duration in seconds.
    function getPodLockSeconds(uint256 podId) external view returns (uint256) {
        return podConfig[podId].lockSeconds;
    }

    /// @notice Pod current rate in bps.
    function getPodRateBps(uint256 podId) external view returns (uint256) {
        return podConfig[podId].rateBps;
    }

    /// @notice Pod capacity cap in wei.
    function getPodCapWei(uint256 podId) external view returns (uint256) {
        return podConfig[podId].capWei;
    }

    /// @notice Pod total deposited so far.
    function getPodTotalDeposited(uint256 podId) external view returns (uint256) {
        return podConfig[podId].totalDeposited;
    }

    /// @notice Block at which pod was created.
    function getPodCreatedBlock(uint256 podId) external view returns (uint256) {
        return podCreatedAtBlock[podId];
    }

    /// @notice Name hash for pod (optional metadata).
    function getPodNameHash(uint256 podId) external view returns (bytes32) {
        return podNameHash[podId];
    }

    /// @notice Whether protocol is paused.
    function isPaused() external view returns (bool) {
        return protocolPaused;
    }

    /// @notice Max deposit allowed into a pod given current cap.
    function getMaxDepositAllowed(uint256 podId) external view returns (uint256) {
        PodConfig storage p = podConfig[podId];
        if (!p.active) return 0;
        if (p.totalDeposited >= p.capWei) return 0;
        return p.capWei - p.totalDeposited;
    }

    /// @notice Fee in wei for a given deposit amount.
    function computeFeeWei(uint256 amountWei) external view returns (uint256) {
        return (amountWei * feeBps) / BPS_DENOM;
    }

    /// @notice Net amount user gets after fee for a given deposit.
    function computeNetWei(uint256 amountWei) external view returns (uint256) {
        return amountWei - (amountWei * feeBps) / BPS_DENOM;
    }

    function getCapacityRemaining(uint256 podId) external view returns (uint256) {
        PodConfig storage p = podConfig[podId];
        if (!p.active || p.totalDeposited >= p.capWei) return 0;
        return p.capWei - p.totalDeposited;
    }

    // -------------------------------------------------------------------------
    // VIEW: REWARD PROJECTION HELPERS
    // -------------------------------------------------------------------------

    /// @notice Projected reward for a principal after a given lock duration at a rate.
    function projectRewardForPrincipal(uint256 principalWei, uint256 rateBps, uint256 lockSeconds) external pure returns (uint256 rewardWei) {
        return (principalWei * rateBps * lockSeconds) / (BPS_DENOM * SECONDS_PER_YEAR);
    }

    /// @notice Effective annual rate in basis points for a pod.
    function getPodAprBps(uint256 podId) external view returns (uint256) {
        return podConfig[podId].rateBps;
    }

    /// @notice Whether a specific user deposit is unlocked.
    function isDepositUnlocked(uint256 podId, address user, uint256 depositIndex) external view returns (bool) {
        UserDeposit[] storage list = userDeposits[podId][user];
        if (depositIndex >= list.length) return false;
        return block.timestamp >= list[depositIndex].unlockAt && list[depositIndex].principalWei > 0;
    }

    /// @notice Count of deposits that are unlocked for a user in a pod.
    function getUnlockedDepositCount(uint256 podId, address user) external view returns (uint256) {
        UserDeposit[] storage list = userDeposits[podId][user];
        uint256 c = 0;
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i].principalWei > 0 && block.timestamp >= list[i].unlockAt) c++;
        }
        return c;
    }

    /// @notice Indices of unlocked deposits for a user in a pod (bounded by maxReturn).
    function getUnlockedDepositIndices(uint256 podId, address user, uint256 maxReturn) external view returns (uint256[] memory) {
        UserDeposit[] storage list = userDeposits[podId][user];
        uint256[] memory tmp = new uint256[](list.length);
        uint256 c = 0;
        for (uint256 i = 0; i < list.length && c < maxReturn; i++) {
            if (list[i].principalWei > 0 && block.timestamp >= list[i].unlockAt) {
                tmp[c] = i;
                c++;
            }
        }
        uint256[] memory out = new uint256[](c);
        for (uint256 i = 0; i < c; i++) out[i] = tmp[i];
        return out;
    }

    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function getExcessBalance() external view returns (uint256) {
        uint256 bal = address(this).balance;
        uint256 res = _totalReservedWei();
        if (bal <= res) return 0;
        return bal - res;
    }

    function getFeeForAmount(uint256 amountWei) external view returns (uint256) {
        return (amountWei * feeBps) / BPS_DENOM;
    }

    function getNetDepositForAmount(uint256 amountWei) external view returns (uint256) {
        return amountWei - (amountWei * feeBps) / BPS_DENOM;
    }

    function getPodCount() external view returns (uint256) {
        return nextPodId == 0 ? 0 : nextPodId - 1;
    }

    function isPodActive(uint256 podId) external view returns (bool) {
        return podId >= 1 && podId < nextPodId && podConfig[podId].active;
    }

    function getGuardianAddress() external view returns (address) {
        return guardian;
    }

    function getPulseCollectorAddress() external view returns (address) {
        return pulseCollector;
    }

    function getDeployerAddress() external view returns (address) {
        return deployer;
    }

    function getCurrentFeeBps() external view returns (uint256) {
        return feeBps;
    }

    function getNextPodId() external view returns (uint256) {
        return nextPodId;
    }

    // -------------------------------------------------------------------------
    // INTERNAL VIEW HELPERS (exposed via wrapper for off-chain)
    // -------------------------------------------------------------------------

    function computeRewardForDepositView(uint256 principalWei, uint256 unlockAt, uint256 accruedRewardAtLock, uint256 rateBpsAtDeposit) external view returns (uint256) {
        if (principalWei == 0 || block.timestamp <= unlockAt) return 0;
        uint256 elapsed = block.timestamp - unlockAt;
        uint256 fullReward = (principalWei * rateBpsAtDeposit * elapsed) / (BPS_DENOM * SECONDS_PER_YEAR);
        if (fullReward <= accruedRewardAtLock) return 0;
        return fullReward - accruedRewardAtLock;
    }

    // -------------------------------------------------------------------------
    // CONSTANT GETTERS (for ABI / off-chain)
    // -------------------------------------------------------------------------

    function getBpsDenom() external pure returns (uint256) { return BPS_DENOM; }
    function getMaxFeeBps() external pure returns (uint256) { return MAX_FEE_BPS; }
    function getMinLockSeconds() external pure returns (uint256) { return MIN_LOCK_SECONDS; }
    function getMaxLockSeconds() external pure returns (uint256) { return MAX_LOCK_SECONDS; }
    function getMinPodCapWei() external pure returns (uint256) { return MIN_POD_CAP_WEI; }
    function getMaxRateBps() external pure returns (uint256) { return MAX_RATE_BPS; }
    function getSecondsPerYear() external pure returns (uint256) { return SECONDS_PER_YEAR; }

    // -------------------------------------------------------------------------
    // SIMULATION: REWARD AT FUTURE TIMESTAMP
    // -------------------------------------------------------------------------

    /// @param atTimestamp Future or past timestamp; reward is computed from unlock to atTimestamp.
    function simulateRewardAtTime(uint256 podId, address user, uint256 depositIndex, uint256 atTimestamp) external view returns (uint256) {
        UserDeposit[] storage list = userDeposits[podId][user];
        if (depositIndex >= list.length) return 0;
        UserDeposit storage d = list[depositIndex];
        if (d.principalWei == 0 || atTimestamp <= d.unlockAt) return 0;
        uint256 elapsed = atTimestamp - d.unlockAt;
        uint256 fullReward = (d.principalWei * d.rateBpsAtDeposit * elapsed) / (BPS_DENOM * SECONDS_PER_YEAR);
        if (fullReward <= d.accruedRewardAtLock) return 0;
        return fullReward - d.accruedRewardAtLock;
    }

    /// @notice Projected total (principal + reward) at a future timestamp for one deposit.
    function simulateTotalAtTime(uint256 podId, address user, uint256 depositIndex, uint256 atTimestamp) external view returns (uint256 principal, uint256 reward) {
        UserDeposit[] storage list = userDeposits[podId][user];
        if (depositIndex >= list.length) return (0, 0);
        UserDeposit storage d = list[depositIndex];
        principal = d.principalWei;
        if (principal == 0) return (0, 0);
        if (atTimestamp <= d.unlockAt) return (principal, 0);
        uint256 elapsed = atTimestamp - d.unlockAt;
        uint256 fullReward = (principal * d.rateBpsAtDeposit * elapsed) / (BPS_DENOM * SECONDS_PER_YEAR);
        if (fullReward <= d.accruedRewardAtLock) reward = 0;
        else reward = fullReward - d.accruedRewardAtLock;
        return (principal, reward);
    }

    // -------------------------------------------------------------------------
    // USER SUMMARY HELPERS
    // -------------------------------------------------------------------------

    function getDepositSummaryForUser(uint256 podId, address user) external view returns (uint256 totalPrincipal, uint256 totalClaimableReward, uint256 depositCount) {
        UserDeposit[] storage list = userDeposits[podId][user];
        depositCount = list.length;
        for (uint256 i = 0; i < list.length; i++) {
            totalPrincipal += list[i].principalWei;
            totalClaimableReward += _computeReward(list[i]);
        }
        return (totalPrincipal, totalClaimableReward, depositCount);
    }

    function getPodSummary(uint256 podId) external view returns (
        uint256 lockSeconds,
        uint256 rateBps,
        uint256 capWei,
        uint256 totalDeposited,
        uint256 capacityRemaining,
        bool active
    ) {
        PodConfig storage p = podConfig[podId];
        lockSeconds = p.lockSeconds;
        rateBps = p.rateBps;
        capWei = p.capWei;
        totalDeposited = p.totalDeposited;
        active = p.active;
        capacityRemaining = (p.active && p.totalDeposited < p.capWei) ? (p.capWei - p.totalDeposited) : 0;
        return (lockSeconds, rateBps, capWei, totalDeposited, capacityRemaining, active);
    }

    function getRewardsForAllDepositsInPod(uint256 podId, address user) external view returns (uint256[] memory rewards) {
        UserDeposit[] storage list = userDeposits[podId][user];
        rewards = new uint256[](list.length);
        for (uint256 i = 0; i < list.length; i++) {
            rewards[i] = _computeReward(list[i]);
        }
        return rewards;
    }

    function getPrincipalsForAllDepositsInPod(uint256 podId, address user) external view returns (uint256[] memory principals) {
        UserDeposit[] storage list = userDeposits[podId][user];
        principals = new uint256[](list.length);
        for (uint256 i = 0; i < list.length; i++) {
            principals[i] = list[i].principalWei;
        }
        return principals;
    }

    function getUnlockTimesForAllDepositsInPod(uint256 podId, address user) external view returns (uint256[] memory unlockAts) {
        UserDeposit[] storage list = userDeposits[podId][user];
        unlockAts = new uint256[](list.length);
        for (uint256 i = 0; i < list.length; i++) {
            unlockAts[i] = list[i].unlockAt;
        }
        return unlockAts;
    }

    function getRatesForAllDepositsInPod(uint256 podId, address user) external view returns (uint256[] memory rateBpsArr) {
        UserDeposit[] storage list = userDeposits[podId][user];
        rateBpsArr = new uint256[](list.length);
        for (uint256 i = 0; i < list.length; i++) {
            rateBpsArr[i] = list[i].rateBpsAtDeposit;
        }
        return rateBpsArr;
    }

    /*
     * PROTOCOL BEHAVIOUR:
     * - Guardian registers pods with lock duration (MIN_LOCK_SECONDS to MAX_LOCK_SECONDS), APR in bps (up to MAX_RATE_BPS), and capacity cap.
     * - Users send ETH to deposit(podId, amountWei). A fee (feeBps) is sent to pulseCollector; the rest is recorded as principal and unlocks after lockSeconds.
     * - After unlock, users may withdraw(podId, depositIndex) to receive principal + reward, or claimReward only. Reward = principal * rateBps * elapsed / (BPS_DENOM * SECONDS_PER_YEAR) after unlock.
     * - Guardian can pause/unpause, set fee, update pod cap/rate, deactivate pod, and emergency sweep excess ETH (not reserved for user principal).
     * - Reentrancy guard and pull-over-push pattern protect against reentrancy. Reserved wei is always at least sum of all pod totalDeposited.
     */
    /*
     * SECURITY:
     * - Only guardian can register/update pods, set fee, pause, sweep. pulseCollector and deployer are immutable.
     * - Withdrawals and reward claims send ETH to msg.sender only. No arbitrary callbacks.
     * - emergencySweepEth only allows sweeping balance above _totalReservedWei(), so user funds are never swept.
     */
    /*
     * INTEGRATION:
     * - Use getProtocolStats() for dashboard totals; getPodInfo(podId) / getPodSummary(podId) for pod details.
     * - Use getUserDepositCount, getUserDeposit, getRewardForDeposit, getUnlockedDepositIndices for user positions.
     * - Use getMaxDepositAllowed(podId) before deposit to avoid SSV_PodCapExceeded.
     */

    /// @notice Full snapshot of user state in one pod: principals, unlock times, claimable rewards, rates.
    function getFullUserSnapshotInPod(uint256 podId, address user) external view returns (
        uint256[] memory principals,
        uint256[] memory unlockAts,
        uint256[] memory claimableRewards,
        uint256[] memory rateBpsAtDeposit
    ) {
        UserDeposit[] storage list = userDeposits[podId][user];
        uint256 n = list.length;
        principals = new uint256[](n);
        unlockAts = new uint256[](n);
        claimableRewards = new uint256[](n);
        rateBpsAtDeposit = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            principals[i] = list[i].principalWei;
            unlockAts[i] = list[i].unlockAt;
            claimableRewards[i] = _computeReward(list[i]);
            rateBpsAtDeposit[i] = list[i].rateBpsAtDeposit;
        }
        return (principals, unlockAts, claimableRewards, rateBpsAtDeposit);
    }

    /// @notice All pod ids that have at least one active config (1 to nextPodId-1 inclusive).
    function getAllPodIds() external view returns (uint256[] memory ids) {
        uint256 maxId = nextPodId == 0 ? 0 : nextPodId - 1;
        ids = new uint256[](maxId);
        for (uint256 i = 0; i < maxId; i++) {
            ids[i] = i + 1;
        }
        return ids;
    }

    /// @notice Pod ids that are active and have capacity remaining.
    function getAvailablePodIds() external view returns (uint256[] memory ids) {
        uint256 maxId = nextPodId == 0 ? 0 : nextPodId - 1;
        uint256[] memory tmp = new uint256[](maxId);
        uint256 c = 0;
        for (uint256 id = 1; id <= maxId; id++) {
            PodConfig storage p = podConfig[id];
            if (p.active && p.totalDeposited < p.capWei) {
                tmp[c] = id;
                c++;
            }
        }
        ids = new uint256[](c);
        for (uint256 i = 0; i < c; i++) ids[i] = tmp[i];
        return ids;
    }

    function getTotalPrincipalDepositedGlobal() external view returns (uint256) {
        return totalPrincipalDepositedWei;
    }

    function getTotalPrincipalWithdrawnGlobal() external view returns (uint256) {
        return totalPrincipalWithdrawnWei;
    }

    function getTotalFeesHarvestedGlobal() external view returns (uint256) {
        return totalFeesHarvestedWei;
    }

    function getTotalRewardPaidGlobal() external view returns (uint256) {
        return totalRewardPaidWei;
    }

    /// @notice Validates that a deposit would succeed without reverting (excluding balance).
    function validateDepositParams(uint256 podId, uint256 amountWei) external view returns (bool valid, string memory err) {
        if (amountWei == 0) return (false, "Zero amount");
        PodConfig storage p = podConfig[podId];
        if (!p.active || p.lockSeconds == 0) return (false, "Pod not found or inactive");
        if (p.rateBps > MAX_RATE_BPS) return (false, "Invalid pod rate");
        if (p.totalDeposited + amountWei > p.capWei) return (false, "Pod cap exceeded");
        if (protocolPaused) return (false, "Protocol paused");
        return (true, "");
    }

    // -------------------------------------------------------------------------
    // EXTENDED VIEWS: POD COMPARISONS AND FILTERS
    // -------------------------------------------------------------------------

    function getPodsWithLockBetween(uint256 minLockSeconds, uint256 maxLockSeconds) external view returns (uint256[] memory ids) {
        uint256 maxId = nextPodId == 0 ? 0 : nextPodId - 1;
        uint256[] memory tmp = new uint256[](maxId);
        uint256 c = 0;
        for (uint256 id = 1; id <= maxId; id++) {
            PodConfig storage p = podConfig[id];
            if (p.active && p.lockSeconds >= minLockSeconds && p.lockSeconds <= maxLockSeconds) {
                tmp[c] = id;
                c++;
            }
        }
        ids = new uint256[](c);
        for (uint256 i = 0; i < c; i++) ids[i] = tmp[i];
        return ids;
    }

    function getPodsWithRateBetween(uint256 minRateBps, uint256 maxRateBps) external view returns (uint256[] memory ids) {
        uint256 maxId = nextPodId == 0 ? 0 : nextPodId - 1;
        uint256[] memory tmp = new uint256[](maxId);
        uint256 c = 0;
        for (uint256 id = 1; id <= maxId; id++) {
            PodConfig storage p = podConfig[id];
            if (p.active && p.rateBps >= minRateBps && p.rateBps <= maxRateBps) {
                tmp[c] = id;
                c++;
            }
        }
        ids = new uint256[](c);
        for (uint256 i = 0; i < c; i++) ids[i] = tmp[i];
        return ids;
    }

    function getPodWithHighestRate() external view returns (uint256 podId, uint256 rateBps) {
        uint256 maxId = nextPodId == 0 ? 0 : nextPodId - 1;
        for (uint256 id = 1; id <= maxId; id++) {
            PodConfig storage p = podConfig[id];
            if (p.active && p.rateBps > rateBps) {
                rateBps = p.rateBps;
                podId = id;
            }
        }
        return (podId, rateBps);
    }

    function getPodWithLongestLock() external view returns (uint256 podId, uint256 lockSeconds) {
        uint256 maxId = nextPodId == 0 ? 0 : nextPodId - 1;
        for (uint256 id = 1; id <= maxId; id++) {
            PodConfig storage p = podConfig[id];
            if (p.active && p.lockSeconds > lockSeconds) {
                lockSeconds = p.lockSeconds;
                podId = id;
            }
        }
        return (podId, lockSeconds);
    }

    function getPodWithMostCapacityRemaining() external view returns (uint256 podId, uint256 capacityWei) {
        uint256 maxId = nextPodId == 0 ? 0 : nextPodId - 1;
        for (uint256 id = 1; id <= maxId; id++) {
            PodConfig storage p = podConfig[id];
            if (!p.active) continue;
            uint256 rem = p.capWei > p.totalDeposited ? p.capWei - p.totalDeposited : 0;
            if (rem > capacityWei) {
                capacityWei = rem;
                podId = id;
            }
        }
        return (podId, capacityWei);
    }

    function getDepositIndicesUnlocked(uint256 podId, address user) external view returns (uint256[] memory indices) {
        UserDeposit[] storage list = userDeposits[podId][user];
        uint256[] memory tmp = new uint256[](list.length);
        uint256 c = 0;
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i].principalWei > 0 && block.timestamp >= list[i].unlockAt) {
                tmp[c] = i;
                c++;
            }
        }
        indices = new uint256[](c);
        for (uint256 i = 0; i < c; i++) indices[i] = tmp[i];
        return indices;
    }

    function getDepositIndicesLocked(uint256 podId, address user) external view returns (uint256[] memory indices) {
        UserDeposit[] storage list = userDeposits[podId][user];
        uint256[] memory tmp = new uint256[](list.length);
        uint256 c = 0;
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i].principalWei > 0 && block.timestamp < list[i].unlockAt) {
                tmp[c] = i;
                c++;
            }
        }
        indices = new uint256[](c);
        for (uint256 i = 0; i < c; i++) indices[i] = tmp[i];
        return indices;
    }

    function getTotalRewardAccruedSoFar(uint256 podId, address user, uint256 depositIndex) external view returns (uint256) {
        return _computeReward(userDeposits[podId][user][depositIndex]);
    }

    function estimateRewardAtUnlock(uint256 podId, address user, uint256 depositIndex) external view returns (uint256) {
        UserDeposit[] storage list = userDeposits[podId][user];
        if (depositIndex >= list.length) return 0;
        UserDeposit storage d = list[depositIndex];
        if (d.principalWei == 0) return 0;
        if (block.timestamp >= d.unlockAt) return _computeReward(d);
        uint256 lockSeconds = d.unlockAt - block.timestamp;
        return (d.principalWei * d.rateBpsAtDeposit * lockSeconds) / (BPS_DENOM * SECONDS_PER_YEAR);
    }

    function getAccruedRewardAtLockForDeposit(uint256 podId, address user, uint256 depositIndex) external view returns (uint256) {
        UserDeposit[] storage list = userDeposits[podId][user];
        if (depositIndex >= list.length) return 0;
        return list[depositIndex].accruedRewardAtLock;
    }

    function getPodExists(uint256 podId) external view returns (bool) {
        return podId >= 1 && podId < nextPodId;
    }

    function hasAnyDepositInPod(uint256 podId, address user) external view returns (bool) {
        return userDeposits[podId][user].length > 0;
    }

    function hasActiveDepositInPod(uint256 podId, address user) external view returns (bool) {
        UserDeposit[] storage list = userDeposits[podId][user];
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i].principalWei > 0) return true;
        }
        return false;
    }

    function getFirstUnlockedDepositIndex(uint256 podId, address user) external view returns (uint256 index, bool found) {
        UserDeposit[] storage list = userDeposits[podId][user];
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i].principalWei > 0 && block.timestamp >= list[i].unlockAt) {
                return (i, true);
            }
        }
        return (0, false);
    }

    function getWithdrawableAmount(uint256 podId, address user, uint256 depositIndex) external view returns (uint256 principal, uint256 reward) {
        UserDeposit[] storage list = userDeposits[podId][user];
        if (depositIndex >= list.length) return (0, 0);
        UserDeposit storage d = list[depositIndex];
        principal = d.principalWei;
        if (principal == 0) return (0, 0);
        if (block.timestamp < d.unlockAt) return (0, 0);
        reward = _computeReward(d);
        return (principal, reward);
    }

    function getTotalWithdrawableForUserInPod(uint256 podId, address user) external view returns (uint256 totalPrincipal, uint256 totalReward) {
        UserDeposit[] storage list = userDeposits[podId][user];
        for (uint256 i = 0; i < list.length; i++) {
            UserDeposit storage d = list[i];
            if (d.principalWei == 0) continue;
            if (block.timestamp < d.unlockAt) continue;
            totalPrincipal += d.principalWei;
            totalReward += _computeReward(d);
        }
        return (totalPrincipal, totalReward);
    }

    // -------------------------------------------------------------------------
    // QUOTE AND SIMULATION HELPERS (no state change)
    // -------------------------------------------------------------------------

    /// @notice Quote: fee and net amount for a given deposit amount.
    function quoteDeposit(uint256 amountWei) external view returns (uint256 feeWei, uint256 netWei) {
        feeWei = (amountWei * feeBps) / BPS_DENOM;
        netWei = amountWei - feeWei;
        return (feeWei, netWei);
    }

    /// @notice Quote: total reward for a principal locked for lockSeconds at rateBps (pure).
    function quoteReward(uint256 principalWei, uint256 rateBps, uint256 lockSeconds) external pure returns (uint256 rewardWei) {
        return (principalWei * rateBps * lockSeconds) / (BPS_DENOM * SECONDS_PER_YEAR);
    }

    /// @notice Quote: unlock timestamp if user deposits now in podId.
    function quoteUnlockTime(uint256 podId) external view returns (uint256 unlockAt) {
        PodConfig storage p = podConfig[podId];
        if (!p.active) return 0;
        return block.timestamp + p.lockSeconds;
    }

    /// @notice Simulate: if user deposits amountWei into podId now, return (netWei, unlockAt, projectedRewardAtUnlock).
    function simulateDeposit(uint256 podId, uint256 amountWei) external view returns (uint256 netWei, uint256 unlockAt, uint256 projectedRewardWei) {
        PodConfig storage p = podConfig[podId];
        if (!p.active || amountWei == 0) return (0, 0, 0);
        netWei = amountWei - (amountWei * feeBps) / BPS_DENOM;
        unlockAt = block.timestamp + p.lockSeconds;
        projectedRewardWei = (netWei * p.rateBps * p.lockSeconds) / (BPS_DENOM * SECONDS_PER_YEAR);
        return (netWei, unlockAt, projectedRewardWei);
    }

    /// @notice Annualised percentage (bps) for a pod.
    function getPodAprBpsView(uint256 podId) external view returns (uint256) {
        return podConfig[podId].rateBps;
    }

    /// @notice Lock duration in days (rounded down) for a pod.
    function getPodLockDays(uint256 podId) external view returns (uint256) {
        return podConfig[podId].lockSeconds / 1 days;
    }

    /// @notice Whether the contract has excess balance (donations) above reserved.
    function hasExcessBalance() external view returns (bool) {
        return address(this).balance > _totalReservedWei();
    }

    /// @notice Amount of excess balance (donations) that could be swept.
    function getSweepableAmount() external view returns (uint256) {
        uint256 bal = address(this).balance;
        uint256 res = _totalReservedWei();
        if (bal <= res) return 0;
        return bal - res;
    }

    function getReservedWeiForPod(uint256 podId) external view returns (uint256) {
        return podConfig[podId].totalDeposited;
    }

    function getTotalPrincipalInProtocol() external view returns (uint256) {
        return _totalReservedWei();
    }

    /// @notice Reusable check: can user withdraw this deposit index?
    function canWithdraw(uint256 podId, address user, uint256 depositIndex) external view returns (bool) {
        UserDeposit[] storage list = userDeposits[podId][user];
        if (depositIndex >= list.length) return false;
        UserDeposit storage d = list[depositIndex];
        return d.principalWei > 0 && block.timestamp >= d.unlockAt;
    }

    /// @notice Reusable check: does user have any claimable reward in this deposit?
    function hasClaimableReward(uint256 podId, address user, uint256 depositIndex) external view returns (bool) {
        UserDeposit[] storage list = userDeposits[podId][user];
        if (depositIndex >= list.length) return false;
        return _computeReward(list[depositIndex]) > 0;
    }

    /// @notice Returns fee bps (basis points) for protocol.
    function getFeeBpsView() external view returns (uint256) {
        return feeBps;
    }

    /// @notice Returns guardian address (alias for getGuardianAddress).
    function guardianAddress() external view returns (address) {
        return guardian;
    }

    /// @notice Returns pulse collector address (alias).
    function pulseCollectorAddress() external view returns (address) {
        return pulseCollector;
    }

    /// @notice Returns deployer address (alias).
    function deployerAddress() external view returns (address) {
        return deployer;
    }

    /*
     * REWARD FORMULA:
     * reward = principalWei * rateBps * elapsedSeconds / (BPS_DENOM * SECONDS_PER_YEAR)
     * where elapsedSeconds = time since unlock (only accrues after unlock).
     * So for a 365-day lock at 500 bps (5% APY), 1 ETH yields 0.05 ETH reward over the lock period,
     * but reward only starts accruing after the lock ends. Before unlock, reward is 0.
     */

    /*
     * FEE: Taken at deposit. feeWei = amountWei * feeBps / BPS_DENOM. Sent to pulseCollector. Net principal = amountWei - feeWei.
     */

    /*
     * POD LIFECYCLE: Guardian registers pod (registerPod or registerPodWithName or registerPodsBatch).
     * Pod can be updated (setPodCap, setPodRate) or deactivated (deactivatePod). Deactivated pods
     * do not accept new deposits; existing deposits can still be withdrawn/claimed when unlocked.
     */

    /*
     * PAUSE: When protocolPaused is true, deposit() and registerPod revert. Withdraw and claimReward
     * remain allowed so users can exit. Guardian can pause/unpause.
     */

    // -------------------------------------------------------------------------
    // ADDITIONAL VIEWS FOR FRONTENDS AND BOTS
    // -------------------------------------------------------------------------

    function getConstants() external pure returns (
        uint256 bpsDenom,
        uint256 maxFeeBps,
        uint256 minLockSecs,
        uint256 maxLockSecs,
        uint256 minPodCapWei,
        uint256 maxRateBps,
        uint256 secondsPerYear
    ) {
        return (BPS_DENOM, MAX_FEE_BPS, MIN_LOCK_SECONDS, MAX_LOCK_SECONDS, MIN_POD_CAP_WEI, MAX_RATE_BPS, SECONDS_PER_YEAR);
    }

    function getState() external view returns (
        address guardian_,
        bool paused_,
        uint256 feeBps_,
        uint256 nextPodId_,
        uint256 totalFeesWei_,
        uint256 totalDepositedWei_,
        uint256 totalWithdrawnWei_,
        uint256 totalRewardPaidWei_
    ) {
        return (
            guardian,
            protocolPaused,
            feeBps,
            nextPodId,
            totalFeesHarvestedWei,
            totalPrincipalDepositedWei,
            totalPrincipalWithdrawnWei,
            totalRewardPaidWei
        );
    }

    function getImmutables() external view returns (address pulseCollector_, address deployer_) {
        return (pulseCollector, deployer);
    }

    function getPodIdsPaginated(uint256 pageSize, uint256 pageIndex) external view returns (uint256[] memory ids) {
        uint256 maxId = nextPodId == 0 ? 0 : nextPodId - 1;
        if (maxId == 0) return new uint256[](0);
        uint256 start = pageIndex * pageSize;
        if (start >= maxId) return new uint256[](0);
        uint256 end = start + pageSize;
        if (end > maxId) end = maxId;
        uint256 n = end - start;
        ids = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            ids[i] = start + i + 1;
        }
        return ids;
    }

    function getUserPositionCountAcrossAllPods(address user) external view returns (uint256 totalDeposits) {
        for (uint256 id = 1; id < nextPodId; id++) {
            totalDeposits += userDeposits[id][user].length;
        }
        return totalDeposits;
    }

    function getPodsWhereUserHasDeposits(address user) external view returns (uint256[] memory podIds) {
        uint256 maxId = nextPodId == 0 ? 0 : nextPodId - 1;
        uint256[] memory tmp = new uint256[](maxId);
        uint256 c = 0;
        for (uint256 id = 1; id <= maxId; id++) {
            if (userDeposits[id][user].length > 0) {
                tmp[c] = id;
                c++;
            }
        }
        podIds = new uint256[](c);
        for (uint256 i = 0; i < c; i++) podIds[i] = tmp[i];
        return podIds;
    }

    function getBalanceAndReserved() external view returns (uint256 balanceWei, uint256 reservedWei) {
        return (address(this).balance, _totalReservedWei());
    }

    function getDepositAt(uint256 podId, address user, uint256 index) external view returns (
        uint256 principalWei,
        uint256 unlockAt,
        uint256 accruedRewardAtLock,
        uint256 rateBpsAtDeposit,
        uint256 claimableRewardNow
    ) {
        UserDeposit[] storage list = userDeposits[podId][user];
        if (index >= list.length) return (0, 0, 0, 0, 0);
        UserDeposit storage d = list[index];
        principalWei = d.principalWei;
        unlockAt = d.unlockAt;
        accruedRewardAtLock = d.accruedRewardAtLock;
        rateBpsAtDeposit = d.rateBpsAtDeposit;
        claimableRewardNow = _computeReward(d);
        return (principalWei, unlockAt, accruedRewardAtLock, rateBpsAtDeposit, claimableRewardNow);
    }

    function getMultiplePodSummaries(uint256[] calldata podIds) external view returns (
        uint256[] memory lockSecondsArr,
        uint256[] memory rateBpsArr,
        uint256[] memory capWeiArr,
        uint256[] memory totalDepositedArr,
        bool[] memory activeArr
    ) {
        uint256 n = podIds.length;
        lockSecondsArr = new uint256[](n);
        rateBpsArr = new uint256[](n);
        capWeiArr = new uint256[](n);
        totalDepositedArr = new uint256[](n);
        activeArr = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            PodConfig storage p = podConfig[podIds[i]];
            lockSecondsArr[i] = p.lockSeconds;
            rateBpsArr[i] = p.rateBps;
            capWeiArr[i] = p.capWei;
            totalDepositedArr[i] = p.totalDeposited;
            activeArr[i] = p.active;
        }
        return (lockSecondsArr, rateBpsArr, capWeiArr, totalDepositedArr, activeArr);
    }

    function getProtocolHealth() external view returns (bool balanceOk, uint256 balanceWei, uint256 reservedWei) {
        balanceWei = address(this).balance;
        reservedWei = _totalReservedWei();
        balanceOk = balanceWei >= reservedWei;
        return (balanceOk, balanceWei, reservedWei);
    }

    function getMinDepositAfterFee(uint256 grossWei) external view returns (uint256) {
        return grossWei - (grossWei * feeBps) / BPS_DENOM;
