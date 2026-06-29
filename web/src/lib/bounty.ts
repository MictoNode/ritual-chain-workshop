import type { Address } from "viem";

/** Parsed shape of the `getBounty` tuple return value. */
export type Bounty = {
  owner: Address;
  title: string;
  rubric: string;
  reward: bigint;
  submissionDeadline: bigint; // commit only before this
  revealDeadline: bigint; // reveal only in [submissionDeadline, revealDeadline)
  judged: boolean;
  finalized: boolean;
  submissionCount: bigint;
  revealedCount: bigint;
  winnerIndex: bigint;
  aiReview: `0x${string}`;
};

/** getBounty returns a positional tuple — map it to a named object. */
export function parseBounty(
  raw: readonly [
    Address, // owner
    string, // title
    string, // rubric
    bigint, // reward
    bigint, // submissionDeadline
    bigint, // revealDeadline
    boolean, // judged
    boolean, // finalized
    bigint, // submissionCount
    bigint, // revealedCount
    bigint, // winnerIndex
    `0x${string}`, // aiReview
  ],
): Bounty {
  const [
    owner,
    title,
    rubric,
    reward,
    submissionDeadline,
    revealDeadline,
    judged,
    finalized,
    submissionCount,
    revealedCount,
    winnerIndex,
    aiReview,
  ] = raw;
  return {
    owner,
    title,
    rubric,
    reward,
    submissionDeadline,
    revealDeadline,
    judged,
    finalized,
    submissionCount,
    revealedCount,
    winnerIndex,
    aiReview,
  };
}

export type BountyStatus =
  | "submitting" // before submissionDeadline — accepting commitments
  | "revealing" // [submissionDeadline, revealDeadline) — reveal window
  | "ready" // after revealDeadline, not yet judged
  | "judged"
  | "finalized";

export function getBountyStatus(
  b: Bounty,
  nowSeconds = Date.now() / 1000,
): BountyStatus {
  if (b.finalized) return "finalized";
  if (b.judged) return "judged";
  if (Number(b.submissionDeadline) > nowSeconds) return "submitting";
  if (Number(b.revealDeadline) > nowSeconds) return "revealing";
  return "ready";
}

export const STATUS_META: Record<
  BountyStatus,
  { label: string; tone: "green" | "amber" | "indigo" | "zinc" }
> = {
  submitting: { label: "Accepting commitments", tone: "green" },
  revealing: { label: "Reveal open", tone: "amber" },
  ready: { label: "Ready for judging", tone: "indigo" },
  judged: { label: "Judged", tone: "indigo" },
  finalized: { label: "Finalized", tone: "zinc" },
};

/** Can a participant still commit a hidden answer (submission phase)? */
export function canCommit(b: Bounty, nowSeconds = Date.now() / 1000): boolean {
  return !b.judged && !b.finalized && Number(b.submissionDeadline) > nowSeconds;
}

/** Can a participant reveal a committed answer (reveal window)? */
export function canReveal(b: Bounty, nowSeconds = Date.now() / 1000): boolean {
  return (
    !b.judged &&
    !b.finalized &&
    Number(b.submissionDeadline) <= nowSeconds &&
    Number(b.revealDeadline) > nowSeconds
  );
}
