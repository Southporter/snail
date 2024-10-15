const std = @import("std");
const App = @This();

const log = std.log.scoped(.app);

const xev = @import("xev");
const vaxis = @import("vaxis");
const TextInput = vaxis.widgets.TextInput;

const git = @import("git.zig");
const Parser = @import("Parser.zig");
const Process = @import("Process.zig");

pub const next_ms: u64 = 8;
allocator: std.mem.Allocator,
/// The buffered writer for the tty
buffered_writer: std.io.BufferedWriter(4096, std.io.AnyWriter),
/// The vaxis instance
vx: *vaxis.Vaxis,
/// A mouse event that we will handle in the draw cycle
mouse: ?vaxis.Mouse,
/// The event loop for the application
loop: *xev.Loop,

shell_input: TextInput,
git_info: git.GitInfo,

cwd: std.fs.Dir,
current_process: struct {
    process: Process,
    completion: xev.Completion,
    waiter: xev.Process,
},

pub fn init(allocator: std.mem.Allocator, vx: *vaxis.Vaxis, writer: std.io.BufferedWriter(4096, std.io.AnyWriter), loop: *xev.Loop) !App {
    return .{
        .allocator = allocator,
        .vx = vx,
        .buffered_writer = writer,
        .loop = loop,
        .mouse = null,
        .shell_input = TextInput.init(allocator, &vx.unicode),
        .cwd = std.fs.cwd(),
        .git_info = .{},
        .current_process = undefined,
    };
}

pub fn deinit(self: *App) void {
    self.shell_input.deinit();
    if (self.git_info.ref.len > 0) {
        self.allocator.free(self.git_info.ref);
    }
}

// pub fn run(self: *App) !void {
//     self.git_info = git.getGitInfo(self.allocator, std.fs.cwd()) catch .{
//         .ref = "",
//     };
//     // Initialize our event loop. This particular loop requires intrusive init
//     var loop: vaxis.Loop(Event) = .{
//         .tty = &self.tty,
//         .vaxis = &self.vx,
//     };
//     try loop.init();

//     // Start the event loop. Events will now be queued
//     try loop.start();

//     try self.vx.enterAltScreen(self.tty.anyWriter());

//     // Query the terminal to detect advanced features, such as kitty keyboard protocol, etc.
//     // This will automatically enable the features in the screen you are in, so you will want to
//     // call it after entering the alt screen if you are a full screen application. The second
//     // arg is a timeout for the terminal to send responses. Typically the response will be very
//     // fast, however it could be slow on ssh connections.
//     try self.vx.queryTerminal(self.tty.anyWriter(), 1 * std.time.ns_per_s);

//     // Enable mouse events
//     try self.vx.setMouseMode(self.tty.anyWriter(), true);

//     // This is the main event loop. The basic structure is
//     // 1. Handle events
//     // 2. Draw application
//     // 3. Render
//     while (!self.should_quit) {
//         // pollEvent blocks until we have an event
//         loop.pollEvent();
//         // tryEvent returns events until the queue is empty
//         while (loop.tryEvent()) |event| {
//             try self.update(event);
//         }
//         // Draw our application after handling events
//         self.draw();

//         // It's best to use a buffered writer for the render method. TTY provides one, but you
//         // may use your own. The provided bufferedWriter has a buffer size of 4096
//         var buffered = self.tty.bufferedWriter();
//         // Render the application to the screen
//         try self.vx.render(buffered.writer().any());
//         try buffered.flush();
//     }
// }

