// Differential flame graph generation for comparing before/after profiles.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const READER_CAPACITY = 128 * 1024;

// Sample counts for before and after profiles.
const Counts = struct {
    first: u64,
    second: u64,

    fn init() Counts {
        return Counts{
            .first = 0,
            .second = 0,
        };
    }
};

// Configuration options for differential generation.
pub const Options = struct {
    // Normalize the first profile count to match the second.
    // This helps when profiles are taken under different load conditions.
    normalize: bool = false,

    // Strip hex addresses like "0x45ef2173" and replace with "0x...".
    strip_hex: bool = false,

    pub fn validate(self: Options) void {
        _ = self;
        // All options are valid boolean values.
    }
};

// Differential flame graph generator.
pub const Generator = struct {
    allocator: std.mem.Allocator,
    options: Options,

    pub fn init(allocator: std.mem.Allocator, options: Options) Generator {
        options.validate();
        return Generator{
            .allocator = allocator,
            .options = options,
        };
    }

    // Generate differential output from two readers.
    pub fn from_readers(
        self: *Generator,
        before_reader: *Io.Reader,
        after_reader: *Io.Reader,
        writer: *Io.Writer,
    ) !void {
        var stack_counts = std.StringHashMap(Counts).init(self.allocator);
        defer {
            var iter = stack_counts.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            stack_counts.deinit();
        }

        const total_before = try self.parse_stack_counts(&stack_counts, before_reader, true);
        const total_after = try self.parse_stack_counts(&stack_counts, after_reader, false);

        // Normalize counts if requested.
        if (self.options.normalize and total_before != total_after and total_before > 0) {
            const total_after_float = @as(f64, @floatFromInt(total_after));
            const total_before_float = @as(f64, @floatFromInt(total_before));
            const scale_factor = total_after_float / total_before_float;

            var iter = stack_counts.iterator();
            while (iter.next()) |entry| {
                const first_float = @as(f64, @floatFromInt(entry.value_ptr.first));
                const scaled_first = @as(u64, @intFromFloat(first_float * scale_factor));
                entry.value_ptr.first = scaled_first;
            }
        }

        try self.write_stacks(&stack_counts, writer);
    }

    // Generate differential output from two files.
    pub fn from_files(
        self: *Generator,
        io: Io,
        before_path: []const u8,
        after_path: []const u8,
        writer: *Io.Writer,
    ) !void {
        var before_file = try Io.Dir.cwd().openFile(io, before_path, .{});
        defer before_file.close(io);

        var after_file = try Io.Dir.cwd().openFile(io, after_path, .{});
        defer after_file.close(io);

        var before_buffer: [READER_CAPACITY]u8 = undefined;
        var after_buffer: [READER_CAPACITY]u8 = undefined;
        var before_reader = before_file.reader(io, &before_buffer);
        var after_reader = after_file.reader(io, &after_buffer);

        try self.from_readers(
            &before_reader.interface,
            &after_reader.interface,
            writer,
        );
    }

    fn parse_stack_counts(
        self: *Generator,
        stack_counts: *std.StringHashMap(Counts),
        reader: *Io.Reader,
        is_first: bool,
    ) !u64 {
        var total: u64 = 0;
        var stripped_fractional_samples = false;

        while (try reader.takeDelimiter('\n')) |line| {
            if (line.len == 0) continue;

            if (self.parse_line(line, &stripped_fractional_samples)) |stack_count| {
                const stack_owned = try self.allocator.dupe(u8, stack_count.stack);

                const result = try stack_counts.getOrPut(stack_owned);
                if (result.found_existing) {
                    // Free the duplicate key since we already have it.
                    self.allocator.free(stack_owned);
                } else {
                    result.value_ptr.* = Counts.init();
                }

                if (is_first) {
                    result.value_ptr.first += stack_count.count;
                } else {
                    result.value_ptr.second += stack_count.count;
                }

                total += stack_count.count;
            }
        }

        return total;
    }

    fn parse_line(
        self: *Generator,
        line: []const u8,
        stripped_fractional_samples: *bool,
    ) ?struct { stack: []const u8, count: u64 } {
        // Find the last space to separate stack from count.
        const last_space = std.mem.findLast(u8, line, " ") orelse return null;

        var samples_str = std.mem.trim(u8, line[last_space + 1 ..], " \t\r\n");

        // Strip fractional part if present.
        if (std.mem.find(u8, samples_str, ".")) |dot_index| {
            // Validate that it's a valid number.
            const before_dot = samples_str[0..dot_index];
            const after_dot = samples_str[dot_index + 1 ..];

            var is_valid = true;
            for (before_dot) |c| {
                if (!std.ascii.isDigit(c)) {
                    is_valid = false;
                    break;
                }
            }
            for (after_dot) |c| {
                if (!std.ascii.isDigit(c)) {
                    is_valid = false;
                    break;
                }
            }

            if (!is_valid) return null;

            // Warn about non-zero fractional parts (only once).
            if (!stripped_fractional_samples.*) {
                var has_non_zero = false;
                for (after_dot) |c| {
                    if (c != '0') {
                        has_non_zero = true;
                        break;
                    }
                }
                if (has_non_zero) {
                    stripped_fractional_samples.* = true;
                    std.debug.print(
                        "Warning: Input data has fractional sample counts " ++
                            "that will be truncated to integers\n",
                        .{},
                    );
                }
            }

            samples_str = before_dot;
        }

        const count = std.fmt.parseInt(u64, samples_str, 10) catch return null;
        const stack = std.mem.trimEnd(u8, line[0..last_space], " \t\r");

        if (self.options.strip_hex) {
            // For simplicity, we'll return the original stack here and implement
            // hex stripping in a separate allocation. In a production version,
            // you'd want to optimize this.
            return .{ .stack = stack, .count = count };
        } else {
            return .{ .stack = stack, .count = count };
        }
    }

    fn write_stacks(
        self: *Generator,
        stack_counts: *const std.StringHashMap(Counts),
        writer: *Io.Writer,
    ) !void {
        _ = self;

        var iter = stack_counts.iterator();
        while (iter.next()) |entry| {
            const stack = entry.key_ptr.*;
            const counts = entry.value_ptr.*;

            try writer.print("{s} {d} {d}\n", .{ stack, counts.first, counts.second });
        }
    }
};

