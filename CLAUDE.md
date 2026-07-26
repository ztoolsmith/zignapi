# zignapi

Écrire des addons Node.js natifs en **Zig** (l'équivalent Zig de napi-rs).
Monorepo pnpm. Fait partie de l'org `mon-org` (voir `../CLAUDE.md`).

## Structure

- `packages/zignapi/` — le package (lib Zig + CLI npm `zignapi`).
  - `native/` — la **bibliothèque Zig**, module `@import("zignapi")`.
    - `root.zig` (point d'entrée), `napi.zig` (bindings N-API bruts),
      `convert.zig` (conversions Zig↔JS comptime), `typedefs.zig` (génération
      des `.d.ts`), `async.zig` (asyncFn + ThreadsafeFunction),
      `errors.zig` (`fail` — messages d'exception custom),
      `register.zig` (branche napi/wasm selon la cible), `wasm.zig` (backend
      WebAssembly : ABI ptr/len + JSON), `_check.zig` (compile check).
    - `vendor/node-api-headers/` — headers N-API vendored (`@cImport`).
  - `src/` — la **CLI TypeScript** : `cli.ts`, `build.ts` (build + cross + wasm),
    `new.ts`, `zig.ts`, `prepublish.ts`, `config.ts` (lecture du champ `"zignapi"`
    de `package.json`), `triples.ts` (table Zig↔npm + triple hôte + cible `wasm`),
    `loader.ts` (génère `bindings.js`/`index.js`/`wasm.js`/`wasm.d.ts`),
    `packaging.ts` (packages `npm/<triple>/`).
  - `templates/` — arbre copié par `zignapi new`.
  - `build.zig`, `build.zig.zon` — build de la lib Zig + checks + tests.
- `examples/hello-world/` — addon d'exemple (sync, async, threadsafe) construit
  via la CLI `zignapi build`.

## Conventions

- TypeScript dans `src/`, Zig dans `native/` — jamais mélangés.
- Sorties : `dist/` (tsc) et `zig-out/` (zig build) — jamais versionnées.
- **Zig 0.16.0** exactement (API `b.addLibrary`, `createModule`, tags
  `@typeInfo` minuscules, `CallingConvention` `.c`). N-API version 8, Node >= 18.
- La CLI génère `index.js` + `index.d.ts` depuis les déclarations embarquées
  dans l'addon (`__zignapi_dts__`).
- **`native/` n'est PAS publié sur npm** (`files` = `dist`, `templates`). La lib
  Zig se distribue uniquement via le tarball de release GitHub
  (`scripts/pack-native.mjs`). Donc `zignapi new` par défaut fetch la release ;
  `--local` et le fallback hors-ligne ne marchent que dans le checkout monorepo.

## Commandes

```bash
pnpm install
pnpm build   # zig build (checks) + tsc (CLI) dans tous les packages
pnpm test
```

## Audit « napi-rs du Zig » (2026-07-25) — mesure avant la v1

> Audit **mesure seule, zéro code** demandé avant de faire de zignapi un vrai
> projet (cible : la 0.2.0 de zcompiler). Sonde : les 7 fichiers de `native/`
> (`convert`/`register`/`typedefs`/`napi`/`async`/`root` + la CLI `build.ts`/
> `zig.ts`) **et** toute la surface N-API de zcompiler (`zparse/native/main.zig`,
> ~30 fonctions). But : quantifier la glue manuelle, comparer à napi-rs, décider
> quoi construire.

### 1. Inventaire de l'existant

**Conversions de types** (`convert.zig` — c'est TOUT ce qui est auto-converti) :

| Type Zig | Sens | Statut |
|---|---|---|
| `i8…i64`, `u8…u64` (bits+signe) | JS↔Zig | ✅ (`int32`/`uint32`/`int64`) |
| `f32`/`f64` | JS↔Zig | ✅ (`double`) |
| `bool` | JS↔Zig | ✅ |
| `[]const u8` | JS↔Zig | ✅ string (fromJs copie dans l'arène) |
| `[]u8` (mutable), **struct, slice, `?T`, union, enum, Buffer** | — | ❌ `unsupported` (`@compileError`) |

**Enregistrement des fonctions** : `register(.{ .name = fn })` en `comptime`,
sans macro — une fonction Zig normale. `Wrap(func)` fabrique le trampoline C :
lit `argv`, convertit chaque param via `convert.fromJs`, appelle, convertit le
retour. Deux **échappatoires** : un param `env: napi.Env` (injecté, ne consomme
pas d'argument JS) et un param/retour `napi.Value` (passe brut, sans `convert`).
`asyncFn(f)` → variante worker-thread + Promise.

**Erreurs → exceptions** : un `!T` est déplié ; en cas d'erreur,
`napi.throwError(@errorName(err))` → une exception JS dont le message est **le
nom de l'enum d'erreur** (`"OutOfMemory"`), sans message ni code custom.

**`.d.ts`** : généré en `comptime` depuis les signatures (`typedefs.zig`),
embarqué dans l'addon (`__zignapi_dts__`), relu par `zignapi build` qui écrit
`index.js`+`index.d.ts`. Limites : params nommés `arg0/arg1`, et **tout retour
`napi.Value` → `any`**.

**Build/chargement** : `zignapi build` = `zig build` (host uniquement, seul flag
`--release`) → copie le `.node` → génère les bindings. Chargement = `require`.
**Pas de fichier de config**, pas de cross-compile exposé, pas de prebuilds npm
(le consommateur build depuis la source : prérequis Zig + checkout zignapi).

**Glue manuelle dans zcompiler** (`main.zig`, ~**180 lignes de glue sur 364**) —
**aucune** des ~30 fonctions n'utilise le chemin auto : toutes prennent
`env: napi.Env` et renvoient `napi.Value`. Trois raisons, trois patterns :

| Fonction(s) | Lignes de glue | Pourquoi l'échappatoire |
|---|---|---|
| `tokenize` | ~16 | construit `Array<{kind,start,end}>` à la main |
| `parseErrorsCore` | ~11 | construit `Array<{message,offset}>` à la main |
| `semanticCore` | ~25 | construit `{scopes,bindings,resolved,unresolved[],diagnostics[]}` à la main |
| `parse/print/transform/mangle/jsxTransform/stripTypes(+Tsx)` Core | ~8–13 chacun | **retour string alloué** : l'arène locale meurt avant le retour → doit `createString` soi-même (le chemin auto `[]const u8` ne peut PAS servir, cf. ci-dessous) |
| `transformCount`, `parseOnly` | ~3–5 | prennent `env` juste pour `convert.toJs` du retour scalaire |
| jumeaux `*Jsx/*Ts/*Tsx` (24 fns) | 2–3 ch. = **~66** | pure dispatch `return xCore(env, input, flags)` |
| helpers `doParse`, `throwDiag` | ~10 | wrappers throw écrits main |

**Fait le plus important** : même les retours string — que zignapi « supporte »
— passent par l'échappatoire. Cause racine : `Wrap` donne une arène pour
convertir les **arguments**, mais **n'en donne aucune à la fonction** pour son
**résultat**. Une fonction ne peut pas faire `fn print(input) ![]const u8` en
allouant la sortie, car le slice pointerait dans une arène déjà libérée
(use-after-free). D'où : prendre `env`, bâtir dans une arène locale, `createString`
(copie dans V8) pendant qu'elle vit, puis `deinit`. **C'est le blocage n°1.**

### 2. Matrice vs napi-rs

| Capacité | zignapi aujourd'hui | napi-rs | Verdict |
|---|---|---|---|
| Déclaration de fonction | `register(.{.n=fn})` comptime, fn Zig normale | `#[napi]` proc-macro | **ok** — ergonomie de base bonne |
| Strings | `[]const u8` ↔ string (2 sens) | `String`/`&str` | **ok en entrée / à refaire en sortie allouée** (lifetime arène) |
| Numbers | int (bits+signe) + f32/f64 (2 sens) | idem + BigInt | **ok** (BigInt hors périmètre) |
| Booleans | `bool` (2 sens) | `bool` | **ok** |
| Structs ↔ objects | ❌ rien (createObject+setNamedProperty main) | `#[napi(object)]` auto | **manquant** — cible n°1 |
| Slices ↔ arrays | ❌ rien (createArray+setElement main) | `Vec<T>`/`&[T]` | **manquant** — cible n°1 |
| Optionals | ❌ pas de `?T` | `Option<T>` ↔ `T\|null` | **manquant** |
| Tagged unions / enums | ❌ rien (`@tagName` à la main) | enums → union discriminée | **manquant** |
| Buffers / TypedArray | ❌ `[]u8` = `unsupported` | `Buffer`/`Uint8Array` | **manquant** |
| Errors → exceptions | `!T` → throw `@errorName` (nom seul) | `Result`/`Error{msg,code}` | **à refaire** (pas de message custom → `throwDiag` main) |
| Async / Promises | `asyncFn` → worker+Promise | `async fn`/`AsyncTask` | **ok** (existe ; pas encore éprouvé par zcompiler) |
| Threadsafe functions | `ThreadsafeFunction(T)` create/call/release | TSFN complète | **ok basique** — proposé **hors v1** |
| `.d.ts` auto | comptime + embarqué ; mais retours composites = `any`, params `argN` | complet (objets, enums, noms) | **à refaire** (débloqué par cible n°1) |
| Cross-compilation | ❌ non exposé (host only) — Zig SAIT pourtant | `napi build --target` | **manquant** (socle gratuit, juste à exposer) |
| npm multi-plateforme | ❌ build-from-source chez le consommateur | `@scope/pkg-os-arch` + optionalDeps | **manquant** |
| Fichier de config | ❌ aucun | champ `napi` dans package.json | **manquant** (mineur) |
| Docs / tests | tests Zig + `_check` compile ; zcompiler = banc d'essai | doc site + suite large | **partiel** |

### 3. Rapport

**Les 3 patterns de glue les plus répétés = les 3 premières cibles de l'API comptime :**

1. **Struct↔objet + slice↔array + enum→string** (`convert.zig`, comptime sur les
   champs). Tue `tokenize`, `parseErrors`, `semantic` (patterns « Array d'objets »
   et « objet mixte »). Rend leurs types `.d.ts` **réels** au lieu de `any`.
2. **Allocateur scratch par appel + retour à durée-de-vie gérée** : injecter un
   param `std.mem.Allocator` (reconnu comme `napi.Env`) et laisser une fonction
   renvoyer un `[]const u8`/`[]T` possédé que zignapi **convertit puis libère**.
   Tue toute la plomberie `env`/`napi.Value`/`ArrayList`/`createString` des
   retours string (pattern dominant, ~9 fns).
3. **Erreur à message custom** : un `!T` qui porte message+offset (pas seulement
   `@errorName`), pour supprimer `throwDiag` et le throw manuel de `mangle`.

**Plan par phases, chiffré en lignes de glue économisées sur zcompiler**
(base : ~180 lignes de glue) :

| Phase | Contenu (dans zignapi) | Glue zcompiler économisée | Après |
|---|---|---|---|
| **1** (v1) | conversions composites : struct↔objet, slice↔array, `?T`, enum→string | **~45 lignes** + 3 retours dé-`any`-fiés | `tokenize` 16→~2, `parseErrors` 11→~1, `semantic` 25→~4 |
| **2** (v1) | allocateur scratch + retour possédé converti-puis-libéré | **~50 lignes** | tous les retours string : ~11→~4 (`parse`/`print`/`transform`/`mangle`/`strip*`/`jsxTransform`) |
| **3** (v1) | erreur message+code ; `.d.ts` params nommés | **~10–15 lignes** | `throwDiag` supprimé ; messages JS propres |
| **4** (opt.) | arg struct d'options `{jsx,ts}` (débloqué par ph.1) | **~66 lignes** (les 24 jumeaux → 6) | **change l'API publique** de zcompiler → décision zcompiler |

**Bilan v1 (phases 1-3)** : ~105-110 lignes de glue sur 180 supprimées (**~58 %**).
Reste ≈ 75 lignes, dont ~66 sont les jumeaux (que la phase 4, optionnelle, ferait
tomber). **Critère de succès atteint** : après v1, chaque fonction cœur tient en
**≤ 5 lignes** (≤ 10 exigé ✅). Le « idéal 1 ligne » est atteint pour les jumeaux
et les fonctions de pure délégation ; le pousser plus loin demanderait à zcompiler
d'exposer une façade unique `compile(src, opts)` derrière ses passes (tâche
zcompiler, pas zignapi). Exemple visé après v1 :

```zig
// Avant : ~12 lignes (env, arène, ArrayList, createString, throwDiag…)
// Après :
fn print(a: Allocator, input: []const u8) ![]const u8 {
    const r = try parser.parseWith(a, input, false, false);
    var out: std.ArrayList(u8) = .empty;
    try printer.print(r.program, input, &out, a);
    return out.items; // zignapi convertit puis libère
}
fn tokenize(a: Allocator, input: []const u8) ![]const Token { // struct→objet auto
    var diag: lexer.Diagnostic = .{};
    return lexer.tokenizeDiag(a, input, &diag, false); // erreur → exception via !T
}
```

**Hors périmètre v1 (proposition à discuter) :**

- **Threadsafe functions** — existent (basiques) ; zcompiler n'en a pas besoin
  (parsing synchrone/court). Laisser tel quel, **ne pas investir** en v1.
- **Classes JS / getters-setters** — zcompiler n'expose que des fonctions libres.
  **Hors v1.**
- **Buffers / TypedArray** — zcompiler renvoie des strings. Candidat **v2** utile
  (entrée `Uint8Array` zéro-copie pour éviter le ré-encodage UTF-8), pas bloquant.
- **BigInt, cross-compile CLI, prebuilds npm multi-plateforme, fichier de config**
  — vrais écarts de parité napi-rs, mais **hors chemin critique** de la 0.2.0
  (zcompiler build depuis la source dans le monorepo). Reportés post-v1.

**Verdict** : le socle (register comptime, scalaires, async, `.d.ts` embarqué) est
sain. Ce qui manque pour « ≤ 10 lignes/fonction » n'est pas une réécriture mais
**3 ajouts ciblés à `convert.zig`/`register.zig`** (composites, allocateur de
retour, erreurs riches). Le pattern échappatoire `env`/`napi.Value` reste dispo
mais devient **optionnel** (utilisé par ~0 fonction) — c'est le résultat visé.

## v1 — l'API de conversion (réalisée : phases 2, 1, 3)

L'audit ci-dessus est **implémenté**. Une fonction enregistrée s'écrit désormais
en Zig pur : elle prend ses arguments (convertis automatiquement), demande
l'allocateur d'appel si elle doit produire de la mémoire, et **retourne une
valeur Zig**. Plus de `napi.Value` bâtie à la main pour le cas courant.

### Paramètres injectés (ne consomment pas d'argument JS)

Reconnus par type dans `register.zig` (`Wrap`) et sautés dans le `.d.ts` :

| Type du paramètre | Injecté | Usage |
|---|---|---|
| `napi.Env` | l'environnement N-API | échappatoire bas niveau |
| `napi.Value` | la valeur JS brute | échappatoire (callback, valeur opaque) |
| `std.mem.Allocator` | **l'arène d'appel** | allouer le résultat / les messages d'erreur |

### Règle de lifetime du résultat (phase 2 — le déblocage)

L'arène d'appel de `Wrap` sert à la fois à convertir les **arguments** ET à ce
que la fonction alloue pour son **résultat**. Elle n'est libérée (`defer`)
qu'**après** que `finish` a converti le retour en valeur JS (copie dans V8).
Donc : **allouez le retour dans l'`Allocator` injecté et retournez-le** — la
copie a lieu tant que la mémoire est vivante, puis l'arène est libérée. Zéro
fuite, zéro use-after-free, par construction. (Même règle pour un message
d'erreur `fail`, cf. plus bas.) Stressé au runtime dans l'exemple `repeat`
(100 000 copies → plusieurs pages d'arène, buffer intact côté JS).

### Conversions supportées (phase 1 — `convert.zig`, comptime, récursif)

Les deux sens (`fromJs` pour les args, `toJs` pour les retours) :

| Zig | JS | Notes |
|---|---|---|
| entiers, flottants, `bool` | number / boolean | |
| `[]const u8` | string | seule slice-de-`u8` = string |
| `struct { … }` | `{ … }` | champ par champ (par nom), récursif ; champ manquant en entrée → défaut si le champ en a un, sinon erreur |
| `[]T` (T ≠ `const u8`) | `Array<T>` | récursif (ex. `[]const []const u8` → `string[]`) |
| `?T` | `T \| null` | `null`/`undefined` JS → `null` Zig |
| `enum` | string | le `@tagName` ; `.d.ts` = union `"a" \| "b"` |
| `union(enum)` | `{ type: "<tag>", …payload }` | payload struct **étalé** ; payload scalaire sous `value` ; payload `void` → `{ type }` seul |

Les composites récursent, donc un type feuille non supporté échoue au **comptime**
avec un message pointant le type fautif. Le `.d.ts` (`typedefs.zig`) rend la
**même** structure (fini les `any` sur les retours composites).

### Erreurs riches (phase 3 — `errors.zig`)

- Une fonction `!T` qui laisse fuiter une erreur → exception JS dont le message
  est `@errorName(err)` (comme avant).
- Pour un **message précis**, retourner `zignapi.fail("…")` : le message est
  stocké (thread-local), puis levé par `register` en exception JS. **Même règle
  de lifetime** : allouer le message dans l'`Allocator` injecté (ou une chaîne
  statique). Sync uniquement (set-puis-read dans un seul callback synchrone ;
  `asyncFn`/threadsafe n'utilisent pas ce canal).

### Éprouvé sur zcompiler (le juge de paix)

Binding zcompiler réécrit sur v1 : **364 → 284 lignes**, **0** `napi.Env`/
`napi.Value` en signature, chaque fonction cœur **≤ 5 instructions** (`print`/
`transform`/`strip*` : 2-3 ; `tokenize`/`semantic`/`parseErrors` : 4-5). Résultat
**bit-identique** : snapshot de toute la surface API sur 76 fichiers (tokenize,
parseErrors, semantic, tous les retours string **et les exceptions**)
byte-identique avant/après ; corpus 679/679 (parse/roundtrip/transform/semantic),
mangle −13,0 % (octet près), recovery 19/19, jsx 13/13, jsx-transform 13/13,
ts-strip 26/26, tsx 8/8 ; `node --test` 69/69 ; `zig build test` OK. Le `.d.ts`
de zcompiler : tous les `any` remplacés par les vrais types (`string`, `number`,
`Array<{ message: string; offset: number }>`, l'objet `semantic`, l'union des
TokenKind), rien d'autre. Hors périmètre v1 (inchangé) : threadsafe functions,
classes JS, Buffers/TypedArray, cross-compile CLI, prebuilds npm, façade
`compile()` — cf. section audit.

## Packaging (parité napi-rs)

Ce que produit `zignapi build` vise la parité napi-rs : un loader multi-plateforme,
des packages npm par plateforme, la cross-compilation native (l'atout Zig), et
des constantes de module.

### Constants (`register` de valeurs non-fonction)

`register(.{ .parse = parse, .VERSION = "0.2.0", .LIMITS = limits })` : tout champ
qui n'est **ni une fonction ni un `asyncFn`** devient une **propriété du module**
(via `convert.toJs`). Les littéraux non typés sont coercés (`"…"` → `[]const u8`,
`42` → `i64` ; cf. `convert.CoercedConst`) ; une struct typée → objet. Le `.d.ts`
les déclare : `export const VERSION: string;`. (Le gel `Object.freeze` reste côté
JS, non fait.)

### Le loader généré (`index.js`, autonome — aucune dépendance zignapi au runtime)

Ordre de résolution (`loader.ts`) :
1. `./<binary>.node` — le build **dev** à la racine (transparent, bit-identique) ;
2. `./npm/<triple>/<binary>.<triple>.node` — un build par plateforme **in-tree** ;
3. `<packageName>-<triple>` — le **package publié** par plateforme ;
4. sinon une **erreur claire** listant les triples supportés et ce qui a été tenté.

Détection : `process.platform` + `process.arch` + **libc** (glibc vs musl sans
dépendance : `process.report.getReport().header.glibcVersionRuntime` présent ⇒
`gnu`, absent ⇒ `musl`). Noms de triples = **napi-rs** (compat outillage).

### La table des triples (Zig ↔ npm) — `triples.ts`

| Triple npm | `os`/`cpu`/`libc` | `-Dtarget` Zig |
|---|---|---|
| darwin-arm64 | darwin / arm64 | aarch64-macos |
| darwin-x64 | darwin / x64 | x86_64-macos |
| linux-x64-gnu | linux / x64 / glibc | x86_64-linux-gnu |
| linux-x64-musl | linux / x64 / musl | x86_64-linux-musl |
| linux-arm64-gnu | linux / arm64 / glibc | aarch64-linux-gnu |
| linux-arm64-musl | linux / arm64 / musl | aarch64-linux-musl |
| win32-x64-msvc | win32 / x64 | x86_64-windows-msvc |
| win32-arm64-msvc | win32 / arm64 | aarch64-windows-msvc |

### Config — le champ `"zignapi"` de `package.json` (source unique)

La config vit dans `package.json` (à la napi-rs) — **JSON pur**, lu par
`config.ts` (`readFileSync` + `JSON.parse`, aucun transpile, aucun jiti) :

```jsonc
{
  "name": "@zparse/zparse",         // le package principal publié
  "version": "0.2.0",               // héritée par les packages de plateforme
  "zignapi": {
    "binaryName": "zparse",         // nomme les fichiers .node
    "packageName": "@zparse/binding", // nomme les packages de plateforme
    "targets": ["darwin-arm64", "linux-x64-gnu", ...]
  }
}
```

**`binaryName` vs `packageName`** (distinction pas évidente, à retenir) : ce sont
**deux axes indépendants** — l'un nomme les **fichiers** binaires, l'autre les
**packages** de plateforme. Aucun n'a à coïncider avec le `name` principal.

**Dérivations** (rien d'autre n'est configuré nulle part) :

| Élément | Dérivation | Exemple |
|---|---|---|
| fichier binaire | `<binaryName>.<triple>.node` | `zparse.darwin-arm64.node` |
| package de plateforme | `<packageName>-<triple>` | `@zparse/binding-darwin-arm64` |
| version de plateforme | héritée de `version` | `0.2.0` |
| loader | généré depuis `targets` + `packageName` | (embarqué en dur) |

**Défauts sains** (le cas « je débute ») : `binaryName` absent → le `name` sans
scope ; `packageName` absent → le `name` (**comportement d'avant, zéro rupture**) ;
`targets` absent → le **triple de la machine courante** (`triples.currentTriple()`).
**Validation** : `target` inconnu → erreur listant la table ; `name`/`packageName`
invalide comme nom npm → erreur ; clé inattendue dans `"zignapi"` → warning.

**Dépréciation** : un `zignapi.config.{ts,mjs,js,json}` résiduel émet un warning
« déplacez vers package.json » et **est ignoré** (une seule source, pas d'ordre de
priorité à mémoriser). Supprime au passage le warning `MODULE_TYPELESS` du rapport
précédent (plus aucun `.ts` chargé). **Option 2 (en réserve)** : `config.ts`
programmatique — le chargeur par import dynamique reste dans `config.ts`
(`loadConfigFileReserved`, non câblé) pour ré-activer un jour un besoin de config
*calculée* (targets depuis une var d'env, etc.).

### Commandes

- `zignapi build` — hôte : `<name>.node` racine + `index.js` (loader) + `index.d.ts`.
- `zignapi build --target <triple>` — cross-compile **un** triple dans
  `npm/<triple>/` (+ `package.json`). Zig cross-compile **nativement**, sans
  toolchain C — l'avantage structurel sur napi-rs.
- `zignapi build --all` — tous les triples ; **résilient** (un échec n'arrête pas
  les autres ; résumé + exit ≠ 0).
- `zignapi prepublish` — écrit `npm/<triple>/package.json` + remplit les
  `optionalDependencies` du `package.json` principal (npm n'installe que le binaire
  correspondant à l'`os`/`cpu`/`libc` de l'hôte).

### Limites de cross-compilation

- **win32-\*-msvc** : Zig ne fournit pas la libc MSVC (SDK Windows requis) → à
  builder sur **hôte/CI Windows** (comme napi-rs). Zig sait `x86_64-windows-gnu`,
  mais l'ABI Node de Windows est msvc — on ne substitue pas.
- **linux/darwin** : cross depuis macOS **produit** le binaire (ELF/Mach-O
  vérifiés) ; son **chargement** se validera en CI sur la vraie plateforme.

### Éprouvé sur zcompiler (répétition générale)

`build --all` depuis macOS : **5/6** triples produits (2 darwin + 3 linux ;
win32-msvc signalé). `prepublish` → 6 `npm/*/package.json` + `optionalDependencies`.
**Prod simulée** (avec `packageName` **découplé**) : `npm pack` du principal
`@zparse/zparse` (livre `index.js`+`index.d.ts`, aucun `.node`) + du package de
plateforme `@zparse/binding-darwin-arm64` (fichier `zparse.darwin-arm64.node`),
extraits dans un témoin vide → `require("@zparse/zparse")` résout le package
**au `packageName`** `@zparse/binding-darwin-arm64` (chemin #3), toute l'API marche.
Test du **défaut** : hello-world sans `packageName` → packages au `name`
(`hello-world-example`), 17/17, zéro changement. Test **erreur** : plateforme sans
binaire → message listant les triples ET le package tenté au `packageName`.
En **dev** : batterie **bit-identique** (snapshot 76 fichiers, corpus 679/679,
node --test 69/69). Correctif : côté zcompiler, `zignapi` passe en
**devDependencies** (outil de build ; le loader est autonome). Hors périmètre
(comme demandé) : CI GitHub Actions, threadsafe/classes/Buffers, publication réelle.

## Backend WASM (le même `register`, deux cibles)

`register(.{...})` reste **LA** déclaration unique. La cible décide de l'artefact
(branche comptime dans `register.zig`, la branche morte est élaguée) :
- **natif** → `napi_register_module_v1` (le `.node`) ;
- **wasm** → des exports WebAssembly (`wasm.zig`), compilé en
  **`wasm32-freestanding`**.

### Freestanding, PAS WASI (l'atout)

zcompiler est du **calcul pur** (pas de fs, pas d'horloge, pas de socket) → cible
`wasm32-freestanding`, **aucun shim WASI**. Avantage sur napi-rs (qui traîne WASI
+ émulation navigateur) : le module tombe direct dans un onglet, rien à polyfiller.
Si un consommateur a un jour besoin de WASI, ce sera une **option** — pas le défaut.

### L'ABI (Zig ↔ glue `wasm.js`)

Les strings traversent en `(ptr, len)` dans la mémoire linéaire :
- `__zignapi_alloc(len) -> ptr` : la glue y écrit l'input (UTF-8) ;
- `<nom>(ptr, len) -> u64` : un export par fonction, renvoie `(ptr<<32)|len` du
  résultat ;
- `__zignapi_err_ptr()/__zignapi_err_len()` : après un appel, une longueur d'erreur
  ≠ 0 = échec → la glue lit le message et **`throw new Error(msg)`** (le message de
  `fail()`, identique au natif) ;
- `__zignapi_meta() -> u64` : un blob JSON `{ dts, returns:{nom:kind}, consts }`
  que la CLI lit (en instanciant le `.wasm`) pour générer `wasm.js` + les types.

### Contrat de lifetime (même règle que l'arène N-API)

Une arène (sur `wasm_allocator`) porte tout le cycle d'appel. `__zignapi_alloc`
**reset** l'arène (libère l'input ET le résultat du cycle précédent) puis alloue
l'input. La fonction alloue son résultat dans la même arène → le résultat reste
valide jusqu'à ce que la glue l'ait lu, et n'est libéré qu'au **prochain**
`__zignapi_alloc`. **La glue DOIT lire un résultat avant l'appel suivant** (elle le
fait). Pas de `__free` (arène ; export no-op pour la symétrie). **Piège wasm côté
glue** : `memory.buffer` se **détache** quand la mémoire grandit → relire une vue
fraîche après chaque appel (fait dans `wasm.js`).

### Retours composites (raccourci v1)

Un retour string traverse en octets bruts. Un composite (`[]Struct`, `Struct`,
`[]const []const u8`…) est **sérialisé en JSON** dans l'arène (petit sérialiseur
maison dans `wasm.zig`, même forme que `convert.toJs`) et `JSON.parse`-é par la
glue. napi-rs fait pareil en wasm pour les objets riches. La conversion structurelle
directe = v2 si le profilage l'exige. (Les **unions taguées** ne sont pas sérialisées
en v1 → `@compileError` ; backend natif ou v2.)

### Le layout généré (découpage napi-rs)

| Fichier | Rôle |
|---|---|
| `bindings.js` | le **loader natif** (détection plateforme/libc, `.node` local → `npm/<triple>/` → `<packageName>-<triple>`) |
| `index.js` | l'**entrée publique Node** : re-export de `bindings.js` (3 lignes) |
| `wasm.js` | la **glue WASM** : UMD, **synchrone**, API **identique** au natif |
| `index.d.ts` | les types (**source unique**, générés du `dts`) |
| `wasm.d.ts` | un **alias** `export * from "./index.js"` — jamais une copie |
| `<binaryName>.wasm` | le module WASM |

`require("pkg/bindings.js")` reste importable (échappatoire pour forcer le natif).

**Décision : `wasm.js` est synchrone et auto-suffisant** — le module WASM est
**embarqué en base64** et instancié de façon **synchrone** (Node + navigateur),
plutôt qu'un `fetch` async. Raison : « API IDENTIQUE au natif » (synchrone) est le
**critère absolu**, et `fetch` est async. Conséquence : `wasm.js` est gros (base64)
mais tourne partout sans init async, se bundle trivialement (aucun fs/fetch), et le
même code utilisateur marche sur les deux backends. Le `.wasm` séparé est **aussi**
livré (artefact canonique + fetch manuel possible). *(Un mode `fetch`/streaming
serait une option future ; il romprait la synchronicité.)*

### Packaging (les champs `package.json`, l'ordre compte)

`zignapi build --target wasm` (ou `wasm` dans les `targets`) produit le `.wasm` +
`wasm.js` + `wasm.d.ts`. `prepublish`, si `wasm` est ciblé, écrit dans le
`package.json` (l'**ordre des clés compte — `types` en premier**) :

```jsonc
"main": "index.js", "browser": "wasm.js", "types": "index.d.ts",
"exports": {
  ".": { "types": "./index.d.ts", "browser": "./wasm.js",
         "node": "./index.js", "default": "./wasm.js" },
  "./bindings.js": "./bindings.js", "./wasm.js": "./wasm.js"
}
```

Un bundler `--platform=browser` prend `wasm.js` ; Node prend `index.js` (natif).
`wasm` n'a **pas** de package de plateforme (il vit dans le package principal).

### Éprouvé sur zcompiler (deux backends, une vérité)

`build --target wasm` : `zcompiler.wasm` **219 Ko** (ReleaseSmall) + `wasm.js`.
**LE juge** : le snapshot API des **76 fichiers** rejoué sur le backend **wasm** est
**byte-identique** au natif (tokenize/parseErrors/semantic + retours string **et
exceptions**). Bundler-witness (conditions Node) : `node` → `index.js` (natif),
`browser` → `wasm.js` (wasm) — même API, mêmes résultats. Natif : **zéro
régression** (corpus 679/679, node --test 69/69, `zig build test`). Le playground
gagne `wasm.html` (zcompiler qui parse dans l'onglet, smoke test manuel).
Hors périmètre (comme demandé) : WASI, threads wasm, conversion structurelle v2,
CI navigateur, le split.

## Journal des modifications de code

<!-- Chaque modification de code est notée ici, la plus récente en haut.
     Format : - AAAA-MM-JJ — <résumé du changement> (fichiers touchés) -->

- 2026-07-25 — **Backend WASM** (le même `register`, deux cibles) — cf. section
  « Backend WASM ». Nouveau `native/wasm.zig` : cible `wasm32-freestanding`
  (**pas WASI**), arène sur `wasm_allocator` (reset à `__zignapi_alloc`, contrat de
  lifetime identique au natif), un export `(ptr,len)->u64` par fonction, sérialiseur
  JSON maison pour les composites (même forme que `convert.toJs`), slot d'erreur
  `__zignapi_err_*` (message de `fail`), `__zignapi_meta` (dts+returns+consts).
  `register.zig` branche comptime napi/wasm (branche morte élaguée) ; `napi.zig`
  guarde `@cImport` + stubs de types pour wasm. `build.zig` : `link_libc` sorti du
  module zignapi → module racine consommateur (`=!is_wasm`) ; branche wasm
  (`addExecutable` entry disabled + rdynamic) dans template + hello-world. Côté CLI :
  `loader.ts` génère `bindings.js` (loader natif) + `index.js` (re-export) +
  `wasm.js` (glue UMD **synchrone**, module WASM en base64 embarqué) + `wasm.d.ts`
  (alias) ; `build.ts` `--target wasm` (compile, lit `__meta` en instanciant le
  `.wasm`, émet la glue) ; `triples.ts` cible `wasm` ; `prepublish` exports map
  (`types` d'abord, browser/node/default). Éprouvé sur zcompiler : `.wasm` 219 Ko,
  **snapshot 76 fichiers wasm = natif byte-identique**, bundler-witness (conditions
  node/browser), natif zéro régression (679/679, 69/69).
- 2026-07-25 — **Découplage `packageName`** : nouveau champ optionnel
  `zignapi.packageName` qui nomme les **packages** de plateforme
  (`<packageName>-<triple>`), indépendamment du `name` principal et du
  `binaryName` (qui nomme les **fichiers**). `config.ts` : lit `field.packageName`
  (défaut → `name`, zéro rupture), `KNOWN_KEYS += packageName`, validation nom npm
  (`validateNpmName` appliquée à `name` ET `packageName`). `prepublish.ts` : les
  `optionalDependencies` nettoient les anciennes entrées de plateforme (clé finissant
  par un triple connu) avant d'ajouter les nouvelles → rename propre. L'aval
  (packaging/loader/build) utilisait déjà `config.packageName` — rien à toucher.
  Éprouvé sur zcompiler (`packageName: @zparse/binding` ≠ `name: @zparse/zparse`) :
  build local bit-identique, `build --all` → `@zparse/binding-<triple>`, prod
  simulée (`require("@zparse/zparse")` résout `@zparse/binding-darwin-arm64`),
  défaut hello-world 17/17, message d'erreur au `packageName`.
- 2026-07-25 — **Migration config → champ `"zignapi"` de package.json** (source
  unique, à la napi-rs). `config.ts` : `loadConfig` lit désormais `package.json`
  en **JSON pur** (fini l'import dynamique sur ce chemin) ; shape `{ packageName,
  binaryName, targets, version }` ; défauts (binaryName → name sans scope ; targets
  → triple hôte via `triples.currentTriple()`) ; validation (target inconnu →
  erreur ; clé inconnue → warning) ; **dépréciation** d'un `zignapi.config.*`
  résiduel (warning + ignoré) ; `loadConfigFileReserved` gardé non-câblé (option 2).
  Alignement napi-rs des **dérivations** : binaires `<binaryName>.<triple>.node`
  (`packaging.ts`), packages `<packageName>-<triple>` (le scope vient du `name`),
  loader mis à jour (`loader.ts` chemin in-tree `.{triple}.node`). Template :
  champ `"zignapi"` dans son `package.json` (plus de `.ts` → plus de warning
  MODULE_TYPELESS). Éprouvé sur zcompiler (renommé `@zparse/zparse`) : build local
  bit-identique, `build --all` 5/6, prod simulée (require scopé), hello-world 17/17.
- 2026-07-25 — **Packaging (parité napi-rs)** — cf. section « Packaging ».
  **Constants** : `register` accepte des valeurs non-fonction → propriétés du
  module (`register.zig#registerField` branche `isConstant` ; `convert.CoercedConst`/
  `coerceConst` pour les littéraux ; `typedefs.zig` émet `export const`).
  **Loader** (`src/loader.ts`) : `index.js` autonome qui détecte platform/arch/libc
  et résout `.node` local → `npm/<triple>/` → `<scope>/<name>-<triple>` → erreur
  claire. **Cross-compile** (`src/build.ts`) : `--target <triple>` (table
  `src/triples.ts` npm↔Zig) + `--all` (résilient). **prepublish** (`src/prepublish.ts`
  + `src/packaging.ts`) : `npm/<triple>/package.json` + `optionalDependencies`.
  **Config** (`src/config.ts`) : `zignapi.config.{ts,mjs,js,json}` (scope, triples ;
  version = source unique du package.json). `_check.zig`/exemple `hello-world`
  exercent les constantes ; `npm/` ajouté au `dot-gitignore`. Éprouvé sur zcompiler :
  5/6 triples cross depuis macOS, prod simulée (npm pack → témoin → require scopé),
  dev bit-identique.
- 2026-07-25 — **v1 : phases 2 + 1 + 3 implémentées** (l'audit devient du code).
  Phase 2 — `register.zig` : `Wrap` injecte un param `std.mem.Allocator` (comme
  `napi.Env`) = l'arène d'appel, libérée après conversion du retour → une
  fonction peut retourner un slice/struct alloué (règle de lifetime). Phase 1 —
  `convert.zig` : `classify`/`fromJs`/`toJs` étendus (struct↔objet, slice↔array,
  `?T`, enum→string, union taguée `{type,…}`), récursif, 2 sens ; `typedefs.zig`
  rend ces types en TS (fini les `any`) et saute le param `Allocator` ; helpers
  `napi.zig` (getArrayLength/getElement/has+getNamedProperty/getNull/isNullish/
  throwMessage). Phase 3 — nouveau `errors.zig` : `zignapi.fail("msg")` (thread-
  local) → exception JS à message custom ; câblé dans `register.zig#finish` ;
  exporté par `root.zig`. `_check.zig` + exemple `hello-world` (native/main.zig +
  test.js, 14 tests runtime) exercent chaque conversion en aller-retour, les
  erreurs et la lifetime (stress 100k). `zig build`/`zig build test` OK. Éprouvé
  sur zcompiler (binding 364→284 l., 0 napi.Value, bit-identique) — cf. section
  « v1 — l'API de conversion ».
- 2026-07-25 — **Audit « napi-rs du Zig »** (doc, zéro code) écrit ci-dessus :
  inventaire de `native/` + de la surface N-API de zcompiler (~180 lignes de glue
  sur 364), matrice 17 lignes vs napi-rs, 3 cibles comptime (composites /
  allocateur de retour / erreurs riches) et plan en 3 phases v1 (~58 % de glue
  supprimée, ≤ 5 lignes/fonction) + phase 4 optionnelle et hors-périmètre.
- 2026-07-22 — Version = **source unique** dans `packages/zignapi/package.json`.
  `zig.ts` : nouvelle `packageVersion()` lue par `releaseUrl()` (l'URL de release,
  et donc la version écrite dans le `build.zig.zon` du projet généré, suit
  automatiquement `package.json`). `pack-native.mjs` lit la même version, l'estampille
  dans `build.zig.zon`, et nomme `dist/zignapi-<version>.tar.gz`. Corrige au passage
  2 bugs de l'archi native-dans-le-package : `resolveZignapiSources()` pointait sur
  `native/` (pas de `build.zig.zon`) → renvoie désormais la racine du package ;
  `pack-native` aplatissait le tarball → structure `build.zig`+`build.zig.zon`+`native/`.
  Vérifié E2E : `new` (release tarball local) → `build.zig.zon` avec `url`/`hash` en
  `0.3.0` → `zignapi build` du projet généré OK.
- 2026-07-22 — Support des **retours composites** : une fonction peut retourner
  une `napi.Value` brute (objet/array/nœud AST), que `register` laisse passer
  sans `convert` (fix dans `register.zig#toJs`). Nouveaux helpers dans `napi.zig` :
  `createObject`, `createArray`, `setElement`. Cas ajouté à `_check.zig`
  (`makeArray`). NB : la génération `.d.ts` type ces retours en `any`.
- 2026-07-22 — Réécriture complète depuis `zigbind-core` en gardant l'archi
  actuelle. `native/` : vraie lib N-API (`root.zig`, `napi.zig`, `convert.zig`,
  `typedefs.zig`, `async.zig`, `register.zig`, `_check.zig` + `vendor/`) au lieu
  du seul `root.zig`. `src/` : CLI TS (`cli.ts`, `build.ts`, `new.ts`, `zig.ts`)
  au lieu du loader ; `zig.ts#resolveZignapiSources` adapté (native/ vit dans le
  package, plus de `prepack`). Ajout de `templates/` et `scripts/pack-native.mjs`.
  `build.zig`/`build.zig.zon` adaptés (chemins `native/…`, `.name = .zignapi`,
  Zig 0.16). Exemple `hello-world` refait (playground adapté). Vérifié :
  `zig build` + `zig build test` OK.
