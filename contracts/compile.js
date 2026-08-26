#!/usr/bin/env node
/**
 * Hoodz - standalone solc compiler driver.
 *
 * Compiles every *.sol under contracts/src in ONE solc standard-JSON invocation, so that
 * cross-file references are always type-checked together. No Foundry / Hardhat required.
 *
 *   node contracts/compile.js                  compile, print errors + warnings from src/
 *   node contracts/compile.js --quiet          errors only
 *   node contracts/compile.js --all-warnings   also show warnings raised inside dependencies
 *   node contracts/compile.js --json           also dump the raw solc output json to stdout
 *
 * Import resolution:
 *   "./x.sol" / "../x.sol"        resolved by solc against the importing source unit name
 *                                 (source unit names are repo-relative: "src/tokens/HOODZ.sol")
 *   "@openzeppelin/contracts/..." nearest node_modules walking up from contracts/
 *   "node_modules/..."            relative to contracts/
 *
 * Exit code: 1 if solc reported any diagnostic of severity "error", else 0.
 */

"use strict";

const fs = require("fs");
const path = require("path");

const CONTRACTS_DIR = __dirname;
const SRC_DIR = path.join(CONTRACTS_DIR, "src");
const OUT_DIR = path.join(CONTRACTS_DIR, "out");
const OUT_FILE = path.join(OUT_DIR, "artifacts.json");

const OPTIMIZER_RUNS = 200;
const EVM_VERSION = "cancun";
const EIP170_LIMIT = 24576;

const argv = process.argv.slice(2);
const QUIET = argv.includes("--quiet") || argv.includes("-q");
const ALL_WARNINGS = argv.includes("--all-warnings") || argv.includes("-a");
const DUMP_JSON = argv.includes("--json");

/* ------------------------------------------------------------------ helpers */

function toUnitName(absPath) {
  return path.relative(CONTRACTS_DIR, absPath).split(path.sep).join("/");
}

/** Every node_modules directory from contracts/ up to the filesystem root. */
function nodeModuleRoots() {
  const roots = [];
  let dir = CONTRACTS_DIR;
  for (;;) {
    const nm = path.join(dir, "node_modules");
    if (fs.existsSync(nm)) roots.push(nm);
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  return roots;
}

/** Recursively collect *.sol files under dir. */
function collectSolidityFiles(dir, acc) {
  acc = acc || [];
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch (_) {
    return acc;
  }
  entries.sort(function (a, b) {
    return a.name.localeCompare(b.name);
  });
  for (const entry of entries) {
    if (entry.name === "node_modules" || entry.name.charAt(0) === ".") continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) collectSolidityFiles(full, acc);
    else if (entry.isFile() && entry.name.endsWith(".sol")) acc.push(full);
  }
  return acc;
}

function loadSolc() {
  try {
    return require("solc");
  } catch (_) {
    console.error("");
    console.error("  solc is not installed.");
    console.error("");
    console.error("    cd contracts && npm install --no-audit --no-fund");
    console.error("");
    process.exit(1);
  }
  return null;
}

/* ------------------------------------------------------- import resolution */

const NM_ROOTS = nodeModuleRoots();
const importCache = new Map();

function resolveImport(importPath) {
  if (importCache.has(importPath)) return importCache.get(importPath);

  const candidates = [];

  if (importPath.startsWith("./") || importPath.startsWith("../")) {
    // solc normally resolves these itself; handle them anyway for robustness.
    candidates.push(path.resolve(CONTRACTS_DIR, importPath));
    candidates.push(path.resolve(SRC_DIR, importPath));
  } else {
    // Bare or remapped path: try every node_modules, then the project itself.
    for (const nm of NM_ROOTS) candidates.push(path.join(nm, importPath));
    candidates.push(path.join(CONTRACTS_DIR, importPath));
    candidates.push(path.join(SRC_DIR, importPath));
  }

  let result = null;
  for (const candidate of candidates) {
    try {
      if (fs.existsSync(candidate) && fs.statSync(candidate).isFile()) {
        result = { contents: fs.readFileSync(candidate, "utf8") };
        break;
      }
    } catch (_) {
      /* keep looking */
    }
  }

  if (!result) {
    result = {
      error:
        "compile.js cannot resolve import '" +
        importPath +
        "'. Looked in: " +
        candidates.map(toUnitName).join(", ") +
        (NM_ROOTS.length === 0
          ? "  (no node_modules found - run `npm install` in contracts/)"
          : "")
    };
  }

  importCache.set(importPath, result);
  return result;
}

