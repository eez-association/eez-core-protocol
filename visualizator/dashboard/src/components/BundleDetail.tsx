import React, { useState, useMemo, useCallback, useEffect } from "react";
import { COLORS } from "../theme";
import { useStore } from "../store";
import type { TransactionBundle } from "../types/visualization";
import { buildBundleSteps, type BundleStep } from "../lib/callFlowBuilder";
import { ArchitectureDiagram } from "./ArchitectureDiagram";
import { buildBundleArchitecture, type StepTableState, type StepContractState } from "../lib/bundleArchitecture";

type Props = {
  bundle: TransactionBundle;
  onClose: () => void;
};

export const BundleDetail: React.FC<Props> = ({ bundle, onClose }) => {
  const events = useStore((s) => s.events);
  const knownAddresses = useStore((s) => s.knownAddresses);
  const l1Contract = useStore((s) => s.l1ContractAddress);
  const l2Contract = useStore((s) => s.l2ContractAddress);
  const [activeStep, setActiveStep] = useState(0);

  // Get events in this bundle
  const bundleEvents = useMemo(() => {
    const eventSet = new Set(bundle.events);
    return events.filter((e) => eventSet.has(e.id));
  }, [events, bundle.events]);

  // Build scoped architecture diagram + tables + state
  const arch = useMemo(
    () => buildBundleArchitecture(bundleEvents, knownAddresses, l1Contract, l2Contract, events),
    [bundleEvents, knownAddresses, l1Contract, l2Contract, events],
  );

  // Build step list
  const steps = useMemo(() => buildBundleSteps(arch.mergedEvents), [arch.mergedEvents]);

  // Per-step active highlights
  const currentHighlight = arch.stepHighlights[activeStep];
  const activeNodesSet = useMemo(
    () => new Set(currentHighlight?.activeNodes ?? []),
    [currentHighlight],
  );
  const activeEdgesSet = useMemo(
    () => new Set(currentHighlight?.activeEdges ?? []),
    [currentHighlight],
  );

  // Per-step table + state
  const currentTable: StepTableState | undefined = arch.tableStates[activeStep];
  const currentRoot: StepContractState | undefined = arch.contractStates[activeStep];

  const currentStep = steps[activeStep];

  // Keyboard navigation
  const handleKeyDown = useCallback(
    (e: KeyboardEvent) => {
      if (e.key === "ArrowRight" || e.key === "ArrowDown") {
        e.preventDefault();
        e.stopPropagation();
        setActiveStep((s) => Math.min(steps.length - 1, s + 1));
      } else if (e.key === "ArrowLeft" || e.key === "ArrowUp") {
        e.preventDefault();
        e.stopPropagation();
        setActiveStep((s) => Math.max(0, s - 1));
      } else if (e.key === "Escape") {
        e.preventDefault();
        onClose();
      }
    },
    [steps.length, onClose],
  );

  useEffect(() => {
    window.addEventListener("keydown", handleKeyDown, true);
    return () => window.removeEventListener("keydown", handleKeyDown, true);
  }, [handleKeyDown]);

  return (
    <div
      style={{
        position: "fixed",
        inset: 0,
        zIndex: 100,
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        background: "rgba(0,0,0,0.7)",
        backdropFilter: "blur(4px)",
      }}
      onClick={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <div
        style={{
          width: "98vw",
          maxWidth: "98vw",
          height: "96vh",
          maxHeight: "96vh",
          background: COLORS.bg,
          border: `1px solid ${COLORS.brd}`,
          borderRadius: 10,
          overflow: "hidden",
          display: "flex",
          flexDirection: "column",
        }}
      >
        {/* Header */}
        <div
          style={{
            padding: "10px 16px",
            borderBottom: `1px solid ${COLORS.brd}`,
            display: "flex",
            justifyContent: "space-between",
            alignItems: "center",
          }}
        >
          <div>
            <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
              <DirectionBadge direction={bundle.direction} />
              <span style={{ fontWeight: 700, fontSize: "0.85rem" }}>{bundle.title}</span>
              <StatusDot status={bundle.status} />
            </div>
            <div style={{ fontSize: "0.5rem", color: COLORS.dim, marginTop: 2 }}>
              {bundle.events.length} events | {bundle.crossChainCallHashes.length} cross-chain call hashes |
              blocks {bundle.blockRange.from.toString()}-{bundle.blockRange.to.toString()} |
              arrow keys to navigate
            </div>
          </div>
          <button
            onClick={onClose}
            style={{
              background: "none",
              border: `1px solid ${COLORS.brd}`,
              borderRadius: 4,
              color: COLORS.dim,
              cursor: "pointer",
              fontSize: "0.65rem",
              padding: "4px 10px",
              fontFamily: "monospace",
            }}
          >
            ESC
          </button>
        </div>

        {/* Body */}
        <div style={{ flex: 1, overflow: "hidden", display: "flex" }}>
          {/* Main content */}
          <div style={{ flex: 1, overflow: "auto", padding: "10px 14px" }}>
            {/* Architecture Diagram */}
            <ArchitectureDiagram
              l1Nodes={arch.l1Nodes}
              l2Nodes={arch.l2Nodes}
              edges={arch.edges}
              activeNodes={activeNodesSet}
              activeEdges={activeEdgesSet}
            />

            {/* Step description */}
            {currentStep && (
              <div
                style={{
                  marginTop: 8,
                  background: COLORS.s1,
                  border: `1px solid ${COLORS.brd}`,
                  borderRadius: 8,
                  padding: "8px 12px",
                }}
              >
                <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                  <StepBadge index={activeStep} />
                  <ChainBadge chain={currentStep.chain} />
                  <div style={{ fontWeight: 700, fontSize: "0.65rem" }}>
                    {currentHighlight?.description ?? currentStep.title}
                  </div>
                </div>
                <div style={{ fontSize: "0.5rem", color: COLORS.dim, marginTop: 4, marginLeft: 28 }}>
                  {currentStep.detail}
                </div>
                <div style={{ display: "flex", alignItems: "center", gap: 4, marginTop: 2, marginLeft: 28 }}>
                  <span style={{ fontSize: "0.45rem", color: COLORS.dim }}>
                    tx: {currentStep.txHash}
                  </span>
                  <CopyButton text={currentStep.txHash} />
                </div>
              </div>
            )}

            {/* Execution Tables — L1 & L2 side by side (always shown) */}
            <div style={{ display: "flex", gap: 8, marginTop: 8 }}>
              <TablePanel
                title="L1 Execution Table"
                subtitle="Rollups"
                entries={currentTable?.l1 ?? []}
                chainColor={COLORS.l1}
                defaultExpanded
              />
              <TablePanel
                title="L2 Execution Table"
                subtitle="ManagerL2"
                entries={currentTable?.l2 ?? []}
                chainColor={COLORS.l2}
                defaultExpanded
              />
            </div>

            {/* Contract State */}
            {currentRoot && currentRoot.entries.length > 0 && (
              <div
                style={{
                  marginTop: 8,
                  background: COLORS.s1,
                  border: `1px solid ${COLORS.brd}`,
                  borderRadius: 8,
                  padding: "8px 12px",
                }}
              >
                <SectionHeader>Contract State</SectionHeader>
                <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: "2px 12px", fontSize: "0.5rem" }}>
                  {currentRoot.entries.map((e) => (
                    <div key={e.key} style={{ display: "flex", gap: 6 }}>
                      <span style={{ color: COLORS.dim }}>{e.key}</span>
                      <span style={{ color: e.changed ? COLORS.ok : COLORS.tx, fontWeight: e.changed ? 700 : 400 }}>
                        {e.value}
                      </span>
                    </div>
                  ))}
                </div>
              </div>
            )}

          </div>

          {/* Step sidebar */}
          <div
            style={{
              width: 280,
              flexShrink: 0,
              borderLeft: `1px solid ${COLORS.brd}`,
              overflow: "auto",
              padding: 8,
              background: COLORS.s1,
            }}
          >
            <div
              style={{
                fontSize: "0.5rem",
                fontWeight: 700,
                textTransform: "uppercase",
                letterSpacing: "0.05em",
                color: COLORS.dim,
                marginBottom: 6,
                padding: "0 4px",
              }}
            >
              Steps ({steps.length})
            </div>

            <div style={{ display: "flex", justifyContent: "center", gap: 6, marginBottom: 8 }}>
              <SmallButton
                onClick={() => setActiveStep(Math.max(0, activeStep - 1))}
                disabled={activeStep === 0}
              >
                Prev
              </SmallButton>
              <SmallButton
                onClick={() => setActiveStep(Math.min(steps.length - 1, activeStep + 1))}
                disabled={activeStep >= steps.length - 1}
              >
                Next
              </SmallButton>
            </div>

            {steps.map((step, i) => {
              const tableSnap = arch.tableStates[i];
              return (
                <StepItem
                  key={step.eventId}
                  step={step}
                  index={i}
                  active={i === activeStep}
                  played={i < activeStep}
                  onClick={() => setActiveStep(i)}
                  highlight={arch.stepHighlights[i]}
                  tableChanges={tableSnap}
                />
              );
            })}
          </div>
        </div>
      </div>
    </div>
  );
};

