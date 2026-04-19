const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const collapse_mod = @import("collapse.zig");
const flamegraph_mod = @import("flamegraph.zig");
const Io = std.Io;
const cli_log = if (builtin.is_test) struct {
    pub fn err(comptime _: []const u8, _: anytype) void {}
} else std.log.scoped(.cli);

// Export modules for library use.
pub const collapse = collapse_mod;
pub const flamegraph = flamegraph_mod;

// Export collapse types.
pub const perf = @import("collapse/perf.zig");
pub const dtrace = @import("collapse/dtrace.zig");
pub const sample = @import("collapse/sample.zig");

const MAX_INPUT_SIZE_BYTES = 1024 * 1024;
const MAX_ARGS_COUNT = 32;
const MAX_COLLAPSED_STACKS_COUNT = 4096;
const MAX_ARG_LENGTH = 512;
const CollapsedStack = collapse_mod.CollapsedStack;

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

const AllErrors = FlameGraphError ||
    Io.File.OpenError ||
    Io.File.Writer.Error ||
    Io.File.Reader.Error ||
    Io.Reader.StreamRemainingError ||
    Io.Reader.Error ||
    Io.Writer.Error ||
    std.fmt.ParseIntError ||
    error{ InvalidData, OutOfMemory, TooManyChildren };

