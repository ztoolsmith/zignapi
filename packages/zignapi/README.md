# zignapi

Write Node.js addons in **Zig** — the napi-rs of Zig. A single comptime
declaration produces either a **native `.node` addon** or a **WebAssembly**
module, with the same JS API and a generated `.d.ts`. TypeScript CLI, **zero
runtime dependencies**, no `node-gyp`.

Requirements: **Zig 0.16.0** in `PATH`, **Node ≥ 18**.

```sh
npm install -g zignapi   # installs the `zignapi` command
```

## Declaring functions

```zig
const std = @import("std");
const zignapi = @import("zignapi");

pub fn greet(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "Hello, {s}!", .{name});
}

comptime {
    zignapi.register(.{
        .greet = greet,
        .VERSION = "1.0.0", // a non-function value becomes a module constant
    });
}
```

`register(.{ … })` is **THE** single declaration. The target decides the artifact
(native or wasm); the dead branch is pruned at comptime.

## How it works

Everything happens at **compile time**. `register` receives an anonymous struct,
walks its fields with `@typeInfo`, and for each function reads the parameter and
return types. From those types alone it generates, in the same pass:

1. **the entry point** for each function — argument extraction, conversion, error
   propagation (`register.zig`);
2. **the conversions both ways**, recursively (`convert.zig`) — a `struct` becomes
   a JS object, a slice an array, `?T` a `T | null`, an `enum` its tag name;
3. **the TypeScript declarations** (`typedefs.zig`) — the `.d.ts` is derived from
   the *same* type information, so it cannot drift from the implementation.

Because it is comptime, there is no reflection at runtime and no glue to
maintain: your Zig signature *is* the JS signature. Writing an addon comes down
to writing ordinary Zig functions and listing them once.

The **branch between backends** is comptime too. The native backend links libc
and resolves N-API symbols from the host process; the wasm backend targets
`wasm32-freestanding` (no WASI) and ships a small synchronous JS glue. Only the
branch matching the target is compiled — that is why one declaration covers both.

### Conversions (comptime, both ways, recursive)

| Zig | JS | `.d.ts` |
|---|---|---|
| `i8…i64` / `u8…u64`, `f32`/`f64` | number | `number` |
| `bool` | boolean | `boolean` |
| `[]const u8` | string | `string` |
| `struct { … }` | `{ … }` | `{ a: T; … }` |
| `[]T` (T ≠ `u8`) | `Array<T>` | `Array<T>` |
| `?T` | `T \| null` | `T \| null` |
| `enum` | the `@tagName` | `"a" \| "b"` |
| `union(enum)` | `{ type: "<tag>", …payload }` | union |

Composites recurse, so an unsupported leaf type fails **at comptime** with a
message pointing at the offending type.

### Injected parameters (they consume no JS argument)

- **`std.mem.Allocator`** — the call arena. Allocate your result in it and return
  it: zignapi converts it to JS **then frees** the arena. That is the lifetime
  rule — the copy into the JS engine happens while the memory is still alive, so
  there is no use-after-free and no leak, by construction.
- **`napi.Env`** / **`napi.Value`** — low-level escape hatches (raw JS value).

### Errors, async, threadsafe (native)

- `return zignapi.fail("message")` → a JS exception with a custom message
  (a `!T` that escapes without `fail` throws `@errorName(err)`).
- `zignapi.asyncFn(f)` → runs `f` on the libuv thread pool, returns a `Promise`.
- `zignapi.ThreadsafeFunction(T)` → call a JS callback from any thread.

## Commands

```sh
zignapi new <name>              # scaffolds ./<name> from the built-in template
zignapi build                   # host: <name>.node + bindings.js + index.js + index.d.ts
zignapi build --target <triple> # cross-compile one triple → npm/<triple>/
zignapi build --target wasm     # WASM backend: <name>.wasm + wasm.js + wasm.d.ts
zignapi build --all             # every target in the config (resilient)
zignapi build --release         # -Doptimize=ReleaseFast (ReleaseSmall for wasm)
zignapi prepublish              # assembles the platform packages + the exports map
```

