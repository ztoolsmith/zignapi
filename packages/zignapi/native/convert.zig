//! Comptime conversions between Zig values and JavaScript values.
//!
//! Every function is generic over the Zig type and dispatches on `@typeInfo`
//! at comptime, so a wrapper compiled for `fn (i32, i32) i32` only ever emits
//! the `int32` code paths.
//!
//! ## Supported types (both directions)
//!
//!   - integers (`i32`/`u32`/`i64`/…), floats (`f16`/`f32`/`f64`), `bool`
//!   - `[]const u8` ↔ string (UTF-8)
//!   - **structs** ↔ plain objects (each field converted by name, recursive)
//!   - **slices** `[]T` (T ≠ const u8) ↔ arrays (recursive)
//!   - **optionals** `?T` ↔ `T | null` (JS `null`/`undefined` → `null`)
//!   - **enums** ↔ their tag name as a string
//!   - **tagged unions** ↔ `{ type: "<tag>", …payload }` (payload struct fields
//!     spread; a non-struct payload goes under `value`; a `void` payload adds
//!     nothing)
//!
//! Composite conversions recurse, so unsupported leaf types fail at comptime
//! with a readable message pointing at the offending type.

const std = @import("std");
const napi = @import("napi.zig");
const c = napi.c;

/// The JS-representable category a Zig type maps onto. Kept as a plain enum
/// (rather than `@compileError` inline) so the classification is unit-testable
/// at comptime without touching the N-API runtime.
pub const Kind = enum { int, float, bool, string, object, array, optional, enumeration, taggedUnion, unsupported };

/// Classify a Zig type. `.unsupported` means there is no JS mapping for it.
pub fn classify(comptime T: type) Kind {
    return switch (@typeInfo(T)) {
        .int => .int,
        .float => .float,
        .bool => .bool,
        .@"enum" => .enumeration,
        .optional => .optional,
        .@"struct" => .object,
        .@"union" => |u| if (u.tag_type != null) .taggedUnion else .unsupported,
        // The one string exception is a const byte slice; every other slice is
        // an array. Non-slice pointers (e.g. `*Node`) have no JS mapping.
        .pointer => |p| if (p.size != .slice)
            .unsupported
        else if (p.child == u8 and p.is_const)
            .string
        else
            .array,
        else => .unsupported,
    };
}

/// Compile-time guard that fails with a readable message for unsupported types.
fn assertSupported(comptime T: type) void {
    if (classify(T) == .unsupported) {
        @compileError("zignapi: unsupported type '" ++ @typeName(T) ++
            "' (supported: ints, floats, bool, []const u8, structs, slices, ?T, enums, tagged unions)");
    }
}

