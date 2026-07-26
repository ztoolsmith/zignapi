const zignapi = @import("zignapi");

/// Exposed to JS as `addon.add(a, b)`.
pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

/// Exposed to JS as `addon.greet(name)`.
pub fn greet(name: []const u8) []const u8 {
    _ = name;
    return "hello from Zig";
}

/// Async — `zignapi.asyncFn` runs it on a worker thread and returns a
/// `Promise`. The body must not touch JS (it runs off the JS thread).
fn slowSquare(x: i32) i32 {
    return x * x;
}

// Emits `napi_register_module_v1`. Each field becomes a property on the addon's
// `exports`. Add your own Zig functions here.
comptime {
    zignapi.register(.{
        .add = add,
        .greet = greet,
        .slowSquare = zignapi.asyncFn(slowSquare),
    });
}