- `new` copies the template and pins the `zignapi` Zig dependency (`zig fetch --save`).
- `build` runs `zig build`, copies the binary, then generates the loader and the
  types. Zig **cross-compiles natively** — a linux/darwin `.node` can be produced
  from any host. Only **win32-msvc** requires a Windows host: Zig does not ship
  the MSVC libc.

## Config — the `"zignapi"` field of `package.json` (single source)

```jsonc
{
  "name": "@me/mylib",
  "version": "1.0.0",              // inherited by the platform packages
  "zignapi": {
    "binaryName": "mylib",         // names the .node/.wasm files
    "packageName": "@me/binding",  // names the platform packages (default: name)
    "targets": ["darwin-arm64", "linux-x64-gnu", "wasm"]
  }
}
```

`binaryName` and `packageName` are **two independent axes**: one names the binary
*files*, the other the platform *packages*. Neither has to match the main `name`.

| Item | Derivation | Example |
|---|---|---|
| binary file | `<binaryName>.<triple>.node` | `mylib.darwin-arm64.node` |
| platform package | `<packageName>-<triple>` | `@me/binding-darwin-arm64` |
| platform version | inherited from `version` | `1.0.0` |
| loader | generated from `targets` + `packageName` | (inlined) |

Sane defaults: no `binaryName` → the `name` without its scope; no `packageName` →
the `name`; no `targets` → the current machine's triple.

## Supported triples

| npm triple | `os`/`cpu`/`libc` | Zig `-Dtarget` |
|---|---|---|
| darwin-arm64 | darwin / arm64 | aarch64-macos |
| darwin-x64 | darwin / x64 | x86_64-macos |
| linux-x64-gnu | linux / x64 / glibc | x86_64-linux-gnu |
| linux-x64-musl | linux / x64 / musl | x86_64-linux-musl |
| linux-arm64-gnu | linux / arm64 / glibc | aarch64-linux-gnu |
| linux-arm64-musl | linux / arm64 / musl | aarch64-linux-musl |
| win32-x64-msvc | win32 / x64 | x86_64-windows-msvc |
| win32-arm64-msvc | win32 / arm64 | aarch64-windows-msvc |

Triple names follow **napi-rs**, so the surrounding tooling stays compatible.

## The generated layout

| File | Role |
|---|---|
| `bindings.js` | the **native** loader (detects platform/libc, resolves the `.node`) |
| `index.js` | the public Node entry (re-exports `bindings.js`) |
| `wasm.js` | the **WASM** glue — UMD, synchronous, identical API, module embedded |
| `index.d.ts` | the types (single source) |
| `wasm.d.ts` | an alias `export * from "./index.js"` — never a copy |
| `<binaryName>.wasm` | the WASM module |

The loader resolves, in order: the dev `./<binary>.node` at the root, then
`./npm/<triple>/`, then the published `<packageName>-<triple>` package, and
otherwise raises a clear error listing the supported triples and everything it
tried. libc is detected without any dependency
(`process.report.getReport().header.glibcVersionRuntime` present ⇒ `gnu`).

`prepublish` (when `wasm` is targeted) writes the `exports` map (`types` first,
`browser`→`wasm.js`, `node`→`index.js`): a bundler picks up the wasm, Node the
native binary.

## What is in this package

Two products in one package:

- `native/` — the **Zig library** (the `@import("zignapi")` module):
  `register.zig` (the native/wasm branch), `convert.zig`, `typedefs.zig`,
  `napi.zig`, `wasm.zig`, `async.zig`, `errors.zig`, `root.zig` + `vendor/`
  (N-API headers). It is **not published to npm** — the Zig library is
  distributed through the GitHub release tarball, which `zignapi new` fetches.
- `src/` — the **TypeScript CLI** (`cli`, `build`, `new`, `zig`, `config`,
  `triples`, `loader`, `packaging`, `prepublish`), compiled into `dist/`.
- `templates/` — the tree copied by `zignapi new`.

## Development

```sh
pnpm install
pnpm --filter zignapi build   # zig build (checks) + tsc (CLI)
pnpm --filter zignapi test    # zig build test (comptime + conversions)
```

MIT.
