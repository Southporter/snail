const std = @import("std");

pub fn getRef(allocator: std.mem.Allocator) ![]const u8 {
    const head = try std.fs.cwd().openFile(".git/HEAD", .{});

    var buf: [128]u8 = undefined;
    const size = try head.readAll(&buf);

    if (std.mem.eql(u8, "ref: ", buf[0..4])) {
        // Strip off the beginning
        // i.e.
        //
        // ref: refs/heads/master
        const leader = "ref: refs/heads/";
        return buf[leader.len .. size - 1];
    }

    return allocator.dupe(u8, buf[0 .. size - 1]);
}
