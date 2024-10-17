const std = @import("std");
const App = @This();

const log = std.log.scoped(.app);

const vaxis = @import("vaxis");
const TextInput = vaxis.widgets.TextInput;

const git = @import("git.zig");
const Parser = @import("Parser.zig");
const Process = @import("Process.zig");

allocator: std.mem.Allocator,
// A flag for if we should quit
should_quit: bool,
/// The tty we are talking to
tty: vaxis.Tty,
/// The vaxis instance
vx: vaxis.Vaxis,
/// A mouse event that we will handle in the draw cycle
mouse: ?vaxis.Mouse,

shell_input: TextInput,
git_info: git.GitInfo,

cwd: std.fs.Dir,

current_process: ?*Process = null,
mode: enum { runner, basic } = .basic,

/// Tagged union of all events our application will handle. These can be generated by Vaxis or your
/// own custom events
const Event = union(enum) {
    key_press: vaxis.Key,
    key_release: vaxis.Key,
    mouse: vaxis.Mouse,
    focus_in, // window has gained focus
    focus_out, // window has lost focus
    paste_start, // bracketed paste start
    paste_end, // bracketed paste end
    paste: []const u8, // osc 52 paste, caller must free
    color_report: vaxis.Color.Report, // osc 4, 10, 11, 12 response
    color_scheme: vaxis.Color.Scheme, // light / dark OS theme changes
    winsize: vaxis.Winsize, // the window size has changed. This event is always sent when the loop is started
    process_update,
};

pub fn init(allocator: std.mem.Allocator) !App {
    const vx = try vaxis.init(allocator, .{
        .kitty_keyboard_flags = .{ .report_events = true },
    });
    return .{
        .allocator = allocator,
        .should_quit = false,
        .tty = try vaxis.Tty.init(),
        .vx = vx,
        .mouse = null,
        .shell_input = TextInput.init(allocator, &vx.unicode),
        .cwd = std.fs.cwd(),
        .git_info = .{},
    };
}

pub fn deinit(self: *App) void {
    // Deinit takes an optional allocator. You can choose to pass an allocator to clean up
    // memory, or pass null if your application is shutting down and let the OS clean up the
    // memory
    self.vx.deinit(self.allocator, self.tty.anyWriter());
    self.tty.deinit();
    self.shell_input.deinit();
    if (self.git_info.ref.len > 0) {
        self.allocator.free(self.git_info.ref);
    }
    if (self.current_process) |proc| {
        proc.destroy(self.allocator);
        self.current_process = null;
    }
}

pub fn run(self: *App) !void {
    self.git_info = git.getGitInfo(self.allocator, std.fs.cwd()) catch .{
        .ref = "",
    };
    // Initialize our event loop. This particular loop requires intrusive init
    var loop: vaxis.Loop(Event) = .{
        .tty = &self.tty,
        .vaxis = &self.vx,
    };
    try loop.init();

    // Start the event loop. Events will now be queued
    try loop.start();

    try self.vx.enterAltScreen(self.tty.anyWriter());
    defer self.vx.exitAltScreen(self.tty.anyWriter()) catch {};

    // Query the terminal to detect advanced features, such as kitty keyboard protocol, etc.
    // This will automatically enable the features in the screen you are in, so you will want to
    // call it after entering the alt screen if you are a full screen application. The second
    // arg is a timeout for the terminal to send responses. Typically the response will be very
    // fast, however it could be slow on ssh connections.
    try self.vx.queryTerminal(self.tty.anyWriter(), 1 * std.time.ns_per_s);

    // Enable mouse events
    try self.vx.setMouseMode(self.tty.anyWriter(), true);

    var scratch_buffer: [2048]u8 = undefined;

    // This is the main event loop. The basic structure is
    // 1. Handle events
    // 2. Draw application
    // 3. Render
    while (!self.should_quit) {
        if (self.current_process) |proc| {
            const output_update = try proc.collectOutput(self.allocator);
            const should_update = try proc.updateStatus();
            if (output_update or should_update) {
                loop.postEvent(.process_update);
            }
        }
        // pollEvent blocks until we have an event
        loop.pollEvent();
        // tryEvent returns events until the queue is empty
        while (loop.tryEvent()) |event| {
            try self.update(event);
        }
        // Draw our application after handling events
        self.draw(&scratch_buffer);

        // It's best to use a buffered writer for the render method. TTY provides one, but you
        // may use your own. The provided bufferedWriter has a buffer size of 4096
        var buffered = self.tty.bufferedWriter();
        // Render the application to the screen
        try self.vx.render(buffered.writer().any());
        try buffered.flush();
    }
}

/// Update our application state from an event
pub fn update(self: *App, event: Event) !void {
    switch (event) {
        .key_press => |key| {
            // key.matches does some basic matching algorithms. Key matching can be complex in
            // the presence of kitty keyboard encodings, this will generally be a good approach.
            // There are other matching functions available for specific purposes, as well
            if (key.matches('c', .{ .ctrl = true }) or key.matches('d', .{ .ctrl = true })) {
                self.should_quit = true;
                return;
            }
            if (key.matches('p', .{ .alt = true })) {
                self.mode = .runner;
                return;
            }
            if (key.matches(vaxis.Key.enter, .{})) {
                defer self.shell_input.clearRetainingCapacity();

                try self.exec(try self.shell_input.toOwnedSlice());
            } else {
                if (key.matches(vaxis.Key.tab, .{})) {
                    if (self.current_process) |proc| {
                        proc.updateInput(key);
                    }
                }
                try self.shell_input.update(.{ .key_press = key });
            }
        },
        .mouse => |mouse| self.mouse = mouse,
        .winsize => |ws| try self.vx.resize(self.allocator, self.tty.anyWriter(), ws),
        else => {},
    }
}

/// Draw our current state
pub fn draw(self: *App, scratch: []u8) void {
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
    _ = try child.printSegment(.{ .text = if (self.mode == .runner) ">> " else "$ ", .style = style }, .{});

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

    const dir_name = self.cwd.realpath(".", scratch) catch "invalid";

    _ = try info_header.printSegment(.{ .text = dir_name, .style = dir_style }, .{});

    const git_header = vaxis.widgets.alignment.center(info_header, self.git_info.ref.len, self.git_info.ref.len);
    const git_style = vaxis.Style{
        .fg = .{ .index = 2 },
    };
    _ = try git_header.printSegment(.{ .text = self.git_info.ref, .style = git_style }, .{});

    if (self.current_process) |proc| {
        if (self.mouse) |mouse| {
            switch (mouse.button) {
                .wheel_up => proc.updateScroll(.up),
                .wheel_down => proc.updateScroll(.down),
                else => {},
            }
        }

        const view = win.child(.{
            .y_off = 3,
            .width = .expand,
            .height = .expand,
        });
        proc.draw(view);
    }
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
            // return self.execFilePath(p, iter);
            // } else {
            //     log.info("Command path not found: {s} {s}", .{ name, path_env });
            // }
            return self.execFilePath(name, iter);
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

    if (self.current_process) |proc| {
        proc.destroy(self.allocator);
    }
    self.current_process = try Process.create(self.allocator, args.items);
    errdefer self.current_process.?.destroy(self.allocator);
    log.info("Running {s}", .{args.items});
    try self.current_process.?.run(self.allocator);
}

fn isFile(self: *App, path: []const u8) bool {
    _ = self.cwd.statFile(path) catch |err| switch (err) {
        error.IsDir => return false,
        else => return true,
    };
    return true;
}
