const std = @import("std");

const Profiler = @import("profiler.zig").Profiler;
const Generator = @import("flamegraph/generator.zig").Generator;

const CommandHandler = struct {
    allocator: *std.mem.Allocator,

    pub fn init(allocator: *std.mem.Allocator) CommandHandler {
        return CommandHandler{ .allocator = allocator };
    }

    pub fn parseAndExecute(self: *CommandHandler, args: []const []const u8) !void {
        // Parse arguments to determine the command
        // For simplicity, let's assume args[1] is the command
        // and args[2..] are the parameters for that command

        if (std.mem.eql(u8, args[1], "profile")) {
            // Assuming args[2] is the path to the binary and args[3..] are its arguments
            try self.profileAndGenerateFlameGraph(args[2], args[3..]);
        } else {
            std.debug.print("Unsupported command.\n", .{});
        }
    }

    fn profileAndGenerateFlameGraph(self: *CommandHandler, binaryPath: []const u8, binaryArgs: []const []const u8) !void {
        // Initialize the profiler
        var profiler = Profiler.init(self.allocator);
        const profileData = try profiler.captureProfile(binaryPath, binaryArgs);

        // Generate the flame graph
        var flameGraphGenerator = Generator.init(self.allocator);
        try flameGraphGenerator.generateFromProfileData(profileData, "flamegraph.svg");
    }
};
