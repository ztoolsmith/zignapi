import process from "node:process";

/**
 * The platform "triple" table.
 *
 * Triple names follow napi-rs exactly (`darwin-arm64`, `linux-x64-gnu`, …) so
 * the generated packages and loader are compatible with the wider tooling
 * ecosystem. Each entry carries what two consumers need:
 *   - `os` / `cpu` / `libc` — the npm `package.json` fields of the per-platform
 *     package (npm uses these to install only the matching binary), and
 *   - `zig` — the `-Dtarget=` value Zig cross-compiles to. This is zignapi's
 *     structural advantage: Zig cross-compiles natively, no C toolchain wrangling.
 *
 * The tricky cases are documented inline: linux splits gnu (glibc) vs musl, and
 * Windows uses the msvc ABI.
 */
export interface TripleInfo {
  /** npm `os` field. */
  os: string;
  /** npm `cpu` field. */
  cpu: string;
  /** npm `libc` field (linux only; distinguishes glibc from musl). */
  libc?: string;
  /** The Zig `-Dtarget=` triple. */
  zig: string;
}

export const TRIPLES: Record<string, TripleInfo> = {
  "darwin-arm64": { os: "darwin", cpu: "arm64", zig: "aarch64-macos" },
  "darwin-x64": { os: "darwin", cpu: "x64", zig: "x86_64-macos" },
  "linux-x64-gnu": { os: "linux", cpu: "x64", libc: "glibc", zig: "x86_64-linux-gnu" },
  "linux-x64-musl": { os: "linux", cpu: "x64", libc: "musl", zig: "x86_64-linux-musl" },
  "linux-arm64-gnu": { os: "linux", cpu: "arm64", libc: "glibc", zig: "aarch64-linux-gnu" },
  "linux-arm64-musl": { os: "linux", cpu: "arm64", libc: "musl", zig: "aarch64-linux-musl" },
  "win32-x64-msvc": { os: "win32", cpu: "x64", zig: "x86_64-windows-msvc" },
  "win32-arm64-msvc": { os: "win32", cpu: "arm64", zig: "aarch64-windows-msvc" },
};

/**
 * The special `wasm` target: not a platform triple (no os/cpu/libc, no
 * per-platform package) but a valid build target. It cross-compiles to
 * `wasm32-freestanding` and ships in the MAIN package (wasm.js + .wasm), routed
 * by the package.json `exports` map.
 */
export const WASM_TARGET = "wasm";

/** All triple names zignapi knows how to build. */
export function knownTriples(): string[] {
  return Object.keys(TRIPLES);
}

/** Every valid `targets` entry: the platform triples plus `wasm`. */
export function isValidTarget(target: string): boolean {
  return target === WASM_TARGET || target in TRIPLES;
}

/** Look up a triple, throwing a clear error (with the valid list) if unknown. */
export function tripleInfo(triple: string): TripleInfo {
  const info = TRIPLES[triple];
  if (!info) {
    throw new Error(
      `unknown target '${triple}'. Known triples: ${knownTriples().join(", ")}`,
    );
  }
  return info;
}

/** The Zig `-Dtarget=` value for a target (a triple, or `wasm`). */
export function zigTarget(target: string): string {
  if (target === WASM_TARGET) return "wasm32-freestanding";
  return tripleInfo(target).zig;
}

/** glibc vs musl on the host (linux only), with no external dependency. */
function currentLibc(): string {
  try {
    const report = process.report.getReport() as { header?: { glibcVersionRuntime?: string } };
    return report.header?.glibcVersionRuntime ? "gnu" : "musl";
  } catch {
    return "gnu";
  }
}

/**
 * The napi-rs triple of the machine this runs on. Used as the default `targets`
 * when a project doesn't list any (the "I'm just building locally" case). Mirrors
 * the logic embedded in the generated loader.
 */
export function currentTriple(): string {
  const arch = process.arch;
  if (process.platform === "darwin") return `darwin-${arch}`;
  if (process.platform === "win32") return `win32-${arch}-msvc`;
  if (process.platform === "linux") return `linux-${arch}-${currentLibc()}`;
  return `${process.platform}-${arch}`;
}
