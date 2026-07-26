//! Build-only compile check (never shipped to consumers, not imported by
//! `root.zig`). Building this as an *object* forces the whole comptime
//! pipeline — `register` → the per-function callback trampolines → `convert`
//! for every supported type, including an error union — to be analyzed, so
//! `zig build` in this package fails loudly on any API or type mistake. The
//! N-API symbols it references stay undefined in the object file; they are
//! resolved when a real addon links, exactly as in production.

const std = @import("std");
const zignapi = @import("root.zig");
const napi = zignapi.napi;

// Reference the concrete (non-generic) wrappers so they are compiled too.
comptime {
    _ = napi.check;
    _ = napi.throwError;
    _ = napi.getCallbackInfo;
    _ = napi.setNamedProperty;
    _ = napi.createFunction;
    _ = napi.createString;
    _ = napi.getUndefined;
    _ = napi.createError;
    _ = napi.createObject;
    _ = napi.createArray;
    _ = napi.setElement;
    _ = napi.getArrayLength;
    _ = napi.getElement;
    _ = napi.hasNamedProperty;
    _ = napi.getNamedProperty;
    _ = napi.getNull;
    _ = napi.isNullish;
    _ = napi.throwMessage;
}

fn add(a: i32, b: i32) i32 {
    return a + b;
}
fn negate(x: bool) bool {
    return !x;
}
fn scale(x: f64) f64 {
    return x * 2.0;
}
fn echo(s: []const u8) []const u8 {
    return s;
}
fn checked(x: i32) !i32 {
    return if (x < 0) error.MustBeNonNegative else x;
}

// Async: runs on the thread pool, returns a Promise.
fn heavy(a: i32, b: i32) i32 {
    return a * b;
}
fn heavyChecked(x: i32) !i32 {
    return if (x < 0) error.MustBeNonNegative else x;
}

// Raw passthrough: `napi.Env` / `napi.Value` params + a threadsafe function.
fn onEvent(env: napi.Env, callback: napi.Value) void {
    const tsfn = zignapi.ThreadsafeFunction(i32).create(env, callback) catch return;
    tsfn.call(1) catch {};
    tsfn.release();
}

// Raw JS value return: build an array of objects by hand and return it.
fn makeArray(env: napi.Env) !napi.Value {
    const arr = try napi.createArray(env, 1);
    const obj = try napi.createObject(env);
    try napi.setNamedProperty(env, obj, "k", try napi.createString(env, "v"));
    try napi.setElement(env, arr, 0, obj);
    return arr;
}

// ---------- v1 surface: exercise every new comptime path ----------

const Point = struct { x: i32, y: i32 };
const Color = enum { red, green, blue };
const Shape = union(enum) { circle: struct { r: f64 }, point: Point, empty: void };

// Phase 2 — scratch allocator injected + owned slice returned (converted then
// freed by the wrapper). No `env`, no `napi.Value`, no manual `createString`.
fn shout(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    const out = try a.alloc(u8, s.len);
    for (s, 0..) |ch, i| out[i] = std.ascii.toUpper(ch);
    return out;
}

// Phase 1 — composite returns: struct→object, []struct→array, enum→string,
// ?T→value|null, tagged union→{ type, …payload }.
fn makePoint(x: i32, y: i32) Point {
    return .{ .x = x, .y = y };
}
fn points(a: std.mem.Allocator, n: u32) ![]const Point {
    const out = try a.alloc(Point, n);
    for (out, 0..) |*p, i| p.* = .{ .x = @intCast(i), .y = 0 };
    return out;
}
fn favColor() Color {
    return .green;
}
fn maybe(x: i32) ?i32 {
    return if (x < 0) null else x;
}
fn shapeFor(x: i32) Shape {
    return if (x == 0) .{ .empty = {} } else .{ .point = .{ .x = x, .y = x } };
}

// Phase 1 — composite arguments (JS→Zig): object→struct, array→slice (built in
// the injected arena — no Allocator param needed on the function itself).
fn sumPoint(p: Point) i32 {
    return p.x + p.y;
}
fn sumList(xs: []const i32) i32 {
    var s: i32 = 0;
    for (xs) |x| s += x;
    return s;
}

// Phase 3 — custom exception message via `zignapi.fail`.
fn mustBePositive(x: i32) !i32 {
    if (x <= 0) return zignapi.fail("value must be positive");
    return x;
}

// Constants: non-function fields become frozen-ish module properties. Untyped
// literals are coerced (string literal → []const u8, `42` → i64); a struct
// constant with concrete field types becomes an object.
const Info = struct { name: []const u8, major: u32 };
const info: Info = .{ .name = "zignapi", .major = 1 };

comptime {
    zignapi.register(.{
        .add = add,
        .negate = negate,
        .scale = scale,
        .echo = echo,
        .checked = checked,
        .heavy = zignapi.asyncFn(heavy),
        .heavyChecked = zignapi.asyncFn(heavyChecked),
        .onEvent = onEvent,
        .makeArray = makeArray,
        // v1 conversions
        .shout = shout,
        .makePoint = makePoint,
        .points = points,
        .favColor = favColor,
        .maybe = maybe,
        .shapeFor = shapeFor,
        .sumPoint = sumPoint,
        .sumList = sumList,
        .mustBePositive = mustBePositive,
        // constants
        .VERSION = "9.9.9",
        .MAX_DEPTH = 42,
        .DEBUG = false,
        .INFO = info,
    });
}
