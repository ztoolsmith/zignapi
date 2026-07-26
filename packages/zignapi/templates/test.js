const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");

// The generated loader (index.js) re-exports the addon; index.d.ts gives it types.
// Both are produced by `zignapi build`, so build before running the tests.
const addon = require("./index.js");

test("add(2, 3) === 5", () => {
  assert.strictEqual(addon.add(2, 3), 5);
});

test("greet returns a string", () => {
  assert.strictEqual(addon.greet("world"), "hello from Zig");
});

test("slowSquare resolves a Promise", async () => {
  assert.strictEqual(await addon.slowSquare(8), 64);
});

test("index.d.ts declares the exports", () => {
  const dts = fs.readFileSync("./index.d.ts", "utf8");
  assert.match(dts, /export function add\(arg0: number, arg1: number\): number;/);
  assert.match(dts, /export function greet\(arg0: string\): string;/);
  assert.match(dts, /export function slowSquare\(arg0: number\): Promise<number>;/);
});
