const std = @import("std");

/// Build script for the `zignapi` Zig library.
///
/// This package bundles the Zig library (`native/`) and the TypeScript CLI
/// (`src/`). Here we only build the Zig side. Its main product is the Zig
/// module named "zignapi" (exposed via `b.addModule`), which addons import to
/// register their functions with Node. Building here also runs two local
/// checks so `zig build` in this directory validates the library on its own:
///
///   - a compile check (`native/_check.zig` built as an object) that exercises
///     the full comptime pipeline for every supported type, and
///   - `zig build test`, the pure-comptime unit tests in `native/convert.zig`
///     and `native/typedefs.zig`.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const headers = b.path("native/vendor/node-api-headers");

    // The module consumers import as `@import("zignapi")`. Target/optimize are
    // left unset here so each consumer picks them; the include path travels with
    // the module. `link_libc` is intentionally NOT set on the module: the native
    // backend needs libc (C allocator + `@cImport` of the N-API headers), but
    // the wasm backend is freestanding and REJECTS libc. So the consumer sets
    // `link_libc = !is_wasm` on its own root module (see the template build.zig).
    const mod = b.addModule("zignapi", .{
        .root_source_file = b.path("native/root.zig"),
    });
    mod.addIncludePath(headers);

    // Expose the N-API import-definition file to consumers as a NAMED lazy path.
    // On Windows a consumer generates an import library from it (a DLL can't
    // leave the N-API symbols undefined). Exposing it via `b.path` here (relative
    // to zignapi) + `dependency.namedLazyPath` there travels correctly across the
    // dependency boundary — unlike `dependency.path`, which mangles the path on
    // Windows (leading `\` before the drive letter).
    b.addNamedLazyPath("node_api_def", b.path("native/vendor/node_api.def"));

    // Standalone compile check. Built as an object, so the still-undefined
    // N-API symbols are fine (they resolve when a real addon links). Failing
    // to compile any of the conversion/registration code fails `zig build`.
    const check_mod = b.createModule(.{
        .root_source_file = b.path("native/_check.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    check_mod.addIncludePath(headers);
    const check_obj = b.addObject(.{
        .name = "zignapi-check",
        .root_module = check_mod,
    });
    b.getInstallStep().dependOn(&check_obj.step);

    // Unit tests: only pure-comptime code (no N-API runtime calls), so the test
    // binaries link without Node present.
    const test_step = b.step("test", "Run zignapi unit tests");
    for ([_][]const u8{ "native/convert.zig", "native/typedefs.zig" }) |root| {
        const tests_mod = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        tests_mod.addIncludePath(headers);
        const unit_tests = b.addTest(.{ .root_module = tests_mod });
        test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    }
}
