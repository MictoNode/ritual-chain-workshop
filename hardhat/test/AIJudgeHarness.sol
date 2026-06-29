// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AIJudge} from "../contracts/AIJudge.sol";

/// @dev Test-only subclass that stubs the Ritual LLM precompile so judgeAll /
/// finalizeWinner can be unit-tested on the Hardhat EDR sim (no Ritual chain).
contract AIJudgeHarness is AIJudge {
    bool public llmHasError;
    bytes public llmCompletion;

    function _runLlmInference(bytes calldata) internal override returns (bytes memory) {
        // matches the decode tuple in AIJudge.judgeAll:
        // (bool hasError, bytes completionData, bytes, string errorMessage, ConvoHistory)
        return abi.encode(
            llmHasError,
            llmCompletion,
            bytes(""),
            "",
            ConvoHistory({storageType: "", path: "", secretsName: ""})
        );
    }

    function setLlmResult(bool hasError, bytes memory completion) external {
        llmHasError = hasError;
        llmCompletion = completion;
    }
}
