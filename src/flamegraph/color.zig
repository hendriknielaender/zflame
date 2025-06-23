// Color palettes and options for flame graph generation.

const std = @import("std");
const assert = std.debug.assert;

// Color type (RGB8).
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn init(r: u8, g: u8, b: u8) Color {
        return Color{ .r = r, .g = g, .b = b };
    }

    pub fn to_hex_string(self: Color, allocator: std.mem.Allocator) ![]u8 {
        return try std.fmt.allocPrint(allocator, "#{:02x}{:02x}{:02x}", .{ self.r, self.g, self.b });
    }
};

// Common colors.
pub const VDGREY = Color.init(160, 160, 160);
pub const DGREY = Color.init(200, 200, 200);

// Background gradients.
const YELLOW_GRADIENT = struct { first: []const u8 = "#eeeeee", second: []const u8 = "#eeeeb0" };
const BLUE_GRADIENT = struct { first: []const u8 = "#eeeeee", second: []const u8 = "#e0e0ff" };
const GREEN_GRADIENT = struct { first: []const u8 = "#eef2ee", second: []const u8 = "#e0ffe0" };
const GRAY_GRADIENT = struct { first: []const u8 = "#f8f8f8", second: []const u8 = "#e8e8e8" };

// Background color options.
pub const BackgroundColor = enum {
    yellow,
    blue,
    green,
    grey,
    flat,

    pub fn default() BackgroundColor {
        return .yellow;
    }

    pub fn from_string(s: []const u8) !BackgroundColor {
        if (std.mem.eql(u8, s, "yellow")) return .yellow;
        if (std.mem.eql(u8, s, "blue")) return .blue;
        if (std.mem.eql(u8, s, "green")) return .green;
        if (std.mem.eql(u8, s, "grey")) return .grey;
        // Could support flat colors with hex parsing
        return error.UnknownBackgroundColor;
    }
};

// Basic color palettes.
pub const BasicPalette = enum {
    hot,
    mem,
    io,
    red,
    green,
    blue,
    aqua,
    yellow,
    purple,
    orange,
};

// Semantic multi-palettes.
pub const MultiPalette = enum {
    java,
    js,
    perl,
    python,
    rust,
    wakeup,
};

// Main palette type.
pub const Palette = union(enum) {
    basic: BasicPalette,
    multi: MultiPalette,

    pub fn default() Palette {
        return .{ .basic = .hot };
    }

    pub fn from_string(s: []const u8) !Palette {
        // Basic palettes.
        if (std.mem.eql(u8, s, "hot")) return .{ .basic = .hot };
        if (std.mem.eql(u8, s, "mem")) return .{ .basic = .mem };
        if (std.mem.eql(u8, s, "io")) return .{ .basic = .io };
        if (std.mem.eql(u8, s, "red")) return .{ .basic = .red };
        if (std.mem.eql(u8, s, "green")) return .{ .basic = .green };
        if (std.mem.eql(u8, s, "blue")) return .{ .basic = .blue };
        if (std.mem.eql(u8, s, "aqua")) return .{ .basic = .aqua };
        if (std.mem.eql(u8, s, "yellow")) return .{ .basic = .yellow };
        if (std.mem.eql(u8, s, "purple")) return .{ .basic = .purple };
        if (std.mem.eql(u8, s, "orange")) return .{ .basic = .orange };

        // Multi palettes.
        if (std.mem.eql(u8, s, "java")) return .{ .multi = .java };
        if (std.mem.eql(u8, s, "js")) return .{ .multi = .js };
        if (std.mem.eql(u8, s, "perl")) return .{ .multi = .perl };
        if (std.mem.eql(u8, s, "python")) return .{ .multi = .python };
        if (std.mem.eql(u8, s, "rust")) return .{ .multi = .rust };
        if (std.mem.eql(u8, s, "wakeup")) return .{ .multi = .wakeup };

        return error.UnknownPalette;
    }

    pub const VARIANTS = [_][]const u8{ "aqua", "blue", "green", "hot", "io", "java", "js", "mem", "orange", "perl", "python", "purple", "red", "rust", "wakeup", "yellow" };
};

