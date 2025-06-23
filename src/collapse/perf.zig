const std = @import("std");
const assert = std.debug.assert;
const collapse_types = @import("collapse.zig");

const MAX_STACK_DEPTH = 32;
const MAX_FUNCTION_NAME_LENGTH = 128;
const MAX_PROCESS_NAME_LENGTH = 64;
const MAX_LINE_LENGTH = 512;
const MAX_CACHE_ENTRIES = 64;

// Configuration options for perf folder.
pub const Options = struct {
    // Annotate JIT functions with a _[j] suffix.
    annotate_jit: bool = false,

    // Annotate kernel functions with a _[k] suffix.
    annotate_kernel: bool = false,

    // Only consider samples of the given event type.
    event_filter: ?[]const u8 = null,

    // Include raw addresses where symbols can't be found.
    include_addrs: bool = false,

    // Include PID in the root frame.
    include_pid: bool = false,

    // Include TID and PID in the root frame.
    include_tid: bool = false,

    // Tidy generic function names.
    tidy_generic: bool = true,

    // Skip frames after any of these function names.
    skip_after: []const []const u8 = &.{},
};

// Filter state for stack processing.
const StackFilter = enum {
    keep,
    skip,
    skip_remaining,
};

// A stack collapser for the output of `perf script`.
pub const Folder = struct {
    options: Options,

    // Parser state.
    event_filter_storage: [256]u8,
    event_filter_len: usize,
    in_event: bool,
    current_comm: [MAX_PROCESS_NAME_LENGTH]u8,
    current_comm_len: usize,
    current_stack: [MAX_LINE_LENGTH]u8,
    current_stack_len: usize,
    current_count: u64,
    stack_filter: StackFilter,

    // Cache for function names.
    cache_keys: [MAX_CACHE_ENTRIES][MAX_FUNCTION_NAME_LENGTH]u8,
    cache_values: [MAX_CACHE_ENTRIES][MAX_FUNCTION_NAME_LENGTH]u8,
    cache_key_lens: [MAX_CACHE_ENTRIES]usize,
    cache_value_lens: [MAX_CACHE_ENTRIES]usize,
    cache_used: [MAX_CACHE_ENTRIES]bool,
    cache_count: usize,

    pub fn init(options: Options) !Folder {
        var folder = Folder{
            .options = options,
            .event_filter_storage = [_]u8{0} ** 256,
            .event_filter_len = 0,
            .in_event = false,
            .current_comm = [_]u8{0} ** MAX_PROCESS_NAME_LENGTH,
            .current_comm_len = 0,
            .current_stack = [_]u8{0} ** MAX_LINE_LENGTH,
            .current_stack_len = 0,
            .current_count = 0,
            .stack_filter = .keep,
            .cache_keys = [_][MAX_FUNCTION_NAME_LENGTH]u8{[_]u8{0} ** MAX_FUNCTION_NAME_LENGTH} ** MAX_CACHE_ENTRIES,
            .cache_values = [_][MAX_FUNCTION_NAME_LENGTH]u8{[_]u8{0} ** MAX_FUNCTION_NAME_LENGTH} ** MAX_CACHE_ENTRIES,
            .cache_key_lens = [_]usize{0} ** MAX_CACHE_ENTRIES,
            .cache_value_lens = [_]usize{0} ** MAX_CACHE_ENTRIES,
            .cache_used = [_]bool{false} ** MAX_CACHE_ENTRIES,
            .cache_count = 0,
        };

        if (options.event_filter) |filter| {
            if (filter.len < folder.event_filter_storage.len) {
                @memcpy(folder.event_filter_storage[0..filter.len], filter);
                folder.event_filter_len = filter.len;
            }
        }

        return folder;
    }

    pub fn deinit(self: *Folder) void {
        // No dynamic memory to free
        _ = self;
    }

    pub fn collapse(
        self: *Folder,
        reader: anytype,
        writer: anytype,
    ) !void {
        var occurrences = collapse_types.Occurrences.init();
        defer occurrences.deinit();

        try self.process_input(reader, &occurrences);
        try occurrences.write_to(writer);
    }

    pub fn is_applicable(self: *Folder, input: []const u8) bool {
        _ = self;
        // Check for perf-specific patterns.
        var lines = std.mem.splitScalar(u8, input, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;

            // Check for perf header patterns.
            if (std.mem.indexOf(u8, trimmed, "perf ") != null or
                std.mem.indexOf(u8, trimmed, "# cmdline") != null)
            {
                return true;
            }

            // Check for perf event line pattern: "comm pid/tid timestamp: event:"
            if (is_event_line(trimmed) and std.mem.indexOf(u8, trimmed, ":") != null) {
                // Look for typical perf timestamp and event pattern
                if (std.mem.indexOf(u8, trimmed, ".") != null and
                    std.mem.indexOf(u8, trimmed, " ") != null)
                {
                    return true;
                }
            }
        }
        return false;
    }

    fn process_input(
        self: *Folder,
        reader: anytype,
        occurrences: *collapse_types.Occurrences,
    ) !void {
        var line_buffer: [MAX_LINE_LENGTH]u8 = undefined;

        while (try reader.readUntilDelimiterOrEof(line_buffer[0..], '\n')) |line| {
            if (line.len == 0) {
                try self.end_stack(occurrences);
                continue;
            }

            if (is_header_line(line)) {
                try self.process_header_line(line);
            } else if (is_event_line(line)) {
                try self.process_event_line(line);
            } else if (is_stack_line(line)) {
                try self.process_stack_line(line);
            }
        }

        // Handle any remaining stack.
        try self.end_stack(occurrences);
    }

    fn process_header_line(self: *Folder, line: []const u8) !void {
        assert(line.len > 0);
        assert(line[0] == '#');

        const cmdline_prefix = "# cmdline : ";
        if (collapse_types.common.starts_with(line, cmdline_prefix)) {
            const cmdline = line[cmdline_prefix.len..];
            self.extract_comm_from_cmdline(cmdline);
        }
    }

    fn process_event_line(self: *Folder, line: []const u8) !void {
        assert(line.len > 0);

        // End previous stack if any.
        try self.end_stack(null);

        // Parse event type and check filter.
        const event_type = extract_event_type(line) orelse return;

        if (self.event_filter_len > 0) {
            // We have a filter from options, check if event matches.
            const filter = self.event_filter_storage[0..self.event_filter_len];
            if (!std.mem.eql(u8, filter, event_type)) {
                self.stack_filter = .skip_remaining;
                return;
            }
        } else {
            // No filter from options, use the first event type we encounter.
            if (event_type.len < self.event_filter_storage.len) {
                @memcpy(self.event_filter_storage[0..event_type.len], event_type);
                self.event_filter_len = event_type.len;
            }
        }

        // Extract sample count (defaults to 1 if not found).
        self.current_count = 1;
        self.in_event = true;
        self.stack_filter = .keep;
    }

    fn process_stack_line(self: *Folder, line: []const u8) !void {
        assert(line.len > 0);
        assert(std.ascii.isWhitespace(line[0]));

        if (!self.in_event or self.stack_filter != .keep) return;

        const function_name = try self.extract_function_name(line);
        if (function_name.len == 0) return;

        // Check skip_after patterns.
        for (self.options.skip_after) |pattern| {
            if (std.mem.eql(u8, function_name, pattern)) {
                self.stack_filter = .skip_remaining;
                return;
            }
        }

        // Prepend to current stack (reverse order).
        const old_len = self.current_stack_len;
        const new_len = old_len + function_name.len + (if (old_len > 0) @as(usize, 1) else 0);

        if (new_len >= self.current_stack.len) return; // Stack too long

        if (old_len > 0) {
            // Move existing content to the right.
            std.mem.copyBackwards(
                u8,
                self.current_stack[function_name.len + 1 .. new_len],
                self.current_stack[0..old_len],
            );
            // Insert function name and separator.
            @memcpy(self.current_stack[0..function_name.len], function_name);
            self.current_stack[function_name.len] = ';';
        } else {
            @memcpy(self.current_stack[0..function_name.len], function_name);
        }

        self.current_stack_len = new_len;
    }

    fn end_stack(self: *Folder, occurrences: ?*collapse_types.Occurrences) !void {
        if (!self.in_event or self.current_stack_len == 0) {
            self.reset_state();
            return;
        }

        // Build final stack with comm if needed.
        var final_stack: [MAX_LINE_LENGTH]u8 = undefined;
        var final_stack_len: usize = 0;

        if (self.current_comm_len > 0) {
            const comm = self.current_comm[0..self.current_comm_len];
            if (final_stack_len + comm.len + 1 < final_stack.len) {
                @memcpy(final_stack[final_stack_len .. final_stack_len + comm.len], comm);
                final_stack_len += comm.len;
                final_stack[final_stack_len] = ';';
                final_stack_len += 1;
            }
        }

        if (final_stack_len + self.current_stack_len < final_stack.len) {
            @memcpy(final_stack[final_stack_len .. final_stack_len + self.current_stack_len], self.current_stack[0..self.current_stack_len]);
            final_stack_len += self.current_stack_len;
        }

        // Add to occurrences if provided.
        if (occurrences) |occ| {
            try occ.put(final_stack[0..final_stack_len], self.current_count);
        }

        self.reset_state();
    }

    fn reset_state(self: *Folder) void {
        self.in_event = false;
        self.current_stack_len = 0;
        self.current_count = 0;
        self.stack_filter = .keep;
    }

    fn extract_comm_from_cmdline(self: *Folder, cmdline: []const u8) void {
        var iter = std.mem.tokenizeScalar(u8, cmdline, ' ');

        while (iter.next()) |arg| {
            if (arg.len == 0 or arg[0] == '-') continue;

            const base_name = extract_base_name(arg);
            if (base_name.len == 0 or base_name.len >= MAX_PROCESS_NAME_LENGTH) continue;

            self.current_comm_len = clean_comm_name(
                base_name,
                &self.current_comm,
            );
            return;
        }

        self.current_comm_len = 0;
    }

    fn extract_function_name(self: *Folder, line: []const u8) ![]const u8 {
        assert(line.len > 0);

        // Skip leading whitespace.
        var start: usize = 0;
        while (start < line.len and std.ascii.isWhitespace(line[start])) {
            start += 1;
        }

        if (start >= line.len) return "";

        // Find hex address if present.
        var address_end = start;
        while (address_end < line.len and
            (std.ascii.isHex(line[address_end]) or line[address_end] == 'x'))
        {
            address_end += 1;
        }

        // Skip whitespace after address.
        while (address_end < line.len and std.ascii.isWhitespace(line[address_end])) {
            address_end += 1;
        }

        // Find function name.
        const func_start = address_end;
        var func_end = func_start;
        while (func_end < line.len and
            line[func_end] != ' ' and
            line[func_end] != '(' and
            line[func_end] != '+')
        {
            func_end += 1;
        }

        // Extract the name.
        const name = if (func_end > func_start)
            line[func_start..func_end]
        else if (self.options.include_addrs and address_end > start)
            line[start..address_end]
        else
            return "";

        if (name.len == 0) return "";

        // Check for kernel annotation by looking for [kernel in the line.
        const is_kernel = std.mem.indexOf(u8, line, "[kernel") != null;
        if (self.options.annotate_kernel and is_kernel) {
            var annotated_buffer: [MAX_FUNCTION_NAME_LENGTH]u8 = undefined;
            if (name.len + 4 < annotated_buffer.len) {
                @memcpy(annotated_buffer[0..name.len], name);
                @memcpy(annotated_buffer[name.len .. name.len + 4], "_[k]");
                const annotated = annotated_buffer[0 .. name.len + 4];
                return self.cache_string(annotated);
            }
        }

        // Apply tidying if needed.
        if (self.options.tidy_generic) {
            return self.tidy_function_name(name);
        }

        return name;
    }

    fn tidy_function_name(self: *Folder, name: []const u8) []const u8 {
        _ = self;
        // TODO: Implement generic tidying for C++ templates, Rust generics, etc.
        return name;
    }

    fn cache_string(self: *Folder, str: []const u8) []const u8 {
        // Check if already cached
        for (0..self.cache_count) |i| {
            if (self.cache_used[i] and
                self.cache_key_lens[i] == str.len and
                std.mem.eql(u8, self.cache_keys[i][0..self.cache_key_lens[i]], str))
            {
                return self.cache_values[i][0..self.cache_value_lens[i]];
            }
        }

        // Find empty slot
        if (self.cache_count < MAX_CACHE_ENTRIES and str.len < MAX_FUNCTION_NAME_LENGTH) {
            const index = self.cache_count;
            self.cache_used[index] = true;
            self.cache_key_lens[index] = str.len;
            self.cache_value_lens[index] = str.len;
            @memcpy(self.cache_keys[index][0..str.len], str);
            @memcpy(self.cache_values[index][0..str.len], str);
            self.cache_count += 1;
            return self.cache_values[index][0..str.len];
        }

        // Cache full, return original
        return str;
    }
};

