// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Chainlink Price Feed Interface
/// @notice Simplified interface for Chainlink AggregatorV3Interface
interface IChainlinkPriceFeed {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );

    function decimals() external view returns (uint8);
}

