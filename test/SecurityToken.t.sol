pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SecurityToken} from "../src/SecurityToken.sol";

contract SecurityTokenTest is Test {
    SecurityToken private token;
    address private admin;
    address private minter;
    address private alice;
    address private bob;
    address private spender;
    bytes32 private adminRole;
    bytes32 private minterRole;

    function setUp() public {
        admin = makeAddr("admin");
        minter = makeAddr("minter");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        spender = makeAddr("spender");
        token = new SecurityToken(admin, minter);
        adminRole = token.DEFAULT_ADMIN_ROLE();
        minterRole = token.MINTER_ROLE();
    }

    function testInitialConfiguration() public view {
        assertEq(token.name(), "Security Token");
        assertEq(token.symbol(), "SECT");
        assertEq(token.decimals(), 6);
        assertEq(token.totalSupply(), 0);
        assertTrue(token.hasRole(adminRole, admin));
        assertTrue(token.hasRole(minterRole, minter));
        assertFalse(token.hasRole(minterRole, admin));
        assertFalse(token.hasRole(adminRole, minter));
        assertFalse(token.hasRole(adminRole, address(this)));
        assertFalse(token.hasRole(minterRole, address(this)));
    }

    function testRejectsZeroAdmin() public {
        vm.expectRevert(SecurityToken.InvalidAdmin.selector);
        new SecurityToken(address(0), minter);
    }

    function testRejectsZeroMinter() public {
        vm.expectRevert(SecurityToken.InvalidMinter.selector);
        new SecurityToken(admin, address(0));
    }

    function testMinterCanMint() public {
        vm.prank(minter);
        token.mint(alice, 100_000_000);

        assertEq(token.balanceOf(alice), 100_000_000);
        assertEq(token.totalSupply(), 100_000_000);
    }

    function testUnauthorizedAccountCannotMint() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, minterRole)
        );
        vm.prank(alice);
        token.mint(alice, 1_000_000);

        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(alice), 0);
    }

    function testAdminCannotMintWithoutMinterRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, minterRole)
        );
        vm.prank(admin);
        token.mint(alice, 1_000_000);
    }

    function testAdminCanGrantMinterRole() public {
        vm.prank(admin);
        token.grantRole(minterRole, bob);

        vm.prank(bob);
        token.mint(alice, 1_000_000);

        assertTrue(token.hasRole(minterRole, bob));
        assertEq(token.balanceOf(alice), 1_000_000);
    }

    function testRevokedMinterCannotMint() public {
        vm.prank(admin);
        token.revokeRole(minterRole, minter);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, minter, minterRole)
        );
        vm.prank(minter);
        token.mint(alice, 1_000_000);

        assertFalse(token.hasRole(minterRole, minter));
        assertEq(token.totalSupply(), 0);
    }

    function testUnauthorizedAccountCannotGrantMinterRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, adminRole)
        );
        vm.prank(alice);
        token.grantRole(minterRole, alice);

        assertFalse(token.hasRole(minterRole, alice));
    }

    function testCannotMintToZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(minter);
        token.mint(address(0), 1_000_000);

        assertEq(token.totalSupply(), 0);
    }

    function testHolderCanTransfer() public {
        vm.prank(minter);
        token.mint(alice, 100_000_000);

        vm.prank(alice);
        token.transfer(bob, 25_000_000);

        assertEq(token.balanceOf(alice), 75_000_000);
        assertEq(token.balanceOf(bob), 25_000_000);
        assertEq(token.totalSupply(), 100_000_000);
    }

    function testApprovedSpenderCanTransferFrom() public {
        vm.prank(minter);
        token.mint(alice, 100_000_000);

        vm.prank(alice);
        token.approve(spender, 40_000_000);

        vm.prank(spender);
        token.transferFrom(alice, bob, 25_000_000);

        assertEq(token.allowance(alice, spender), 15_000_000);
        assertEq(token.balanceOf(alice), 75_000_000);
        assertEq(token.balanceOf(bob), 25_000_000);
        assertEq(token.totalSupply(), 100_000_000);
    }

    function testTransferFromCannotExceedAllowance() public {
        vm.prank(minter);
        token.mint(alice, 100_000_000);

        vm.prank(alice);
        token.approve(spender, 10_000_000);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 10_000_000, 20_000_000)
        );
        vm.prank(spender);
        token.transferFrom(alice, bob, 20_000_000);

        assertEq(token.allowance(alice, spender), 10_000_000);
        assertEq(token.balanceOf(alice), 100_000_000);
        assertEq(token.balanceOf(bob), 0);
    }

    function testFuzzMintPreservesAccounting(uint96 amount) public {
        vm.prank(minter);
        token.mint(alice, amount);

        assertEq(token.balanceOf(alice), amount);
        assertEq(token.totalSupply(), amount);
    }

    function testFuzzTransferPreservesSupply(uint96 minted, uint96 requested) public {
        uint256 amount = bound(uint256(requested), 0, uint256(minted));

        vm.prank(minter);
        token.mint(alice, minted);

        vm.prank(alice);
        token.transfer(bob, amount);

        assertEq(token.balanceOf(alice), uint256(minted) - amount);
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.balanceOf(alice) + token.balanceOf(bob), minted);
        assertEq(token.totalSupply(), minted);
    }
}
