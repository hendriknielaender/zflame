const std = @import("std");
const assert = std.debug.assert;

const MAX_INPUT_SIZE_BYTES = 100 * 1024 * 1024;
const MAX_STACK_FRAMES = 10000;
const MAX_FUNCTION_NAME_BYTES = 512;
const MAX_COLLAPSED_STACKS = 100000;
const MAX_ARGS_COUNT = 64;

comptime {
    assert(MAX_INPUT_SIZE_BYTES > 0);
    assert(MAX_INPUT_SIZE_BYTES <= 1024 * 1024 * 1024);
    assert(MAX_STACK_FRAMES > 0);
    assert(MAX_STACK_FRAMES <= 1000000);
    assert(MAX_FUNCTION_NAME_BYTES > 0);
    assert(MAX_FUNCTION_NAME_BYTES <= 4096);
    assert(MAX_COLLAPSED_STACKS > 0);
    assert(MAX_COLLAPSED_STACKS <= 10000000);
    assert(MAX_ARGS_COUNT > 0);
    assert(MAX_ARGS_COUNT <= 1024);
    
    assert(MAX_FUNCTION_NAME_BYTES < MAX_INPUT_SIZE_BYTES);
    assert(MAX_STACK_FRAMES * @sizeOf(parser.CollapsedStack) < MAX_INPUT_SIZE_BYTES);
    assert(@sizeOf(Frame) > 0);
    assert(@sizeOf(Config) > 0);
    assert(@sizeOf(parser.CollapsedStack) >= 16);
}
const parser = @import("flamegraph/parser.zig");
const perf_parser = @import("flamegraph/parser/perf_parser.zig");

const FlameGraphError = error{
    InvalidArgumentCount,
    TooManyArguments,
    HelpRequested,
    InvalidArguments,
    UnsupportedFormat,
    EmptyInputFile,
    StandardInputNotSupported,
    StandardOutputNotSupported,
    OutputTooLarge,
    InvalidInputData,
    MemoryAllocationFailed,
};

const ValidationError = error{
    InvalidConfiguration,
    InvalidStackFormat,
    InvalidFunctionName,
    FrameValueOutOfRange,
    StackDepthExceeded,
};

const AllErrors = FlameGraphError || ValidationError || std.fs.File.OpenError || std.fs.File.WriteError || std.fs.File.ReadError || std.mem.Allocator.Error || std.fmt.ParseIntError;

const Config = struct {
    input_file_path: []const u8,
    output_file_path: []const u8,
    input_format: []const u8,
    image_width_px: u32,
    frame_height_px: u32,
    font_size_px: f32,
    min_width_px: f32,
    colors: []const u8,
    inverted: bool,
    title: []const u8,
    subtitle: []const u8,

    fn init_default() Config {
        return Config{
            .input_file_path = "-",
            .output_file_path = "-",
            .input_format = "perf",
            .image_width_px = 1200,
            .frame_height_px = 16,
            .font_size_px = 12.0,
            .min_width_px = 0.1,
            .colors = "hot",
            .inverted = false,
            .title = "Flame Graph",
            .subtitle = "",
        };
    }

    fn validate(self: Config) void {
        assert(self.image_width_px > 0);
        assert(self.image_width_px <= 10000);
        assert(self.frame_height_px > 0);
        assert(self.frame_height_px <= 100);
        assert(self.font_size_px > 0.0);
        assert(self.font_size_px <= 100.0);
        assert(self.min_width_px >= 0.0);
        assert(self.min_width_px <= @as(f32, @floatFromInt(self.image_width_px)));
        assert(self.input_file_path.len > 0);
        assert(self.input_file_path.len <= 1024);
        assert(self.output_file_path.len > 0);
        assert(self.output_file_path.len <= 1024);
        assert(self.input_format.len > 0);
        assert(self.input_format.len <= 64);
        
        assert(self.frame_height_px * 100 <= self.image_width_px);
        assert(self.font_size_px <= @as(f32, @floatFromInt(self.frame_height_px)));
    }
};