/* --------------------------------------------------------- error reporting */

function severityRank(sev) {
  if (sev === "error") return 0;
  if (sev === "warning") return 1;
  return 2;
}

/** True for diagnostics raised inside a dependency rather than our own src/. */
function isDependencyDiagnostic(diag) {
  const file = (diag.sourceLocation && diag.sourceLocation.file) || "";
  return file.indexOf("node_modules") !== -1 || file.charAt(0) === "@";
}

/**
 * Errors are always shown. Warnings are shown unless --quiet, and warnings coming from
 * dependencies (OpenZeppelin) are hidden unless --all-warnings - they are not ours to fix
 * and they bury the diagnostics that matter.
 */
function shouldShow(diag) {
  if (diag.severity === "error") return true;
  if (QUIET) return false;
  if (!ALL_WARNINGS && isDependencyDiagnostic(diag)) return false;
  return true;
}

function printDiagnostics(diagnostics) {
  const shown = diagnostics.filter(shouldShow);
  if (shown.length === 0) return;

  // Group by file.
  const groups = new Map();
  for (const err of shown) {
    const file = (err.sourceLocation && err.sourceLocation.file) || "<general>";
    if (!groups.has(file)) groups.set(file, []);
    groups.get(file).push(err);
  }

  const files = Array.from(groups.keys()).sort(function (a, b) {
    if (a === "<general>") return -1;
    if (b === "<general>") return 1;
    return a.localeCompare(b);
  });

  const rule = "-".repeat(78);

  for (const file of files) {
    const list = groups.get(file).slice();
    list.sort(function (a, b) {
      return severityRank(a.severity) - severityRank(b.severity);
    });
    let nErr = 0;
    let nWarn = 0;
    for (const e of list) {
      if (e.severity === "error") nErr += 1;
      else if (e.severity === "warning") nWarn += 1;
    }

    console.log("");
    console.log(rule);
    console.log(
      file +
        "  (" +
        nErr +
        " error" +
        (nErr === 1 ? "" : "s") +
        ", " +
        nWarn +
        " warning" +
        (nWarn === 1 ? "" : "s") +
        ")"
    );
    console.log(rule);
    for (const err of list) {
      const msg = err.formattedMessage || err.message || "";
      console.log(msg.replace(/\s+$/, ""));
    }
  }
}

/* ----------------------------------------------------------------- compile */

