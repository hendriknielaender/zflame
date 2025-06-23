// Command-line tool for generating differential flame graph data.

const std = @import("std");
const differential = @import("differential.zig");

const MAX_ARGS_COUNT = 64;

const DiffError = error{
    InvalidArgumentCount,
    TooManyArguments,
    HelpRequested,
    InvalidArguments,
    FileNotFound,
    AccessDenied,
    InvalidFileFormat,
};

const AllErrors = DiffError || std.fs.File.OpenError || std.fs.File.WriteError || std.fs.File.ReadError || std.mem.Allocator.Error;

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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len > MAX_ARGS_COUNT) {
        return error.TooManyArguments;
    }

    if (args.len > 1 and std.mem.eql(u8, args[1], "--help")) {
        try show_help();
        return;
    }

    if (args.len < 3) {
        std.debug.print("diff-folded: Generate differential flame graph data\n", .{});
        std.debug.print("Usage: diff-folded [options] before.folded after.folded\n", .{});
        std.debug.print("Use --help for more information.\n", .{});
        return;
    }

    try execute_diff_generation(allocator, args[1..]);
}

fn execute_diff_generation(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    const string_args = convert_args_to_const_slices(args);
    const config = try parse_command_line_args(string_args);
    config.validate();

    try process_differential_generation(allocator, config);
}

fn convert_args_to_const_slices(args: [][:0]u8) [][]const u8 {
    const result: [][]const u8 = @ptrCast(args);
    return result;
}

fn process_differential_generation(allocator: std.mem.Allocator, config: Config) !void {
    const diff_options = differential.Options{
        .normalize = config.normalize,
        .strip_hex = config.strip_hex,
    };

    var generator = differential.Generator.init(allocator, diff_options);

    if (config.output_file) |output_path| {
        const output_file = try std.fs.cwd().createFile(output_path, .{});
        defer output_file.close();

        try generator.from_files(
            config.before_file,
            config.after_file,
            output_file.writer(),
        );

        std.debug.print("Differential data generated: {s}\n", .{output_path});
    } else {
        const stdout = std.io.getStdOut().writer();
        try generator.from_files(
            config.before_file,
            config.after_file,
            stdout,
        );
    }
}

fn parse_command_line_args(args: [][]const u8) AllErrors!Config {
    std.debug.assert(args.len <= MAX_ARGS_COUNT);

    var config = Config.init_default();
    var current_index: usize = 0;

    while (current_index < args.len) {
        const current_arg = args[current_index];
        std.debug.assert(current_arg.len > 0);

        if (is_flag(current_arg, "--normalize")) {
            config.normalize = true;
            current_index += 1;
        } else if (is_flag(current_arg, "--strip-hex")) {
            config.strip_hex = true;
            current_index += 1;
        } else if (is_flag(current_arg, "--output")) {
            config.output_file = try consume_string_flag(args, &current_index);
        } else {
            // Positional arguments: before_file after_file
            if (config.before_file.len == 0) {
                config.before_file = current_arg;
                current_index += 1;
            } else if (config.after_file.len == 0) {
                config.after_file = current_arg;
                current_index += 1;
            } else {
                std.debug.print("Error: Too many positional arguments\n", .{});
                return DiffError.InvalidArguments;
            }
        }
    }

    if (config.before_file.len == 0 or config.after_file.len == 0) {
        std.debug.print("Error: Both before and after files must be specified\n", .{});
        return DiffError.InvalidArguments;
    }

    return config;
}

fn is_flag(arg: []const u8, flag_name: []const u8) bool {
    std.debug.assert(arg.len > 0);
    std.debug.assert(flag_name.len > 0);
    return std.mem.eql(u8, arg, flag_name);
}

fn consume_string_flag(args: [][]const u8, current_index: *usize) AllErrors![]const u8 {
    std.debug.assert(current_index.* < args.len);

    const value_index = current_index.* + 1;
    if (value_index >= args.len) {
        return DiffError.InvalidArguments;
    }

    const value_string = args[value_index];
    std.debug.assert(value_string.len > 0);

    current_index.* = value_index + 1;
    return value_string;
}

fn show_help() !void {
    const stdout = std.io.getStdOut().writer();
    const usage =
        \\ USAGE: diff-folded [options] before.folded after.folded
        \\ 
        \\ Generate differential flame graph data from two folded stack files.
        \\ Output format has three columns: stack before_count after_count
        \\ 
        \\ Options:
        \\   --help            Show this help message
        \\   --normalize       Normalize first profile to match second total
        \\   --strip-hex       Replace hex addresses (0x1234abcd) with 0x...
        \\   --output FILE     Output file (default: stdout)
        \\ 
        \\ Examples:
        \\   diff-folded before.folded after.folded > diff.folded
        \\   diff-folded --normalize before.folded after.folded > normalized.folded
        \\   diff-folded --strip-hex --output diff.txt before.folded after.folded
        \\ 
        \\ The output can be used with flame graph generators that support
        \\ differential visualization (red/blue coloring for increases/decreases).
        \\
    ;
    try stdout.print(usage, .{});
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
    const args = [_][]const u8{ "--normalize", "--strip-hex", "--output", "result.txt", "before.folded", "after.folded" };
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
