//! WebAssembly backend — the *same* `register(.{...})` compiled to
//! `wasm32-freestanding` for the browser and non-N-API runtimes.
//!
//! ## Why freestanding (not WASI)
//!
//! The exposed functions are pure computation (no fs, no clock, no sockets), so
//! we target `wasm32-freestanding` — **no WASI shim at all**. That's an edge
//! over napi-rs's wasm story (which drags in WASI + browser emulation): the
//! module drops straight into a browser with nothing to polyfill. If a future
//! consumer genuinely needs WASI, that becomes an opt-in — not the default.
//!
//! ## The ABI (matches the JS glue in `wasm.js`)
//!
//! Strings cross the boundary as `(ptr, len)` into the linear memory:
//!   - `__zignapi_alloc(len) -> ptr` : the glue writes the UTF-8 input there.
//!   - `<name>(ptr, len) -> u64`     : one export per registered function,
//!     returning `(out_ptr << 32) | out_len` of the result bytes.
//!   - `__zignapi_err_ptr()/__zignapi_err_len()` : after a call, a non-zero err
//!     length means the call failed; the glue reads the message and throws.
//!   - `__zignapi_meta() -> u64`     : `(ptr,len)` of a JSON blob describing the
//!     surface (the `.d.ts`, each function's return kind, and constants), so the
//!     CLI can generate the glue + types without a Node-only introspection step.
//!
//! ## The lifetime contract (same rule as the N-API arena)
//!
//! One arena backs a whole call cycle. `__zignapi_alloc` **resets** it (freeing
//! the previous cycle's input *and* result), then allocates the input buffer.
//! The function allocates its result in the same arena. So the result stays
//! valid until the glue has read it — and is freed only when the *next* call
//! allocates. The glue MUST read a result before starting the next call (it
//! does). No `__free` is needed (arena); it's a no-op export for symmetry.
//!
//! ## Composite returns (v1 shortcut)
//!
//! A string return crosses as raw bytes. A composite (`[]Struct`, `Struct`,
//! `[]const []const u8`, …) is **serialized to JSON** in the arena and
//! `JSON.parse`-d by the glue — exactly the shape `convert.toJs` produces on the
//! native side. napi-rs does the same for rich objects in wasm. A structural
//! direct conversion is a v2 if profiling ever demands it.

const std = @import("std");
const convert = @import("convert.zig");
const typedefs = @import("typedefs.zig");
const errors = @import("errors.zig");

/// One arena for the whole call cycle, backed by the wasm page allocator.
var arena = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);

/// The pending error message (empty = success). Points into the arena, so it
/// stays valid until the glue reads it (before the next `__zignapi_alloc`).
var g_err: []const u8 = "";

fn alloc() std.mem.Allocator {
    return arena.allocator();
}

/// Pack a byte range into the `(ptr << 32) | len` return convention.
fn pack(s: []const u8) u64 {
    return (@as(u64, @intFromPtr(s.ptr)) << 32) | @as(u64, s.len);
}

// ---------- Fixed exports (the ABI utilities) ----------

/// Reset the arena (frees the previous cycle) and hand back an input buffer.
export fn __zignapi_alloc(len: usize) [*]u8 {
    _ = arena.reset(.retain_capacity);
    const buf = alloc().alloc(u8, len) catch unreachable;
    return buf.ptr;
}

/// No-op: the arena owns everything and resets at the next `__zignapi_alloc`.
export fn __zignapi_free(ptr: [*]u8, len: usize) void {
    _ = ptr;
    _ = len;
}

export fn __zignapi_err_ptr() usize {
    return @intFromPtr(g_err.ptr);
}
export fn __zignapi_err_len() usize {
    return g_err.len;
}

// ---------- Registration ----------

/// Emit a wasm export per registered function, plus `__zignapi_meta`. Called by
/// `register` when the target is wasm. Constants aren't exported as functions —
/// they travel in the meta blob and the glue exposes them.
pub fn registerWasm(comptime defs: anytype) void {
    inline for (@typeInfo(@TypeOf(defs)).@"struct".fields) |field| {
        const val = @field(defs, field.name);
        if (comptime @typeInfo(@TypeOf(val)) == .@"fn" and wasmExportable(@TypeOf(val))) {
            const Exporter = WasmExport(val, field.name);
            @export(&Exporter.call, .{ .name = field.name, .linkage = .strong });
        }
    }
    const Meta = MetaExport(defs);
    @export(&Meta.call, .{ .name = "__zignapi_meta", .linkage = .strong });
}

