//! Rich errors: let a Zig function surface a *custom* JS exception message
//! (and not just `@errorName`).
//!
//! A registered function returns `!T`. If it just `try`s and an error escapes,
//! `register` throws a JS `Error` whose message is the error's name
//! (`"OutOfMemory"`). To throw a precise, user-facing message instead, return
//! `zignapi.fail("…")`:
//!
//! ```zig
//! fn tokenize(a: std.mem.Allocator, src: []const u8) ![]const Token {
//!     var d: lexer.Diagnostic = .{};
//!     return lexer.tokenizeDiag(a, src, &d, false) catch
//!         return zignapi.fail(try std.fmt.allocPrint(a, "{s} (offset {d})", .{ d.message, d.pos }));
//! }
//! ```
//!
//! ## Lifetime rule (same as return values)
//!
//! The message is read (copied into V8) *after* the function returns but
//! *before* the call's scratch arena is freed — so allocate it in the injected
//! `std.mem.Allocator` (or use a static string). A `[]const u8` into freed
//! memory is a use-after-free, exactly as for a returned slice.
//!
//! ## Scope
//!
//! Sync functions only. The detail is stored in a thread-local set-then-read
//! within one synchronous callback (the Zig body never re-enters JS), so there
//! is no interleaving. `asyncFn` / threadsafe paths do not use this.

/// The sentinel error `fail` returns. Any `!T` return type infers a superset of
/// this, so `return zignapi.fail(...)` type-checks in every registered function.
pub const Error = error{ZignapiThrow};

/// The pending custom message, if any. Set by `fail`, consumed by `register`.
threadlocal var detail: ?[]const u8 = null;

/// Record a custom exception message and return the sentinel error. See module
/// docs for the lifetime rule.
pub fn fail(message: []const u8) Error {
    detail = message;
    return Error.ZignapiThrow;
}

/// Clear any stale message. `register` calls this at the start of every call so
/// a message left behind by a previous call can never leak into this one.
pub fn reset() void {
    detail = null;
}

/// Take and clear the pending message (called by `register` on the error path).
pub fn take() ?[]const u8 {
    defer detail = null;
    return detail;
}