const Frame = struct {
    name: []const u8,
    value: f64,
    children: std.StringHashMap(*Frame),

    fn validate(self: Frame) void {
        assert(self.name.len > 0);
        assert(self.name.len <= MAX_FUNCTION_NAME_BYTES);
        assert(self.value >= 0.0);
        assert(self.value <= 1000000000.0);
        
        var total_child_value: f64 = 0.0;
        var children_iterator = self.children.iterator();
        while (children_iterator.next()) |entry| {
            const child_Frame = entry.value_ptr.*;
            assert(child_Frame.value >= 0.0);
            total_child_value += child_Frame.value;
        }
        
        if (self.children.count() > 0) {
            assert(total_child_value <= self.value);
        }
    }
};

pub fn main() !void {
    var allocator = std.heap.page_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    
    if (args.len > MAX_ARGS_COUNT) {
        return error.TooManyArguments;
    }
    
    if (args.len > 1 and std.mem.eql(u8, args[1], "--help")) {
        try showHelp();
        return;
    }
    
    if (args.len < 2) {
        std.debug.print("zflame: flamegraph generator\n", .{});
        std.debug.print("Usage: zflame [options] input.txt\n", .{});
        return;
    }
    
    try executeFlameGraphGeneration(&allocator, args[1..]);
}

fn executeFlameGraphGeneration(allocator: *std.mem.Allocator, args: [][:0]u8) !void {
    const string_args = convertArgsToConstSlices(args);
    const config = try parseCommandLineArgs(string_args);
    config.validate();
    
    try processInputAndGenerateFlameGraph(allocator, config);
}

fn convertArgsToConstSlices(args: [][:0]u8) [][]const u8 {
    const result: [][]const u8 = @ptrCast(args);
    return result;
}

fn processInputAndGenerateFlameGraph(allocator: *std.mem.Allocator, config: Config) !void {
    var input_buffer: [MAX_INPUT_SIZE_BYTES]u8 = undefined;
    const input_data = try readInputFileWithValidation(&input_buffer, config.input_file_path);
    
    var collapsed_stacks_buffer: [MAX_COLLAPSED_STACKS]parser.CollapsedStack = undefined;
    const collapsed_stacks = try parseInputByFormatWithValidation(allocator, input_data, config.input_format, &collapsed_stacks_buffer);
    defer freeTracesWithValidation(allocator, collapsed_stacks);
    
    var root_frame = try buildFlameGraphFromStacksWithValidation(allocator, collapsed_stacks);
    defer freeFrameWithValidation(allocator, &root_frame);
    
    try generateSvgOutputWithValidation(allocator, &root_frame, config);
    
    std.debug.print("Flame graph generated successfully: {s}\n", .{config.output_file_path});
}

fn parseCommandLineArgs(args: [][]const u8) AllErrors!Config {
    assert(args.len <= MAX_ARGS_COUNT);
    
    var config = Config.init_default();
    var current_index: usize = 0;
    
    while (current_index < args.len) {
        const current_arg = args[current_index];
        assert(current_arg.len > 0);
        
        if (isFlag(current_arg, "--width")) {
            current_index = try consumeFlagValue(args, current_index, &config.image_width_px);
        } else if (isFlag(current_arg, "--height")) {
            current_index = try consumeFlagValue(args, current_index, &config.frame_height_px);
        } else if (isFlag(current_arg, "--colors")) {
            current_index = try consumeStringFlag(args, current_index, &config.colors);
        } else if (std.mem.eql(u8, current_arg, "--inverted")) {
            config.inverted = true;
            current_index += 1;
        } else if (isFlag(current_arg, "--title")) {
            current_index = try consumeStringFlag(args, current_index, &config.title);
        } else if (isFlag(current_arg, "--subtitle")) {
            current_index = try consumeStringFlag(args, current_index, &config.subtitle);
        } else if (isFlag(current_arg, "--output")) {
            current_index = try consumeStringFlag(args, current_index, &config.output_file_path);
        } else if (isFlag(current_arg, "--input")) {
            current_index = try consumeStringFlag(args, current_index, &config.input_file_path);
        } else if (isFlag(current_arg, "--format")) {
            current_index = try consumeStringFlag(args, current_index, &config.input_format);
        } else {
            if (std.mem.eql(u8, config.input_file_path, "-")) {
                config.input_file_path = current_arg;
                current_index += 1;
            } else {
                return FlameGraphError.InvalidArguments;
            }
        }
    }
    
    return config;
}

