//! Module registration: turn a struct of `name = fn` pairs into the
//! `napi_register_module_v1` entry point Node looks up when it loads a `.node`.
//!
//! Usage from an addon's root source file:
//!
//! ```zig
//! const zignapi = @import("zignapi");
//! pub fn add(a: i32, b: i32) i32 { return a + b; }
//! comptime { zignapi.register(.{ .add = add }); }
//! ```

const std = @import("std");
const builtin = @import("builtin");
const napi = @import("napi.zig");
const convert = @import("convert.zig");
const typedefs = @import("typedefs.zig");
const asyncwork = @import("async.zig");
const errors = @import("errors.zig");
const c = napi.c;

/// Expose a set of Zig functions to JavaScript.
///
/// `defs` must be an anonymous struct literal whose field names become the JS
/// property names and whose field values are the Zig functions (or constants).
/// Must be called from a `comptime {}` block at container scope so the `@export`
/// runs while building the module.
///
/// **One declaration, two backends.** The target decides what gets emitted:
///   - native (`.node`)  → the `napi_register_module_v1` entry point (below).
///   - wasm (freestanding) → per-function wasm exports (see `wasm.zig`).
/// The dead branch is comptime-pruned, so a wasm build never analyzes the N-API
/// code and a native build never analyzes the wasm code.
pub fn register(comptime defs: anytype) void {
    switch (@typeInfo(@TypeOf(defs))) {
        .@"struct" => {},
        else => @compileError("zignapi.register expects a struct literal, e.g. .{ .add = add }"),
    }
    if (comptime builtin.target.cpu.arch.isWasm()) {
        @import("wasm.zig").registerWasm(defs);
    } else {
        registerNapi(defs);
    }
}

/// The native backend: export `napi_register_module_v1` for the given defs.
fn registerNapi(comptime defs: anytype) void {
    const Defs = @TypeOf(defs);

    // TypeScript declarations for this module, generated at comptime and
    // embedded so `zignapi build` can emit `index.d.ts` / `index.js`.
    const dts = typedefs.declarations(defs);

    const Registrar = struct {
        fn entry(env: napi.Env, exports: napi.Value) callconv(.c) napi.Value {
            inline for (@typeInfo(Defs).@"struct".fields) |field| {
                registerField(env, exports, field.name, @field(defs, field.name)) catch {
                    napi.throwError(env, "zignapi: failed to register '" ++ field.name ++ "'");
                    return null;
                };
            }
            // Best-effort: attach the type declarations. Failure here must not
            // break a working module, so ignore errors.
            if (napi.createString(env, dts)) |v| {
                napi.setNamedProperty(env, exports, "__zignapi_dts__", v) catch {};
            } else |_| {}
            return exports;
        }
    };

    @export(&Registrar.entry, .{ .name = "napi_register_module_v1", .linkage = .strong });
}

/// Bind a single field onto `exports` under `name`. A field is one of:
///   - a plain function        → registered as a JS function
///   - an `asyncFn(...)` marker → registered as an async (Promise) function
///   - anything else (a value)  → registered as a module constant (string,
///     number, bool, or a struct → object), via `convert.toJs`
fn registerField(
    env: napi.Env,
    exports: napi.Value,
    comptime name: [:0]const u8,
    comptime field_val: anytype,
) !void {
    const T = @TypeOf(field_val);
    if (comptime isConstant(T)) {
        const value = try convert.toJs(convert.CoercedConst(T), env, convert.coerceConst(field_val));
        try napi.setNamedProperty(env, exports, name, value);
        return;
    }
    const fn_value = try napi.createFunction(env, name, callbackFor(field_val));
    try napi.setNamedProperty(env, exports, name, fn_value);
}

/// Whether a registered field is a plain constant value (not a function and not
/// an `asyncFn` marker).
fn isConstant(comptime T: type) bool {
    if (@typeInfo(T) == .@"fn") return false;
    if (asyncwork.isAsyncMarker(T)) return false;
    return true;
}

