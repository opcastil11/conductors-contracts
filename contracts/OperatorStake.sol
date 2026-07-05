// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title OperatorStake
 * @notice Per-agent operator bond — the on-chain half of the revenue-attestation trust model
 *         (docs/TOKENOMICS.md §6). The agent's operator posts a **USDC bond**; if an
 *         **attester** proves the operator under-reported the asset's real x402 revenue (or
 *         otherwise misbehaved), the bond is **slashed** to a beneficiary (an insurance fund /
 *         the treasury). This gives holders recourse and makes honest reporting the operator's
 *         dominant strategy.
 *
 * Key property: withdrawals are **cooldown-delayed**, and slashing works **during** the
 * cooldown — so an operator can't front-run a slash by yanking the bond the moment they expect
 * to be caught. The attestation itself (proving under-reporting) is off-chain/oracle work; this
 * contract is the escrow + slash primitive that gives it teeth.
 */
contract OperatorStake is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable bondToken;  // USDC
    address public immutable operator;  // the bonded operator

    address public attester;            // may slash (attestation oracle / owner)
    address public beneficiary;         // receives slashed funds (insurance / treasury)
    uint256 public cooldown;            // seconds a withdrawal must wait

    uint256 public staked;              // bonded amount currently held
    uint256 public unlockAt;            // maturity of a pending withdrawal (0 = none pending)

    event Staked(address indexed operator, uint256 amount, uint256 total);
    event WithdrawRequested(uint256 unlockAt);
    event Withdrawn(uint256 amount, uint256 remaining);
    event Slashed(uint256 amount, address indexed to, string reason, uint256 remaining);
    event AttesterUpdated(address indexed attester);
    event BeneficiaryUpdated(address indexed beneficiary);
    event CooldownUpdated(uint256 cooldown);

    modifier onlyOperator() {
        require(msg.sender == operator, "not operator");
        _;
    }

    constructor(
        address _bondToken,
        address _operator,
        address _attester,
        address _beneficiary,
        uint256 _cooldown,
        address _owner
    ) Ownable(_owner) {
        require(_bondToken != address(0) && _operator != address(0), "zero addr");
        require(_attester != address(0) && _beneficiary != address(0), "zero addr");
        bondToken = IERC20(_bondToken);
        operator = _operator;
        attester = _attester;
        beneficiary = _beneficiary;
        cooldown = _cooldown;
    }

    // ─── Operator ───────────────────────────────────────────────────────────────

    /// @notice Post (or top up) the bond. Approve `bondToken` first. Cancels a pending withdrawal.
    function stake(uint256 amount) external onlyOperator nonReentrant {
        require(amount > 0, "amount>0");
        bondToken.safeTransferFrom(msg.sender, address(this), amount);
        staked += amount;
        unlockAt = 0; // topping up recommits the bond
        emit Staked(operator, amount, staked);
    }

    /// @notice Begin the withdrawal cooldown. Slashing still applies until funds actually leave.
    function requestWithdraw() external onlyOperator {
        require(staked > 0, "nothing staked");
        unlockAt = block.timestamp + cooldown;
        emit WithdrawRequested(unlockAt);
    }

    /// @notice Withdraw up to the bonded amount once the cooldown has matured.
    function withdraw(uint256 amount) external onlyOperator nonReentrant {
        require(unlockAt != 0 && block.timestamp >= unlockAt, "cooldown");
        require(amount > 0 && amount <= staked, "bad amount");
        staked -= amount;
        if (staked == 0) unlockAt = 0;
        bondToken.safeTransfer(operator, amount);
        emit Withdrawn(amount, staked);
    }

    // ─── Attester / owner ─────────────────────────────────────────────────────────

    /// @notice Slash part (or all) of the bond to the beneficiary. Works during the cooldown.
    function slash(uint256 amount, string calldata reason) external nonReentrant {
        require(msg.sender == attester || msg.sender == owner(), "not attester");
        require(amount > 0 && amount <= staked, "bad amount");
        staked -= amount;
        bondToken.safeTransfer(beneficiary, amount);
        emit Slashed(amount, beneficiary, reason, staked);
    }

    function setAttester(address _attester) external onlyOwner {
        require(_attester != address(0), "zero addr");
        attester = _attester;
        emit AttesterUpdated(_attester);
    }

    function setBeneficiary(address _beneficiary) external onlyOwner {
        require(_beneficiary != address(0), "zero addr");
        beneficiary = _beneficiary;
        emit BeneficiaryUpdated(_beneficiary);
    }

    function setCooldown(uint256 _cooldown) external onlyOwner {
        cooldown = _cooldown;
        emit CooldownUpdated(_cooldown);
    }

    /// @notice True while a withdrawal request is maturing.
    function withdrawalPending() external view returns (bool) {
        return unlockAt != 0 && block.timestamp < unlockAt;
    }
}