fn isFlag(arg: []const u8, flag_name: []const u8) bool {
    assert(arg.len > 0);
    assert(flag_name.len > 0);
    return std.mem.eql(u8, arg, flag_name);
}

fn consumeFlagValue(args: [][]const u8, current_index: usize, output: *u32) AllErrors!usize {
    assert(current_index < args.len);
    
    const value_index = current_index + 1;
    if (value_index >= args.len) {
        return FlameGraphError.InvalidArguments;
    }
    
    const value_string = args[value_index];
    assert(value_string.len > 0);
    
    const parsed_value = try parsePositiveInteger(value_string);
    output.* = parsed_value;
    
    return value_index + 1;
}

fn consumeStringFlag(args: [][]const u8, current_index: usize, output: *[]const u8) AllErrors!usize {
    assert(current_index < args.len);
    
    const value_index = current_index + 1;
    if (value_index >= args.len) {
        return FlameGraphError.InvalidArguments;
    }
    
    const value_string = args[value_index];
    assert(value_string.len > 0);
    
    output.* = value_string;
    return value_index + 1;
}

fn showHelp() !void {
    const stdout = std.io.getStdOut().writer();
    const usage =
        \\ USAGE: zflame [options] input.txt > graph.svg
        \\ Options:
        \\   --help            Show this help message
        \\   --width NUM       Width of the SVG image (default 1200)
        \\   --height NUM      Height of each Frame (default 16)
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

fn parsePositiveInteger(input_string: []const u8) AllErrors!u32 {
    assert(input_string.len > 0);
    assert(input_string.len <= 10);
    
    const parsed_value = try std.fmt.parseInt(u32, input_string, 10);
    assert(parsed_value > 0);
    assert(parsed_value <= 1000000);
    
    return parsed_value;
}

fn readInputFileWithValidation(buffer: []u8, file_path: []const u8) AllErrors![]u8 {
    assert(buffer.len > 0);
    assert(file_path.len > 0);
    assert(buffer.len == MAX_INPUT_SIZE_BYTES);
    assert(file_path.len > 0);
    assert(file_path.len <= 1024);
    
    if (std.mem.eql(u8, file_path, "-")) {
        return error.StandardInputNotSupported;
    }
    
    const file = std.fs.cwd().openFile(file_path, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("Error: Input file not found: {s}\n", .{file_path});
            return err;
        },
        error.AccessDenied => {
            std.debug.print("Error: Access denied to file: {s}\n", .{file_path});
            return err;
        },
        else => return err,
    };
    defer file.close();
    
    const bytes_read = try file.readAll(buffer);
    assert(bytes_read <= MAX_INPUT_SIZE_BYTES);
    assert(bytes_read <= buffer.len);
    
    if (bytes_read == 0) {
        return FlameGraphError.EmptyInputFile;
    }
    
    const result = buffer[0..bytes_read];
    assert(result.len == bytes_read);
    assert(result.len > 0);
    return result;
}

fn parseInputByFormatWithValidation(
    allocator: *std.mem.Allocator,
    input_data: []const u8,
    format: []const u8,
    output_buffer: []parser.CollapsedStack,
) AllErrors![]parser.CollapsedStack {
    assert(input_data.len > 0);
    assert(format.len > 0);
    assert(output_buffer.len > 0);
    assert(input_data.len > 0);
    assert(input_data.len <= MAX_INPUT_SIZE_BYTES);
    assert(format.len > 0);
    assert(format.len <= 64);
    assert(output_buffer.len == MAX_COLLAPSED_STACKS);
    
    if (std.mem.eql(u8, format, "perf")) {
        const perf = perf_parser.PerfParser.init();
        const result = try perf.parse_to_buffer(allocator, input_data, output_buffer);
        assert(result.len > 0);
        assert(result.len <= MAX_COLLAPSED_STACKS);
        assert(result.len <= output_buffer.len);
        
        for (result) |stack| {
            stack.validate();
        }
        
        return result;
    } else {
        std.debug.print("Error: Unsupported input format: {s}\n", .{format});
        std.debug.print("Supported formats: perf\n", .{});
        return FlameGraphError.UnsupportedFormat;
    }
}

fn freeTracesWithValidation(allocator: *std.mem.Allocator, traces: []parser.CollapsedStack) void {
    assert(traces.len > 0);
    assert(traces.len <= MAX_COLLAPSED_STACKS);
    
    for (traces) |trace| {
        trace.validate();
        if (trace.stack.len > 0) {
            allocator.free(trace.stack);
        }
    }
}

