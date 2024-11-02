// parser.zig
const std = @import("std");

/// Represents a standardized collapsed stack with its associated count.
pub const CollapsedStack = struct {
    stack: []const u8,
    count: u64,
};

/// Parser interface.
pub const Parser = struct {
    /// Parses raw input data and returns an array of collapsed stacks.
    parse: fn (allocator: *std.mem.Allocator, input_data: []const u8) []CollapsedStack,

    /// Returns the name of the parser.
    name: fn () []const u8,
};