/// Read a JavaScript `value` into a Zig value of type `T`.
///
/// `allocator` backs every heap result: string bytes copied out of V8, slices
/// built from arrays, and any of these nested inside a struct/optional/union.
/// The caller owns those allocations' lifetime.
pub fn fromJs(comptime T: type, env: napi.Env, value: napi.Value, allocator: std.mem.Allocator) !T {
    comptime assertSupported(T);
    return switch (comptime classify(T)) {
        .int => blk: {
            const info = @typeInfo(T).int;
            if (info.signedness == .unsigned and info.bits <= 32) {
                var out: u32 = undefined;
                try napi.check(c.napi_get_value_uint32(env, value, &out));
                break :blk @intCast(out);
            } else if (info.signedness == .signed and info.bits <= 32) {
                var out: i32 = undefined;
                try napi.check(c.napi_get_value_int32(env, value, &out));
                break :blk @intCast(out);
            } else {
                var out: i64 = undefined;
                try napi.check(c.napi_get_value_int64(env, value, &out));
                break :blk @intCast(out);
            }
        },
        .float => blk: {
            var out: f64 = undefined;
            try napi.check(c.napi_get_value_double(env, value, &out));
            break :blk @floatCast(out);
        },
        .bool => blk: {
            var out: bool = undefined;
            try napi.check(c.napi_get_value_bool(env, value, &out));
            break :blk out;
        },
        .string => blk: {
            // First call with a null buffer to learn the byte length, then copy.
            var len: usize = 0;
            try napi.check(c.napi_get_value_string_utf8(env, value, null, 0, &len));
            const buf = try allocator.alloc(u8, len + 1);
            var written: usize = 0;
            try napi.check(c.napi_get_value_string_utf8(env, value, buf.ptr, buf.len, &written));
            break :blk buf[0..written];
        },
        .enumeration => blk: {
            const name = try fromJs([]const u8, env, value, allocator);
            break :blk std.meta.stringToEnum(T, name) orelse return napi.Error.NapiFailure;
        },
        .optional => blk: {
            const Child = @typeInfo(T).optional.child;
            if (try napi.isNullish(env, value)) break :blk null;
            break :blk try fromJs(Child, env, value, allocator);
        },
        .array => blk: {
            const Child = @typeInfo(T).pointer.child;
            const len = try napi.getArrayLength(env, value);
            const out = try allocator.alloc(Child, len);
            var i: u32 = 0;
            while (i < len) : (i += 1) {
                out[i] = try fromJs(Child, env, try napi.getElement(env, value, i), allocator);
            }
            break :blk out;
        },
        .object => blk: {
            var out: T = undefined;
            inline for (@typeInfo(T).@"struct".fields) |field| {
                @field(out, field.name) = try fromJsField(field, env, value, allocator);
            }
            break :blk out;
        },
        .taggedUnion => blk: {
            const name = try fromJs([]const u8, env, try napi.getNamedProperty(env, value, "type"), allocator);
            break :blk try fromJsUnion(T, env, value, allocator, name);
        },
        .unsupported => unreachable,
    };
}

/// Read one struct field from `object`. A missing property falls back to the
/// field's default value if it has one, else errors.
fn fromJsField(
    comptime field: std.builtin.Type.StructField,
    env: napi.Env,
    object: napi.Value,
    allocator: std.mem.Allocator,
) !field.type {
    if (!try napi.hasNamedProperty(env, object, field.name)) {
        if (field.default_value_ptr) |ptr| {
            const dv: *const field.type = @ptrCast(@alignCast(ptr));
            return dv.*;
        }
        return napi.Error.NapiFailure;
    }
    return fromJs(field.type, env, try napi.getNamedProperty(env, object, field.name), allocator);
}

/// Decode `{ type: name, … }` into the union variant whose tag is `name`.
fn fromJsUnion(comptime T: type, env: napi.Env, value: napi.Value, allocator: std.mem.Allocator, name: []const u8) !T {
    inline for (@typeInfo(T).@"union".fields) |field| {
        if (std.mem.eql(u8, field.name, name)) {
            if (field.type == void) return @unionInit(T, field.name, {});
            const payload = switch (@typeInfo(field.type)) {
                // Struct payloads were spread onto the object itself.
                .@"struct" => try fromJs(field.type, env, value, allocator),
                // Everything else lives under `value`.
                else => try fromJs(field.type, env, try napi.getNamedProperty(env, value, "value"), allocator),
            };
            return @unionInit(T, field.name, payload);
        }
    }
    return napi.Error.NapiFailure;
}

