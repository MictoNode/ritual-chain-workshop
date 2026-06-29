// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AIJudgeHarness} from "./AIJudgeHarness.sol";

contract AIJudgeTest is Test {
    AIJudgeHarness judge;
    address owner = address(this);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256 constant SUB_DEADLINE = 1_000_000;
    uint256 constant REVEAL_DEADLINE = 2_000_000;

    function setUp() public {
        judge = new AIJudgeHarness();
        vm.deal(owner, 100 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _commit(address who, string memory answer, bytes32 salt, uint256 bountyId)
        internal
        returns (bytes32 commitment)
    {
        commitment = keccak256(abi.encodePacked(answer, salt, who, bountyId));
        vm.prank(who);
        judge.submitCommitment(bountyId, commitment);
    }

    // ------------------------------------------------------------------
    // createBounty
    // ------------------------------------------------------------------

    function test_CreateBounty_RevertsOnBadDeadlines() public {
        vm.expectRevert("bad reveal deadline");
        judge.createBounty{value: 1 ether}("t", "r", REVEAL_DEADLINE, SUB_DEADLINE);

        vm.expectRevert("bad submission deadline");
        judge.createBounty{value: 1 ether}("t", "r", block.timestamp, REVEAL_DEADLINE);
    }

    // ------------------------------------------------------------------
    // submitCommitment / revealAnswer
    // ------------------------------------------------------------------

    function test_CommitThenReveal_HappyPath() public {
        uint256 id = judge.createBounty{value: 1 ether}("t", "r", SUB_DEADLINE, REVEAL_DEADLINE);
        bytes32 salt = bytes32(uint256(0xC0FFEE));
        bytes32 commitment = _commit(alice, "my answer", salt, id);

        (, bytes32 storedCommit, bool revealed, string memory answer) = judge.getSubmission(id, 0);
        assertEq(storedCommit, commitment);
        assertFalse(revealed);
        assertEq(answer, ""); // hidden until reveal

        vm.warp(SUB_DEADLINE); // reveal window opens
        vm.prank(alice);
        judge.revealAnswer(id, "my answer", salt);

        (, , bool revealedAfter, string memory answerAfter) = judge.getSubmission(id, 0);
        assertTrue(revealedAfter);
        assertEq(answerAfter, "my answer");
        assertEq(judge.revealedCount(id), 1);
    }

    function test_Reveal_WrongAnswer_Reverts() public {
        uint256 id = judge.createBounty{value: 1 ether}("t", "r", SUB_DEADLINE, REVEAL_DEADLINE);
        _commit(alice, "real answer", bytes32(uint256(1)), id);

        vm.warp(SUB_DEADLINE);
        vm.startPrank(alice);
        vm.expectRevert("commitment mismatch");
        judge.revealAnswer(id, "fake answer", bytes32(uint256(1)));
        vm.stopPrank();
    }

    function test_Reveal_WrongSalt_Reverts() public {
        uint256 id = judge.createBounty{value: 1 ether}("t", "r", SUB_DEADLINE, REVEAL_DEADLINE);
        _commit(alice, "answer", bytes32(uint256(1)), id);

        vm.warp(SUB_DEADLINE);
        vm.startPrank(alice);
        vm.expectRevert("commitment mismatch");
        judge.revealAnswer(id, "answer", bytes32(uint256(2)));
        vm.stopPrank();
    }

    function test_Commit_AfterSubmissionDeadline_Reverts() public {
        uint256 id = judge.createBounty{value: 1 ether}("t", "r", SUB_DEADLINE, REVEAL_DEADLINE);
        vm.warp(SUB_DEADLINE); // window closed
        vm.expectRevert("submissions closed");
        _commit(alice, "a", bytes32(0), id);
    }

    function test_Reveal_BeforeWindow_Reverts() public {
        uint256 id = judge.createBounty{value: 1 ether}("t", "r", SUB_DEADLINE, REVEAL_DEADLINE);
        _commit(alice, "a", bytes32(0), id);
        // still in submission phase
        vm.prank(alice);
        vm.expectRevert("reveal not open");
        judge.revealAnswer(id, "a", bytes32(0));
    }

    function test_Reveal_AfterRevealDeadline_Reverts() public {
        uint256 id = judge.createBounty{value: 1 ether}("t", "r", SUB_DEADLINE, REVEAL_DEADLINE);
        _commit(alice, "a", bytes32(0), id);
        vm.warp(REVEAL_DEADLINE);
        vm.prank(alice);
        vm.expectRevert("reveal closed");
        judge.revealAnswer(id, "a", bytes32(0));
    }

    function test_DoubleCommit_Reverts() public {
        uint256 id = judge.createBounty{value: 1 ether}("t", "r", SUB_DEADLINE, REVEAL_DEADLINE);
        _commit(alice, "a", bytes32(0), id);
        vm.prank(alice);
        vm.expectRevert("already committed");
        judge.submitCommitment(id, bytes32(uint256(999)));
    }

    function test_CommitmentCopyAttack_OtherSenderCannotReveal() public {
        uint256 id = judge.createBounty{value: 1 ether}("t", "r", SUB_DEADLINE, REVEAL_DEADLINE);
        bytes32 salt = bytes32(uint256(7));
        bytes32 commitment = keccak256(abi.encodePacked("secret", salt, alice, id));

        // alice commits during the submission phase
        vm.prank(alice);
        judge.submitCommitment(id, commitment);

        // bob sees alice's commitment on-chain and copies it verbatim, also
        // during the submission phase (before the window closes)
        vm.prank(bob);
        judge.submitCommitment(id, commitment);

        // reveal phase: bob tries to reveal alice's answer. sender (bob) is bound
        // into the hash, so it cannot match alice's commitment.
        vm.warp(SUB_DEADLINE);
        vm.startPrank(bob);
        vm.expectRevert("commitment mismatch");
        judge.revealAnswer(id, "secret", salt);
        vm.stopPrank();

        // and a non-committer cannot reveal at all
        address carol = address(0xCA401);
        vm.startPrank(carol);
        vm.expectRevert("no commitment");
        judge.revealAnswer(id, "secret", salt);
        vm.stopPrank();
    }

    function test_Reveal_TooLongAnswer_Reverts() public {
        uint256 id = judge.createBounty{value: 1 ether}("t", "r", SUB_DEADLINE, REVEAL_DEADLINE);
        bytes memory long = new bytes(2001);
        _commit(alice, string(long), bytes32(0), id);

        vm.warp(SUB_DEADLINE);
        vm.startPrank(alice);
        vm.expectRevert("answer too long");
        judge.revealAnswer(id, string(long), bytes32(0));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // helpers + judgeAll / finalizeWinner
    // ------------------------------------------------------------------

    function _reveal(address who, string memory answer, bytes32 salt, uint256 bountyId)
        internal
    {
        vm.warp(SUB_DEADLINE);
        vm.prank(who);
        judge.revealAnswer(bountyId, answer, salt);
    }

    function _fullBountyOneReveal() internal returns (uint256 id) {
        id = judge.createBounty{value: 1 ether}("t", "r", SUB_DEADLINE, REVEAL_DEADLINE);
        _commit(alice, "answer", bytes32(uint256(1)), id);
        _reveal(alice, "answer", bytes32(uint256(1)), id);
    }

    function test_JudgeAll_BeforeRevealDeadline_Reverts() public {
        uint256 id = _fullBountyOneReveal();
        vm.warp(REVEAL_DEADLINE - 1); // reveal phase still open
        vm.expectRevert("reveal phase open");
        judge.judgeAll(id, bytes(""));
    }

    function test_JudgeAll_NoRevealed_Reverts() public {
        uint256 id = judge.createBounty{value: 1 ether}("t", "r", SUB_DEADLINE, REVEAL_DEADLINE);
        _commit(alice, "a", bytes32(0), id); // committed but not revealed
        vm.warp(REVEAL_DEADLINE);
        vm.expectRevert("no revealed submissions");
        judge.judgeAll(id, bytes(""));
    }

    function test_JudgeAll_NotOwner_Reverts() public {
        uint256 id = _fullBountyOneReveal();
        vm.warp(REVEAL_DEADLINE);
        vm.prank(alice);
        vm.expectRevert("not bounty owner");
        judge.judgeAll(id, bytes(""));
    }

    function test_JudgeAll_HappyPath_StoresAiReview() public {
        uint256 id = _fullBountyOneReveal();
        judge.setLlmResult(false, bytes("LLM SAYS 0"));
        vm.warp(REVEAL_DEADLINE);
        judge.judgeAll(id, bytes("llmInput"));

        (, , , , , , bool judged, , , , , ) = judge.getBounty(id);
        assertTrue(judged);
    }

    function test_Finalize_BeforeJudge_Reverts() public {
        uint256 id = _fullBountyOneReveal();
        vm.warp(REVEAL_DEADLINE);
        vm.expectRevert("not judged yet");
        judge.finalizeWinner(id, 0);
    }

    function test_Finalize_UnrevealedIndex_Reverts() public {
        uint256 id = judge.createBounty{value: 1 ether}("t", "r", SUB_DEADLINE, REVEAL_DEADLINE);
        // commit both BEFORE any reveal (reveal warps time forward past the
        // submission window)
        _commit(alice, "a", bytes32(uint256(1)), id); // index 0
        _commit(bob, "b", bytes32(uint256(2)), id); // index 1, NOT revealed
        _reveal(alice, "a", bytes32(uint256(1)), id);

        judge.setLlmResult(false, bytes("ok"));
        vm.warp(REVEAL_DEADLINE);
        judge.judgeAll(id, bytes("in"));

        vm.expectRevert("winner not revealed");
        judge.finalizeWinner(id, 1);
    }

    function test_Finalize_HappyPath_PaysWinner() public {
        uint256 id = _fullBountyOneReveal();
        judge.setLlmResult(false, bytes("ok"));
        vm.warp(REVEAL_DEADLINE);
        judge.judgeAll(id, bytes("in"));

        uint256 before = alice.balance;
        judge.finalizeWinner(id, 0);

        assertEq(alice.balance - before, 1 ether);
        // getBounty returns: owner,title,rubric,reward,subDeadline,revealDeadline,
        //                    judged,finalized,subCount,revealedCount,winnerIndex,aiReview
        (, , , uint256 reward, , , , bool finalized, , , uint256 winnerIndex, ) =
            judge.getBounty(id);
        assertTrue(finalized);
        assertEq(winnerIndex, 0);
        assertEq(reward, 0);
    }
}
