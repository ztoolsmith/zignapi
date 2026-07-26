import { spawnSync, type SpawnSyncReturns } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import process from "node:process";

// From the compiled entry (dist/zig.js) or the source (src/zig.ts), one level
// up is the package root.
const PKG_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

/** Options for {@link runZig}. */
export interface RunZigOptions {
  /** Path to a build.zig.zon whose fingerprint may be auto-repaired on failure. */
  repairZon?: string;
}

/**
 * The version of the zignapi Zig library — the SINGLE source of truth for the
 * release tag and tarball name. Read from this package's package.json, which is
 * always present (even in a published npm install), so `releaseUrl` resolves
 * everywhere. `scripts/pack-native.mjs` reads the same field to name the
 * tarball and stamp `build.zig.zon`, so the three can never drift: bump the
 * version in `packages/zignapi/package.json` and everything follows.
 */
export function packageVersion(): string {
  const pkg = JSON.parse(readFileSync(join(PKG_ROOT, "package.json"), "utf8")) as {
    version?: string;
  };
  if (!pkg.version) {
    throw new Error("could not read .version from the zignapi package.json");
  }
  return pkg.version;
}

/**
 * The hosted release tarball of the zignapi Zig package, used as the default
 * (portable, shareable) dependency source. The version comes from
 * {@link packageVersion}, so `zignapi new` requests `v<version>` and
 * `zig fetch --save` records that same version in the generated build.zig.zon.
 * Overridable via ZIGNAPI_RELEASE_URL — handy for testing against a local
 * `file://` tarball or a mirror.
 */
export function releaseUrl(): string {
  const override = process.env.ZIGNAPI_RELEASE_URL;
  if (override) return override;
  const v = packageVersion();
  return `https://github.com/zignapi/zignapi/releases/download/v${v}/zignapi-${v}.tar.gz`;
}

/**
 * Locate the zignapi Zig package (the directory holding build.zig.zon, whose
 * `.paths` expose only build.zig, build.zig.zon and native/). It is the package
 * root, resolvable in a monorepo checkout — but it is intentionally NOT
 * published to npm (`files` = dist, templates), so a published install always
 * uses the hosted release instead. This backs `--local` and the offline
 * fallback of `zignapi new` from a source checkout.
 */
export function resolveZignapiSources(): string {
  if (existsSync(join(PKG_ROOT, "build.zig.zon"))) return PKG_ROOT;
  throw new Error(
    "could not locate the zignapi Zig package (build.zig.zon) shipped with the CLI",
  );
}

/**
 * Run `zig` with the given args in `cwd`. If the run fails because
 * `build.zig.zon` is missing/has an invalid fingerprint and `repairZon` is
 * given, patch in the value Zig suggests and retry once. On success, forwards
 * zig's output; on failure, forwards it and throws.
 */
export function runZig(
  cwd: string,
  args: string[],
  { repairZon }: RunZigOptions = {},
): SpawnSyncReturns<string> {
  let res = spawnSync("zig", args, { cwd, encoding: "utf8" });

  if (res.error) {
    if ((res.error as NodeJS.ErrnoException).code === "ENOENT") {
      throw new Error("could not find `zig` on PATH (Zig 0.16.0 is required)");
    }
    throw res.error;
  }

  if (res.status !== 0 && repairZon) {
    const suggested = (res.stderr ?? "").match(
      /(?:suggested value|use this value): (0x[0-9a-fA-F]+)/,
    );
    if (suggested) {
      patchFingerprint(repairZon, suggested[1]);
      res = spawnSync("zig", args, { cwd, encoding: "utf8" });
    }
  }

  process.stdout.write(res.stdout ?? "");
  process.stderr.write(res.stderr ?? "");
  if (res.status !== 0) {
    throw new Error(`zig ${args[0] ?? ""} failed`);
  }
  return res;
}

/** Extract a human-readable message from an unknown thrown value. */
export function errMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

/** Insert or replace the `.fingerprint` field in a build.zig.zon. */
export function patchFingerprint(zonPath: string, value: string): void {
  if (!existsSync(zonPath)) return;
  let src = readFileSync(zonPath, "utf8");
  if (/\.fingerprint\s*=\s*0x[0-9a-fA-F]+/.test(src)) {
    src = src.replace(/\.fingerprint\s*=\s*0x[0-9a-fA-F]+/, `.fingerprint = ${value}`);
  } else {
    // Insert right after the `.name = ...,` line.
    src = src.replace(/(\.name\s*=\s*[^\n]*,\n)/, `$1    .fingerprint = ${value},\n`);
  }
  writeFileSync(zonPath, src);
}
