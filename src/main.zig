const std = @import("std");
const Io = std.Io;

const _1brc = @import("1brc");
const measurements_path = "./measurements.txt";

const Stats = struct {
    min: f64,
    sum: f64,
    max: f64,
    count: u64,
};

// <station> -> Stats{}

pub fn main(init: std.process.Init) !void {
    // _ = init;
    const io = init.io;
    const arena = init.arena.allocator();

    var map: std.StringArrayHashMapUnmanaged(Stats) = .empty;

    const file = try Io.Dir.cwd().openFile(io, measurements_path, .{});
    defer file.close(io);

    var reader_buf: [6 * 1024]u8 = undefined;
    var reader = file.reader(io, &reader_buf);

    const reader_interface = &reader.interface;

    // var idx: usize = 0;
    while (try reader_interface.takeDelimiter('\n')) |line| {
        const station, const temperature_bytes = std.mem.cutScalar(u8, line, ';').?;
        const temperature = try std.fmt.parseFloat(f64, temperature_bytes);

        const result = try map.getOrPut(arena, station);
        const val = result.value_ptr;

        if (result.found_existing) {
            val.count += 1;
            val.sum += temperature;
            val.max = @max(val.max, temperature);
            val.min = @min(val.min, temperature);
        } else {
            result.key_ptr.* = try arena.dupe(u8, station);
            val.* = .{ .count = 1, .min = temperature, .max = temperature, .sum = temperature };
        }

        // idx += 1;

        // std.debug.print("station: {s} | temp: {d}", .{ station, temperature });
        // if (idx >= 10) break;
    }

    const SortCtx = struct {
        keys: [][]const u8,

        pub fn lessThan(self: @This(), a: usize, b: usize) bool {
            return std.mem.lessThan(u8, self.keys[a], self.keys[b]);
        }
    };

    var writer_buf: [64 * 1024]u8 = undefined;
    var writer = Io.File.Writer.init(.stdout(), io, &writer_buf);
    const writer_interface = &writer.interface;

    try writer_interface.writeByte('{');
    map.sortUnstable(SortCtx{ .keys = map.keys() });
    var iterator = map.iterator();

    var first: bool = true;
    while (iterator.next()) |station| {
        const float_count: f64 = @floatFromInt(station.value_ptr.count);
        const avg: f64 = station.value_ptr.sum / float_count;

        if (!first) try writer_interface.writeAll(", ");

        first = false;

        try writer_interface.print("{s}={d:.1}/{d:.1}/{d:.1}", .{ station.key_ptr.*, station.value_ptr.*.min, avg, station.value_ptr.*.max });

        // std.debug.print("station: {s} | stats: {any} | avg: {d}\n", .{ station.key_ptr.*, station.value_ptr.*, avg });
    }
    try writer_interface.writeAll("}\n");
    try writer_interface.flush();
}

test "does this work?" {
    // do our stuff
    // read the expected results file
    // compare hashes for our output and expected one

    const result = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{"zig-out/bin/_1brc"},
    });

    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    var our_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(result.stdout, &our_hash, .{});

    const verification_path = "./expected.txt";
    const file = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, verification_path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(file);

    var verification_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(file, &verification_hash, .{});

    try std.testing.expectEqual(our_hash, verification_hash);
}
