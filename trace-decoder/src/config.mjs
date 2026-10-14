import fs from "node:fs";
import path from "node:path";

const ENV = {
  L1_RPC: "l1Rpc", L2_RPC: "l2Rpc", L1_FRONT: "l1Front", L2_FRONT: "l2Front",
  EXPLORER_L1: "l1Explorer", EXPLORER_L2: "l2Explorer",
  L1_EXPLORER_TYPE: "l1ExplorerType", L2_EXPLORER_TYPE: "l2ExplorerType",
  L1_EXPLORER_API_KEY: "l1ExplorerApiKey", L2_EXPLORER_API_KEY: "l2ExplorerApiKey",
  ETHERSCAN_API_KEY: "etherscanApiKey",
  ROLLUPS: "rollups", MANAGER_L2: "managerL2", EEZ_ROLLUP_MANAGER: "rollupManager",
  EEZ_CORR_RPC: "correlationRpc", L1_TRACE_RPC: "l1TraceRpc", L2_TRACE_RPC: "l2TraceRpc",
  EXPECTED_L1_CHAIN_ID: "expectedL1ChainId", EXPECTED_L2_CHAIN_ID: "expectedL2ChainId",
};
const FLAGS = {
  "--tx": "tx", "--env-file": "envFile", "--l1-rpc": "l1Rpc", "--l2-rpc": "l2Rpc",
  "--l1-front": "l1Front", "--l2-front": "l2Front", "--l1-explorer": "l1Explorer",
  "--l2-explorer": "l2Explorer", "--rollups": "rollups", "--manager-l2": "managerL2",
  "--l1-manager": "rollups", "--l2-manager": "managerL2", "--correlation-rpc": "correlationRpc",
  "--l1-trace-rpc": "l1TraceRpc", "--l2-trace-rpc": "l2TraceRpc",
  "--l1-explorer-type": "l1ExplorerType", "--l2-explorer-type": "l2ExplorerType",
  "--l1-explorer-api-key": "l1ExplorerApiKey", "--l2-explorer-api-key": "l2ExplorerApiKey",
  "--etherscan-api-key": "etherscanApiKey",
  "--l1-from": "l1From", "--l1-to": "l1To", "--l2-from": "l2From", "--l2-to": "l2To",
};