/// Create a JavaScript value from a Zig value of type `T`.
pub fn toJs(comptime T: type, env: napi.Env, value: T) !napi.Value {
    comptime assertSupported(T);
    switch (comptime classify(T)) {
        .int => {
            var result: napi.Value = undefined;
            const info = @typeInfo(T).int;
            if (info.signedness == .unsigned and info.bits <= 32) {
                try napi.check(c.napi_create_uint32(env, @intCast(value), &result));
            } else if (info.signedness == .signed and info.bits <= 32) {
                try napi.check(c.napi_create_int32(env, @intCast(value), &result));
            } else {
                try napi.check(c.napi_create_int64(env, @intCast(value), &result));
            }
            return result;
        },
        .float => {
            var result: napi.Value = undefined;
            try napi.check(c.napi_create_double(env, @floatCast(value), &result));
            return result;
        },
        .bool => {
            var result: napi.Value = undefined;
            try napi.check(c.napi_get_boolean(env, value, &result));
            return result;
        },
        .string => return napi.createString(env, value),
        .enumeration => return napi.createString(env, @tagName(value)),
        .optional => {
            if (value) |v| return toJs(@typeInfo(T).optional.child, env, v);
            return napi.getNull(env);
        },
        .array => {
            const Child = @typeInfo(T).pointer.child;
            const arr = try napi.createArray(env, value.len);
            for (value, 0..) |elem, i| {
                try napi.setElement(env, arr, @intCast(i), try toJs(Child, env, elem));
            }
            return arr;
        },
        .object => {
            const obj = try napi.createObject(env);
            inline for (@typeInfo(T).@"struct".fields) |field| {
                try napi.setNamedProperty(env, obj, field.name, try toJs(field.type, env, @field(value, field.name)));
            }
            return obj;
        },
        .taggedUnion => {
            const obj = try napi.createObject(env);
            switch (value) {
                inline else => |payload, tag| {
                    try napi.setNamedProperty(env, obj, "type", try napi.createString(env, @tagName(tag)));
                    const P = @TypeOf(payload);
                    if (P != void) switch (@typeInfo(P)) {
                        .@"struct" => |ps| inline for (ps.fields) |pf| {
                            try napi.setNamedProperty(env, obj, pf.name, try toJs(pf.type, env, @field(payload, pf.name)));
                        },
                        else => try napi.setNamedProperty(env, obj, "value", try toJs(P, env, payload)),
                    };
                },
            }
            return obj;
        },
        .unsupported => unreachable,
    }
}

/// The concrete type a *constant* registered value is exposed as. Untyped
/// literals get a fixed width, and a string literal (`*const [N:0]u8`) becomes
/// `[]const u8`, so `register(.{ .VERSION = "1.0.0", .MAX = 42 })` just works.
pub fn CoercedConst(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .comptime_int => i64,
        .comptime_float => f64,
        .pointer => |p| if (p.size == .one and isByteArray(p.child)) []const u8 else T,
        else => T,
    };
}

fn isByteArray(comptime C: type) bool {
    return switch (@typeInfo(C)) {
        .array => |a| a.child == u8,
        else => false,
    };
}

/// Coerce a registered constant to its exposed type (see `CoercedConst`).
pub fn coerceConst(comptime v: anytype) CoercedConst(@TypeOf(v)) {
    return v;
}

test "classify maps Zig types to JS kinds" {
    const expectEqual = std.testing.expectEqual;
    try expectEqual(Kind.int, classify(i32));
    try expectEqual(Kind.int, classify(u64));
    try expectEqual(Kind.float, classify(f64));
    try expectEqual(Kind.float, classify(f32));
    try expectEqual(Kind.bool, classify(bool));
    try expectEqual(Kind.string, classify([]const u8));
    // Composite kinds.
    try expectEqual(Kind.object, classify(struct { x: i32 }));
    try expectEqual(Kind.array, classify([]const []const u8));
    try expectEqual(Kind.array, classify([]u32));
    try expectEqual(Kind.optional, classify(?i32));
    try expectEqual(Kind.enumeration, classify(enum { a, b }));
    try expectEqual(Kind.taggedUnion, classify(union(enum) { a: i32, b: void }));
    // A bare (untagged) union and a non-slice pointer have no JS mapping.
    try expectEqual(Kind.unsupported, classify(*u8));
    try expectEqual(Kind.unsupported, classify(extern union { a: i32 }));
}
