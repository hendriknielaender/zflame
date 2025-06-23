// Basic tests for all collapse parsers.

const std = @import("std");
const testing = std.testing;

// Import all collapse modules.
const perf_mod = @import("collapse/perf.zig");
const dtrace_mod = @import("collapse/dtrace.zig");
const sample_mod = @import("collapse/sample.zig");
const vtune_mod = @import("collapse/vtune.zig");
const xctrace_mod = @import("collapse/xctrace.zig");
const recursive_mod = @import("collapse/recursive.zig");
const guess_mod = @import("collapse/guess.zig");

test "perf basic functionality" {
    var folder = try perf_mod.Folder.init(.{});
    defer folder.deinit();

    const input =
        "boa_cli 12937 10360.271071:   10101010 cpu-clock:uhH: \n" ++
        "            562039122f0f func1+0xbf (/workspaces/boa/target/debug/boa_cli)\n" ++
        "            56203912789e func2+0xe (/workspaces/boa/target/debug/boa_cli)\n" ++
        "\n";

    var input_stream = std.io.fixedBufferStream(input);
    var output_buffer: [4096]u8 = undefined;
    var output_stream = std.io.fixedBufferStream(&output_buffer);

    try folder.collapse(input_stream.reader(), output_stream.writer());

    const result = output_stream.getWritten();
    try testing.expect(result.len > 0);
}

test "dtrace basic functionality" {
    var folder = try dtrace_mod.Folder.init(.{});
    defer folder.deinit();

    const input =
        "# dtrace -x stackindent=1 -n 'profile-1234hz { @[ustack()] = count(); }'\n" ++
        "dtrace: description 'profile-1234hz { @[ustack()] = count(); }' matched 1 probe\n" ++
        "\n" ++
        "              libc.so.1`_lwp_start\n" ++
        "              libpthread.so.1`pthread_start\n" ++
        "              myapp`main\n" ++
        "                5\n" ++
        "\n";

    var input_stream = std.io.fixedBufferStream(input);
    var output_buffer: [4096]u8 = undefined;
    var output_stream = std.io.fixedBufferStream(&output_buffer);

    try folder.collapse(input_stream.reader(), output_stream.writer());

    const result = output_stream.getWritten();
    try testing.expect(result.len > 0);
}

test "sample basic functionality" {
    var folder = try sample_mod.Folder.init(.{});
    defer folder.deinit();

    const input =
        "Sample analysis of process 1234:\n" ++
        "Call graph:\n" ++
        "    100 Thread_1\n" ++
        "    + 100 start_wqthread  (in libsystem_pthread.dylib)\n" ++
        "    +   100 work_function  (in myapp)\n" ++
        "Total number in stack: 100\n";

    var input_stream = std.io.fixedBufferStream(input);
    var output_buffer: [4096]u8 = undefined;
    var output_stream = std.io.fixedBufferStream(&output_buffer);

    try folder.collapse(input_stream.reader(), output_stream.writer());

    const result = output_stream.getWritten();
    try testing.expect(result.len > 0);
}

test "vtune basic functionality" {
    var folder = try vtune_mod.Folder.init(.{});
    defer folder.deinit();

    const input =
        "Function Stack,CPU Time:Self,Module\n" ++
        "main,0.500,myapp\n" ++
        " worker_func,0.300,myapp\n" ++
        "  inner_func,0.200,myapp\n";

    var input_stream = std.io.fixedBufferStream(input);
    var output_buffer: [4096]u8 = undefined;
    var output_stream = std.io.fixedBufferStream(&output_buffer);

    try folder.collapse(input_stream.reader(), output_stream.writer());

    const result = output_stream.getWritten();
    try testing.expect(result.len > 0);
}

test "xctrace basic functionality" {
    var folder = try xctrace_mod.Folder.init(.{});
    defer folder.deinit();

    const input =
        "<?xml version=\"1.0\"?>\n" ++
        "<trace-query-result>\n" ++
        "<node>\n" ++
        "  <row>\n" ++
        "    <backtrace id=\"10\">\n" ++
        "      <frame id=\"11\" name=\"main\" addr=\"0x102af5fa0\"></frame>\n" ++
        "      <frame id=\"12\" name=\"worker_func\" addr=\"0x102af5d99\"></frame>\n" ++
        "    </backtrace>\n" ++
        "  </row>\n" ++
        "</node>\n" ++
        "</trace-query-result>\n";

    var input_stream = std.io.fixedBufferStream(input);
    var output_buffer: [4096]u8 = undefined;
    var output_stream = std.io.fixedBufferStream(&output_buffer);

    try folder.collapse(input_stream.reader(), output_stream.writer());

    const result = output_stream.getWritten();
    try testing.expect(result.len > 0);
}

test "recursive basic functionality" {
    var folder = try recursive_mod.Folder.init(.{});
    defer folder.deinit();

    const input =
        "main;recursive;recursive;recursive;helper 1\n" ++
        "main;worker;inner 5\n" ++
        "main;func;func;other 3\n";

    var input_stream = std.io.fixedBufferStream(input);
    var output_buffer: [4096]u8 = undefined;
    var output_stream = std.io.fixedBufferStream(&output_buffer);

    try folder.collapse(input_stream.reader(), output_stream.writer());

    const result = output_stream.getWritten();
    try testing.expect(result.len > 0);
}

test "guess basic functionality" {
    var folder = guess_mod.Folder.init(.{});
    defer folder.deinit();

    const input =
        "boa_cli 12937 10360.271071:   10101010 cpu-clock:uhH: \n" ++
        "            562039122f0f <std::collections::hash::map::HashMap<K,V> as gc::trace::Trace>::trace+0xbf (/workspaces/boa/target/debug/boa_cli)\n" ++
        "            56203912789e <alloc::boxed::Box<T> as gc::trace::Trace>::trace::mark+0xe (/workspaces/boa/target/debug/boa_cli)\n" ++
        "\n";

    var input_stream = std.io.fixedBufferStream(input);
    var output_buffer: [4096]u8 = undefined;
    var output_stream = std.io.fixedBufferStream(&output_buffer);

    try folder.collapse(input_stream.reader(), output_stream.writer());

    const result = output_stream.getWritten();
    try testing.expect(result.len > 0);
}