// ─── Execution Table Panel ──────────────────────────────

type MiniEntry = {
  stepStatus: string;
  crossChainCallHash: string;
  delta: string | null;
  stateDeltas?: string[];
  actionDetail?: Record<string, string>;
  entryMeta?: Record<string, string>;
  fullCrossChainCallHash?: string;
};

const TablePanel: React.FC<{
  title: string;
  subtitle: string;
  entries: MiniEntry[];
  chainColor: string;
  defaultExpanded?: boolean;
}> = ({ title, subtitle, entries, chainColor, defaultExpanded }) => {
  const active = entries.filter(e => e.stepStatus !== "consumed");
  return (
    <div
      style={{
        flex: 1,
        background: COLORS.s1,
        border: `1px solid ${COLORS.brd}`,
        borderRadius: 8,
        padding: "10px 12px",
        minWidth: 0,
      }}
    >
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", marginBottom: 6 }}>
        <div style={{ fontSize: "0.6rem", fontWeight: 700, color: chainColor }}>
          {title} <span style={{ color: COLORS.dim, fontWeight: 400 }}>({subtitle})</span>
        </div>
        <div style={{ fontSize: "0.5rem", color: COLORS.dim }}>{active.length} entries</div>
      </div>
      {entries.length === 0 ? (
        <div style={{ fontSize: "0.55rem", color: COLORS.dim, fontStyle: "italic", textAlign: "center", padding: 8 }}>
          empty
        </div>
      ) : (
        entries.map((entry, i) => <TableEntryMini key={i} entry={entry} index={i} defaultExpanded={defaultExpanded} />)
      )}
    </div>
  );
};

