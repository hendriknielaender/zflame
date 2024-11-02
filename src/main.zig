const std = @import("std");
const assert = std.debug.assert;
const parser = @import("flamegraph/parser.zig");
const perf_parser = @import("flamegraph/parser/perf_parser.zig");
// const dtrace_parser = @import("dtrace_parser.zig");

/// Configuration options for zflame.
const Config = struct {
    /// Input file path. Defaults to standard input ("-").
    input_file: []const u8 = "-",
    /// Output file path. Defaults to standard output ("-").
    output_file: []const u8 = "-",
    /// Input format (e.g., perf, dtrace, etc.).
    input_format: []const u8 = "perf",
    /// Width of the generated SVG image.
    image_width: u32 = 1200,
    /// Height of each frame in the flame graph.
    frame_height: u32 = 16,
    /// Font size used in the SVG.
    font_size: f32 = 12.0,
    /// Minimum width for frames. Frames narrower than this will be omitted.
    min_width: f32 = 0.1,
    /// Color palette to use for the flame graph.
    colors: []const u8 = "hot",
    /// Inverted flame graph (icicle graph) if true.
    inverted: bool = false,
    /// Title text for the flame graph.
    title: []const u8 = "Flame Graph",
    /// Subtitle text for the flame graph (optional).
    subtitle: []const u8 = "",
};

/// Represents a single frame in the flame graph.
const Frame = struct {
    /// Name of the function or symbol.
    name: []const u8,
    /// Total value (e.g., samples) attributed to this frame.
    value: f64,
    /// Children frames (functions called by this function).
    children: std.StringHashMap(*Frame),
};

/// Entry point of the zflame program.
pub fn main() !void {
    var allocator = std.heap.page_allocator;

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const config = try parseArgs(args[1..]);
    assert(config.image_width > 0);
    assert(config.frame_height > 0);
    assert(config.font_size > 0);

    std.debug.print("Input file: {s}\n", .{config.input_file});
    std.debug.print("Input format: {s}\n", .{config.input_format});

    const input_data = try readInput(&allocator, config.input_file);
    defer allocator.free(input_data);

    var collapsed_stacks: []parser = undefined;

    // Select the appropriate parser based on input_format.
    if (std.mem.eql(u8, config.input_format, "perf")) {
        const perf = perf_parser.PerfParser{};
        collapsed_stacks = try perf.parse(&allocator, input_data);
        // } else if (std.mem.eql(u8, config.input_format, "dtrace")) {
        //     const dtrace = dtrace_parser.DTraceParser{};
        //     collapsed_stacks = try dtrace.parse(&allocator, input_data);
    } else {
        return error.UnsupportedFormat;
    }

    defer freeTraces(&allocator, collapsed_stacks);

    var root_frame = try buildFlameGraph(&allocator, collapsed_stacks);

    try generateSVG(&allocator, &root_frame, config);

    // Clean up allocated frames.
    freeFrame(&allocator, &root_frame);
}

/// Parses command-line arguments into a `Config` struct.
fn parseArgs(args: [][]const u8) !Config {
    var config = Config{};
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help")) {
            try showHelp();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--width")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            config.image_width = try parseUnsignedInt(args[i]);
        } else if (std.mem.eql(u8, arg, "--height")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            config.frame_height = try parseUnsignedInt(args[i]);
        } else if (std.mem.eql(u8, arg, "--colors")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            config.colors = args[i];
        } else if (std.mem.eql(u8, arg, "--inverted")) {
            config.inverted = true;
        } else if (std.mem.eql(u8, arg, "--title")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            config.title = args[i];
        } else if (std.mem.eql(u8, arg, "--subtitle")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            config.subtitle = args[i];
        } else if (std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            config.output_file = args[i];
        } else if (std.mem.eql(u8, arg, "--input")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            config.input_file = args[i];
        } else if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            config.input_format = args[i];
        } else {
            // Treat as input file if not already set.
            if (std.mem.eql(u8, config.input_file, "-")) {
                config.input_file = arg;
            } else {
                return error.InvalidArguments;
            }
        }
    }

    return config;
}

