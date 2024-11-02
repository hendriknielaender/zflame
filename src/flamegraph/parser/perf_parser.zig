// perf_parser.zig
const std = @import("std");
const parser = @import("../parser.zig");
const stackcollapse = @import("../../stackcollapse.zig");

/// Configuration options specific to the perf parser.
pub const PerfParserConfig = struct {
    include_pname: bool = true,
    include_pid: bool = false,
    include_tid: bool = false,
    include_addrs: bool = false,
    tidy_generic: bool = true,
};

/// Represents a `perf` parser.
pub const PerfParser = struct {
    config: PerfParserConfig,

    /// Implements the `parse` function for `perf` input.
    pub fn parse(
        self: *PerfParser,
        allocator: *std.mem.Allocator,
        input_data: []const u8,
    ) ![]parser.CollapsedStack {
        // Implement the perf parsing logic here.
        // This can be similar to the previously provided `stackcollapse-perf.pl` port.
        // For brevity, assume we have a function `collapsePerfStacks` defined elsewhere.
        return stackcollapse.collapsePerfStacks(allocator, input_data, self.config);
    }

    /// Returns the name of the parser.
    pub fn name() []const u8 {
        return "perf";
    }
};
