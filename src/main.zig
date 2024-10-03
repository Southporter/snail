const std = @import("std");
const vaxis = @import("vaxis");
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

    // Initialize our application
    var app = try App.init(allocator);
    defer app.deinit();

    // Run the application
    try app.run();
}

test "Snail tests" {
    _ = @import("Parser.zig");
}
