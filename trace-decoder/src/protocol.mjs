import fs from "node:fs";
import { ethers } from "ethers";
const abis = JSON.parse(fs.readFileSync(new URL("./protocol-abi.json", import.meta.url), "utf8"));
export const protocol = Object.fromEntries(Object.entries(abis).map(([chain, abi]) => [chain, new ethers.Interface(abi)]));
export const proxyABI = new ethers.Interface([
  "function executeOnBehalf(address destination,uint64 callGas,bytes data) payable",
  "function staticCheck()",
]);
export const lower = value => typeof value === "string" ? value.toLowerCase() : value;
export const same = (a, b) => a != null && b != null && lower(a) === lower(b);
export const hex = n => ethers.toQuantity(n);
export const number = n => { const value = Number(n); if (n == null || !Number.isSafeInteger(value) || value < 0) throw new Error(`Invalid block/index: ${n}`); return value; };
export const shortAddress = a => a ? `${a.slice(0, 8)}…${a.slice(-6)}` : "(creation)";
export const plain = value => JSON.parse(JSON.stringify(value, (_, v) => typeof v === "bigint" ? v.toString() : v));
export function named(params, values) {
  return params.map((param, i) => ({ name: param.name || String(i), type: param.type, value: abiValue(param, values[i]) }));
}
export function abiValue(param, value) {
  if (param.baseType === "array") return Array.from(value, v => abiValue(param.arrayChildren, v));
  if (param.baseType === "tuple") return Object.fromEntries(param.components.map((p, i) => [p.name || String(i), abiValue(p, value[i])]));
  return typeof value === "bigint" ? value.toString() : value;
}
export function parseCall(iface, input) { try { return iface.parseTransaction({ data: input || "0x" }); } catch { return null; } }
export function parseEvent(chain, log) {
  try { const p = protocol[chain].parseLog(log); return p ? { name: p.name, signature: p.signature, args: Object.fromEntries(named(p.fragment.inputs, p.args).map(p => [p.name, p.value])) } : null; } catch { return null; }
}
export function callHash(c, gas = "0") {
  return ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(
    ["bool", "address", "uint64", "address", "uint64", "uint256", "uint64", "bytes"],
    [c.isStatic, c.sourceAddress, c.sourceRollupId, c.targetAddress, c.targetRollupId, c.value, gas, c.data]));
}