// Palette resolution functions for semantic coloring.
const java = struct {
    fn resolve(name: []const u8) BasicPalette {
        // Handle annotations (_[j], _[i], _[k]).
        if (std.mem.endsWith(u8, name, "]")) {
            if (std.mem.lastIndexOf(u8, name, "_[")) |ai| {
                if (ai + 4 == name.len) {
                    switch (name[ai + 2]) {
                        'k' => return .orange, // kernel annotation
                        'i' => return .aqua, // inline annotation
                        'j' => return .green, // jit annotation
                        else => {},
                    }
                }
            }
        }

        const java_prefix = if (std.mem.startsWith(u8, name, "L")) name[1..] else name;

        if (std.mem.indexOf(u8, name, "::") != null or
            std.mem.startsWith(u8, name, "-[") or
            std.mem.startsWith(u8, name, "+["))
        {
            // C++ or Objective C
            return .yellow;
        } else if (std.mem.indexOf(u8, java_prefix, "/") != null or
            (std.mem.indexOf(u8, java_prefix, ".") != null and !std.mem.startsWith(u8, java_prefix, "[")))
        {
            // Java
            return .green;
        } else if (java_prefix.len > 0 and std.ascii.isUpper(java_prefix[0])) {
            // Java class (starts with uppercase)
            return .green;
        } else {
            // System
            return .red;
        }
    }
};

const perl = struct {
    fn resolve(name: []const u8) BasicPalette {
        if (std.mem.endsWith(u8, name, "_[k]")) {
            return .orange;
        } else if (std.mem.indexOf(u8, name, "Perl") != null or std.mem.indexOf(u8, name, ".pl") != null) {
            return .green;
        } else if (std.mem.indexOf(u8, name, "::") != null) {
            return .yellow;
        } else {
            return .red;
        }
    }
};

const python = struct {
    fn resolve(name: []const u8) BasicPalette {
        // Check for site-packages.
        if (std.mem.indexOf(u8, name, "site-packages") != null) {
            return .aqua;
        }

        // Check for python stdlib paths.
        if (std.mem.indexOf(u8, name, "python") != null or
            std.mem.indexOf(u8, name, "Python") != null or
            std.mem.startsWith(u8, name, "<built-in") or
            std.mem.startsWith(u8, name, "<method") or
            std.mem.startsWith(u8, name, "<frozen"))
        {
            return .yellow;
        } else {
            return .red;
        }
    }
};

const js = struct {
    fn resolve(name: []const u8) BasicPalette {
        if (name.len > 0 and std.mem.trim(u8, name, " \t").len == 0) {
            return .green;
        } else if (std.mem.endsWith(u8, name, "_[k]")) {
            return .orange;
        } else if (std.mem.endsWith(u8, name, "_[j]")) {
            if (std.mem.indexOf(u8, name, "/") != null) {
                return .green;
            } else {
                return .aqua;
            }
        } else if (std.mem.indexOf(u8, name, "::") != null) {
            return .yellow;
        } else if (std.mem.indexOf(u8, name, ":") != null) {
            return .aqua;
        } else if (std.mem.indexOf(u8, name, "/")) |slash_idx| {
            if (std.mem.indexOf(u8, name[slash_idx..], "node_modules/") != null) {
                return .purple;
            } else if (std.mem.indexOf(u8, name[slash_idx..], ".js") != null) {
                return .green;
            }
        }

        return .red;
    }
};

const rust = struct {
    fn resolve(name: []const u8) BasicPalette {
        const func_name = if (std.mem.indexOf(u8, name, "`")) |backtick|
            name[backtick + 1 ..]
        else
            name;

        if (std.mem.startsWith(u8, func_name, "core::") or
            std.mem.startsWith(u8, func_name, "std::") or
            std.mem.startsWith(u8, func_name, "alloc::") or
            (std.mem.startsWith(u8, func_name, "<core::") and
                !std.mem.startsWith(u8, func_name, "<core::future::from_generator::GenFuture<T>")) or
            std.mem.startsWith(u8, func_name, "<std::") or
            std.mem.startsWith(u8, func_name, "<alloc::"))
        {
            // Rust system functions.
            return .orange;
        } else if (std.mem.indexOf(u8, func_name, "::") != null) {
            // Rust user functions.
            return .aqua;
        } else {
            // Non-Rust functions.
            return .yellow;
        }
    }
};

const wakeup = struct {
    fn resolve(_: []const u8) BasicPalette {
        return .aqua;
    }
};

// Hash function for consistent coloring.
const NamehashVariables = struct {
    vector: f32 = 0.0,
    weight: f32 = 1.0,
    max: f32 = 1.0,
    modulo: u8 = 10,

    fn update(self: *NamehashVariables, character: u8) void {
        const i = @as(f32, @floatFromInt(character % self.modulo));
        self.vector += (i / @as(f32, @floatFromInt(self.modulo - 1))) * self.weight;
        self.modulo += 1;
        self.max += self.weight;
        self.weight *= 0.70;
    }

    fn result(self: NamehashVariables) f32 {
        return 1.0 - self.vector / self.max;
    }
};

