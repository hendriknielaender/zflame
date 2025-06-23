// XCTrace stack collapse parser - minimal stub for no-allocation version

const std = @import("std");
const collapse_types = @import("collapse.zig");

pub const Options = struct {
    include_modules: bool = true,
};

pub const Folder = struct {
    options: Options,

    pub fn init(options: Options) !Folder {
        return Folder{
            .options = options,
        };
    }

    pub fn deinit(self: *Folder) void {
        _ = self;
    }

    pub fn collapse(
        self: *Folder,
        reader: anytype,
        writer: anytype,
    ) !void {
        _ = self;
        var line_buffer: [4096]u8 = undefined;
        while (try reader.readUntilDelimiterOrEof(line_buffer[0..], '\n')) |line| {
            if (line.len > 0) {
                try writer.print("{s} 1\n", .{line});
            }
        }
    }

    pub fn is_applicable(self: *Folder, input: []const u8) bool {
        _ = self;
        return std.mem.indexOf(u8, input, "xctrace") != null;
    }
};