fn callbackFor(comptime field_val: anytype) napi.Callback {
    const FieldT = @TypeOf(field_val);
    if (comptime asyncwork.isAsyncMarker(FieldT)) {
        return asyncwork.AsyncWrap(FieldT.func).callback;
    }
    return Wrap(field_val).callback;
}

/// Build the `napi_callback` trampoline for a specific Zig function.
///
/// Each distinct `func` produces its own type (and therefore its own callback),
/// which is how we smuggle the target function into the fixed C callback
/// signature without any runtime closure/state.
fn Wrap(comptime func: anytype) type {
    const fn_info = @typeInfo(@TypeOf(func)).@"fn";

    return struct {
        fn callback(env: napi.Env, info: napi.CallbackInfo) callconv(.c) napi.Value {
            // Collect the JS arguments (one slot per Zig parameter).
            var argv: [fn_info.params.len]napi.Value = undefined;
            _ = napi.getCallbackInfo(env, info, &argv) catch {
                napi.throwError(env, "zignapi: failed to read arguments");
                return null;
            };

            // This arena backs both argument conversion (strings/arrays copied
            // out of V8) AND anything the function allocates for its result: it
            // is freed by `defer` only after `finish` has converted the return
            // value into JS, so a returned slice is copied while still valid.
            var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer arena.deinit();
            const allocator = arena.allocator();

            // Clear any custom error message a previous call may have left.
            errors.reset();

            // Convert each argument from JS into its Zig type. Three parameter
            // types are *injected* rather than read from a JS argument (they
            // don't consume an argument slot, like napi-rs's `Env`), so track
            // the JS index separately:
            //   - `napi.Env`         → the environment handle
            //   - `napi.Value`       → the raw JS value (escape hatch)
            //   - `std.mem.Allocator`→ the per-call scratch arena above
            var args: std.meta.ArgsTuple(@TypeOf(func)) = undefined;
            comptime var js_arg: usize = 0;
            inline for (fn_info.params, 0..) |param, i| {
                const P = param.type.?;
                if (P == napi.Env) {
                    args[i] = env;
                } else if (P == napi.Value) {
                    args[i] = argv[js_arg];
                    js_arg += 1;
                } else if (P == std.mem.Allocator) {
                    args[i] = allocator;
                } else {
                    args[i] = convert.fromJs(P, env, argv[js_arg], allocator) catch {
                        napi.throwError(env, "zignapi: failed to convert argument");
                        return null;
                    };
                    js_arg += 1;
                }
            }

            const result = @call(.auto, func, args);
            return finish(env, fn_info.return_type.?, result);
        }

        /// Convert the Zig return value to JS, turning `!T` error unions into
        /// thrown JS exceptions and `void` into `undefined`. An error carries a
        /// custom message when the function returned `zignapi.fail("…")`,
        /// otherwise the JS message is the error's name.
        fn finish(env: napi.Env, comptime RetType: type, result: RetType) napi.Value {
            switch (@typeInfo(RetType)) {
                .error_union => |eu| {
                    const payload = result catch |err| {
                        if (errors.take()) |msg| {
                            napi.throwMessage(env, msg);
                        } else {
                            napi.throwError(env, @errorName(err));
                        }
                        return null;
                    };
                    return toJs(env, eu.payload, payload);
                },
                .void => return null,
                else => return toJs(env, RetType, result),
            }
        }

        fn toJs(env: napi.Env, comptime T: type, value: T) napi.Value {
            // A function may return a raw `napi.Value` — a JS value it built
            // itself (an object, an array, an AST node). Pass it straight
            // through instead of running it through the scalar `convert`.
            if (T == napi.Value) return value;
            return convert.toJs(T, env, value) catch {
                napi.throwError(env, "zignapi: failed to convert return value");
                return null;
            };
        }
    };
}
