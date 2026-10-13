const std = @import("std");
const c = @import("sockets");
const builtin = @import("builtin");
var stopping = std.atomic.Value(bool).init(false);

fn stopMusic(_: c_int) callconv(.c) void {
    stopping.store(true, .monotonic);
}

fn sendColor(fd: c_int, source: u32, target: [8]u8, hsbk: [8]u8, sequence: u8) !void {
    var packet: [49]u8 = undefined;
    header(&packet, 102, sequence, source, target, true);
    @memcpy(packet[37..45], &hsbk);
    std.mem.writeInt(u32, packet[45..49], 150, .little);
    var response: [512]u8 = undefined;
    _ = try exchange(fd, &packet, 45, &response);
}

fn sendPower(fd: c_int, source: u32, target: [8]u8, level: u16, sequence: u8) !void {
    var packet: [42]u8 = undefined;
    header(&packet, 117, sequence, source, target, true);
    put16(&packet, 36, level);
    var response: [512]u8 = undefined;
    _ = try exchange(fd, &packet, 45, &response);
}

fn musicLoop(fd: c_int, source: u32, target: [8]u8, initial: [8]u8, initial_power: u16, stdin_levels: bool) !void {
    if (builtin.os.tag != .macos and !stdin_levels) return error.MusicRequiresMacOS;
    stopping.store(false, .monotonic);
    const old_int = c.signal(c.SIGINT, stopMusic);
    const old_term = c.signal(c.SIGTERM, stopMusic);
    defer _ = c.signal(c.SIGINT, old_int);
    defer _ = c.signal(c.SIGTERM, old_term);

    var input_fd: c_int = c.STDIN_FILENO;
    var child: c.pid_t = 0;
    if (!stdin_levels) {
        if (builtin.os.tag == .macos) {
            var path: [4096]u8 = undefined;
            var size: u32 = path.len;
            if (c._NSGetExecutablePath(&path, &size) != 0) return error.ExecutablePathTooLong;
            const dir = std.fs.path.dirname(std.mem.sliceTo(&path, 0)) orelse return error.HelperPathMissing;
            var helper_buf: [4096]u8 = undefined;
            const suffix = "/lifx-microphone";
            const helper_len = dir.len + suffix.len;
            if (helper_len >= helper_buf.len) return error.ExecutablePathTooLong;
            @memcpy(helper_buf[0..dir.len], dir);
            @memcpy(helper_buf[dir.len..helper_len], suffix);
            helper_buf[helper_len] = 0;
            const helper = helper_buf[0..helper_len :0];
            var pipes: [2]c_int = undefined;
            if (c.pipe(&pipes) != 0) return error.PipeFailed;
            errdefer _ = c.close(pipes[0]);
            defer _ = c.close(pipes[1]);
            var actions: c.posix_spawn_file_actions_t = undefined;
            if (c.posix_spawn_file_actions_init(&actions) != 0) return error.SpawnFailed;
            defer _ = c.posix_spawn_file_actions_destroy(&actions);
            if (c.posix_spawn_file_actions_adddup2(&actions, pipes[1], c.STDOUT_FILENO) != 0 or
                c.posix_spawn_file_actions_addclose(&actions, pipes[0]) != 0 or
                c.posix_spawn_file_actions_addclose(&actions, pipes[1]) != 0 or
                c.posix_spawn_file_actions_addclose(&actions, fd) != 0) return error.SpawnFailed;
            var argv = [_:null]?[*:0]const u8{helper.ptr};
            if (c.posix_spawn(&child, helper.ptr, &actions, null, @ptrCast(&argv), c.environ) != 0) return error.MicrophoneHelperMissing;
            input_fd = pipes[0];
        }
    }
    // Restore even when the microphone exits or a network request fails.
    defer {
        if (child != 0) {
            _ = c.close(input_fd);
            _ = c.kill(child, c.SIGTERM);
            var status: c_int = 0;
            _ = c.waitpid(child, &status, 0);
        }
        sendColor(fd, source, target, initial, 254) catch |err| {
            std.debug.print("Could not restore brightness: {s}\n", .{@errorName(err)});
        };
        sendPower(fd, source, target, initial_power, 255) catch |err| {
            std.debug.print("Could not restore power: {s}\n", .{@errorName(err)});
        };
    }
    var sequence: u8 = 2;
    var powered = false;
    var last_brightness: ?u16 = null;
    var pending: ?u8 = null;
    std.debug.print("Music mode: listening to volume; press Ctrl+C to stop and restore the bulb.\n", .{});
    while (!stopping.load(.monotonic)) {
        var pfd = c.struct_pollfd{ .fd = input_fd, .events = c.POLLIN, .revents = 0 };
        const ready = c.poll(&pfd, 1, 100);
        if (stopping.load(.monotonic)) break;
        if (ready < 0) return error.AudioPollFailed;
        if (ready == 0) continue;
        var bytes: [256]u8 = undefined;
        const count = c.read(input_fd, &bytes, bytes.len);
        if (count < 0) return error.AudioReadFailed;
        if (count == 0) {
            if (stdin_levels and pending == null) break;
            return error.MicrophoneStopped;
        }
        var latest: ?u16 = null;
        for (bytes[0..@intCast(count)]) |byte| {
            if (pending) |low| {
                latest = @as(u16, low) | (@as(u16, byte) << 8);
                pending = null;
            } else pending = byte;
        }
        if (latest) |brightness| {
            if (last_brightness) |previous| {
                const difference = @abs(@as(i32, brightness) - @as(i32, previous));
                if (difference < 328) continue; // Ignore changes smaller than 0.5%.
            }
            var color = initial;
            put16(&color, 4, brightness);
            try sendColor(fd, source, target, color, sequence);
            last_brightness = brightness;
            sequence +%= 1;
            if (!powered) {
                try sendPower(fd, source, target, 65535, sequence);
                sequence +%= 1;
                powered = true;
            }
        }
    }
}

