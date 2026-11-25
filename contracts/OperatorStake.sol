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

    address public attester;            // the only address that may slash
    address public immutable beneficiary; // receives slashed funds (insurance / treasury); fixed
    address public pendingAttester;
    uint256 public pendingAttesterAt;
    uint256 public constant ATTESTER_DELAY = 2 days;
    uint256 public cooldown;            // seconds a withdrawal must wait

    uint256 public staked;              // bonded amount currently held
    uint256 public unlockAt;            // maturity of a pending withdrawal (0 = none pending)
    uint256 public pendingAmount;       // amount fixed at request time

    /// @notice A matured request must be used within this window or it lapses — otherwise one old
    ///         request would be a standing permission to exit instantly whenever a slash loomed.
    uint256 public constant WITHDRAW_WINDOW = 7 days;
    uint256 public constant MAX_COOLDOWN = 90 days;

    event Staked(address indexed operator, uint256 amount, uint256 total);
    event WithdrawRequested(uint256 amount, uint256 unlockAt);
    event WithdrawCancelled();
    event Withdrawn(uint256 amount, uint256 remaining);
    event Slashed(uint256 amount, address indexed to, string reason, uint256 remaining);
    event AttesterUpdated(address indexed attester);
    event AttesterProposed(address indexed attester, uint256 effectiveAt);
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
        require(_cooldown <= MAX_COOLDOWN, "cooldown too long");
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
        _cancelPending(); // topping up recommits the bond
        emit Staked(operator, amount, staked);
    }

    /// @notice Begin the cooldown for withdrawing `amount`. Slashing still applies until funds leave.
    function requestWithdraw(uint256 amount) external onlyOperator {
        require(amount > 0 && amount <= staked, "bad amount");
        pendingAmount = amount;
        unlockAt = block.timestamp + cooldown;
        emit WithdrawRequested(amount, unlockAt);
    }

    /// @notice Withdraw the requested amount, once matured and before the window lapses. One shot.
    function withdraw() external onlyOperator nonReentrant {
        require(unlockAt != 0 && block.timestamp >= unlockAt, "cooldown");
        require(block.timestamp <= unlockAt + WITHDRAW_WINDOW, "request lapsed");
        uint256 amount = pendingAmount <= staked ? pendingAmount : staked;
        require(amount > 0, "nothing to withdraw");
        _cancelPending();
        staked -= amount;
        bondToken.safeTransfer(operator, amount);
        emit Withdrawn(amount, staked);
    }

    function _cancelPending() internal {
        if (unlockAt == 0 && pendingAmount == 0) return;
        unlockAt = 0;
        pendingAmount = 0;
        emit WithdrawCancelled();
    }

    // ─── Attester / owner ─────────────────────────────────────────────────────────

    /// @notice Slash part (or all) of the bond to the beneficiary. Works during the cooldown, and
    ///         cancels any pending withdrawal: the operator must re-request (and re-wait) after it.
    function slash(uint256 amount, string calldata reason) external nonReentrant {
        require(msg.sender == attester, "not attester");
        require(amount > 0, "bad amount");
        // Clamped, so an operator cannot dodge an exact-amount slash by withdrawing 1 wei first.
        if (amount > staked) amount = staked;
        require(amount > 0, "nothing staked");
        staked -= amount;
        _cancelPending();
        bondToken.safeTransfer(beneficiary, amount);
        emit Slashed(amount, beneficiary, reason, staked);
    }

    /// @notice Propose a new attester; it takes effect after ATTESTER_DELAY via {acceptAttester},
    ///         so a leaked owner key can't install itself and slash the bond in one go.
    function setAttester(address _attester) external onlyOwner {
        require(_attester != address(0), "zero addr");
        pendingAttester = _attester;
        pendingAttesterAt = block.timestamp + ATTESTER_DELAY;
        emit AttesterProposed(_attester, pendingAttesterAt);
    }

    function acceptAttester() external onlyOwner {
        require(pendingAttester != address(0), "none pending");
        require(block.timestamp >= pendingAttesterAt, "timelocked");
        attester = pendingAttester;
        pendingAttester = address(0);
        emit AttesterUpdated(attester);
    }

    function setCooldown(uint256 _cooldown) external onlyOwner {
        require(_cooldown <= MAX_COOLDOWN, "cooldown too long");
        cooldown = _cooldown;
        emit CooldownUpdated(_cooldown);
    }

    /// @notice True while a withdrawal request is maturing.
    function withdrawalPending() external view returns (bool) {
        return unlockAt != 0 && block.timestamp < unlockAt;
    }
}
