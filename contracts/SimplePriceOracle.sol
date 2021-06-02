pragma solidity ^0.5.16;

import "./PriceOracle.sol";
import "./CErc20.sol";

import "@openzeppelin/contracts/ownership/Ownable.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";

contract Access is Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;
    EnumerableSet.AddressSet private feeders;
    modifier onlyFeeder() {require(feeders.contains(msg.sender) || msg.sender == owner(), "onlyFeeder");_;}

    function add(address value)
        external onlyOwner
        returns (bool)
    {
        return feeders.add(value);
    }

    /**
     * @dev Removes a value from a set. O(1).
     * Returns false if the value was not present in the set.
     */
    function remove(address value)
        external onlyOwner
        returns (bool)
    {
        return feeders.remove(value);
    }

    function contains( address value)
        external
        view
        returns (bool)
    {
        return feeders.contains(value);
    }

    function enumerate()
        external
        view
        returns (address[] memory)
    {
        return feeders.enumerate();
    }

    function length()
        external
        view
        returns (uint256)
    {
        return feeders.length();
    }

    function get(uint256 index)
        external
        view
        returns (address)
    {
        return feeders.get(index);
    }
}

contract SimplePriceOracle is PriceOracle, Access {
    mapping(address => uint) prices;
    event PricePosted(address asset, uint previousPriceMantissa, uint requestedPriceMantissa, uint newPriceMantissa);

    function getUnderlyingPrice(CToken cToken) public view returns (uint) {
        if (compareStrings(cToken.symbol(), "cETH")) {
            return 1e18;
        } else {
            return prices[address(CErc20(address(cToken)).underlying())];
        }
    }

    function setUnderlyingPrice(CToken cToken, uint underlyingPriceMantissa) external onlyFeeder {
        address asset = address(CErc20(address(cToken)).underlying());
        emit PricePosted(asset, prices[asset], underlyingPriceMantissa, underlyingPriceMantissa);
        prices[asset] = underlyingPriceMantissa;
    }

    function setDirectPrice(address asset, uint price) external onlyFeeder {
        emit PricePosted(asset, prices[asset], price, price);
        prices[asset] = price;
    }

    // v1 price oracle interface for use as backing of proxy
    function assetPrices(address asset) external view returns (uint) {
        return prices[asset];
    }

    function compareStrings(string memory a, string memory b) internal pure returns (bool) {
        return (keccak256(abi.encodePacked((a))) == keccak256(abi.encodePacked((b))));
    }
}