/// Displays the help message.
fn showHelp() !void {
    const stdout = std.io.getStdOut().writer();
    const usage =
        \\ USAGE: zflame [options] input.txt > graph.svg
        \\ Options:
        \\   --help            Show this help message
        \\   --width NUM       Width of the SVG image (default 1200)
        \\   --height NUM      Height of each frame (default 16)
        \\   --colors PALETTE  Color palette to use (default "hot")
        \\   --inverted        Generate an inverted flame graph (icicle graph)
        \\   --title TEXT      Title text for the flame graph
        \\   --subtitle TEXT   Subtitle text for the flame graph
        \\   --output FILE     Output file (default standard output)
        \\   --input FILE      Input file (default standard input)
    ;
    try stdout.print(
        usage,
        .{},
    );
}

/// Parses an unsigned integer from a string.
fn parseUnsignedInt(s: []const u8) !u32 {
    const value = try std.fmt.parseInt(u32, s, 10);
    return value;
}

/// Reads the input data from a file or standard input.
fn readInput(allocator: *std.mem.Allocator, input_file: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(input_file, .{});
    defer file.close();
    const reader = file.reader();

    var buffer = std.ArrayList(u8).init(allocator.*);
    defer buffer.deinit();

    var chunk: [1024]u8 = undefined;
    while (true) {
        const bytes_read = try reader.read(&chunk);
        if (bytes_read == 0) break;
        try buffer.appendSlice(chunk[0..bytes_read]);
    }

    return buffer.toOwnedSlice();
}

/// Parses the input data into a list of stack traces.
fn parseInputData(
    allocator: *std.mem.Allocator,
    input_data: []const u8,
) ![]const []const u8 {
    var lines_it = std.mem.split(u8, input_data, "\n");

    var traces_list = std.ArrayList([]const u8).init(allocator.*);
    defer traces_list.deinit();

    while (lines_it.next()) |line| {
        if (line.len == 0) continue;
        try traces_list.append(line);
    }

    return traces_list.toOwnedSlice();
}

/// Frees the allocated traces.
fn freeTraces(allocator: *std.mem.Allocator, traces: []parser.CollapsedStack) void {
    for (traces) |trace| {
        // If `stack` was duplicated, ensure to free it.
        if (trace.stack != null and trace.stack[0] != 0) {
            allocator.free(trace.stack);
        }
    }
    allocator.free(traces);
}

/// Builds the flame graph data structure from the parsed traces.
fn buildFlameGraph(
    allocator: *std.mem.Allocator,
    traces: []const []const u8,
) !Frame {
    var root = Frame{
        .name = "root",
        .value = 0.0,
        .children = std.StringHashMap(*Frame).init(allocator.*),
    };

    for (traces) |trace_line| {
        var parts_it = std.mem.split(u8, trace_line, " ");

        var stack_str: []const u8 = undefined;
        var sample_value_str: ?[]const u8 = null; // Declare as optional

        var index: usize = 0;
        while (parts_it.next()) |part| {
            if (index == 0) {
                stack_str = part;
            } else if (index == 1) {
                sample_value_str = part; // Assign to optional
            }
            index += 1;
        }

        if (index < 1 or stack_str.len == 0) continue;

        var sample_value: f64 = 1.0;
        if (sample_value_str) |s| {
            sample_value = try std.fmt.parseFloat(f64, s);
        }

        var stack_it = std.mem.split(u8, stack_str, ";");

        var current = &root;
        while (stack_it.next()) |func_name| {
            const child = current.children.get(func_name) orelse blk: {
                const new_frame = try allocator.create(Frame);
                try initFrame(new_frame, func_name, allocator);
                try current.children.put(func_name, new_frame);
                break :blk new_frame;
            };
            current = child;
        }
        current.value += sample_value;
        root.value += sample_value;
    }

    return root;
}

/// Initializes a `Frame` in place.
fn initFrame(
    frame: *Frame,
    name: []const u8,
    allocator: *std.mem.Allocator,
) !void {
    frame.* = Frame{
        .name = name,
        .value = 0.0,
        .children = std.StringHashMap(*Frame).init(allocator.*),
    };
}

/// Frees the allocated memory for a frame and its children.
fn freeFrame(allocator: *std.mem.Allocator, frame: *Frame) void {
    var it = frame.children.iterator();
    while (it.next()) |entry| {
        freeFrame(allocator, entry.value_ptr.*);
        allocator.destroy(entry.value_ptr.*);
    }
    frame.children.deinit();
}

