// Stack collapsing implementations for various profiler formats.

pub const collapse = @import("collapse/collapse.zig");
pub const perf = @import("collapse/perf.zig");
pub const dtrace = @import("collapse/dtrace.zig");
pub const sample = @import("collapse/sample.zig");
pub const guess = @import("collapse/guess.zig");
pub const vtune = @import("collapse/vtune.zig");
pub const recursive = @import("collapse/recursive.zig");
pub const xctrace = @import("collapse/xctrace.zig");

// Re-export commonly used types.
pub const Collapse = collapse.Collapse;
pub const CollapsedStack = collapse.CollapsedStack;
pub const Occurrences = collapse.Occurrences;
pub const create_collapse = collapse.create_collapse;
