const std = @import("std");
const vaxis = @import("vaxis");
const xev = @import("xev");
const App = @import("App.zig");

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
        .app, std.log.default_log_scope => @tagName(scope),
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

    var tty = try vaxis.Tty.init();
    defer tty.deinit();

    var vx = try vaxis.init(allocator, .{
        .kitty_keyboard_flags = .{ .report_events = true },
    });
    defer vx.deinit(allocator, tty.anyWriter());

    var pool = xev.ThreadPool.init(.{});
    var loop = try xev.Loop.init(.{
        .thread_pool = &pool,
    });
    defer loop.deinit();

    // Initialize our application
    var app = try App.init(allocator, &vx, tty.bufferedWriter(), &loop);
    defer app.deinit();

    var vx_loop: vaxis.xev.TtyWatcher(App) = undefined;
    try vx_loop.init(&tty, &vx, &loop, &app, App.update);

    try vx.enterAltScreen(tty.anyWriter());
    errdefer vx.exitAltScreen(tty.anyWriter()) catch @panic("Failed to exit alt screen");
    // send queries asynchronously
    try vx.queryTerminalSend(tty.anyWriter());
    // Enable mouse events
    // try vx.setMouseMode(tty.anyWriter(), true);

    const timer = try xev.Timer.init();
    var timer_cmp: xev.Completion = .{};
    timer.run(&loop, &timer_cmp, App.next_ms, App, &app, App.tick);

    try loop.run(.until_done);
}

test "Snail tests" {
    _ = @import("Parser.zig");
}
