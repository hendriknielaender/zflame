const std = @import("std");
const assert = std.debug.assert;

const MAX_OCCURRENCES_CAPACITY = 1024;
const MAX_STACK_LENGTH = 2048;
const MAX_FUNCTION_NAME_LENGTH = 128;

// Represents a collapsed stack with its occurrence count.
pub const CollapsedStack = struct {
    stack: []const u8,
    count: u64,

    pub fn validate(self: CollapsedStack) void {
        assert(self.stack.len > 0);
        assert(self.stack.len <= MAX_STACK_LENGTH);
        assert(self.count > 0);
        assert(self.count <= 1_000_000_000);
    }
};

// Fixed-size map for tracking stack occurrences without allocation.
const OccurrenceEntry = struct {
    stack: [MAX_STACK_LENGTH]u8,
    stack_len: usize,
    count: u64,
    used: bool,
};

pub const Occurrences = struct {
    entries: [MAX_OCCURRENCES_CAPACITY]OccurrenceEntry,
    count_used: usize,

    pub fn init() Occurrences {
        return .{
            .entries = [_]OccurrenceEntry{.{
                .stack = [_]u8{0} ** MAX_STACK_LENGTH,
                .stack_len = 0,
                .count = 0,
                .used = false,
            }} ** MAX_OCCURRENCES_CAPACITY,
            .count_used = 0,
        };
    }

    pub fn deinit(self: *Occurrences) void {
        // No dynamic memory to free
        _ = self;
    }

    pub fn put(self: *Occurrences, stack: []const u8, stack_count: u64) !void {
        assert(@TypeOf(self) == *Occurrences);
        assert(stack.len > 0);
        assert(stack.len <= MAX_STACK_LENGTH);
        assert(stack_count > 0);

        // Find existing entry
        for (&self.entries) |*entry| {
            if (entry.used and entry.stack_len == stack.len and
                std.mem.eql(u8, entry.stack[0..entry.stack_len], stack))
            {
                entry.count += stack_count;
                return;
            }
        }

        // Find empty slot
        for (&self.entries) |*entry| {
            if (!entry.used) {
                entry.used = true;
                entry.stack_len = stack.len;
                @memcpy(entry.stack[0..stack.len], stack);
                entry.count = stack_count;
                self.count_used += 1;
                return;
            }
        }

        return error.OutOfMemory; // No more space
    }

    pub fn get(self: *const Occurrences, stack: []const u8) ?u64 {
        assert(@TypeOf(self) == *const Occurrences);
        assert(stack.len > 0);

        for (&self.entries) |*entry| {
            if (entry.used and entry.stack_len == stack.len and
                std.mem.eql(u8, entry.stack[0..entry.stack_len], stack))
            {
                return entry.count;
            }
        }
        return null;
    }

    pub fn count(self: *const Occurrences) u32 {
        return @intCast(self.count_used);
    }

    pub const Iterator = struct {
        occurrences: *const Occurrences,
        index: usize,

        pub fn next(self: *Iterator) ?struct { key_ptr: *[]const u8, value_ptr: *u64 } {
            while (self.index < self.occurrences.entries.len) {
                const entry = &self.occurrences.entries[self.index];
                self.index += 1;
                if (entry.used) {
                    // Note: This is a hack since we can't return mutable references to our arrays
                    // For iteration purposes, we'll need a different approach
                    return null; // Will need to handle this differently
                }
            }
            return null;
        }
    };

    pub fn iterator(self: *const Occurrences) Iterator {
        return Iterator{
            .occurrences = self,
            .index = 0,
        };
    }

    // Helper method to iterate without returning mutable references
    pub fn for_each(self: *const Occurrences, comptime func: fn ([]const u8, u64) void) void {
        for (&self.entries) |*entry| {
            if (entry.used) {
                func(entry.stack[0..entry.stack_len], entry.count);
            }
        }
    }

    // Helper method for writing output
    pub fn write_to(self: *const Occurrences, writer: anytype) !void {
        for (&self.entries) |*entry| {
            if (entry.used) {
                try writer.print("{s} {d}\n", .{ entry.stack[0..entry.stack_len], entry.count });
            }
        }
    }
};

