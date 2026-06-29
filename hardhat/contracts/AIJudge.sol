// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PrecompileConsumer} from "./utils/PrecompileConsumer.sol";

interface IRitualWallet {
    function deposit(uint256 lockDuration) external payable;

    function depositFor(address user, uint256 lockDuration) external payable;

    function withdraw(uint256 amount) external;

    function balanceOf(address) external view returns (uint256);

    function lockUntil(address) external view returns (uint256);
}

contract AIJudge is PrecompileConsumer {
    uint256 public constant MAX_SUBMISSIONS = 10;
    uint256 public constant MAX_ANSWER_LENGTH = 2_000;

    uint256 public nextBountyId = 1;

    IRitualWallet wallet =
        IRitualWallet(0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948);

    struct Submission {
        address submitter;
        bytes32 commitment; // keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))
        string answer; // "" until reveal (plaintext hidden during submission phase)
        bytes32 salt; // set at reveal
        bool revealed; // set true at reveal
    }

    struct Bounty {
        address owner;
        string title;
        string rubric;
        uint256 reward;
        uint256 submissionDeadline; // commit only before this
        uint256 revealDeadline; // reveal only in [submissionDeadline, revealDeadline)
        bool judged;
        bool finalized;
        bytes aiReview;
        uint256 winnerIndex;
        Submission[] submissions;
    }

    struct ConvoHistory {
        string storageType;
        string path;
        string secretsName;
    }

    mapping(uint256 => Bounty) public bounties;

    // bountyId => submitter => (array index + 1). 0 means "no commitment".
    mapping(uint256 => mapping(address => uint256)) internal submitterIndex;

    event BountyCreated(
        uint256 indexed bountyId,
        address indexed owner,
        string title,
        uint256 reward,
        uint256 submissionDeadline,
        uint256 revealDeadline
    );

    event CommitmentSubmitted(
        uint256 indexed bountyId,
        uint256 indexed submissionIndex,
        address indexed submitter,
        bytes32 commitment
    );

    event AnswerRevealed(
        uint256 indexed bountyId,
        uint256 indexed submissionIndex,
        address indexed submitter
    );

    event AllAnswersJudged(uint256 indexed bountyId, bytes aiReview);

    event WinnerFinalized(
        uint256 indexed bountyId,
        uint256 indexed winnerIndex,
        address indexed winner,
        uint256 reward
    );

    modifier onlyOwner(uint256 bountyId) {
        require(msg.sender == bounties[bountyId].owner, "not bounty owner");
        _;
    }

    modifier bountyExists(uint256 bountyId) {
        require(bounties[bountyId].owner != address(0), "bounty not found");
        _;
    }

    function createBounty(
        string calldata title,
        string calldata rubric,
        uint256 submissionDeadline,
        uint256 revealDeadline
    ) external payable returns (uint256 bountyId) {
        require(msg.value > 0, "reward required");
        require(submissionDeadline > block.timestamp, "bad submission deadline");
        require(revealDeadline > submissionDeadline, "bad reveal deadline");

        bountyId = nextBountyId++;

        Bounty storage bounty = bounties[bountyId];
        bounty.owner = msg.sender;
        bounty.title = title;
        bounty.rubric = rubric;
        bounty.reward = msg.value;
        bounty.submissionDeadline = submissionDeadline;
        bounty.revealDeadline = revealDeadline;
        bounty.winnerIndex = type(uint256).max;

        emit BountyCreated(
            bountyId,
            msg.sender,
            title,
            msg.value,
            submissionDeadline,
            revealDeadline
        );
    }

    function submitCommitment(uint256 bountyId, bytes32 commitment)
        external
        bountyExists(bountyId)
    {
        Bounty storage bounty = bounties[bountyId];
        require(block.timestamp < bounty.submissionDeadline, "submissions closed");
        require(!bounty.judged, "already judged");
        require(!bounty.finalized, "already finalized");
        require(submitterIndex[bountyId][msg.sender] == 0, "already committed");
        require(bounty.submissions.length < MAX_SUBMISSIONS, "too many submissions");

        bounty.submissions.push(
            Submission({
                submitter: msg.sender,
                commitment: commitment,
                answer: "",
                salt: 0,
                revealed: false
            })
        );
        // store index + 1 so the value 0 still means "no commitment"
        submitterIndex[bountyId][msg.sender] = bounty.submissions.length;

        emit CommitmentSubmitted(
            bountyId,
            bounty.submissions.length - 1,
            msg.sender,
            commitment
        );
    }

    function revealAnswer(uint256 bountyId, string calldata answer, bytes32 salt)
        external
        bountyExists(bountyId)
    {
        Bounty storage bounty = bounties[bountyId];
        require(block.timestamp >= bounty.submissionDeadline, "reveal not open");
        require(block.timestamp < bounty.revealDeadline, "reveal closed");
        require(bytes(answer).length <= MAX_ANSWER_LENGTH, "answer too long");

        uint256 idxPlusOne = submitterIndex[bountyId][msg.sender];
        require(idxPlusOne != 0, "no commitment");
        uint256 index = idxPlusOne - 1;

        Submission storage sub = bounty.submissions[index];
        require(!sub.revealed, "already revealed");
        require(
            keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId)) ==
                sub.commitment,
            "commitment mismatch"
        );

        sub.answer = answer;
        sub.salt = salt;
        sub.revealed = true;

        emit AnswerRevealed(bountyId, index, msg.sender);
    }

    function judgeAll(uint256 bountyId, bytes calldata llmInput)
        external
        bountyExists(bountyId)
        onlyOwner(bountyId)
    {
        Bounty storage bounty = bounties[bountyId];
        require(block.timestamp >= bounty.revealDeadline, "reveal phase open");
        require(!bounty.judged, "already judged");
        require(!bounty.finalized, "already finalized");
        require(revealedCount(bountyId) > 0, "no revealed submissions");

        bytes memory output = _runLlmInference(llmInput);

        (
            bool hasError,
            bytes memory completionData,
            ,
            string memory errorMessage,

        ) = abi.decode(output, (bool, bytes, bytes, string, ConvoHistory));

        require(!hasError, errorMessage);

        bounty.judged = true;
        bounty.aiReview = completionData;

        emit AllAnswersJudged(bountyId, completionData);
    }

    function finalizeWinner(uint256 bountyId, uint256 winnerIndex)
        external
        bountyExists(bountyId)
        onlyOwner(bountyId)
    {
        Bounty storage bounty = bounties[bountyId];
        require(bounty.judged, "not judged yet");
        require(!bounty.finalized, "already finalized");
        require(winnerIndex < bounty.submissions.length, "invalid index");
        require(bounty.submissions[winnerIndex].revealed, "winner not revealed");

        bounty.finalized = true;
        bounty.winnerIndex = winnerIndex;

        address winner = bounty.submissions[winnerIndex].submitter;
        uint256 reward = bounty.reward;
        bounty.reward = 0;

        (bool ok, ) = payable(winner).call{value: reward}("");
        require(ok, "payment failed");

        emit WinnerFinalized(bountyId, winnerIndex, winner, reward);
    }

    /// @dev Virtual seam: unit tests override this to stub the Ritual-only LLM
    /// precompile (address(0x0802)), which exists only on the Ritual chain.
    /// Production behavior is identical to the base implementation.
    function _runLlmInference(bytes calldata llmInput)
        internal
        virtual
        returns (bytes memory)
    {
        return _executePrecompile(LLM_INFERENCE_PRECOMPILE, llmInput);
    }

    function revealedCount(uint256 bountyId) public view returns (uint256 count) {
        Bounty storage bounty = bounties[bountyId];
        uint256 len = bounty.submissions.length;
        for (uint256 i = 0; i < len; i++) {
            if (bounty.submissions[i].revealed) {
                count++;
            }
        }
    }

    function getBounty(uint256 bountyId)
        external
        view
        bountyExists(bountyId)
        returns (
            address owner,
            string memory title,
            string memory rubric,
            uint256 reward,
            uint256 submissionDeadline,
            uint256 revealDeadline,
            bool judged,
            bool finalized,
            uint256 submissionCount,
            uint256 _revealedCount,
            uint256 winnerIndex,
            bytes memory aiReview
        )
    {
        Bounty storage bounty = bounties[bountyId];
        return (
            bounty.owner,
            bounty.title,
            bounty.rubric,
            bounty.reward,
            bounty.submissionDeadline,
            bounty.revealDeadline,
            bounty.judged,
            bounty.finalized,
            bounty.submissions.length,
            revealedCount(bountyId),
            bounty.winnerIndex,
            bounty.aiReview
        );
    }

    function getSubmission(uint256 bountyId, uint256 index)
        external
        view
        bountyExists(bountyId)
        returns (
            address submitter,
            bytes32 commitment,
            bool revealed,
            string memory answer
        )
    {
        Bounty storage bounty = bounties[bountyId];
        require(index < bounty.submissions.length, "invalid index");
        Submission storage sub = bounty.submissions[index];
        return (sub.submitter, sub.commitment, sub.revealed, sub.answer);
    }

    /// @notice Returns all revealed answers (and their submission indices) in
    /// submission order. The bounty owner builds the single batch LLM input from
    /// this list before calling judgeAll.
    function getRevealedAnswers(uint256 bountyId)
        external
        view
        bountyExists(bountyId)
        returns (string[] memory answers, uint256[] memory indices)
    {
        Bounty storage bounty = bounties[bountyId];
        uint256 len = bounty.submissions.length;
        uint256 rc = revealedCount(bountyId);
        answers = new string[](rc);
        indices = new uint256[](rc);
        uint256 j;
        for (uint256 i = 0; i < len; i++) {
            if (bounty.submissions[i].revealed) {
                answers[j] = bounty.submissions[i].answer;
                indices[j] = i;
                j++;
            }
        }
    }
}
