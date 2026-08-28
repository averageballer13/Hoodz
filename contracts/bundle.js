#!/usr/bin/env node
/**
 * Hoodz - build the browser deployer's bytecode bundle.
 *
 * /deploy sends one creation transaction per contract straight from the browser,
 * so it needs creation bytecode and a constructor signature for each. This reads
 * those out of contracts/out/artifacts.json and writes web/assets/deploy/bytecode.json.
 *
 *   node contracts/compile.js && node contracts/bundle.js
 *
 * Run it after ANY contract change. The failure mode it exists to prevent is
 * quiet: rename a contract and hand-edit the bundle's keys, and you ship a file
 * that deploys yesterday's bytes under today's name. Nothing errors - the
 * addresses just hold the wrong code, and Blockscout verification later fails
 * against a source that never produced them.
 *
 * The deploy ORDER is preserved from the existing bundle, because it is not
 * derivable from the artifacts: it encodes which contracts take another's
 * address in their constructor. A new contract must be placed by hand.
 */

"use strict";

const fs = require("fs");
const path = require("path");

const ARTIFACTS = path.join(__dirname, "out", "artifacts.json");
const BUNDLE = path.join(__dirname, "..", "web", "assets", "deploy", "bytecode.json");

function die(msg) {
  console.error("bundle: " + msg);
  process.exit(1);
}

if (!fs.existsSync(ARTIFACTS)) die("no artifacts - run `node contracts/compile.js` first");
if (!fs.existsSync(BUNDLE)) die("no existing bundle to take the deploy order from: " + BUNDLE);

const art = JSON.parse(fs.readFileSync(ARTIFACTS, "utf8"));
const prev = JSON.parse(fs.readFileSync(BUNDLE, "utf8"));

// index every contract compiled from src/ by its bare name
const byName = new Map();
for (const key of Object.keys(art.contracts)) {
  const c = art.contracts[key];
  if (!c.sourceName || !c.sourceName.startsWith("src/")) continue;
  if (byName.has(c.contractName)) {
    die("two contracts named " + c.contractName + " under src/ - the bundle keys by bare name");
  }
  byName.set(c.contractName, c);
}

const order = prev.order || Object.keys(prev.contracts || {});
const contracts = {};
const missing = [];

for (const name of order) {
  const c = byName.get(name);
  if (!c) { missing.push(name); continue; }

  const bytecode = typeof c.bytecode === "string" ? c.bytecode : (c.bytecode && c.bytecode.object) || "";
  if (!/^0x[0-9a-fA-F]*$/.test(bytecode) || bytecode.length <= 2) {
    die(name + " has no creation bytecode (abstract or interface?)");
  }

  const ctor = (c.abi || []).find((e) => e.type === "constructor");
  contracts[name] = {
    sourceName: c.sourceName,
    bytecode: bytecode,
    constructor: (ctor ? ctor.inputs : []).map((i) => ({ name: i.name, type: i.type })),
    sizeBytes: (bytecode.length - 2) / 2,
  };
}

if (missing.length) die("not found in the compiled output: " + missing.join(", "));

const out = {
  generatedAt: new Date().toISOString(),
  compiler: art.compiler,
  evmVersion: art.evmVersion,
  optimizer: art.optimizer,
  order: order,
  contracts: contracts,
};

fs.writeFileSync(BUNDLE, JSON.stringify(out, null, 2) + "\n");

const total = Object.keys(contracts).reduce((n, k) => n + contracts[k].sizeBytes, 0);
console.log("Wrote " + order.length + " contracts to web/assets/deploy/bytecode.json");
console.log("  compiler   " + art.compiler);
console.log("  total size " + total + " bytes");
for (const name of order) {
  const c = contracts[name];
  const over = c.sizeBytes > 24576 ? "  <-- OVER THE 24576-byte limit" : "";
  console.log("  " + name.padEnd(26) + String(c.sizeBytes).padStart(6) + " bytes" + over);
}