/// Generates the SVG output for the flame graph.
fn generateSVG(
    _: *std.mem.Allocator,
    root: *Frame,
    config: Config,
) !void {
    var output_file = try std.fs.cwd().createFile(config.output_file, .{});
    defer output_file.close();
    const file = output_file.writer();

    // Calculate the maximum depth of the flame graph.
    //const depth_max = 20; // Placeholder; you may want to calculate this

    // Write SVG header.
    try file.print(
        \\<?xml version="1.0" standalone="no"?>
        \\<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN"
        \\  "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
        \\<svg version="1.1" width="{d}" height="{d}" xmlns="http://www.w3.org/2000/svg">
        \\\n
    ,
        .{ config.image_width, calculateImageHeight(config) },
    );

    // Write frames recursively.
    try writeFrame(
        file,
        root,
        0,
        0.0,
        @floatFromInt(config.image_width - 2 * 10),
        root.value,
        config,
    );

    // Write SVG footer.
    try file.print("</svg>\n", .{});
}

/// Calculates the total height of the SVG image.
fn calculateImageHeight(config: Config) u32 {
    const size: u32 = @intFromFloat(config.font_size);
    const ypad1: u32 = size * 3;
    const ypad2: u32 = size * 2 + 10;
    const depth_max = 20; // Placeholder for maximum depth.
    const image_height = ((depth_max + 1) * config.frame_height) + ypad1 + ypad2;
    return image_height;
}

/// Recursively writes a frame and its children to the SVG.
fn writeFrame(
    file: anytype,
    frame: *Frame,
    depth: u32,
    x_offset: f64,
    total_width: f64,
    root_value: f64,
    config: Config,
) !void {
    const width = (frame.value / root_value) * total_width;
    const x = x_offset;
    const y = calculateYPosition(depth, config);
    const size = config.font_size;
    const height: f64 = @floatFromInt(config.frame_height);

    // Draw rectangle.
    try file.print(
        "<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" fill=\"{s}\" />\n",
        .{ x, y, width, height, getColor(frame.name, config.colors) },
    );

    // Draw text.
    const text_y = y + height / 2.0 + size / 2.0 - 2.0;
    try file.print(
        "<text x=\"{d}\" y=\"{d}\" font-size=\"{d}px\">{s}</text>\n",
        .{ x + 3.0, text_y, size, frame.name },
    );

    // Recursively write children.
    var child_x_offset = x_offset;

    // Obtain the iterator from the HashMap
    var it = frame.children.iterator();

    // Iterate using the while loop
    while (it.next()) |entry| {
        const child_frame_ptr = entry.value_ptr.*;

        // Calculate the width for the child frame
        const child_width = (child_frame_ptr.value / root_value) * total_width;

        // Recursively write the child frame
        try writeFrame(
            file,
            child_frame_ptr,
            depth + 1,
            child_x_offset,
            child_width,
            root_value,
            config,
        );

        // Update the x_offset for the next child
        child_x_offset += child_width;
    }
}

/// Calculates the Y position based on the depth and configuration.
fn calculateYPosition(depth: u32, config: Config) f64 {
    const size = config.font_size;
    if (config.inverted) {
        const ypad1 = size * 3.0;
        const depth_f64: f64 = @floatFromInt(depth);
        const height_f64: f64 = @floatFromInt(config.frame_height);
        return ypad1 + depth_f64 * height_f64;
    } else {
        const image_height: f64 = @floatFromInt(calculateImageHeight(config));
        const ypad2 = size * 2.0 + 10.0;
        const depth_f64_2: f64 = @floatFromInt(depth + 1);
        const height_f64_2: f64 = @floatFromInt(config.frame_height);
        return image_height - ypad2 - (depth_f64_2 * height_f64_2);
    }
}

/// Gets the total value of all child frames.
fn getTotalChildValue(frame: *Frame) f64 {
    var total: f64 = 0.0;
    var it = frame.children.iterator();
    while (it.next()) |entry| {
        total += entry.value.value;
    }
    return total;
}

/// Gets the color for a frame based on the selected palette.
fn getColor(_: []const u8, _: []const u8) []const u8 {
    // For simplicity, we return a hardcoded color.
    // You can implement different palettes based on the name and palette.
    return "#ff0000"; // Red color.
}
