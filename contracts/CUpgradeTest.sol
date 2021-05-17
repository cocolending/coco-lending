pragma solidity ^0.5.16;

import "./CToken.sol";
import "./CErc20.sol";
import "./Unitroller.sol";

/**
 * @title Compound's CErc20 Contract
 * @notice CTokens which wrap an EIP-20 underlying
 * @author Compound
 */
contract CUpgradeTest is CDelegateInterface {
    uint constant public compRate = 3141592654;

    function balanceOf(address owner) external view returns (uint) {
        return uint(uint160(owner));
    }

    /**
     * @notice Called by the delegator on a delegate to initialize it for duty
     * @param data The encoded bytes data for any initialization
     */
    function _becomeImplementation(bytes memory data) public {
        // Shh -- currently unused
        data;
        // Shh -- we don't ever want this hook to be marked pure
        if (false) {
            //implementation = address(0);
        }

        //require(msg.sender == admin, "only the admin may call _becomeImplementation");
    }

    /**
     * @notice Called by the delegator on a delegate to forfeit its responsibility
     */
    function _resignImplementation() public {
        // Shh -- we don't ever want this hook to be marked pure
        if (false) {
            //implementation = address(0);
        }
        //require(msg.sender == admin, "only the admin may call _resignImplementation");
    }

    function _become(Unitroller unitroller) public {
        require(msg.sender == unitroller.admin(), "only unitroller admin can change brains");
        require(unitroller._acceptImplementation() == 0, "change not authorized");
    }
}