fn put16(bytes: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, .little);
}

fn get16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn header(bytes: []u8, kind: u16, sequence: u8, source: u32, target: [8]u8, ack: bool) void {
    @memset(bytes, 0);
    put16(bytes, 0, @intCast(bytes.len));
    put16(bytes, 2, 0x1400); // Protocol 1024, addressable, unicast.
    std.mem.writeInt(u32, bytes[4..8], source, .little);
    @memcpy(bytes[8..16], &target);
    bytes[22] = if (ack) 2 else 0;
    bytes[23] = sequence;
    put16(bytes, 32, kind);
}

fn exchange(fd: c_int, request: []const u8, expected: u16, response: *[512]u8) !usize {
    for (0..3) |_| {
        const sent = c.send(fd, request.ptr, request.len, 0);
        if (sent < 0 or sent != request.len) return error.SendFailed;
        // A fixed poll budget also bounds time spent discarding unrelated packets.
        for (0..10) |_| {
            var pollfd = c.struct_pollfd{ .fd = fd, .events = c.POLLIN, .revents = 0 };
            const ready = c.poll(&pollfd, 1, 100);
            if (ready < 0) return error.PollFailed;
            if (ready == 0) continue;
            const received = c.recv(fd, response, response.len, 0);
            if (received < 0) return error.ReceiveFailed;
            const n: usize = @intCast(received);
            if (n < 36 or get16(response, 0) != n) continue;
            if (get16(response, 2) & 0x1fff != 0x1400) continue;
            if (!std.mem.eql(u8, response[4..8], request[4..8])) continue;
            if (response[23] != request[23] or get16(response, 32) != expected) continue;
            if (!std.mem.allEqual(u8, request[8..16], 0) and
                !std.mem.eql(u8, response[8..16], request[8..16])) continue;
            return n;
        }
    }
    return error.BulbTimedOut;
}

