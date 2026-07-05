// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title AgentConversion
 * @notice The bridge between the two dobx products: converts an agent's **Product A** token
 *         (growth / speculative, from the bonding curve) into its **Product B** distribution
 *         token (income / real yield) — see docs/TOKENOMICS.md.
 *
 * Design (from the tokenomics spec, hardened against the yield-dilution trap):
 *  - **One-way only** (A → B). There is no B → A path, so A is monotonically retired and the
 *    income side is never inflated by round-trips.
 *  - **NAV-anchored rate**, not a fixed peg. `rate` = B per A (scaled 1e18) is supplied by an
 *    authorized updater (a NAV/price oracle in production) with an optional staleness bound, so
 *    conversion reflects B's real yield-backed value and gives A a fundamental floor.
 *  - **B is drawn from a bounded treasury reserve**, never minted. When the reserve depletes,
 *    conversion halts — which caps circulating B and protects every B holder's per-token yield.
 *    (A fixed-peg mint-on-convert design would dilute B yield to zero; this avoids it.)
 *  - **Converted A is sent to the treasury** (a non-sellable sink), matching the buyback loop.
 *
 * In production, `tokenB` is the DobProtocol participation token the distributor pays yield to.
 */
contract AgentConversion is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable tokenA;      // agent token (Product A)
    IERC20 public immutable tokenB;      // distribution token (Product B)
    address public immutable treasury;   // non-sellable sink for converted A

    address public rateUpdater;          // NAV/price oracle allowed to set the rate
    uint256 public rate;                 // B per A, scaled 1e18 (bOut = aIn * rate / 1e18)
    uint256 public rateUpdatedAt;        // timestamp of the last rate update
    uint256 public maxRateStaleness;     // seconds; 0 = no staleness check
    uint256 public bReserve;             // tracked B available to hand out (bounded)

    event Converted(address indexed user, uint256 aIn, uint256 bOut, uint256 rate);
    event RateUpdated(uint256 rate, uint256 at);
    event RateUpdaterSet(address indexed updater);
    event ReserveFunded(address indexed from, uint256 amount);

    modifier ensure(uint256 deadline) {
        require(block.timestamp <= deadline, "expired");
        _;
    }

    constructor(
        address _tokenA,
        address _tokenB,
        address _treasury,
        address _owner,
        address _rateUpdater,
        uint256 _maxRateStaleness
    ) Ownable(_owner) {
        require(_tokenA != address(0) && _tokenB != address(0), "zero token");
        require(_tokenA != _tokenB, "same token");
        require(_treasury != address(0) && _rateUpdater != address(0), "zero addr");
        tokenA = IERC20(_tokenA);
        tokenB = IERC20(_tokenB);
        treasury = _treasury;
        rateUpdater = _rateUpdater;
        maxRateStaleness = _maxRateStaleness;
    }

    // ─── Admin / oracle ─────────────────────────────────────────────────────────

    /// @notice Set the NAV-anchored conversion rate (B per A, scaled 1e18).
    function setRate(uint256 newRate) external {
        require(msg.sender == rateUpdater || msg.sender == owner(), "not updater");
        require(newRate > 0, "rate>0");
        rate = newRate;
        rateUpdatedAt = block.timestamp;
        emit RateUpdated(newRate, block.timestamp);
    }

    function setRateUpdater(address updater) external onlyOwner {
        require(updater != address(0), "zero addr");
        rateUpdater = updater;
        emit RateUpdaterSet(updater);
    }

    function setMaxRateStaleness(uint256 secs) external onlyOwner {
        maxRateStaleness = secs;
    }

    /// @notice Fund the B reserve that conversions draw from (owner/protocol tops it up from
    ///         the fixed B allocation — never beyond it, keeping B supply bounded).
    function fundReserve(uint256 amount) external {
        require(amount > 0, "amount>0");
        tokenB.safeTransferFrom(msg.sender, address(this), amount);
        bReserve += amount;
        emit ReserveFunded(msg.sender, amount);
    }

    // ─── Conversion (one-way A → B) ─────────────────────────────────────────────

    /// @notice B received for converting `aIn` of A at the current rate.
    function quote(uint256 aIn) public view returns (uint256) {
        return (aIn * rate) / 1e18;
    }

    /// @notice Convert `aIn` of A into B. Approve A first. B is drawn from the reserve; the A
    ///         is sunk into the treasury. Reverts if the rate is unset/stale or the reserve is
    ///         insufficient (the natural cap that protects B's per-token yield).
    function convert(uint256 aIn, uint256 minBOut, uint256 deadline)
        external
        ensure(deadline)
        nonReentrant
        returns (uint256 bOut)
    {
        require(aIn > 0, "aIn>0");
        require(rate > 0, "no rate");
        if (maxRateStaleness > 0) {
            require(block.timestamp - rateUpdatedAt <= maxRateStaleness, "stale rate");
        }
        bOut = quote(aIn);
        require(bOut > 0 && bOut >= minBOut, "slippage");
        require(bReserve >= bOut, "reserve depleted");

        bReserve -= bOut;                                   // effects
        tokenA.safeTransferFrom(msg.sender, treasury, aIn); // A → treasury sink
        tokenB.safeTransfer(msg.sender, bOut);              // B out of the reserve

        emit Converted(msg.sender, aIn, bOut, rate);
    }
}