fn namehash(name: []const u8) f32 {
    var namehash_variables = NamehashVariables{};
    var name_iter = name;
    var module_name_found = false;

    if (name_iter.len == 0) return namehash_variables.result();

    namehash_variables.update(name_iter[0]);
    name_iter = name_iter[1..];

    // Check first 2 characters for backtick.
    var chars_processed: usize = 0;
    for (name_iter) |character| {
        if (chars_processed >= 2) break;
        if (character == '`') {
            module_name_found = true;
            break;
        }
        namehash_variables.update(character);
        chars_processed += 1;
    }

    // Check rest of string for backtick if not found yet.
    if (!module_name_found) {
        for (name_iter[chars_processed..]) |c| {
            if (c == '`') {
                module_name_found = true;
                break;
            }
        }
    }

    if (module_name_found) {
        namehash_variables = NamehashVariables{};

        // Find position after first backtick.
        var after_backtick = name;
        if (std.mem.indexOf(u8, name, "`")) |backtick_pos| {
            if (backtick_pos + 1 < name.len) {
                after_backtick = name[backtick_pos + 1 ..];
            }
        }

        // Process up to 3 characters after backtick.
        for (after_backtick[0..@min(3, after_backtick.len)]) |character| {
            namehash_variables.update(character);
        }
    }

    return namehash_variables.result();
}

// Color calculation macro helpers.
fn t(base: u8, scale: f32, value: f32) u8 {
    return base + @as(u8, @intFromFloat(scale * value));
}

fn rgb_components_for_palette(palette: Palette, name: []const u8, v1: f32, v2: f32, v3: f32) Color {
    const basic_palette = switch (palette) {
        .basic => |basic| basic,
        .multi => |multi| switch (multi) {
            .java => java.resolve(name),
            .perl => perl.resolve(name),
            .python => python.resolve(name),
            .js => js.resolve(name),
            .wakeup => wakeup.resolve(name),
            .rust => rust.resolve(name),
        },
    };

    return switch (basic_palette) {
        .hot => Color.init(t(205, 50, v3), t(0, 230, v1), t(0, 55, v2)),
        .mem => Color.init(t(0, 0, v3), t(190, 50, v2), t(0, 210, v1)),
        .io => Color.init(t(80, 60, v1), t(80, 60, v1), t(190, 55, v2)),
        .red => Color.init(t(200, 55, v1), t(50, 80, v1), t(50, 80, v1)),
        .green => Color.init(t(50, 60, v1), t(200, 55, v1), t(50, 60, v1)),
        .blue => Color.init(t(80, 60, v1), t(80, 60, v1), t(205, 50, v1)),
        .yellow => Color.init(t(175, 55, v1), t(175, 55, v1), t(50, 20, v1)),
        .purple => Color.init(t(190, 65, v1), t(80, 60, v1), t(190, 65, v1)),
        .aqua => Color.init(t(50, 60, v1), t(165, 55, v1), t(165, 55, v1)),
        .orange => Color.init(t(190, 65, v1), t(90, 65, v1), t(0, 0, v1)),
    };
}

// Main color generation function.
pub fn color(
    palette: Palette,
    hash: bool,
    deterministic: bool,
    name: []const u8,
    rng_fn: *const fn () f32,
) Color {
    const v1: f32 = blk: {
        if (hash) {
            break :blk namehash(name);
        } else if (deterministic) {
            // FNV hash for deterministic colors.
            var hash_val: u64 = 0xcbf29ce484222325;
            for (name) |byte| {
                hash_val ^= @as(u64, byte);
                hash_val = hash_val *% 0x100000001b3;
            }
            break :blk @as(f32, @floatCast(@as(f64, @floatFromInt(hash_val)) / @as(f64, @floatFromInt(std.math.maxInt(u64)))));
        } else {
            break :blk rng_fn();
        }
    };

    const v2: f32 = if (hash) blk: {
        // Reverse hash for second component.
        var reversed = std.ArrayList(u8).init(std.heap.page_allocator);
        defer reversed.deinit();

        var i = name.len;
        while (i > 0) {
            i -= 1;
            reversed.append(name[i]) catch break :blk v1;
        }

        break :blk namehash(reversed.items);
    } else if (deterministic) v1 else rng_fn();

    const v3: f32 = if (hash) v2 else if (deterministic) v1 else rng_fn();

    return rgb_components_for_palette(palette, name, v1, v2, v3);
}

// Color scale for differential flame graphs.
pub fn color_scale(value: isize, max: usize) Color {
    if (value == 0) {
        return Color.init(250, 250, 250);
    } else if (value > 0) {
        // Positive value (more samples) = red hue.
        const c = 100 + @as(u8, @intCast((150 * (@as(isize, @intCast(max)) - value)) / @as(isize, @intCast(max))));
        return Color.init(255, c, c);
    } else {
        // Negative value (fewer samples) = blue hue.
        const c = 100 + @as(u8, @intCast((150 * (@as(isize, @intCast(max)) + value)) / @as(isize, @intCast(max))));
        return Color.init(c, c, 255);
    }
}

