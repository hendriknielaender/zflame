// Command-line tool for generating differential flame graph data.

const std = @import("std");
const builtin = @import("builtin");
const differential = @import("differential.zig");
const Io = std.Io;
const cli_log = if (builtin.is_test) struct {
    pub fn err(comptime _: []const u8, _: anytype) void {}
} else std.log.scoped(.cli);

const MAX_ARGS_COUNT = 64;
const MAX_ARG_LENGTH = 512;

const DiffError = error{
    InvalidArgumentCount,
    TooManyArguments,
    HelpRequested,
    InvalidArguments,
    FileNotFound,
    AccessDenied,
    InvalidFileFormat,
};

const AllErrors = DiffError ||
    Io.File.OpenError ||
    Io.File.Writer.Error ||
    Io.Writer.Error ||
    std.mem.Allocator.Error;

const Config = struct {
    before_file: []const u8,
    after_file: []const u8,
    output_file: ?[]const u8,
    normalize: bool,
    strip_hex: bool,

    fn init_default() Config {
        return Config{
            .before_file = "",
            .after_file = "",
            .output_file = null,
            .normalize = false,
            .strip_hex = false,
        };
    }

    fn validate(self: Config) void {
        std.debug.assert(self.before_file.len > 0);
        std.debug.assert(self.after_file.len > 0);
    }
};

