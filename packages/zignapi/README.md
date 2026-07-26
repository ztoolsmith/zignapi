# zignapi

Écrire des addons Node.js en **Zig** — le napi-rs du Zig. Une seule déclaration
comptime produit un addon **natif `.node`** ou un module **WebAssembly**, avec la
même API JS et un `.d.ts` généré. CLI en TypeScript, **zéro dépendance runtime**,
pas de `node-gyp`.

Prérequis : **Zig 0.16.0** dans le `PATH`, **Node ≥ 18**.

```sh
npm install -g zignapi   # installe la commande `zignapi`
```

## Déclarer des fonctions

```zig
const std = @import("std");
const zignapi = @import("zignapi");

pub fn greet(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "Hello, {s}!", .{name});
}

comptime {
    zignapi.register(.{
        .greet = greet,
        .VERSION = "1.0.0", // une valeur non-fonction = une constante du module
    });
}
```

`register(.{ … })` est **LA** déclaration unique. La cible décide de l'artefact
(natif ou wasm) ; la branche morte est élaguée au comptime.

### Conversions (comptime, deux sens, récursives)

| Zig | JS | `.d.ts` |
|---|---|---|
| `i8…i64` / `u8…u64`, `f32`/`f64` | number | `number` |
| `bool` | boolean | `boolean` |
| `[]const u8` | string | `string` |
| `struct { … }` | `{ … }` | `{ a: T; … }` |
| `[]T` (T ≠ `u8`) | `Array<T>` | `Array<T>` |
| `?T` | `T \| null` | `T \| null` |
| `enum` | le `@tagName` | `"a" \| "b"` |
| `union(enum)` | `{ type: "<tag>", …payload }` | union |

### Paramètres injectés (ne consomment pas d'argument JS)

- **`std.mem.Allocator`** — l'arène d'appel. Alloues-y ton résultat et retourne-le :
  zignapi le convertit en JS **puis libère** l'arène (règle de lifetime).
- **`napi.Env`** / **`napi.Value`** — échappatoires bas niveau (valeur JS brute).

### Erreurs, async, threadsafe (natif)

- `return zignapi.fail("message")` → une exception JS au message custom
  (un `!T` qui fuit sans `fail` lève `@errorName(err)`).
- `zignapi.asyncFn(f)` → exécute `f` sur le thread pool de libuv, retourne une `Promise`.
- `zignapi.ThreadsafeFunction(T)` → appeler un callback JS depuis n'importe quel thread.

## Commandes

```sh
zignapi new <name>              # scaffolde ./<name> depuis le template intégré
zignapi build                   # hôte : <name>.node + bindings.js + index.js + index.d.ts
zignapi build --target <triple> # cross-compile un triple → npm/<triple>/
zignapi build --target wasm     # backend WASM : <name>.wasm + wasm.js + wasm.d.ts
zignapi build --all             # tous les targets de la config (résilient)
zignapi build --release         # -Doptimize=ReleaseFast (ReleaseSmall pour wasm)
zignapi prepublish              # assemble les packages par plateforme + l'exports map
```

- `new` copie le template et épingle la dépendance Zig `zignapi` (`zig fetch --save`).
- `build` lance `zig build`, copie le binaire, et génère le loader + les types.
  Zig **cross-compile nativement** — un `.node` linux/darwin se produit depuis
  n'importe quel hôte (seul **win32-msvc** exige un hôte Windows : Zig ne fournit
  pas la libc MSVC).

## Config — le champ `"zignapi"` du `package.json` (source unique)

```jsonc
{
  "name": "@me/mylib",
  "version": "1.0.0",              // héritée par les packages de plateforme
  "zignapi": {
    "binaryName": "mylib",         // nomme les fichiers .node/.wasm
    "packageName": "@me/binding",  // nomme les packages de plateforme (déf: name)
    "targets": ["darwin-arm64", "linux-x64-gnu", "wasm"]
  }
}
```

Dérivations : binaire `<binaryName>.<triple>.node`, package plateforme
`<packageName>-<triple>`, version héritée, loader généré depuis `targets`.
Défauts : `binaryName`/`packageName` absents → le `name` ; `targets` absent → le
triple de la machine courante.

## Le layout généré

| Fichier | Rôle |
|---|---|
| `bindings.js` | le loader **natif** (détecte plateforme/libc, résout `.node`) |
| `index.js` | l'entrée publique Node (re-export de `bindings.js`) |
| `wasm.js` | la glue **WASM** — UMD, synchrone, API identique, module embarqué |
| `index.d.ts` | les types (source unique) |
| `wasm.d.ts` | un alias `export * from "./index.js"` (jamais une copie) |
| `<binaryName>.wasm` | le module WASM |

`prepublish` (si `wasm` est ciblé) écrit l'`exports` map (`types` en premier,
`browser`→`wasm.js`, `node`→`index.js`) : un bundler prend le wasm, Node le natif.

## Structure de ce package

Deux produits dans un package :

- `native/` — la **bibliothèque Zig** (module `@import("zignapi")`) :
  `register.zig` (branche natif/wasm), `convert.zig`, `typedefs.zig`, `napi.zig`,
  `wasm.zig`, `async.zig`, `errors.zig`, `root.zig` + `vendor/` (headers N-API).
- `src/` — la **CLI TypeScript** (`cli`, `build`, `new`, `zig`, `config`,
  `triples`, `loader`, `packaging`, `prepublish`), compilée en `dist/`.
- `templates/` — l'arbre copié par `zignapi new`.

## Développement

```sh
pnpm install
pnpm --filter zignapi build   # zig build (checks) + tsc (CLI)
pnpm --filter zignapi test    # zig build test (comptime + conversions)
```
