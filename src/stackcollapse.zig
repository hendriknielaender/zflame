const std = @import("std");
const assert = std.debug.assert;
const parser = @import("flamegraph/parser.zig");

const MAX_STACK_DEPTH = 50;
const MAX_FUNCTION_NAME_LEN = 512;
const MAX_PROCESS_NAME_LEN = 256;
const MAX_LINE_LEN = 4096;

comptime {
    assert(MAX_STACK_DEPTH > 0);
    assert(MAX_STACK_DEPTH <= 10000);
    assert(MAX_FUNCTION_NAME_LEN > 0);
    assert(MAX_FUNCTION_NAME_LEN <= 4096);
    assert(MAX_PROCESS_NAME_LEN > 0);
    assert(MAX_PROCESS_NAME_LEN <= 1024);
    assert(MAX_LINE_LEN > 0);
    assert(MAX_LINE_LEN <= 65536);

    assert(MAX_FUNCTION_NAME_LEN < MAX_LINE_LEN);
    assert(MAX_PROCESS_NAME_LEN < MAX_FUNCTION_NAME_LEN);
    assert(MAX_STACK_DEPTH < 100);
    assert(MAX_FUNCTION_NAME_LEN < 1000);
    assert(MAX_LINE_LEN > 1000);
}

pub const PerfParserConfig = struct {
    include_process_name: bool,
    include_process_id: bool,
    include_thread_id: bool,
    include_addresses: bool,
    tidy_generic_names: bool,

    pub fn init_default() PerfParserConfig {
        return PerfParserConfig{
            .include_process_name = true,
            .include_process_id = false,
            .include_thread_id = false,
            .include_addresses = false,
            .tidy_generic_names = true,
        };
    }

    pub fn validate(self: PerfParserConfig) void {
        _ = self;
    }
};

pub const PerfParser = struct {
    config: PerfParserConfig,

    pub fn init() PerfParser {
        return PerfParser{
            .config = PerfParserConfig.init_default(),
        };
    }

    pub fn parse_to_buffer(
        self: *const PerfParser,
        allocator: *std.mem.Allocator,
        input_data: []const u8,
        output_buffer: []parser.CollapsedStack,
    ) ![]parser.CollapsedStack {
        assert(input_data.len > 0);
        assert(output_buffer.len > 0);
        self.config.validate();

        return collapse_perf_stacks_to_buffer(allocator, input_data, self.config, output_buffer);
    }
};

pub fn collapse_perf_stacks_to_buffer(
    allocator: *std.mem.Allocator,
    input_data: []const u8,
    config: PerfParserConfig,
    output_buffer: []parser.CollapsedStack,
) ![]parser.CollapsedStack {
    assert(input_data.len > 0);
    assert(output_buffer.len > 0);
    config.validate();

    var state = ParsingState.init(allocator);
    defer state.deinit();

    return process_input_lines(&state, input_data, config, output_buffer);
}

const ParsingState = struct {
    collapsed_map: std.StringHashMap(u64),
    current_process_name: [MAX_PROCESS_NAME_LEN]u8,
    current_process_name_len: usize,
    current_stack_buffer: [MAX_LINE_LEN]u8,
    current_stack_len: usize,
    current_sample_count: u64,

    fn init(allocator: *std.mem.Allocator) ParsingState {
        return ParsingState{
            .collapsed_map = std.StringHashMap(u64).init(allocator.*),
            .current_process_name = std.mem.zeroes([MAX_PROCESS_NAME_LEN]u8),
            .current_process_name_len = 0,
            .current_stack_buffer = std.mem.zeroes([MAX_LINE_LEN]u8),
            .current_stack_len = 0,
            .current_sample_count = 0,
        };
    }

    fn deinit(self: *ParsingState) void {
        self.collapsed_map.deinit();
    }

    fn reset(self: *ParsingState) void {
        self.current_stack_len = 0;
        self.current_sample_count = 0;
    }

    fn get_current_process_name(self: *const ParsingState) []const u8 {
        return self.current_process_name[0..self.current_process_name_len];
    }

    fn get_current_stack(self: *const ParsingState) []const u8 {
        return self.current_stack_buffer[0..self.current_stack_len];
    }
};

fn process_input_lines(
    state: *ParsingState,
    input_data: []const u8,
    config: PerfParserConfig,
    output_buffer: []parser.CollapsedStack,
) ![]parser.CollapsedStack {
    assert(input_data.len > 0);
    assert(output_buffer.len > 0);

    var lines_iterator = std.mem.splitScalar(u8, input_data, '\n');

    while (lines_iterator.next()) |line| {
        if (line.len == 0) continue;
        assert(line.len <= MAX_LINE_LEN);

        try process_input_line(state, line, config);
    }

    return convert_map_to_collapsed_stacks(state, output_buffer);
}

