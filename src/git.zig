const std = @import("std");

const log = std.log.scoped(.git);

pub const Status = enum {
    dirty,
    clean,
};

pub const GitInfo = struct {
    ref: []const u8 = "",
    status: Status = .clean,
};

fn getRef(allocator: std.mem.Allocator, dir: std.fs.Dir) ![]const u8 {
    const head = try dir.openFile(".git/HEAD", .{});

    var buf: [128]u8 = undefined;
    const size = try head.readAll(&buf);

    if (std.mem.eql(u8, "ref: ", buf[0..5])) {
        // Strip off the beginning
        // i.e.
        //
        // ref: refs/heads/master
        const leader = "ref: refs/heads/";
        return allocator.dupe(u8, buf[leader.len .. size - 1]);
    }

    return allocator.dupe(u8, buf[0 .. size - 1]);
}

const ENTRIES_OFFSET = 12;
const ENTRY_SIZE = @sizeOf(u32) * 7 + @sizeOf(u16) + @sizeOf(u32) * 3;

fn getStatus(allocator: std.mem.Allocator, dir: std.fs.Dir) !Status {
    const file = try dir.readFileAlloc(allocator, ".git/index", 4098);
    defer allocator.free(file);
    std.debug.assert(std.mem.eql(u8, "DIRC", file[0..4]));
    log.info("Git version {s}", .{std.fmt.fmtSliceHexLower(file[4..8])});
    const entries = try std.fmt.parseInt(u32, file[8..12], 10);

    for (0..entries) |i| {
        const start = ENTRIES_OFFSET + i * ENTRY_SIZE;
        log.info("name {s}", .{file[start..(start + 16)]});
    }

    return .clean;
}

pub fn getGitInfo(allocator: std.mem.Allocator, dir: std.fs.Dir) !GitInfo {
    const ref = getRef(allocator, dir) catch "";
    const status = getStatus(allocator, dir) catch .clean;
    return .{
        .ref = ref,
        .status = status,
    };
}
