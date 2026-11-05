pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {InstitutionalTokenCustodyVault} from "../src/InstitutionalTokenCustodyVault.sol";
import {SecurityToken} from "../src/SecurityToken.sol";

contract DepositAccountingHandler is Test {
    InstitutionalTokenCustodyVault private immutable _vault;
    address[3] private _owners;
    SecurityToken[2] private _tokens;

    mapping(address => mapping(address => uint256)) public credited;
    mapping(address => uint256) public depositedTotal;
    mapping(address => uint256) public surplus;
    uint256 public successfulDeposits;
    uint256 public successfulDonations;
    uint256 public unexpectedFailures;

    constructor(InstitutionalTokenCustodyVault vault, address admin, address[3] memory owners) {
        _vault = vault;
        _owners = owners;
        _tokens[0] = new SecurityToken(admin, address(this));
        _tokens[1] = new SecurityToken(admin, address(this));
    }

    function ownerAt(uint256 index) external view returns (address) {
        return _owners[index];
    }

    function tokenAt(uint256 index) external view returns (SecurityToken) {
        return _tokens[index];
    }

    function depositFor(uint256 ownerSeed, uint256 tokenSeed, uint256 amountSeed) external {
        address owner = _owners[ownerSeed % _owners.length];
        SecurityToken token = _tokens[tokenSeed % _tokens.length];
        uint256 amount = bound(amountSeed, 1, 1e24);

        token.mint(owner, amount);
        vm.prank(owner);
        assertTrue(token.approve(address(_vault), amount));

        vm.prank(owner);
        try _vault.deposit(address(token), amount) {
            credited[owner][address(token)] += amount;
            depositedTotal[address(token)] += amount;
            successfulDeposits += 1;
        } catch {
            unexpectedFailures += 1;
        }
    }

    function donateFor(uint256 ownerSeed, uint256 tokenSeed, uint256 amountSeed) external {
        address owner = _owners[ownerSeed % _owners.length];
        SecurityToken token = _tokens[tokenSeed % _tokens.length];
        uint256 amount = bound(amountSeed, 1, 1e24);

        token.mint(owner, amount);
        vm.prank(owner);
        assertTrue(token.transfer(address(_vault), amount));

        surplus[address(token)] += amount;
        successfulDonations += 1;
    }
}

contract VaultDepositInvariantTest is Test {
    InstitutionalTokenCustodyVault private vault;
    DepositAccountingHandler private handler;

    function setUp() public {
        vault = new InstitutionalTokenCustodyVault(address(this));
        vault.grantRole(keccak256("COMPLIANCE_ROLE"), address(this));
        vault.grantRole(keccak256("POLICY_ROLE"), address(this));

        address[3] memory owners = [makeAddr("alice"), makeAddr("bob"), makeAddr("carol")];
        handler = new DepositAccountingHandler(vault, address(this), owners);

        for (uint256 i = 0; i < owners.length; ++i) {
            vault.setInvestorAllowed(owners[i], true);
        }

        InstitutionalTokenCustodyVault.TokenPolicy memory policy = InstitutionalTokenCustodyVault.TokenPolicy({
            depositsEnabled: true, withdrawalsEnabled: false, maxPerWithdrawal: 0, maxPerOwnerDay: 0, maxPerVaultDay: 0
        });

        for (uint256 tokenIndex = 0; tokenIndex < 2; ++tokenIndex) {
            vault.setTokenPolicy(address(handler.tokenAt(tokenIndex)), policy);

            for (uint256 ownerIndex = 0; ownerIndex < owners.length; ++ownerIndex) {
                handler.depositFor(ownerIndex, tokenIndex, (ownerIndex + 1) * 1_000_000);
            }

            handler.donateFor(tokenIndex, tokenIndex, 1_000_000);
        }

        assertEq(handler.successfulDeposits(), 6);
        assertEq(handler.successfulDonations(), 2);
        assertEq(handler.unexpectedFailures(), 0);
        _assertAccounting();

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = DepositAccountingHandler.depositFor.selector;
        selectors[1] = DepositAccountingHandler.donateFor.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariantDepositsRemainReconciled() public view {
        assertEq(handler.unexpectedFailures(), 0);
        _assertAccounting();
    }

    function afterInvariant() public view {
        assertGt(handler.successfulDeposits() + handler.successfulDonations(), 8);
        assertEq(handler.unexpectedFailures(), 0);
        _assertAccounting();
    }

    function _assertAccounting() private view {
        for (uint256 tokenIndex = 0; tokenIndex < 2; ++tokenIndex) {
            SecurityToken token = handler.tokenAt(tokenIndex);
            uint256 totalCredited;

            for (uint256 ownerIndex = 0; ownerIndex < 3; ++ownerIndex) {
                address owner = handler.ownerAt(ownerIndex);
                uint256 expected = handler.credited(owner, address(token));
                assertEq(vault.balanceOf(owner, address(token)), expected);
                totalCredited += expected;
            }

            assertEq(totalCredited, handler.depositedTotal(address(token)));
            assertEq(vault.totalLiability(address(token)), totalCredited);
            assertEq(token.balanceOf(address(vault)), totalCredited + handler.surplus(address(token)));
            assertEq(vault.balanceOf(address(handler), address(token)), 0);
            assertEq(vault.balanceOf(address(this), address(token)), 0);
        }
    }
}
