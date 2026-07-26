import { parseArgs } from "node:util";
import { existsSync, copyFileSync, readdirSync, writeFileSync, readFileSync } from "node:fs";
import { join, basename, extname } from "node:path";
import { createRequire } from "node:module";
import process from "node:process";
import { runZig, errMessage } from "./zig.js";
import { loadConfig, type ZignapiConfig } from "./config.js";
import { zigTarget, WASM_TARGET } from "./triples.js";
import {
  generateLoader,
  generateIndexEntry,
  generateWasmGlue,
  generateWasmDts,
} from "./loader.js";
import { writePlatformPackage, binaryFileName, npmDir } from "./packaging.js";

const BUILD_HELP = `zignapi build — build the addon in the current directory

Usage:
  zignapi build [--release]
  zignapi build --target <triple> [--release]
  zignapi build --all [--release]

Options:
  --target <t>  Cross-compile for one target: a triple (e.g. linux-x64-gnu) into
                npm/<triple>/, or 'wasm' → the WASM backend (wasm.js + .wasm)
  --all         Build every target listed in zignapi.config
  --release     Optimize the build (-Doptimize=ReleaseFast / ReleaseSmall for wasm)
  -h, --help    Show this help

With no target, builds for the host: copies the addon to ./<name>.node and
generates bindings.js (the native loader), index.js (the public entry) and
index.d.ts. 'wasm' produces <name>.wasm + wasm.js (a standalone, synchronous glue
with the SAME API) + wasm.d.ts. Cross triples only produce the binary +
npm/<triple>/package.json (a foreign binary can't be loaded to introspect here).
`;

export async function runBuild(argv: string[]): Promise<void> {
  const { values } = parseArgs({
    args: argv,
    options: {
      release: { type: "boolean", default: false },
      target: { type: "string" },
      all: { type: "boolean", default: false },
      help: { type: "boolean", short: "h", default: false },
    },
  });

  if (values.help) {
    process.stdout.write(BUILD_HELP);
    return;
  }

  const cwd = process.cwd();
  if (!existsSync(join(cwd, "build.zig"))) {
    throw new Error("no build.zig found in the current directory");
  }

  const config = loadConfig(cwd);
  const release = values.release ?? false;

  if (values.all) {
    // Build every target, but don't let one host-specific gap (e.g. Windows-msvc
    // needs the MSVC SDK, absent on macOS/Linux) abort the rest. Collect the
    // failures and report them, then still produce the host dev artifacts.
    const failures: string[] = [];
    for (const target of config.targets) {
      try {
        if (target === WASM_TARGET) buildWasm(cwd, release, config);
        else buildTriple(cwd, target, release, config);
      } catch (err) {
        failures.push(target);
        process.stderr.write(`✗ ${target}: ${errMessage(err)}\n`);
      }
    }
    buildHost(cwd, release, config);
    if (failures.length > 0) {
      process.stderr.write(
        `\n${failures.length}/${config.targets.length} target(s) could not be cross-compiled ` +
          `on this host: ${failures.join(", ")}.\n` +
          `Windows-msvc needs the MSVC SDK (Zig can't provide it) — build those on a ` +
          `Windows host/CI. The rest are in npm/.\n`,
      );
      process.exitCode = 1;
    }
    return;
  }

  if (values.target !== undefined) {
    if (values.target === WASM_TARGET) buildWasm(cwd, release, config);
    else buildTriple(cwd, values.target, release, config);
    return;
  }

  buildHost(cwd, release, config);
}

/** Build for the host: copy the addon to the project root and generate bindings. */
function buildHost(cwd: string, release: boolean, config: ZignapiConfig): void {
  runZigBuild(cwd, release);

  const addonPath = findAddon(join(cwd, "zig-out"));
  if (!addonPath) {
    throw new Error("build succeeded but no addon (.node or shared library) was found under zig-out");
  }

  const nodeFile = addonName(addonPath);
  copyFileSync(addonPath, join(cwd, nodeFile));
  process.stdout.write(`✔ built ${nodeFile}\n`);

  generateBindings(cwd, nodeFile, config);
}

/**
 * Build the WASM backend: `<binary>.wasm` + `wasm.js` (a standalone, synchronous
 * glue with the SAME API) + `wasm.d.ts` (types alias) + `index.d.ts`. Reads the
 * addon's own `__zignapi_meta` (by instantiating the freshly built module) to
 * learn the surface — no separate introspection needed.
 */
function buildWasm(cwd: string, _release: boolean, config: ZignapiConfig): void {
  // wasm is always ReleaseSmall — a debug wasm is impractically large and there
  // is no reason to ship an unoptimized one.
  runZig(cwd, ["build", `-Dtarget=${zigTarget(WASM_TARGET)}`, "-Doptimize=ReleaseSmall"], {
    repairZon: join(cwd, "build.zig.zon"),
  });

  const wasmPath = findWasm(join(cwd, "zig-out"));
  if (!wasmPath) {
    throw new Error("wasm build succeeded but no .wasm was found under zig-out");
  }

  const wasmFile = `${config.binaryName}.wasm`;
  copyFileSync(wasmPath, join(cwd, wasmFile));

  const meta = readWasmMeta(wasmPath);
  const wasmBase64 = readFileSync(wasmPath).toString("base64");
  writeFileSync(
    join(cwd, "wasm.js"),
    generateWasmGlue({ returns: meta.returns, consts: meta.consts, wasmBase64 }),
  );
  writeFileSync(join(cwd, "wasm.d.ts"), generateWasmDts());
  if (meta.dts) {
    writeFileSync(join(cwd, "index.d.ts"), `// Generated by zignapi — do not edit.\n\n${meta.dts}`);
  }
  process.stdout.write(`✔ built ${wasmFile} + wasm.js + wasm.d.ts\n`);
}

