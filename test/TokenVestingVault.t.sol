// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/TokenVestingVault.sol";
import "./mocks/MockERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract TokenVestingVaultTest is Test {
    TokenVestingVault public vault;
    MockERC20 public token;

    address public owner = makeAddr("owner");
    address public beneficiary = makeAddr("beneficiary");
    address public outsider = makeAddr("outsider");

    uint256 public constant TOTAL_ALLOCATION = 1_000_000 ether;
    uint256 public constant START_TIME = 100_000;
    uint256 public constant CLIFF_DURATION = 10_000;
    uint256 public constant TOTAL_DURATION = 40_000;

    function setUp() public {
        vm.warp(START_TIME);
        vm.startPrank(owner);
        vault = new TokenVestingVault();
        token = new MockERC20("Vesting Token", "VTK", 18);
        token.mint(owner, 10_000_000 ether);
        token.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function _createDefaultSchedule(bool revocable) internal returns (bytes32 scheduleId) {
        vm.prank(owner);
        scheduleId = vault.createVestingSchedule(
            beneficiary,
            address(token),
            TOTAL_ALLOCATION,
            START_TIME,
            CLIFF_DURATION,
            TOTAL_DURATION,
            revocable
        );
    }

    function test_CreateSchedule_Success() public {
        bytes32 id = _createDefaultSchedule(true);
        (
            bool init,
            address b,
            address t,
            uint256 total,
            uint256 start,
            uint256 cliff,
            uint256 duration,
            uint256 released,
            bool revocable,
            bool revoked,
            uint256 vestedAtRevocation
        ) = vault.schedules(id);

        assertTrue(init);
        assertEq(b, beneficiary);
        assertEq(t, address(token));
        assertEq(total, TOTAL_ALLOCATION);
        assertEq(start, START_TIME);
        assertEq(cliff, CLIFF_DURATION);
        assertEq(duration, TOTAL_DURATION);
        assertEq(released, 0);
        assertTrue(revocable);
        assertFalse(revoked);
        assertEq(vestedAtRevocation, 0);
        assertEq(token.balanceOf(address(vault)), TOTAL_ALLOCATION);
    }

    function test_CreateSchedule_InvalidParametersRevert() public {
        vm.startPrank(owner);

        // Zero beneficiary
        vm.expectRevert(TokenVestingVault.ZeroAddress.selector);
        vault.createVestingSchedule(address(0), address(token), 100, START_TIME, 10, 100, true);

        // Zero token
        vm.expectRevert(TokenVestingVault.ZeroAddress.selector);
        vault.createVestingSchedule(beneficiary, address(0), 100, START_TIME, 10, 100, true);

        // Zero amount
        vm.expectRevert(TokenVestingVault.ZeroAmount.selector);
        vault.createVestingSchedule(beneficiary, address(token), 0, START_TIME, 10, 100, true);

        // Zero duration
        vm.expectRevert(TokenVestingVault.InvalidDuration.selector);
        vault.createVestingSchedule(beneficiary, address(token), 100, START_TIME, 0, 0, true);

        // Cliff > duration
        vm.expectRevert(TokenVestingVault.InvalidCliff.selector);
        vault.createVestingSchedule(beneficiary, address(token), 100, START_TIME, 150, 100, true);

        vm.stopPrank();
    }

    function test_PreCliff_ReleasesNothing() public {
        bytes32 id = _createDefaultSchedule(true);

        // Warp to 1 second before cliff
        vm.warp(START_TIME + CLIFF_DURATION - 1);
        assertEq(vault.computeVestedAmount(id), 0);
        assertEq(vault.computeReleasableAmount(id), 0);

        vm.prank(beneficiary);
        vm.expectRevert(TokenVestingVault.NothingToClaim.selector);
        vault.claim(id);
    }

    function test_CliffReached_ReleasesLinearly() public {
        bytes32 id = _createDefaultSchedule(true);

        // Warp exactly to cliff (10,000s out of 40,000s = 25%)
        vm.warp(START_TIME + CLIFF_DURATION);
        uint256 expectedVested = (TOTAL_ALLOCATION * CLIFF_DURATION) / TOTAL_DURATION; // 250,000 ether
        assertEq(vault.computeVestedAmount(id), expectedVested);
        assertEq(vault.computeReleasableAmount(id), expectedVested);

        vm.prank(beneficiary);
        vault.claim(id);

        assertEq(token.balanceOf(beneficiary), expectedVested);
        assertEq(vault.computeReleasableAmount(id), 0);
    }

    function test_PartialAndRepeatedClaims() public {
        bytes32 id = _createDefaultSchedule(true);

        // Step 1: Claim at 50% time (20,000s)
        vm.warp(START_TIME + 20_000);
        vm.prank(beneficiary);
        vault.claim(id);
        assertEq(token.balanceOf(beneficiary), 500_000 ether);

        // Step 2: Claim at 75% time (30,000s)
        vm.warp(START_TIME + 30_000);
        vm.prank(beneficiary);
        vault.claim(id);
        assertEq(token.balanceOf(beneficiary), 750_000 ether);

        // Step 3: Claim at 100% time (40,000s)
        vm.warp(START_TIME + 40_000);
        vm.prank(beneficiary);
        vault.claim(id);
        assertEq(token.balanceOf(beneficiary), TOTAL_ALLOCATION);

        // Step 4: Double claim attempt after completion
        vm.warp(START_TIME + 100_000);
        vm.prank(beneficiary);
        vm.expectRevert(TokenVestingVault.NothingToClaim.selector);
        vault.claim(id);
    }

    function test_UnauthorizedClaimReverts() public {
        bytes32 id = _createDefaultSchedule(true);
        vm.warp(START_TIME + 20_000);

        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(TokenVestingVault.UnauthorizedBeneficiary.selector, outsider, beneficiary)
        );
        vault.claim(id);
    }

    function test_Revocation_MidSchedule() public {
        bytes32 id = _createDefaultSchedule(true);

        // Warp to 50% time (20,000s)
        vm.warp(START_TIME + 20_000);
        uint256 vestedSoFar = 500_000 ether;
        uint256 unvested = 500_000 ether;

        uint256 ownerBalBefore = token.balanceOf(owner);

        // Revoke schedule
        vm.prank(owner);
        uint256 refunded = vault.revoke(id);

        assertEq(refunded, unvested);
        assertEq(token.balanceOf(owner), ownerBalBefore + unvested);

        // Beneficiary claims their vested 500,000 ether even after revocation
        vm.prank(beneficiary);
        vault.claim(id);
        assertEq(token.balanceOf(beneficiary), vestedSoFar);

        // Beneficiary cannot claim more later
        vm.warp(START_TIME + TOTAL_DURATION + 10_000);
        vm.prank(beneficiary);
        vm.expectRevert(TokenVestingVault.NothingToClaim.selector);
        vault.claim(id);
    }

    function test_Revocation_PreCliff_RefundsAll() public {
        bytes32 id = _createDefaultSchedule(true);

        // Warp before cliff
        vm.warp(START_TIME + 5_000);

        uint256 ownerBalBefore = token.balanceOf(owner);
        vm.prank(owner);
        uint256 refunded = vault.revoke(id);

        assertEq(refunded, TOTAL_ALLOCATION);
        assertEq(token.balanceOf(owner), ownerBalBefore + TOTAL_ALLOCATION);

        // Beneficiary gets 0
        vm.prank(beneficiary);
        vm.expectRevert(TokenVestingVault.NothingToClaim.selector);
        vault.claim(id);
    }

    function test_Revocation_NonRevocableOrAlreadyRevokedReverts() public {
        bytes32 nonRevId = _createDefaultSchedule(false);

        // Attempting to revoke non-revocable schedule
        vm.prank(owner);
        vm.expectRevert(TokenVestingVault.NotRevocable.selector);
        vault.revoke(nonRevId);

        bytes32 revId = _createDefaultSchedule(true);
        vm.prank(owner);
        vault.revoke(revId);

        // Attempting to revoke again
        vm.prank(owner);
        vm.expectRevert(TokenVestingVault.AlreadyRevoked.selector);
        vault.revoke(revId);
    }

    function test_UnauthorizedRevokeReverts() public {
        bytes32 id = _createDefaultSchedule(true);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        vault.revoke(id);
    }

    function testFuzz_VestingLinearity(uint32 warpSeconds) public {
        bytes32 id = _createDefaultSchedule(true);
        vm.warp(START_TIME + warpSeconds);

        uint256 vested = vault.computeVestedAmount(id);
        if (warpSeconds < CLIFF_DURATION) {
            assertEq(vested, 0);
        } else if (warpSeconds >= TOTAL_DURATION) {
            assertEq(vested, TOTAL_ALLOCATION);
        } else {
            uint256 expected = (TOTAL_ALLOCATION * warpSeconds) / TOTAL_DURATION;
            assertEq(vested, expected);
        }
    }
}
