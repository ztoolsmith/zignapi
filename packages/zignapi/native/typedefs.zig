//! Comptime generation of TypeScript declarations for the registered functions.
//!
//! The mapping reuses `convert.classify`, so the `.d.ts` and the runtime
//! conversions can never drift apart. `register.zig` embeds the produced string
//! in the addon (as the `__zignapi_dts__` export); `zignapi build` reads it back
//! and writes `index.d.ts` / `index.js`.

const std = @import("std");
const napi = @import("napi.zig");
const convert = @import("convert.zig");
const asyncwork = @import("async.zig");

/// The TypeScript type string for a Zig type. `napi.Value` (a raw JS handle,
/// e.g. a callback) maps to `any`; error unions map to their payload (Zig
/// errors surface as thrown JS exceptions); `void` maps to `void`. Composite
/// types render structurally so the `.d.ts` mirrors `convert` exactly (no more
/// `any` for objects/arrays).
pub fn tsType(comptime T: type) []const u8 {
    if (T == napi.Value) return "any";
    return switch (@typeInfo(T)) {
        .void => "void",
        .error_union => |eu| tsType(eu.payload),
        else => switch (convert.classify(T)) {
            .int, .float => "number",
            .bool => "boolean",
            .string => "string",
            .enumeration => enumUnion(T),
            .optional => tsType(@typeInfo(T).optional.child) ++ " | null",
            .array => "Array<" ++ tsType(@typeInfo(T).pointer.child) ++ ">",
            .object => objectType(T),
            .taggedUnion => unionType(T),
            .unsupported => @compileError(
                "zignapi: no TypeScript mapping for '" ++ @typeName(T) ++ "'",
            ),
        },
    };
}

/// `enum { a, b }` → `"a" | "b"` (matches `convert`'s enum→tag-name mapping).
fn enumUnion(comptime T: type) []const u8 {
    comptime var out: []const u8 = "";
    inline for (@typeInfo(T).@"enum".fields, 0..) |field, i| {
        out = out ++ (if (i == 0) "" else " | ") ++ "\"" ++ field.name ++ "\"";
    }
    return out;
}

/// `struct { a: T, b: U }` → `{ a: <T>; b: <U> }`.
fn objectType(comptime T: type) []const u8 {
    comptime var out: []const u8 = "{ ";
    inline for (@typeInfo(T).@"struct".fields, 0..) |field, i| {
        out = out ++ (if (i == 0) "" else "; ") ++ field.name ++ ": " ++ tsType(field.type);
    }
    return out ++ " }";
}

/// `union(enum) { a: A, b: void }` → `{ type: "a"; …A } | { type: "b" }`.
fn unionType(comptime T: type) []const u8 {
    comptime var out: []const u8 = "";
    inline for (@typeInfo(T).@"union".fields, 0..) |field, i| {
        out = out ++ (if (i == 0) "" else " | ") ++ variantType(field);
    }
    return out;
}

fn variantType(comptime field: std.builtin.Type.UnionField) []const u8 {
    if (field.type == void) return "{ type: \"" ++ field.name ++ "\" }";
    return switch (@typeInfo(field.type)) {
        .@"struct" => |ps| blk: {
            comptime var out: []const u8 = "{ type: \"" ++ field.name ++ "\"";
            inline for (ps.fields) |pf| out = out ++ "; " ++ pf.name ++ ": " ++ tsType(pf.type);
            break :blk out ++ " }";
        },
        else => "{ type: \"" ++ field.name ++ "\"; value: " ++ tsType(field.type) ++ " }",
    };
}

/// Build the `.d.ts` body: one `export function` line per registered function.
/// `napi.Env` parameters are skipped (they aren't JS arguments); `asyncFn`
/// functions return `Promise<T>`. Parameter names are `arg0`, `arg1`, …
pub fn declarations(comptime defs: anytype) []const u8 {
    comptime var out: []const u8 = "";
    inline for (@typeInfo(@TypeOf(defs)).@"struct".fields) |field| {
        const field_val = @field(defs, field.name);
        const FieldT = @TypeOf(field_val);
        const is_async = asyncwork.isAsyncMarker(FieldT);

        // A non-function, non-async field is a module constant.
        if (!is_async and @typeInfo(FieldT) != .@"fn") {
            out = out ++ "export const " ++ field.name ++ ": " ++ tsType(convert.CoercedConst(FieldT)) ++ ";\n";
            continue;
        }

        const func = if (is_async) FieldT.func else field_val;
        const fn_info = @typeInfo(@TypeOf(func)).@"fn";

        comptime var params: []const u8 = "";
        comptime var js_i: usize = 0;
        inline for (fn_info.params) |param| {
            const P = param.type.?;
            if (P == napi.Env or P == std.mem.Allocator) continue; // injected, not a JS argument
            const sep = if (js_i == 0) "" else ", ";
            params = params ++ sep ++ std.fmt.comptimePrint("arg{d}: {s}", .{ js_i, tsType(P) });
            js_i += 1;
        }

        const ret = tsType(fn_info.return_type.?);
        const ret_str = if (is_async) "Promise<" ++ ret ++ ">" else ret;
        out = out ++ "export function " ++ field.name ++ "(" ++ params ++ "): " ++ ret_str ++ ";\n";
    }
    return out;
}

test "declarations render sync, async and passthrough signatures" {
    const S = struct {
        fn add(a: i32, b: i32) i32 {
            return a + b;
        }
        fn greet(name: []const u8) []const u8 {
            return name;
        }
        fn heavy(a: i32, b: i32) i32 {
            return a * b;
        }
        fn onEvent(env: napi.Env, cb: napi.Value) void {
            _ = env;
            _ = cb;
        }
    };
    const dts = comptime declarations(.{
        .add = S.add,
        .greet = S.greet,
        .heavy = asyncwork.asyncFn(S.heavy),
        .onEvent = S.onEvent,
    });
    try std.testing.expectEqualStrings(
        \\export function add(arg0: number, arg1: number): number;
        \\export function greet(arg0: string): string;
        \\export function heavy(arg0: number, arg1: number): Promise<number>;
        \\export function onEvent(arg0: any): void;
        \\
    , dts);
}
