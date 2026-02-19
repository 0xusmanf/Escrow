// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title ArbiterRegistry
 * @notice Registry contract for managing arbiters who can resolve disputes
 * @dev Arbiters must stake tokens to participate and build reputation over time
 */
// aderyn-ignore-next-line(centralization-risk)
contract ArbiterRegistry is Ownable {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ArbiterRegistry__InsufficientStakeValue();
    error ArbiterRegistry__AlreadyRegistered();
    error ArbiterRegistry__NotRegistered();
    error ArbiterRegistry__WithdrawalAlreadyRequested();
    error ArbiterRegistry__NoWithdrawalRequested();
    error ArbiterRegistry__WithdrawalTooSoon();
    error ArbiterRegistry__NoStakeToWithdraw();
    error ArbiterRegistry__TransactionFailed();
    error ArbiterRegistry__ArbiterNotFound();

    /*//////////////////////////////////////////////////////////////
                           TYPE DECLARATIONS
    //////////////////////////////////////////////////////////////*/

    // Minimum stake required to register as an arbiter
    uint256 public constant MINIMUM_STAKE = 0.1 ether;

    // Time period an arbiter must wait before withdrawing stake
    uint256 public constant WITHDRAWAL_DELAY = 7 days;

    /**
     * @notice Arbiter information structure
     * @param isActive Whether the arbiter is currently active
     * @param stake Amount of ETH staked by the arbiter
     * @param disputesResolved Total number of disputes resolved
     * @param successfulResolutions Number of resolutions that weren't challenged
     * @param registeredAt Timestamp when arbiter registered
     * @param withdrawalRequestTime Timestamp when withdrawal was requested (0 if none)
     */
    struct Arbiter {
        bool isActive;
        uint256 stake;
        uint256 disputesResolved;
        uint256 successfulResolutions;
        uint256 registeredAt;
        uint256 withdrawalRequestTime;
    }

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    // Mapping of arbiter addresses to their information
    mapping(address => Arbiter) public arbiters;

    // Total number of registered arbiters
    uint256 public totalArbiters;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event ArbiterRegistered(address indexed arbiter, uint256 indexed stake);
    event ArbiterStakeIncreased(address indexed arbiter, uint256 indexed additionalStake);
    event WithdrawalRequested(address indexed arbiter, uint256 indexed timestamp);
    event StakeWithdrawn(address indexed arbiter, uint256 indexed amount);
    event ReputationUpdated(address indexed arbiter, bool indexed successful);

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() Ownable(msg.sender) {}

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Register as an arbiter by staking the minimum required amount
     * @dev Requires sending at least MINIMUM_STAKE ETH with the transaction
     */
    function registerArbiter() external payable {
        if (msg.value < MINIMUM_STAKE) {
            revert ArbiterRegistry__InsufficientStakeValue();
        }
        if (arbiters[msg.sender].isActive) {
            revert ArbiterRegistry__AlreadyRegistered();
        }

        arbiters[msg.sender] = Arbiter({
            isActive: true,
            stake: msg.value,
            disputesResolved: 0,
            successfulResolutions: 0,
            registeredAt: block.timestamp,
            withdrawalRequestTime: 0
        });

        totalArbiters++;
        emit ArbiterRegistered(msg.sender, msg.value);
    }

    /**
     * @notice Request to withdraw stake, initiating the withdrawal delay
     * @dev Arbiter becomes inactive immediately but must wait WITHDRAWAL_DELAY to withdraw
     */
    function requestWithdrawal() external {
        Arbiter storage arbiter = arbiters[msg.sender];
        if (!arbiter.isActive) {
            revert ArbiterRegistry__NotRegistered();
        }
        if (arbiter.withdrawalRequestTime > 0) {
            revert ArbiterRegistry__WithdrawalAlreadyRequested();
        }

        arbiter.isActive = false;
        arbiter.withdrawalRequestTime = block.timestamp;

        emit WithdrawalRequested(msg.sender, block.timestamp);
    }

    /**
     * @notice Withdraw stake after the withdrawal delay period
     * @dev Can only be called after WITHDRAWAL_DELAY has passed since requesting withdrawal
     */
    function withdrawStake() external {
        Arbiter storage arbiter = arbiters[msg.sender];
        if (arbiter.withdrawalRequestTime == 0) {
            revert ArbiterRegistry__NoWithdrawalRequested();
        }
        if (block.timestamp < arbiter.withdrawalRequestTime + WITHDRAWAL_DELAY) {
            revert ArbiterRegistry__WithdrawalTooSoon();
        }

        uint256 amount = arbiter.stake;
        if (amount == 0) {
            revert ArbiterRegistry__NoStakeToWithdraw();
        }

        arbiter.stake = 0;
        totalArbiters--;

        (bool success,) = msg.sender.call{value: amount}("");
        if (!success) {
            revert ArbiterRegistry__TransactionFailed();
        }

        emit StakeWithdrawn(msg.sender, amount);
    }

    /**
     * @notice Update arbiter's reputation after resolving a dispute
     * @dev Can only be called by the EscrowFactory
     * @param arbiter Address of the arbiter
     * @param successful Whether the resolution was successful (not challenged)
     */
    // aderyn-ignore-next-line(centralization-risk)
    function updateReputation(address arbiter, bool successful) external onlyOwner {
        if (arbiters[arbiter].registeredAt == 0) {
            revert ArbiterRegistry__ArbiterNotFound();
        }

        arbiters[arbiter].disputesResolved++;
        if (successful) {
            arbiters[arbiter].successfulResolutions++;
        }

        emit ReputationUpdated(arbiter, successful);
    }

    /**
     * @notice Check if an arbiter is currently active
     * @param arbiter Address to check
     * @return bool True if arbiter is active
     */
    function isArbiterActive(address arbiter) external view returns (bool) {
        return arbiters[arbiter].isActive;
    }

    /**
     * @notice Get arbiter's reputation score (percentage of successful resolutions)
     * @param arbiter Address of the arbiter
     * @return uint256 Reputation score (0-100)
     */
    function getReputationScore(address arbiter) external view returns (uint256) {
        Arbiter memory a = arbiters[arbiter];
        if (a.disputesResolved == 0) {
            return 0;
        }
        // Need to check these calculations for edge cases
        return (a.successfulResolutions * 100) / a.disputesResolved;
    }
}
