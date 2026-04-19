// Format auto-detection for stack collapse parsers - minimal stub for no-allocation version

const std = @import("std");
const collapse_types = @import("collapse.zig");
const Io = std.Io;

pub const Options = struct {};

pub const Folder = struct {
    options: Options,

    pub fn init(options: Options) Folder {
        return Folder{
            .options = options,
        };
    }

    pub fn deinit(self: *Folder) void {
        _ = self;
    }

    pub fn collapse(
        self: *Folder,
        reader: *Io.Reader,
        writer: *Io.Writer,
    ) !void {
        _ = self;
        while (try reader.takeDelimiter('\n')) |line| {
            if (line.len > 0) {
                try writer.print("{s} 1\n", .{line});
            }
        }
    }

    pub fn is_applicable(self: *Folder, input: []const u8) bool {
        _ = self;
        _ = input;
        return true; // Guess format always applicable as fallback
    }
};
