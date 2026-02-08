const std = @import("std");

const sqlite_flags = .{
    "-DSQLITE_DQS=0",
    "-DSQLITE_THREADSAFE=2",
    "-DSQLITE_DEFAULT_MEMSTATUS=0",
    "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
    "-DSQLITE_LIKE_DOESNT_MATCH_BLOBS",
    "-DSQLITE_OMIT_DEPRECATED",
    "-DSQLITE_OMIT_PROGRESS_CALLBACK",
    "-DSQLITE_OMIT_SHARED_CACHE",
    "-DSQLITE_USE_ALLOCA",
    "-DSQLITE_ENABLE_FTS5",
    "-DSQLITE_ENABLE_JSON1",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zqlite", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Bundle SQLite amalgamation into the module so consumers get it
    // transitively via zig fetch --save without any extra linking
    mod.addIncludePath(b.path("vendor"));
    mod.addCSourceFile(.{
        .file = b.path("vendor/sqlite3.c"),
        .flags = &sqlite_flags,
    });
    mod.link_libc = true;

    // Demo executable
    const exe = b.addExecutable(.{
        .name = "zqlite",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zqlite", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    // Run step
    const run_step = b.step("run", "Run the demo");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_step.dependOn(&run_cmd.step);

    // Tests
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
