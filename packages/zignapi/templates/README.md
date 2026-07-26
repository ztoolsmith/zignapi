# __NAME__

A native Node.js addon written in [Zig](https://ziglang.org/) with
[zignapi](https://github.com/) — requires **Zig 0.16.0** and **Node >= 18**.

```sh
zignapi build      # compiles src/main.zig into __NAME__.node (and zig-out/lib/)
node --test        # runs test.js
```

Edit `src/main.zig` to add functions, then list them in the `zignapi.register`
call at the bottom of that file.

## The zignapi dependency

`zignapi new` added the `zignapi` Zig module to `build.zig.zon` with
`zig fetch --save`, which pins it by content hash:

```zig
.dependencies = .{
    .zignapi = .{ .url = "…", .hash = "zignapi-…" },
},
```

The `url` points at the zignapi sources on the machine where you scaffolded.
The content is cached globally by hash, so builds don't need that path again.
To share this project across machines/CI, re-point `url` at a hosted tarball
of the zignapi `native/` sources (the `hash` stays the same) with:

```sh
zig fetch --save=zignapi https://…/zignapi-native.tar.gz
```