fn buildFlameGraphFromStacksWithValidation(
    allocator: *std.mem.Allocator,
    collapsed_stacks: []const parser.CollapsedStack,
) AllErrors!Frame {
    assert(collapsed_stacks.len > 0);
    assert(collapsed_stacks.len <= MAX_COLLAPSED_STACKS);
    assert(collapsed_stacks.len > 0);
    assert(collapsed_stacks.len <= MAX_COLLAPSED_STACKS);
    
    var root = Frame{
        .name = "root",
        .value = 0.0,
        .children = std.StringHashMap(*Frame).init(allocator.*),
    };
    
    var processed_stacks: usize = 0;
    for (collapsed_stacks) |collapsed_stack| {
        collapsed_stack.validate();
        
        const sample_value: f64 = @floatFromInt(collapsed_stack.count);
        assert(sample_value > 0.0);
        assert(sample_value <= 1000000000.0);
        
        const old_root_value = root.value;
        try addStackToFlameGraphWithValidation(allocator, &root, collapsed_stack.stack, sample_value);
        assert(root.value > old_root_value);
        
        processed_stacks += 1;
    }
    
    assert(processed_stacks == collapsed_stacks.len);
    root.validate();
    assert(root.value > 0.0);
    return root;
}

// Builds the hierarchical flame graph structure from semicolon-separated stack strings.
// Each function in the call stack becomes a node, with sample counts accumulated
// at leaf nodes and propagated up the tree for proper flame graph rendering.
fn addStackToFlameGraphWithValidation(
    allocator: *std.mem.Allocator,
    root: *Frame,
    stack_str: []const u8,
    sample_value: f64,
) AllErrors!void {
    assert(stack_str.len > 0);
    assert(sample_value > 0.0);
    assert(stack_str.len > 0);
    assert(stack_str.len <= 4096);
    assert(sample_value > 0.0);
    assert(sample_value <= 1000000000.0);
    root.validate();
    
    var stack_iterator = std.mem.splitScalar(u8, stack_str, ';');
    var current_Frame = root;
    
    while (stack_iterator.next()) |func_name| {
        if (func_name.len == 0) continue;
        assert(func_name.len <= MAX_FUNCTION_NAME_BYTES);
        
        const child_Frame = current_Frame.children.get(func_name) orelse blk: {
            const new_Frame = try allocator.create(Frame);
            initFrameInPlaceWithValidation(new_Frame, func_name, allocator);
            try current_Frame.children.put(func_name, new_Frame);
            break :blk new_Frame;
        };
        child_Frame.validate();
        current_Frame = child_Frame;
    }
    
    const old_value = current_Frame.value;
    current_Frame.value += sample_value;
    assert(current_Frame.value > old_value);
    
    const old_root_value = root.value;
    root.value += sample_value;
    assert(root.value > old_root_value);
}

fn initFrameInPlaceWithValidation(
    frame: *Frame,
    name: []const u8,
    allocator: *std.mem.Allocator,
) void {
    assert(name.len > 0);
    assert(name.len <= MAX_FUNCTION_NAME_BYTES);
    
    frame.* = Frame{
        .name = name,
        .value = 0.0,
        .children = std.StringHashMap(*Frame).init(allocator.*),
    };
    
    frame.validate();
    assert(frame.children.count() == 0);
}

fn freeFrameWithValidation(allocator: *std.mem.Allocator, frame: *Frame) void {
    frame.validate();
    
    var children_iterator = frame.children.iterator();
    while (children_iterator.next()) |entry| {
        const child_frame = entry.value_ptr.*;
        child_frame.validate();
        freeFrameWithValidation(allocator, child_frame);
        allocator.destroy(child_frame);
    }
    frame.children.deinit();
}

fn createOrOpenOutputFile(file_path: []const u8) AllErrors!std.fs.File {
    assert(file_path.len > 0);
    assert(file_path.len <= 1024);
    
    return std.fs.cwd().createFile(file_path, .{ .read = false, .truncate = true }) catch {
        const existing_file = std.fs.cwd().openFile(file_path, .{ .mode = .write_only }) catch |err| {
            std.debug.print("Error: Cannot write to output file: {s}\n", .{file_path});
            return err;
        };
        try existing_file.setEndPos(0);
        return existing_file;
    };
}

