// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title TokenVestingVault
 * @notice Linear token vesting vault with cliff, beneficiary claiming, double-claim prevention,
 * and fair revocation that refunds unvested tokens to the owner while locking in vested claims.
 */
contract TokenVestingVault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct VestingSchedule {
        bool initialized;
        address beneficiary;
        address token;
        uint256 totalAmount;
        uint256 start;
        uint256 cliff;      // cliff duration in seconds from start
        uint256 duration;   // total vesting duration in seconds from start
        uint256 released;   // total amount already claimed
        bool revocable;     // true if owner can revoke
        bool revoked;       // true if schedule was revoked
        uint256 vestedAtRevocation; // snapshot of vested tokens when revoked
    }

    uint256 private _scheduleCounter;
    mapping(bytes32 => VestingSchedule) public schedules;
    mapping(address => bytes32[]) private _beneficiarySchedules;

    // Custom errors
    error ZeroAddress();
    error ZeroAmount();
    error InvalidDuration();
    error InvalidCliff();
    error ScheduleNotFound();
    error UnauthorizedBeneficiary(address caller, address expected);
    error NothingToClaim();
    error NotRevocable();
    error AlreadyRevoked();

    // Events
    event ScheduleCreated(
        bytes32 indexed scheduleId,
        address indexed beneficiary,
        address indexed token,
        uint256 totalAmount,
        uint256 start,
        uint256 cliff,
        uint256 duration,
        bool revocable
    );
    event TokensClaimed(bytes32 indexed scheduleId, address indexed beneficiary, uint256 amount);
    event ScheduleRevoked(bytes32 indexed scheduleId, uint256 unvestedRefunded);

    constructor() Ownable(msg.sender) {}

    /**
     * @notice Create a new linear vesting schedule for a beneficiary
     */
    function createVestingSchedule(
        address beneficiary,
        address token,
        uint256 totalAmount,
        uint256 start,
        uint256 cliff,
        uint256 duration,
        bool revocable
    ) external onlyOwner nonReentrant returns (bytes32 scheduleId) {
        if (beneficiary == address(0) || token == address(0)) revert ZeroAddress();
        if (totalAmount == 0) revert ZeroAmount();
        if (duration == 0) revert InvalidDuration();
        if (cliff > duration) revert InvalidCliff();

        scheduleId = keccak256(
            abi.encodePacked(beneficiary, token, start, duration, ++_scheduleCounter)
        );

        schedules[scheduleId] = VestingSchedule({
            initialized: true,
            beneficiary: beneficiary,
            token: token,
            totalAmount: totalAmount,
            start: start,
            cliff: cliff,
            duration: duration,
            released: 0,
            revocable: revocable,
            revoked: false,
            vestedAtRevocation: 0
        });

        _beneficiarySchedules[beneficiary].push(scheduleId);

        emit ScheduleCreated(
            scheduleId,
            beneficiary,
            token,
            totalAmount,
            start,
            cliff,
            duration,
            revocable
        );

        IERC20(token).safeTransferFrom(msg.sender, address(this), totalAmount);
    }

    /**
     * @notice Claim all vested and unreleased tokens for a specific schedule
     */
    function claim(bytes32 scheduleId) external nonReentrant returns (uint256 amountToClaim) {
        VestingSchedule storage schedule = schedules[scheduleId];
        if (!schedule.initialized) revert ScheduleNotFound();
        if (msg.sender != schedule.beneficiary) {
            revert UnauthorizedBeneficiary(msg.sender, schedule.beneficiary);
        }

        amountToClaim = computeReleasableAmount(scheduleId);
        if (amountToClaim == 0) revert NothingToClaim();

        schedule.released += amountToClaim;

        emit TokensClaimed(scheduleId, msg.sender, amountToClaim);

        IERC20(schedule.token).safeTransfer(msg.sender, amountToClaim);
    }

    /**
     * @notice Revoke a revocable schedule, refunding unvested tokens to owner and locking vested tokens for beneficiary
     */
    function revoke(bytes32 scheduleId) external onlyOwner nonReentrant returns (uint256 unvestedRefunded) {
        VestingSchedule storage schedule = schedules[scheduleId];
        if (!schedule.initialized) revert ScheduleNotFound();
        if (!schedule.revocable) revert NotRevocable();
        if (schedule.revoked) revert AlreadyRevoked();

        uint256 vested = _computeVestedAmount(schedule, block.timestamp);
        unvestedRefunded = schedule.totalAmount - vested;

        schedule.revoked = true;
        schedule.vestedAtRevocation = vested;
        schedule.totalAmount = vested;

        emit ScheduleRevoked(scheduleId, unvestedRefunded);

        if (unvestedRefunded > 0) {
            IERC20(schedule.token).safeTransfer(owner(), unvestedRefunded);
        }
    }

    /**
     * @notice Calculate currently vested amount for a schedule based on current block.timestamp
     */
    function computeVestedAmount(bytes32 scheduleId) public view returns (uint256) {
        VestingSchedule memory schedule = schedules[scheduleId];
        if (!schedule.initialized) return 0;
        return _computeVestedAmount(schedule, block.timestamp);
    }

    /**
     * @notice Calculate currently claimable (releasable) amount for a schedule
     */
    function computeReleasableAmount(bytes32 scheduleId) public view returns (uint256) {
        VestingSchedule memory schedule = schedules[scheduleId];
        if (!schedule.initialized) return 0;
        uint256 vested = _computeVestedAmount(schedule, block.timestamp);
        return vested > schedule.released ? vested - schedule.released : 0;
    }

    /**
     * @notice Internal linear vesting calculation
     */
    function _computeVestedAmount(
        VestingSchedule memory schedule,
        uint256 currentTime
    ) internal pure returns (uint256) {
        if (schedule.revoked) {
            return schedule.vestedAtRevocation;
        }

        if (currentTime < schedule.start + schedule.cliff) {
            return 0;
        } else if (currentTime >= schedule.start + schedule.duration) {
            return schedule.totalAmount;
        } else {
            return (schedule.totalAmount * (currentTime - schedule.start)) / schedule.duration;
        }
    }

    /**
     * @notice Retrieve all schedule IDs belonging to a beneficiary
     */
    function getSchedulesByBeneficiary(address beneficiary) external view returns (bytes32[] memory) {
        return _beneficiarySchedules[beneficiary];
    }
}
