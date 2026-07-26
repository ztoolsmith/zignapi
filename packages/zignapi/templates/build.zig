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

    const zignapi_dep = b.dependency("zignapi", .{});
    const zignapi = zignapi_dep.module("zignapi");

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
        linkNapiOnWindows(b, addon, target, zignapi_dep);
        const install = b.addInstallFileWithDir(addon.getEmittedBin(), .lib, "__NAME__.node");
        b.getInstallStep().dependOn(&install.step);
    }
}

/// Windows: resolve the N-API symbols against the running node.exe. A Windows
/// DLL can't leave symbols undefined (unlike ELF/Mach-O), so generate an import
/// library from zignapi's vendored `node_api.def` (whose `LIBRARY node.exe` binds
/// the imports to the host) with `zig lib /def:`, and link the addon against it.
/// No-op off Windows.
fn linkNapiOnWindows(
    b: *std.Build,
    addon: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    zignapi_dep: *std.Build.Dependency,
) void {
    if (target.result.os.tag != .windows) return;
    const gen = b.addSystemCommand(&.{ b.graph.zig_exe, "lib", "-nologo" });
    gen.addPrefixedFileArg("/def:", zignapi_dep.namedLazyPath("node_api_def"));
    const implib = gen.addPrefixedOutputFileArg("/out:", "node_api.lib");
    gen.addArg(if (target.result.cpu.arch == .aarch64) "/machine:arm64" else "/machine:x64");
    addon.root_module.addObjectFile(implib);
}
