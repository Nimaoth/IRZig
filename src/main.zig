const std = @import("std");
const net = std.net;
const fs = std.fs;
const os = std.os;

pub const io_mode = .evented;

pub const IRCErrors = error{
    EmptyMessage,
    MissingCommand,
    MissingCrlf,
};

const Message = struct {
    prefix: ?[]const u8,
    command: []const u8,
    args: std.ArrayList([]const u8),

    const Self = @This();

    fn extract_until_next_space(raw: []const u8) struct { text: []const u8, rest: []const u8 } {
        var space_index: usize = 0;
        while (space_index < raw.len) : (space_index += 1) {
            if (raw[space_index] == ' ') {
                break;
            }
        }

        return .{
            .text = raw[0..space_index],
            .rest = blk: {
                if (space_index < raw.len) {
                    break :blk raw[(space_index + 1)..];
                } else {
                    break :blk "";
                }
            },
        };
    }

    pub fn parse(raw: []const u8, allocator: *std.mem.Allocator) !?Self {
        if (raw.len == 0) {
            return null;
        }

        const prefix_or_command = extract_until_next_space(raw);

        var prefix: ?[]const u8 = null;
        if (prefix_or_command.text.len == 0) {
            return error.EmptyMessage;
        }

        const command = blk: {
            if (prefix_or_command.text[0] == ':') {
                prefix = prefix_or_command.text[1..];
                break :blk extract_until_next_space(prefix_or_command.rest);
            } else {
                break :blk prefix_or_command;
            }
        };

        if (command.text.len == 0) {
            return error.EmptyMessage;
        }

        const args_raw = command.rest;

        var args = std.ArrayList([]const u8).init(allocator);
        var i: usize = 0;
        while (i < args_raw.len) : (i += 1) {
            if (args_raw[i] == ':') {
                try args.append(args_raw[(i + 1)..]);
                break;
            } else {
                const next = extract_until_next_space(args_raw[i..]);
                try args.append(next.text);
                i += next.text.len;
            }
        }

        return Message{
            .prefix = prefix,
            .command = command.text,
            .args = args,
        };
    }
};

const IrcClient = struct {
    stream: std.net.Stream,
    allocator: *std.mem.Allocator,

    const Self = @This();

    pub fn init(server_address: []const u8, server_port: u16, allocator: *std.mem.Allocator) !IrcClient {
        const address = try net.Address.parseIp(server_address, server_port);
        var stream = try net.tcpConnectToAddress(address);
        return IrcClient{
            .stream = stream,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stream.close();
    }

    pub fn read_message(self: *Self, buff: []u8) !?Message {
        var read = try self.stream.read(buff);

        if (read <= 2 or buff[read - 2] != '\r' or buff[read - 1] != '\n') {
            return error.MissingCrlf;
        }

        const message = try Message.parse(buff[0..(read - 2)], self.allocator);
        return message;
    }

    pub fn write_message(self: *Self, message: Message) !void {
        if (message.prefix) |prefix| {
            _ = try self.stream.write(":");
            _ = try self.stream.write(prefix);
            _ = try self.stream.write(" ");
        }
        _ = try self.stream.write(message.command);
        var i: usize = 0;
        while (i < message.args.items.len) : (i += 1) {
            _ = try self.stream.write(" ");
            _ = try self.stream.write(message.args.items[i]);
        }
        _ = try self.stream.write("\r\n");
    }
};

fn reader(client: *IrcClient, allocator: *std.mem.Allocator) !void {
    std.log.warn("reader()", .{});
    const buff: []u8 = try allocator.alloc(u8, 5120);
    while (true) {
        std.log.warn("reader(): reading message from stream", .{});
        var frame = async client.read_message(buff);
        var message = await frame catch |err| {
            std.debug.warn("{any}\n", .{buff});
            std.debug.warn("'{s}'\n", .{buff});
            std.debug.warn("Failed to parse message: {}\n", .{err});
            continue;
        };
        if (message) |msg| {
            std.debug.print(":{s} {s}", .{ msg.prefix, msg.command });
            var i: usize = 0;
            while (i < msg.args.items.len) : (i += 1) {
                std.debug.print(" '{s}'", .{msg.args.items[i]});
            }
            std.debug.print("\n", .{});
        }
    }
}

fn writer(client: *IrcClient, allocator: *std.mem.Allocator) !void {
    const stdin = std.io.getStdIn().reader();
    const buff: []u8 = try allocator.alloc(u8, 5120);
    while (true) {
        std.log.info("writer(): reading stdin... ", .{});
        if (try stdin.readUntilDelimiterOrEof(buff, '\n')) |line| {
            const message = Message.parse(":Nimaoth USER Nico irc.nimaoth.com tutorial.ubuntu.com :NO", allocator) catch |err| {
                std.log.warn("Failed to parse input as message: {}", .{err});
                continue;
            };

            if (message) |m| {
                std.log.info("writer(): sending message", .{});
                _ = try client.write_message(m);
            }
        }
    }
}

pub fn main() anyerror!void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = &general_purpose_allocator.allocator;

    var client = try IrcClient.init("127.0.0.1", 6697, allocator);
    defer client.deinit();

    try client.write_message((Message.parse("NICK Nimaoth", allocator) catch unreachable) orelse unreachable);
    try client.write_message((Message.parse(":Nimaoth USER Nico irc.nimaoth.com tutorial.ubuntu.com :NO", allocator) catch unreachable) orelse unreachable);

    var reader_frame = async reader(&client, allocator);
    var writer_frame = async writer(&client, allocator);

    try await reader_frame;
    try await writer_frame;
}
