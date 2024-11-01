const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const log = std.log.scoped(.pty);

pub const winsize = extern struct {
    row: u16 = 100,
    col: u16 = 80,
    xpixel: u16 = 800,
    ypixel: u16 = 600,
};

// TODO windows?
pub const Pty = PosixPty;

pub const PosixPty = struct {
    pub const Fd = posix.fd_t;

    const TIOCSCTTY = if (builtin.os.tag == .macos) 536900705 else std.os.linux.T.IOCSCTTY;
    const TIOCSWINSZ = if (builtin.os.tag == .macos) 2148037735 else std.os.linux.T.IOCSWINSZ;
    const TIOCGWINSZ = if (builtin.os.tag == .macos) 1074295912 else std.os.linux.T.IOCGWINSZ;

    const ioctl = switch (builtin.os.tag) {
        .macos => @cImport({
            @cInclude("sys/ioctl.h"); // ioctl and constants
            @cInclude("util.h"); // openpty()
        }),
        else => @cImport({
            @cInclude("sys/ioctl.h"); // ioctl and constants
            @cInclude("pty.h");
        }),
    };

    manager: Fd,
    worker: Fd,

    pub fn open(size: winsize) !Pty {
        var sizecpy = size;

        var manager_fd: Fd = undefined;
        var worker_fd: Fd = undefined;
        if (ioctl.openpty(&manager_fd, &worker_fd, null, null, @ptrCast(&sizecpy)) < 0) {
            return error.FailedToOpenpty;
        }
        errdefer {
            _ = posix.close(manager_fd);
            _ = posix.close(worker_fd);
        }

        var attrs: ioctl.termios = undefined;
        if (ioctl.tcgetattr(manager_fd, &attrs) != 0) {
            return error.FailedToGetTCAttrs;
        }
        attrs.c_iflag |= ioctl.IUTF8;
        if (ioctl.tcsetattr(manager_fd, ioctl.TCSANOW, &attrs) != 0) {
            return error.FailedToSetTCAttrs;
        }

        return Pty{
            .manager = manager_fd,
            .worker = worker_fd,
        };
    }

    pub fn deinit(pty: *Pty) void {
        _ = posix.close(pty.manager);
        _ = posix.close(pty.worker);
    }

    /// Set the size of the pty.
    pub fn setSize(self: *Pty, size: winsize) !void {
        if (ioctl.ioctl(self.manager, TIOCSWINSZ, @intFromPtr(&size)) < 0)
            return error.IoctlFailed;
    }
};
