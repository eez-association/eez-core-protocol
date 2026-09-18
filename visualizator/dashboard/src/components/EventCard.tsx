import React, { useState } from "react";
import { COLORS } from "../theme";
import type { EventRecord } from "../types/events";
import { truncateHex, truncateAddress } from "../lib/actionFormatter";
import { TxDetails } from "./TxDetails";

type Props = {
  event: EventRecord;
  selected: boolean;
  onClick: () => void;
  correlatedChain?: "l1" | "l2";
  stepNumber: number;
  isPlayed: boolean;
};

const EVENT_COLORS: Record<string, string> = {
  BatchPosted: COLORS.l1,
  ExecutionTableLoaded: COLORS.l2,
  ExecutionConsumed: COLORS.rm,
  CrossChainCallExecuted: COLORS.add,
  CrossChainProxyCreated: COLORS.ok,
  RollupCreated: COLORS.acc,
  RollupContractChanged: COLORS.warn,
  L2TXExecuted: COLORS.warn,
  ImmediateEntrySkipped: COLORS.warn,
  CallResult: COLORS.dim,
  NestedActionConsumed: COLORS.add,
  EntryExecuted: COLORS.ok,
  RevertSpanExecuted: COLORS.warn,
};

function eventColor(eventName: string): string {
  return EVENT_COLORS[eventName] ?? COLORS.dim;
}

function eventDetail(event: EventRecord): string {
  switch (event.eventName) {
    case "BatchPosted":
      return `Posts ${String(event.args.rollupCount ?? 0)} ${(event.args.rollupCount ?? 0n) === 1n ? "rollup" : "rollups"} to L1`;
    case "ExecutionTableLoaded": {
      const entries = event.args.entries as unknown[] | undefined;
      return entries ? `Loads ${entries.length} ${entries.length === 1 ? "entry" : "entries"} into L2 table` : "";
    }
    case "ExecutionConsumed":
      return `Entry consumed: ${truncateHex(event.args.crossChainCallHash as string)} (rollup ${String(event.args.rollupId ?? "")} cursor ${String(event.args.cursor ?? "")})`;
    case "CrossChainCallExecuted":
      return `Proxy ${truncateAddress(event.args.proxy as string)} called by ${truncateAddress(event.args.sourceAddress as string)}`;
    case "CrossChainProxyCreated":
      return `Proxy ${truncateAddress(event.args.proxy as string)} for ${truncateAddress(event.args.originalAddress as string)}`;
    case "RollupCreated":
      return `Rollup ${String(event.args.rollupId)} created`;
    case "RollupContractChanged":
      return `Rollup ${String(event.args.rollupId)} contract updated`;
    case "ImmediateEntrySkipped":
      return `Immediate entry @ ${String(event.args.transientIdx ?? "")} skipped`;
    case "L2TXExecuted":
      return `L2TX rollup ${String(event.args.rollupId ?? "")} cursor ${String(event.args.cursor ?? "")}`;
    case "CallResult":
      return `Call #${String(event.args.callNumber ?? "")} ${event.args.success ? "success" : "failed"}`;
    case "EntryExecuted":
      return `Entry #${String(event.args.entryIndex ?? "")} executed (${String(event.args.callsProcessed ?? 0)} calls)`;
    default:
      return "";
  }
}

function tableChangeSummary(event: EventRecord): { adds: string[]; consumes: string[] } {
  const adds: string[] = [];
  const consumes: string[] = [];
  // TODO(user-decision): post-refactor BatchPosted no longer carries entries;
  // table change summary for L1 batches must be sourced elsewhere (tx input decode).
  if (event.eventName === "ExecutionTableLoaded") {
    const entries = event.args.entries as unknown[] | undefined;
    if (entries) {
      for (let i = 0; i < entries.length; i++) {
        adds.push(`+${event.chain.toUpperCase()}`);
      }
    }
  }
  if (event.eventName === "ExecutionConsumed") {
    consumes.push(`-${event.chain.toUpperCase()}`);
  }
  return { adds, consumes };
}

