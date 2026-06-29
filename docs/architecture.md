# Architecture: Commit-Reveal vs Ritual-Native Hidden Submissions

This note covers the **Required track** (implemented) and the **Advanced track**
(Ritual-native, design only — full implementation is out of scope per the
homework, which permits a design document).

## Required track — commit-reveal (implemented in `AIJudge.sol`)

| Phase | What is public on-chain | What is hidden |
|---|---|---|
| Submission (now .. submissionDeadline) | 32-byte `commitment` per participant | plaintext `answer`, `salt` |
| Reveal (submissionDeadline .. revealDeadline) | revealed `answer` + `salt` | answers of participants who have not yet revealed |
| After revealDeadline | all revealed answers | nothing (unrevealed answers were never stored) |

**Where plaintext exists:** only in the participant's own memory until they call
`revealAnswer`. From that point it is on-chain and public — which is the intent of
the Required track (answers become visible only *after* the submission window
closes, so no one can copy during submission).

**Batch judging:** the owner reads `getRevealedAnswers(bountyId)` and builds a
single LLM input containing all revealed answers + the rubric. `judgeAll` makes
**one** Ritual LLM call (never one per answer). The contract cannot verify the
opaque `llmInput` bytes match the revealed answers — the safety boundary is the
human-in-the-loop `finalizeWinner`, which additionally requires the chosen index
to be `revealed`.

**Limitation:** answers are public *before* AI judging. The Advanced track removes
even that.

## Advanced track — Ritual-native encrypted submissions (design)

Goal: keep answers hidden **until judging is complete** using Ritual's TEE-backed
execution.

### Private submission flow (diagram)

```
[Participant]              [Contract]                 [Ritual TEE]
     |                         |                            |
     | 1. encrypt answer for   |                            |
     |    TEE pubkey           |                            |
     |--- submitCommitment --->| stores encryptedAnswerRef  |
     |    (encryptedAnswerRef) | only — NO plaintext        |
     |                         | on chain                   |
     |                         |                            |
     |        ... reveal deadline passes ...                |
     |                         |                            |
     |                         | 2. owner judgeAll -------> | 3. decrypt ALL answers
     |                         |    (ONE batch LLM request) |    INSIDE the enclave,
     |                         |                            |    feed to the LLM
     |                         |                            |    together
     |                         |<-- ranking + ref/hash ---- | 4. only the result
     |                         | stores revealedAnswersHash |    leaves the enclave
     |                         |                            |    (plaintext never does)
     |                         |                            |
     | 5. owner finalizeWinner |                            |
     |    (human-in-the-loop)->| pays the winner            |
     |                         |                            |
  [Anyone]  6. the published off-chain reveal bundle is auditable against the on-chain
             revealedAnswersHash
```

### Flow

1. Each participant encrypts their answer for a Ritual TEE executor (Ritual key
   flow / encrypted secret). Only the encrypted blob (or a storage reference to it)
   is sent on-chain.
2. The contract stores only `encryptedAnswerRef` (e.g. an IPFS/storage ref) per
   submission — never plaintext.
3. Before judging, neither other participants nor the public can read plaintext.
4. During `judgeAll`, the TEE workflow decrypts all answers **inside** the enclave,
   feeds them to the LLM in one batch, and returns only the ranking/winner (and an
   optional `revealedAnswersRef` + `revealedAnswersHash`).
5. After judging, the system reveals the winner and publishes a revealed-answers
   bundle off-chain; the contract stores only the bundle's hash.

### Where plaintext exists, and who can read it

- **Participant's device** — always (they wrote it).
- **TEE enclave only**, during the single judging call — decrypted inside the
  enclave, never exposed to the public chain or to the contract caller.
- **After reveal** — published via the off-chain bundle, verifiable against the
  on-chain hash.

No one outside the TEE sees plaintext before the post-judging reveal.

### On-chain vs off-chain

| Stored on-chain | Stored off-chain |
|---|---|
| `encryptedAnswerRef` per submission | encrypted answer blob (IPFS/storage) |
| `revealedAnswersHash` (after judging) | revealed-answers bundle |
| winner index, ranking hash | full LLM output / reasons |

This avoids storing large plaintext on-chain (gas) while keeping a verifiable
commitment to the revealed result.

### How the LLM receives all submissions together

The TEE workflow reads every `encryptedAnswerRef` for the bounty, decrypts each
inside the enclave, assembles one prompt (rubric + all plaintext answers), and
makes a single LLM call. One request judges the whole bounty — satisfying the
"batch, not one call per answer" requirement.

### Final reveal + contract verification

After judging, the owner publishes the revealed-answers bundle off-chain and calls
the contract with `revealedAnswersRef` + `revealedAnswersHash`. The contract does
NOT trust the hash blindly for payout — the owner still calls
`finalizeWinner(winnerIndex)` (human-in-the-loop). The hash lets anyone later audit
that the published bundle matches what judging used.

### Example final output shape

The TEE judging workflow returns a compact result; only the bundle reference/hash
touches the chain:

```json
{
  "winnerIndex": 2,
  "ranking": [{ "index": 2, "score": 94, "reason": "Best satisfies the rubric." }],
  "revealedAnswersRef": "ipfs://... or storage-ref://...",
  "revealedAnswersHash": "0x...",
  "summary": "Submission 2 is the strongest answer."
}
```

`revealedAnswersHash` is committed on-chain (e.g. via a `publishRevealBundle`
setter that stores it on the bounty) so the off-chain bundle is auditable: anyone
re-hashes the published bundle and checks it against the on-chain value. The owner
then calls `finalizeWinner(winnerIndex)` to move funds — the hash never auto-pays.

### Why the Required track does not do this

Commit-reveal works on any EVM chain with no trusted hardware, but reveals answers
before judging. The Ritual-native design hides answers through judging but depends
on the TEE attestation and Ritual's key/secret flow. The two trade off portability
against maximal secrecy.

## Reflection: what should be public, hidden, AI-decided, or human-decided?

Commitments, deadlines, and the winner should be public so anyone can audit that
the bounty ran fairly and that the reward was paid. Raw answers and salts should
stay hidden at least until the submission window closes (Required track) and,
ideally, until judging is complete (Advanced track), so no participant gains an
information advantage. The rubric must be public from the start so everyone knows
how they will be scored. Scoring and ranking are a good fit for AI: comparing many
answers against a fixed rubric in one batch is exactly what an LLM does well, and
batch judging hides individual timing. But the final payout should stay a human
decision — the owner reviews the AI ranking and calls `finalizeWinner`, because an
AI can hallucinate or misread, and money should not move on an unreviewed model
output. Eligibility rules (valid reveal, deadlines, single winner) are neither
public debate nor AI judgment — they are hard contract invariants enforced in code.
