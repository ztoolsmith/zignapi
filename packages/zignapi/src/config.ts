import { existsSync, readFileSync } from "node:fs";
import { join, basename } from "node:path";
import { pathToFileURL } from "node:url";
import process from "node:process";
import { knownTriples, currentTriple, isValidTarget, WASM_TARGET } from "./triples.js";

/**
 * Packaging configuration — the **single source of truth is `package.json`**
 * (napi-rs style). Nothing is configured anywhere else:
 *
 * ```jsonc
 * {
 *   "name": "@zparse/zparse",      // the main published package
 *   "version": "1.0.0",            // inherited by the per-platform packages
 *   "zignapi": {
 *     "binaryName": "zparse",      // names the .node files
 *     "packageName": "@zparse/binding", // names the per-platform packages
 *     "targets": ["darwin-arm64", "linux-x64-gnu", ...]
 *   }
 * }
 * ```
 *
 * `binaryName` and `packageName` are **independent**: one names the binary
 * *files*, the other names the per-platform *packages*. Neither has to match the
 * main `name`.
 *
 * Derivations (everything else follows):
 *   - binary file       → `<binaryName>.<triple>.node`
 *   - platform package  → `<packageName>-<triple>`
 *   - platform version  → inherited from `version`
 *   - loader            → generated from `targets` + `packageName`
 */
export interface ZignapiConfig {
  /** Base name of the per-platform packages: `<packageName>-<triple>`. Default:
   * the main `name` (so nothing changes unless you set it). */
  packageName: string;
  /** The `.node` base name. Default: the unscoped `name`. */
  binaryName: string;
  /** Target triples (napi-rs names). Default: the host triple. */
  targets: string[];
  /** Version — inherited from `package.json`. */
  version: string;
}

/** The recognised keys inside the `"zignapi"` field. */
const KNOWN_KEYS = new Set(["binaryName", "packageName", "targets"]);

/** Deprecated standalone config files (superseded by the package.json field). */
const LEGACY_CONFIG_FILES = [
  "zignapi.config.ts",
  "zignapi.config.mjs",
  "zignapi.config.js",
  "zignapi.config.json",
];

interface PackageJson {
  name?: string;
  version?: string;
  zignapi?: Record<string, unknown>;
}

/**
 * Read the packaging config from `<cwd>/package.json`'s `"zignapi"` field.
 * Pure JSON — no transpilation, no dynamic import. Warns (and ignores) a leftover
 * `zignapi.config.*`, so there is exactly one source and no precedence to memorise.
 */
export function loadConfig(cwd: string): ZignapiConfig {
  warnOnLegacyConfig(cwd);

  const pkgPath = join(cwd, "package.json");
  if (!existsSync(pkgPath)) {
    throw new Error("no package.json found in the current directory");
  }
  const pkg = JSON.parse(readFileSync(pkgPath, "utf8")) as PackageJson;
  const field = pkg.zignapi ?? {};
  warnOnUnknownKeys(field);

  const name = pkg.name;
  if (!name) throw new Error("package.json has no `name`");
  validateNpmName(name, "name");

  // `packageName` decouples the per-platform package base from the main package
  // name (files vs packages are independent). Absent → the main name (zero churn).
  const packageName = typeof field.packageName === "string" ? field.packageName : name;
  validateNpmName(packageName, "zignapi.packageName");

  const binaryName = typeof field.binaryName === "string" ? field.binaryName : unscoped(name);
  const targets = validateTargets(Array.isArray(field.targets) ? (field.targets as string[]) : [currentTriple()]);

  return { packageName, binaryName, targets, version: pkg.version ?? "0.0.0" };
}

/** Reject a string that isn't a valid npm package name (optional `@scope/`,
 * lowercase, url-safe, ≤214 chars). Applied to both `name` and `packageName`. */
function validateNpmName(value: string, field: string): void {
  const ok = value.length <= 214 && /^(?:@[a-z0-9][a-z0-9-._]*\/)?[a-z0-9][a-z0-9-._]*$/.test(value);
  if (!ok) {
    throw new Error(`${field} '${value}' is not a valid npm package name`);
  }
}

function warnOnLegacyConfig(cwd: string): void {
  const legacy = LEGACY_CONFIG_FILES.find((f) => existsSync(join(cwd, f)));
  if (legacy) {
    process.stderr.write(
      `warning: ${legacy} is deprecated and IGNORED — move its settings into the ` +
        `"zignapi" field of package.json (single source of truth).\n`,
    );
  }
}

function warnOnUnknownKeys(field: Record<string, unknown>): void {
  for (const key of Object.keys(field)) {
    if (!KNOWN_KEYS.has(key)) {
      process.stderr.write(
        `warning: unknown key "zignapi.${key}" in package.json (known: ${[...KNOWN_KEYS].join(", ")})\n`,
      );
    }
  }
}

function validateTargets(targets: string[]): string[] {
  for (const t of targets) {
    if (!isValidTarget(t)) {
      throw new Error(`unknown target '${t}'. Known: ${knownTriples().join(", ")}, ${WASM_TARGET}`);
    }
  }
  return targets;
}

/** `@scope/foo` → `foo`; `foo` → `foo`. */
function unscoped(name: string): string {
  return name.startsWith("@") ? (name.split("/")[1] ?? name) : name;
}

// ---------------------------------------------------------------------------
// RESERVE (option 2): a programmatic `zignapi.config.{ts,mjs,js}` loader.
//
// Not wired into the CLI. The package.json field is the one source of truth. If
// a project ever needs *computed* config (targets from an env var, etc.), this
// is the seam to re-enable — load the module, take its default export, and merge
// it the same way. Kept here (dead but compiled) so the option stays documented
// and doesn't rot. A `.ts` here relies on Node's built-in type stripping.
// ---------------------------------------------------------------------------
export async function loadConfigFileReserved(file: string): Promise<Record<string, unknown>> {
  const mod = (await import(pathToFileURL(file).href)) as { default?: Record<string, unknown> };
  return mod.default ?? (mod as Record<string, unknown>);
}
