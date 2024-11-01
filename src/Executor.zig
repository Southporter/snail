const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const Executor = @This();
const xev = @import("xev");
const vaxis = @import("vaxis");

const log = std.log.scoped(.executor);

const Pty = @import("pty.zig").Pty;
const ttyWatcher = @import("TtyWatcher.zig");

pid: ?posix.pid_t = null,
pty: Pty,
watcher: ?ttyWatcher.TtyWatcher(Executor),
manager_file: xev.File = undefined,
read_buf: [256]u8 = undefined,
read_cmp: xev.Completion = .{},

pub fn start(self: *Executor, alloc: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    // TODO add windows support?
    return self.startPosix(arena.allocator());
}

fn startPosix(self: *Executor, alloc: std.mem.Allocator) !void {
    const pid: posix.pid_t = try posix.fork();

    if (pid != 0) {
        // Parent, return
        self.pid = pid;
        return;
    }

    // Set up pty as in and out
    setupFd(self.pty.worker, posix.STDIN_FILENO) catch {
        return error.FailedToSetStdIn;
    };
    setupFd(self.pty.worker, posix.STDOUT_FILENO) catch {
        return error.FailedToSetStdOut;
    };
    setupFd(self.pty.worker, posix.STDERR_FILENO) catch {
        return error.FailedToSetStdErr;
    };
    defer {
        posix.close(self.pty.manager);
        posix.close(self.pty.worker);
    }

    return self.run(alloc);
}

fn run(_: *Executor, _: std.mem.Allocator) !void {
    const input = std.io.getStdIn().reader();

    var buf: [256]u8 = undefined;
    const b = try input.read(&buf);

    const output = std.io.getStdOut().writer();

    _ = try output.write(buf[0..b]);
}

fn setupFd(src: posix.fd_t, target: i32) !void {
    try posix.dup2(src, target);
}

pub fn watch(self: *Executor, loop: *xev.Loop) !void {
    self.manager_file = xev.File.initFd(self.pty.manager);
    self.manager_file.read(loop, &self.read_cmp, .{ .slice = &self.read_buf }, Executor, self, readCallback);
}

pub fn send(self: *Executor, bytes: []const u8) !void {
    _ = try std.posix.write(self.pty.manager, bytes);
}

fn eventCallback(
    ud: ?*Executor,
    _: *xev.Loop,
    _: *vaxis.xev.TtyWatcher(Executor),
    event: vaxis.xev.Event,
) xev.CallbackAction {
    _ = ud orelse unreachable;
    switch (event) {
        .raw => |raw| {
            log.debug("Got bytes from worker: {s}", .{std.fmt.fmtSliceHexLower(raw)});
        },
        else => {
            log.debug("Got an unexpected response from the worker side: {any}", .{event});
        },
    }
    return .rearm;
}

fn readCallback(
    ud: ?*Executor,
    loop: *xev.Loop,
    c: *xev.Completion,
    f: xev.File,
    buf: xev.ReadBuffer,
    r: xev.ReadError!usize,
) xev.CallbackAction {
    const n = r catch |err| {
        log.err("Read error: {}", .{err});
        return .disarm;
    };

    const self = ud orelse unreachable;

    const data = buf.slice[0..n];
    log.info("Got data from worker: {s}", .{std.fmt.fmtSliceHexUpper(data)});

    f.read(
        loop,
        c,
        .{ .slice = &self.read_buf },
        Executor,
        self,
        readCallback,
    );
    return .disarm;
}
