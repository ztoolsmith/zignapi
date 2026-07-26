const std = @import("std");

/// Builds the addon. Two targets, two artifacts (`zignapi build` /
/// `zignapi build --target wasm`):
///   - native → `zig-out/lib/__NAME__.node` (dynamic lib; N-API symbols left
///     undefined and resolved by Node at load time),
///   - wasm   → `zig-out/lib/__NAME__.wasm` (wasm32-freestanding, no libc, no
///     entry point, symbols exported).
///
/// `link_libc` is decided HERE by the target: the N-API backend needs libc, the
/// freestanding wasm backend rejects it (so it isn't set on the zignapi module).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const is_wasm = target.result.cpu.arch.isWasm();

    const zignapi = b.dependency("zignapi", .{}).module("zignapi");

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = !is_wasm,
        .imports = &.{
            .{ .name = "zignapi", .module = zignapi },
        },
    });

    if (is_wasm) {
        const wasm = b.addExecutable(.{ .name = "__NAME__", .root_module = mod });
        wasm.entry = .disabled; // no `main`, just exports
        wasm.rdynamic = true;
        const install = b.addInstallFileWithDir(wasm.getEmittedBin(), .lib, "__NAME__.wasm");
        b.getInstallStep().dependOn(&install.step);
    } else {
        const addon = b.addLibrary(.{ .name = "__NAME__", .linkage = .dynamic, .root_module = mod });
        // Portable equivalent of macOS `-undefined dynamic_lookup`: let N-API
        // symbols stay undefined so Node resolves them when it loads the addon.
        addon.linker_allow_shlib_undefined = true;
        const install = b.addInstallFileWithDir(addon.getEmittedBin(), .lib, "__NAME__.node");
        b.getInstallStep().dependOn(&install.step);
    }
}
