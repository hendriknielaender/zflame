// stackcollapse.zig
const std = @import("std");
const parser = @import("parser.zig");

/// Configuration options specific to the perf parser.
pub const PerfParserConfig = struct {
    include_pname: bool = true,
    include_pid: bool = false,
    include_tid: bool = false,
    include_addrs: bool = false,
    tidy_generic: bool = true,
};

/// Represents a `perf` parser.
pub const PerfParser = struct {
    config: PerfParserConfig,

    /// Implements the `parse` function for `perf` input.
    pub fn parse(
        self: *PerfParser,
        allocator: *std.mem.Allocator,
        input_data: []const u8,
    ) ![]parser.CollapsedStack {
        return collapsePerfStacks(allocator, input_data, self.config);
    }

    /// Returns the name of the parser.
    pub fn name(_: *PerfParser) []const u8 {
        return "perf";
    }
};

/// Collapses perf script output into single-line stack entries.
/// Each entry consists of semicolon-separated function names followed by a space and the sample count.
///
/// # Arguments
/// * `allocator` - Allocator for dynamic memory allocations.
/// * `input_data` - Raw input data from `perf script`.
/// * `config` - Configuration options for collapsing.
///
/// # Returns
/// An array of `CollapsedStack` entries.
pub fn collapsePerfStacks(
    allocator: *std.mem.Allocator,
    input_data: []const u8,
    config: PerfParserConfig,
) ![]parser.CollapsedStack {
    const lines = std.mem.split(u8, input_data, "\n");
    var collapsed_map = std.StringHashMap(u64).init(allocator.*);
    defer collapsed_map.deinit();

    var current_pname: []const u8 = "";
    var current_stack: std.ArrayList(u8) = std.ArrayList(u8).init(allocator.*);
    defer current_stack.deinit();

    var current_count: u64 = 0;

    while (lines.next()) |line| {
        if (isHeaderLine(line)) {
            if (std.mem.startsWith(u8, line, "# cmdline")) {
                current_pname = extractProcessName(line, allocator) orelse "";
            }
            continue;
        }

        if (isTraceHeaderLine(line)) {
            const count = extractSampleCount(line) orelse 1;
            current_count = count;
            current_stack.clear();
            continue;
        }

        if (isStackFrameLine(line)) {
            const func_name = extractFunctionName(line, config, allocator) orelse continue;
            try current_stack.appendSlice(func_name);
            try current_stack.append(u8(';'));
            continue;
        }

        if (isEmptyLine(line)) {
            if (current_stack.len == 0) continue;

            // Remove trailing semicolon.
            if (current_stack.items[current_stack.len - 1] == ';') {
                current_stack.len -= 1;
            }

            var final_stack: []const u8 = "";

            if (config.include_pname and current_pname.len > 0) {
                final_stack = try prependProcessName(
                    allocator,
                    current_pname,
                    current_stack.toOwnedSlice(),
                    config,
                );
            } else {
                final_stack = current_stack.toOwnedSlice();
            }

            if (final_stack.len > 0) {
                try collapsed_map.put(final_stack, collapsed_map.get(final_stack) orelse 0) += current_count;
            }

            current_stack.clear();
            current_count = 0;
            continue;
        }

        // Unrecognized line format; skip.
    }

    // Handle any remaining stack after the last line.
    if (current_stack.len > 0) {
        if (current_stack.items[current_stack.len - 1] == ';') {
            current_stack.len -= 1;
        }

        var final_stack: []const u8 = "";

        if (config.include_pname and current_pname.len > 0) {
            final_stack = try prependProcessName(
                allocator,
                current_pname,
                current_stack.toOwnedSlice(),
                config,
            );
        } else {
            final_stack = current_stack.toOwnedSlice();
        }

        if (final_stack.len > 0) {
            try collapsed_map.put(final_stack, collapsed_map.get(final_stack) orelse 0) += current_count;
        }
    }

    // Convert the map to an array of CollapsedStack.
    var collapsed_stacks = std.ArrayList(parser.CollapsedStack).init(allocator.*);
    defer collapsed_stacks.deinit();

    var it = collapsed_map.iterator();
    while (it.next()) |entry| {
        try collapsed_stacks.append(parser.CollapsedStack{
            .stack = entry.key,
            .count = entry.value,
        });
    }

    return collapsed_stacks.toOwnedSlice();
}

