// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

/// @dev UNAUDITED. Do not use in production without a full audit.

import {IPriceFeed} from "../../src/interfaces/IPriceFeed.sol";

/// @title  MockPriceFeed
/// @notice Chainlink-shaped price feed implementing {IPriceFeed}, the oracle the Emissions
///         Manager and the Yield Repurchase Facility price HOOD with.
/// @dev    Quotes one whole HOOD in whole reserve tokens, carrying {decimals} decimals. The
///         staleness setters exist so a test can drive a consumer's `maxPriceAge` check, and
///         {setAnswer} accepts a negative answer so the "reject answer <= 0" branch is reachable.
contract MockPriceFeed is IPriceFeed {
    /// @inheritdoc IPriceFeed
    uint8 public override decimals;

    /// @notice Human-readable feed name, e.g. "HOOD / DAI".
    string public description;

    /// @notice Chainlink aggregator interface version.
    uint256 public constant version = 4;

    int256 private _answer;
    uint256 private _updatedAt;
    uint80 private _roundId;
    uint256 private _startedAt;

    /// @param description_ Feed name.
    /// @param decimals_ Answer decimals; {IPriceFeed} consumers reject anything above 18.
    /// @param answer_ Initial answer, carrying `decimals_` decimals.
    constructor(string memory description_, uint8 decimals_, int256 answer_) {
        description = description_;
        decimals = decimals_;
        _answer = answer_;
        _roundId = 1;
        _startedAt = block.timestamp;
        _updatedAt = block.timestamp;
    }

    /// @inheritdoc IPriceFeed
    function latestAnswer() external view override returns (int256) {
        return _answer;
    }

    /// @inheritdoc IPriceFeed
    function updatedAt() external view override returns (uint256) {
        return _updatedAt;
    }

    /// @notice Latest round in the full Chainlink layout, for consumers that read the envelope.
    /// @return roundId The round id.
    /// @return answer The reported price.
    /// @return startedAt When the round started.
    /// @return updatedAt_ When the answer was last written.
    /// @return answeredInRound The round the answer was computed in.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt_, uint80 answeredInRound)
    {
        return (_roundId, _answer, _startedAt, _updatedAt, _roundId);
    }

    /// @notice Publishes a new answer in a fresh round, timestamped now.
    /// @param answer_ The new price, carrying {decimals} decimals.
    function setAnswer(int256 answer_) external {
        _answer = answer_;
        _roundId += 1;
        _startedAt = block.timestamp;
        _updatedAt = block.timestamp;
    }

    /// @notice Forces a stale `updatedAt` so a consumer's staleness guard can be exercised.
    /// @param updatedAt_ The timestamp to report.
    function setUpdatedAt(uint256 updatedAt_) external {
        _updatedAt = updatedAt_;
    }
}