// Helper functions.

fn is_header_line(line: []const u8) bool {
    return line.len > 0 and line[0] == '#';
}

fn is_event_line(line: []const u8) bool {
    return line.len > 0 and !std.ascii.isWhitespace(line[0]) and line[0] != '#';
}

fn is_stack_line(line: []const u8) bool {
    return line.len > 0 and std.ascii.isWhitespace(line[0]);
}

fn extract_event_type(line: []const u8) ?[]const u8 {
    // Format: "comm pid/tid [cpu] timestamp: event_type: ..."
    const colon_pos = collapse_types.common.index_of_char(line, ':') orelse return null;
    if (colon_pos + 2 >= line.len) return null;

    const after_colon = line[colon_pos + 2 ..];
    const next_colon = collapse_types.common.index_of_char(after_colon, ':') orelse return null;

    return collapse_types.common.trim_whitespace(after_colon[0..next_colon]);
}

fn extract_sample_count(line: []const u8) ?u64 {
    // Look for pattern like "1234/5678" in the line.
    var iter = std.mem.tokenizeScalar(u8, line, ' ');

    while (iter.next()) |token| {
        const slash_pos = collapse_types.common.index_of_char(token, '/') orelse continue;
        if (slash_pos == 0) continue;

        const count_str = token[0..slash_pos];
        return std.fmt.parseInt(u64, count_str, 10) catch continue;
    }

    return null;
}

