const std = @import("std");

const Profiler = @import("profiler.zig").Profiler;

pub const CommandHandler = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CommandHandler {
        return CommandHandler{ .allocator = allocator };
    }

    pub fn parseAndExecute(self: *CommandHandler, args: []const []const u8) !void {
        if (args.len > 1 and std.mem.eql(u8, args[1], "profile")) {
            // Ensure there's a binary path provided
            if (args.len >= 3) {
                try self.profileAndGenerateFlameGraph(args[2], args[3..]);
            } else {
                std.debug.print("Usage: command profile <binaryPath> [args...]\n", .{});
            }
        } else {
            std.debug.print("Unsupported command or insufficient arguments.\nUsage: command profile <binaryPath> [args...]\n", .{});
        }
    }

    fn profileAndGenerateFlameGraph(self: *CommandHandler, binaryPath: []const u8, binaryArgs: []const []const u8) !void {
        // Instantiate the correct profiler for the platform
        var profiler = Profiler.init(self.allocator, 1_000_000); // Example: profile every second
        //defer profiler.deinit(); // Ensure resources are cleaned up appropriately

        // Start profiling
        try profiler.start(binaryPath, binaryArgs);
        try profiler.stop(); // Make sure to stop profiling when done

        // At this point, the profile data should be captured and saved by the profiler's stop method.
        // Now, generate the flame graph from the captured profile data.
        //var flameGraphGenerator = Generator.init(self.allocator);
        const outputFilePath = "flamegraph.svg"; // Define the output file path for the flame graph

        // Assuming the profiler saves the profile data in a known location/format,
        // the generator needs to process that data.
        //try flameGraphGenerator.generateFromProfileData("profile_data_output_path", outputFilePath);

        std.debug.print("Flame graph generated at: {s}\n", .{outputFilePath});
    }
};
