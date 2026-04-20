const std = @import("std");
const zbench = @import("zbench");
const zflame = @import("zflame");
const Io = std.Io;

// Test data file paths matching inferno structure.
const TEST_DATA_PERF = "tests/data/collapse-perf/go-stacks.txt";
const TEST_DATA_DTRACE = "tests/data/collapse-dtrace/java.txt";
const TEST_DATA_SAMPLE = "tests/data/collapse-sample/sample.txt";

var data_perf: []const u8 = &.{};
var data_dtrace: []const u8 = &.{};
var data_sample: []const u8 = &.{};

// Helper function to read test data file.
fn read_test_file(io: Io, file_path: []const u8, bench_allocator: std.mem.Allocator) ![]u8 {
    var file = Io.Dir.cwd().openFile(io, file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("Test data file not found: {s}\n", .{file_path});
            return error.TestDataNotFound;
        },
        else => return err,
    };
    defer file.close(io);

    const file_size = try file.length(io);
    const file_size_usize = std.math.cast(usize, file_size) orelse return error.FileTooBig;
    const contents = try bench_allocator.alloc(u8, file_size_usize);
    errdefer bench_allocator.free(contents);

    var reader_buffer: [16 * 1024]u8 = undefined;
    var reader = file.reader(io, &reader_buffer);
    try reader.interface.readSliceAll(contents);

    return contents;
}

// Benchmark perf stack collapse matching inferno's perf benchmark.
fn bench_perf_collapse(bench_allocator: std.mem.Allocator) void {
    _ = bench_allocator;
    if (data_perf.len == 0) return;

    const options = zflame.perf.Options{};
    var folder = zflame.perf.Folder.init(options) catch return;
    defer folder.deinit();

    var output_buffer: [1024 * 1024]u8 = undefined;
    var output_writer: Io.Writer = .fixed(&output_buffer);

    var reader: Io.Reader = .fixed(data_perf);
    folder.collapse(&reader, &output_writer) catch return;
}

// Benchmark dtrace stack collapse matching inferno's dtrace benchmark.
fn bench_dtrace_collapse(bench_allocator: std.mem.Allocator) void {
    _ = bench_allocator;
    if (data_dtrace.len == 0) return;

    const options = zflame.dtrace.Options{};
    var folder = zflame.dtrace.Folder.init(options) catch return;
    defer folder.deinit();

    var output_buffer: [1024 * 1024]u8 = undefined;
    var output_writer: Io.Writer = .fixed(&output_buffer);

    var reader: Io.Reader = .fixed(data_dtrace);
    folder.collapse(&reader, &output_writer) catch return;
}

// Benchmark sample stack collapse matching inferno's sample benchmark.
fn bench_sample_collapse(bench_allocator: std.mem.Allocator) void {
    _ = bench_allocator;
    if (data_sample.len == 0) return;

    const options = zflame.sample.Options{};
    var folder = zflame.sample.Folder.init(options) catch return;
    defer folder.deinit();

    var output_buffer: [1024 * 1024]u8 = undefined;
    var output_writer: Io.Writer = .fixed(&output_buffer);

    var reader: Io.Reader = .fixed(data_sample);
    folder.collapse(&reader, &output_writer) catch return;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    data_perf = read_test_file(init.io, TEST_DATA_PERF, allocator) catch &.{};
    defer if (data_perf.len > 0) allocator.free(data_perf);

    data_dtrace = read_test_file(init.io, TEST_DATA_DTRACE, allocator) catch &.{};
    defer if (data_dtrace.len > 0) allocator.free(data_dtrace);

    data_sample = read_test_file(init.io, TEST_DATA_SAMPLE, allocator) catch &.{};
    defer if (data_sample.len > 0) allocator.free(data_sample);

    var benchmark = zbench.Benchmark.init(allocator, .{});
    defer benchmark.deinit();

    try benchmark.add("perf_collapse", bench_perf_collapse, .{});
    try benchmark.add("dtrace_collapse", bench_dtrace_collapse, .{});
    try benchmark.add("sample_collapse", bench_sample_collapse, .{});

    try benchmark.run(init.io, Io.File.stdout());
}
