const std = @import("std");
const assert = std.debug.assert;

pub const CollapsedStack = struct {
    stack: []const u8,
    count: u64,

    pub fn validate(self: CollapsedStack) void {
        assert(self.stack.len > 0);
        assert(self.stack.len <= 4096);
        assert(self.count > 0);
        assert(self.count <= 1000000000);
    }
};

pub const Parser = struct {
    parse_to_buffer: *const fn (allocator: *std.mem.Allocator, input_data: []const u8, output_buffer: []CollapsedStack) []CollapsedStack,
    get_parser_name: *const fn () []const u8,

    fn validate(self: Parser) void {
        assert(self.parse_to_buffer != null);
        assert(self.get_parser_name != null);
    }
};