fn process_input_line(
    state: *ParsingState,
    line: []const u8,
    config: PerfParserConfig,
) !void {
    assert(line.len > 0);
    assert(line.len <= MAX_LINE_LEN);
    if (is_header_line(line)) {
        try process_header_line(state, line);
    } else if (is_trace_header_line(line)) {
        try process_trace_header_line(state, line);
    } else if (is_stack_frame_line(line)) {
        try process_stack_frame_line(state, line, config);
    } else if (is_empty_line(line)) {
        try process_empty_line(state, config);
    }
}

fn process_header_line(state: *ParsingState, line: []const u8) !void {
    assert(line.len > 0);
    assert(is_header_line(line));

    if (std.mem.startsWith(u8, line, "# cmdline")) {
        try extract_process_name_to_buffer(line, &state.current_process_name, &state.current_process_name_len);
    }
}

fn process_trace_header_line(state: *ParsingState, line: []const u8) !void {
    assert(line.len > 0);
    assert(is_trace_header_line(line));

    const count = extract_sample_count(line) orelse 1;
    state.current_sample_count = count;
    state.current_stack_len = 0;
}

fn process_stack_frame_line(state: *ParsingState, line: []const u8, config: PerfParserConfig) !void {
    assert(line.len > 0);
    assert(is_stack_frame_line(line));

    var func_name_buffer: [MAX_FUNCTION_NAME_LEN]u8 = undefined;
    const func_name = extract_function_name_to_buffer(line, config, &func_name_buffer) orelse return;

    if (state.current_stack_len + func_name.len + 1 >= MAX_LINE_LEN) return;

    @memcpy(state.current_stack_buffer[state.current_stack_len .. state.current_stack_len + func_name.len], func_name);
    state.current_stack_len += func_name.len;
    state.current_stack_buffer[state.current_stack_len] = ';';
    state.current_stack_len += 1;
}

fn process_empty_line(state: *ParsingState, config: PerfParserConfig) !void {
    if (state.current_stack_len == 0) return;

    if (state.current_stack_buffer[state.current_stack_len - 1] == ';') {
        state.current_stack_len -= 1;
    }

    var final_stack_buffer: [MAX_LINE_LEN]u8 = undefined;
    const final_stack = try build_final_stack(state, config, &final_stack_buffer);

    if (final_stack.len > 0) {
        const existing_count = state.collapsed_map.get(final_stack) orelse 0;
        try state.collapsed_map.put(final_stack, existing_count + state.current_sample_count);
    }

    state.reset();
}

fn build_final_stack(
    state: *const ParsingState,
    config: PerfParserConfig,
    buffer: *[MAX_LINE_LEN]u8,
) ![]const u8 {
    const current_stack = state.get_current_stack();
    assert(current_stack.len <= MAX_LINE_LEN);

    if (config.include_process_name and state.current_process_name_len > 0) {
        const process_name = state.get_current_process_name();
        if (process_name.len + 1 + current_stack.len >= MAX_LINE_LEN) {
            return current_stack;
        }

        @memcpy(buffer[0..process_name.len], process_name);
        buffer[process_name.len] = ';';
        @memcpy(buffer[process_name.len + 1 .. process_name.len + 1 + current_stack.len], current_stack);

        return buffer[0 .. process_name.len + 1 + current_stack.len];
    } else {
        @memcpy(buffer[0..current_stack.len], current_stack);
        return buffer[0..current_stack.len];
    }
}

fn convert_map_to_collapsed_stacks(
    state: *const ParsingState,
    output_buffer: []parser.CollapsedStack,
) ![]parser.CollapsedStack {
    var output_index: usize = 0;
    var iterator = state.collapsed_map.iterator();

    while (iterator.next()) |entry| {
        if (output_index >= output_buffer.len) break;

        output_buffer[output_index] = parser.CollapsedStack{
            .stack = entry.key_ptr.*,
            .count = entry.value_ptr.*,
        };
        output_index += 1;
    }

    assert(output_index <= output_buffer.len);
    return output_buffer[0..output_index];
}

fn is_header_line(line: []const u8) bool {
    assert(line.len > 0);
    return line[0] == '#';
}