/// Whether a function fits the wasm v1 ABI: its JS arguments are a single
/// `[]const u8` (plus an optional injected `std.mem.Allocator`), and its result
/// is serializable (not a raw `napi.Value` / unsupported type). Functions that
/// don't fit — threadsafe callbacks, scalar/multi args, `napi.Value` returns —
/// are silently skipped on the wasm backend (they remain native-only).
fn wasmExportable(comptime FnT: type) bool {
    const info = @typeInfo(FnT).@"fn";
    comptime var strings: usize = 0;
    inline for (info.params) |param| {
        const P = param.type.?;
        if (P == std.mem.Allocator) {
            // injected, fine
        } else if (P == []const u8) {
            strings += 1;
        } else {
            return false;
        }
    }
    if (strings > 1) return false;
    return switch (@typeInfo(info.return_type.?)) {
        .void => true,
        .error_union => |eu| convert.classify(eu.payload) != .unsupported,
        else => convert.classify(info.return_type.?) != .unsupported,
    };
}

/// The wasm trampoline for one function: `(ptr, len) -> u64`. Injects the arena
/// allocator, reads the single `[]const u8` input, calls, and encodes the result
/// (string → raw bytes; anything else → JSON). Errors set `g_err` and return 0.
fn WasmExport(comptime func: anytype, comptime name: []const u8) type {
    const fn_info = @typeInfo(@TypeOf(func)).@"fn";
    return struct {
        fn call(ptr: [*]const u8, len: usize) callconv(.c) u64 {
            errors.reset();
            g_err = "";
            const a = alloc();

            var args: std.meta.ArgsTuple(@TypeOf(func)) = undefined;
            inline for (fn_info.params, 0..) |param, i| {
                const P = param.type.?;
                if (P == std.mem.Allocator) {
                    args[i] = a;
                } else if (P == []const u8) {
                    args[i] = ptr[0..len];
                } else {
                    @compileError("zignapi wasm v1: '" ++ name ++
                        "' has an unsupported parameter; only (std.mem.Allocator, []const u8) is supported");
                }
            }

            return finish(fn_info.return_type.?, @call(.auto, func, args), a);
        }
    };
}

fn finish(comptime RetType: type, result: RetType, a: std.mem.Allocator) u64 {
    switch (@typeInfo(RetType)) {
        .error_union => |eu| {
            const payload = result catch |err| {
                // A custom `fail("…")` message wins; else the error's name.
                g_err = errors.take() orelse @errorName(err);
                return 0;
            };
            return encode(eu.payload, payload, a);
        },
        .void => return pack(""),
        else => return encode(RetType, result, a),
    }
}

/// A string return crosses as raw UTF-8 bytes; everything else as JSON.
fn encode(comptime T: type, value: T, a: std.mem.Allocator) u64 {
    if (comptime convert.classify(T) == .string) return pack(value);
    var out: std.ArrayList(u8) = .empty;
    writeJson(T, value, &out, a) catch {
        g_err = "zignapi: failed to serialize result";
        return 0;
    };
    return pack(out.items);
}

// ---------- A tiny JSON writer (mirrors `convert.toJs`'s shapes) ----------

fn writeJson(comptime T: type, value: T, out: *std.ArrayList(u8), a: std.mem.Allocator) !void {
    switch (comptime convert.classify(T)) {
        .int => try out.print(a, "{d}", .{value}),
        .float => try out.print(a, "{d}", .{value}),
        .bool => try out.appendSlice(a, if (value) "true" else "false"),
        .string => try writeJsonString(out, a, value),
        .enumeration => try writeJsonString(out, a, @tagName(value)),
        .optional => {
            if (value) |v| try writeJson(@typeInfo(T).optional.child, v, out, a) else try out.appendSlice(a, "null");
        },
        .array => {
            const Child = @typeInfo(T).pointer.child;
            try out.append(a, '[');
            for (value, 0..) |elem, i| {
                if (i != 0) try out.append(a, ',');
                try writeJson(Child, elem, out, a);
            }
            try out.append(a, ']');
        },
        .object => {
            try out.append(a, '{');
            inline for (@typeInfo(T).@"struct".fields, 0..) |f, i| {
                if (i != 0) try out.append(a, ',');
                try writeJsonString(out, a, f.name);
                try out.append(a, ':');
                try writeJson(f.type, @field(value, f.name), out, a);
            }
            try out.append(a, '}');
        },
        .taggedUnion => @compileError("zignapi wasm v1: tagged-union returns aren't serialized (use the N-API backend, or v2)"),
        .unsupported => @compileError("zignapi wasm: no JSON mapping for '" ++ @typeName(T) ++ "'"),
    }
}