/// Update our application state from an event
pub fn update(userdata: ?*App, loop: *xev.Loop, watcher: *vaxis.xev.TtyWatcher(App), event: vaxis.xev.Event) xev.CallbackAction {
    var app = userdata orelse unreachable;
    log.info("Processing event: {any}", .{event});
    switch (event) {
        .key_press => |key| {
            // key.matches does some basic matching algorithms. Key matching can be complex in
            // the presence of kitty keyboard encodings, this will generally be a good approach.
            // There are other matching functions available for specific purposes, as well
            if (key.matches('c', .{ .ctrl = true }) or key.matches('d', .{ .ctrl = true })) {
                loop.stop();
                return .disarm;
            } else if (key.matches(vaxis.Key.enter, .{})) {
                const input = app.shell_input.toOwnedSlice() catch |err| {
                    log.err("Error copying shell input: {any}", .{err});
                    return .disarm;
                };
                app.exec(input) catch |err| {
                    log.err("Error executing command: {any}", .{err});
                    return .disarm;
                };
            } else {
                app.shell_input.update(.{ .key_press = key }) catch |err| {
                    log.err("Error updating shell input: {any}", .{err});
                    return .disarm;
                };
            }
        },
        .mouse => |mouse| app.mouse = mouse,
        .winsize => |ws| watcher.vx.resize(app.allocator, watcher.tty.anyWriter(), ws) catch @panic("Unable to resize in xev update"),
        else => {},
    }
    return .rearm;
}

pub fn tick(
    userdata: ?*App,
    loop: *xev.Loop,
    completion: *xev.Completion,
    runtime_err: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = runtime_err catch |err| {
        log.err("timer error: {}", .{err});
    };

    var app = userdata orelse return .disarm;
    app.draw() catch |err| {
        log.err("Error drawing: {any}", .{err});
        return .disarm;
    };

    const timer = try xev.Timer.init();
    timer.run(loop, completion, next_ms, App, userdata, tick);

    return .disarm;
}

/// Draw our current state
pub fn draw(self: *App) !void {
    // Window is a bounded area with a view to the screen. You cannot draw outside of a windows
    // bounds. They are light structures, not intended to be stored.
    const win = self.vx.window();

    // Clearing the window has the effect of setting each cell to it's "default" state. Vaxis
    // applications typically will be immediate mode, and you will redraw your entire
    // application during the draw cycle.
    win.clear();

    const window_mode: enum { compact, relaxed } = if (win.screen.width < 80) .compact else .relaxed;
    _ = window_mode;

    // In addition to clearing our window, we want to clear the mouse shape state since we may
    // be changing that as well
    self.vx.setMouseShape(.default);

    const child = win.child(.{
        .x_off = 1,
        .y_off = 1,
        .height = .{
            .limit = 2,
        },
        .border = .{
            .where = .{ .other = .{
                .bottom = true,
                .left = true,
                .right = true,
            } },
        },
    });

    // mouse events are much easier to handle in the draw cycle. Windows have a helper method to
    // determine if the event occurred in the target window. This method returns null if there
    // is no mouse event, or if it occurred outside of the window
    const style: vaxis.Style = if (child.hasMouse(self.mouse)) |_| blk: {
        // We handled the mouse event, so set it to null
        self.mouse = null;
        self.vx.setMouseShape(.pointer);
        break :blk .{ .reverse = true };
    } else .{};
    _ = try child.printSegment(.{ .text = "$", .style = style }, .{});

    const input_child = win.child(.{
        .y_off = 1,
        .x_off = 3,
        .height = .{
            .limit = 2,
        },
        .width = .expand,
    });

    self.shell_input.draw(input_child);

    const info_header = win.child(.{ .height = .{
        .limit = 1,
    } });

    const dir_style = vaxis.Style{
        .fg = .{ .index = 3 },
    };

    var dir_name_buf: [256]u8 = undefined;
    const dir_name = self.cwd.realpath(".", &dir_name_buf) catch "invalid";

    _ = try info_header.printSegment(.{ .text = dir_name, .style = dir_style }, .{});

    const git_header = vaxis.widgets.alignment.center(info_header, self.git_info.ref.len, 1);
    const git_style = vaxis.Style{
        .fg = .{ .index = 2 },
    };
    _ = try git_header.printSegment(.{ .text = self.git_info.ref, .style = git_style }, .{});

    // It's best to use a buffered writer for the render method. TTY provides one, but you
    // may use your own. The provided bufferedWriter has a buffer size of 4096
    // Render the application to the screen
    try self.vx.render(self.buffered_writer.writer().any());
    try self.buffered_writer.flush();
}

