//! Async support: run a Zig function on libuv's thread pool and resolve a JS
//! `Promise`, plus a threadsafe-function primitive for calling JS from any
//! thread.
//!
//! ## Async functions
//!
//! Wrap a function with `asyncFn` when registering it. Its arguments are
//! converted on the JS thread, the function body runs on a worker thread (so it
//! must NOT touch JS / N-API), and the result (or a thrown error) settles the
//! promise back on the JS thread:
//!
//! ```zig
//! fn heavy(a: i32, b: i32) i32 { return a * b; }
//! comptime { zignapi.register(.{ .heavy = zignapi.asyncFn(heavy) }); }
//! // JS: await addon.heavy(6, 7) === 42
//! ```
//!
//! ## Threadsafe functions
//!
//! `ThreadsafeFunction(T)` lets native code call a JS callback from any thread.
//! Create it on the JS thread from a callback the addon received as a raw
//! `napi.Value`, hand it to a worker thread, `call` it, then `release` it.

const std = @import("std");
const napi = @import("napi.zig");
const convert = @import("convert.zig");
const c = napi.c;

/// Mark a function as async when registering it (runs on the thread pool and
/// returns a `Promise`). See the module docs.
pub fn asyncFn(comptime f: anytype) AsyncMarker(f) {
    return .{};
}

fn AsyncMarker(comptime f: anytype) type {
    return struct {
        pub const zignapi_async_task = true;
        pub const func = f;
    };
}

/// Whether a `register` field value's type is an `asyncFn(...)` marker.
pub fn isAsyncMarker(comptime FieldT: type) bool {
    return switch (@typeInfo(FieldT)) {
        .@"struct" => @hasDecl(FieldT, "zignapi_async_task"),
        else => false,
    };
}

/// Build the `napi_callback` trampoline for an async function: it returns a
/// Promise immediately and does the work on a libuv worker thread.
pub fn AsyncWrap(comptime func: anytype) type {
    const fn_info = @typeInfo(@TypeOf(func)).@"fn";
    const RetType = fn_info.return_type.?;
    const Payload = switch (@typeInfo(RetType)) {
        .error_union => |eu| eu.payload,
        else => RetType,
    };

    const Task = struct {
        args: std.meta.ArgsTuple(@TypeOf(func)),
        arena: std.heap.ArenaAllocator,
        deferred: c.napi_deferred,
        work: c.napi_async_work,
        payload: Payload,
        err_name: ?[:0]const u8,
    };

    return struct {
        pub fn callback(env: napi.Env, info: napi.CallbackInfo) callconv(.c) napi.Value {
            var argv: [fn_info.params.len]napi.Value = undefined;
            _ = napi.getCallbackInfo(env, info, &argv) catch {
                napi.throwError(env, "zignapi: failed to read arguments");
                return null;
            };

            const task = std.heap.c_allocator.create(Task) catch {
                napi.throwError(env, "zignapi: out of memory");
                return null;
            };
            task.arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            task.err_name = null;

            // Convert arguments on the JS thread (N-API access is valid here).
            const allocator = task.arena.allocator();
            inline for (fn_info.params, 0..) |param, i| {
                task.args[i] = convert.fromJs(param.type.?, env, argv[i], allocator) catch
                    return abort(task, env, "zignapi: failed to convert argument");
            }

            var promise: napi.Value = undefined;
            if (c.napi_create_promise(env, &task.deferred, &promise) != c.napi_ok)
                return abort(task, env, "zignapi: failed to create promise");

            const name = napi.createString(env, "zignapi_async_task") catch
                return abort(task, env, "zignapi: failed to create async work");

            _ = c.napi_create_async_work(env, null, name, execute, complete, task, &task.work);
            _ = c.napi_queue_async_work(env, task.work);
            return promise;
        }

        /// Free a partially-initialised task, throw, and return null (on the JS
        /// thread, before the work is queued).
        fn abort(task: *Task, env: napi.Env, msg: [:0]const u8) napi.Value {
            task.arena.deinit();
            std.heap.c_allocator.destroy(task);
            napi.throwError(env, msg);
            return null;
        }

        /// Worker thread — no N-API / JS access allowed.
        fn execute(env: napi.Env, data: ?*anyopaque) callconv(.c) void {
            _ = env;
            const task: *Task = @ptrCast(@alignCast(data.?));
            switch (@typeInfo(RetType)) {
                .error_union => task.payload = @call(.auto, func, task.args) catch |err| {
                    task.err_name = @errorName(err);
                    return;
                },
                else => task.payload = @call(.auto, func, task.args),
            }
        }

        /// JS thread — settle the promise with the result or the error.
        fn complete(env: napi.Env, status: c.napi_status, data: ?*anyopaque) callconv(.c) void {
            const task: *Task = @ptrCast(@alignCast(data.?));
            defer {
                task.arena.deinit();
                _ = c.napi_delete_async_work(env, task.work);
                std.heap.c_allocator.destroy(task);
            }

            if (status != c.napi_ok) return reject(env, task.deferred, "zignapi: async work cancelled");
            if (task.err_name) |name| return reject(env, task.deferred, name);

            const resolution = if (Payload == void)
                (napi.getUndefined(env) catch return reject(env, task.deferred, "zignapi: internal error"))
            else
                (convert.toJs(Payload, env, task.payload) catch
                    return reject(env, task.deferred, "zignapi: failed to convert result"));
            _ = c.napi_resolve_deferred(env, task.deferred, resolution);
        }
    };
}

