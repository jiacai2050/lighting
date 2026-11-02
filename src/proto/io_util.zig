const std = @import("std");

/// High performance, direct socket read helper bypassing buggy std.Io.net.Stream.read destructuring
pub fn readSocket(stream: std.Io.net.Stream, io: std.Io, buffer: []u8) !usize {
    return readSocketTimeout(stream, io, buffer, null);
}

/// Reads from socket with an optional timeout in nanoseconds.
pub fn readSocketTimeout(stream: std.Io.net.Stream, io: std.Io, buffer: []u8, timeout_ns: ?u64) !usize {
    const timeout: std.Io.Timeout = if (timeout_ns) |ns|
        .{ .duration = .{ .raw = .{ .nanoseconds = @intCast(ns) }, .clock = .boot } }
    else
        .none;
    return readSocketWithTimeout(stream, io, buffer, timeout);
}

/// Reads from socket with an explicit std.Io.Timeout (supports both .duration and .deadline)
pub fn readSocketWithTimeout(stream: std.Io.net.Stream, io: std.Io, buffer: []u8, timeout: std.Io.Timeout) !usize {
    var data = [1][]u8{buffer};
    const op = std.Io.Operation{
        .net_read = .{
            .socket_handle = stream.socket.handle,
            .data = &data,
        },
    };

    if (timeout == .none) {
        const res = try (try io.operate(op)).net_read;
        return res.data_len;
    } else {
        const res = try io.operateTimeout(op, timeout);
        const read_res = try res.net_read;
        return read_res.data_len;
    }
}

/// High performance, vectored socket write helper
pub fn writeSocket(stream: std.Io.net.Stream, io: std.Io, vecs: []const []const u8) !usize {
    return writeSocketTimeout(stream, io, vecs, null);
}

/// Writes vectored buffers to socket with an optional timeout in nanoseconds.
pub fn writeSocketTimeout(stream: std.Io.net.Stream, io: std.Io, vecs: []const []const u8, timeout_ns: ?u64) !usize {
    const op = std.Io.Operation{
        .net_write = .{
            .socket_handle = stream.socket.handle,
            .data = vecs,
        },
    };

    if (timeout_ns) |ns| {
        const timeout = std.Io.Timeout{
            .duration = .{
                .raw = .{ .nanoseconds = @intCast(ns) },
                .clock = .boot,
            },
        };
        const res = try io.operateTimeout(op, timeout);
        return try res.net_write;
    } else {
        return try (try io.operate(op)).net_write;
    }
}

/// Writes all vectored buffers to the socket until exhausted
pub fn writeSocketAll(stream: std.Io.net.Stream, io: std.Io, vecs: []const []const u8) !void {
    return writeSocketAllTimeout(stream, io, vecs, null);
}

/// Writes all vectored buffers to the socket until exhausted, with optional timeout.
pub fn writeSocketAllTimeout(stream: std.Io.net.Stream, io: std.Io, vecs: []const []const u8, timeout_ns: ?u64) !void {
    var remaining_vecs = vecs;
    while (remaining_vecs.len > 0) {
        if (remaining_vecs[0].len == 0) {
            remaining_vecs = remaining_vecs[1..];
            continue;
        }
        var written = try writeSocketTimeout(stream, io, remaining_vecs, timeout_ns);
        if (written == 0) return error.ConnectionClosed;
        while (remaining_vecs.len > 0 and written >= remaining_vecs[0].len) {
            written -= remaining_vecs[0].len;
            remaining_vecs = remaining_vecs[1..];
        }
        if (remaining_vecs.len > 0 and written > 0) {
            var mutable_first = remaining_vecs[0][written..];
            while (mutable_first.len > 0) {
                const sub_vecs = [1][]const u8{mutable_first};
                const n = try writeSocketTimeout(stream, io, &sub_vecs, timeout_ns);
                if (n == 0) return error.ConnectionClosed;
                mutable_first = mutable_first[n..];
            }
            remaining_vecs = remaining_vecs[1..];
        }
    }
}
