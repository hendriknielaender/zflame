const std = @import("std");
const assert = std.debug.assert;
const collapse_mod = @import("collapse.zig");
const flamegraph_mod = @import("flamegraph.zig");

// Export modules for library use
pub const collapse = collapse_mod;
pub const flamegraph = flamegraph_mod;

// Export collapse types
pub const perf = @import("collapse/perf.zig");
pub const dtrace = @import("collapse/dtrace.zig");
pub const sample = @import("collapse/sample.zig");

const MAX_INPUT_SIZE_BYTES = 1024 * 1024;
const MAX_ARGS_COUNT = 32;
const MAX_COLLAPSED_STACKS_COUNT = 4096;
const MAX_ARG_LENGTH = 512;

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
    ArgumentTooLong,
    StreamTooLong,
};

const AllErrors = FlameGraphError || std.fs.File.OpenError || std.fs.File.WriteError || std.fs.File.ReadError || std.fmt.ParseIntError || std.io.FixedBufferStream([]const u8).Reader.Error || error{ InvalidData, OutOfMemory, TooManyChildren };

const Config = struct {
    input_file_path: []const u8,
    output_file_path: []const u8,
    input_format: []const u8,
    flamegraph_options: flamegraph_mod.Options,

    fn init_default() Config {
        return Config{
            .input_file_path = "-",
            .output_file_path = "-",
            .input_format = "perf",
            .flamegraph_options = flamegraph_mod.Options{},
        };
    }

    fn validate(self: Config) void {
        assert(self.input_file_path.len > 0);
        assert(self.input_file_path.len <= 1024);
        assert(self.output_file_path.len > 0);
        assert(self.output_file_path.len <= 1024);
        assert(self.input_format.len > 0);
        assert(self.input_format.len <= 64);

        self.flamegraph_options.validate();
    }
};

pub fn main() !void {
    // Use stack-allocated arguments buffer
    var args_buffer: [MAX_ARGS_COUNT][MAX_ARG_LENGTH]u8 = undefined;
    var args_ptrs: [MAX_ARGS_COUNT][]u8 = undefined;
    var args_count: usize = 0;

    // Parse command line arguments without allocation
    var arg_iter = std.process.args();
    while (arg_iter.next()) |arg| {
        if (args_count >= MAX_ARGS_COUNT) {
            return error.TooManyArguments;
        }
        if (arg.len >= MAX_ARG_LENGTH) {
            return error.ArgumentTooLong;
        }
        @memcpy(args_buffer[args_count][0..arg.len], arg);
        args_ptrs[args_count] = args_buffer[args_count][0..arg.len];
        args_count += 1;
    }

    const args = args_ptrs[0..args_count];

    if (args.len > 1 and std.mem.eql(u8, args[1], "--help")) {
        try show_help();
        return;
    }

    // Allow running with no arguments (stdin mode)
    if (args.len == 1) {
        // No arguments - use stdin/stdout defaults
        execute_flame_graph_generation(&[_][]u8{}) catch |err| {
            const stderr = std.io.getStdErr().writer();
            stderr.print("Error: {}\n", .{err}) catch {};
            std.process.exit(1);
        };
        return;
    }

    execute_flame_graph_generation(args[1..]) catch |err| {
        const stderr = std.io.getStdErr().writer();
        stderr.print("Error in main: {}\n", .{err}) catch {};
        std.process.exit(1);
    };
}

fn execute_flame_graph_generation(args: [][]u8) !void {
    assert(args.len <= MAX_ARGS_COUNT);

    const string_args = convert_args_to_const_slices(args);
    assert(string_args.len == args.len);

    const config = try parse_command_line_args(string_args);
    config.validate();

    try process_input_and_generate_flame_graph(config);
}

fn convert_args_to_const_slices(args: [][]u8) [][]const u8 {
    assert(args.len <= MAX_ARGS_COUNT);

    const result: [][]const u8 = @ptrCast(args);

    assert(result.len == args.len);
    return result;
}

