pragma solidity 0.8.38;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract SecurityToken is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    error InvalidAdmin();
    error InvalidMinter();

    constructor(address admin, address minter) ERC20("Security Token", "SECT") {
        if (admin ==address(0)) revert InvalidAdmin();
        if (minter == address(0)) revert InvalidMinter();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, minter);

    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address recipeint, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(recipeint,amount);
    }
    
}