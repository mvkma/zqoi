//! By convention, root.zig is the root source file when making a library. If
//! you are making an executable, the convention is to delete this file and
//! start with main.zig instead.
const std = @import("std");
const testing = std.testing;

const OpRun: u8 = 0b1100_0000;

const OpIndex: u8 = 0b0000_0000;

const OpDiff: u8 = 0b0100_0000;

const OpLuma: u8 = 0b1000_0000;

const OpRgba: u8 = 0b1111_1111;

const OpRgb: u8 = 0b1111_1110;

const HeaderSize = 14;

const EndMarkerSize = 8;

const Magic = [_]u8{ 'q', 'o', 'i', 'f' };

const EndMarker = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 1 };

pub const PixelFormat = enum(u8) {
    rgb = 3,
    rgba = 4,
};

pub const Colorspace = enum(u8) {
    s_rgb = 0,
    linear = 1,
};

pub const Header = struct {
    width: u32,
    height: u32,
    channels: PixelFormat,
    colorspace: Colorspace,
};

pub const Pixel = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 0xff,
};

pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []const Pixel,
    colorspace: u8,
};

fn hash(p: Pixel) u8 {
    return (p.r *% 3 +% p.g *% 5 +% p.b *% 7 +% p.a *% 11) % 64;
}

fn encodeHeader(header: Header) [HeaderSize]u8 {
    var bytes: [HeaderSize]u8 = undefined;

    @memcpy(bytes[0..4], &Magic);
    std.mem.writeInt(u32, bytes[4..8], header.width, .big);
    std.mem.writeInt(u32, bytes[8..12], header.height, .big);
    bytes[12] = @intFromEnum(header.channels);
    bytes[13] = @intFromEnum(header.colorspace);

    return bytes;
}

fn decodeHeader(bytes: []const u8) Header {
    std.debug.assert(std.mem.eql(u8, bytes[0..4], &Magic));

    const header: Header = .{
        .width = std.mem.readInt(u32, bytes[4..8], .big),
        .height = std.mem.readInt(u32, bytes[8..12], .big),
        .channels = @enumFromInt(bytes[12]),
        .colorspace = @enumFromInt(bytes[13]),
    };

    return header;
}

fn same(p1: Pixel, p2: Pixel) bool {
    return (p1.r == p2.r) and (p1.g == p2.g) and (p1.b == p2.b) and (p1.a == p2.a);
}

fn toU2(n: i16) u8 {
    std.debug.assert(n > -3 and n < 2);
    return @intCast(n + 2);
}

fn toU4(n: i16) u8 {
    std.debug.assert(n > -9 and n < 8);
    return @intCast(n + 8);
}

fn toU6(n: i16) u8 {
    std.debug.assert(n > -33 and n < 32);
    return @intCast(n + 32);
}

fn fromU2(n: u32) i16 {
    std.debug.assert(0 <= n and n < 4);
    return @as(i16, @intCast(n)) - 2;
}

fn fromU4(n: u32) i16 {
    std.debug.assert(0 <= n and n < 16);
    return @as(i16, @intCast(n)) - 8;
}

fn fromU6(n: u32) i16 {
    std.debug.assert(0 <= n and n < 64);
    return @as(i16, @intCast(n)) - 32;
}

