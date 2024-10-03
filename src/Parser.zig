const std = @import("std");
const Parser = @This();
const log = std.log.scoped(.snail_parser);

source: []const u8,
offset: usize = 0,

pub fn init(src: []const u8) Parser {
    return .{
        .source = src,
    };
}

pub const Token = struct {
    kind: Kind,
    location: Location,

    pub const Kind = enum {
        path,
        identifier,
        flag,
        string,
        invalid,
        end_of_input,
    };

    pub const Location = struct {
        start: usize,
        end: usize,
    };
};

const State = enum {
    start,
    path,
    identifier,
    flag,
    quoted,
};

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t';
}

pub fn next(self: *Parser) Token {
    var result = Token{
        .kind = if (self.offset >= self.source.len) .end_of_input else .invalid,
        .location = .{
            .start = self.offset,
            .end = self.offset,
        },
    };

    var state = State.start;
    var unclosed_quote: u8 = undefined;
    while (self.offset < self.source.len) : (self.offset += 1) {
        const c = self.source[self.offset];
        switch (state) {
            .start => switch (c) {
                '.', '/' => {
                    state = .path;
                    result.kind = .path;
                },
                'a'...'z', 'A'...'Z' => {
                    state = .identifier;
                    result.kind = .identifier;
                },
                '-' => {
                    state = .flag;
                    result.kind = .flag;
                },
                ' ', '\t', '\r' => {
                    result.location.start += 1;
                },
                '\'', '"', '`' => {
                    state = .quoted;
                    unclosed_quote = c;
                    result.kind = .string;
                },
                else => {
                    log.warn("Parser encountered an unexpected start character: {s}", .{self.source[self.offset .. self.offset + 3]});
                    break;
                },
            },
            .path => switch (c) {
                '\'', '"', '`' => {
                    state = .quoted;
                    unclosed_quote = c;
                },
                ' ', '\t' => {
                    break;
                },
                else => {},
            },
            .identifier => switch (c) {
                '/' => {
                    state = .path;
                    result.kind = .path;
                },
                '\'', '"', '`' => {
                    break;
                },
                ' ', '\t' => {
                    break;
                },
                else => {},
            },
            .flag => switch (c) {
                ' ', '\t' => {
                    break;
                },
                '\'', '"', '`' => {
                    state = .quoted;
                    unclosed_quote = c;
                },
                else => {},
            },
            .quoted => {
                const escaped = self.source[self.offset - 1] == '\\';
                if (c == unclosed_quote and !escaped) {
                    break;
                }
            },
        }
    }

    result.location.end = self.offset;
    return result;
}

test "paths" {
    const input = "/an/absolute/path ./local.sh another/path";
    var parser = Parser.init(input);

    const expected = [_]Token{
        .{
            .kind = .path,
            .location = .{
                .start = 0,
                .end = 17,
            },
        },
        .{
            .kind = .path,
            .location = .{
                .start = 18,
                .end = 28,
            },
        },
        .{
            .kind = .path,
            .location = .{
                .start = 29,
                .end = 41,
            },
        },
    };

    for (expected) |expect| {
        const got = parser.next();
        std.debug.print("Expecting {any} got {any}\n", .{ expect, got });
        try std.testing.expectEqual(expect, got);
    }
}

test "identifiers" {
    const input = "cat log.txt";
    var parser = Parser.init(input);

    const expected = [_]Token{
        .{
            .kind = .identifier,
            .location = .{
                .start = 0,
                .end = 3,
            },
        },
        .{
            .kind = .identifier,
            .location = .{
                .start = 4,
                .end = 11,
            },
        },
    };

    for (expected) |expect| {
        const got = parser.next();
        std.debug.print("Expecting {any} got {any}\n", .{ expect, got });
        try std.testing.expectEqual(expect, got);
    }
}
