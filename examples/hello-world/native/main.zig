//! Exemple d'addon Node.js écrit avec zignapi, exerçant tout le pipeline :
//! fonction synchrone, fonctions async (Promise), erreur -> rejet, et une
//! threadsafe function qui rappelle un callback JS depuis un thread worker.

const std = @import("std");
const zignapi = @import("zignapi");
const napi = zignapi.napi;

/// Sync — exposé à JS comme `addon.add(a, b)`.
pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

/// Async — tourne sur le thread pool de libuv et résout un `Promise<number>`.
fn multiplySlow(a: i32, b: i32) i32 {
    return a * b;
}

/// Async pouvant rejeter : une erreur Zig devient une promesse rejetée.
fn failing(x: i32) !i32 {
    return if (x < 0) error.MustBeNonNegative else x;
}

/// Threadsafe : appelle le `callback` JS avec 1..n depuis un thread worker.
/// `env` est passé tel quel et n'est pas un argument JS.
fn countTo(env: napi.Env, n: i32, callback: napi.Value) void {
    const tsfn = zignapi.ThreadsafeFunction(i32).create(env, callback) catch return;
    const worker = std.Thread.spawn(.{}, countWorker, .{ tsfn, n }) catch {
        tsfn.release();
        return;
    };
    worker.detach();
}

fn countWorker(tsfn: zignapi.ThreadsafeFunction(i32), n: i32) void {
    var i: i32 = 1;
    while (i <= n) : (i += 1) tsfn.call(i) catch {};
    tsfn.release();
}

// ---------- v1 conversions (round-trippable from JS) ----------

const Point = struct { x: i32, y: i32 };
const Color = enum { red, green, blue };
/// Tagged union → `{ type, …payload }`. `dot` has a struct payload (spread),
/// `scalar` a non-struct payload (under `value`), `origin` is `void`.
const Shape = union(enum) { dot: Point, scalar: i32, origin: void };

/// Phase 2 — owned string return: allocate in the injected scratch arena and
/// return the slice; zignapi copies it into V8 before the arena is freed. A
/// large `n` stresses that the lifetime rule holds (no use-after-free).
fn repeat(a: std.mem.Allocator, s: []const u8, n: u32) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..n) |_| try out.appendSlice(a, s);
    return out.items;
}

/// struct → object, and object → struct (round-trip: `sumPoint(makePoint(...))`).
fn makePoint(x: i32, y: i32) Point {
    return .{ .x = x, .y = y };
}
fn sumPoint(p: Point) i32 {
    return p.x + p.y;
}

/// array → slice → array round-trip: doubles each element.
fn doubleAll(a: std.mem.Allocator, xs: []const i32) ![]const i32 {
    const out = try a.alloc(i32, xs.len);
    for (xs, 0..) |x, i| out[i] = x * 2;
    return out;
}

/// slice of structs → array of objects.
fn column(a: std.mem.Allocator, n: u32) ![]const Point {
    const out = try a.alloc(Point, n);
    for (out, 0..) |*p, i| p.* = .{ .x = 0, .y = @intCast(i) };
    return out;
}

/// enum ↔ string round-trip: `nameOf(favColor())`.
fn favColor() Color {
    return .green;
}
fn nameOf(c: Color) []const u8 {
    return @tagName(c);
}

/// optional → `T | null`.
fn maybe(x: i32) ?i32 {
    return if (x < 0) null else x;
}

/// tagged union → tagged object.
fn shapeFor(x: i32) Shape {
    if (x == 0) return .{ .origin = {} };
    return if (x > 0) .{ .dot = .{ .x = x, .y = x } } else .{ .scalar = x };
}

/// Phase 3 — custom exception message (vs the bare `@errorName`).
fn mustBePositive(x: i32) !i32 {
    if (x <= 0) return zignapi.fail("value must be positive");
    return x;
}

/// Constantes exposées comme propriétés du module (part packaging).
const Limits = struct { maxDepth: u32, name: []const u8 };
const limits: Limits = .{ .maxDepth = 64, .name = "hello" };

comptime {
    zignapi.register(.{
        .add = add,
        .multiplySlow = zignapi.asyncFn(multiplySlow),
        .failing = zignapi.asyncFn(failing),
        .countTo = countTo,
        // constantes (valeurs non-fonction) → propriétés du module
        .VERSION = "1.2.3",
        .LIMITS = limits,
        // v1 conversions
        .repeat = repeat,
        .makePoint = makePoint,
        .sumPoint = sumPoint,
        .doubleAll = doubleAll,
        .column = column,
        .favColor = favColor,
        .nameOf = nameOf,
        .maybe = maybe,
        .shapeFor = shapeFor,
        .mustBePositive = mustBePositive,
    });
}
