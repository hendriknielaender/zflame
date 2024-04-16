const std = @import("std");

/// Main entry point of the application.
pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Construct the DTrace command string with detailed error handling.
    const pid = "2177"; // Example PID for profiling
    const dtrace_script = try buildDTraceScript(allocator, pid);
    defer allocator.free(dtrace_script);

    // Execute DTrace command and handle the output
    const output = try executeDTrace(allocator, dtrace_script);
    defer allocator.free(output);

    // Analyze and log the results from DTrace
    try processDTraceOutput(output);
}

/// Builds a DTrace command script for profiling based on a given PID.
fn buildDTraceScript(allocator: std.mem.Allocator, pid: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "profile-997 /pid == {s} / {{ @[ustack()] = count(); }}", .{pid}) catch |err| {
        std.log.err("Error formatting DTrace script: {any}", .{err});
        return err;
    };
}

/// Executes the DTrace script and returns the collected output as bytes.
fn executeDTrace(allocator: std.mem.Allocator, script: []const u8) ![]const u8 {
    const args = &.{ "sudo", "dtrace", "-n", script, "-o", "output.txt" };
    const stdout = (try std.process.Child.run(.{ .allocator = allocator, .argv = args })).stdout;
    if (stdout.len == 0) {
        return error.EmptyOutput;
    }
    return stdout;
}

/// Processes and logs the output from the DTrace command.
fn processDTraceOutput(output: []const u8) !void {
    if (output.len == 0) {
        std.log.warn("DTrace output is empty.", .{});
    } else {
        std.log.info("DTrace Output: {any}", .{output});
    }
}
