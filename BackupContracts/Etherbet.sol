// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "hardhat/console.sol";

contract Etherbet {
    /******* state variables *******/

    address public immutable owner;
    uint256 public gameCounter; // Number of all games
    uint256 public betCounter; // Number of all bets (a new game is also a bet)
    mapping(uint => Game) public games; // Game ID to game struct
    mapping(address => uint[]) public addressToGameId; // Mapping from each user address to list of game IDs (game creators)
    mapping(address => uint[]) public addressToBetId; // Mapping from each user address to list of user bets ID (bet placers)
    mapping(uint => Bet) public bets; // Mapping to store each Bet by its ID
    mapping(address => uint256) public pendingWithdrawals; // Track pending withdrawals

    /******* structs *******/

    struct Game {
        uint gameId; // Game ID for identification.
        uint betFinishTime; // Timestamp for when the betting period finishes and no more bets can be added.
        uint gameFinishTime; // Payout time when the result is known.
        bool isActive; // Is the bet currently accepting new players? Yes/No.
        bool isAccepted; // Did the bet go ahead? Yes = continue, No = Refund Participants.
        bool outcome; // A truthy/falsy value. Win/Lose.
        uint[] outcomeTrueBets; // Array of IDs of 'true' bets.
        uint[] outcomeFalseBets; // Array of IDs of 'false' bets.
        uint256 totalBetAmountTrue; // Total amount bet on the 'true' outcome.
        uint256 totalBetAmountFalse; // Total amount bet on the 'false' outcome.
    }

    struct Bet {
        uint amount;
        bool betOnOutcome;
        address bettor;
    }

    /******* Events *******/

    // Emitted when a new game is added.
    event GameAdded(
        uint indexed _gameId,
        uint indexed _finishTime,
        string indexed _nameOfTheGame
    );
    // Emitted when a game is cancelled.
    event GameCancelled(uint indexed _gameId);
    // Emitted when a game goes ahead, no more bets accepted.
    event GameAccepted(uint indexed _id);
    // Emitted when a game finishes. (Emits an array of addresses that won). May have to remove array as limit to event size.
    event GamePayout(
        uint indexed _id,
        uint indexed _amount,
        address[] indexed _winners
    );
    // Emitted when a bet is placed on a game.
    event BetPlaced(
        uint indexed gameId,
        address indexed bettor,
        bool betOnOutcome,
        uint amount
    );

    /******* Modifiers *******/

    // Check if the game is active and the betting period has not ended
    modifier gameIsActiveAndNotEnded(uint _gameId) {
        require(games[_gameId].isActive, "Game is not active.");
        require(
            block.timestamp < games[_gameId].betFinishTime,
            "Betting period has ended."
        );
        _;
    }

    /******* Constructor *******/

    constructor(address _owner) {
		owner = _owner;
	}

    /******* Functions *******/

    /** CREATE A NEW GAME */
    /* params ex: string: 'Sol flips ETH by 1st July 2024 CET', Bool: 'true',
    uint: '1713033600' (unix timestamp).*/
    function newGame(
        string memory _nameOfTheGame,
        bool _winOrLose,
        uint _betFinishTime,
        uint _gameFinishTime
    ) public payable {
        require(msg.value >= 0.001 * 1e18, "You must bet at least 0.001 ETH");
        gameCounter++;
        betCounter++; // Game creation is also considered as a bet.

        // Create a new bet for the game creator.
        bets[betCounter] = Bet({
            amount: msg.value,
            betOnOutcome: _winOrLose,
            bettor: msg.sender
        });

        uint256 totalBetAmountTrue = 0;
        uint256 totalBetAmountFalse = 0;

        // Update total bet amount based on the outcome betted on.
        if (_winOrLose) {
            totalBetAmountTrue = msg.value;
        } else {
            totalBetAmountFalse = msg.value;
        }

        // Initialize arrays for bet IDs and add the first bet ID.
        uint[] memory outcomeTrueBets = new uint[](_winOrLose ? 1 : 0);
        uint[] memory outcomeFalseBets = new uint[](!_winOrLose ? 1 : 0);
        if (_winOrLose) {
            outcomeTrueBets[0] = betCounter;
        } else {
            outcomeFalseBets[0] = betCounter;
        }

        // Create the new game with the initial bet included.
        games[gameCounter] = Game(
            gameCounter,
            _betFinishTime,
            _gameFinishTime,
            true,
            false,
            false, // outcome is not known at game creation
            outcomeTrueBets,
            outcomeFalseBets,
            totalBetAmountTrue,
            totalBetAmountFalse
        );

        // Update mappings for the game creator.
        addressToGameId[msg.sender].push(gameCounter);
        addressToBetId[msg.sender].push(betCounter);

        // Emit events for game addition and bet placement.
        emit GameAdded(gameCounter, _betFinishTime, _nameOfTheGame);
        emit BetPlaced(gameCounter, msg.sender, _winOrLose, msg.value);
    }

    /* PLACE A NEW BET */
    // must already have an established game/event

    function placeBet(
        uint _gameId,
        bool _agreeOrDisagree
    ) public payable gameIsActiveAndNotEnded(_gameId) {
        require(msg.value >= 0.001 * 1e18, "You must bet at least 0.001 ETH");

        // Increment betCounter and use it as the new betId
        uint256 betId = betCounter++;

        // Store the new Bet in the bets mapping, including the bettor's address
        bets[betId] = Bet({
            amount: msg.value,
            betOnOutcome: _agreeOrDisagree,
            bettor: msg.sender // Store the bettor's address with the bet
        });

        // Adjust total bet amounts and record the betId in the appropriate outcome array
        if (_agreeOrDisagree) {
            games[_gameId].totalBetAmountTrue += msg.value;
            games[_gameId].outcomeTrueBets.push(betId); // Store betId indicating it's a bet on the "true" outcome
        } else {
            games[_gameId].totalBetAmountFalse += msg.value;
            games[_gameId].outcomeFalseBets.push(betId); // Store betId indicating it's a bet on the "false" outcome
        }

        // Link this betId with the bettor's address in the addressToBetId mapping
        addressToBetId[msg.sender].push(betId);

        // Emit an event indicating a bet has been placed
        emit BetPlaced(_gameId, msg.sender, _agreeOrDisagree, msg.value);
    }

    /* GET GAME ODDS */
    // simple view function

    function getGameOdds(
        uint _gameId
    ) public view returns (uint oddsTrue, uint oddsFalse) {
        Game storage game = games[_gameId];
        uint totalBetAmountTrue = game.totalBetAmountTrue;
        uint totalBetAmountFalse = game.totalBetAmountFalse;

        if (totalBetAmountTrue == 0 && totalBetAmountFalse == 0) {
            return (0, 0); // If no bets placed, return 0 odds to indicate no betting activity.
        }

        // Calculate odds as a ratio of total bets on the opposite outcome.
        // These odds can be used to determine payout ratios.
        if (totalBetAmountTrue > 0) {
            oddsTrue =
                ((totalBetAmountFalse + totalBetAmountTrue) * 1e18) /
                totalBetAmountTrue;
        } else {
            oddsTrue = 0;
        }

        if (totalBetAmountFalse > 0) {
            oddsFalse =
                ((totalBetAmountFalse + totalBetAmountTrue) * 1e18) /
                totalBetAmountFalse;
        } else {
            oddsFalse = 0;
        }

        return (oddsTrue, oddsFalse);
    }

    /* PAYOUT - UNFINISHED */
    // just for testing atm, need to change to a withdraw pattern

    function distributePayouts(uint _gameId) public {
        require(
            !games[_gameId].isActive,
            "Game must be finished to distribute payouts."
        );

        Game storage game = games[_gameId];
        require(!game.isAccepted, "Payouts already distributed.");
        game.isAccepted = true; // Ensure this function cannot be called more than once.

        bool outcome = game.outcome; // Assume this is correctly set based on the game's result.
        uint[] storage winnerBetIds = outcome
            ? game.outcomeTrueBets
            : game.outcomeFalseBets;
        uint totalPayoutPool = outcome
            ? game.totalBetAmountFalse
            : game.totalBetAmountTrue;
        uint totalWinningBets = outcome
            ? game.totalBetAmountTrue
            : game.totalBetAmountFalse;

        for (uint i = 0; i < winnerBetIds.length; i++) {
            uint betId = winnerBetIds[i];
            Bet storage bet = bets[betId];
            uint winnerShare = (bet.amount * totalPayoutPool) /
                totalWinningBets;
            pendingWithdrawals[bet.bettor] += winnerShare;
        }
    }

    function withdraw() public {
        uint amount = pendingWithdrawals[msg.sender];
        require(amount > 0, "No funds available for withdrawal.");

        // Reset the withdrawal balance to prevent reentrancy attack
        pendingWithdrawals[msg.sender] = 0;

        // Send the funds
        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "Failed to withdraw funds.");
    }
}

// // Cancel a game, only allowed by contract owner
// function cancelGame(uint _id) public onlyOwner {
//     require(_id <= gameCounter && _id > 0, "Bet ID is invalid");
//     require(games[_id].isActive, "Bet is already inactive");

//     // **need to add logic to refund participants**
//     // **beware of re-entrancy here**

//     games[_id].isActive = false; // Mark the bet as inactive

//     emit GameCancelled(_id);
// }

// // Return number of all bets active in the contract
// function getNumberOfBets() public view returns (uint) {
//     return betCounter;
// }

// // Returns the list of your bets (msg.sender bets)
// function getUserBets() public view returns(Bet[] memory) {
//     uint size = addressToBetId[msg.sender].length;
//     Bet[] memory userBets = new Bet[](size);

//     for(uint i = 0; i < size; i++) {
//         uint index = addressToBetId[msg.sender][i];
//         userBets[i] = bets[index];
//     }
//     return userBets;
// }