fn generateSvgOutputWithValidation(
    allocator: *std.mem.Allocator,
    root: *Frame,
    config: Config,
) AllErrors!void {
    _ = allocator;
    root.validate();
    config.validate();
    
    if (std.mem.eql(u8, config.output_file_path, "-")) {
        return FlameGraphError.StandardOutputNotSupported;
    }
    
    const output_file = try createOrOpenOutputFile(config.output_file_path);
    defer output_file.close();
    const writer = output_file.writer();

    // Calculate the maximum depth of the flame graph.
    //const depth_max = 20; // Placeholder; you may want to calculate this

    // Write SVG header.
    try writer.print(
        \\<?xml version="1.0" standalone="no"?>
        \\<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN"
        \\  "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
        \\<svg version="1.1" width="{d}" height="{d}" xmlns="http://www.w3.org/2000/svg">
        \\\n
    ,
        .{ config.image_width_px, calculateImageHeightPx(config) },
    );

    // Write Frames recursively.
    try writeFrameRecursively(
        writer,
        root,
        0,
        0.0,
        @floatFromInt(config.image_width_px - 2 * 10),
        root.value,
        config,
    );

    // Write SVG footer.
    try writeSvgFooter(writer);
}

fn writeSvgHeader(writer: anytype, width_px: u32, height_px: u32) !void {
    assert(width_px > 0);
    assert(height_px > 0);
    
    try writer.print(
        \\<?xml version="1.0" standalone="no"?>
        \\<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN"
        \\  "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
        \\<svg version="1.1" width="{d}" height="{d}" xmlns="http://www.w3.org/2000/svg">
        \\
    ,
        .{ width_px, height_px },
    );
}

fn writeSvgFooter(writer: anytype) !void {
    try writer.print("</svg>\n", .{});
}

fn calculateImageHeightPx(config: Config) u32 {
    const font_size_int: u32 = @intFromFloat(config.font_size_px);
    assert(font_size_int > 0);
    assert(font_size_int <= 100);
    
    const padding_top_px: u32 = font_size_int * 3;
    const padding_bottom_px: u32 = font_size_int * 2 + 10;
    const max_depth = 100;
    const content_height_px = (max_depth + 1) * config.frame_height_px;
    
    const total_height_px = content_height_px + padding_top_px + padding_bottom_px;
    assert(total_height_px > 0);
    assert(total_height_px <= 10000);
    
    return total_height_px;
}

fn writeFrameRecursively(
    writer: anytype,
    frame: *Frame,
    depth: u32,
    x_offset: f64,
    total_width: f64,
    root_value: f64,
    config: Config,
) AllErrors!void {
    assert(frame.value >= 0.0);
    assert(depth <= 100);
    assert(x_offset >= 0.0);
    assert(total_width > 0.0);
    assert(root_value > 0.0);
    config.validate();
    const width_px = (frame.value / root_value) * total_width;
    const x_px = x_offset;
    const y_px = calculateYPositionPx(depth, config);
    const font_size_px = config.font_size_px;
    const height_px: f64 = @floatFromInt(config.frame_height_px);
    
    assert(width_px >= 0.0);
    assert(x_px >= 0.0);
    assert(y_px >= 0.0);
    assert(height_px > 0.0);
    
    if (width_px < config.min_width_px) return;
    
    try drawFrameRectangle(writer, x_px, y_px, width_px, height_px, frame.name, config.colors);
    try drawFrameText(writer, x_px, y_px, width_px, height_px, font_size_px, frame.name);
    
    try writeChildrenFrames(writer, frame, depth, x_offset, total_width, root_value, config);
}

fn drawFrameRectangle(
    writer: anytype,
    x_px: f64,
    y_px: f64,
    width_px: f64,
    height_px: f64,
    frame_name: []const u8,
    color_palette: []const u8,
) !void {
    assert(x_px >= 0.0);
    assert(y_px >= 0.0);
    assert(width_px > 0.0);
    assert(height_px > 0.0);
    assert(frame_name.len > 0);
    
    const color = getFrameColor(frame_name, color_palette);
    try writer.print(
        "<rect x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\" fill=\"{s}\" stroke=\"none\" />\n",
        .{ x_px, y_px, width_px, height_px, color },
    );
}

