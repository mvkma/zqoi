//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

const std = @import("std");

const lib = @import("zqoi_lib");

fn readRGB(allocator: std.mem.Allocator, path: []const u8) ![]lib.Pixel {
    const data = try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
    defer allocator.free(data);

    var pixels = std.ArrayList(lib.Pixel).init(allocator);
    defer pixels.deinit();

    var i: usize = 0;
    while (i < data.len) {
        try pixels.append(.{
            .r = data[i + 0],
            .g = data[i + 1],
            .b = data[i + 2],
        });
        i += 3;
    }

    return pixels.toOwnedSlice();
}

fn toRGB(allocator: std.mem.Allocator, pixels: []lib.Pixel) ![]u8 {
    var bytes = std.ArrayList(u8).init(allocator);
    defer bytes.deinit();

    const writer = bytes.writer();

    for (pixels) |pixel| {
        try writer.writeAll(&[3]u8{ pixel.r, pixel.g, pixel.b });
    }

    return bytes.toOwnedSlice();
}

fn writeToFile(bytes: []const u8, path: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    try file.writeAll(bytes);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const pixels = try readRGB(allocator, "lenna.rgb");
    defer allocator.free(pixels);

    const image: lib.Image = .{
        .height = 512,
        .width = 512,
        .pixels = pixels,
        .colorspace = 0,
    };

    const qoi_image = try lib.encode(allocator, image);
    defer allocator.free(qoi_image);

    try writeToFile(qoi_image, "lenna.qoi");

    const decoded = try lib.decode(allocator, qoi_image);
    defer allocator.free(decoded);

    const decoded_bytes = try toRGB(allocator, decoded);
    defer allocator.free(decoded_bytes);

    try writeToFile(decoded_bytes, "lenna.dec.rgb");
}
