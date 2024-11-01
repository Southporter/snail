const std = @import("std");
const vaxis = @import("vaxis");
const xev = @import("xev");
const App = @import("App.zig");
const Pty = @import("pty.zig").Pty;
const watch = @import("TtyWatcher.zig");
const Executor = @import("Executor.zig");

const log = std.log.scoped(.main);

pub const panix = vaxis.panix_handler;

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .vaxis, .level = .warn },
        .{ .scope = .vaxis_parser, .level = .warn },
    },
    .logFn = fileLogger,
};

var log_file: std.fs.File = undefined;

pub fn fileLogger(
    comptime level: std.log.Level,
    comptime scope: @Type(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const scope_prefix = "(" ++ switch (scope) {
        .main, .app, .process, std.log.default_log_scope, .pty, .executor => @tagName(scope),
        else => if (@intFromEnum(level) <= @intFromEnum(std.log.Level.err))
            @tagName(scope)
        else
            return,
    } ++ "): ";

    const prefix = "[" ++ comptime level.asText() ++ "] " ++ scope_prefix;

    const writer = log_file.writer();
    nosuspend writer.print(prefix ++ format ++ "\n", args) catch return;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        //fail test; can't try in defer as defer is executed after we return
        if (deinit_status == .leak) {
            std.log.err("memory leak", .{});
        }
    }
    const allocator = gpa.allocator();

    log_file = try std.fs.cwd().createFile("log.txt", .{
        .truncate = true,
    });

    try runSimple(allocator);
    // try runApplication(allocator);
}

fn runApplication(allocator: std.mem.Allocator) !void {
    var app = try App.init(allocator);
    defer app.deinit();

    return app.run();
}

const next_ms: u64 = 8;

fn runSimple(allocator: std.mem.Allocator) !void {
    var pool = xev.ThreadPool.init(.{});
    var loop = try xev.Loop.init(.{
        .thread_pool = &pool,
    });
    defer loop.deinit();

    var shell = Shell{
        .allocator = allocator,
        .tty = try vaxis.Tty.init(),
        .executor = undefined,
        .vx = try vaxis.init(allocator, .{}),
        .loop = &loop,
    };
    defer shell.deinit();

    try shell.run();
}

const Shell = struct {
    allocator: std.mem.Allocator,
    executor: Executor,
    tty: vaxis.Tty,
    vx: vaxis.Vaxis,
    loop: *xev.Loop,

    mode: Mode = .passthrough,

    pub const Mode = enum {
        passthrough,
        command,
    };

    fn deinit(self: *Shell) void {
        self.executor.pty.deinit();
        self.tty.deinit();
        self.vx.deinit(self.allocator, self.tty.anyWriter());
    }

    fn run(self: *Shell) !void {
        const timer = try xev.Timer.init();
        var timer_cmp: xev.Completion = .{};
        timer.run(self.loop, &timer_cmp, next_ms, Shell, self, timerCallback);

        var watcher: watch.TtyWatcher(Shell) = undefined;
        try watcher.init(&self.tty, &self.vx, self.loop, self, eventCallback);

        const winsize = try vaxis.Tty.getWinsize(self.tty.fd);
        self.executor.pty = try Pty.open(.{
            .row = @truncate(winsize.rows),
            .col = @truncate(winsize.cols),
            .xpixel = @truncate(winsize.x_pixel),
            .ypixel = @truncate(winsize.y_pixel),
        });
        try self.executor.start(self.allocator);
        try self.executor.watch(self.loop);
        try self.executor.send("ping");

        try self.loop.run(.until_done);
    }
};

fn eventCallback(
    ud: ?*Shell,
    loop: *xev.Loop,
    watcher: *watch.TtyWatcher(Shell),
    event: watch.Event,
) xev.CallbackAction {
    const shell = ud orelse unreachable;
    switch (event) {
        .key_press => |key| {
            if (key.matches('c', .{ .ctrl = true })) {
                loop.stop();
                return .disarm;
            }
        },
        .winsize => |ws| {
            watcher.vx.resize(shell.allocator, watcher.tty.anyWriter(), ws) catch @panic("TODO");
            shell.executor.pty.setSize(.{
                .row = @truncate(ws.rows),
                .col = @truncate(ws.cols),
                .xpixel = @truncate(ws.x_pixel),
                .ypixel = @truncate(ws.y_pixel),
            }) catch @panic("TODO");
        },
        .raw => |raw| {
            if (shell.mode == .passthrough) {
                shell.executor.send(raw) catch @panic("Unable to send to worker");
            }
        },
        else => {},
    }
    return .rearm;
}

fn timerCallback(
    ud: ?*Shell,
    l: *xev.Loop,
    c: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch @panic("timer error");

    _ = ud orelse return .disarm;
    // _ = shell.tty.write(" |tick| ") catch @panic("could not write a tick");
    log.debug(" |tick| ", .{});

    const timer = try xev.Timer.init();
    timer.run(l, c, next_ms, Shell, ud, timerCallback);

    return .disarm;
}

test "Snail tests" {
    _ = @import("Parser.zig");
}
