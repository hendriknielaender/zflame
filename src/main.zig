const std = @import("std");

const Profiler = @import("profiler.zig").Profiler;
const CommandHandler = @import("command_handler.zig").CommandHandler;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var commandHandler = CommandHandler.init(allocator);
    try commandHandler.parseAndExecute(args);
}
