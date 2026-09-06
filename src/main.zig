const std = @import("std");
const Io = std.Io;

const _1brc = @import("1brc");
const measurements_path = "./measurements.txt";

const Stats = struct {
    min: i64,
    sum: i64,
    max: i64,
    count: i64,
};

const morsel_count: usize = 56;
const thread_count: usize = 16;

var morsels: [morsel_count]Morsel = undefined;
var morsel_ready_idx = std.atomic.Value(usize).init(0);

const Morsel = struct { start: usize, end: usize };

// <station> -> Stats{}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var map: std.StringArrayHashMapUnmanaged(Stats) = .empty;
    try map.ensureTotalCapacity(arena, 10000);

    const file = try Io.Dir.cwd().openFile(io, measurements_path, .{});
    defer file.close(io);

    const yo = try file.stat(io);
    const measurements = try std.posix.mmap(
        null,
        yo.size,
        .{ .READ = true },
        .{ .TYPE = .PRIVATE },
        file.handle,
        0,
    );
    defer std.posix.munmap(measurements);

    var start: usize = 0;
    const chunk_size = measurements.len / morsel_count;
    for (0..morsel_count) |i| {
        var end = @min(measurements.len, start + chunk_size);
        const wut = std.mem.indexOfScalar(u8, measurements[end..], '\n') orelse 0;

        end += wut;
        morsels[i] = .{ .start = start, .end = end };
        start = end + 1;

        // std.debug.print("idk man: {c}\n", .{measurements[end..][wut]});
    }

    // std.debug.print("measuments size: {d} | morsels are: {any}\n", .{ measurements.len, morsels });

    var threads: [thread_count]std.Thread = undefined;
    var maps: [thread_count]std.StringArrayHashMapUnmanaged(Stats) = undefined;

    for (0..thread_count) |i| {
        maps[i] = .empty;
        try maps[i].ensureTotalCapacity(arena, 10000);
        threads[i] = try std.Thread.spawn(.{}, process, .{ arena, &maps[i], measurements });
    }

    // join threads and merge the maps into big map
    for (0..thread_count) |i| {
        threads[i].join();

        var iterator = maps[i].iterator();

        while (iterator.next()) |entry| {
            const idk = try map.getOrPut(arena, entry.key_ptr.*);

            if (idk.found_existing) {
                const my_value = entry.value_ptr.*;
                const val = idk.value_ptr;
                val.count += my_value.count;
                val.sum += my_value.sum;
                val.max = @max(val.max, my_value.max);
                val.min = @min(val.min, my_value.min);
            } else {
                idk.value_ptr.* = entry.value_ptr.*;
            }
        }
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
        const float_count: f64 = @floatFromInt(station.value_ptr.count * 10);
        const float_sum: f64 = @floatFromInt(station.value_ptr.sum);
        const float_min: f64 = @as(f64, @floatFromInt(station.value_ptr.*.min)) / 10.0;
        const float_max: f64 = @as(f64, @floatFromInt(station.value_ptr.*.max)) / 10.0;
        const avg: f64 = float_sum / float_count;

        if (!first) try writer_interface.writeAll(", ");

        first = false;

        try writer_interface.print("{s}={d:.1}/{d:.1}/{d:.1}", .{ station.key_ptr.*, float_min, avg, float_max });
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

fn parseTemperature(text: []const u8) i64 {
    const is_neg: usize = @intFromBool(text[0] == '-');
    const has_two_integers: i64 = @intFromBool(text.len - is_neg == 4);
    const ret: i64 = @as(i64, @as(i64, (text[text.len - 1] - '0') + 10 * @as(i64, (text[text.len - 3] - '0'))) + has_two_integers * 100 * @as(i64, (text[is_neg] - '0')));
    if (is_neg == 1) return -ret;
    return ret;
}

/// okay, so what does this guy needs ?
/// each core needs its own map
/// so: map,measurements, morsel
fn process(
    arena: std.mem.Allocator,
    map: *std.StringArrayHashMapUnmanaged(Stats),
    measurements: []u8,
) !void {
    while (true) {
        // get the morsel
        const idx = morsel_ready_idx.fetchAdd(1, .monotonic);
        if (idx >= morsel_count) {
            break;
        }

        const morsel = morsels[idx];

        var it = std.mem.splitScalar(u8, measurements[morsel.start..morsel.end], '\n');

        while (it.next()) |line| {
            if (line.len == 0) break;
            const station, const temperature_bytes = std.mem.cutScalar(u8, line, ';').?;
            const temperature = parseTemperature(temperature_bytes);

            const result = try map.getOrPut(arena, station);
            const val = result.value_ptr;

            if (result.found_existing) {
                val.count += 1;
                val.sum += temperature;
                val.max = @max(val.max, temperature);
                val.min = @min(val.min, temperature);
            } else {
                result.key_ptr.* = station;
                val.* = .{ .count = 1, .min = temperature, .max = temperature, .sum = temperature };
            }
        }
    }
}

// how the hell do we merge those maps darn it
// just be a brute

// so the whole game plan is that we:
// - basically pre determine morsel boundaries
// - then just let threads consume them at their own pace

// now we need the merge logic so we can use multiple threads
