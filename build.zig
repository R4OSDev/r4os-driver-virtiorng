const std = @import("std");
pub fn build(b: *std.Build) void {
    const sdk_build = b.lazyImport(@This(), "r4os_sdk") orelse return;
    const sdk_dep = b.dependencyFromBuildZig(sdk_build, .{});
    const sdk = sdk_build.sdk(b, sdk_dep, .{});
    _ = sdk.addR4MF(b.path("module.R4MF"));
    const host = sdk.createR4osModule(b.graph.host, .Debug);
    const fixture = b.createModule(.{ .root_source_file = b.path("src/queue_test.zig"), .target = b.graph.host, .optimize = .Debug });
    fixture.addImport("r4os", host);
    const tests = b.addRunArtifact(b.addTest(.{ .root_module = fixture }));
    b.step("test", "Actual queue policy: short/delayed/malformed completions, timeout and retained DMA").dependOn(&tests.step);
}
