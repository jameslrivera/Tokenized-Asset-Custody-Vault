pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {InstitutionalTokenCustodyVault} from "../src/InstitutionalTokenCustodyVault.sol";
import {SecurityToken} from "../src/SecurityToken.sol";

contract VaultPauseTest is Test {
    bytes32 private constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 private constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");
    bytes32 private constant POLICY_ROLE = keccak256("POLICY_ROLE");
    bytes32 private constant SIGNER_ADMIN_ROLE = keccak256("SIGNER_ADMIN_ROLE");
    bytes32 private constant DEFAULT_ADMIN_ROLE = bytes32(0);

    InstitutionalTokenCustodyVault private vault;
    address private admin;
    address private pauser;
    address private alice;
    address private bob;

    event Paused(address account);
    event Unpaused(address account);
    event PolicyEpochAdvanced(uint256 previousEpoch, uint256 newEpoch);

    function setUp() public {
        admin = makeAddr("admin");
        pauser = makeAddr("pauser");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        vault = new InstitutionalTokenCustodyVault(admin);

        vm.prank(admin);
        vault.grantRole(PAUSER_ROLE, pauser);
    }

    function testStartsUnpaused() public view {
        assertFalse(vault.paused());
        assertEq(vault.policyEpoch(), 1);
        assertEq(vault.PAUSER_ROLE(), PAUSER_ROLE);
        assertTrue(vault.hasRole(PAUSER_ROLE, pauser));
        assertFalse(vault.hasRole(PAUSER_ROLE, admin));
    }

    function testPauserCanPauseAndAdminCanUnpause() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit Paused(pauser);
        vm.expectEmit(false, false, false, true, address(vault));
        emit PolicyEpochAdvanced(1, 2);
        vm.prank(pauser);
        vault.pause();

        assertTrue(vault.paused());
        assertEq(vault.policyEpoch(), 2);

        vm.expectEmit(false, false, false, true, address(vault));
        emit Unpaused(admin);
        vm.expectEmit(false, false, false, true, address(vault));
        emit PolicyEpochAdvanced(2, 3);
        vm.prank(admin);
        vault.unpause();

        assertFalse(vault.paused());
        assertEq(vault.policyEpoch(), 3);
    }

    function testUnauthorizedCallerCannotPauseInEitherState() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, PAUSER_ROLE)
        );
        vm.prank(alice);
        vault.pause();

        assertFalse(vault.paused());
        assertEq(vault.policyEpoch(), 1);

        vm.prank(pauser);
        vault.pause();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, PAUSER_ROLE)
        );
        vm.prank(alice);
        vault.pause();

        assertTrue(vault.paused());
        assertEq(vault.policyEpoch(), 2);
    }

    function testAdminNeedsPauserRoleToPause() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, PAUSER_ROLE)
        );
        vm.prank(admin);
        vault.pause();

        assertFalse(vault.paused());
        assertEq(vault.policyEpoch(), 1);

        vm.startPrank(admin);
        vault.grantRole(PAUSER_ROLE, admin);
        vault.pause();
        vm.stopPrank();

        assertTrue(vault.paused());
        assertEq(vault.policyEpoch(), 2);
    }

    function testPauserCannotUnpause() public {
        vm.prank(pauser);
        vault.pause();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, pauser, DEFAULT_ADMIN_ROLE)
        );
        vm.prank(pauser);
        vault.unpause();

        assertTrue(vault.paused());
        assertEq(vault.policyEpoch(), 2);
    }

    function testUnauthorizedCallerCannotUnpauseInEitherState() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, DEFAULT_ADMIN_ROLE)
        );
        vm.prank(alice);
        vault.unpause();

        assertFalse(vault.paused());
        assertEq(vault.policyEpoch(), 1);

        vm.prank(pauser);
        vault.pause();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, DEFAULT_ADMIN_ROLE)
        );
        vm.prank(alice);
        vault.unpause();

        assertTrue(vault.paused());
        assertEq(vault.policyEpoch(), 2);
    }

    function testOtherOperationalRolesCannotPauseOrUnpause() public {
        vm.startPrank(admin);
        vault.grantRole(COMPLIANCE_ROLE, alice);
        vault.grantRole(POLICY_ROLE, alice);
        vault.grantRole(SIGNER_ADMIN_ROLE, alice);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, PAUSER_ROLE)
        );
        vm.prank(alice);
        vault.pause();

        assertFalse(vault.paused());
        assertEq(vault.policyEpoch(), 1);

        vm.prank(pauser);
        vault.pause();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, DEFAULT_ADMIN_ROLE)
        );
        vm.prank(alice);
        vault.unpause();

        assertTrue(vault.paused());
        assertEq(vault.policyEpoch(), 2);
    }

    function testAdminCanReplacePauserWhilePaused() public {
        vm.prank(pauser);
        vault.pause();

        vm.startPrank(admin);
        vault.revokeRole(PAUSER_ROLE, pauser);
        vault.grantRole(PAUSER_ROLE, bob);
        vm.stopPrank();

        assertTrue(vault.paused());
        assertFalse(vault.hasRole(PAUSER_ROLE, pauser));
        assertTrue(vault.hasRole(PAUSER_ROLE, bob));
        assertEq(vault.policyEpoch(), 2);

        vm.prank(admin);
        vault.unpause();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, pauser, PAUSER_ROLE)
        );
        vm.prank(pauser);
        vault.pause();

        assertFalse(vault.paused());
        assertEq(vault.policyEpoch(), 3);

        vm.prank(bob);
        vault.pause();

        assertTrue(vault.paused());
        assertEq(vault.policyEpoch(), 4);
    }

    function testRepeatedPauseRevertsWithoutChangingStateOrEmittingEvents() public {
        vm.prank(pauser);
        vault.pause();

        vm.recordLogs();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(pauser);
        vault.pause();

        assertEq(vm.getRecordedLogs().length, 0);
        assertTrue(vault.paused());
        assertEq(vault.policyEpoch(), 2);
    }

    function testUnpauseWhileRunningRevertsWithoutChangingStateOrEmittingEvents() public {
        vm.recordLogs();
        vm.expectRevert(Pausable.ExpectedPause.selector);
        vm.prank(admin);
        vault.unpause();

        assertEq(vm.getRecordedLogs().length, 0);
        assertFalse(vault.paused());
        assertEq(vault.policyEpoch(), 1);
    }

    function testPauseCyclesKeepAdvancingEpoch() public {
        for (uint256 cycle = 0; cycle < 3; ++cycle) {
            vm.prank(pauser);
            vault.pause();

            assertTrue(vault.paused());
            assertEq(vault.policyEpoch(), 2 + cycle * 2);

            vm.prank(admin);
            vault.unpause();

            assertFalse(vault.paused());
            assertEq(vault.policyEpoch(), 3 + cycle * 2);
        }
    }

    function testComplianceCanChangeAllowlistsWhilePaused() public {
        vm.prank(admin);
        vault.grantRole(COMPLIANCE_ROLE, alice);

        vm.prank(pauser);
        vault.pause();

        vm.prank(alice);
        vault.setInvestorAllowed(alice, true);

        assertTrue(vault.paused());
        assertTrue(vault.investorAllowed(alice));
        assertEq(vault.policyEpoch(), 3);

        vm.prank(alice);
        vault.setRecipientAllowed(alice, bob, true);

        assertTrue(vault.paused());
        assertTrue(vault.recipientAllowed(alice, bob));
        assertEq(vault.policyEpoch(), 4);

        vm.prank(admin);
        vault.unpause();

        assertFalse(vault.paused());
        assertTrue(vault.investorAllowed(alice));
        assertTrue(vault.recipientAllowed(alice, bob));
        assertEq(vault.policyEpoch(), 5);
    }

    function testPolicyManagerCanChangeTokenPolicyWhilePaused() public {
        SecurityToken token = new SecurityToken(admin, admin);
        InstitutionalTokenCustodyVault.TokenPolicy memory policy = InstitutionalTokenCustodyVault.TokenPolicy({
            depositsEnabled: true,
            withdrawalsEnabled: true,
            maxPerWithdrawal: 100_000_000,
            maxPerOwnerDay: 250_000_000,
            maxPerVaultDay: 500_000_000
        });

        vm.prank(admin);
        vault.grantRole(POLICY_ROLE, bob);

        vm.prank(bob);
        vault.setTokenPolicy(address(token), policy);
        assertEq(vault.policyEpoch(), 2);

        vm.prank(pauser);
        vault.pause();
        assertEq(vault.policyEpoch(), 3);

        policy.depositsEnabled = false;
        policy.maxPerWithdrawal = 50_000_000;
        vm.prank(bob);
        vault.setTokenPolicy(address(token), policy);

        assertTrue(vault.paused());
        _assertPolicy(address(token), policy);
        assertEq(vault.policyEpoch(), 4);

        vm.prank(admin);
        vault.unpause();

        assertFalse(vault.paused());
        _assertPolicy(address(token), policy);
        assertEq(vault.policyEpoch(), 5);
    }

    function _assertPolicy(address token, InstitutionalTokenCustodyVault.TokenPolicy memory expected) private view {
        InstitutionalTokenCustodyVault.TokenPolicy memory actual = vault.tokenPolicy(token);
        assertEq(actual.depositsEnabled, expected.depositsEnabled);
        assertEq(actual.withdrawalsEnabled, expected.withdrawalsEnabled);
        assertEq(actual.maxPerWithdrawal, expected.maxPerWithdrawal);
        assertEq(actual.maxPerOwnerDay, expected.maxPerOwnerDay);
        assertEq(actual.maxPerVaultDay, expected.maxPerVaultDay);
    }
}
