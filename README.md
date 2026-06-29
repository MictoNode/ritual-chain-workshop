# Privacy-Preserving AI Bounty Judge (Commit-Reveal)

Extends the Ritual workshop `AIJudge` so bounty answers stay **hidden during the
submission phase** and are revealed only after the reveal deadline, right before
Ritual AI batch-judges them. Closes the "copy an earlier answer and resubmit" flaw.

## What this submission covers

- **Required track — implemented:** commit-reveal `AIJudge` with the four mandated
  functions, two deadlines, `salt`/`sender`/`bountyId` binding, reveal-window +
  eligibility enforcement, and human-in-the-loop finalization. 17 Solidity unit
  tests pass (`hardhat test`).
- **Advanced track — design document** (the homework explicitly permits a design
  doc): a Ritual TEE-native variant where answers stay encrypted until inside the
  enclave, judged in one batch, with an off-chain reveal bundle committed on-chain
  by hash. See `docs/architecture.md`.
- **Reflection** (5–8 sentences) in `docs/architecture.md`.

## Lifecycle

```
owner.createBounty(title, rubric, submissionDeadline, revealDeadline) {value: reward}
        |
        |  submission phase (now .. submissionDeadline): answers HIDDEN
        v
participant.submitCommitment(bountyId, keccak256(abi.encodePacked(answer, salt, sender, bountyId)))
        |
        |  submissionDeadline .. revealDeadline: reveal window
        v
participant.revealAnswer(bountyId, answer, salt)   // contract verifies the hash
        |
        |  after revealDeadline
        v
owner.getRevealedAnswers(bountyId)   // off-chain: build ONE batch LLM input
owner.judgeAll(bountyId, llmInput)   // single Ritual LLM call, all revealed answers
        |
        v
owner.finalizeWinner(bountyId, winnerIndex)   // human-in-the-loop; pays the winner
```

During the submission phase the only thing on-chain per participant is a 32-byte
`commitment`. The plaintext `answer` is stored only after a valid `revealAnswer`,
which happens in the reveal window (after the submission deadline). A participant
who never reveals is simply ineligible — their answer is never stored or judged.

## Commitment formula (required)

```solidity
bytes32 commitment = keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId));
```

`msg.sender` and `bountyId` are bound in, so a commitment copied from another
participant or another bounty cannot be revealed by anyone else.

## Contract API (changes from workshop baseline)

- `createBounty(title, rubric, submissionDeadline, revealDeadline) payable` — was
  `createBounty(title, rubric, deadline)`. Two deadlines now.
- `submitCommitment(bountyId, bytes32 commitment)` — replaces `submitAnswer`.
- `revealAnswer(bountyId, string answer, bytes32 salt)` — new.
- `judgeAll(bountyId, bytes llmInput)` — unchanged signature; now requires
  `block.timestamp >= revealDeadline` and `revealedCount > 0`.
- `finalizeWinner(bountyId, uint256 winnerIndex)` — unchanged signature; now
  requires `submissions[winnerIndex].revealed`.
- `getSubmission` now returns `(submitter, commitment, revealed, answer)`.
- `getBounty` now returns the two deadlines and `revealedCount`.
- New view `getRevealedAnswers(bountyId)` returns revealed answers + indices for
  building the batch LLM input.

> Frontend note: the `web/` app still imports the old ABI (`submitAnswer`, single
> `deadline`). To use the new flow from the UI, regenerate the ABI from
> `hardhat/contracts/AIJudge.sol` and add commit/reveal UI. Out of scope for this
> submission.

## Build & test

```bash
cd hardhat
pnpm install
pnpm hardhat test solidity     # commit-reveal + judge/finalize unit tests
pnpm hardhat test              # everything
```

> `viaIR: true` + optimizer are enabled in `hardhat.config.ts` (required to compile
> the 12-field `getBounty` return tuple without "stack too deep"). `hardhat/
> pnpm-workspace.yaml` allows the esbuild postinstall build.

> **Ritual timestamp quirk:** Ritual's `block.timestamp` is in **milliseconds**,
> not seconds. The frontend therefore sends submission/reveal deadlines as ms
> (`Date.getTime()`) and all in-app time comparisons use ms, so they line up with
> the on-chain timestamp. The contract itself is unit-agnostic (it compares the
> passed deadline to `block.timestamp`), so this is purely a frontend convention.

### LLM precompile testing limitation

`judgeAll` calls the Ritual LLM inference precompile (`address(0x0802)`), which
exists only on the Ritual chain. Unit tests use `AIJudgeHarness` (in
`hardhat/test/`) to stub that call via the `_runLlmInference` virtual seam, so the
full commit → reveal → judge → finalize lifecycle is testable on the Hardhat EDR
simulator. Live LLM judging is verified by deploying to the Ritual testnet.

## Deploy

```bash
cd hardhat
pnpm hardhat ignition deploy ignition/modules/AIJudge.ts --network ritual
```

(`DEPLOYER_PRIVATE_KEY` configured via keystore or env; network `ritual` is in
`hardhat.config.ts`, `chainId 1979`, `https://rpc.ritualfoundation.org`.)

## See also

- `docs/architecture.md` — commit-reveal vs Ritual-native (Advanced) design, and
  the reflection answer.
