const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sockets = b.addTranslateC(.{
        .root_source_file = b.path("sockets.h"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "lifx-control",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addImport("sockets", sockets.createModule());
    b.installArtifact(exe);
    if (target.result.os.tag == .macos) {
        const mic = b.addSystemCommand(&.{ "xcrun", "swiftc", "-O", "-module-cache-path", "/tmp/lifx-swift-module-cache" });
        mic.addFileArg(b.path("microphone.swift"));
        mic.addArgs(&.{ "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker" });
        mic.addFileArg(b.path("MicrophoneInfo.plist"));
        mic.addArg("-o");
        const helper = mic.addOutputFileArg("lifx-microphone");
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(helper, .bin, "lifx-microphone").step);
    }
}
