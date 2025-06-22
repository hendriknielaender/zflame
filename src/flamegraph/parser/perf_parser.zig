const std = @import("std");
const assert = std.debug.assert;
const parser = @import("../parser.zig");
const stackcollapse = @import("../../stackcollapse.zig");

pub const PerfParser = struct {
    config: stackcollapse.PerfParserConfig,

    pub fn init() PerfParser {
        return PerfParser{
            .config = stackcollapse.PerfParserConfig.init_default(),
        };
    }

    pub fn parse_to_buffer(
        self: *const PerfParser,
        allocator: *std.mem.Allocator,
        input_data: []const u8,
        output_buffer: []parser.CollapsedStack,
    ) ![]parser.CollapsedStack {
        assert(input_data.len > 0);
        assert(output_buffer.len > 0);
        self.config.validate();
        
        return stackcollapse.collapse_perf_stacks_to_buffer(allocator, input_data, self.config, output_buffer);
    }

    pub fn get_parser_name(_: *const PerfParser) []const u8 {
        return "perf";
    }
};
