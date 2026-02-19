// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Escrow} from "./Escrow.sol";
import {ArbiterRegistry} from "./ArbiterRegistry.sol";

/**
 * @title EscrowFactory
 * @notice Factory contract for creating and managing escrow instances
 * @dev Central registry for all escrows with platform fee collection
 */
contract EscrowFactory is Ownable, ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error EscrowFactory__InvalidRegistry();
    error EscrowFactory__InvalidFeeCollector();
    error EscrowFactory__InvalidSeller();
    error EscrowFactory__CannotEscrowWithYourself();
    error EscrowFactory__InvalidAmount();
    error EscrowFactory__InvalidDeadline();
    error EscrowFactory__ArbiterNotActive();
    error EscrowFactory__InvalidAddress();
    error EscrowFactory__NoFeesToWithdraw();
    error EscrowFactory__TransferFailed();
    error EscrowFactory__InvalidArbiter();

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    // Instance of the arbiter registry
    ArbiterRegistry public arbiterRegistry;

    // Platform fee collector address
    address public feeCollector;

    // Total number of escrows created
    uint256 public escrowCount;

    // Mapping from escrow ID to escrow address
    mapping(uint256 => address) public escrows;

    // Mapping from user address to their escrow IDs (as buyer or seller)
    mapping(address => uint256[]) public userEscrows;

    // Mapping to track if an address is a valid escrow
    mapping(address => bool) public isEscrow;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event EscrowCreated(
        uint256 indexed escrowId, address indexed buyer, address indexed seller, address escrow, uint256 amount
    );
    event ArbiterRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event FeeCollectorUpdated(address indexed oldCollector, address indexed newCollector);
    event FeesWithdrawn(address indexed collector, uint256 indexed amount);

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize the factory
     * @param _arbiterRegistry Address of the arbiter registry contract
     * @param _feeCollector Address where platform fees are collected
     */
    constructor(address _arbiterRegistry, address _feeCollector) Ownable(msg.sender) {
        if (_arbiterRegistry == address(0)) {
            revert EscrowFactory__InvalidRegistry();
        }
        if (_feeCollector == address(0)) {
            revert EscrowFactory__InvalidFeeCollector();
        }

        arbiterRegistry = ArbiterRegistry(_arbiterRegistry);
        feeCollector = _feeCollector;
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Create a new escrow
     * @param _seller Address of the seller
     * @param _arbiter Address of the arbiter
     * @param _amount Amount to be escrowed
     * @param _deadline Deadline timestamp for delivery
     * @param _description Description of the work/goods
     * @return escrowAddress Address of the newly created escrow
     */
    function createEscrow(
        address _seller,
        address _arbiter,
        uint256 _amount,
        uint256 _deadline,
        string memory _description
    ) external returns (address escrowAddress) {
        if (_seller == address(0)) {
            revert EscrowFactory__InvalidSeller();
        }
        if (_seller == msg.sender) {
            revert EscrowFactory__CannotEscrowWithYourself();
        }
        if (_amount == 0) {
            revert EscrowFactory__InvalidAmount();
        }
        if (_deadline <= block.timestamp) {
            revert EscrowFactory__InvalidDeadline();
        }

        if (_arbiter == address(0)) {
            revert EscrowFactory__InvalidArbiter();
        }

        // Check if arbiter is active
        if (!arbiterRegistry.isArbiterActive(_arbiter)) {
            revert EscrowFactory__ArbiterNotActive();
        }

        // Create new escrow
        Escrow escrow = new Escrow(
            msg.sender, // buyer
            _seller,
            _arbiter,
            _amount,
            _deadline,
            _description
        );

        escrowAddress = address(escrow);
        uint256 escrowId = escrowCount;

        escrows[escrowId] = escrowAddress;
        isEscrow[escrowAddress] = true;
        userEscrows[msg.sender].push(escrowId); // buyer
        userEscrows[_seller].push(escrowId); // seller

        escrowCount++;

        emit EscrowCreated(escrowId, msg.sender, _seller, escrowAddress, _amount);
    }

    /**
     * @notice Get all escrow IDs for a user
     * @param user Address of the user
     * @return uint256[] Array of escrow IDs
     */
    function getEscrowsByUser(address user) external view returns (uint256[] memory) {
        return userEscrows[user];
    }

    /**
     * @notice Update arbiter registry address
     * @param _newRegistry New registry address
     */
    function setArbiterRegistry(address _newRegistry) external onlyOwner {
        if (_newRegistry == address(0)) {
            revert EscrowFactory__InvalidAddress();
        }

        address oldRegistry = address(arbiterRegistry);
        arbiterRegistry = ArbiterRegistry(_newRegistry);

        emit ArbiterRegistryUpdated(oldRegistry, _newRegistry);
    }

    /**
     * @notice Update fee collector address
     * @param _newCollector New collector address
     */
    function setFeeCollector(address _newCollector) external onlyOwner {
        if (_newCollector == address(0)) {
            revert EscrowFactory__InvalidAddress();
        }

        address oldCollector = feeCollector;
        feeCollector = _newCollector;

        emit FeeCollectorUpdated(oldCollector, _newCollector);
    }

    /**
     * @notice Withdraw collected fees
     * @dev Can only be called by owner, sends to fee collector
     */
    function withdrawFees() external onlyOwner {
        uint256 balance = address(this).balance;
        if (balance == 0) {
            revert EscrowFactory__NoFeesToWithdraw();
        }

        (bool success,) = feeCollector.call{value: balance}("");
        if (!success) {
            revert EscrowFactory__TransferFailed();
        }

        emit FeesWithdrawn(feeCollector, balance);
    }

    /**
     * @notice Allow factory to receive ETH (for fees)
     */
    receive() external payable {}
}
