//! Raw N-API bindings and thin wrappers.
//!
//! The N-API C headers are vendored under `vendor/node-api-headers/` and pulled
//! in here with `@cImport`. Everything the rest of the library needs from the C
//! API is re-exported through `c`, plus a few ergonomic wrappers so the comptime
//! machinery in `convert.zig` / `register.zig` doesn't have to spell out the raw
//! `napi_status` dance every time.

const std = @import("std");
const builtin = @import("builtin");

/// The N-API C API is only relevant to the native (`.node`) backend. On a wasm
/// target there is no Node runtime and no headers to include, so `@cImport`
/// would fail — we swap in an empty stub. Everything in this file that touches
/// `c.napi_*` (the wrapper functions) is only *analyzed* when referenced, and
/// the wasm build never references it (`register` routes to `wasm.zig`). The few
/// TYPES below are stubbed so the shared `.d.ts`/registration code still
/// type-checks on wasm without pulling in the C import.
const is_wasm = builtin.target.cpu.arch.isWasm();

/// The imported N-API C API. We pin `NAPI_VERSION` to 8 (Node >= 18) so the
/// headers expose exactly the surface we support.
pub const c = if (is_wasm) struct {} else @cImport({
    @cDefine("NAPI_VERSION", "8");
    @cInclude("node_api.h");
});

// Convenience aliases for the handful of opaque handles we pass around. On wasm
// these are inert placeholders (never a real value crosses the boundary).
pub const Env = if (is_wasm) ?*anyopaque else c.napi_env;
pub const Value = if (is_wasm) ?*anyopaque else c.napi_value;
pub const CallbackInfo = if (is_wasm) ?*anyopaque else c.napi_callback_info;
pub const Callback = if (is_wasm) ?*const anyopaque else c.napi_callback;
pub const Status = if (is_wasm) c_int else c.napi_status;

/// A call into the N-API C API returned a non-`napi_ok` status.
pub const Error = error{NapiFailure};

/// Turn a `napi_status` into a Zig error. `napi_ok` is `0`.
pub fn check(status: Status) Error!void {
    if (status != c.napi_ok) return Error.NapiFailure;
}

/// Throw a JavaScript `Error` with the given message and return control to JS.
/// `msg` must be a null-terminated string. Used to surface Zig error unions.
pub fn throwError(env: Env, msg: [:0]const u8) void {
    _ = c.napi_throw_error(env, null, msg.ptr);
}

/// Read the arguments of the current call into `argv`, returning the actual
/// argument count reported by N-API.
pub fn getCallbackInfo(
    env: Env,
    info: CallbackInfo,
    argv: []Value,
) Error!usize {
    var argc: usize = argv.len;
    const argv_ptr: [*c]Value = if (argv.len == 0) null else argv.ptr;
    try check(c.napi_get_cb_info(env, info, &argc, argv_ptr, null, null));
    return argc;
}

/// Attach `value` to `object` under the (null-terminated) property `name`.
pub fn setNamedProperty(env: Env, object: Value, name: [:0]const u8, value: Value) Error!void {
    try check(c.napi_set_named_property(env, object, name.ptr, value));
}

/// Create a JS function backed by the native callback `cb`, named `name`.
pub fn createFunction(env: Env, name: [:0]const u8, cb: Callback) Error!Value {
    var result: Value = undefined;
    try check(c.napi_create_function(env, name.ptr, name.len, cb, null, &result));
    return result;
}

/// Create a JS UTF-8 string from a Zig slice.
pub fn createString(env: Env, s: []const u8) Error!Value {
    var result: Value = undefined;
    try check(c.napi_create_string_utf8(env, s.ptr, s.len, &result));
    return result;
}

/// The JS `undefined` value.
pub fn getUndefined(env: Env) Error!Value {
    var result: Value = undefined;
    try check(c.napi_get_undefined(env, &result));
    return result;
}

/// Create a JS `Error` object carrying `msg` (used to reject promises).
pub fn createError(env: Env, msg: []const u8) Error!Value {
    const message = try createString(env, msg);
    var result: Value = undefined;
    try check(c.napi_create_error(env, null, message, &result));
    return result;
}

// ---------- Building structured JS values (objects & arrays) ----------
//
// zignapi's automatic `convert` only covers scalars and strings. To return a
// composite value (an object, an array of objects, an AST node…), a function
// takes `env: napi.Env`, builds the value with these helpers, and returns it as
// a raw `napi.Value` (which `register` passes straight through to JS).

/// Create an empty JS object (`{}`).
pub fn createObject(env: Env) Error!Value {
    var result: Value = undefined;
    try check(c.napi_create_object(env, &result));
    return result;
}

/// Create a JS array of length `len` (`new Array(len)`).
pub fn createArray(env: Env, len: usize) Error!Value {
    var result: Value = undefined;
    try check(c.napi_create_array_with_length(env, len, &result));
    return result;
}

/// Set `array[index] = value`.
pub fn setElement(env: Env, array: Value, index: u32, value: Value) Error!void {
    try check(c.napi_set_element(env, array, index, value));
}

/// `array.length` (assumes `array` is a JS array).
pub fn getArrayLength(env: Env, array: Value) Error!u32 {
    var len: u32 = 0;
    try check(c.napi_get_array_length(env, array, &len));
    return len;
}

/// `array[index]`.
pub fn getElement(env: Env, array: Value, index: u32) Error!Value {
    var result: Value = undefined;
    try check(c.napi_get_element(env, array, index, &result));
    return result;
}

/// Whether `object` has an own/inherited property `name` (null-terminated).
pub fn hasNamedProperty(env: Env, object: Value, name: [:0]const u8) Error!bool {
    var has: bool = false;
    try check(c.napi_has_named_property(env, object, name.ptr, &has));
    return has;
}

/// `object[name]` (null-terminated `name`).
pub fn getNamedProperty(env: Env, object: Value, name: [:0]const u8) Error!Value {
    var result: Value = undefined;
    try check(c.napi_get_named_property(env, object, name.ptr, &result));
    return result;
}

/// The JS `null` value.
pub fn getNull(env: Env) Error!Value {
    var result: Value = undefined;
    try check(c.napi_get_null(env, &result));
    return result;
}

/// Whether `value` is JS `null` or `undefined` (used to decode `?T`).
pub fn isNullish(env: Env, value: Value) Error!bool {
    var t: c.napi_valuetype = undefined;
    try check(c.napi_typeof(env, value, &t));
    return t == c.napi_null or t == c.napi_undefined;
}

// ---------- Throwing structured errors ----------

/// Throw a JS `Error` carrying an arbitrary-length `msg` (no null terminator
/// required, unlike `throwError`). Used by `register` to surface custom error
/// messages set via `zignapi.fail`.
pub fn throwMessage(env: Env, msg: []const u8) void {
    const err = createError(env, msg) catch {
        throwError(env, "zignapi: error");
        return;
    };
    _ = c.napi_throw(env, err);
}
