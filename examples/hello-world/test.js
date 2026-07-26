const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");

// `zignapi build` copie l'addon en ./hello.node et génère index.js (loader) +
// index.d.ts (types) à partir des déclarations embarquées dans l'addon.
const addon = require("./hello.node");
const api = require("./index.js");

test("add(2, 3) === 5", () => {
  assert.strictEqual(addon.add(2, 3), 5);
});

test("index.js re-exporte l'API et masque les internes", () => {
  assert.strictEqual(api.add(2, 3), 5);
  assert.strictEqual(api.__zignapi_dts__, undefined);
});

test("async multiplySlow résout une Promise", async () => {
  const pending = api.multiplySlow(6, 7);
  assert.ok(pending instanceof Promise);
  assert.strictEqual(await pending, 42);
});

test("async failing rejette une erreur Zig, résout sinon", async () => {
  await assert.rejects(() => api.failing(-1), /MustBeNonNegative/);
  assert.strictEqual(await api.failing(9), 9);
});

test("threadsafe countTo rappelle depuis un thread worker", async () => {
  const got = [];
  await new Promise((resolve) => {
    let n = 0;
    api.countTo(3, (v) => {
      got.push(v);
      if (++n === 3) resolve();
    });
  });
  assert.deepStrictEqual(got, [1, 2, 3]);
});

test("index.d.ts déclare les signatures async et callback", () => {
  const dts = fs.readFileSync("./index.d.ts", "utf8");
  assert.match(dts, /export function multiplySlow\(arg0: number, arg1: number\): Promise<number>;/);
  assert.match(dts, /export function countTo\(arg0: number, arg1: any\): void;/);
});

// ---------- v1 conversions ----------

test("phase 2 — retour string alloué (lifetime : gros buffer copié avant free)", () => {
  assert.strictEqual(api.repeat("ab", 3), "ababab");
  // 100k copies : force plusieurs pages d'arène ; doit rester valide côté JS.
  const big = api.repeat("x", 100000);
  assert.strictEqual(big.length, 100000);
  assert.strictEqual(big, "x".repeat(100000));
});

test("struct ↔ objet (aller-retour)", () => {
  assert.deepStrictEqual(api.makePoint(2, 5), { x: 2, y: 5 });
  assert.strictEqual(api.sumPoint({ x: 2, y: 5 }), 7);
  assert.strictEqual(api.sumPoint(api.makePoint(4, 6)), 10);
});

test("slice ↔ array (aller-retour) + array d'objets", () => {
  assert.deepStrictEqual(api.doubleAll([1, 2, 3]), [2, 4, 6]);
  assert.deepStrictEqual(api.doubleAll([]), []);
  assert.deepStrictEqual(api.column(3), [{ x: 0, y: 0 }, { x: 0, y: 1 }, { x: 0, y: 2 }]);
});

test("enum ↔ string (aller-retour)", () => {
  assert.strictEqual(api.favColor(), "green");
  assert.strictEqual(api.nameOf("blue"), "blue");
  assert.strictEqual(api.nameOf(api.favColor()), "green");
});

test("optional → T | null", () => {
  assert.strictEqual(api.maybe(5), 5);
  assert.strictEqual(api.maybe(-1), null);
});

test("tagged union → { type, …payload }", () => {
  assert.deepStrictEqual(api.shapeFor(3), { type: "dot", x: 3, y: 3 });
  assert.deepStrictEqual(api.shapeFor(-4), { type: "scalar", value: -4 });
  assert.deepStrictEqual(api.shapeFor(0), { type: "origin" });
});

test("phase 3 — message d'exception custom via zignapi.fail", () => {
  assert.throws(() => api.mustBePositive(-1), /value must be positive/);
  assert.strictEqual(api.mustBePositive(9), 9);
});

test("index.d.ts : les composites ont de vrais types (plus d'any)", () => {
  const dts = fs.readFileSync("./index.d.ts", "utf8");
  assert.match(dts, /export function makePoint\(arg0: number, arg1: number\): \{ x: number; y: number \};/);
  assert.match(dts, /export function doubleAll\(arg0: Array<number>\): Array<number>;/);
  assert.match(dts, /export function favColor\(\): "red" \| "green" \| "blue";/);
  assert.match(dts, /export function maybe\(arg0: number\): number \| null;/);
  assert.match(dts, /export function repeat\(arg0: string, arg1: number\): string;/);
});

test("constants — valeurs non-fonction exposées comme propriétés", () => {
  assert.strictEqual(api.VERSION, "1.2.3");
  assert.deepStrictEqual(api.LIMITS, { maxDepth: 64, name: "hello" });
});

test("index.d.ts : les constantes en export const typé", () => {
  const dts = fs.readFileSync("./index.d.ts", "utf8");
  assert.match(dts, /export const VERSION: string;/);
  assert.match(dts, /export const LIMITS: \{ maxDepth: number; name: string \};/);
});

test("layout : index.js re-exporte bindings.js (le loader multi-plateforme)", () => {
  const index = fs.readFileSync("./index.js", "utf8");
  assert.match(index, /require\("\.\/bindings\.js"\)/);
  const bindings = fs.readFileSync("./bindings.js", "utf8");
  assert.match(bindings, /currentTriple/);
  assert.match(bindings, /no native binary for platform/);
  // En dev le loader charge le .node racine : l'API est bien là.
  assert.strictEqual(api.add(1, 1), 2);
});
