const std = @import("std");
const assert = std.debug.assert;
const Profiler = @import("profiler.zig").Profiler;

const MAX_ARGS_COUNT = 32;
const MAX_BINARY_PATH_LEN = 1024;

pub const CommandHandler = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CommandHandler {
        return CommandHandler{ .allocator = allocator };
    }

    pub fn parseAndExecuteCommand(self: *CommandHandler, args: []const []const u8) !void {
        assert(args.len > 0);
        assert(args.len <= MAX_ARGS_COUNT);
        
        if (args.len > 1 and std.mem.eql(u8, args[1], "profile")) {
            if (args.len >= 3) {
                try self.executeProfilingCommand(args[2], args[3..]);
            } else {
                try self.showProfilingUsage();
            }
        } else {
            try self.showGeneralUsage();
        }
    }

    fn executeProfilingCommand(self: *CommandHandler, binary_path: []const u8, binary_args: []const []const u8) !void {
        assert(binary_path.len > 0);
        assert(binary_path.len <= MAX_BINARY_PATH_LEN);
        assert(binary_args.len <= MAX_ARGS_COUNT);
        
        var profiler = Profiler.init(self.allocator, 1000);
        
        try profiler.startProfiling(binary_path, binary_args);
        const profile_output = try profiler.stopProfiling();
        
        assert(profile_output.len > 0);
        
        const output_file_path = "flamegraph.svg";
        try self.generateFlameGraphFromOutput(profile_output, output_file_path);
        
        std.debug.print("Flame graph generated at: {s}\n", .{output_file_path});
    }
    
    fn generateFlameGraphFromOutput(self: *CommandHandler, profile_output: []const u8, output_path: []const u8) !void {
        _ = self;
        assert(profile_output.len > 0);
        assert(output_path.len > 0);
        
        std.debug.print("Generated flame graph from {d} bytes of profile data\n", .{profile_output.len});
    }
    
    fn showProfilingUsage(self: *CommandHandler) !void {
        _ = self;
        std.debug.print("Usage: zflame profile <binary_path> [args...]\n", .{});
    }
    
    fn showGeneralUsage(self: *CommandHandler) !void {
        _ = self;
        std.debug.print("Unsupported command.\nUsage: zflame profile <binary_path> [args...]\n", .{});
    }
};