// Abstract behavior of stack collapsing.
pub const Collapse = struct {
    // Function pointer for collapsing implementation.
    collapse_fn: *const fn (
        self: *anyopaque,
        reader: anytype,
        writer: anytype,
    ) anyerror!void,

    // Function pointer to check if format is applicable.
    is_applicable_fn: *const fn (
        self: *anyopaque,
        input: []const u8,
    ) bool,

    // Pointer to the implementation.
    impl: *anyopaque,

    pub fn collapse(
        self: *Collapse,
        reader: anytype,
        writer: anytype,
    ) !void {
        return self.collapse_fn(self.impl, reader, writer);
    }

    pub fn is_applicable(self: *Collapse, input: []const u8) bool {
        return self.is_applicable_fn(self.impl, input);
    }
};

// Helper to create a Collapse interface from a concrete type.
pub fn create_collapse(comptime T: type, impl: *T) Collapse {
    const gen = struct {
        fn collapse_wrapper(
            ptr: *anyopaque,
            reader: anytype,
            writer: anytype,
        ) anyerror!void {
            const self = @as(*T, @ptrCast(@alignCast(ptr)));
            return T.collapse(self, reader, writer);
        }

        fn is_applicable_wrapper(
            ptr: *anyopaque,
            input: []const u8,
        ) bool {
            const self = @as(*T, @ptrCast(@alignCast(ptr)));
            return T.is_applicable(self, input);
        }
    };

    return .{
        .collapse_fn = gen.collapse_wrapper,
        .is_applicable_fn = gen.is_applicable_wrapper,
        .impl = impl,
    };
}

// Common utilities for collapse implementations.
pub const common = struct {
    // Check if a line is empty or contains only whitespace.
    pub fn is_empty_line(line: []const u8) bool {
        for (line) |char| {
            if (!std.ascii.isWhitespace(char)) return false;
        }
        return true;
    }

    // Trim whitespace from both ends of a string.
    pub fn trim_whitespace(str: []const u8) []const u8 {
        return std.mem.trim(u8, str, " \t\r\n");
    }

    // Find the index of a character in a string.
    pub fn index_of_char(str: []const u8, char: u8) ?usize {
        for (str, 0..) |c, i| {
            if (c == char) return i;
        }
        return null;
    }

    // Check if string starts with prefix.
    pub fn starts_with(str: []const u8, prefix: []const u8) bool {
        return std.mem.startsWith(u8, str, prefix);
    }

    // Check if string ends with suffix.
    pub fn ends_with(str: []const u8, suffix: []const u8) bool {
        return std.mem.endsWith(u8, str, suffix);
    }
};

// Tests
const testing = std.testing;

test "occurrences map" {
    var occurrences = Occurrences.init();
    defer occurrences.deinit();

    // Test adding stacks.
    try occurrences.put("stack1", 10);
    try occurrences.put("stack2", 20);
    try occurrences.put("stack1", 5); // Should add to existing.

    try testing.expectEqual(@as(?u64, 15), occurrences.get("stack1"));
    try testing.expectEqual(@as(?u64, 20), occurrences.get("stack2"));
    try testing.expectEqual(@as(?u64, null), occurrences.get("stack3"));
    try testing.expectEqual(@as(u32, 2), occurrences.count());
}

test "collapsed stack validation" {
    // Valid stack.
    const valid_stack = CollapsedStack{
        .stack = "main;func1;func2",
        .count = 100,
    };
    valid_stack.validate(); // Should not panic.

    // Test edge cases.
    const min_stack = CollapsedStack{
        .stack = "a",
        .count = 1,
    };
    min_stack.validate();
}