// Default background color for palette.
fn default_bg_color_for(palette: Palette) BackgroundColor {
    return switch (palette) {
        .basic => |basic| switch (basic) {
            .mem => .green,
            .io => .blue,
            .red, .green, .blue, .aqua, .yellow, .purple, .orange => .grey,
            else => .yellow,
        },
        .multi => |multi| switch (multi) {
            .wakeup => .blue,
            else => .yellow,
        },
    };
}

// Background color gradient getter.
pub fn bgcolor_for(bgcolor: ?BackgroundColor, palette: Palette) struct { first: []const u8, second: []const u8 } {
    const bg = bgcolor orelse default_bg_color_for(palette);

    return switch (bg) {
        .yellow => .{ .first = YELLOW_GRADIENT.first, .second = YELLOW_GRADIENT.second },
        .blue => .{ .first = BLUE_GRADIENT.first, .second = BLUE_GRADIENT.second },
        .green => .{ .first = GREEN_GRADIENT.first, .second = GREEN_GRADIENT.second },
        .grey => .{ .first = GRAY_GRADIENT.first, .second = GRAY_GRADIENT.second },
        .flat => .{ .first = "#ffffff", .second = "#ffffff" }, // Would need hex color support
    };
}

// Parse hex color.
pub fn parse_hex_color(s: []const u8) ?Color {
    if (s.len != 7 or s[0] != '#') return null;

    const hex_part = s[1..];
    var r: u8 = 0;
    var g: u8 = 0;
    var b: u8 = 0;

    // Parse red component.
    r = (std.fmt.charToDigit(hex_part[0], 16) catch return null) << 4;
    r |= std.fmt.charToDigit(hex_part[1], 16) catch return null;

    // Parse green component.
    g = (std.fmt.charToDigit(hex_part[2], 16) catch return null) << 4;
    g |= std.fmt.charToDigit(hex_part[3], 16) catch return null;

    // Parse blue component.
    b = (std.fmt.charToDigit(hex_part[4], 16) catch return null) << 4;
    b |= std.fmt.charToDigit(hex_part[5], 16) catch return null;

    return Color.init(r, g, b);
}

// Tests
const testing = std.testing;

fn dummy_rng() f32 {
    return 0.5;
}

test "basic palette color generation" {
    const test_color = color(.{ .basic = .hot }, false, false, "test_function", &dummy_rng);
    try testing.expect(test_color.r > 0);
    try testing.expect(test_color.g >= 0);
    try testing.expect(test_color.b >= 0);
}

test "java semantic coloring" {
    const java_color = java.resolve("org/example/MyClass");
    try testing.expectEqual(BasicPalette.green, java_color);

    const kernel_color = java.resolve("something_[k]");
    try testing.expectEqual(BasicPalette.orange, kernel_color);

    const cpp_color = java.resolve("std::vector::push_back");
    try testing.expectEqual(BasicPalette.yellow, cpp_color);
}

test "rust semantic coloring" {
    const std_color = rust.resolve("std::collections::HashMap::new");
    try testing.expectEqual(BasicPalette.orange, std_color);

    const user_color = rust.resolve("myapp::module::function");
    try testing.expectEqual(BasicPalette.aqua, user_color);

    const non_rust_color = rust.resolve("malloc");
    try testing.expectEqual(BasicPalette.yellow, non_rust_color);
}

test "namehash consistency" {
    const hash1 = namehash("test_function");
    const hash2 = namehash("test_function");
    try testing.expectEqual(hash1, hash2);
}

test "hex color parsing" {
    const white = parse_hex_color("#ffffff").?;
    try testing.expectEqual(@as(u8, 255), white.r);
    try testing.expectEqual(@as(u8, 255), white.g);
    try testing.expectEqual(@as(u8, 255), white.b);

    const black = parse_hex_color("#000000").?;
    try testing.expectEqual(@as(u8, 0), black.r);
    try testing.expectEqual(@as(u8, 0), black.g);
    try testing.expectEqual(@as(u8, 0), black.b);

    try testing.expectEqual(@as(?Color, null), parse_hex_color("ffffff"));
    try testing.expectEqual(@as(?Color, null), parse_hex_color("#fffffff"));
}

test "palette from string" {
    const hot_palette = try Palette.from_string("hot");
    try testing.expectEqual(Palette{ .basic = .hot }, hot_palette);

    const java_palette = try Palette.from_string("java");
    try testing.expectEqual(Palette{ .multi = .java }, java_palette);

    try testing.expectError(error.UnknownPalette, Palette.from_string("unknown"));
}