interface WasmMeta {
  dts: string;
  returns: Record<string, string>;
  consts: Record<string, unknown>;
}

/** Instantiate a freshly built `.wasm` and read its embedded `__zignapi_meta`. */
function readWasmMeta(wasmPath: string): WasmMeta {
  const bytes = readFileSync(wasmPath);
  const instance = new WebAssembly.Instance(new WebAssembly.Module(bytes), {});
  const ex = instance.exports as Record<string, CallableFunction> & {
    memory: WebAssembly.Memory;
  };
  const packed = (ex.__zignapi_meta as () => bigint)();
  const ptr = Number(packed >> 32n);
  const len = Number(packed & 0xffffffffn);
  const json = new TextDecoder().decode(new Uint8Array(ex.memory.buffer, ptr, len));
  return JSON.parse(json) as WasmMeta;
}

/** Cross-compile one triple into npm/<triple>/<binary>.node (+ its package.json). */
function buildTriple(cwd: string, triple: string, release: boolean, config: ZignapiConfig): void {
  runZigBuild(cwd, release, zigTarget(triple));

  const addonPath = findAddon(join(cwd, "zig-out"));
  if (!addonPath) {
    throw new Error(`build for ${triple} succeeded but no addon was found under zig-out`);
  }

  const dir = writePlatformPackage(cwd, triple, config);
  const binary = binaryFileName(config, triple);
  copyFileSync(addonPath, join(dir, binary));
  process.stdout.write(`✔ built ${triple} → ${join("npm", triple, binary)}\n`);
}

function runZigBuild(cwd: string, release: boolean, target?: string): void {
  const args = ["build"];
  if (target) args.push(`-Dtarget=${target}`);
  if (release) args.push("-Doptimize=ReleaseFast");
  runZig(cwd, args, { repairZon: join(cwd, "build.zig.zon") });
}

/**
 * Emit the native-backend JS: `bindings.js` (the standalone multi-platform
 * loader), `index.js` (the public entry that re-exports it), and `index.d.ts`
 * (from the addon's embedded `__zignapi_dts__`). `bindings.js`/`index.js` are
 * always written; `.d.ts` is skipped if the freshly built addon can't be loaded
 * to introspect (non-fatal).
 */
function generateBindings(cwd: string, nodeFile: string, config: ZignapiConfig): void {
  const binaryName = basename(nodeFile, ".node");
  writeFileSync(
    join(cwd, "bindings.js"),
    generateLoader({ binaryName, packageName: config.packageName, targets: config.targets }),
  );
  writeFileSync(join(cwd, "index.js"), generateIndexEntry());

  const require = createRequire(import.meta.url);
  let addon: Record<string, unknown>;
  try {
    addon = require(join(cwd, nodeFile)) as Record<string, unknown>;
  } catch (err) {
    process.stderr.write(
      `note: wrote bindings.js/index.js but skipped index.d.ts (could not load ${nodeFile}: ${errMessage(err)})\n`,
    );
    return;
  }

  const dts = addon.__zignapi_dts__;
  if (typeof dts !== "string" || dts.length === 0) {
    process.stderr.write("note: addon has no embedded type info; skipping index.d.ts\n");
    return;
  }

  writeFileSync(join(cwd, "index.d.ts"), `// Generated by zignapi — do not edit.\n\n${dts}`);
  process.stdout.write("✔ generated bindings.js + index.js + index.d.ts\n");
}

/** Find the built `.wasm` under zig-out. */
function findWasm(dir: string): string | null {
  const walk = (d: string): string | null => {
    if (!existsSync(d)) return null;
    for (const entry of readdirSync(d, { withFileTypes: true })) {
      const p = join(d, entry.name);
      if (entry.isDirectory()) {
        const found = walk(p);
        if (found) return found;
      } else if (entry.name.endsWith(".wasm")) {
        return p;
      }
    }
    return null;
  };
  return walk(dir);
}

/**
 * Find the built addon under zig-out. Prefers an already-named `.node`,
 * falling back to the first shared library it finds.
 */
function findAddon(dir: string): string | null {
  const nodes: string[] = [];
  const libs: string[] = [];
  const walk = (d: string): void => {
    if (!existsSync(d)) return;
    for (const entry of readdirSync(d, { withFileTypes: true })) {
      const p = join(d, entry.name);
      if (entry.isDirectory()) {
        walk(p);
      } else if (entry.isFile()) {
        if (entry.name.endsWith(".node")) nodes.push(p);
        else if (/\.(dylib|so|dll)$/.test(entry.name)) libs.push(p);
      }
    }
  };
  walk(dir);
  return nodes[0] ?? libs[0] ?? null;
}

/** The `<name>.node` filename to copy an addon to at the project root. */
function addonName(addon: string): string {
  if (extname(addon) === ".node") return basename(addon);
  // libfoo.dylib -> foo.node
  let name = basename(addon, extname(addon));
  if (name.startsWith("lib")) name = name.slice(3);
  return `${name}.node`;
}

// Re-export for callers that assemble packages without building.
export { npmDir };
