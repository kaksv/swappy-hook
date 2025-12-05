// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "v4-core/types/Currency.sol";
import {IChainlinkPriceFeed} from "../../src/interfaces/IChainlinkPriceFeed.sol";

/// @title Mock Chainlink Price Feed for Testing
/// @notice Simple mock that implements Chainlink interface for testing
contract MockChainlinkPriceFeed is IChainlinkPriceFeed {
    int256 public price;
    uint8 public constant PRICE_DECIMALS = 8; // Chainlink typically uses 8 decimals
    uint256 public lastUpdated;

    constructor(int256 _initialPrice) {
        price = _initialPrice;
        lastUpdated = block.timestamp;
    }

    function setPrice(int256 _price) external {
        price = _price;
        lastUpdated = block.timestamp;
    }

    function latestRoundData()
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        // Ensure startedAt doesn't underflow
        uint256 startedAtTime = block.timestamp >= 1 hours 
            ? block.timestamp - 1 hours 
            : 0;
        return (1, price, startedAtTime, lastUpdated, 1);
    }

    function decimals() external pure override returns (uint8) {
        return PRICE_DECIMALS;
    }
}

/// @title Mock Oracle Adapter for PerpHook
/// @notice Wraps Chainlink feeds and provides easy price setting for tests
contract MockOracleAdapter {
    mapping(Currency => MockChainlinkPriceFeed) public feeds;

    /// @notice Create or update a price feed for a currency
    function setPriceFeed(Currency currency, MockChainlinkPriceFeed feed) external {
        feeds[currency] = feed;
    }

    /// @notice Set price for a currency (creates feed if needed)
    function setPrice(Currency currency, int256 price) external {
        if (address(feeds[currency]) == address(0)) {
            feeds[currency] = new MockChainlinkPriceFeed(price);
        } else {
            feeds[currency].setPrice(price);
        }
    }

    /// @notice Get the price feed for a currency
    function getFeed(Currency currency) external view returns (IChainlinkPriceFeed) {
        return IChainlinkPriceFeed(address(feeds[currency]));
    }
}
