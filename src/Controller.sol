// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

// Tracks the ownership token, an NFT,
// the holder of which is entitled to request delivery
// of the good.
struct OwnershipToken {
    IERC721 token;
    uint256 id;
}

struct Stake {
    IERC20 token;
    uint256 amount;
}

struct Terms {
    OwnershipToken ownershipToken;
    // what the possesor of the physical good is 
    // staking in promise that they will deliver it
    Stake possesorStake;
    // what the ownershipToken holder requesting physical 
    // delivery must stake.
    Stake fulfillmentStake;
    // Time that is allowed for fulfillment
    uint256 fulfillmentTime;
}

// uses 216 bits, fits in a single slot
struct DealState {
    bool ownerCancelFulfill;
    bool possessorCancelFulfill;
    uint40 fulfillmentRequestedTimestamp;
    // The creator of the deal, presumed possessor of the item
    // described by ownershipToken described in Terms
    address possessor;
}

contract Controller {
    using SafeERC20 for IERC20;

    // Some DAO address
    address public DAO = address(1); 
    mapping(bytes32 => DealState) public dealState;

    error AlreadyExists();
    event Create(bytes32 indexed key, address indexed creator, Terms terms);

    function create(Terms calldata terms) external {
        bytes32 k = termsKey(terms);

        if (dealState[k].possessor != address(0)) {
            revert AlreadyExists();
        }

        dealState[k].possessor = msg.sender;

        terms.possesorStake.token.safeTransferFrom(
            msg.sender,
            address(this), 
            terms.possesorStake.amount
        );

        emit Create(k, msg.sender, terms);
    }

    error MustBeCreatorAndOwnershipTokenOwner();

    function cancel(Terms calldata terms) external {
        bytes32 k = termsKey(terms);
        
        if (dealState[k].possessor != msg.sender || msg.sender != terms.ownershipToken.token.ownerOf(terms.ownershipToken.id)) {
            revert MustBeCreatorAndOwnershipTokenOwner();
        }

        if (dealState[k].fulfillmentRequestedTimestamp != 0) {
            // tbd if this should be allowed
            revert FulfillmentInProgress();
        }

        delete dealState[k];

        terms.possesorStake.token.safeTransferFrom(
            address(this),
            msg.sender,
            terms.possesorStake.amount
        );
    }

    error MustBeOwnershipTokenOwner();
    error NotFound();
    error FulfillmentInProgress();

    event RequestFulfillment(bytes32 indexed key, bytes data);

    function requestFulfillment(Terms calldata terms, bytes calldata data) external {
        bytes32 k = termsKey(terms);

        if (dealState[k].possessor == address(0)) {
            revert NotFound();
        }

        if (dealState[k].fulfillmentRequestedTimestamp != 0) {
            revert FulfillmentInProgress();
        }

        if (msg.sender != terms.ownershipToken.token.ownerOf(terms.ownershipToken.id)) {
            revert MustBeOwnershipTokenOwner();
        }

        dealState[k].fulfillmentRequestedTimestamp = uint40(block.timestamp);

        terms.fulfillmentStake.token.safeTransferFrom(
            msg.sender,
            address(this),
            terms.fulfillmentStake.amount
        );

        emit RequestFulfillment(k, data);
    }

    error OnlyOwner();

    function markFulfilled(Terms calldata terms) external {
        bytes32 k = termsKey(terms);

        if (msg.sender != terms.ownershipToken.token.ownerOf(terms.ownershipToken.id)) {
            revert MustBeOwnershipTokenOwner();
        }

        address possessor = dealState[k].possessor;

        delete dealState[k];

        terms.possesorStake.token.safeTransferFrom(
            address(this),
            possessor,
            terms.possesorStake.amount
        );

        terms.fulfillmentStake.token.safeTransferFrom(
            address(this),
            msg.sender,
            terms.fulfillmentStake.amount
        );
    }

    error FulfilmentNotExpired();

    // Penalty for not fulfilling in time, stakes are sent to DAO
    function claimStakes(Terms calldata terms) external {
        bytes32 k = termsKey(terms);

        if (dealState[k].possessor == address(0)) {
            revert NotFound();
        }

        if (terms.fulfillmentTime + dealState[k].fulfillmentRequestedTimestamp < block.timestamp) {
            revert FulfilmentNotExpired();
        }

        terms.possesorStake.token.safeTransferFrom(
            address(this),
            DAO,
            terms.possesorStake.amount
        );

        terms.fulfillmentStake.token.safeTransferFrom(
            address(this),
            DAO,
            terms.fulfillmentStake.amount
        );
    }

    function ownerCancelFulfill() external {
        // TODO
    }

    error OnlyPossessor();

    function possessorCancelFulfill() external {
        // TODO
    }

    error FulfillmentNotInProgress();
    error CancelNotAllowed();

    event CancelFulfill(bytes32 indexed key);

    // cancellation could possibly better be done by having one party
    // pass a signature from the other party to this function 
    function cancelFulfill(Terms calldata terms) external {
        bytes32 k = termsKey(terms);

        DealState storage deal = dealState[k];
        
        if (deal.fulfillmentRequestedTimestamp == 0) {
            revert FulfillmentInProgress();
        }

        if (!deal.possessorCancelFulfill || !deal.possessorCancelFulfill) {
            revert CancelNotAllowed();
        }

        address owner = deal.possessor;

        // more efficient to delete and recreate
        delete dealState[k];

        dealState[k].possessor = owner;

        emit CancelFulfill(k);
    }

    function termsKey(Terms calldata terms) public returns (bytes32) {
        return keccak256(abi.encode(terms));
    }
}