function main() {
  const solc = loadSolc();

  if (!fs.existsSync(SRC_DIR)) {
    console.error("No source directory at " + toUnitName(SRC_DIR));
    process.exit(1);
  }

  const files = collectSolidityFiles(SRC_DIR);
  if (files.length === 0) {
    console.log(
      "No .sol files found under " + toUnitName(SRC_DIR) + " - nothing to compile."
    );
    process.exit(0);
  }

  const sources = {};
  for (const file of files) {
    sources[toUnitName(file)] = { content: fs.readFileSync(file, "utf8") };
  }

  const input = {
    language: "Solidity",
    sources: sources,
    settings: {
      optimizer: { enabled: true, runs: OPTIMIZER_RUNS },
      evmVersion: EVM_VERSION,
      outputSelection: {
        "*": {
          "*": [
            "abi",
            "evm.bytecode.object",
            "evm.deployedBytecode.object",
            "evm.methodIdentifiers"
          ]
        }
      }
    }
  };

  const version = typeof solc.version === "function" ? solc.version() : "unknown";
  console.log(
    "Hoodz - compiling " + files.length + " source file" + (files.length === 1 ? "" : "s")
  );
  console.log("  solc         " + version);
  console.log("  evmVersion   " + EVM_VERSION);
  console.log("  optimizer    enabled, runs=" + OPTIMIZER_RUNS);
  console.log(
    "  node_modules " +
      (NM_ROOTS.length ? NM_ROOTS.map(toUnitName).join(", ") : "(none found)")
  );

  let output;
  try {
    output = JSON.parse(solc.compile(JSON.stringify(input), { import: resolveImport }));
  } catch (e) {
    console.error("");
    console.error("solc invocation failed: " + (e && e.message ? e.message : String(e)));
    process.exit(1);
  }

  if (DUMP_JSON) console.log(JSON.stringify(output, null, 2));

  const diagnostics = output.errors || [];
  printDiagnostics(diagnostics);

  let errorCount = 0;
  let warnCount = 0;
  let depWarnCount = 0;
  for (const d of diagnostics) {
    if (d.severity === "error") {
      errorCount += 1;
    } else if (d.severity === "warning") {
      warnCount += 1;
      if (isDependencyDiagnostic(d)) depWarnCount += 1;
    }
  }
  const ownWarnCount = warnCount - depWarnCount;
  const hiddenNote =
    !ALL_WARNINGS && depWarnCount > 0
      ? " (+" + depWarnCount + " in dependencies, hidden - use --all-warnings)"
      : "";

  // Collect artifacts even on failure - partial output is still useful.
  const artifacts = {};
  let contractCount = 0;
  const outContracts = output.contracts || {};
  for (const unit of Object.keys(outContracts)) {
    for (const name of Object.keys(outContracts[unit])) {
      const c = outContracts[unit][name];
      const evm = c.evm || {};
      const creation = (evm.bytecode && evm.bytecode.object) || "";
      const runtime = (evm.deployedBytecode && evm.deployedBytecode.object) || "";
      artifacts[unit + ":" + name] = {
        contractName: name,
        sourceName: unit,
        abi: c.abi || [],
        bytecode: creation ? "0x" + creation : "0x",
        deployedBytecode: runtime ? "0x" + runtime : "0x",
        methodIdentifiers: evm.methodIdentifiers || {},
        deployedSizeBytes: runtime.length / 2
      };
      contractCount += 1;
    }
  }

  fs.mkdirSync(OUT_DIR, { recursive: true });
  fs.writeFileSync(
    OUT_FILE,
    JSON.stringify(
      {
        _comment:
          "UNAUDITED build output. Generated by contracts/compile.js - do not edit by hand.",
        compiler: version,
        evmVersion: EVM_VERSION,
        optimizer: { enabled: true, runs: OPTIMIZER_RUNS },
        generatedAt: new Date().toISOString(),
        sourceCount: files.length,
        contractCount: contractCount,
        contracts: artifacts
      },
      null,
      2
    ) + "\n"
  );

  console.log("");
  if (errorCount > 0) {
    console.log(
      "FAILED - " +
        errorCount +
        " error" +
        (errorCount === 1 ? "" : "s") +
        ", " +
        ownWarnCount +
        " warning" +
        (ownWarnCount === 1 ? "" : "s") +
        "." +
        hiddenNote
    );
    console.log("Partial artifacts: " + toUnitName(OUT_FILE));
    process.exit(1);
  }

  for (const key of Object.keys(artifacts)) {
    const a = artifacts[key];
    if (a.deployedSizeBytes > EIP170_LIMIT) {
      console.log(
        "  ! " +
          key +
          " runtime size " +
          a.deployedSizeBytes +
          " bytes exceeds the " +
          EIP170_LIMIT +
          "-byte EIP-170 limit"
      );
    }
  }

  console.log(
    "OK - " +
      contractCount +
      " contract" +
      (contractCount === 1 ? "" : "s") +
      " compiled, " +
      ownWarnCount +
      " warning" +
      (ownWarnCount === 1 ? "" : "s") +
      "." +
      hiddenNote
  );
  console.log("Artifacts: " + toUnitName(OUT_FILE));
  process.exit(0);
}

main();