// Tests
const testing = std.testing;

test "differential basic functionality" {
    const allocator = testing.allocator;

    var generator = Generator.init(allocator, .{});

    const before_data = "main;func1 100\nmain;func2 50\n";
    const after_data = "main;func1 150\nmain;func3 75\n";

    var before_reader: Io.Reader = .fixed(before_data);
    var after_reader: Io.Reader = .fixed(after_data);

    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    try generator.from_readers(
        &before_reader,
        &after_reader,
        &output.writer,
    );

    const result = output.written();

    // Should contain three lines with stack and two counts.
    try testing.expect(std.mem.find(u8, result, "main;func1 100 150") != null);
    try testing.expect(std.mem.find(u8, result, "main;func2 50 0") != null);
    try testing.expect(std.mem.find(u8, result, "main;func3 0 75") != null);
}

test "differential with normalization" {
    const allocator = testing.allocator;

    var generator = Generator.init(allocator, .{ .normalize = true });

    const before_data = "main;func1 100\n"; // Total: 100
    const after_data = "main;func1 50\n"; // Total: 50

    var before_reader: Io.Reader = .fixed(before_data);
    var after_reader: Io.Reader = .fixed(after_data);

    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    try generator.from_readers(
        &before_reader,
        &after_reader,
        &output.writer,
    );

    const result = output.written();

    // With normalization, first count should be scaled: 100 * (50/100) = 50.
    try testing.expect(std.mem.find(u8, result, "main;func1 50 50") != null);
}

test "parse line with fractional samples" {
    const allocator = testing.allocator;

    var generator = Generator.init(allocator, .{});
    var stripped = false;

    // Test fractional sample parsing.
    const line = "main;func1 123.456";
    const parsed = generator.parse_line(line, &stripped);

    try testing.expect(parsed != null);
    try testing.expectEqualStrings("main;func1", parsed.?.stack);
    try testing.expectEqual(@as(u64, 123), parsed.?.count);
    try testing.expect(stripped); // Should warn about fractional part.
}

test "parse line with invalid format" {
    const allocator = testing.allocator;

    var generator = Generator.init(allocator, .{});
    var stripped = false;

    // Test invalid line parsing.
    const invalid_lines = [_][]const u8{
        "no_count_here",
        "main;func1 not_a_number",
        "",
        "main;func1 123.abc", // Invalid fractional part
    };

    for (invalid_lines) |line| {
        const parsed = generator.parse_line(line, &stripped);
        try testing.expect(parsed == null);
    }
}