// Deliberately not a shell/dotenv interpreter. Only network/explorer settings
// are allowlisted, including explorer API keys but never wallet private keys.
// Never mutate process.env or evaluate substitutions.
export function parseEnv(text, exported = {}) {
  const values = {};
  for (const line of text.split(/\r?\n/)) {
    const m = line.match(/^\s*(?:export\s+)?([A-Z][A-Z0-9_]*)\s*=\s*(.*?)\s*$/);
    if (!m || !(m[1] in ENV)) continue;
    let value = m[2];
    if (value.startsWith('"') || value.startsWith("'")) {
      const quote = value[0], end = value.indexOf(quote, 1);
      if (end < 0 || !/^\s*(?:#.*)?$/.test(value.slice(end + 1))) throw new Error(`Invalid ${m[1]} assignment`);
      value = value.slice(1, end);
    } else value = value.replace(/\s+#.*$/, "").trim();
    if (/[`]|\$\(/.test(value)) throw new Error(`Shell expressions are not supported in ${m[1]}`);
    values[m[1]] = value;
  }
  function expand(key, seen = new Set()) {
    if (seen.has(key)) throw new Error(`Cyclic environment reference: ${key}`);
    seen.add(key);
    return (values[key] ?? exported[key] ?? "").replace(/\$\{([A-Z][A-Z0-9_]*)\}|\$([A-Z][A-Z0-9_]*)/g, (_, a, b) => {
      const ref = a || b;
      if (!(ref in ENV)) throw new Error(`Unsupported environment reference: ${ref}`);
      return expand(ref, new Set(seen));
    });
  }
  return Object.fromEntries(Object.keys(values).map(key => [key, expand(key)]));
}

export function loadConfig(argv = process.argv.slice(2), env = process.env, cwd = process.cwd()) {
  const cli = {};
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (["--json", "--full", "--no-explorer", "--no-4byte", "--help", "-h", "--no-correlation", "--thorough"].includes(arg)) {
      cli[({"--no-explorer": "noExplorer", "--no-4byte": "no4byte", "--no-correlation": "noCorrelation", "-h": "help"})[arg] || arg.slice(2)] = true;
    } else if (FLAGS[arg]) {
      if (!argv[i + 1] || argv[i + 1].startsWith("--")) throw new Error(`${arg} needs a value`);
      cli[FLAGS[arg]] = argv[++i];
    } else if (!arg.startsWith("-") && !cli.tx) cli.tx = arg;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  if (cli.help) return cli;
  const envFile = path.resolve(cwd, cli.envFile || env.DEVNET_ENV || "chain.env");
  const file = fs.existsSync(envFile) ? parseEnv(fs.readFileSync(envFile, "utf8"), env) : {};
  if (!fs.existsSync(envFile) && (cli.envFile || env.DEVNET_ENV)) throw new Error(`Environment file not found: ${envFile}`);
  const config = {};
  for (const [key, option] of Object.entries(ENV)) {
    // Exported configuration overrides a file; CLI overrides both.
    if (env[key] ?? file[key]) config[option] = env[key] ?? file[key];
  }
  Object.assign(config, cli, { envFile: fs.existsSync(envFile) ? envFile : null,
    explicitManagers: { L1: !!cli.rollups, L2: !!cli.managerL2 } });
  if (!/^0x[0-9a-f]{64}$/i.test(config.tx || "")) throw new Error("Provide a 32-byte transaction hash (positional or --tx)");
  for (const key of ["l1Rpc", "l2Rpc"]) if (!config[key]) throw new Error(`Missing ${key}; configure RPC URLs or use --env-file`);
  for (const chain of ["l1", "l2"]) {
    if (config[chain + "ExplorerType"] && !["auto", "blockscout", "etherscan"].includes(config[chain + "ExplorerType"])) {
      throw new Error(`Invalid ${chain}ExplorerType; use auto, blockscout, or etherscan`);
    }
    for (const suffix of ["From", "To"]) if (config[chain + suffix] != null) {
      const value = Number(config[chain + suffix]);
      if (!Number.isSafeInteger(value) || value < 0) throw new Error(`Invalid ${chain + suffix}`);
      config[chain + suffix] = value;
    }
    if ((config[chain + "From"] == null) !== (config[chain + "To"] == null)) throw new Error(`Provide both --${chain}-from and --${chain}-to`);
    if (config[chain + "From"] > config[chain + "To"]) throw new Error(`Inverted ${chain} search range`);
  }
  return config;
}

export const HELP = `Usage: node trace-decoder/decode-trace.mjs <TX_HASH> [options]
  --tx HASH                       Compatibility alias for positional hash
  --env-file FILE                 Otherwise DEVNET_ENV, then chain.env
  --l1-rpc URL --l2-rpc URL        Chain reads and traces
  --l1-front URL --l2-front URL    Composer / settlement discovery
  --correlation-rpc URL           First settlement capability candidate
  --l1-trace-rpc URL --l2-trace-rpc URL
  --l1-manager ADDRESS --l2-manager ADDRESS  Historical deployment overrides
  --l1-from N --l1-to N --l2-from N --l2-to N
  --l1-explorer URL --l2-explorer URL
  --l1-explorer-type TYPE --l2-explorer-type TYPE  auto, blockscout, etherscan
  --l1-explorer-api-key KEY --l2-explorer-api-key KEY
  --etherscan-api-key KEY         Also ETHERSCAN_API_KEY; enables V2 fallback
  --json --full --no-explorer --no-4byte --no-correlation
  --thorough                      Trace every transaction in scanned blocks, not only manager calls/events
Fallback search: nearest timestamp on the other chain, ±2,000 blocks, chunks of 500.
All operations are read-only. Diagnostics are written to stderr.`;