fn reject(env: napi.Env, deferred: c.napi_deferred, msg: []const u8) void {
    const err = napi.createError(env, msg) catch return;
    _ = c.napi_reject_deferred(env, deferred, err);
}

/// A threadsafe function: a JS callback that native code can invoke from any
/// thread. `T` is the Zig type of the single argument passed to the callback
/// (converted to JS via `convert`). Create it on the JS thread, use it from
/// worker threads, and `release` it when done.
pub fn ThreadsafeFunction(comptime T: type) type {
    return struct {
        const Self = @This();

        handle: c.napi_threadsafe_function,

        /// Create from a JS callback value. Call on the JS thread.
        pub fn create(env: napi.Env, js_callback: napi.Value) napi.Error!Self {
            const name = try napi.createString(env, "zignapi_tsfn");
            var handle: c.napi_threadsafe_function = undefined;
            try napi.check(c.napi_create_threadsafe_function(
                env,
                js_callback,
                null, // async_resource
                name,
                0, // max_queue_size: unlimited
                1, // initial_thread_count
                null, // thread_finalize_data
                null, // thread_finalize_cb
                null, // context
                callJs,
                &handle,
            ));
            return .{ .handle = handle };
        }

        /// Queue a call to the JS callback with `value`. Safe from any thread.
        pub fn call(self: Self, value: T) napi.Error!void {
            const boxed = std.heap.c_allocator.create(T) catch return napi.Error.NapiFailure;
            boxed.* = value;
            if (c.napi_call_threadsafe_function(self.handle, boxed, c.napi_tsfn_blocking) != c.napi_ok) {
                std.heap.c_allocator.destroy(boxed);
                return napi.Error.NapiFailure;
            }
        }

        /// Release the reference so Node can tear the function down. Any thread.
        pub fn release(self: Self) void {
            _ = c.napi_release_threadsafe_function(self.handle, c.napi_tsfn_release);
        }

        /// JS thread — convert the queued value and invoke the callback.
        fn callJs(env: napi.Env, js_cb: napi.Value, context: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
            _ = context;
            const boxed: *T = @ptrCast(@alignCast(data.?));
            defer std.heap.c_allocator.destroy(boxed);
            if (env == null) return; // the environment is tearing down
            const arg = convert.toJs(T, env, boxed.*) catch return;
            const recv = napi.getUndefined(env) catch return;
            var argv = [_]napi.Value{arg};
            _ = c.napi_call_function(env, recv, js_cb, argv.len, &argv, null);
        }
    };
}
