// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./interfaces/IStationAdoptionCertificateNFT.sol";

/**
 * @title StationAdoptionPool
 * @notice Sponsor pool for weather station adoption in data deserts.
 *
 * Lifecycle:
 *   1. Admin creates a project (region, target amount, revenue-share %, cliff).
 *   2. Sponsors deposit WRF until the target is reached → project becomes "funded".
 *   3. Before the project is funded, sponsors may withdraw their deposit via
 *      `withdraw()`.
 *   4. Admin finalizes deployment (attaches stationId, records deployment time).
 *      Project becomes "active".
 *   5. Oracle records periodic data rewards via `recordAdoptionRewards()`.
 *   6. After the optional cliff period elapses, sponsors claim their pro-rata
 *      yield share via `claimRewards()`.
 *   7. Sponsors may claim their adoption certificate NFT once the station is live.
 */
contract StationAdoptionPool is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant POOL_ADMIN_ROLE = keccak256("POOL_ADMIN_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    IERC20 public immutable wrfToken;
    IStationAdoptionCertificateNFT public immutable certificateNFT;

    struct AdoptionProject {
        bytes32 regionId;
        string regionLabel;
        uint256 targetAmount;
        uint256 totalDeposited;
        uint256 revenueShareBps;
        uint256 cumulativeDataRewards;
        uint256 createdAt;
        uint256 deploymentTimestamp;
        /// @dev Seconds after deploymentTimestamp before yield can be claimed (0 = no cliff).
        uint256 cliffDuration;
        bytes32 stationId;
        bool funded;
        bool active;
        uint256 sponsorCount;
    }

    mapping(uint256 => AdoptionProject) private _projects;
    mapping(uint256 => mapping(address => uint256)) public sponsorDeposits;
    /// @dev Cumulative data rewards already claimed by each sponsor per project.
    mapping(uint256 => mapping(address => uint256)) public sponsorRewardsClaimed;
    mapping(uint256 => mapping(address => bool)) public certificateClaimed;
    mapping(uint256 => address[]) private _sponsors;

    uint256 public nextProjectId = 1;

    // ── Events ───────────────────────────────────────────────────────────────

    event ProjectCreated(
        uint256 indexed projectId,
        bytes32 indexed regionId,
        string regionLabel,
        uint256 targetAmount,
        uint256 revenueShareBps,
        uint256 cliffDuration
    );
    event AdoptionDeposited(
        uint256 indexed projectId,
        address indexed sponsor,
        uint256 amount,
        uint256 totalDeposited
    );
    event ProjectFunded(uint256 indexed projectId, uint256 totalDeposited);
    event DepositWithdrawn(
        uint256 indexed projectId,
        address indexed sponsor,
        uint256 amount
    );
    event StationDeploymentFinalized(
        uint256 indexed projectId,
        bytes32 indexed stationId,
        uint256 deploymentTimestamp
    );
    event AdoptionRewardsRecorded(
        uint256 indexed projectId,
        uint256 dataRewards,
        uint256 cumulativeDataRewards
    );
    event RewardsClaimed(
        uint256 indexed projectId,
        address indexed sponsor,
        uint256 amount
    );
    event CertificateClaimed(
        uint256 indexed projectId,
        address indexed sponsor,
        uint256 tokenId
    );

    // ── Custom errors ─────────────────────────────────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error ZeroRegion();
    error InvalidRevenueShare();
    error ProjectNotFound();
    error ProjectNotFunded();
    error ProjectNotActive();
    error ProjectAlreadyActive();
    error ProjectAlreadyFunded();
    error AlreadyClaimed();
    error InvalidStationId();
    error InvalidDeploymentTimestamp();
    error CliffNotReached();
    error NothingToClaim();
    error NoDeposit();

    // ── Constructor ───────────────────────────────────────────────────────────

    constructor(address wrfToken_, address certificateNFT_) {
        if (wrfToken_ == address(0) || certificateNFT_ == address(0)) {
            revert ZeroAddress();
        }

        wrfToken = IERC20(wrfToken_);
        certificateNFT = IStationAdoptionCertificateNFT(certificateNFT_);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(POOL_ADMIN_ROLE, msg.sender);
        _grantRole(ORACLE_ROLE, msg.sender);
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    /**
     * @notice Create a new station-adoption project.
     * @param regionId      Keccak256 identifier for the geographic data-desert zone.
     * @param regionLabel   Human-readable region name (stored on-chain for certificate metadata).
     * @param targetAmount  WRF amount required to fund hardware deployment.
     * @param revenueShareBps  Basis points (1–10 000) of data rewards paid to sponsors.
     * @param cliffDuration Seconds after deployment before yield can be claimed (0 = immediately).
     */
    function createProject(
        bytes32 regionId,
        string calldata regionLabel,
        uint256 targetAmount,
        uint256 revenueShareBps,
        uint256 cliffDuration
    ) external onlyRole(POOL_ADMIN_ROLE) returns (uint256 projectId) {
        if (regionId == bytes32(0)) revert ZeroRegion();
        if (targetAmount == 0) revert ZeroAmount();
        if (revenueShareBps == 0 || revenueShareBps > 10_000) revert InvalidRevenueShare();

        projectId = nextProjectId++;
        _projects[projectId] = AdoptionProject({
            regionId: regionId,
            regionLabel: regionLabel,
            targetAmount: targetAmount,
            totalDeposited: 0,
            revenueShareBps: revenueShareBps,
            cumulativeDataRewards: 0,
            createdAt: block.timestamp,
            deploymentTimestamp: 0,
            cliffDuration: cliffDuration,
            stationId: bytes32(0),
            funded: false,
            active: false,
            sponsorCount: 0
        });

        emit ProjectCreated(projectId, regionId, regionLabel, targetAmount, revenueShareBps, cliffDuration);
    }

    function finalizeDeployment(
        uint256 projectId,
        bytes32 stationId,
        uint256 deploymentTimestamp
    ) external onlyRole(POOL_ADMIN_ROLE) whenNotPaused {
        AdoptionProject storage project = _project(projectId);
        if (!project.funded) revert ProjectNotFunded();
        if (project.active) revert ProjectAlreadyActive();
        if (stationId == bytes32(0)) revert InvalidStationId();
        if (deploymentTimestamp > block.timestamp) revert InvalidDeploymentTimestamp();

        project.stationId = stationId;
        project.deploymentTimestamp = deploymentTimestamp;
        project.active = true;

        emit StationDeploymentFinalized(projectId, stationId, deploymentTimestamp);
    }

    function pause() external onlyRole(POOL_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(POOL_ADMIN_ROLE) {
        _unpause();
    }

    // ── Oracle ────────────────────────────────────────────────────────────────

    /**
     * @notice Record data rewards earned by the station for the current epoch.
     * @dev Only callable by the ORACLE_ROLE. The oracle is the backend service
     *      that monitors station liveness and attestation quality.
     */
    function recordAdoptionRewards(
        uint256 projectId,
        uint256 dataRewards
    ) external onlyRole(ORACLE_ROLE) whenNotPaused {
        AdoptionProject storage project = _project(projectId);
        if (!project.active) revert ProjectNotActive();
        if (dataRewards == 0) revert ZeroAmount();

        project.cumulativeDataRewards += dataRewards;

        emit AdoptionRewardsRecorded(projectId, dataRewards, project.cumulativeDataRewards);
    }

    // ── Sponsor ───────────────────────────────────────────────────────────────

    /**
     * @notice Deposit WRF to sponsor a station deployment project.
     * @dev Deposits are only accepted before the station becomes active.
     */
    function deposit(uint256 projectId, uint256 amount)
        external
        whenNotPaused
        nonReentrant
    {
        if (amount == 0) revert ZeroAmount();

        AdoptionProject storage project = _project(projectId);
        // Deposits closed once station is active (hardware already deployed).
        if (project.active) revert ProjectAlreadyActive();

        wrfToken.safeTransferFrom(msg.sender, address(this), amount);

        if (sponsorDeposits[projectId][msg.sender] == 0) {
            project.sponsorCount += 1;
            _sponsors[projectId].push(msg.sender);
        }

        sponsorDeposits[projectId][msg.sender] += amount;
        project.totalDeposited += amount;

        emit AdoptionDeposited(projectId, msg.sender, amount, project.totalDeposited);

        if (!project.funded && project.totalDeposited >= project.targetAmount) {
            project.funded = true;
            emit ProjectFunded(projectId, project.totalDeposited);
        }
    }

    /**
     * @notice Withdraw the caller's full deposit from an unfunded project.
     * @dev Once a project is funded the deposit is earmarked for hardware
     *      purchase and can no longer be recalled.
     */
    function withdraw(uint256 projectId) external whenNotPaused nonReentrant {
        AdoptionProject storage project = _project(projectId);
        if (project.funded) revert ProjectAlreadyFunded();

        uint256 amount = sponsorDeposits[projectId][msg.sender];
        if (amount == 0) revert NoDeposit();

        sponsorDeposits[projectId][msg.sender] = 0;
        project.totalDeposited -= amount;

        wrfToken.safeTransfer(msg.sender, amount);

        emit DepositWithdrawn(projectId, msg.sender, amount);
    }

    /**
     * @notice Claim pro-rata yield share from accrued station data rewards.
     * @dev The cliff guard prevents gaming the reward pool by depositing just
     *      before a large oracle batch and withdrawing immediately after.
     *      `sponsorRewardsClaimed` tracks cumulative claimed amounts so that
     *      successive calls only pay out newly accrued rewards.
     */
    function claimRewards(uint256 projectId)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 amount)
    {
        AdoptionProject storage project = _project(projectId);
        if (!project.active) revert ProjectNotActive();

        // Enforce vesting cliff.
        if (block.timestamp < project.deploymentTimestamp + project.cliffDuration) {
            revert CliffNotReached();
        }

        uint256 depositAmount = sponsorDeposits[projectId][msg.sender];
        if (depositAmount == 0) revert NoDeposit();

        uint256 totalEarned = (depositAmount * project.cumulativeDataRewards * project.revenueShareBps) /
            (project.totalDeposited * 10_000);
        uint256 alreadyClaimed = sponsorRewardsClaimed[projectId][msg.sender];

        if (totalEarned <= alreadyClaimed) revert NothingToClaim();

        amount = totalEarned - alreadyClaimed;
        sponsorRewardsClaimed[projectId][msg.sender] = totalEarned;

        wrfToken.safeTransfer(msg.sender, amount);

        emit RewardsClaimed(projectId, msg.sender, amount);
    }

    function claimCertificate(uint256 projectId)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 tokenId)
    {
        AdoptionProject storage project = _project(projectId);
        if (!project.active) revert ProjectNotActive();
        if (sponsorDeposits[projectId][msg.sender] == 0) revert ZeroAmount();
        if (certificateClaimed[projectId][msg.sender]) revert AlreadyClaimed();

        certificateClaimed[projectId][msg.sender] = true;

        tokenId = certificateNFT.mintCertificate(
            msg.sender,
            projectId,
            project.regionId,
            project.stationId,
            sponsorDeposits[projectId][msg.sender],
            project.deploymentTimestamp,
            project.cumulativeDataRewards
        );

        emit CertificateClaimed(projectId, msg.sender, tokenId);
    }

    // ── Views ─────────────────────────────────────────────────────────────────

    /**
     * @notice Total yield earned by a sponsor minus what they have already claimed.
     * @dev Security: Fixed division-before-multiplication precision loss.
     *      The original expression divided twice sequentially:
     *        `(a * b * c) / d / e`
     *      which loses up to (d-1) wei per division step. The corrected form
     *      combines both denominators into a single division:
     *        `(a * b * c) / (d * e)`
     *      preserving full precision for small deposits relative to the pool.
     */
    function claimableRewards(uint256 projectId, address sponsor) external view returns (uint256) {
        AdoptionProject storage project = _project(projectId);
        uint256 depositAmount = sponsorDeposits[projectId][sponsor];
        if (depositAmount == 0 || project.totalDeposited == 0 || project.cumulativeDataRewards == 0) {
            return 0;
        }

        uint256 totalEarned = (depositAmount * project.cumulativeDataRewards * project.revenueShareBps) /
            (project.totalDeposited * 10_000);
        uint256 alreadyClaimed = sponsorRewardsClaimed[projectId][sponsor];
        return totalEarned > alreadyClaimed ? totalEarned - alreadyClaimed : 0;
    }

    function getProject(uint256 projectId)
        external
        view
        returns (
            bytes32 regionId,
            string memory regionLabel,
            uint256 targetAmount,
            uint256 totalDeposited,
            uint256 revenueShareBps,
            uint256 cumulativeDataRewards,
            uint256 createdAt,
            uint256 deploymentTimestamp,
            uint256 cliffDuration,
            bytes32 stationId,
            bool funded,
            bool active,
            uint256 sponsorCount
        )
    {
        AdoptionProject storage project = _project(projectId);
        return (
            project.regionId,
            project.regionLabel,
            project.targetAmount,
            project.totalDeposited,
            project.revenueShareBps,
            project.cumulativeDataRewards,
            project.createdAt,
            project.deploymentTimestamp,
            project.cliffDuration,
            project.stationId,
            project.funded,
            project.active,
            project.sponsorCount
        );
    }

    function getSponsors(uint256 projectId) external view returns (address[] memory) {
        _project(projectId);
        return _sponsors[projectId];
    }

    function getTopSponsor(uint256 projectId) external view returns (address sponsor, uint256 amount) {
        _project(projectId);
        address[] storage sponsors = _sponsors[projectId];
        for (uint256 i = 0; i < sponsors.length; i++) {
            uint256 depositAmount = sponsorDeposits[projectId][sponsors[i]];
            if (depositAmount > amount) {
                amount = depositAmount;
                sponsor = sponsors[i];
            }
        }
    }

    // ── Internal ──────────────────────────────────────────────────────────────

    function _project(uint256 projectId) internal view returns (AdoptionProject storage) {
        AdoptionProject storage project = _projects[projectId];
        if (project.createdAt == 0) revert ProjectNotFound();
        return project;
    }
}
