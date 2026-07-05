// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal view of AgentAMM used by the converter and the buyback.
interface IAgentAMM {
    function shareToken() external view returns (address);
    function quoteToken() external view returns (address);

    function swapShareForQuote(uint256 shareIn, uint256 minQuoteOut, uint256 deadline)
        external
        returns (uint256 quoteOut);

    function swapQuoteForShare(uint256 quoteIn, uint256 minShareOut, uint256 deadline)
        external
        returns (uint256 shareOut);
}