fn drawFrameText(
    writer: anytype,
    x_px: f64,
    y_px: f64,
    width_px: f64,
    height_px: f64,
    font_size_px: f32,
    frame_name: []const u8,
) !void {
    assert(x_px >= 0.0);
    assert(y_px >= 0.0);
    assert(width_px > 0.0);
    assert(height_px > 0.0);
    assert(font_size_px > 0.0);
    assert(frame_name.len > 0);
    
    const text_x_px = x_px + 3.0;
    const text_y_px = y_px + height_px / 2.0 + font_size_px / 2.0 - 2.0;
    
    if (width_px < font_size_px) return;
    
    try writer.print(
        "<text x=\"{d:.2}\" y=\"{d:.2}\" font-size=\"{d:.1}px\" font-family=\"monospace\" fill=\"black\">{s}</text>\n",
        .{ text_x_px, text_y_px, font_size_px, frame_name },
    );
}

fn writeChildrenFrames(
    writer: anytype,
    frame: *Frame,
    depth: u32,
    x_offset: f64,
    total_width: f64,
    root_value: f64,
    config: Config,
) AllErrors!void {
    assert(frame.value >= 0.0);
    assert(depth <= 100);
    assert(x_offset >= 0.0);
    assert(total_width > 0.0);
    assert(root_value > 0.0);
    
    var child_x_offset = x_offset;
    var children_iterator = frame.children.iterator();
    
    while (children_iterator.next()) |entry| {
        const child_frame = entry.value_ptr.*;
        const child_width_px = (child_frame.value / root_value) * total_width;
        
        assert(child_width_px >= 0.0);
        
        try writeFrameRecursively(
            writer,
            child_frame,
            depth + 1,
            child_x_offset,
            child_width_px,
            root_value,
            config,
        );
        
        child_x_offset += child_width_px;
    }
}

fn calculateYPositionPx(depth: u32, config: Config) f64 {
    assert(depth <= 100);
    config.validate();
    
    const font_size = config.font_size_px;
    const depth_f64: f64 = @floatFromInt(depth);
    const frame_height_f64: f64 = @floatFromInt(config.frame_height_px);
    
    if (config.inverted) {
        const padding_top = font_size * 3.0;
        const y_pos = padding_top + depth_f64 * frame_height_f64;
        assert(y_pos >= 0.0);
        return y_pos;
    } else {
        const image_height_f64: f64 = @floatFromInt(calculateImageHeightPx(config));
        const padding_bottom = font_size * 2.0 + 10.0;
        const offset_from_bottom = (depth_f64 + 1.0) * frame_height_f64;
        const y_pos = image_height_f64 - padding_bottom - offset_from_bottom;
        assert(y_pos >= 0.0);
        return y_pos;
    }
}

fn getTotalChildValue(frame: *const Frame) f64 {
    assert(frame.value >= 0.0);
    
    var total_value: f64 = 0.0;
    var children_iterator = frame.children.iterator();
    
    while (children_iterator.next()) |entry| {
        const child_frame = entry.value_ptr.*;
        assert(child_frame.value >= 0.0);
        total_value += child_frame.value;
    }
    
    assert(total_value >= 0.0);
    return total_value;
}

fn getFrameColor(frame_name: []const u8, palette: []const u8) []const u8 {
    assert(frame_name.len > 0);
    assert(palette.len > 0);
    
    const hash_value = calculateStringHash(frame_name);
    
    if (std.mem.eql(u8, palette, "hot")) {
        const color_index = hash_value % 6;
        return switch (color_index) {
            0 => "#ff6b6b",
            1 => "#4ecdc4",
            2 => "#45b7d1",
            3 => "#96ceb4",
            4 => "#feca57",
            5 => "#ff9ff3",
            else => "#ff6b6b",
        };
    } else {
        return "#ff6b6b";
    }
}

// djb2 hash algorithm for deterministic color assignment.
// This provides consistent colors for the same function names
// across different flame graph generations, improving readability.
fn calculateStringHash(str: []const u8) u32 {
    assert(str.len > 0);
    
    var hash: u32 = 5381;
    for (str) |c| {
        hash = ((hash << 5) +% hash) +% c;
    }
    return hash;
}