fn extract_base_name(path: []const u8) []const u8 {
    var last_slash: usize = 0;
    for (path, 0..) |char, i| {
        if (char == '/') last_slash = i + 1;
    }
    return path[last_slash..];
}

fn clean_comm_name(name: []const u8, buffer: *[MAX_PROCESS_NAME_LENGTH]u8) usize {
    assert(name.len > 0);
    assert(name.len < MAX_PROCESS_NAME_LENGTH);

    var write_index: usize = 0;
    for (name) |char| {
        if (write_index >= MAX_PROCESS_NAME_LENGTH - 1) break;

        buffer[write_index] = if (char == ' ') '_' else char;
        write_index += 1;
    }

    return write_index;
}

// Tests
const testing = std.testing;

test "perf collapse basic functionality" {
    // Create a perf folder with default options.
    var folder = try Folder.init(.{});
    defer folder.deinit();

    // Test input data.
    const input =
        "# cmdline : /usr/bin/test-program\n" ++
        "test-program 1234/1234 [000] 12345.678901: cycles: \n" ++
        "\tffffffff81234567 func1 ([kernel.kallsyms])\n" ++
        "\tffffffff81234568 func2 ([kernel.kallsyms])\n" ++
        "\t          401234 main (/usr/bin/test-program)\n" ++
        "\n" ++
        "test-program 1234/1234 [000] 12345.678902: cycles: \n" ++
        "\tffffffff81234569 func3 ([kernel.kallsyms])\n" ++
        "\t          401234 main (/usr/bin/test-program)\n" ++
        "\n";

    var input_stream = std.io.fixedBufferStream(input);
    var output_buffer: [4096]u8 = undefined;
    var output_stream = std.io.fixedBufferStream(&output_buffer);

    // Run collapse.
    try folder.collapse(input_stream.reader(), output_stream.writer());

    // Check output contains expected stacks.
    const result = output_stream.getWritten();
    try testing.expect(std.mem.indexOf(u8, result, "test-program;main;func2;func1 1") != null);
    try testing.expect(std.mem.indexOf(u8, result, "test-program;main;func3 1") != null);
}

