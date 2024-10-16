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
out_buf: [256]u8 = undefined,
out_offset: usize = 0,
err_buf: [256]u8 = undefined,
err_offset: usize = 0,
child: std.process.Child,
stdout: vaxis.widgets.TextView.Buffer = .{},
stderr: vaxis.widgets.TextView.Buffer = .{},
scroll: vaxis.widgets.ScrollView.Scroll = .{},
gd: grapheme.GraphemeData = undefined,
wd: WidthData = undefined,

pub fn create(allocator: std.mem.Allocator, args: []const []const u8) !*Process {
    var p = try allocator.create(Process);
    p.* = .{
        .child = std.process.Child.init(args, allocator),
        .state = .initialized,
        .gd = try grapheme.GraphemeData.init(allocator),
        .wd = try WidthData.init(allocator),
    };
    p.child.expand_arg0 = .expand;
    p.child.stdin_behavior = .Pipe;
    p.child.stdout_behavior = .Pipe;
    p.child.stderr_behavior = .Pipe;
    return p;
}

pub fn destroy(self: *Process, allocator: std.mem.Allocator) void {
    self.stderr.deinit(allocator);
    self.stdout.deinit(allocator);
    self.gd.deinit();
    self.wd.deinit();
    allocator.destroy(self);
}

pub fn finish(self: *Process) void {
    self.state = .finished;
    return;
}

pub fn run(self: *Process, allocator: std.mem.Allocator) !void {
    log.debug("Spawning process", .{});
    self.child.spawn() catch |err| {
        log.err("Error running process: {any}", .{err});
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Error: {any}", .{err}) catch "Error: Unknown";
        return self.writeErr(allocator, msg);
    };
    log.debug("Process is now Running", .{});
    self.state = .running;
}

fn writeErr(self: *Process, allocator: std.mem.Allocator, err: []const u8) !void {
    return self.stderr.append(allocator, .{
        .bytes = err,
        .gd = &self.gd,
        .wd = &self.wd,
    });
}

pub fn collectOutput(self: *Process, allocator: std.mem.Allocator) !bool {
    var got_output = false;
    if (self.child.stdout) |out| {
        const read = try out.read(&self.out_buf);
        if (read > 0) {
            got_output = true;
            log.debug("Got stdout: {s}", .{self.out_buf[0..read]});
            try self.stdout.append(allocator, .{
                .bytes = self.out_buf[0..read],
                .gd = &self.gd,
                .wd = &self.wd,
            });
        }
    }
    if (self.child.stderr) |err| {
        const read = try err.read(&self.err_buf);
        if (read > 0) {
            log.debug("Got stderr: {s}", .{self.err_buf[0..read]});
            try self.stderr.append(allocator, .{
                .bytes = self.err_buf[0..read],
                .gd = &self.gd,
                .wd = &self.wd,
            });
            got_output = true;
        }
    }
    return got_output;
}

pub fn updateStatus(self: *Process) !bool {
    if (self.state != .running) {
        return false;
    }

    const res = std.posix.waitpid(self.child.id, std.c.W.NOHANG);

    log.debug("Res from waitpid: {any}", .{res});
    if (std.c.W.IFEXITED(res.status)) {
        self.state = .finished;
        log.debug("Child finised with {d}", .{std.c.W.EXITSTATUS(res.status)});
        return true;
    }
    return false;
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
    const err_win = win.child(.{
        .x_off = half,
    });
    var err_view = vaxis.widgets.TextView{
        .scroll_view = .{
            .scroll = self.scroll,
        },
    };
    err_view.draw(err_win, self.stderr);
}

pub fn updateScroll(self: *Process, direction: enum { up, down }) void {
    switch (direction) {
        .up => self.scroll.y = 5,
        .down => self.scroll.y += 5,
    }
}