fn writeJsonString(out: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    try out.append(a, '"');
    for (s) |ch| switch (ch) {
        '"' => try out.appendSlice(a, "\\\""),
        '\\' => try out.appendSlice(a, "\\\\"),
        '\n' => try out.appendSlice(a, "\\n"),
        '\r' => try out.appendSlice(a, "\\r"),
        '\t' => try out.appendSlice(a, "\\t"),
        0...8, 11, 12, 14...31 => try out.print(a, "\\u{x:0>4}", .{ch}),
        else => try out.append(a, ch),
    };
    try out.append(a, '"');
}

// ---------- The meta blob (comptime JSON) ----------

/// `{ "dts": "...", "returns": { name: kind, ... }, "consts": { NAME: value } }`.
/// `kind` ∈ string | number | boolean | json | void — tells the glue how to
/// decode each function's result.
fn MetaExport(comptime defs: anytype) type {
    return struct {
        const blob = buildMeta(defs);
        fn call() callconv(.c) u64 {
            return pack(blob);
        }
    };
}

fn buildMeta(comptime defs: anytype) []const u8 {
    comptime {
        // The embedded `.d.ts` can be long (e.g. a wide enum union), and the
        // char-by-char comptime escaping/concatenation below burns branches.
        @setEvalBranchQuota(1_000_000);
        var s: []const u8 = "{\"dts\":" ++ jsonQuote(typedefs.declarations(defs));
        s = s ++ ",\"returns\":{";
        var first = true;
        for (@typeInfo(@TypeOf(defs)).@"struct".fields) |field| {
            const val = @field(defs, field.name);
            if (@typeInfo(@TypeOf(val)) != .@"fn" or !wasmExportable(@TypeOf(val))) continue;
            if (!first) s = s ++ ",";
            first = false;
            s = s ++ jsonQuote(field.name) ++ ":" ++ jsonQuote(returnKind(@TypeOf(val)));
        }
        s = s ++ "},\"consts\":{";
        first = true;
        for (@typeInfo(@TypeOf(defs)).@"struct".fields) |field| {
            const val = @field(defs, field.name);
            if (@typeInfo(@TypeOf(val)) == .@"fn") continue;
            if (@import("async.zig").isAsyncMarker(@TypeOf(val))) continue;
            if (!first) s = s ++ ",";
            first = false;
            s = s ++ jsonQuote(field.name) ++ ":" ++ constJson(convert.CoercedConst(@TypeOf(val)), convert.coerceConst(val));
        }
        return s ++ "}}";
    }
}

/// The glue's decode strategy for a function's return type.
fn returnKind(comptime FnT: type) []const u8 {
    const RetType = @typeInfo(FnT).@"fn".return_type.?;
    const Payload = switch (@typeInfo(RetType)) {
        .error_union => |eu| eu.payload,
        .void => return "void",
        else => RetType,
    };
    return switch (convert.classify(Payload)) {
        .string => "string",
        .int, .float => "number",
        .bool => "boolean",
        else => "json",
    };
}

/// Comptime JSON of a constant value (scalars, strings, and one level of struct).
fn constJson(comptime T: type, comptime value: T) []const u8 {
    return switch (convert.classify(T)) {
        .int, .float => std.fmt.comptimePrint("{d}", .{value}),
        .bool => if (value) "true" else "false",
        .string => jsonQuote(value),
        .enumeration => jsonQuote(@tagName(value)),
        .object => blk: {
            var s: []const u8 = "{";
            for (@typeInfo(T).@"struct".fields, 0..) |f, i| {
                if (i != 0) s = s ++ ",";
                s = s ++ jsonQuote(f.name) ++ ":" ++ constJson(f.type, @field(value, f.name));
            }
            break :blk s ++ "}";
        },
        else => "null",
    };
}

/// Comptime double-quote + escape of a string literal for embedding in JSON.
fn jsonQuote(comptime s: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "\"";
        for (s) |ch| out = out ++ switch (ch) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            else => &[_]u8{ch},
        };
        return out ++ "\"";
    }
}