fn exec(self: *App, input: []const u8) !void {
    defer self.allocator.free(input);

    log.info("Execing {s}", .{input});

    var iter = Parser.init(input);
    const first = iter.next();
    log.info("First token: {any} = {s}", .{ first, input[first.location.start..first.location.end] });
    switch (first.kind) {
        .path => {
            const path = input[first.location.start..first.location.end];
            if (self.isFile(path)) {
                // Run the file with the rest of the input

                return self.execFilePath(path, iter);
            } else {
                const new_dir = self.cwd.openDir(path, .{}) catch |err| {
                    log.err("Tried to open dir that was not a dir: {any}", .{err});
                    return;
                };
                new_dir.setAsCwd() catch |err| {
                    log.err("Failed to set `{s}` as current working directory: {any}", .{ path, err });
                    return;
                };
                self.cwd = new_dir;
            }
        },
        .identifier => {
            const name = input[first.location.start..first.location.end];
            return try self.execCommand(name, iter);
            // var path: ?[]const u8 = null;
            // defer if (path) |p| {
            //     self.allocator.free(p);
            // };
            // const path_env = try std.process.getEnvVarOwned(self.allocator, "PATH");
            // defer self.allocator.free(path_env);
            // var path_iter = std.mem.splitScalar(u8, path_env, ':');
            // while (path_iter.next()) |search_path| {
            //     log.debug("Searching in {s} for {s}", .{ search_path, name });
            //     // Create file path
            //     const dir = std.fs.openDirAbsolute(search_path, .{}) catch |err| {
            //         log.err("Could not open path dir for reading ({any}): {s} - ", .{ err, search_path });
            //         continue;
            //     };
            //     const stat = dir.statFile(name) catch |err| {
            //         log.err("Could not stat name in path for reading ({any}): {s} - {s}", .{ err, search_path, name });
            //         continue;
            //     };
            //     log.debug("Got stat: {any}", .{stat});
            //     switch (stat.kind) {
            //         .file, .sym_link => {
            //             path = try dir.realpathAlloc(self.allocator, name);
            //             break;
            //         },
            //         else => {
            //             log.info("Found a path that is not a file or symlink: {s}/{s} - {s}", .{ search_path, name, @tagName(stat.kind) });
            //         },
            //     }
            // }

            // // We have a command to run
            // if (path) |p| {
            //     return self.execFilePath(p, iter);
            // } else {
            //     log.info("Command path not found: {s} {s}", .{ name, path_env });
            // }
        },
        else => {
            log.err("Received unexpected token: {any}", .{first});
        },
    }
}

fn execFilePath(self: *App, file_path: []const u8, parser: Parser) !void {
    var iter = parser;
    var args = std.ArrayList([]const u8).init(self.allocator);
    defer args.deinit();
    try args.append(file_path);
    var next = iter.next();
    while (next.kind != .end_of_input) : (next = iter.next()) {
        try args.append(parser.source[next.location.start..next.location.end]);
    }

    log.info("Running {s}", .{args.items});
    var child = std.process.Child.init(args.items, self.allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    const res = child.spawnAndWait();
    log.info("Res from child: {any}", .{res});
}

fn execCommand(self: *App, command: []const u8, parser: Parser) !void {
    var iter = parser;
    var args = std.ArrayList([]const u8).init(self.allocator);
    defer args.deinit();
    try args.append(command);
    var next = iter.next();
    while (next.kind != .end_of_input) : (next = iter.next()) {
        try args.append(parser.source[next.location.start..next.location.end]);
    }

    log.info("Running {s}", .{args.items});

    self.current_process.process.init(self.allocator, args.items);
    try self.current_process.process.run(self.loop);
    self.current_process.waiter = try xev.Process.init(self.current_process.process.child.id);
    self.current_process.waiter.wait(self.loop, &self.current_process.completion, App, self, handleProcessCompletion);
}

fn handleProcessCompletion(userdata: ?*App, loop: *xev.Loop, c: *xev.Completion, result: xev.Process.WaitError!u32) xev.CallbackAction {
    var app = userdata orelse unreachable;
    _ = loop;
    _ = c;
    log.debug("Finised current process: {any}", .{result});
    app.current_process.process.finish();
    return .disarm;
}

fn isFile(self: *App, path: []const u8) bool {
    _ = self.cwd.statFile(path) catch |err| switch (err) {
        error.IsDir => return false,
        else => return true,
    };
    return true;
}
