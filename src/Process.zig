const std = @import("std");
const xev = @import("xev");
const Process = @This();
const log = std.log.scoped(.process);

pub const State = enum {
    initialized,
    running,
    finished,
};

state: State = .initialized,
stdout_completion: xev.Completion = undefined,
out_buf: [256]u8 = undefined,
out_len: usize = 0,
stderr_completion: xev.Completion = undefined,
err_buf: [256]u8 = undefined,
err_len: usize = 0,
child: std.process.Child,

pub fn create(allocator: std.mem.Allocator, args: []const []const u8) !Process {
    var p = try allocator.create(Process);
    p.* = .{
        .child = try std.process.spawn(args),
    };
    p.child.expand_arg0 = .expand;
    p.child.stdin_behavior = .Pipe;
    p.child.stdout_behavior = .Pipe;
    p.child.stderr_behavior = .Pipe;
    return p;
}

pub fn init(self: *Process, allocator: std.mem.Allocator, args: []const []const u8) void {
    self.child = std.process.Child.init(args, allocator);
    self.child.expand_arg0 = .expand;
    self.child.stdin_behavior = .Pipe;
    self.child.stdout_behavior = .Pipe;
    self.child.stderr_behavior = .Pipe;
    self.state = .initialized;
}

pub fn finish(self: *Process) void {
    self.state = .finished;
    return;
}

pub fn run(self: *Process, loop: *xev.Loop) !void {
    try self.child.spawn();
    self.state = .running;

    const out = self.child.stdout orelse unreachable;
    const err = self.child.stderr orelse unreachable;
    var out_file = try xev.File.init(out);
    var err_file = try xev.File.init(err);
    out_file.read(loop, &self.stdout_completion, .{ .slice = &self.out_buf }, Process, self, readCallback);
    err_file.read(loop, &self.stderr_completion, .{ .slice = &self.err_buf }, Process, self, readCallback);
}

const Stream = enum {
    stdout,
    stderr,
};

fn whichStream(self: *Process, file: xev.File) Stream {
    if (file.fd == self.child.stdout.?.handle) {
        return .stdout;
    } else if (file.fd == self.child.stderr.?.handle) {
        return .stderr;
    } else {
        unreachable;
    }
}

fn readCallback(
    ud: ?*Process,
    _: *xev.Loop,
    _: *xev.Completion,
    file: xev.File,
    _: xev.ReadBuffer,
    r: xev.File.ReadError!usize,
) xev.CallbackAction {
    const process = ud orelse unreachable;
    var action: xev.CallbackAction = .rearm;
    if (process.state == .finished) {
        action = .disarm;
    }
    const stream = process.whichStream(file);
    const read = r catch |err| {
        log.err("Error reading file for stream {s}: {any}", .{ @tagName(stream), err });
        if (process.state != .finished and err == error.EOF) {
            return .rearm;
        } else {
            return .disarm;
        }
    };
    const buf = switch (stream) {
        .stdout => process.out_buf,
        .stderr => process.err_buf,
    };
    log.info("Current data ingested from {s}: {s}", .{ @tagName(stream), buf[0..read] });
    return action;
}
