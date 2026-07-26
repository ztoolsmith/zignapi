import { parseArgs } from "node:util";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import process from "node:process";
import { loadConfig, type ZignapiConfig } from "./config.js";
import { knownTriples, WASM_TARGET } from "./triples.js";
import { writePlatformPackage, platformPackageName, npmDir, binaryFileName } from "./packaging.js";

const PREPUBLISH_HELP = `zignapi prepublish — assemble the per-platform npm packages

Usage:
  zignapi prepublish

Reads the "zignapi" field of package.json, then:
  - writes npm/<triple>/package.json for every configured target (run
    "zignapi build --all" first to put the binaries there), and
  - fills the main package.json's optionalDependencies with the per-platform
    packages (and ensures index.js/index.d.ts are in "files").

Does NOT publish anything.
`;

export async function runPrepublish(argv: string[]): Promise<void> {
  const { values } = parseArgs({
    args: argv,
    options: { help: { type: "boolean", short: "h", default: false } },
  });
  if (values.help) {
    process.stdout.write(PREPUBLISH_HELP);
    return;
  }

  const cwd = process.cwd();
  const config = loadConfig(cwd);

  // The platform triples get a per-platform package; `wasm` doesn't (it ships in
  // the MAIN package, routed by the `exports` map — see below).
  const triples = config.targets.filter((t) => t !== WASM_TARGET);
  const hasWasm = config.targets.includes(WASM_TARGET);

  // 1. Per-platform package.json (+ report whether the binary is present).
  for (const triple of triples) {
    writePlatformPackage(cwd, triple, config);
    const binary = join(npmDir(cwd, triple), binaryFileName(config, triple));
    const present = existsSync(binary);
    process.stdout.write(
      `${present ? "✔" : "…"} npm/${triple}/package.json${present ? " (+ binary)" : " (binary missing — run `zignapi build --all`)"}\n`,
    );
  }

  // 2. Wire the main package.json.
  updateMainPackage(cwd, triples.map((t) => platformPackageName(config, t)), config, hasWasm);
  process.stdout.write(
    `✔ updated package.json (optionalDependencies, files${hasWasm ? ", browser + exports map" : ""})\n`,
  );
}

/**
 * Set the per-platform packages as `optionalDependencies` (npm installs only the
 * one matching the host's os/cpu/libc), make sure the JS/types are in `files`,
 * and — when `wasm` is a target — add the dual-backend `exports` map so bundlers
 * pick `wasm.js` for the browser and Node picks the native `index.js`.
 */
function updateMainPackage(
  cwd: string,
  packageNames: string[],
  config: ZignapiConfig,
  hasWasm: boolean,
): void {
  const path = join(cwd, "package.json");
  const pkg = JSON.parse(readFileSync(path, "utf8")) as Record<string, unknown>;

  const optional = { ...(pkg.optionalDependencies as Record<string, string> | undefined) };
  // Drop any previously-managed per-platform entry (a key ending in a known
  // triple) so a renamed `packageName` doesn't leave stale deps behind.
  for (const key of Object.keys(optional)) {
    if (knownTriples().some((t) => key.endsWith(`-${t}`))) delete optional[key];
  }
  for (const name of packageNames) optional[name] = config.version;
  pkg.optionalDependencies = sortKeys(optional);

  const files = new Set([...((pkg.files as string[]) ?? [])]);
  for (const f of ["index.js", "bindings.js", "index.d.ts"]) files.add(f);

  if (hasWasm) {
    const wasmFile = `${config.binaryName}.wasm`;
    for (const f of ["wasm.js", "wasm.d.ts", wasmFile]) files.add(f);
    pkg.main = "index.js";
    pkg.browser = "wasm.js";
    pkg.types = "index.d.ts";
    // Key ORDER matters: `types` MUST come first, then the runtime conditions.
    pkg.exports = {
      ".": {
        types: "./index.d.ts",
        browser: "./wasm.js",
        node: "./index.js",
        default: "./wasm.js",
      },
      // Keep the escape hatches importable (the `exports` map otherwise hides them).
      "./bindings.js": "./bindings.js",
      "./wasm.js": "./wasm.js",
    };
  }

  pkg.files = [...files];
  writeFileSync(path, JSON.stringify(pkg, null, 2) + "\n");
}

function sortKeys(obj: Record<string, string>): Record<string, string> {
  return Object.fromEntries(Object.entries(obj).sort(([a], [b]) => a.localeCompare(b)));
}
