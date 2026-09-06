fn parseTemperature(text: []const u8) i64 {
    var ret: i64 = 0;
    const neg: i8 = @intFromBool(text[0] == '-');

    for (text[@as(usize, @intCast(neg))..]) |byte| {
        if (byte != '.') {
            ret = (ret * 10) + (byte - '0');
        }
    }

    return ret * (1 - 2 * @as(i64, @intFromBool(text[0] == '-')));
}

export fn entry(ptr: [*]const u8, len: usize) i64 {
    return parseTemperature(ptr[0..len]);
}