pub fn encode(allocator: std.mem.Allocator, image: Image) ![]u8 {
    var bytes = std.ArrayList(u8).init(allocator);
    defer bytes.deinit();

    const writer = bytes.writer();

    const header: Header = .{
        .width = image.width,
        .height = image.height,
        .channels = PixelFormat.rgb, // TODO
        .colorspace = Colorspace.s_rgb,
    };
    try writer.writeAll(&encodeHeader(header));

    var run: usize = 0;
    var prev: Pixel = .{ .r = 0, .g = 0, .b = 0, .a = 0xff };
    var colors: [64]Pixel = std.mem.zeroes([64]Pixel);

    for (image.pixels) |curr| {
        const seen = same(curr, prev);

        if (seen) {
            run += 1;
        }

        if (run == 62 or (run > 0 and !seen)) {
            try writer.writeByte(OpRun | @as(u8, @truncate(run - 1)));
            run = 0;
        }

        if (seen) {
            continue;
        }

        const idx = hash(curr);

        if (same(colors[idx], curr)) {
            try writer.writeByte(OpIndex | idx);
        } else {
            colors[idx] = curr;

            const dr = @as(i16, curr.r) - @as(i16, prev.r);
            const dg = @as(i16, curr.g) - @as(i16, prev.g);
            const db = @as(i16, curr.b) - @as(i16, prev.b);
            const da = @as(i16, curr.a) - @as(i16, prev.a);

            const drg = dr - dg;
            const dbg = db - dg;

            if (da != 0) {
                try writer.writeAll(&[5]u8{
                    OpRgba,
                    curr.r,
                    curr.g,
                    curr.b,
                    curr.a,
                });
            } else {
                if (dr > -3 and dr < 2 and dg > -3 and dg < 2 and db > -3 and db < 2) {
                    try writer.writeByte(OpDiff | (toU2(dr) << 4) | (toU2(dg) << 2) | toU2(db));
                } else if (dg > -33 and dg < 32 and drg > -9 and drg < 8 and dbg > -9 and dbg < 8) {
                    try writer.writeAll(&[2]u8{
                        OpLuma | toU6(dg),
                        (toU4(drg) << 4) | toU4(dbg),
                    });
                } else {
                    try writer.writeAll(&[4]u8{
                        OpRgb,
                        curr.r,
                        curr.g,
                        curr.b,
                    });
                }
            }
        }

        prev = curr;
    }

    if (run > 0) {
        try writer.writeByte(OpRun | @as(u8, @truncate(run - 1)));
        run = 0;
    }

    try writer.writeAll(&EndMarker);

    return bytes.toOwnedSlice();
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) ![]Pixel {
    const header: Header = decodeHeader(bytes[0..HeaderSize]);

    const size = header.width * header.height * @as(u32, @intFromEnum(header.channels));
    var pixels = try std.ArrayList(Pixel).initCapacity(allocator, size);
    defer pixels.deinit();

    var run: usize = 0;
    var curr: Pixel = .{ .r = 0, .g = 0, .b = 0, .a = 0xff };
    var colors: [64]Pixel = std.mem.zeroes([64]Pixel);

    var i: usize = HeaderSize;
    while (i < bytes.len - EndMarkerSize) {
        if (run > 0) {
            try pixels.appendNTimes(curr, run);
            run = 0;
        }

        const b = bytes[i];
        i += 1;

        if (b == OpRgb) {
            curr = .{
                .r = bytes[i + 0],
                .g = bytes[i + 1],
                .b = bytes[i + 2],
            };
            i += 3;
        } else if (b == OpRgba) {
            curr = .{
                .r = bytes[i + 0],
                .g = bytes[i + 1],
                .b = bytes[i + 2],
                .a = bytes[i + 3],
            };
            i += 4;
        } else if ((b & 0b1100_0000) == OpIndex) {
            curr = colors[b];
        } else if ((b & 0b1100_0000) == OpDiff) {
            const dr = fromU2((b >> 4) & 0b11);
            const dg = fromU2((b >> 2) & 0b11);
            const db = fromU2((b >> 0) & 0b11);
            curr = .{
                .r = @intCast(@as(i16, curr.r) + dr),
                .g = @intCast(@as(i16, curr.g) + dg),
                .b = @intCast(@as(i16, curr.b) + db),
            };
        } else if ((b & 0b1100_0000) == OpLuma) {
            const c = bytes[i];
            i += 1;

            const drg = fromU4((c >> 4) & 0b1111);
            const dbg = fromU4((c >> 0) & 0b1111);

            const dg = fromU6(b & 0b0011_1111);
            const dr = drg + dg;
            const db = dbg + dg;

            curr = .{
                .r = @intCast(@as(i16, curr.r) + dr),
                .g = @intCast(@as(i16, curr.g) + dg),
                .b = @intCast(@as(i16, curr.b) + db),
            };
        } else if ((b & 0b1100_0000) == OpRun) {
            run = b & 0b0011_1111;
        }

        colors[hash(curr)] = curr;

        try pixels.append(curr);
    }

    return pixels.toOwnedSlice();
}