test "perf collapse with options" {
    // Test with various options.
    var folder = try Folder.init(.{
        .include_pid = true,
        .annotate_kernel = true,
    });
    defer folder.deinit();

    const input =
        "# cmdline : /usr/bin/test\n" ++
        "test 100/100 [001] 1000.123456: cycles: \n" ++
        "\tffffffff81000000 kernel_func ([kernel.kallsyms])\n" ++
        "\t          400000 user_func (/usr/bin/test)\n" ++
        "\n";

    var input_stream = std.io.fixedBufferStream(input);
    var output_buffer: [4096]u8 = undefined;
    var output_stream = std.io.fixedBufferStream(&output_buffer);

    try folder.collapse(input_stream.reader(), output_stream.writer());

    const result = output_stream.getWritten();
    try testing.expect(result.len > 0);
}

test "perf collapse empty input" {
    var folder = try Folder.init(.{});
    defer folder.deinit();

    const input = "";
    var input_stream = std.io.fixedBufferStream(input);
    var output_buffer: [1024]u8 = undefined;
    var output_stream = std.io.fixedBufferStream(&output_buffer);

    try folder.collapse(input_stream.reader(), output_stream.writer());

    try testing.expectEqual(@as(usize, 0), output_stream.pos);
}

test "perf is_applicable" {
    var folder = try Folder.init(.{});
    defer folder.deinit();

    // Should detect perf format.
    try testing.expect(folder.is_applicable("perf record data"));
    try testing.expect(folder.is_applicable("# cmdline : test"));
    try testing.expect(!folder.is_applicable("random data"));
}
