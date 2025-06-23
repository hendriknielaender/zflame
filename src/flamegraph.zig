// Enhanced flame graph generation module for zflame.

const std = @import("std");
const assert = std.debug.assert;
const collapse_mod = @import("collapse.zig");
pub const color = @import("flamegraph/color.zig");

const MAX_DEPTH = 512;
const MAX_TITLE_LENGTH = 256;
const MAX_SUBTITLE_LENGTH = 256;
const MAX_COLOR_NAME_LENGTH = 64;
const DEFAULT_FRAME_HEIGHT = 16;
const DEFAULT_FONT_SIZE = 12;
const DEFAULT_MIN_WIDTH = 0.1;
const DEFAULT_WIDTH = 1200;
const MAX_FRAMES_COUNT = 4096;
const MAX_FRAME_NAME_LENGTH = 128;

// Re-export color types.
pub const ColorPalette = color.Palette;
pub const Color = color.Color;
pub const BackgroundColor = color.BackgroundColor;

// Direction of flame graph growth.
pub const Direction = enum {
    normal, // Bottom to top (standard)
    inverted, // Top to bottom (icicle)
};

// Text truncation direction.
pub const TextTruncateDirection = enum {
    left,
    right,
};

// Options for flame graph generation.
pub const Options = struct {
    // Visual appearance.
    palette: ColorPalette = ColorPalette.default(),
    direction: Direction = .normal,
    image_width: ?u32 = null, // null means fluid width
    frame_height: u32 = DEFAULT_FRAME_HEIGHT,
    min_width: f64 = DEFAULT_MIN_WIDTH,

    // Text and fonts.
    font_type: []const u8 = "monospace",
    font_size: u32 = DEFAULT_FONT_SIZE,
    font_width: f64 = 0.59, // Character width factor
    text_truncate_direction: TextTruncateDirection = .right,

    // Labels and titles.
    title: []const u8 = "Flame Graph",
    subtitle: ?[]const u8 = null,
    count_name: []const u8 = "samples",
    name_type: []const u8 = "Function:",

    // Colors.
    search_color: []const u8 = "#e600e6",
    ui_color: []const u8 = "#000000",
    stroke_color: []const u8 = "none",

    // Advanced features.
    hash_colors: bool = false, // Hash-based deterministic colors
    color_diffusion: bool = false, // Spread colors across palette
    factor: f64 = 1.0, // Scale sample values
    notes: ?[]const u8 = null, // Additional notes

    pub fn validate(self: Options) void {
        assert(self.frame_height > 0);
        assert(self.frame_height <= 100);
        assert(self.font_size > 0);
        assert(self.font_size <= 100);
        assert(self.min_width >= 0.0);
        assert(self.font_width > 0.0);
        assert(self.factor > 0.0);

        if (self.image_width) |width| {
            assert(width > 0);
            assert(width <= 10000);
        }
    }
};

// Frame data for SVG generation.
const Frame = struct {
    name: [MAX_FRAME_NAME_LENGTH]u8,
    name_len: usize,
    value: u64,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    color: []const u8,
    children_indices: [32]usize, // Reduced size
    children_count: usize,
    used: bool,

    pub fn init() Frame {
        return Frame{
            .name = [_]u8{0} ** MAX_FRAME_NAME_LENGTH,
            .name_len = 0,
            .value = 0,
            .x = 0.0,
            .y = 0.0,
            .width = 0.0,
            .height = 0.0,
            .color = "#000000",
            .children_indices = [_]usize{0} ** 32,
            .children_count = 0,
            .used = false,
        };
    }

    pub fn set_name(self: *Frame, name: []const u8) void {
        const copy_len = @min(name.len, MAX_FRAME_NAME_LENGTH - 1);
        @memcpy(self.name[0..copy_len], name[0..copy_len]);
        self.name_len = copy_len;
        // Ensure null termination if there's space
        if (copy_len < MAX_FRAME_NAME_LENGTH) {
            self.name[copy_len] = 0;
        }
    }

    pub fn get_name(self: *const Frame) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn add_child(self: *Frame, child_index: usize) !void {
        if (self.children_count >= self.children_indices.len) {
            return error.TooManyChildren;
        }
        self.children_indices[self.children_count] = child_index;
        self.children_count += 1;
    }
};