/// Checks if a line is a header line (starts with '#').
fn isHeaderLine(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "#");
}

/// Checks if a line is a trace header line (starts with 'perf').
fn isTraceHeaderLine(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "perf");
}

/// Checks if a line is a stack frame line (starts with whitespace).
fn isStackFrameLine(line: []const u8) bool {
    return (line.len > 0) and (std.ascii.isSpace(line[0]) or
        std.ascii.isSpace(line[1]) // Handles lines starting with multiple spaces
    );
}

/// Checks if a line is empty or contains only whitespace.
fn isEmptyLine(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t\r\n").len == 0;
}

/// Extracts the process name from a header line.
/// Returns `null` if extraction fails.
fn extractProcessName(
    line: []const u8,
    allocator: *std.mem.Allocator,
) ?[]const u8 {
    const prefix = "# cmdline : ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;

    const cmdline = line[std.mem.len(prefix)..];
    const args = std.mem.split(u8, cmdline, " ");

    while (args.next()) |arg| {
        if (!std.mem.startsWith(u8, arg, "-")) {
            // Strip pathname if present.
            const path_parts = std.mem.split(u8, arg, "/");
            const pname = path_parts.last orelse arg;
            // Replace spaces with underscores.
            var pname_clean = std.ArrayList(u8).init(allocator.*);
            defer pname_clean.deinit();

            for (pname) |c| {
                if (c == ' ') {
                    try pname_clean.append(u8('_'));
                } else {
                    try pname_clean.append(c);
                }
            }

            return pname_clean.toOwnedSlice();
        }
    }

    return null;
}

/// Extracts the sample count from a trace header line.
/// Returns `null` if extraction fails.
fn extractSampleCount(line: []const u8) ?u64 {
    const parts = std.mem.split(u8, line, " ");
    var index: usize = 0;
    var count_str: []const u8 = "";

    while (parts.next()) |part| {
        if (index == 1) { // The "977/977" part
            const sep = std.mem.find(u8, part, '/') orelse return null;
            count_str = part[0..sep];
            break;
        }
        index += 1;
    }

    if (count_str.len == 0) return null;

    return std.fmt.parseInt(u64, count_str, 10) catch null;
}

/// Extracts the function name from a stack frame line.
/// Returns `null` if extraction fails.
fn extractFunctionName(
    line: []const u8,
    config: PerfParserConfig,
    allocator: *std.mem.Allocator,
) ?[]const u8 {
    // Example stack frame line:
    //     ffffffff8104f45a native_write_msr_safe ([kernel.kallsyms])

    // Split the line by spaces.
    const parts = std.mem.split(u8, line, " ");
    _ = parts.next(); // Skip address.

    if (!parts.next()) return null;

    var func_name = parts.curr();

    // Remove any suffixes like "+0x800047c022ec"
    const plus_pos = std.mem.find(u8, func_name, "+") orelse func_name.len;
    func_name = func_name[0..plus_pos];

    // Replace or remove characters based on `tidy_generic` configuration.
    if (config.tidy_generic) {
        func_name = tidyFunctionName(func_name, allocator) orelse func_name;
    }

    return func_name;
}

/// Tidies the function name by removing unwanted characters.
/// Returns `null` if memory allocation fails.
fn tidyFunctionName(
    func_name: []const u8,
    allocator: *std.mem.Allocator,
) ?[]const u8 {
    // Replace or remove characters as needed.
    // For simplicity, remove characters that are not alphanumeric or underscores.

    var buffer = std.ArrayList(u8).init(allocator.*);
    defer buffer.deinit();

    for (func_name) |c| {
        if (std.ascii.isAlphaNumeric(c) or c == '_') {
            try buffer.append(c);
        }
    }

    return buffer.toOwnedSlice();
}

/// Prepends the process name to the stack if configured.
/// Returns `null` if memory allocation fails.
fn prependProcessName(
    allocator: *std.mem.Allocator,
    pname: []const u8,
    stack: []const u8,
    _: PerfParserConfig,
) ![]const u8 {
    var temp_stack = std.ArrayList(u8).init(allocator.*);
    defer temp_stack.deinit();

    try temp_stack.appendSlice(pname);
    try temp_stack.append(u8(';'));
    try temp_stack.appendSlice(stack);

    return temp_stack.toOwnedSlice();
}
