// Produit l'asset de release du package Zig zignapi : un tarball dont la RACINE
// contient `build.zig`, `build.zig.zon` et `native/` — la structure attendue
// par `zig fetch` (build.zig.zon à la racine, sources sous native/, comme le
// déclarent les `.paths` du package).
//
// La version est la SOURCE UNIQUE lue depuis packages/zignapi/package.json (la
// même que `releaseUrl()` côté CLI). On l'estampille aussi dans build.zig.zon
// pour que la version déclarée dans le tarball colle à son nom de fichier.
//
// Sortie : dist/zignapi-<version>.tar.gz — ce que `zignapi new` récupère.
//
// Usage : node scripts/pack-native.mjs
import { spawnSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const pkgDir = join(repoRoot, "packages", "zignapi");
const distDir = join(repoRoot, "dist");

// Source unique de la version : le package.json (celle que releaseUrl lit aussi).
const pkg = JSON.parse(readFileSync(join(pkgDir, "package.json"), "utf8"));
const version = pkg.version;
if (!version) {
  console.error("pack-native: pas de .version dans packages/zignapi/package.json");
  process.exit(1);
}

// Estampille build.zig.zon avec la même version (idempotent) pour que le
// tarball déclare en interne la version de son nom de fichier.
const zonPath = join(pkgDir, "build.zig.zon");
const zon = readFileSync(zonPath, "utf8");
const stamped = zon.replace(/(\.version\s*=\s*")[^"]*(")/, `$1${version}$2`);
if (stamped !== zon) {
  writeFileSync(zonPath, stamped);
  console.log(`pack-native: build.zig.zon .version -> ${version}`);
}

mkdirSync(distDir, { recursive: true });
const out = join(distDir, `zignapi-${version}.tar.gz`);
rmSync(out, { force: true });

// `-C pkgDir` puis les membres préserve la hiérarchie : build.zig et
// build.zig.zon à la racine du tarball, native/ (sources + vendor) en dessous.
const res = spawnSync(
  "tar",
  [
    "-czf", out,
    "--exclude", ".DS_Store",
    "-C", pkgDir,
    "build.zig", "build.zig.zon", "native",
  ],
  { stdio: "inherit", env: { ...process.env, COPYFILE_DISABLE: "1" } },
);
if (res.status !== 0) {
  console.error("pack-native: tar a échoué");
  process.exit(res.status ?? 1);
}
console.log(`pack-native: écrit ${out}`);
