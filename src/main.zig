const std = @import("std");
const os = std.os;
const fs = std.fs;

const Profiler = @import("profiler.zig").Profiler;
const FlameGraphGenerator = @import("flamegraph/generator.zig").FlameGraphGenerator;
const CommandHandler = @import("command_handler.zig").CommandHandler;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try os.argsAlloc(allocator);
    defer os.argsFree(allocator, args);

    var commandHandler = CommandHandler.init(allocator);
    try commandHandler.parseAndExecute(args);
}
