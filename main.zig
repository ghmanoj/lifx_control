const std = @import("std");
const c = @import("sockets");

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

fn control(ip: [:0]const u8, setting: ?f64) !void {
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
        std.debug.print("Usage: lifx-control <IPv4 address> <brightness 0-100|get>\nExample: lifx-control 192.168.1.50 50\nQuery: lifx-control 192.168.1.50 get\n0 turns off; positive values set brightness and turn on.\n", .{});
        return;
    }
    if (args.len != 3) {
        std.debug.print("Usage: lifx-control <IPv4 address> <brightness 0-100|get>\n", .{});
        std.process.exit(2);
    }
    if (std.mem.eql(u8, args[2], "get")) {
        control(args[1], null) catch |err| {
            std.debug.print("Failed: {s}. Check the IP, bulb power, and local network access.\n", .{@errorName(err)});
            std.process.exit(1);
        };
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
    control(args[1], percent) catch |err| {
        std.debug.print("Failed: {s}. Check the IP, bulb power, and local network access.\n", .{@errorName(err)});
        std.process.exit(1);
    };
    std.debug.print("Bulb {s} acknowledged brightness {d}%.\n", .{ args[1], percent });
}