fn control(ip: [:0]const u8, setting: ?f64, music: bool, stdin_levels: bool) !void {
    var address: c.struct_sockaddr_in = std.mem.zeroes(c.struct_sockaddr_in);
    address.sin_family = c.AF_INET;
    address.sin_port = c.htons(56700);
    if (@hasField(c.struct_sockaddr_in, "sin_len")) address.sin_len = @sizeOf(c.struct_sockaddr_in);
    if (c.inet_pton(c.AF_INET, ip.ptr, &address.sin_addr) != 1) return error.InvalidIPv4Address;
    if (address.sin_addr.s_addr == 0 or address.sin_addr.s_addr == 0xffffffff) return error.InvalidIPv4Address;
    const fd = c.socket(c.AF_INET, c.SOCK_DGRAM, 0);
    if (fd < 0) return error.SocketFailed;
    defer _ = c.close(fd);
    if (c.connect(fd, @ptrCast(&address), @sizeOf(c.struct_sockaddr_in)) != 0) return error.ConnectFailed;

    const source: u32 = @as(u32, @intCast(c.getpid())) | 0x80000000;
    var response: [512]u8 = undefined;
    var query: [36]u8 = undefined;
    header(&query, 101, 1, source, std.mem.zeroes([8]u8), false);
    const n = try exchange(fd, &query, 107, &response);
    if (n < 88) return error.InvalidLightState;
    var target: [8]u8 = undefined;
    @memcpy(&target, response[8..16]);
    if (std.mem.allEqual(u8, &target, 0)) return error.InvalidLightState;
    if (music) {
        var initial: [8]u8 = undefined;
        @memcpy(&initial, response[36..44]);
        return musicLoop(fd, source, target, initial, get16(&response, 46), stdin_levels);
    }

    const percent = setting orelse {
        const brightness = @as(f64, @floatFromInt(get16(&response, 40))) * 100.0 / 65535.0;
        const power: [*:0]const u8 = if (get16(&response, 46) == 0) "off" else "on";
        _ = c.printf("Brightness: %.2f%%\nPower: %s\n", brightness, power);
        return;
    };

    if (percent > 0) {
        var color: [49]u8 = undefined;
        header(&color, 102, 2, source, target, true);
        @memcpy(color[37..45], response[36..44]); // Preserve hue, saturation and kelvin.
        put16(&color, 41, @intFromFloat(@round(percent * 65535.0 / 100.0)));
        _ = try exchange(fd, &color, 45, &response);
    }
    var power: [42]u8 = undefined;
    header(&power, 117, 3, source, target, true);
    put16(&power, 36, if (percent == 0) 0 else 65535);
    _ = try exchange(fd, &power, 45, &response);
}

pub fn main(init: std.process.Init) void {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch {
        std.debug.print("Unable to read arguments.\n", .{});
        std.process.exit(1);
    };
    if (args.len == 2 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))) {
        std.debug.print("Usage: lifx-control <IPv4 address> <brightness 0-100|poweroff|get|music>\nSet brightness: lifx-control 192.168.1.50 50\nPower off: lifx-control 192.168.1.50 poweroff\nGet status: lifx-control 192.168.1.50 get\nMusic: lifx-control 192.168.1.50 music\n0 turns off; positive values set brightness and turn on.\n", .{});
        return;
    }
    if (args.len >= 3 and std.mem.eql(u8, args[2], "music")) {
        const stdin_levels = args.len == 4 and std.mem.eql(u8, args[3], "--levels-stdin");
        if (args.len != 3 and !stdin_levels) {
            std.debug.print("Usage: lifx-control <IPv4 address> music [--levels-stdin]\n", .{});
            std.process.exit(2);
        }
        control(args[1], null, true, stdin_levels) catch |err| {
            std.debug.print("Music mode failed: {s}.\n", .{@errorName(err)});
            std.process.exit(1);
        };
        return;
    }
    if (args.len != 3) {
        std.debug.print("Usage: lifx-control <IPv4 address> <brightness 0-100|poweroff|get|music>\n", .{});
        std.process.exit(2);
    }
    if (std.mem.eql(u8, args[2], "get")) {
        control(args[1], null, false, false) catch |err| {
            std.debug.print("Failed: {s}. Check the IP, bulb power, and local network access.\n", .{@errorName(err)});
            std.process.exit(1);
        };
        return;
    }
    if (std.mem.eql(u8, args[2], "poweroff")) {
        powerOff(args[1]) catch |err| {
            std.debug.print("Failed: {s}. Check the IP, bulb power, and local network access.\n", .{@errorName(err)});
            std.process.exit(1);
        };
        std.debug.print("Bulb {s} acknowledged power off.\n", .{args[1]});
        return;
    }
    const percent = std.fmt.parseFloat(f64, args[2]) catch {
        std.debug.print("Brightness must be a number from 0 to 100.\n", .{});
        std.process.exit(2);
    };
    if (!std.math.isFinite(percent) or percent < 0 or percent > 100) {
        std.debug.print("Brightness must be a number from 0 to 100.\n", .{});
        std.process.exit(2);
    }
    control(args[1], percent, false, false) catch |err| {
        std.debug.print("Failed: {s}. Check the IP, bulb power, and local network access.\n", .{@errorName(err)});
        std.process.exit(1);
    };
    std.debug.print("Bulb {s} acknowledged brightness {d}%.\n", .{ args[1], percent });
}

fn powerOff(ip: [:0]const u8) !void {
    // Zero selects only SetLightPower, leaving the stored brightness intact.
    try control(ip, 0, false, false);
}
