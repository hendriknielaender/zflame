const std = @import("std");
const zbench = @import("zbench");
const zflame = @import("zflame");

const allocator = std.heap.page_allocator;

// Test data file paths (matching inferno structure)
const TEST_DATA_PERF = "tests/data/collapse-perf/go-stacks.txt";
const TEST_DATA_DTRACE = "tests/data/collapse-dtrace/java.txt";
const TEST_DATA_SAMPLE = "tests/data/collapse-sample/sample.txt";

// Helper function to read test data file
fn read_test_file(file_path: []const u8, bench_allocator: std.mem.Allocator) ![]u8 {
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("Test data file not found: {s}\n", .{file_path});
            return error.TestDataNotFound;
        },
        else => return err,
    };
    defer file.close();

    const file_size = try file.getEndPos();
    const contents = try bench_allocator.alloc(u8, file_size);
    _ = try file.readAll(contents);
    return contents;
}

// Benchmark perf stack collapse (matching inferno's perf benchmark)
fn bench_perf_collapse(bench_allocator: std.mem.Allocator) void {
    const data = read_test_file(TEST_DATA_PERF, bench_allocator) catch |err| switch (err) {
        error.TestDataNotFound => {
            // Skip benchmark if test data not available
            return;
        },
        else => return,
    };
    defer bench_allocator.free(data);

    const options = zflame.perf.Options{};
    var folder = zflame.perf.Folder.init(options) catch return;
    defer folder.deinit();

    var output_buffer: [1024 * 1024]u8 = undefined; // 1MB stack buffer
    var output_stream = std.io.fixedBufferStream(&output_buffer);

    var reader = std.io.fixedBufferStream(data);
    folder.collapse(reader.reader(), output_stream.writer()) catch return;
}

// Benchmark dtrace stack collapse (matching inferno's dtrace benchmark)
fn bench_dtrace_collapse(bench_allocator: std.mem.Allocator) void {
    const data = read_test_file(TEST_DATA_DTRACE, bench_allocator) catch |err| switch (err) {
        error.TestDataNotFound => {
            // Skip benchmark if test data not available
            return;
        },
        else => return,
    };
    defer bench_allocator.free(data);

    const options = zflame.dtrace.Options{};
    var folder = zflame.dtrace.Folder.init(options) catch return;
    defer folder.deinit();

    var output_buffer: [1024 * 1024]u8 = undefined; // 1MB stack buffer
    var output_stream = std.io.fixedBufferStream(&output_buffer);

    var reader = std.io.fixedBufferStream(data);
    folder.collapse(reader.reader(), output_stream.writer()) catch return;
}

// Benchmark sample stack collapse (matching inferno's sample benchmark)
fn bench_sample_collapse(bench_allocator: std.mem.Allocator) void {
    const data = read_test_file(TEST_DATA_SAMPLE, bench_allocator) catch |err| switch (err) {
        error.TestDataNotFound => {
            // Skip benchmark if test data not available
            return;
        },
        else => return,
    };
    defer bench_allocator.free(data);

    const options = zflame.sample.Options{};
    var folder = zflame.sample.Folder.init(options) catch return;
    defer folder.deinit();

    var output_buffer: [1024 * 1024]u8 = undefined; // 1MB stack buffer
    var output_stream = std.io.fixedBufferStream(&output_buffer);

    var reader = std.io.fixedBufferStream(data);
    folder.collapse(reader.reader(), output_stream.writer()) catch return;
}

pub fn main() !void {
    var benchmark = zbench.Benchmark.init(allocator, .{});
    defer benchmark.deinit();

    try benchmark.add("perf_collapse", bench_perf_collapse, .{});
    try benchmark.add("dtrace_collapse", bench_dtrace_collapse, .{});
    try benchmark.add("sample_collapse", bench_sample_collapse, .{});

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try benchmark.run(stdout);
}
