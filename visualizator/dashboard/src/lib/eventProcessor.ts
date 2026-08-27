import type { EventRecord } from "../types/events";
import type { TableEntry } from "../types/visualization";
import { truncateHex } from "./actionFormatter";

/**
 * Processes an event into table entry mutations.
 * Returns { adds, consumes } for the appropriate chain.
 */
export type ConsumeInfo = {
  crossChainCallHash: string;
  actionDetail: Record<string, string>;
};

export function processEventForTables(
  event: EventRecord,
): {
  l1Adds: TableEntry[];
  l2Adds: TableEntry[];
  l1Consumes: ConsumeInfo[];
  l2Consumes: ConsumeInfo[];
} {
  const result = {
    l1Adds: [] as TableEntry[],
    l2Adds: [] as TableEntry[],
    l1Consumes: [] as ConsumeInfo[],
    l2Consumes: [] as ConsumeInfo[],
  };

  switch (event.eventName) {
    case "BatchPosted": {
      // TODO(user-decision): post-refactor BatchPosted no longer carries entries;
      // decode from tx input or rebuild table from EntryExecuted / ExecutionConsumed events.
      break;
    }

    case "ExecutionTableLoaded": {
      const entries = event.args.entries as Array<{
        stateDeltas: Array<{
          rollupId: bigint;
          currentRoot: string;
          newRoot: string;
          etherDelta: bigint;
        }>;
        crossChainCallHash: string;
        destinationRollupId: bigint;
        calls: unknown[];
        nestedActions: unknown[];
        callCount: bigint;
        returnData: string;
        rollingHash: string;
      }>;
      if (!entries) break;
      for (const entry of entries) {
        const te = entryToTableEntry(entry, event.id);
        result.l2Adds.push(te);
      }
      break;
    }

    case "ExecutionConsumed": {
      const crossChainCallHash = event.args.crossChainCallHash as string;
      const actionDetail: Record<string, string> = {
        crossChainCallHash,
        rollupId: String(event.args.rollupId ?? ""),
        cursor: String(event.args.cursor ?? ""),
      };
      const info: ConsumeInfo = { crossChainCallHash, actionDetail };
      if (event.chain === "l1") {
        result.l1Consumes.push(info);
      } else {
        result.l2Consumes.push(info);
      }
      break;
    }
  }

  return result;
}

function entryToTableEntry(
  entry: {
    stateDeltas: Array<{
      rollupId: bigint;
      currentRoot: string;
      newRoot: string;
      etherDelta: bigint;
    }>;
    crossChainCallHash: string;
    destinationRollupId: bigint;
    calls: unknown[];
    nestedActions: unknown[];
    callCount: bigint;
    returnData: string;
    rollingHash: string;
  },
  eventId: string,
): TableEntry {
  const deltas = entry.stateDeltas.map(
    (sd) => `r${sd.rollupId}: -> ${truncateHex(sd.newRoot)}`,
  );
  const rollupIds = entry.stateDeltas.map((sd) => sd.rollupId);

  const entryMeta: Record<string, string> = {
    callCount: String(entry.callCount ?? 0),
    callsLen: String(entry.calls?.length ?? 0),
    nestedLen: String(entry.nestedActions?.length ?? 0),
    destinationRollupId: String(entry.destinationRollupId ?? 0),
    rollingHash: truncateHex(entry.rollingHash ?? "0x0"),
    returnData: entry.returnData && entry.returnData !== "0x"
      ? truncateHex(entry.returnData, 12)
      : "(empty)",
  };

  return {
    id: `${eventId}-${entry.crossChainCallHash}`,
    crossChainCallHash: truncateHex(entry.crossChainCallHash),
    delta: deltas.length > 0 ? deltas.join("; ") : null,
    status: "ja",
    stateDeltas: deltas,
    rollupIds,
    actionDetail: { crossChainCallHash: entry.crossChainCallHash },
    fullCrossChainCallHash: entry.crossChainCallHash,
    entryMeta,
  };
}


/**
 * Extracts rollup state changes from events.
 */
export function extractRollupState(
  event: EventRecord,
): { rollupId: string; key: string; value: string }[] {
  const updates: { rollupId: string; key: string; value: string }[] = [];

  switch (event.eventName) {
    case "RollupCreated": {
      const rid = String(event.args.rollupId);
      updates.push(
        { rollupId: rid, key: `Rollup ${rid} state`, value: truncateHex(event.args.initialRoot as string) },
        { rollupId: rid, key: `Rollup ${rid} contract`, value: (event.args.rollupContract as string) },
      );
      break;
    }
    case "RollupContractChanged": {
      const rid = String(event.args.rollupId);
      updates.push({
        rollupId: rid,
        key: `Rollup ${rid} contract`,
        value: (event.args.newContract as string),
      });
      break;
    }
    case "BatchPosted": {
      // TODO(user-decision): post-refactor BatchPosted no longer carries entries;
      // state-delta extraction must come from another source (tx input decode or
      // an alternative event stream).
      break;
    }
  }

  return updates;
}
