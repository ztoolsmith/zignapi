import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tripleInfo } from "./triples.js";
import type { ZignapiConfig } from "./config.js";

/** `<cwd>/npm/<triple>` — where a per-platform package is assembled. */
export function npmDir(cwd: string, triple: string): string {
  return join(cwd, "npm", triple);
}

/** The npm id of a per-platform package: `<packageName>-<triple>` (the scope
 * comes from `packageName`), e.g. `@zparse/zparse-linux-x64-gnu`. */
export function platformPackageName(config: ZignapiConfig, triple: string): string {
  return `${config.packageName}-${triple}`;
}

/** The binary file name for a triple: `<binaryName>.<triple>.node` (napi-rs). */
export function binaryFileName(config: ZignapiConfig, triple: string): string {
  return `${config.binaryName}.${triple}.node`;
}

/**
 * Write `npm/<triple>/package.json` describing the per-platform package: `os`/
 * `cpu`/`libc` gate installation to the matching machine, and `main` points at
 * the binary. Returns the directory (the caller copies the `.node` into it).
 */
export function writePlatformPackage(cwd: string, triple: string, config: ZignapiConfig): string {
  const info = tripleInfo(triple);
  const dir = npmDir(cwd, triple);
  mkdirSync(dir, { recursive: true });

  const binary = binaryFileName(config, triple);
  const pkg: Record<string, unknown> = {
    name: platformPackageName(config, triple),
    version: config.version,
    os: [info.os],
    cpu: [info.cpu],
    ...(info.libc ? { libc: [info.libc] } : {}),
    main: binary,
    files: [binary],
  };
  writeFileSync(join(dir, "package.json"), JSON.stringify(pkg, null, 2) + "\n");
  return dir;
}
