// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title Escrow
 * @notice Individual escrow contract managing funds between buyer and seller
 * @dev Implements state machine for escrow lifecycle with optional arbiter for disputes
 */
contract Escrow is ReentrancyGuard, Pausable {
    error NotBuyer();
    error NotSeller();
    error NotArbiter();
    error InvalidState();
    error BuyerCannotBeZeroAddress();
    error SellerCannotBeZeroAddress();
    error ArbiterCannotBeZeroAddress();
    error BuyerCannotBeSeller();
    error AmountMustBePositive();
    error InvalidDeadline();
    error DescriptionRequired();
    error IncorrectAmount();
    error DeadlinePassed();
    error ReasonRequired();
    error ResolutionRequired();
    error AmountsShouldAddUpToAvailableAmount();
    error NotAuthorized();
    error DeadlineNotPassed();
    error CannotCancelInCurrentState();
    error NoFundsToWithdraw();
    error WithdrawalFailed();

    /**
     * @notice Possible states of an escrow contract
     * @dev State transitions follow a strict order to ensure security
     *
     * State Flow:
     * Created → Funded → Delivered → Completed (happy path)
     * Created → Cancelled (before funding)
     * Created → Funded → Refunded (after deadline, no delivery)
     * Created → Funded → Delivered → Disputed → Resolved (dispute path)
     *
     * @param Created Initial state when escrow is deployed
     * @param Funded Buyer has deposited the escrowed amount
     * @param Delivered Seller has marked the work/goods as delivered
     * @param Completed Buyer confirmed delivery, funds released to seller
     * @param Disputed Buyer raised a dispute after delivery
     * @param Resolved Arbiter has resolved the dispute
     * @param Cancelled Escrow cancelled before funding
     * @param Refunded Buyer reclaimed funds after deadline passed without delivery
     */
    enum EscrowState {
        Created,
        Funded,
        Delivered,
        Completed,
        Disputed,
        Resolved,
        Cancelled,
        Refunded
    }

    /**
     * @notice Core escrow details structure
     * @param buyer Address of the buyer who creates and funds the escrow
     * @param seller Address of the seller who receives payment upon completion
     * @param arbiter Address of the arbiter who can resolve disputes
     * @param amount Amount of ETH held in escrow
     * @param deadline Timestamp by which delivery must occur
     * @param state Current state of the escrow
     * @param description Description of the work/goods being escrowed
     * @param createdAt Timestamp when escrow was created
     */
    struct EscrowDetails {
        address buyer;
        address seller;
        address arbiter;
        uint256 amount;
        uint256 deadline;
        EscrowState state;
        string description;
        uint256 createdAt;
    }

    // Core escrow details
    EscrowDetails public details;

    // Factory contract that created this escrow
    address public immutable FACTORY;

    // @notice Whether a dispute has been raised
    bool public isDisputed;

    // Timestamp when dispute was raised
    uint256 public disputeTimestamp;

    // Reason provided for the dispute
    string public disputeReason;

    // Platform fee percentage (in basis points, 100 = 1%)
    uint256 public constant PLATFORM_FEE_BPS = 50; // 0.5%

    // Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 1e4;

    // Pending withdrawals mapping
    mapping(address => uint256) public pendingWithdrawals;

    event Funded(uint256 amount, uint256 timestamp);
    event Delivered(uint256 timestamp);
    event Completed(uint256 amount, uint256 fee, uint256 timestamp);
    event Disputed(string reason, uint256 timestamp);
    event DisputeResolved(uint256 buyerAmount, uint256 sellerAmount, string resolution);
    event Cancelled(uint256 timestamp);
    event RefundClaimed(uint256 amount, uint256 timestamp);
    event WithdrawalReady(address indexed recipient, uint256 amount);

    modifier onlyBuyer() {
        if (msg.sender != details.buyer) {
            revert NotBuyer();
        }
        _;
    }

    modifier onlySeller() {
        if (msg.sender != details.seller) {
            revert NotSeller();
        }
        _;
    }

    modifier onlyArbiter() {
        if (msg.sender != details.arbiter) {
            revert NotArbiter();
        }
        _;
    }

    modifier inState(EscrowState _state) {
        if (details.state != _state) {
            revert InvalidState();
        }
        _;
    }

    /**
     * @notice Initialize a new escrow
     * @param _buyer Address of the buyer
     * @param _seller Address of the seller
     * @param _arbiter Address of the arbiter (can be zero address for no arbiter)
     * @param _amount Amount to be escrowed in ETH
     * @param _deadline Deadline for delivery
     * @param _description Description of the work/goods
     */
    constructor(
        address _buyer,
        address _seller,
        address _arbiter,
        uint256 _amount,
        uint256 _deadline,
        string memory _description
    ) {
        if (_buyer == address(0)) {
            revert BuyerCannotBeZeroAddress();
        }

        if (_seller == address(0)) {
            revert SellerCannotBeZeroAddress();
        }

        if (_arbiter == address(0)) {
            revert ArbiterCannotBeZeroAddress();
        }

        if (_buyer == _seller) {
            revert BuyerCannotBeSeller();
        }

        if (_amount == 0) {
            revert AmountMustBePositive();
        }

        if (_deadline <= block.timestamp) {
            revert InvalidDeadline();
        }

        if (bytes(_description).length == 0) {
            revert DescriptionRequired();
        }

        // need to figure out a way to insure that the factory is the contract that created the escrow
        FACTORY = msg.sender;

        details = EscrowDetails({
            buyer: _buyer,
            seller: _seller,
            arbiter: _arbiter,
            amount: _amount,
            deadline: _deadline,
            state: EscrowState.Created,
            description: _description,
            createdAt: block.timestamp
        });
    }

    /**
     * @notice Fund the escrow (buyer only)
     * @dev Must send exact amount specified during creation
     */
    function fund() external payable onlyBuyer inState(EscrowState.Created) whenNotPaused {
        if (msg.value != details.amount) {
            revert IncorrectAmount();
        }

        if (block.timestamp > details.deadline) {
            revert DeadlinePassed();
        }

        details.state = EscrowState.Funded;
        emit Funded(msg.value, block.timestamp);
    }

    /**
     * @notice Mark work as delivered (seller only)
     * @dev Transitions from Funded to Delivered state
     */
    function markDelivered() external onlySeller inState(EscrowState.Funded) whenNotPaused {
        if (block.timestamp > details.deadline) {
            revert DeadlinePassed();
        }

        details.state = EscrowState.Delivered;
        emit Delivered(block.timestamp);
    }

    /**
     * @notice Confirm delivery and release payment (buyer only)
     * @dev Uses pull-over-push pattern for safety
     */
    function confirmDelivery() external onlyBuyer inState(EscrowState.Delivered) whenNotPaused {
        details.state = EscrowState.Completed;

        uint256 fee = (details.amount * PLATFORM_FEE_BPS) / BPS_DENOMINATOR;
        uint256 sellerAmount = details.amount - fee;

        // Use pull-over-push pattern
        pendingWithdrawals[details.seller] += sellerAmount;
        pendingWithdrawals[FACTORY] += fee;

        emit Completed(sellerAmount, fee, block.timestamp);
        emit WithdrawalReady(details.seller, sellerAmount);
        emit WithdrawalReady(FACTORY, fee);
    }

    /**
     * @notice Raise a dispute (buyer only)
     * @dev Can only dispute after delivery is marked
     * @param _reason Explanation for the dispute
     */
    function raiseDispute(string memory _reason) external onlyBuyer inState(EscrowState.Delivered) whenNotPaused {
        if (bytes(_reason).length == 0) {
            revert ReasonRequired();
        }

        isDisputed = true;
        disputeTimestamp = block.timestamp;
        disputeReason = _reason;
        details.state = EscrowState.Disputed;

        emit Disputed(_reason, block.timestamp);
    }

    /**
     * @notice Resolve a dispute (arbiter only)
     * @dev Arbiter decides how to split the escrowed amount
     * @param _buyerAmount Amount to return to buyer
     * @param _sellerAmount Amount to send to seller
     * @param _resolution Explanation of the decision
     */
    function resolveDispute(uint256 _buyerAmount, uint256 _sellerAmount, string memory _resolution)
        external
        onlyArbiter
        inState(EscrowState.Disputed)
        whenNotPaused
    {
        if (bytes(_resolution).length == 0) {
            revert ResolutionRequired();
        }

        uint256 fee = (details.amount * PLATFORM_FEE_BPS) / BPS_DENOMINATOR;
        uint256 availableAmount = details.amount - fee;

        if (_buyerAmount + _sellerAmount != availableAmount) {
            revert AmountsShouldAddUpToAvailableAmount();
        }

        details.state = EscrowState.Resolved;

        // Use pull-over-push pattern
        if (_buyerAmount > 0) {
            pendingWithdrawals[details.buyer] += _buyerAmount;
            emit WithdrawalReady(details.buyer, _buyerAmount);
        }
        if (_sellerAmount > 0) {
            pendingWithdrawals[details.seller] += _sellerAmount;
            emit WithdrawalReady(details.seller, _sellerAmount);
        }
        pendingWithdrawals[FACTORY] += fee;
        emit WithdrawalReady(FACTORY, fee);

        emit DisputeResolved(_buyerAmount, _sellerAmount, _resolution);
    }

    /**
     * @notice Cancel escrow before funding or after deadline
     * @dev Can be called by buyer or seller under specific conditions
     */
    function cancel() external whenNotPaused {
        if (msg.sender != details.buyer || msg.sender != details.seller) {
            revert NotAuthorized();
        }

        if (details.state == EscrowState.Created) {
            // Can cancel anytime before funding
            details.state = EscrowState.Cancelled;
            emit Cancelled(block.timestamp);
        } else if (details.state == EscrowState.Funded) {
            // Can only cancel after deadline if not delivered
            if (block.timestamp <= details.deadline) {
                revert DeadlineNotPassed();
            }
            details.state = EscrowState.Refunded;

            pendingWithdrawals[details.buyer] += details.amount;
            emit RefundClaimed(details.amount, block.timestamp);
            emit WithdrawalReady(details.buyer, details.amount);
        } else {
            revert CannotCancelInCurrentState();
        }
    }

    /**
     * @notice Withdraw pending funds
     * @dev Implements pull-over-push pattern for safe withdrawals
     */
    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) {
            revert NoFundsToWithdraw();
        }

        pendingWithdrawals[msg.sender] = 0;

        (bool success,) = msg.sender.call{value: amount}("");
        if (!success) {
            revert WithdrawalFailed();
        }
    }

    /**
     * @notice Get current escrow state
     * @return EscrowState Current state
     */
    function getState() external view returns (EscrowState) {
        return details.state;
    }

    /**
     * @notice Get complete escrow details
     * @return EscrowDetails All escrow information
     */
    function getDetails() external view returns (EscrowDetails memory) {
        return details;
    }

    /**
     * @notice Pause contract (factory only)
     * @dev Emergency pause mechanism
     */
    function pause() external {
        if (msg.sender != FACTORY) {
            revert NotAuthorized();
        }
        _pause();
    }

    /**
     * @notice Unpause contract (factory only)
     */
    function unpause() external {
        if (msg.sender != FACTORY) {
            revert NotAuthorized();
        }
        _unpause();
    }
}