const OptionSeen = struct {
    normalize: bool = false,
    strip_hex: bool = false,
    output: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var args_buffer: [MAX_ARGS_COUNT][MAX_ARG_LENGTH]u8 = undefined;
    var args_ptrs: [MAX_ARGS_COUNT][]u8 = undefined;
    var args_count: usize = 0;

    var arg_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer arg_iter.deinit();

    while (arg_iter.next()) |arg| {
        if (args_count >= MAX_ARGS_COUNT) {
            return error.TooManyArguments;
        }
        if (arg.len >= MAX_ARG_LENGTH) {
            return error.InvalidArguments;
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

    execute_diff_generation(io, allocator, args[1..]) catch |err| {
        if (!cli_error_reported(err)) {
            write_stderr(io, "Error: {}\n", .{err});
        }
        std.process.exit(1);
    };
}

fn execute_diff_generation(
    io: Io,
    allocator: std.mem.Allocator,
    args: [][]u8,
) !void {
    const string_args = convert_args_to_const_slices(args);
    const config = try parse_command_line_args(string_args);
    config.validate();

    try process_differential_generation(io, allocator, config);
}

fn convert_args_to_const_slices(args: [][]u8) [][]const u8 {
    const result: [][]const u8 = @ptrCast(args);
    return result;
}

fn process_differential_generation(
    io: Io,
    allocator: std.mem.Allocator,
    config: Config,
) !void {
    const diff_options = differential.Options{
        .normalize = config.normalize,
        .strip_hex = config.strip_hex,
    };

    var generator = differential.Generator.init(allocator, diff_options);

    if (config.output_file) |output_path| {
        var output_file = try Io.Dir.cwd().createFile(io, output_path, .{});
        defer output_file.close(io);

        var output_buffer: [16 * 1024]u8 = undefined;
        var output_writer = output_file.writer(io, &output_buffer);

        try generator.from_files(
            io,
            config.before_file,
            config.after_file,
            &output_writer.interface,
        );
        try output_writer.interface.flush();

        std.debug.print("Differential data generated: {s}\n", .{output_path});
    } else {
        var stdout_buffer: [16 * 1024]u8 = undefined;
        var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);

        try generator.from_files(
            io,
            config.before_file,
            config.after_file,
            &stdout_writer.interface,
        );
        try stdout_writer.interface.flush();
    }
}

fn parse_command_line_args(args: []const []const u8) AllErrors!Config {
    std.debug.assert(args.len <= MAX_ARGS_COUNT);

    var config = Config.init_default();
    var seen = OptionSeen{};
    var positional_seen = false;
    var current_index: usize = 0;

    while (current_index < args.len) {
        const current_arg = args[current_index];
        std.debug.assert(current_arg.len > 0);

        if (try parse_option_arg(&config, &seen, current_arg)) {
            if (positional_seen) {
                cli_log.err("unexpected trailing option: {s}", .{current_arg});
                return DiffError.InvalidArguments;
            }
            current_index += 1;
            continue;
        }

        try parse_positional_arg(&config, current_arg);
        positional_seen = true;
        current_index += 1;
    }

    try validate_cli_config(config);

    return config;
}

fn parse_option_arg(config: *Config, seen: *OptionSeen, arg: []const u8) AllErrors!bool {
    std.debug.assert(arg.len > 0);

    if (try option_present(arg, "--normalize")) {
        try mark_option_seen(&seen.normalize, "--normalize");
        config.normalize = true;
        return true;
    } else if (try option_present(arg, "--strip-hex")) {
        try mark_option_seen(&seen.strip_hex, "--strip-hex");
        config.strip_hex = true;
        return true;
    } else if (try option_value(arg, "--output")) |value| {
        try mark_option_seen(&seen.output, "--output");
        config.output_file = value;
        return true;
    } else if (is_option_like(arg)) {
        cli_log.err("unknown option: {s}", .{arg});
        return DiffError.InvalidArguments;
    } else {
        return false;
    }
}

fn parse_positional_arg(config: *Config, arg: []const u8) AllErrors!void {
    std.debug.assert(arg.len > 0);

    if (is_option_like(arg)) {
        cli_log.err("unexpected argument: {s}", .{arg});
        return DiffError.InvalidArguments;
    }

    if (config.before_file.len == 0) {
        config.before_file = arg;
        return;
    }

    if (config.after_file.len == 0) {
        config.after_file = arg;
        return;
    }

    cli_log.err("unexpected positional argument: {s}", .{arg});
    return DiffError.InvalidArguments;
}

fn option_value(arg: []const u8, option_name: []const u8) AllErrors!?[]const u8 {
    std.debug.assert(arg.len > 0);
    std.debug.assert(option_name.len > 0);

    if (!std.mem.startsWith(u8, arg, option_name)) {
        return null;
    }

    if (arg.len == option_name.len) {
        cli_log.err("use {s}=<value> syntax", .{option_name});
        return DiffError.InvalidArguments;
    }

    if (arg[option_name.len] != '=') {
        return null;
    }

    const value = arg[option_name.len + 1 ..];
    if (value.len == 0) {
        cli_log.err("option requires a value: {s}", .{option_name});
        return DiffError.InvalidArguments;
    }

    return value;
}

fn option_present(arg: []const u8, option_name: []const u8) AllErrors!bool {
    std.debug.assert(arg.len > 0);
    std.debug.assert(option_name.len > 0);

    if (std.mem.eql(u8, arg, option_name)) {
        return true;
    }

    if (std.mem.startsWith(u8, arg, option_name)) {
        if (arg.len > option_name.len and arg[option_name.len] == '=') {
            cli_log.err("option does not take a value: {s}", .{option_name});
            return DiffError.InvalidArguments;
        }
    }

    return false;
}

fn mark_option_seen(seen: *bool, option_name: []const u8) AllErrors!void {
    std.debug.assert(option_name.len > 0);

    if (seen.*) {
        cli_log.err("repeated option: {s}", .{option_name});
        return DiffError.InvalidArguments;
    }

    seen.* = true;
}

fn validate_cli_config(config: Config) AllErrors!void {
    if (config.before_file.len == 0) {
        cli_log.err("missing before folded file", .{});
        return DiffError.InvalidArguments;
    }

    if (config.after_file.len == 0) {
        cli_log.err("missing after folded file", .{});
        return DiffError.InvalidArguments;
    }

    config.validate();
}

fn is_option_like(arg: []const u8) bool {
    std.debug.assert(arg.len > 0);

    return arg.len > 1 and arg[0] == '-';
}

fn is_help_arg(arg: []const u8) bool {
    std.debug.assert(arg.len > 0);

    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

fn show_help(io: Io) !void {
    const usage =
        \\USAGE:
        \\  diff-folded -h
        \\  diff-folded --help
        \\  diff-folded [options] <before.folded> <after.folded>
        \\
        \\Generate differential flame graph data from two folded stack files.
        \\Output format has three columns: stack before_count after_count.
        \\
        \\Options:
        \\  --normalize       Normalize first profile to match second total.
        \\  --strip-hex       Replace hex addresses (0x1234abcd) with 0x...
        \\  --output=<path>   Output file. Omit to write standard output.
        \\
        \\Options with values must use --key=value syntax.
        \\
        \\Examples:
        \\  diff-folded before.folded after.folded > diff.folded
        \\  diff-folded --normalize before.folded after.folded > normalized.folded
        \\  diff-folded --strip-hex --output=diff.txt before.folded after.folded
        \\
        \\The output can be used with flame graph generators that support
        \\differential visualization.
        \\
    ;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    try stdout_writer.interface.print(usage, .{});
    try stdout_writer.interface.flush();
}

fn write_stderr(io: Io, comptime format: []const u8, args: anytype) void {
    var buffer: [4096]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &buffer);
    stderr_writer.interface.print(format, args) catch return;
    stderr_writer.interface.flush() catch return;
}

fn cli_error_reported(err: anyerror) bool {
    return switch (err) {
        error.InvalidArguments => true,
        else => false,
    };
}

// Tests
const testing = std.testing;

test "parse command line args basic" {
    const args = [_][]const u8{ "before.folded", "after.folded" };
    const config = try parse_command_line_args(&args);

    try testing.expectEqualStrings("before.folded", config.before_file);
    try testing.expectEqualStrings("after.folded", config.after_file);
    try testing.expect(config.output_file == null);
    try testing.expect(!config.normalize);
    try testing.expect(!config.strip_hex);
}

test "parse command line args with options" {
    const args = [_][]const u8{
        "--normalize",
        "--strip-hex",
        "--output=result.txt",
        "before.folded",
        "after.folded",
    };
    const config = try parse_command_line_args(&args);

    try testing.expectEqualStrings("before.folded", config.before_file);
    try testing.expectEqualStrings("after.folded", config.after_file);
    try testing.expectEqualStrings("result.txt", config.output_file.?);
    try testing.expect(config.normalize);
    try testing.expect(config.strip_hex);
}

test "parse command line args insufficient files" {
    const args = [_][]const u8{"only_one_file.folded"};
    const result = parse_command_line_args(&args);

    try testing.expectError(DiffError.InvalidArguments, result);
}

test "parse command line args rejects repeated options" {
    const args = [_][]const u8{
        "--normalize",
        "--normalize",
        "before.folded",
        "after.folded",
    };
    const result = parse_command_line_args(&args);

    try testing.expectError(DiffError.InvalidArguments, result);
}

test "parse command line args rejects ambiguous option values" {
    const args = [_][]const u8{
        "--output",
        "result.txt",
        "before.folded",
        "after.folded",
    };
    const result = parse_command_line_args(&args);

    try testing.expectError(DiffError.InvalidArguments, result);
}

test "parse command line args rejects trailing options" {
    const args = [_][]const u8{
        "before.folded",
        "after.folded",
        "--strip-hex",
    };
    const result = parse_command_line_args(&args);

    try testing.expectError(DiffError.InvalidArguments, result);
}