fn process_input_and_generate_flame_graph(config: Config) !void {
    config.validate();

    // Read input file using stack-allocated buffer.
    var input_buffer: [MAX_INPUT_SIZE_BYTES]u8 = undefined;
    const input_data = try read_input_file(&input_buffer, config.input_file_path);
    assert(input_data.len > 0);
    assert(input_data.len <= MAX_INPUT_SIZE_BYTES);

    // Collapse stacks based on input format using stack-allocated storage.
    var collapsed_stacks_storage: [MAX_COLLAPSED_STACKS_COUNT]collapse_mod.CollapsedStack = undefined;
    const collapsed_stacks_count = try collapse_input_data(&collapsed_stacks_storage, input_data, config.input_format);
    const collapsed_stacks = collapsed_stacks_storage[0..collapsed_stacks_count];

    // Generate flame graph.
    try generate_flame_graph(collapsed_stacks, config);

    // Only print success message if not writing to stdout
    if (!std.mem.eql(u8, config.output_file_path, "-")) {
        std.debug.print("Flame graph generated successfully: {s}\n", .{config.output_file_path});
    }
}

fn parse_command_line_args(args: [][]const u8) AllErrors!Config {
    assert(args.len <= MAX_ARGS_COUNT);

    var config = Config.init_default();
    var current_index: usize = 0;

    while (current_index < args.len) {
        const current_arg = args[current_index];
        assert(current_arg.len > 0);

        if (is_flag(current_arg, "--width")) {
            const width = try consume_flag_value_u32(args, &current_index);
            config.flamegraph_options.image_width = width;
        } else if (is_flag(current_arg, "--height")) {
            const height = try consume_flag_value_u32(args, &current_index);
            config.flamegraph_options.frame_height = height;
        } else if (is_flag(current_arg, "--colors")) {
            const palette_str = try consume_string_flag(args, &current_index);
            config.flamegraph_options.palette = flamegraph_mod.ColorPalette.from_string(palette_str) catch flamegraph_mod.ColorPalette.default();
        } else if (std.mem.eql(u8, current_arg, "--inverted")) {
            config.flamegraph_options.direction = .inverted;
            current_index += 1;
        } else if (is_flag(current_arg, "--title")) {
            config.flamegraph_options.title = try consume_string_flag(args, &current_index);
        } else if (is_flag(current_arg, "--subtitle")) {
            config.flamegraph_options.subtitle = try consume_string_flag(args, &current_index);
        } else if (is_flag(current_arg, "--output")) {
            config.output_file_path = try consume_string_flag(args, &current_index);
        } else if (is_flag(current_arg, "--input")) {
            config.input_file_path = try consume_string_flag(args, &current_index);
        } else if (is_flag(current_arg, "--format")) {
            config.input_format = try consume_string_flag(args, &current_index);
        } else if (is_flag(current_arg, "--min-width")) {
            const min_width_str = try consume_string_flag(args, &current_index);
            config.flamegraph_options.min_width = try std.fmt.parseFloat(f64, min_width_str);
        } else if (is_flag(current_arg, "--font-size")) {
            const font_size = try consume_flag_value_u32(args, &current_index);
            config.flamegraph_options.font_size = font_size;
        } else if (std.mem.eql(u8, current_arg, "--hash")) {
            config.flamegraph_options.hash_colors = true;
            current_index += 1;
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

fn is_flag(arg: []const u8, flag_name: []const u8) bool {
    assert(arg.len > 0);
    assert(flag_name.len > 0);
    // Support both --flag and --flag=value syntax
    return std.mem.eql(u8, arg, flag_name) or std.mem.startsWith(u8, arg, flag_name) and arg.len > flag_name.len and arg[flag_name.len] == '=';
}

fn consume_flag_value_u32(args: [][]const u8, current_index: *usize) AllErrors!u32 {
    assert(current_index.* < args.len);

    const current_arg = args[current_index.*];

    // Check if this is --flag=value syntax
    if (std.mem.indexOf(u8, current_arg, "=")) |eq_pos| {
        const value_string = current_arg[eq_pos + 1 ..];
        if (value_string.len == 0) {
            return FlameGraphError.InvalidArguments;
        }
        const parsed_value = try std.fmt.parseInt(u32, value_string, 10);
        current_index.* += 1;
        return parsed_value;
    }

    // Otherwise use --flag value syntax
    const value_index = current_index.* + 1;
    if (value_index >= args.len) {
        return FlameGraphError.InvalidArguments;
    }

    const value_string = args[value_index];
    assert(value_string.len > 0);

    const parsed_value = try std.fmt.parseInt(u32, value_string, 10);
    current_index.* = value_index + 1;

    return parsed_value;
}

fn consume_string_flag(args: [][]const u8, current_index: *usize) AllErrors![]const u8 {
    assert(current_index.* < args.len);

    const current_arg = args[current_index.*];

    // Check if this is --flag=value syntax
    if (std.mem.indexOf(u8, current_arg, "=")) |eq_pos| {
        const value_string = current_arg[eq_pos + 1 ..];
        if (value_string.len == 0) {
            return FlameGraphError.InvalidArguments;
        }
        current_index.* += 1;
        return value_string;
    }

    // Otherwise use --flag value syntax
    const value_index = current_index.* + 1;
    if (value_index >= args.len) {
        return FlameGraphError.InvalidArguments;
    }

    const value_string = args[value_index];
    assert(value_string.len > 0);

    current_index.* = value_index + 1;
    return value_string;
}

fn show_help() !void {
    const stdout = std.io.getStdOut().writer();
    const usage =
        \\ USAGE: zflame [options] input.txt > graph.svg
        \\ 
        \\ Options:
        \\   --help            Show this help message
        \\   --width NUM       Width of the SVG image (default: fluid)
        \\   --height NUM      Height of each frame (default 16)
        \\   --colors PALETTE  Color palette: hot, mem, io, red, green, blue, etc.
        \\   --inverted        Generate an inverted flame graph (icicle graph)
        \\   --title TEXT      Title text for the flame graph
        \\   --subtitle TEXT   Subtitle text for the flame graph
        \\   --output FILE     Output file (default standard output)
        \\   --input FILE      Input file (default positional argument)
        \\   --format FORMAT   Input format: perf, dtrace, sample, vtune, xctrace, recursive, guess (default perf)
        \\   --min-width NUM   Minimum width to show frames (default 0.1)
        \\   --font-size NUM   Font size in pixels (default 12)
        \\   --hash            Use hash-based deterministic colors
        \\ 
        \\ Examples:
        \\   zflame --colors hot data.perf > flame.svg
        \\   zflame --inverted --title "My Profile" data.perf > icicle.svg
        \\   zflame --width 1600 --font-size 14 data.perf > big_flame.svg
        \\
    ;
    try stdout.print(usage, .{});
}

fn read_input_file(buffer: *[MAX_INPUT_SIZE_BYTES]u8, file_path: []const u8) AllErrors![]u8 {
    assert(file_path.len > 0);
    assert(file_path.len <= 1024);

    if (std.mem.eql(u8, file_path, "-")) {
        // Read from stdin
        const stdin = std.io.getStdIn().reader();
        const bytes_read = try stdin.readAll(buffer);
        if (bytes_read == 0) {
            return error.EmptyInputFile;
        }
        assert(bytes_read <= buffer.len);
        return buffer[0..bytes_read];
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

    if (bytes_read == 0) {
        return FlameGraphError.EmptyInputFile;
    }

    assert(bytes_read > 0);
    return buffer[0..bytes_read];
}

fn collapse_input_data(
    storage: *[MAX_COLLAPSED_STACKS_COUNT]collapse_mod.CollapsedStack,
    input_data: []const u8,
    format: []const u8,
) AllErrors!usize {
    assert(input_data.len > 0);
    assert(input_data.len <= MAX_INPUT_SIZE_BYTES);
    assert(format.len > 0);
    assert(format.len <= 64);

    if (std.mem.eql(u8, format, "perf")) {
        return collapse_perf_data(storage, input_data);
    } else if (std.mem.eql(u8, format, "dtrace")) {
        return collapse_dtrace_data(storage, input_data);
    } else if (std.mem.eql(u8, format, "sample")) {
        return collapse_sample_data(storage, input_data);
    } else if (std.mem.eql(u8, format, "vtune")) {
        return collapse_vtune_data(storage, input_data);
    } else if (std.mem.eql(u8, format, "xctrace")) {
        return collapse_xctrace_data(storage, input_data);
    } else if (std.mem.eql(u8, format, "recursive")) {
        return collapse_recursive_data(storage, input_data);
    } else if (std.mem.eql(u8, format, "guess")) {
        return collapse_guess_data(storage, input_data);
    } else {
        std.debug.print("Error: Unsupported input format: {s}\n", .{format});
        std.debug.print("Supported formats: perf, dtrace, sample, vtune, xctrace, recursive, guess\n", .{});
        return FlameGraphError.UnsupportedFormat;
    }
}

fn collapse_perf_data(
    storage: *[MAX_COLLAPSED_STACKS_COUNT]collapse_mod.CollapsedStack,
    input_data: []const u8,
) AllErrors!usize {
    var folder = try collapse_mod.perf.Folder.init(.{});
    defer folder.deinit();

    var input_stream = std.io.fixedBufferStream(input_data);
    var output_buffer: [MAX_INPUT_SIZE_BYTES * 2]u8 = undefined; // Allow for expansion
    var output_stream = std.io.fixedBufferStream(&output_buffer);

    try folder.collapse(input_stream.reader(), output_stream.writer());

    // Parse the collapsed output into CollapsedStack structs.
    return parse_collapsed_output(storage, output_stream.getWritten());
}

fn parse_collapsed_output(
    storage: *[MAX_COLLAPSED_STACKS_COUNT]collapse_mod.CollapsedStack,
    collapsed_data: []const u8,
) AllErrors!usize {
    var result_count: usize = 0;

    // Static storage for stack strings (reuse input data space when possible)
    var stack_storage: [MAX_INPUT_SIZE_BYTES]u8 = undefined;
    var stack_storage_offset: usize = 0;

    var lines = std.mem.splitScalar(u8, collapsed_data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (result_count >= MAX_COLLAPSED_STACKS_COUNT) break;

        // Find the last space to separate stack from count.
        if (std.mem.lastIndexOf(u8, line, " ")) |last_space| {
            const stack_part = line[0..last_space];
            const count_part = line[last_space + 1 ..];

            if (stack_part.len > 0 and count_part.len > 0) {
                const count = std.fmt.parseInt(u64, count_part, 10) catch continue;

                // Copy stack to our storage
                if (stack_storage_offset + stack_part.len >= stack_storage.len) break;
                @memcpy(stack_storage[stack_storage_offset .. stack_storage_offset + stack_part.len], stack_part);

                storage[result_count] = collapse_mod.CollapsedStack{
                    .stack = stack_storage[stack_storage_offset .. stack_storage_offset + stack_part.len],
                    .count = count,
                };

                stack_storage_offset += stack_part.len;
                result_count += 1;
            }
        }
    }

    return result_count;
}

fn collapse_dtrace_data(
    storage: *[MAX_COLLAPSED_STACKS_COUNT]collapse_mod.CollapsedStack,
    input_data: []const u8,
) AllErrors!usize {
    var folder = try collapse_mod.dtrace.Folder.init(.{});
    defer folder.deinit();

    var input_stream = std.io.fixedBufferStream(input_data);
    var output_buffer: [MAX_INPUT_SIZE_BYTES * 2]u8 = undefined;
    var output_stream = std.io.fixedBufferStream(&output_buffer);

    try folder.collapse(input_stream.reader(), output_stream.writer());

    return parse_collapsed_output(storage, output_stream.getWritten());
}

fn collapse_sample_data(
    storage: *[MAX_COLLAPSED_STACKS_COUNT]collapse_mod.CollapsedStack,
    input_data: []const u8,
) AllErrors!usize {
    var folder = try collapse_mod.sample.Folder.init(.{});
    defer folder.deinit();

    var input_stream = std.io.fixedBufferStream(input_data);
    var output_buffer: [MAX_INPUT_SIZE_BYTES * 2]u8 = undefined;
    var output_stream = std.io.fixedBufferStream(&output_buffer);

    try folder.collapse(input_stream.reader(), output_stream.writer());

    return parse_collapsed_output(storage, output_stream.getWritten());
}

fn collapse_vtune_data(
    storage: *[MAX_COLLAPSED_STACKS_COUNT]collapse_mod.CollapsedStack,
    input_data: []const u8,
) AllErrors!usize {
    var folder = try collapse_mod.vtune.Folder.init(.{});
    defer folder.deinit();

    var input_stream = std.io.fixedBufferStream(input_data);
    var output_buffer: [MAX_INPUT_SIZE_BYTES * 2]u8 = undefined;
    var output_stream = std.io.fixedBufferStream(&output_buffer);

    try folder.collapse(input_stream.reader(), output_stream.writer());

    return parse_collapsed_output(storage, output_stream.getWritten());
}

fn collapse_xctrace_data(
    storage: *[MAX_COLLAPSED_STACKS_COUNT]collapse_mod.CollapsedStack,
    input_data: []const u8,
) AllErrors!usize {
    var folder = try collapse_mod.xctrace.Folder.init(.{});
    defer folder.deinit();

    var input_stream = std.io.fixedBufferStream(input_data);
    var output_buffer: [MAX_INPUT_SIZE_BYTES * 2]u8 = undefined;
    var output_stream = std.io.fixedBufferStream(&output_buffer);

    try folder.collapse(input_stream.reader(), output_stream.writer());

    return parse_collapsed_output(storage, output_stream.getWritten());
}

fn collapse_recursive_data(
    storage: *[MAX_COLLAPSED_STACKS_COUNT]collapse_mod.CollapsedStack,
    input_data: []const u8,
) AllErrors!usize {
    var folder = try collapse_mod.recursive.Folder.init(.{});
    defer folder.deinit();

    var input_stream = std.io.fixedBufferStream(input_data);
    var output_buffer: [MAX_INPUT_SIZE_BYTES * 2]u8 = undefined;
    var output_stream = std.io.fixedBufferStream(&output_buffer);

    try folder.collapse(input_stream.reader(), output_stream.writer());

    return parse_collapsed_output(storage, output_stream.getWritten());
}

fn collapse_guess_data(
    storage: *[MAX_COLLAPSED_STACKS_COUNT]collapse_mod.CollapsedStack,
    input_data: []const u8,
) AllErrors!usize {
    var folder = collapse_mod.guess.Folder.init(.{});
    defer folder.deinit();

    var input_stream = std.io.fixedBufferStream(input_data);
    var output_buffer: [MAX_INPUT_SIZE_BYTES * 2]u8 = undefined;
    var output_stream = std.io.fixedBufferStream(&output_buffer);

    try folder.collapse(input_stream.reader(), output_stream.writer());

    return parse_collapsed_output(storage, output_stream.getWritten());
}

fn generate_flame_graph(
    collapsed_stacks: []const collapse_mod.CollapsedStack,
    config: Config,
) AllErrors!void {
    if (collapsed_stacks.len == 0) {
        return;
    }

    var generator = flamegraph_mod.Generator.init(config.flamegraph_options);

    if (std.mem.eql(u8, config.output_file_path, "-")) {
        const stdout = std.io.getStdOut().writer();
        try generator.generate_from_collapsed(collapsed_stacks, stdout);
    } else {
        const output_file = try std.fs.cwd().createFile(config.output_file_path, .{});
        defer output_file.close();
        try generator.generate_from_collapsed(collapsed_stacks, output_file.writer());
    }
}
