const std = @import("std");
const constants = @import("constants.zig");
const ConstantsError = constants.Error;
const Colour = constants.Colour;
const common = @import("common.zig");

const OUT = std.io.getStdOut();
const OUT_WRITER = OUT.writer();

pub const StdOut = struct {
    const STDOUT_BUFFER_SIZE = 2 * 1024;
    const Writer = std.io.BufferedWriter(STDOUT_BUFFER_SIZE, @TypeOf(OUT_WRITER));
    pub const Error = Writer.Error;

    writer: Writer = .{ .unbuffered_writer = OUT_WRITER },
    options: *common.Options,

    pub fn init(options: *common.Options) StdOut {
        return StdOut{ .options = options };
    }

    /// Updates options based on if stdout is a tty
    pub fn update_options(self: *StdOut) void {
        if (OUT.isTty()) {
            return;
        }

        self.options.colour = !self.options.colour;
        self.options.header = !self.options.header;
        self.options.line_numbers = !self.options.line_numbers;
    }

    pub fn write(self: *StdOut, bytes: []const u8) Error!void {
        const size = try self.writer.write(bytes);
        if (size != bytes.len) {
            std.log.err("failed writing line: wrote {d} bytes, expecting {d}", .{ size, bytes.len });
            return Error.Unexpected;
        }
    }

    pub fn write_fmt(self: *StdOut, comptime format: []const u8, args: anytype) !void {
        try std.fmt.format(self.writer.writer(), format, args);
    }

    pub fn write_u8(self: *StdOut, byte: u8) !void {
        try self.writer.writer().writeByte(byte);
    }

    pub fn write_padding(self: *StdOut, size: usize) !void {
        try self.writer.writer().writeByteNTimes(' ', size);
    }

    fn get_padding(padding: anytype) ?usize {
        const padding_type = @typeInfo(@TypeOf(padding));
        const s = switch (padding_type) {
            .Struct => padding_type.Struct,
            else => @compileError("padding needs to be struct containing padding amount"),
        };

        if (s.fields.len == 0) {
            return null;
        }

        if (s.fields.len > 1) {
            @compileError("too many values provided");
        }

        return switch (s.fields[0].type) {
            usize => padding[0],
            else => @compileError("invalid type provided"),
        };
    }

    pub fn write_header(self: *StdOut, bytes: []const u8, padding: anytype) !void {
        const padding_amount = get_padding(padding);
        const underline_length = bytes.len * 4 / 3;

        if (padding_amount) |p| {
            try self.write_padding(p);
            try self.start_colour(Colour.Header);
            try self.write(bytes);
            try self.write_u8('\n');
            try self.end_colour();
            try self.write_padding(p - 1);
            try self.write("╭");
            try self.writer.writer().writeBytesNTimes("─", underline_length);
            try self.write_u8('\n');
        } else {
            try self.start_colour(Colour.Header);
            try self.write(bytes);
            try self.write_u8('\n');
            try self.end_colour();
            try self.writer.writer().writeBytesNTimes("─", underline_length);
            try self.write_u8('\n');
        }
    }

    pub fn write_line_number(self: *StdOut, line_number: usize, max_padding: usize) !void {
        const padding_size = max_padding - common.digit_count(line_number);
        try self.write_padding(padding_size);
        try self.start_colour(constants.Colour.LineNumber);
        try self.write_fmt("{d}", .{line_number});
        try self.end_colour();
        try self.write("│ ");
    }

    pub fn write_separator(self: *StdOut, header_length: usize, padding: anytype) !void {
        const padding_amount = get_padding(padding);
        const underline_length = header_length * 4 / 3;

        if (padding_amount) |p| {
            try self.write_padding(p);
            try self.write("╰");
            try self.writer.writer().writeBytesNTimes("─", underline_length);
            try self.write_u8('\n');
        } else {
            try self.writer.writer().writeBytesNTimes("─", underline_length);
            try self.write_u8('\n');
        }
    }

    pub inline fn start_colour(self: *StdOut, comptime colour: Colour) !void {
        if (!self.options.colour) {
            return;
        }
        const seg = switch (colour) {
            .Default => "\x1b[0m",
            .LineNumber => "\x1b[32m",
            .Header => "\x1b[36m",
        };
        try self.write(seg);
    }

    pub inline fn end_colour(self: *StdOut) !void {
        try self.start_colour(Colour.Default);
    }

    pub fn flush(self: *StdOut) !void {
        try self.writer.flush();
    }
};

pub fn read_to_buffer(alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var buf_reader = std.io.bufferedReader(file.reader());
    const byte_size = if (file.metadata()) |metadata| metadata.size() else |_| try seek_file_size(file);

    std.log.debug("allocating {d} bytes", .{byte_size});
    const buf = try alloc.alloc(u8, byte_size);
    const read = try buf_reader.read(buf);
    std.log.debug("read {d} bytes", .{read});

    return buf;
}

fn seek_file_size(file: std.fs.File) !u64 {
    try file.reader().skipUntilDelimiterOrEof(0);
    const bytes = try file.reader().context.getPos();
    std.log.debug("seeked byte_size: {d}", .{bytes});

    try file.reader().context.seekTo(0);
    return bytes;
}

pub fn is_valid_path(path: []const u8) ConstantsError!void {
    const Error = ConstantsError;
    std.fs.cwd().access(path, .{}) catch |e| switch (e) {
        error.FileNotFound => {
            std.log.err("file not found: {s}", .{path});
            return Error.FileNotFound;
        },
        error.NameTooLong => {
            std.log.err("name too long: {d} characters", .{path.len});
            return Error.InvalidArgs;
        },
        error.BadPathName => {
            std.log.err("bad filepath: {s}", .{path});
            return Error.InvalidArgs;
        },
        error.InvalidUtf8, error.InvalidWtf8 => {
            std.log.err("invalid utf-8: {s}", .{path});
            return Error.InvalidArgs;
        },
        error.PermissionDenied => {
            std.log.err("permission denied: {s}", .{path});
            return Error.PermissionDenied;
        },
        error.ReadOnlyFileSystem => {
            std.log.err("read only filesystem: {s}", .{path});
            return Error.PermissionDenied;
        },
        error.InputOutput, error.SymLinkLoop, error.SystemResources => {
            std.log.err("io error: {s}", .{path});
            return Error.IOError;
        },
        error.FileBusy => {
            std.log.err("file busy: {s}", .{path});
            return Error.IOError;
        },
        error.Unexpected => {
            std.log.err("unknown error: {s}", .{path});
            return Error.InvalidArgs;
        },
    };
}