const TableEntryMini: React.FC<{
  entry: MiniEntry;
  index: number;
  defaultExpanded?: boolean;
}> = ({ entry, index, defaultExpanded }) => {
  const [expanded, setExpanded] = useState(defaultExpanded ?? false);
  const isJa = entry.stepStatus === "ja";
  const isJc = entry.stepStatus === "jc";
  const isConsumed = entry.stepStatus === "consumed";

  const borderColor = isJa ? COLORS.add : isJc ? COLORS.rm : COLORS.brd;
  const opacity = isConsumed ? 0.3 : 1;

  // Extract decoded fields (skip crossChainCallHash key — shown as the header hash)
  const actionFields = entry.actionDetail
    ? Object.entries(entry.actionDetail).filter(([k]) => k !== "crossChainCallHash")
    : [];
  const metaFields = entry.entryMeta
    ? Object.entries(entry.entryMeta)
    : [];
  const hasDecodedFields = actionFields.length > 0 || metaFields.length > 0;

  return (
    <div
      style={{
        marginBottom: 4,
        borderRadius: 5,
        background: COLORS.s2,
        border: `1px solid ${borderColor}`,
        opacity,
        fontSize: "0.58rem",
        transition: "all 0.2s",
        overflow: "hidden",
      }}
    >
      {/* Summary row */}
      <div
        onClick={() => hasDecodedFields && setExpanded(!expanded)}
        style={{
          display: "flex",
          gap: 6,
          alignItems: "center",
          padding: "5px 8px",
          cursor: hasDecodedFields ? "pointer" : "default",
          textDecoration: isJc ? "line-through" : undefined,
        }}
      >
        <span style={{ color: COLORS.dim, fontWeight: 700 }}>#{index + 1}</span>
        <span style={{ color: COLORS.add, flex: 1, minWidth: 0, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{entry.crossChainCallHash}</span>
        {isJa && (
          <span style={{ fontSize: "0.48rem", color: COLORS.add, fontWeight: 700, flexShrink: 0 }}>+added</span>
        )}
        {isJc && (
          <span style={{ fontSize: "0.48rem", color: COLORS.rm, fontWeight: 700, flexShrink: 0 }}>consumed</span>
        )}
        {hasDecodedFields && (
          <span style={{ fontSize: "0.48rem", color: COLORS.dim, flexShrink: 0 }}>
            {expanded ? "\u25B2" : "\u25BC"}
          </span>
        )}
      </div>

      {/* State deltas (always visible) */}
      {entry.stateDeltas && entry.stateDeltas.length > 0 && (
        <div style={{ fontSize: "0.52rem", color: COLORS.ok, padding: "0 8px 4px" }}>
          {entry.stateDeltas.join("; ")}
        </div>
      )}

      {/* Expanded decoded fields */}
      {expanded && hasDecodedFields && (
        <div style={{ borderTop: `1px solid ${COLORS.brd}`, padding: "6px 8px", background: "rgba(0,0,0,0.2)" }}>
          {actionFields.length > 0 && (
            <div style={{ marginBottom: 5 }}>
              <div style={{ fontSize: "0.48rem", fontWeight: 700, color: COLORS.acc, textTransform: "uppercase", letterSpacing: "0.04em", marginBottom: 3 }}>
                Action Hash Details
              </div>
              <div style={{ display: "grid", gridTemplateColumns: "85px 1fr", gap: "2px 8px", fontSize: "0.52rem" }}>
                {actionFields.map(([k, v]) => (
                  <React.Fragment key={k}>
                    <span style={{ color: COLORS.dim }}>{k}</span>
                    <span style={{ color: k === "data" && v !== "0x" ? COLORS.add : COLORS.tx, wordBreak: "break-all" }}>{v}</span>
                  </React.Fragment>
                ))}
              </div>
            </div>
          )}
          {metaFields.length > 0 && (
            <div>
              <div style={{ fontSize: "0.48rem", fontWeight: 700, color: COLORS.acc, textTransform: "uppercase", letterSpacing: "0.04em", marginBottom: 3 }}>
                Entry Metadata
              </div>
              <div style={{ display: "grid", gridTemplateColumns: "85px 1fr", gap: "2px 8px", fontSize: "0.52rem" }}>
                {metaFields.map(([k, v]) => (
                  <React.Fragment key={k}>
                    <span style={{ color: COLORS.dim }}>{k}</span>
                    <span style={{ color: COLORS.tx, wordBreak: "break-all" }}>{v}</span>
                  </React.Fragment>
                ))}
              </div>
            </div>
          )}
        </div>
      )}
    </div>
  );
};

// ─── Small components ────────────────────────────────

const SectionHeader: React.FC<{ children: React.ReactNode }> = ({ children }) => (
  <div
    style={{
      fontSize: "0.5rem",
      fontWeight: 700,
      color: COLORS.acc,
      textTransform: "uppercase",
      letterSpacing: "0.05em",
      marginBottom: 6,
    }}
  >
    {children}
  </div>
);

const StepBadge: React.FC<{ index: number }> = ({ index }) => (
  <div
    style={{
      width: 20,
      height: 20,
      borderRadius: "50%",
      background: COLORS.acc,
      color: "#fff",
      display: "flex",
      alignItems: "center",
      justifyContent: "center",
      fontSize: "0.5rem",
      fontWeight: 700,
      flexShrink: 0,
    }}
  >
    {index + 1}
  </div>
);

const ChainBadge: React.FC<{ chain: string }> = ({ chain }) => {
  const color = chain === "l1" ? COLORS.l1 : COLORS.l2;
  return (
    <div
      style={{
        padding: "1px 5px",
        borderRadius: 3,
        fontSize: "0.45rem",
        fontWeight: 700,
        color,
        border: `1px solid ${color}30`,
        background: `${color}10`,
      }}
    >
      {chain.toUpperCase()}
    </div>
  );
};

const DirectionBadge: React.FC<{ direction: string }> = ({ direction }) => {
  const color = direction.includes("L1") && direction.includes("L2")
    ? COLORS.warn
    : direction.includes("L1")
      ? COLORS.l1
      : COLORS.l2;
  return (
    <span
      style={{
        padding: "2px 6px",
        borderRadius: 4,
        fontSize: "0.5rem",
        fontWeight: 700,
        background: `${color}15`,
        color,
        border: `1px solid ${color}30`,
      }}
    >
      {direction}
    </span>
  );
};

const StatusDot: React.FC<{ status: string }> = ({ status }) => (
  <div
    style={{
      width: 8,
      height: 8,
      borderRadius: "50%",
      background: status === "complete" ? COLORS.ok : COLORS.warn,
      boxShadow: `0 0 6px ${status === "complete" ? "rgba(52,211,153,0.4)" : "rgba(245,158,11,0.4)"}`,
    }}
    title={status}
  />
);

const CopyButton: React.FC<{ text: string }> = ({ text }) => {
  const [copied, setCopied] = useState(false);
  return (
    <button
      onClick={(e) => {
        e.stopPropagation();
        navigator.clipboard.writeText(text);
        setCopied(true);
        setTimeout(() => setCopied(false), 1500);
      }}
      style={{
        fontSize: "0.4rem",
        color: copied ? COLORS.ok : COLORS.dim,
        background: "none",
        border: "none",
        cursor: "pointer",
        fontFamily: "monospace",
        padding: "0 2px",
      }}
      title="Copy to clipboard"
    >
      {copied ? "copied" : "copy"}
    </button>
  );
};

const StepItem: React.FC<{
  step: BundleStep;
  index: number;
  active: boolean;
  played: boolean;
  onClick: () => void;
  highlight?: { description: string };
  tableChanges?: StepTableState;
}> = ({ step, index, active, played, onClick, highlight, tableChanges }) => {
  const chainColor = step.chain === "l1" ? COLORS.l1 : COLORS.l2;

  // Compute table change summary
  const l1Added = tableChanges?.l1.filter(e => e.stepStatus === "ja").length ?? 0;
  const l1Consumed = tableChanges?.l1.filter(e => e.stepStatus === "jc").length ?? 0;
  const l2Added = tableChanges?.l2.filter(e => e.stepStatus === "ja").length ?? 0;
  const l2Consumed = tableChanges?.l2.filter(e => e.stepStatus === "jc").length ?? 0;
  const hasChanges = l1Added + l1Consumed + l2Added + l2Consumed > 0;

  return (
    <div
      onClick={onClick}
      style={{
        display: "flex",
        gap: 6,
        padding: "5px 6px",
        borderRadius: 5,
        border: `1px solid ${active ? COLORS.acc : "transparent"}`,
        background: active ? COLORS.s2 : "transparent",
        marginBottom: 3,
        cursor: "pointer",
        opacity: active ? 1 : played ? 0.65 : 0.3,
        transition: "all 0.15s",
        fontSize: "0.55rem",
      }}
    >
      <div
        style={{
          width: 14,
          height: 14,
          borderRadius: "50%",
          background: active ? COLORS.acc : COLORS.s3,
          color: active ? "#fff" : COLORS.dim,
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          fontSize: "0.4rem",
          fontWeight: 700,
          flexShrink: 0,
          marginTop: 1,
        }}
      >
        {index + 1}
      </div>
      <div
        style={{
          flexShrink: 0,
          padding: "0 4px",
          borderRadius: 3,
          fontSize: "0.4rem",
          fontWeight: 700,
          marginTop: 1,
          color: chainColor,
          border: `1px solid ${chainColor}30`,
          background: `${chainColor}10`,
        }}
      >
        {step.chain.toUpperCase()}
      </div>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontWeight: 700, fontSize: "0.5rem" }}>
          {highlight?.description ?? step.title}
        </div>
        <div
          style={{
            color: COLORS.dim,
            fontSize: "0.45rem",
            overflow: "hidden",
            textOverflow: "ellipsis",
            whiteSpace: "nowrap",
          }}
        >
          {step.detail}
        </div>
        {hasChanges && (
          <div style={{ fontSize: "0.4rem", marginTop: 2 }}>
            {l1Added > 0 && <span style={{ color: COLORS.add, marginRight: 4 }}>+L1</span>}
            {l1Consumed > 0 && <span style={{ color: COLORS.rm, marginRight: 4 }}>-L1</span>}
            {l2Added > 0 && <span style={{ color: COLORS.add, marginRight: 4 }}>+L2</span>}
            {l2Consumed > 0 && <span style={{ color: COLORS.rm, marginRight: 4 }}>-L2</span>}
          </div>
        )}
      </div>
    </div>
  );
};

const SmallButton: React.FC<{
  children: React.ReactNode;
  onClick: () => void;
  disabled?: boolean;
}> = ({ children, onClick, disabled }) => (
  <button
    onClick={onClick}
    disabled={disabled}
    style={{
      padding: "3px 10px",
      borderRadius: 4,
      border: `1px solid ${COLORS.brd}`,
      background: disabled ? "transparent" : COLORS.s2,
      color: disabled ? COLORS.dim : COLORS.tx,
      cursor: disabled ? "default" : "pointer",
      fontFamily: "monospace",
      fontSize: "0.5rem",
      fontWeight: 700,
      opacity: disabled ? 0.3 : 1,
    }}
  >
    {children}
  </button>
);
