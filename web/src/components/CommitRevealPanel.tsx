"use client";

import { useEffect, useState } from "react";
import { useAccount } from "wagmi";
import { encodePacked, keccak256, toHex, type Address } from "viem";
import { useNow } from "@/hooks/useNow";
import aiJudgeAbi from "@/abi/AIJudge";
import { contractAddress } from "@/config/contract";
import { ritualChain } from "@/config/wagmi";
import { canCommit, canReveal, type Bounty } from "@/lib/bounty";
import { formatTimestamp } from "@/lib/format";
import { useWriteTx } from "@/hooks/useWriteTx";
import {
  Card,
  CardHeader,
  CardBody,
  Field,
  Textarea,
  Button,
  TxStatus,
  Notice,
  Badge,
} from "@/components/ui";

const explorerBase = ritualChain.blockExplorers?.default.url;

type StoredCommit = { answer: string; salt: `0x${string}`; revealed?: boolean };

function storageKey(bountyId: bigint, address: string) {
  return `aijudge:commit:${bountyId.toString()}:${address.toLowerCase()}`;
}

function loadCommit(bountyId: bigint, address?: Address): StoredCommit | null {
  if (!address || typeof window === "undefined") return null;
  try {
    const raw = window.localStorage.getItem(storageKey(bountyId, address));
    return raw ? (JSON.parse(raw) as StoredCommit) : null;
  } catch {
    return null;
  }
}

function saveCommit(bountyId: bigint, address: Address, c: StoredCommit) {
  try {
    window.localStorage.setItem(storageKey(bountyId, address), JSON.stringify(c));
  } catch {
    /* ignore quota / private mode */
  }
}

function randomSalt(): `0x${string}` {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return toHex(bytes);
}

/**
 * Phase-aware commit/reveal panel for a single participant.
 *
 * During the submission phase it collects the answer, builds the commitment hash
 * `keccak256(abi.encodePacked(answer, salt, sender, bountyId))` client-side, and
 * calls `submitCommitment` — the answer never touches the chain. The answer +
 * salt are persisted to localStorage so the same browser can call `revealAnswer`
 * later, in the reveal window.
 */
export function CommitRevealPanel({
  bountyId,
  bounty,
  onChanged,
}: {
  bountyId: bigint;
  bounty: Bounty;
  onChanged: () => void;
}) {
  const { address, isConnected } = useAccount();
  const now = useNow();
  const [answer, setAnswer] = useState("");
  const [stored, setStored] = useState<StoredCommit | null>(null);

  // Load any persisted commitment for this bounty + connected account (client only).
  useEffect(() => {
    setStored(loadCommit(bountyId, address));
  }, [bountyId, address]);

  const commitTx = useWriteTx(() => onChanged());
  const revealTx = useWriteTx(() => {
    if (address && stored) {
      const updated = { ...stored, revealed: true };
      saveCommit(bountyId, address, updated);
      setStored(updated);
    }
    onChanged();
  });

  const inCommit = canCommit(bounty, now);
  const inReveal = canReveal(bounty, now);

  // Nothing actionable for a participant outside the two windows.
  if (!inCommit && !inReveal) return null;

  async function handleCommit(e: React.FormEvent) {
    e.preventDefault();
    if (!answer.trim() || !address || !contractAddress) return;
    const salt = randomSalt();
    const commitment = keccak256(
      encodePacked(
        ["string", "bytes32", "address", "uint256"],
        [answer.trim(), salt, address, bountyId],
      ),
    );
    // Persist BEFORE the tx so a reveal is still possible if the user closes the
    // tab right after the wallet confirms.
    const commit: StoredCommit = { answer: answer.trim(), salt };
    saveCommit(bountyId, address, commit);
    setStored(commit);
    try {
      await commitTx.run({
        address: contractAddress,
        abi: aiJudgeAbi,
        functionName: "submitCommitment",
        args: [bountyId, commitment],
        chainId: ritualChain.id,
      });
    } catch {
      /* surfaced via tx.state */
    }
  }

  async function handleReveal() {
    if (!stored || !contractAddress) return;
    try {
      await revealTx.run({
        address: contractAddress,
        abi: aiJudgeAbi,
        functionName: "revealAnswer",
        args: [bountyId, stored.answer, stored.salt],
        chainId: ritualChain.id,
      });
    } catch {
      /* surfaced via tx.state */
    }
  }

  // ---- Commit phase ----
  if (inCommit) {
    return (
      <Card>
        <CardHeader
          title="Commit your answer"
          subtitle="Only a commitment hash is stored on-chain. Your answer stays hidden until reveal."
          action={<Badge tone="green">Hidden</Badge>}
        />
        <CardBody>
          {stored ? (
            <div className="space-y-3">
              <Notice tone="green">
                Commitment submitted. Your answer + salt are saved in this browser for the
                reveal step.
              </Notice>
              <p className="text-xs text-zinc-500">
                Reveal opens {formatTimestamp(bounty.submissionDeadline)}.
              </p>
            </div>
          ) : (
            <form onSubmit={handleCommit} className="space-y-3">
              <Field
                label="Your answer"
                hint="One entry only. This browser stores what you need to reveal later — don't clear it."
              >
                <Textarea
                  value={answer}
                  onChange={(e) => setAnswer(e.target.value)}
                  rows={5}
                  placeholder="Write your submission…"
                />
              </Field>
              <Button
                type="submit"
                disabled={!isConnected || !answer.trim() || commitTx.isBusy}
                className="w-full"
              >
                {commitTx.isBusy ? "Committing…" : "Commit answer"}
              </Button>
              {!isConnected && (
                <p className="text-xs text-zinc-500">Connect your wallet to commit.</p>
              )}
              <TxStatus
                state={commitTx.state}
                error={commitTx.error}
                hash={commitTx.hash}
                explorerBase={explorerBase}
              />
            </form>
          )}
        </CardBody>
      </Card>
    );
  }

  // ---- Reveal phase ----
  return (
    <Card>
      <CardHeader
        title="Reveal your answer"
        subtitle="Verify your commitment. Revealed answers become public and eligible for judging."
        action={<Badge tone="amber">Reveal open</Badge>}
      />
      <CardBody className="space-y-3">
        {stored ? (
          stored.revealed ? (
            <Notice tone="green">Answer revealed — eligible for judging.</Notice>
          ) : (
            <>
              <Notice tone="zinc">
                Reveal uses the answer + salt saved when you committed. Reveals close{" "}
                {formatTimestamp(bounty.revealDeadline)}.
              </Notice>
              <Button
                onClick={handleReveal}
                disabled={!isConnected || revealTx.isBusy}
                className="w-full"
              >
                {revealTx.isBusy ? "Revealing…" : "Reveal answer"}
              </Button>
              {!isConnected && (
                <p className="text-xs text-zinc-500">Connect your wallet to reveal.</p>
              )}
              <TxStatus
                state={revealTx.state}
                error={revealTx.error}
                hash={revealTx.hash}
                explorerBase={explorerBase}
              />
            </>
          )
        ) : (
          <Notice tone="zinc">
            You didn&apos;t commit during the submission window, so there is nothing to reveal.
          </Notice>
        )}
      </CardBody>
    </Card>
  );
}
