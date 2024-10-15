const std = @import("std");
const vaxis = @import("vaxis");
const grapheme = @import("grapheme");
const WidthData = @import("DisplayWidth").DisplayWidthData;
const Process = @This();
const log = std.log.scoped(.process);

pub const State = enum {
    initialized,
    running,
    finished,
};

state: State = .initialized,
out: std.ArrayListUnmanaged(u8) = .{},
out_buf: [256]u8 = undefined,
out_offset: usize = 0,
err: std.ArrayListUnmanaged(u8) = .{},
err_buf: [256]u8 = undefined,
err_offset: usize = 0,
child: std.process.Child,
stdout: vaxis.widgets.TextView.Buffer,
scroll: vaxis.widgets.ScrollView.Scroll = .{},

pub fn create(allocator: std.mem.Allocator, args: []const []const u8) !*Process {
    var p = try allocator.create(Process);
    p.* = .{
        .child = std.process.Child.init(args, allocator),
        .state = .initialized,
        .stdout = .{},
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

pub fn run(self: *Process) !void {
    try self.child.spawn();
    self.state = .running;
}

pub fn collectOutput(self: *Process, allocator: std.mem.Allocator) !void {
    const gd = try grapheme.GraphemeData.init(allocator);
    defer gd.deinit();
    const wd = try WidthData.init(allocator);
    if (self.child.stdout) |out| {
        const read = try out.read(&self.out_buf);
        try self.out.appendSlice(allocator, self.out_buf[0..read]);
        try self.stdout.append(allocator, .{
            .bytes = self.out_buf[0..read],
            .gd = &gd,
            .wd = &wd,
        });
    }
    if (self.child.stderr) |err| {
        const read = try err.read(&self.err_buf);
        try self.err.appendSlice(allocator, self.err_buf[0..read]);
    }
}

pub fn updateStatus(self: *Process) !void {
    if (self.state != .running) {
        return;
    }

    const res = std.posix.waitpid(self.child.id, std.c.W.NOHANG);

    log.debug("Res from waitpid: {any}", .{res});
    if (std.c.W.IFEXITED(res.status)) {
        self.state = .finished;
        log.debug("Child finised with {d}", .{std.c.W.EXITSTATUS(res.status)});
        return;
    }
}

pub fn updateInput(self: *Process, key: vaxis.Key) void {
    if (key.matches(vaxis.Key.right, .{})) {
        self.scroll.x +|= 1;
    } else if (key.matches(vaxis.Key.right, .{ .shift = true })) {
        self.scroll.x +|= 32;
    } else if (key.matches(vaxis.Key.left, .{})) {
        self.scroll.x -|= 1;
    } else if (key.matches(vaxis.Key.left, .{ .shift = true })) {
        self.scroll.x -|= 32;
    } else if (key.matches(vaxis.Key.up, .{})) {
        self.scroll.y -|= 1;
    } else if (key.matches(vaxis.Key.page_up, .{})) {
        self.scroll.y -|= 32;
    } else if (key.matches(vaxis.Key.down, .{})) {
        self.scroll.y +|= 1;
    } else if (key.matches(vaxis.Key.page_down, .{})) {
        self.scroll.y +|= 32;
    } else if (key.matches(vaxis.Key.end, .{})) {
        self.scroll.y = std.math.maxInt(usize);
    } else if (key.matches(vaxis.Key.home, .{})) {
        self.scroll.y = 0;
    }
}

pub fn draw(self: *Process, win: vaxis.Window) void {
    const half = win.width / 2;
    const out_win = win.child(.{
        .width = .{ .limit = half },
    });
    var out_view = vaxis.widgets.TextView{
        .scroll_view = .{
            .scroll = self.scroll,
        },
    };
    out_view.draw(out_win, self.stdout);
    // const err_win = win.child(.{
    //     .x_off = .{ .limit = half },
    // });
}

pub fn updateScroll(self: *Process, direction: enum { up, down }) void {
    switch (direction) {
        .up => self.scroll.y = 1,
        .down => self.scroll.y += 1,
    }
}