export const EventCard: React.FC<Props> = ({
  event,
  selected,
  onClick,
  correlatedChain,
  stepNumber,
  isPlayed,
}) => {
  const [expanded, setExpanded] = useState(false);
  const chainColor = event.chain === "l1" ? COLORS.l1 : COLORS.l2;
  const chainBg = event.chain === "l1" ? COLORS.l1bg : COLORS.l2bg;
  const chainBorder = event.chain === "l1" ? COLORS.l1b : COLORS.l2b;
  const detail = eventDetail(event);
  const { adds, consumes } = tableChangeSummary(event);

  // Style matching index.html .si
  const opacity = selected ? 1 : isPlayed ? 0.65 : 0.25;

  return (
    <div
      onClick={onClick}
      style={{
        display: "flex",
        gap: 8,
        padding: "6px 8px",
        borderRadius: 6,
        border: `1px solid ${selected ? COLORS.acc : "transparent"}`,
        background: selected ? COLORS.s2 : COLORS.s1,
        marginBottom: 4,
        cursor: "pointer",
        transition: "all 0.15s",
        opacity,
        fontSize: "0.63rem",
        lineHeight: 1.45,
      }}
    >
      {/* Step number */}
      <div
        style={{
          width: 17,
          height: 17,
          borderRadius: "50%",
          background: selected ? COLORS.acc : COLORS.s3,
          color: selected ? "#fff" : COLORS.dim,
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          fontSize: "0.5rem",
          fontWeight: 700,
          flexShrink: 0,
          marginTop: 2,
        }}
      >
        {stepNumber}
      </div>

      {/* Chain badge */}
      <div
        style={{
          flexShrink: 0,
          padding: "1px 5px",
          borderRadius: 3,
          fontSize: "0.5rem",
          fontWeight: 700,
          marginTop: 2,
          background: chainBg,
          color: chainColor,
          border: `1px solid ${chainBorder}`,
        }}
      >
        {event.chain.toUpperCase()}
      </div>

      {/* Body */}
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontWeight: 700, color: eventColor(event.eventName) }}>
          {event.eventName}
        </div>
        {detail && (
          <div style={{ color: COLORS.dim, fontSize: "0.55rem" }}>
            {detail}
          </div>
        )}

        {/* Table change summary */}
        {(adds.length > 0 || consumes.length > 0) && (
          <div style={{ marginTop: 2, fontSize: "0.52rem" }}>
            {adds.map((a, i) => (
              <span key={`a${i}`} style={{ color: COLORS.add, marginRight: 4 }}>
                {a}
              </span>
            ))}
            {consumes.map((c, i) => (
              <span key={`c${i}`} style={{ color: COLORS.rm, marginRight: 4 }}>
                {c} consumed
              </span>
            ))}
          </div>
        )}

        {/* Cross-chain correlation */}
        {correlatedChain && event.eventName === "ExecutionConsumed" && (
          <div style={{ fontSize: "0.52rem", color: COLORS.warn, marginTop: 2 }}>
            {"<->"} Matched on {correlatedChain.toUpperCase()} (same crossChainCallHash)
          </div>
        )}

        {/* Expand tx details */}
        {event.eventName === "ExecutionConsumed" && (
          <div style={{ marginTop: 3 }}>
            <button
              onClick={(e) => {
                e.stopPropagation();
                setExpanded(!expanded);
              }}
              style={{
                fontSize: "0.5rem",
                color: COLORS.acc,
                background: "none",
                border: "none",
                cursor: "pointer",
                padding: 0,
                fontFamily: "monospace",
              }}
            >
              {expanded ? "\u25BC Hide tx details" : "\u25B6 Show tx details"}
            </button>
            {expanded && (
              <TxDetails
                txHash={event.transactionHash}
                chain={event.chain}
              />
            )}
          </div>
        )}
      </div>
    </div>
  );
};
