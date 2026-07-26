const std = @import("std");

/// Compile l'addon d'exemple en `zig-out/lib/hello.node`.
///
/// L'addon est une bibliothèque dynamique qui importe le module `zignapi`
/// (résolu depuis `../../packages/zignapi` via build.zig.zon). Les symboles
/// N-API restent volontairement indéfinis au link et sont résolus par Node au
/// chargement du .node.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const is_wasm = target.result.cpu.arch.isWasm();

    const zignapi = b.dependency("zignapi", .{}).module("zignapi");

    const mod = b.createModule(.{
        .root_source_file = b.path("native/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = !is_wasm,
        .imports = &.{
            .{ .name = "zignapi", .module = zignapi },
        },
    });

    if (is_wasm) {
        const wasm = b.addExecutable(.{ .name = "hello", .root_module = mod });
        wasm.entry = .disabled;
        wasm.rdynamic = true;
        const install = b.addInstallFileWithDir(wasm.getEmittedBin(), .lib, "hello.wasm");
        b.getInstallStep().dependOn(&install.step);
    } else {
        const addon = b.addLibrary(.{ .name = "hello", .linkage = .dynamic, .root_module = mod });
        // Équivalent portable de `-undefined dynamic_lookup` (macOS) : on laisse les
        // symboles N-API indéfinis pour que Node les résolve au chargement.
        addon.linker_allow_shlib_undefined = true;
        const install = b.addInstallFileWithDir(addon.getEmittedBin(), .lib, "hello.node");
        b.getInstallStep().dependOn(&install.step);
    }
}