// Frame pool for memory management without allocation
const FramePool = struct {
    frames: [MAX_FRAMES_COUNT]Frame,
    next_free: usize,

    pub fn init() FramePool {
        return FramePool{
            .frames = undefined, // Don't initialize until needed
            .next_free = 0,
        };
    }

    pub fn allocate(self: *FramePool) !usize {
        if (self.next_free >= self.frames.len) {
            return error.OutOfMemory;
        }
        const index = self.next_free;
        self.frames[index] = Frame.init(); // Initialize on allocation
        self.frames[index].used = true;
        self.next_free += 1;
        return index;
    }

    pub fn get(self: *FramePool, index: usize) *Frame {
        assert(index < self.frames.len);
        return &self.frames[index];
    }

    pub fn reset(self: *FramePool) void {
        // No need to reset all frames, just reset the counter
        self.next_free = 0;
    }
};

// Flame graph generator.
pub const Generator = struct {
    options: Options,
    total_samples: u64,
    max_depth: u32,
    frame_pool: FramePool,

    pub fn init(options: Options) Generator {
        options.validate();

        return Generator{
            .options = options,
            .total_samples = 0,
            .max_depth = 0,
            .frame_pool = FramePool.init(),
        };
    }

    pub fn generate_from_collapsed(
        self: *Generator,
        collapsed_stacks: []const collapse_mod.CollapsedStack,
        writer: anytype,
    ) !void {
        if (collapsed_stacks.len == 0) {
            return;
        }

        // Validate all input stacks.
        for (collapsed_stacks) |stack| {
            stack.validate();
        }

        // Reset frame pool
        self.frame_pool.reset();
        self.total_samples = 0;
        self.max_depth = 0;

        // Build frame tree from collapsed stacks.
        const root_index = try self.build_frame_tree(collapsed_stacks);

        assert(self.total_samples > 0); // postcondition after building tree
        assert(self.max_depth > 0); // postcondition after building tree

        // Calculate layout.
        try self.calculate_layout(root_index);

        // Generate SVG.
        try self.write_svg(root_index, writer);
    }

    fn build_frame_tree(
        self: *Generator,
        collapsed_stacks: []const collapse_mod.CollapsedStack,
    ) !usize {
        const root_index = try self.frame_pool.allocate();
        const root = self.frame_pool.get(root_index);
        root.set_name("root");

        // Build tree structure.
        for (collapsed_stacks) |collapsed_stack| {
            collapsed_stack.validate();

            const adjusted_value = @as(u64, @intFromFloat(@as(f64, @floatFromInt(collapsed_stack.count)) * self.options.factor));
            self.total_samples += adjusted_value;

            try self.add_stack_to_tree(root_index, collapsed_stack.stack, adjusted_value);
        }

        // Propagate values up the tree so parent nodes have sum of children
        self.propagate_values(root_index);

        return root_index;
    }

    fn add_stack_to_tree(
        self: *Generator,
        root_index: usize,
        stack_str: []const u8,
        value: u64,
    ) !void {
        var current_index = root_index;
        var depth: u32 = 0;

        var iter = std.mem.splitScalar(u8, stack_str, ';');
        while (iter.next()) |func_name| {
            if (func_name.len == 0) continue;

            depth += 1;
            if (depth > self.max_depth) {
                self.max_depth = depth;
            }

            // Find or create child frame.
            var found_child_index: ?usize = null;
            const current_frame = self.frame_pool.get(current_index);

            for (0..current_frame.children_count) |i| {
                const child_index = current_frame.children_indices[i];
                const child = self.frame_pool.get(child_index);
                if (std.mem.eql(u8, child.get_name(), func_name)) {
                    found_child_index = child_index;
                    break;
                }
            }

            if (found_child_index == null) {
                const new_index = try self.frame_pool.allocate();
                const new_frame = self.frame_pool.get(new_index);
                new_frame.set_name(func_name);
                new_frame.value = 0;
                try current_frame.add_child(new_index);
                found_child_index = new_index;
            }

            current_index = found_child_index.?;
        }

        const leaf_frame = self.frame_pool.get(current_index);
        leaf_frame.value += value;
    }

    fn propagate_values(self: *Generator, frame_index: usize) void {
        const frame = self.frame_pool.get(frame_index);

        // First, recursively propagate values for all children
        for (0..frame.children_count) |i| {
            const child_index = frame.children_indices[i];
            self.propagate_values(child_index);
        }

        // If this frame has children, set its value to the sum of children's values
        if (frame.children_count > 0) {
            var total_value: u64 = 0;
            for (0..frame.children_count) |i| {
                const child_index = frame.children_indices[i];
                const child = self.frame_pool.get(child_index);
                total_value += child.value;
            }
            frame.value = total_value;
        }
        // If no children, the value was already set by add_stack_to_tree
    }

    fn calculate_layout(self: *Generator, root_index: usize) !void {
        const root = self.frame_pool.get(root_index);
        const height = @as(f64, @floatFromInt(self.options.frame_height));
        const total_height = (self.max_depth + 2) * self.options.frame_height + 100; // Extra space for title
        const ypad1 = self.calculate_ypad1();
        const ypad2 = self.calculate_ypad2();

        // Set root frame dimensions using percentage-based width (like inferno)
        root.x = 0.0;
        root.y = if (self.options.direction == .inverted)
            @as(f64, @floatFromInt(ypad1))
        else
            @as(f64, @floatFromInt(total_height - ypad2 - self.options.frame_height));
        root.width = 100.0; // 100% width
        root.height = height;
        root.color = self.get_color(root.get_name(), 0);

        // Recursively calculate layout for children.
        try self.calculate_children_layout(root_index, 0, total_height, ypad1, ypad2);
    }

    fn calculate_children_layout(self: *Generator, frame_index: usize, depth: u32, total_height: u32, ypad1: u32, ypad2: u32) !void {
        const frame = self.frame_pool.get(frame_index);
        if (frame.children_count == 0) return;

        var x_offset_pct = frame.x;
        const child_height = @as(f64, @floatFromInt(self.options.frame_height));

        for (0..frame.children_count) |i| {
            const child_index = frame.children_indices[i];
            const child = self.frame_pool.get(child_index);

            if (child.value == 0) continue;
            if (frame.value == 0) continue; // Prevent division by zero

            // Calculate width as percentage of total samples
            const child_width_pct = (frame.width * @as(f64, @floatFromInt(child.value))) / @as(f64, @floatFromInt(frame.value));

            // Convert percentage to actual pixels for min width check
            const image_width = if (self.options.image_width) |w| @as(f64, @floatFromInt(w)) else @as(f64, @floatFromInt(DEFAULT_WIDTH));
            const child_width_pixels = (child_width_pct / 100.0) * image_width;

            if (child_width_pixels < self.options.min_width) continue;

            child.x = x_offset_pct;

            // Calculate Y position using inferno's method
            child.y = if (self.options.direction == .inverted)
                @as(f64, @floatFromInt(ypad1 + (depth + 1) * self.options.frame_height))
            else
                @as(f64, @floatFromInt(total_height - ypad2 - ((depth + 2) * self.options.frame_height)));

            child.width = child_width_pct;
            child.height = child_height;
            child.color = self.get_color(child.get_name(), depth + 1);

            x_offset_pct += child_width_pct;

            try self.calculate_children_layout(child_index, depth + 1, total_height, ypad1, ypad2);
        }
    }

    fn calculate_ypad1(self: *Generator) u32 {
        const subtitle_height = if (self.options.subtitle != null)
            self.options.font_size * 2
        else
            0;

        return if (self.options.direction == .inverted)
            self.options.font_size * 4 + subtitle_height + 4
        else
            self.options.font_size * 3 + subtitle_height;
    }

    fn calculate_ypad2(self: *Generator) u32 {
        return if (self.options.direction == .inverted)
            self.options.font_size + 10
        else
            self.options.font_size * 2 + 10;
    }

    fn get_color(self: *Generator, name: []const u8, depth: u32) []const u8 {
        _ = self;
        _ = depth;

        if (name.len == 0) return "#d0d0d0";

        // Use simple hash for color selection
        var hash: u32 = 0;
        for (name) |c| {
            hash = hash *% 31 +% c;
        }

        const colors = [_][]const u8{
            "#dc3912", "#ff9900", "#109618", "#990099", "#0099c6", "#dd4477",
            "#66aa00", "#b82e2e", "#316395", "#994499", "#22aa99", "#aaaa11",
            "#6633cc", "#e67300", "#8b0707", "#651067", "#329262", "#5574a6",
            "#3b3eac", "#b77322", "#16537e", "#4a148c", "#9e9d24", "#795548",
        };

        return colors[hash % colors.len];
    }

    fn write_svg(self: *Generator, root_index: usize, writer: anytype) !void {
        const width = if (self.options.image_width) |w| w else DEFAULT_WIDTH;
        const total_height = (self.max_depth + 2) * self.options.frame_height + 100; // Extra space for title

        // Write SVG header.
        try self.write_svg_header(writer, width, total_height);

        // Write styles.
        try self.write_svg_styles(writer);

        // Write title and subtitle.
        try self.write_svg_title(writer, width);

        // Write frames container with total_samples attribute
        const xpad = 10;
        try writer.print("<svg id=\"frames\" x=\"{d}\" width=\"{d}\" total_samples=\"{d}\">\n", .{ xpad, width - (xpad * 2), self.total_samples });

        // Write frames recursively.
        try self.write_frame_recursive(writer, root_index);

        // Close frames container
        try writer.print("</svg>\n", .{});

        // Write SVG footer.
        try writer.print("</svg>\n", .{});
    }

    fn write_svg_header(self: *Generator, writer: anytype, width: u32, height: u32) !void {
        _ = self;

        try writer.print(
            \\<?xml version="1.0" standalone="no"?>
            \\<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
            \\<svg version="1.1" width="{d}" height="{d}" onload="init(evt)" viewBox="0 0 {d} {d}" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" xmlns:fg="http://github.com/jonhoo/inferno">
            \\
        , .{ width, height, width, height });
    }

    fn write_svg_styles(self: *Generator, writer: anytype) !void {
        try writer.print(
            \\<style type="text/css">
            \\  .func_g:hover {{ stroke:{s}; stroke-width:0.5; cursor:pointer; }}
            \\  .func_text {{ font-family:{s}; font-size:{d}px; fill:{s}; }}
            \\  .title {{ font-family:{s}; font-size:{d}px; fill:{s}; font-weight:bold; }}
            \\  .subtitle {{ font-family:{s}; font-size:{d}px; fill:{s}; }}
            \\</style>
            \\
        , .{
            self.options.search_color,
            self.options.font_type,
            self.options.font_size,
            self.options.ui_color,
            self.options.font_type,
            self.options.font_size + 4,
            self.options.ui_color,
            self.options.font_type,
            self.options.font_size,
            self.options.ui_color,
        });
    }

    fn write_svg_title(self: *Generator, writer: anytype, width: u32) !void {
        const title_y = self.options.font_size + 10;

        // Title
        try writer.print("<text id=\"title\" x=\"50%\" y=\"{d}\" class=\"title\" text-anchor=\"middle\">{s}</text>\n", .{ title_y, self.options.title });

        if (self.options.subtitle) |subtitle| {
            const subtitle_y = title_y + self.options.font_size + 5;
            try writer.print("<text x=\"50%\" y=\"{d}\" class=\"subtitle\" text-anchor=\"middle\">{s}</text>\n", .{ subtitle_y, subtitle });
        }

        _ = width; // suppress unused warning
    }

    fn write_frame_recursive(self: *Generator, writer: anytype, frame_index: usize) !void {
        const frame = self.frame_pool.get(frame_index);

        // Convert percentage width to pixels for min width check
        const image_width = if (self.options.image_width) |w| @as(f64, @floatFromInt(w)) else @as(f64, @floatFromInt(DEFAULT_WIDTH));
        const frame_width_pixels = (frame.width / 100.0) * image_width;
        if (frame_width_pixels < self.options.min_width) return;

        // Write frame rectangle
        const frame_name = frame.get_name();
        // Clean up the name for display - remove null characters and trim whitespace
        var clean_name_buf: [128]u8 = undefined;
        var clean_len: usize = 0;
        for (frame_name) |c| {
            if (c != 0 and clean_len < clean_name_buf.len - 1) {
                clean_name_buf[clean_len] = c;
                clean_len += 1;
            }
        }
        const clean_name = std.mem.trim(u8, clean_name_buf[0..clean_len], " \t\r\n");
        const safe_name = if (clean_name.len > 0) clean_name else "[unknown]";

        try writer.print(
            \\<g class="func_g">
            \\<title>{s} ({d} samples, {d:.2}%)</title>
            \\<rect x="{d:.4}%" y="{d:.1}" width="{d:.4}%" height="{d:.1}" fill="{s}"/>
            \\
        , .{
            safe_name,
            frame.value,
            frame.width,
            frame.x,
            frame.y,
            frame.width,
            frame.height,
            frame.color,
        });

        // Write frame text if there's room.
        const text_width_pixels = (frame.width / 100.0) * image_width - 6.0; // Padding
        if (text_width_pixels > @as(f64, @floatFromInt(self.options.font_size))) {
            const text_x_pct = frame.x + (3.0 / image_width * 100.0); // Convert 3px padding to percentage
            const text_y = frame.y + @as(f64, @floatFromInt(self.options.frame_height)) / 2.0 + @as(f64, @floatFromInt(self.options.font_size)) / 3.0;

            // Only write text if name is not empty and contains non-whitespace characters
            if (frame_name.len > 0) {
                var has_content = false;
                for (frame_name) |c| {
                    if (!std.ascii.isWhitespace(c) and c != 0) {
                        has_content = true;
                        break;
                    }
                }
                if (has_content) {
                    try writer.print("<text x=\"{d:.4}%\" y=\"{d:.1}\" class=\"func_text\">{s}</text>\n", .{ text_x_pct, text_y, frame_name });
                }
            }
        }

        try writer.print("</g>\n", .{});

        // Write children.
        for (0..frame.children_count) |i| {
            const child_index = frame.children_indices[i];
            try self.write_frame_recursive(writer, child_index);
        }
    }
};

// Tests
const testing = std.testing;

test "color palette from string" {
    try testing.expect(ColorPalette.from_string("hot") == .hot);
    try testing.expect(ColorPalette.from_string("mem") == .mem);
    try testing.expect(ColorPalette.from_string("invalid") == null);
}

test "options validation" {
    const valid_options = Options{};
    valid_options.validate(); // Should not panic.

    const custom_options = Options{
        .frame_height = 20,
        .font_size = 14,
        .min_width = 0.5,
        .image_width = 1600,
    };
    custom_options.validate(); // Should not panic.
}

test "flame graph generator basic" {
    const options = Options{};
    const generator = Generator.init(options);

    // Test basic initialization.
    try testing.expectEqual(@as(u64, 0), generator.total_samples);
    try testing.expectEqual(@as(u32, 0), generator.max_depth);
}
