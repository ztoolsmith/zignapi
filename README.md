# zignapi

Écrire des addons Node.js en [Zig](https://ziglang.org/) — le **napi-rs du Zig**.

Tu écris des fonctions Zig normales, tu les déclares avec **un seul appel
comptime**, et zignapi produit soit un addon **natif `.node`**, soit un module
**WebAssembly** — **la même déclaration, deux backends, la même API JS**. Pas de
`node-gyp`, pas de glue C, pas de `.d.ts` écrit à la main.

```zig
const std = @import("std");
const zignapi = @import("zignapi");

const Point = struct { x: i32, y: i32 };

// L'allocateur d'appel est injecté ; on retourne des données possédées,
// zignapi les convertit en JS (structs → objets, slices → tableaux) PUIS libère.
pub fn doubles(a: std.mem.Allocator, xs: []const i32) ![]const Point {
    const out = try a.alloc(Point, xs.len);
    for (xs, 0..) |v, i| out[i] = .{ .x = v, .y = v * 2 };
    return out;
}

comptime {
    zignapi.register(.{ .doubles = doubles });
}
```

```js
const { doubles } = require("my-addon");
doubles([1, 2, 3]); // → [ { x: 1, y: 2 }, { x: 2, y: 4 }, { x: 3, y: 6 } ]
```

Et le `.d.ts` est généré tout seul :
`export function doubles(arg0: Array<number>): Array<{ x: number; y: number }>;`

## Ce que ça fait

**Conversions (comptime, deux sens, récursives)** — entiers, flottants, `bool`,
`[]const u8` (string), **struct ↔ objet**, **slice ↔ tableau**, `?T ↔ T | null`,
**enum → string**, **union taguée → `{ type, …payload }`**. Le `.d.ts` rend la
même structure (des vrais types, pas des `any`).

**Paramètres injectés** (ne consomment pas d'argument JS) — `std.mem.Allocator`
(l'arène d'appel : alloue ton résultat, zignapi le convertit puis le libère),
`napi.Env` / `napi.Value` (échappatoires bas niveau).

**Le reste** — erreurs à message custom (`return zignapi.fail("…")` → exception
JS), **constantes** de module (`.VERSION = "1.0.0"`), **async** (`zignapi.asyncFn(f)`
→ `Promise`) et **threadsafe functions** (appeler un callback JS depuis n'importe
quel thread) — natif uniquement.

**Backend WASM** — `zignapi build --target wasm` compile la MÊME déclaration en
`wasm32-freestanding` (**pas de WASI** : calcul pur, rien à polyfiller dans le
navigateur) et génère une glue `wasm.js` **synchrone** exposant **l'API identique**.
Deux backends, une vérité.

**Packaging (parité napi-rs)** — cross-compilation native (Zig cross-compile
tout depuis n'importe quel hôte), packages npm par plateforme
(`<scope>/<name>-<triple>` + `optionalDependencies`), `exports` map dual-backend
(navigateur → `wasm.js`, Node → natif), config **source unique** dans le champ
`"zignapi"` du `package.json`.

## Prérequis

- **Zig 0.16.0** exactement (le comptime dans `native/` repose sur les API 0.16).
- **Node.js ≥ 18**, **N-API version 8**.
- **pnpm** pour le workspace.

## Structure

```
zignapi/
├── packages/zignapi/          # LE package (lib Zig + CLI npm `zignapi`)
│   ├── native/                # la bibliothèque Zig — module @import("zignapi")
│   │   ├── register.zig       #   register() : branche natif/wasm selon la cible
│   │   ├── convert.zig        #   conversions Zig↔JS comptime
│   │   ├── typedefs.zig       #   génération du .d.ts
│   │   ├── napi.zig           #   bindings N-API (backend natif)
│   │   ├── wasm.zig           #   backend WebAssembly (ABI ptr/len + JSON)
│   │   ├── async.zig errors.zig root.zig
│   │   └── vendor/            #   headers N-API vendored
│   ├── src/                   # la CLI TypeScript (build, new, prepublish, config…)
│   ├── templates/             # arbre copié par `zignapi new`
│   └── build.zig(.zon)
└── examples/hello-world/      # addon exerçant tout le pipeline (natif + wasm)
```

## Essayer

```sh
pnpm install
pnpm --filter hello-world-example build   # compile l'addon via la CLI zignapi
pnpm --filter hello-world-example test    # node --test
```

## Démarrer un projet

```sh
npm install -g zignapi
zignapi new my-addon
cd my-addon
zignapi build            # → my-addon.node + index.js + index.d.ts
```

Détails de la CLI et de l'API : [`packages/zignapi/README.md`](packages/zignapi/README.md).
Architecture et journal : [`CLAUDE.md`](CLAUDE.md).

## Licence

MIT.