const Config = struct {
    input_file_path: []const u8,
    output_file_path: []const u8,
    input_format: []const u8,
    flamegraph_options: flamegraph_mod.Options,

    fn init() Config {
        return Config{
            .input_file_path = "",
            .output_file_path = "-",
            .input_format = "",
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

const OptionSeen = struct {
    width: bool = false,
    height: bool = false,
    colors: bool = false,
    inverted: bool = false,
    title: bool = false,
    subtitle: bool = false,
    output: bool = false,
    min_width: bool = false,
    font_size: bool = false,
    hash: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // Use stack-allocated arguments buffer.
    var args_buffer: [MAX_ARGS_COUNT][MAX_ARG_LENGTH]u8 = undefined;
    var args_ptrs: [MAX_ARGS_COUNT][]u8 = undefined;
    var args_count: usize = 0;

    // Parse command line arguments without allocation on POSIX.
    var arg_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer arg_iter.deinit();

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

    if (args.len == 2 and is_help_arg(args[1])) {
        try show_help(io);
        return;
    }

    if (args.len == 1) {
        write_stderr(io, "Error: missing format and input path. Use --help for usage.\n", .{});
        std.process.exit(1);
        return;
    }

    execute_flame_graph_generation(io, args[1..]) catch |err| {
        if (!cli_error_reported(err)) {
            write_stderr(io, "Error in main: {}\n", .{err});
        }
        std.process.exit(1);
    };
}

fn execute_flame_graph_generation(io: Io, args: [][]u8) !void {
    assert(args.len <= MAX_ARGS_COUNT);

    const string_args = convert_args_to_const_slices(args);
    assert(string_args.len == args.len);

    const config = try parse_command_line_args(string_args);

    try process_input_and_generate_flame_graph(io, config);
}

fn convert_args_to_const_slices(args: [][]u8) [][]const u8 {
    assert(args.len <= MAX_ARGS_COUNT);

    const result: [][]const u8 = @ptrCast(args);

    assert(result.len == args.len);
    return result;
}

fn process_input_and_generate_flame_graph(io: Io, config: Config) !void {
    config.validate();

    // Read input file using stack-allocated buffer.
    var input_buffer: [MAX_INPUT_SIZE_BYTES]u8 = undefined;
    const input_data = try read_input_file(io, &input_buffer, config.input_file_path);
    assert(input_data.len > 0);
    assert(input_data.len <= MAX_INPUT_SIZE_BYTES);

    // Collapse stacks based on input format using stack-allocated storage.
    var collapsed_stacks_storage: [MAX_COLLAPSED_STACKS_COUNT]CollapsedStack = undefined;
    var collapsed_stack_bytes: [MAX_INPUT_SIZE_BYTES]u8 = undefined;
    const collapsed_stacks_count = try collapse_input_data(
        &collapsed_stacks_storage,
        &collapsed_stack_bytes,
        input_data,
        config.input_format,
    );
    const collapsed_stacks = collapsed_stacks_storage[0..collapsed_stacks_count];

    // Generate flame graph.
    try generate_flame_graph(io, collapsed_stacks, config);

    // Only print success message if not writing to stdout
    if (!std.mem.eql(u8, config.output_file_path, "-")) {
        std.debug.print("Flame graph generated successfully: {s}\n", .{config.output_file_path});
    }
}

fn parse_command_line_args(args: []const []const u8) AllErrors!Config {
    assert(args.len <= MAX_ARGS_COUNT);

    var config = Config.init();
    var seen = OptionSeen{};
    if (args.len == 0) {
        try validate_cli_config(config);
        return config;
    }

    config.input_format = try parse_format_arg(args[0]);

    var input_seen = false;
    var current_index: usize = 1;

    while (current_index < args.len) {
        const current_arg = args[current_index];
        assert(current_arg.len > 0);

        if (try parse_option_arg(&config, &seen, current_arg)) {
            if (input_seen) {
                cli_log.err("unexpected trailing option: {s}", .{current_arg});
                return FlameGraphError.InvalidArguments;
            }
            current_index += 1;
            continue;
        }

        try parse_positional_arg(&config, current_arg);
        input_seen = true;
        current_index += 1;
    }

    try validate_cli_config(config);
    return config;
}

fn parse_option_arg(config: *Config, seen: *OptionSeen, arg: []const u8) AllErrors!bool {
    assert(arg.len > 0);

    if (try option_value(arg, "--width")) |value| {
        try mark_option_seen(&seen.width, "--width");
        config.flamegraph_options.image_width = try parse_u32_option(value, "--width", 1, 10000);
        return true;
    } else if (try option_value(arg, "--height")) |value| {
        try mark_option_seen(&seen.height, "--height");
        config.flamegraph_options.frame_height = try parse_u32_option(value, "--height", 1, 100);
        return true;
    } else if (try option_value(arg, "--colors")) |value| {
        try mark_option_seen(&seen.colors, "--colors");
        config.flamegraph_options.palette = try parse_palette_option(value);
        return true;
    } else if (try option_value(arg, "--title")) |value| {
        try mark_option_seen(&seen.title, "--title");
        config.flamegraph_options.title = value;
        return true;
    } else if (try option_value(arg, "--subtitle")) |value| {
        try mark_option_seen(&seen.subtitle, "--subtitle");
        config.flamegraph_options.subtitle = value;
        return true;
    } else if (try option_value(arg, "--output")) |value| {
        try mark_option_seen(&seen.output, "--output");
        config.output_file_path = value;
        return true;
    } else if (try option_value(arg, "--min-width")) |value| {
        try mark_option_seen(&seen.min_width, "--min-width");
        config.flamegraph_options.min_width = try parse_min_width_option(value);
        return true;
    } else if (try option_value(arg, "--font-size")) |value| {
        try mark_option_seen(&seen.font_size, "--font-size");
        config.flamegraph_options.font_size = try parse_u32_option(value, "--font-size", 1, 100);
        return true;
    } else if (try option_present(arg, "--inverted")) {
        try mark_option_seen(&seen.inverted, "--inverted");
        config.flamegraph_options.direction = .inverted;
        return true;
    } else if (try option_present(arg, "--hash")) {
        try mark_option_seen(&seen.hash, "--hash");
        config.flamegraph_options.hash_colors = true;
        return true;
    } else if (is_option_like(arg)) {
        cli_log.err("unknown option: {s}", .{arg});
        return FlameGraphError.InvalidArguments;
    } else {
        return false;
    }
}

fn parse_positional_arg(config: *Config, arg: []const u8) AllErrors!void {
    assert(arg.len > 0);

    if (config.input_file_path.len == 0) {
        config.input_file_path = arg;
        return;
    }

    cli_log.err("unexpected positional argument: {s}", .{arg});
    return FlameGraphError.InvalidArguments;
}

fn option_value(arg: []const u8, option_name: []const u8) AllErrors!?[]const u8 {
    assert(arg.len > 0);
    assert(option_name.len > 0);

    if (!std.mem.startsWith(u8, arg, option_name)) {
        return null;
    }

    if (arg.len == option_name.len) {
        cli_log.err("use {s}=<value> syntax", .{option_name});
        return FlameGraphError.InvalidArguments;
    }

    if (arg[option_name.len] != '=') {
        return null;
    }

    const value = arg[option_name.len + 1 ..];
    if (value.len == 0) {
        cli_log.err("option requires a value: {s}", .{option_name});
        return FlameGraphError.InvalidArguments;
    }

    return value;
}

fn option_present(arg: []const u8, option_name: []const u8) AllErrors!bool {
    assert(arg.len > 0);
    assert(option_name.len > 0);

    if (std.mem.eql(u8, arg, option_name)) {
        return true;
    }

    if (std.mem.startsWith(u8, arg, option_name)) {
        if (arg.len > option_name.len and arg[option_name.len] == '=') {
            cli_log.err("option does not take a value: {s}", .{option_name});
            return FlameGraphError.InvalidArguments;
        }
    }

    return false;
}

fn mark_option_seen(seen: *bool, option_name: []const u8) AllErrors!void {
    assert(option_name.len > 0);

    if (seen.*) {
        cli_log.err("repeated option: {s}", .{option_name});
        return FlameGraphError.InvalidArguments;
    }

    seen.* = true;
}

fn parse_u32_option(
    value: []const u8,
    option_name: []const u8,
    min_value: u32,
    max_value: u32,
) AllErrors!u32 {
    assert(value.len > 0);
    assert(min_value <= max_value);

    const parsed = std.fmt.parseInt(u32, value, 10) catch {
        cli_log.err("invalid integer for {s}: {s}", .{ option_name, value });
        return FlameGraphError.InvalidArguments;
    };

    if (parsed < min_value or parsed > max_value) {
        cli_log.err("{s} must be between {d} and {d}", .{
            option_name,
            min_value,
            max_value,
        });
        return FlameGraphError.InvalidArguments;
    }

    return parsed;
}

fn parse_min_width_option(value: []const u8) AllErrors!f64 {
    assert(value.len > 0);

    const parsed = std.fmt.parseFloat(f64, value) catch {
        cli_log.err("invalid float for --min-width: {s}", .{value});
        return FlameGraphError.InvalidArguments;
    };

    if (!std.math.isFinite(parsed) or parsed < 0.0) {
        cli_log.err("--min-width must be a finite non-negative number", .{});
        return FlameGraphError.InvalidArguments;
    }

    return parsed;
}

fn parse_palette_option(value: []const u8) AllErrors!flamegraph_mod.ColorPalette {
    assert(value.len > 0);

    return flamegraph_mod.ColorPalette.from_string(value) catch {
        cli_log.err("unknown color palette: {s}", .{value});
        return FlameGraphError.InvalidArguments;
    };
}

fn parse_format_arg(value: []const u8) AllErrors![]const u8 {
    assert(value.len > 0);

    if (is_supported_format(value)) {
        return value;
    }

    cli_log.err("unsupported input format: {s}", .{value});
    cli_log.err("supported formats: perf, dtrace, sample, vtune, xctrace, recursive, guess", .{});
    return FlameGraphError.UnsupportedFormat;
}

fn validate_cli_config(config: Config) AllErrors!void {
    if (config.input_format.len == 0) {
        cli_log.err("missing format subcommand", .{});
        return FlameGraphError.InvalidArguments;
    }

    if (config.input_file_path.len == 0) {
        cli_log.err("missing input path. Use '-' to read standard input", .{});
        return FlameGraphError.InvalidArguments;
    }

    config.validate();
}

fn is_supported_format(format: []const u8) bool {
    assert(format.len > 0);

    return std.mem.eql(u8, format, "perf") or
        std.mem.eql(u8, format, "dtrace") or
        std.mem.eql(u8, format, "sample") or
        std.mem.eql(u8, format, "vtune") or
        std.mem.eql(u8, format, "xctrace") or
        std.mem.eql(u8, format, "recursive") or
        std.mem.eql(u8, format, "guess");
}

fn is_option_like(arg: []const u8) bool {
    assert(arg.len > 0);

    return arg.len > 1 and arg[0] == '-';
}

fn is_help_arg(arg: []const u8) bool {
    assert(arg.len > 0);

    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

fn show_help(io: Io) !void {
    const usage =
        \\USAGE:
        \\  zflame -h
        \\  zflame --help
        \\  zflame <format> [options] <input> > graph.svg
        \\
        \\Formats:
        \\  perf, dtrace, sample, vtune, xctrace, recursive, guess
        \\
        \\Options:
        \\  --width=<pixels>       Width of the SVG image.
        \\  --height=<pixels>      Height of each frame.
        \\  --colors=<palette>     Color palette.
        \\  --inverted             Generate an inverted flame graph.
        \\  --title=<text>         Title text for the flame graph.
        \\  --subtitle=<text>      Subtitle text for the flame graph.
        \\  --output=<path>        Output file. Omit to write standard output.
        \\  --min-width=<pixels>   Minimum width to show frames.
        \\  --font-size=<pixels>   Font size in pixels.
        \\  --hash                 Use hash-based deterministic colors.
        \\
        \\Options with values must use --key=value syntax.
        \\Use '-' as the input path to read standard input explicitly.
        \\
        \\Examples:
        \\  zflame perf data.perf > flame.svg
        \\  zflame perf --colors=hot --title="CPU Profile" data.perf > flame.svg
        \\  zflame sample --inverted --output=icicle.svg sample.txt
        \\
    ;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    try stdout_writer.interface.print(usage, .{});
    try stdout_writer.interface.flush();
}

fn read_input_file(
    io: Io,
    buffer: *[MAX_INPUT_SIZE_BYTES]u8,
    file_path: []const u8,
) AllErrors![]u8 {
    assert(file_path.len > 0);
    assert(file_path.len <= 1024);

    if (std.mem.eql(u8, file_path, "-")) {
        var reader_buffer: [16 * 1024]u8 = undefined;
        var stdin_reader = Io.File.stdin().reader(io, &reader_buffer);
        return read_all_input(&stdin_reader.interface, buffer) catch |err| switch (err) {
            error.ReadFailed => return stdin_reader.err orelse err,
            else => |e| return e,
        };
    }

    var file = Io.Dir.cwd().openFile(io, file_path, .{
        .mode = .read_only,
    }) catch |err| switch (err) {
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
    defer file.close(io);

    var reader_buffer: [16 * 1024]u8 = undefined;
    var file_reader = file.reader(io, &reader_buffer);
    return read_all_input(&file_reader.interface, buffer) catch |err| switch (err) {
        error.ReadFailed => return file_reader.err orelse err,
        else => |e| return e,
    };
}

fn read_all_input(reader: *Io.Reader, buffer: *[MAX_INPUT_SIZE_BYTES]u8) AllErrors![]u8 {
    var writer: Io.Writer = .fixed(buffer);
    _ = reader.streamRemaining(&writer) catch |err| switch (err) {
        error.WriteFailed => return FlameGraphError.StreamTooLong,
        error.ReadFailed => return error.ReadFailed,
    };

    const bytes = writer.buffered();
    assert(bytes.len <= MAX_INPUT_SIZE_BYTES);

    if (bytes.len == 0) {
        return FlameGraphError.EmptyInputFile;
    }

    return bytes;
}

fn collapse_input_data(
    storage: *[MAX_COLLAPSED_STACKS_COUNT]collapse_mod.CollapsedStack,
    stack_storage: *[MAX_INPUT_SIZE_BYTES]u8,
    input_data: []const u8,
    format: []const u8,
) AllErrors!usize {
    assert(input_data.len > 0);
    assert(input_data.len <= MAX_INPUT_SIZE_BYTES);
    assert(format.len > 0);
    assert(format.len <= 64);

    if (std.mem.eql(u8, format, "perf")) {
        return collapse_perf_data(storage, stack_storage, input_data);
    } else if (std.mem.eql(u8, format, "dtrace")) {
        return collapse_dtrace_data(storage, stack_storage, input_data);
    } else if (std.mem.eql(u8, format, "sample")) {
        return collapse_sample_data(storage, stack_storage, input_data);
    } else if (std.mem.eql(u8, format, "vtune")) {
        return collapse_vtune_data(storage, stack_storage, input_data);
    } else if (std.mem.eql(u8, format, "xctrace")) {
        return collapse_xctrace_data(storage, stack_storage, input_data);
    } else if (std.mem.eql(u8, format, "recursive")) {
        return collapse_recursive_data(storage, stack_storage, input_data);
    } else if (std.mem.eql(u8, format, "guess")) {
        return collapse_guess_data(storage, stack_storage, input_data);
    } else {
        std.debug.print("Error: Unsupported input format: {s}\n", .{format});
        std.debug.print(
            "Supported formats: perf, dtrace, sample, vtune, xctrace, recursive, guess\n",
            .{},
        );
        return FlameGraphError.UnsupportedFormat;
    }
}

fn collapse_perf_data(
    storage: *[MAX_COLLAPSED_STACKS_COUNT]collapse_mod.CollapsedStack,
    stack_storage: *[MAX_INPUT_SIZE_BYTES]u8,
    input_data: []const u8,
) AllErrors!usize {
    var folder = try collapse_mod.perf.Folder.init(.{});
    defer folder.deinit();

    return collapse_with_folder(storage, stack_storage, input_data, &folder);
}

fn parse_collapsed_output(
    storage: *[MAX_COLLAPSED_STACKS_COUNT]collapse_mod.CollapsedStack,
    stack_storage: *[MAX_INPUT_SIZE_BYTES]u8,
    collapsed_data: []const u8,
) AllErrors!usize {
    var result_count: usize = 0;
    var stack_storage_offset: usize = 0;

    var lines = std.mem.splitScalar(u8, collapsed_data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (result_count >= MAX_COLLAPSED_STACKS_COUNT) break;

        // Find the last space to separate stack from count.
        if (std.mem.findLast(u8, line, " ")) |last_space| {
            const stack_part = line[0..last_space];
            const count_part = line[last_space + 1 ..];

            if (stack_part.len > 0 and count_part.len > 0) {
                const count = std.fmt.parseInt(u64, count_part, 10) catch continue;

                if (stack_storage_offset + stack_part.len >= stack_storage.len) break;
                const stack_begin = stack_storage_offset;
                const stack_end = stack_begin + stack_part.len;
                @memcpy(stack_storage[stack_begin..stack_end], stack_part);

                storage[result_count] = collapse_mod.CollapsedStack{
                    .stack = stack_storage[stack_begin..stack_end],
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
    stack_storage: *[MAX_INPUT_SIZE_BYTES]u8,
    input_data: []const u8,
) AllErrors!usize {
    var folder = try collapse_mod.dtrace.Folder.init(.{});
    defer folder.deinit();

    return collapse_with_folder(storage, stack_storage, input_data, &folder);
}

fn collapse_sample_data(
    storage: *[MAX_COLLAPSED_STACKS_COUNT]collapse_mod.CollapsedStack,
    stack_storage: *[MAX_INPUT_SIZE_BYTES]u8,
    input_data: []const u8,
) AllErrors!usize {
    var folder = try collapse_mod.sample.Folder.init(.{});
    defer folder.deinit();

    return collapse_with_folder(storage, stack_storage, input_data, &folder);
}

fn collapse_vtune_data(
    storage: *[MAX_COLLAPSED_STACKS_COUNT]collapse_mod.CollapsedStack,
    stack_storage: *[MAX_INPUT_SIZE_BYTES]u8,
    input_data: []const u8,
) AllErrors!usize {
    var folder = try collapse_mod.vtune.Folder.init(.{});
    defer folder.deinit();

    return collapse_with_folder(storage, stack_storage, input_data, &folder);
}

fn collapse_xctrace_data(
    storage: *[MAX_COLLAPSED_STACKS_COUNT]collapse_mod.CollapsedStack,
    stack_storage: *[MAX_INPUT_SIZE_BYTES]u8,
    input_data: []const u8,
) AllErrors!usize {
    var folder = try collapse_mod.xctrace.Folder.init(.{});
    defer folder.deinit();

    return collapse_with_folder(storage, stack_storage, input_data, &folder);
}

fn collapse_recursive_data(
    storage: *[MAX_COLLAPSED_STACKS_COUNT]collapse_mod.CollapsedStack,
    stack_storage: *[MAX_INPUT_SIZE_BYTES]u8,
    input_data: []const u8,
) AllErrors!usize {
    var folder = try collapse_mod.recursive.Folder.init(.{});
    defer folder.deinit();

    return collapse_with_folder(storage, stack_storage, input_data, &folder);
}

fn collapse_guess_data(
    storage: *[MAX_COLLAPSED_STACKS_COUNT]collapse_mod.CollapsedStack,
    stack_storage: *[MAX_INPUT_SIZE_BYTES]u8,
    input_data: []const u8,
) AllErrors!usize {
    var folder = collapse_mod.guess.Folder.init(.{});
    defer folder.deinit();

    return collapse_with_folder(storage, stack_storage, input_data, &folder);
}

fn collapse_with_folder(
    storage: *[MAX_COLLAPSED_STACKS_COUNT]collapse_mod.CollapsedStack,
    stack_storage: *[MAX_INPUT_SIZE_BYTES]u8,
    input_data: []const u8,
    folder: anytype,
) AllErrors!usize {
    var input_reader: Io.Reader = .fixed(input_data);
    var output_buffer: [MAX_INPUT_SIZE_BYTES * 2]u8 = undefined;
    var output_writer: Io.Writer = .fixed(&output_buffer);

    try folder.collapse(&input_reader, &output_writer);

    return parse_collapsed_output(storage, stack_storage, output_writer.buffered());
}

fn generate_flame_graph(
    io: Io,
    collapsed_stacks: []const collapse_mod.CollapsedStack,
    config: Config,
) AllErrors!void {
    if (collapsed_stacks.len == 0) {
        return;
    }

    var generator = flamegraph_mod.Generator.init(config.flamegraph_options);

    if (std.mem.eql(u8, config.output_file_path, "-")) {
        var stdout_buffer: [16 * 1024]u8 = undefined;
        var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
        try generator.generate_from_collapsed(collapsed_stacks, &stdout_writer.interface);
        try stdout_writer.interface.flush();
    } else {
        var output_file = try Io.Dir.cwd().createFile(io, config.output_file_path, .{});
        defer output_file.close(io);

        var output_buffer: [16 * 1024]u8 = undefined;
        var output_writer = output_file.writer(io, &output_buffer);
        try generator.generate_from_collapsed(collapsed_stacks, &output_writer.interface);
        try output_writer.interface.flush();
    }
}

fn write_stderr(io: Io, comptime format: []const u8, args: anytype) void {
    var buffer: [4096]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &buffer);
    stderr_writer.interface.print(format, args) catch return;
    stderr_writer.interface.flush() catch return;
}

fn cli_error_reported(err: anyerror) bool {
    return switch (err) {
        error.InvalidArguments,
        error.UnsupportedFormat,
        => true,
        else => false,
    };
}

const testing = std.testing;

test "parse command line args uses format subcommand" {
    const args = [_][]const u8{ "perf", "data.perf" };
    const config = try parse_command_line_args(&args);

    try testing.expectEqualStrings("perf", config.input_format);
    try testing.expectEqualStrings("data.perf", config.input_file_path);
    try testing.expectEqualStrings("-", config.output_file_path);
}

test "parse command line args accepts explicit long options" {
    const args = [_][]const u8{
        "perf",
        "--width=1600",
        "--height=20",
        "--colors=java",
        "--inverted",
        "--title=CPU Profile",
        "--subtitle=run 42",
        "--output=flame.svg",
        "--min-width=0.2",
        "--font-size=14",
        "--hash",
        "data.perf",
    };
    const config = try parse_command_line_args(&args);

    try testing.expectEqual(@as(u32, 1600), config.flamegraph_options.image_width.?);
    try testing.expectEqual(@as(u32, 20), config.flamegraph_options.frame_height);
    try testing.expectEqual(flamegraph_mod.Direction.inverted, config.flamegraph_options.direction);
    try testing.expectEqualStrings("CPU Profile", config.flamegraph_options.title);
    try testing.expectEqualStrings("run 42", config.flamegraph_options.subtitle.?);
    try testing.expectEqualStrings("flame.svg", config.output_file_path);
    try testing.expect(config.flamegraph_options.hash_colors);
}

test "parse command line args rejects repeated options" {
    const args = [_][]const u8{
        "perf",
        "--width=1200",
        "--width=1600",
        "data.perf",
    };
    const result = parse_command_line_args(&args);

    try testing.expectError(FlameGraphError.InvalidArguments, result);
}

test "parse command line args rejects ambiguous option values" {
    const args = [_][]const u8{
        "perf",
        "--width",
        "1600",
        "data.perf",
    };
    const result = parse_command_line_args(&args);

    try testing.expectError(FlameGraphError.InvalidArguments, result);
}

test "parse command line args rejects trailing options" {
    const args = [_][]const u8{
        "perf",
        "data.perf",
        "--hash",
    };
    const result = parse_command_line_args(&args);

    try testing.expectError(FlameGraphError.InvalidArguments, result);
}

test "parse command line args rejects unknown palettes" {
    const args = [_][]const u8{
        "perf",
        "--colors=surprise",
        "data.perf",
    };
    const result = parse_command_line_args(&args);

    try testing.expectError(FlameGraphError.InvalidArguments, result);
}