fn is_trace_header_line(line: []const u8) bool {
    assert(line.len > 0);
    return std.mem.startsWith(u8, line, "perf");
}

fn is_stack_frame_line(line: []const u8) bool {
    assert(line.len > 0);
    return std.ascii.isWhitespace(line[0]);
}

fn is_empty_line(line: []const u8) bool {
    assert(line.len >= 0);
    if (line.len == 0) return true;
    return std.mem.trim(u8, line, " \t\r\n").len == 0;
}

fn extract_process_name_to_buffer(
    line: []const u8,
    buffer: *[MAX_PROCESS_NAME_LEN]u8,
    name_len: *usize,
) !void {
    assert(line.len > 0);
    assert(is_header_line(line));

    const prefix = "# cmdline : ";
    if (!std.mem.startsWith(u8, line, prefix)) return;

    const cmdline = line[prefix.len..];
    var args_iterator = std.mem.splitScalar(u8, cmdline, ' ');

    while (args_iterator.next()) |arg| {
        if (arg.len == 0) continue;
        if (arg[0] == '-') continue;

        const process_name = extract_base_name(arg);
        if (process_name.len == 0) continue;
        if (process_name.len >= MAX_PROCESS_NAME_LEN) continue;

        clean_process_name(process_name, buffer, name_len);
        return;
    }

    name_len.* = 0;
}

fn extract_base_name(path: []const u8) []const u8 {
    assert(path.len > 0);

    var last_slash_index: usize = 0;
    var i: usize = 0;
    while (i < path.len) {
        if (path[i] == '/') {
            last_slash_index = i + 1;
        }
        i += 1;
    }

    return path[last_slash_index..];
}

fn clean_process_name(
    name: []const u8,
    buffer: *[MAX_PROCESS_NAME_LEN]u8,
    output_len: *usize,
) void {
    assert(name.len > 0);
    assert(name.len < MAX_PROCESS_NAME_LEN);

    var write_index: usize = 0;
    for (name) |c| {
        if (write_index >= MAX_PROCESS_NAME_LEN - 1) break;

        if (c == ' ') {
            buffer[write_index] = '_';
        } else {
            buffer[write_index] = c;
        }
        write_index += 1;
    }

    output_len.* = write_index;
}

fn extract_sample_count(line: []const u8) ?u64 {
    assert(line.len > 0);
    assert(is_trace_header_line(line));

    var parts_iterator = std.mem.splitScalar(u8, line, ' ');
    var part_index: usize = 0;

    while (parts_iterator.next()) |part| {
        if (part_index == 1) {
            const slash_pos = std.mem.indexOf(u8, part, "/") orelse return null;
            if (slash_pos == 0) return null;

            const count_str = part[0..slash_pos];
            if (count_str.len == 0) return null;
            if (count_str.len > 10) return null;

            return std.fmt.parseInt(u64, count_str, 10) catch null;
        }
        part_index += 1;
    }

    return null;
}

fn extract_function_name_to_buffer(
    line: []const u8,
    config: PerfParserConfig,
    buffer: *[MAX_FUNCTION_NAME_LEN]u8,
) ?[]const u8 {
    assert(line.len > 0);
    assert(is_stack_frame_line(line));

    var parts_iterator = std.mem.splitScalar(u8, line, ' ');
    _ = parts_iterator.next();

    const func_name_part = parts_iterator.next() orelse return null;
    if (func_name_part.len == 0) return null;

    const plus_pos = std.mem.indexOf(u8, func_name_part, "+") orelse func_name_part.len;
    const func_name = func_name_part[0..plus_pos];

    if (func_name.len == 0) return null;
    if (func_name.len >= MAX_FUNCTION_NAME_LEN) return null;

    if (config.tidy_generic_names) {
        return tidy_function_name_to_buffer(func_name, buffer);
    } else {
        @memcpy(buffer[0..func_name.len], func_name);
        return buffer[0..func_name.len];
    }
}

fn tidy_function_name_to_buffer(
    func_name: []const u8,
    buffer: *[MAX_FUNCTION_NAME_LEN]u8,
) ?[]const u8 {
    assert(func_name.len > 0);
    assert(func_name.len < MAX_FUNCTION_NAME_LEN);

    var write_index: usize = 0;
    for (func_name) |c| {
        if (write_index >= MAX_FUNCTION_NAME_LEN - 1) break;

        if (std.ascii.isAlphanumeric(c) or c == '_' or c == ':') {
            buffer[write_index] = c;
            write_index += 1;
        }
    }

    if (write_index == 0) return null;
    return buffer[0..write_index];
}
