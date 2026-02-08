const std = @import("std");
const zqlite = @import("zqlite");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var db = try zqlite.Database.open(allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)");

    var insert = try db.prepare("INSERT INTO users (name, age) VALUES (?1, ?2)");
    defer insert.deinit();

    try insert.bindText(1, "Alice");
    try insert.bindInt32(2, 30);
    _ = try insert.step();
    insert.reset();

    try insert.bindText(1, "Bob");
    try insert.bindInt32(2, 25);
    _ = try insert.step();

    var query = try db.prepare("SELECT name, age FROM users ORDER BY name");
    defer query.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("Users:\n", .{});
    while (try query.step()) {
        const name = query.columnText(0) orelse "(null)";
        const age = query.columnInt32(1);
        try stdout.print("  {s}, age {d}\n", .{ name, age });
    }

    try stdout.flush();
}
