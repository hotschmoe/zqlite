//! zqlite - Zig SQLite bindings
//!
//! Provides a safe Zig interface to SQLite with:
//! - Connection management with WAL mode
//! - Prepared statement binding and execution
//! - Transaction support with automatic rollback

const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const SqliteError = error{
    OpenFailed,
    PrepareFailed,
    BindFailed,
    StepFailed,
    ExecuteFailed,
    BusyTimeout,
    Corrupt,
};

pub const Database = struct {
    handle: *c.sqlite3,
    allocator: std.mem.Allocator,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Database {
        var db: ?*c.sqlite3 = null;
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        const rc = c.sqlite3_open(path_z, &db);
        if (rc != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            return SqliteError.OpenFailed;
        }

        var self = Database{ .handle = db.?, .allocator = allocator };
        try self.configure();
        return self;
    }

    fn configure(self: *Database) !void {
        try self.exec("PRAGMA journal_mode = WAL");
        try self.exec("PRAGMA synchronous = NORMAL");
        try self.exec("PRAGMA foreign_keys = ON");
        try self.exec("PRAGMA busy_timeout = 5000");
    }

    pub fn close(self: *Database) void {
        _ = c.sqlite3_close(self.handle);
    }

    pub fn exec(self: *Database, sql: []const u8) !void {
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);
        try self.execZ(sql_z);
    }

    pub fn execZ(self: *Database, sql: [:0]const u8) !void {
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.handle, sql, null, null, &err_msg);
        if (err_msg != null) {
            c.sqlite3_free(err_msg);
        }
        if (rc != c.SQLITE_OK) {
            return if (rc == c.SQLITE_BUSY or rc == c.SQLITE_LOCKED)
                SqliteError.BusyTimeout
            else
                SqliteError.ExecuteFailed;
        }
    }

    pub fn prepare(self: *Database, sql: []const u8) !Statement {
        return Statement.init(self, sql);
    }

    pub fn lastInsertRowId(self: *Database) i64 {
        return c.sqlite3_last_insert_rowid(self.handle);
    }

    pub fn changes(self: *Database) i32 {
        return @intCast(c.sqlite3_changes(self.handle));
    }

    pub fn getErrorMessage(self: *Database) []const u8 {
        const msg = c.sqlite3_errmsg(self.handle);
        if (msg) |m| {
            return std.mem.sliceTo(m, 0);
        }
        return "unknown error";
    }
};

pub const Statement = struct {
    stmt: *c.sqlite3_stmt,
    db: *Database,

    pub fn init(db: *Database, sql: []const u8) !Statement {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(
            db.handle,
            sql.ptr,
            @intCast(sql.len),
            &stmt,
            null,
        );
        if (rc != c.SQLITE_OK or stmt == null) {
            return SqliteError.PrepareFailed;
        }
        return Statement{ .stmt = stmt.?, .db = db };
    }

    pub fn deinit(self: *Statement) void {
        _ = c.sqlite3_finalize(self.stmt);
    }

    pub fn bindText(self: *Statement, idx: u32, value: ?[]const u8) !void {
        const rc = if (value) |v|
            c.sqlite3_bind_text(
                self.stmt,
                @intCast(idx),
                v.ptr,
                @intCast(v.len),
                c.SQLITE_TRANSIENT,
            )
        else
            c.sqlite3_bind_null(self.stmt, @intCast(idx));
        if (rc != c.SQLITE_OK) return SqliteError.BindFailed;
    }

    pub fn bindInt(self: *Statement, idx: u32, value: i64) !void {
        const rc = c.sqlite3_bind_int64(self.stmt, @intCast(idx), value);
        if (rc != c.SQLITE_OK) return SqliteError.BindFailed;
    }

    pub fn bindInt32(self: *Statement, idx: u32, value: i32) !void {
        const rc = c.sqlite3_bind_int(self.stmt, @intCast(idx), value);
        if (rc != c.SQLITE_OK) return SqliteError.BindFailed;
    }

    pub fn bindNull(self: *Statement, idx: u32) !void {
        const rc = c.sqlite3_bind_null(self.stmt, @intCast(idx));
        if (rc != c.SQLITE_OK) return SqliteError.BindFailed;
    }

    pub fn bindOptionalInt(self: *Statement, idx: u32, value: ?i64) !void {
        if (value) |v| {
            try self.bindInt(idx, v);
        } else {
            try self.bindNull(idx);
        }
    }

    pub fn bindOptionalInt32(self: *Statement, idx: u32, value: ?i32) !void {
        if (value) |v| {
            try self.bindInt32(idx, v);
        } else {
            try self.bindNull(idx);
        }
    }

    pub fn bindBool(self: *Statement, idx: u32, value: bool) !void {
        try self.bindInt(idx, if (value) 1 else 0);
    }

    pub fn columnText(self: *Statement, idx: u32) ?[]const u8 {
        const ptr = c.sqlite3_column_text(self.stmt, @intCast(idx));
        if (ptr == null) return null;
        const len = c.sqlite3_column_bytes(self.stmt, @intCast(idx));
        if (len <= 0) return null;
        return ptr[0..@intCast(len)];
    }

    pub fn columnInt(self: *Statement, idx: u32) i64 {
        return c.sqlite3_column_int64(self.stmt, @intCast(idx));
    }

    pub fn columnInt32(self: *Statement, idx: u32) i32 {
        return c.sqlite3_column_int(self.stmt, @intCast(idx));
    }

    pub fn columnOptionalInt(self: *Statement, idx: u32) ?i64 {
        if (c.sqlite3_column_type(self.stmt, @intCast(idx)) == c.SQLITE_NULL) {
            return null;
        }
        return self.columnInt(idx);
    }

    pub fn columnOptionalInt32(self: *Statement, idx: u32) ?i32 {
        if (c.sqlite3_column_type(self.stmt, @intCast(idx)) == c.SQLITE_NULL) {
            return null;
        }
        return self.columnInt32(idx);
    }

    pub fn columnBool(self: *Statement, idx: u32) bool {
        return self.columnInt(idx) != 0;
    }

    pub fn step(self: *Statement) !bool {
        const rc = c.sqlite3_step(self.stmt);
        return switch (rc) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            c.SQLITE_BUSY, c.SQLITE_LOCKED => SqliteError.BusyTimeout,
            c.SQLITE_CORRUPT, c.SQLITE_NOTADB => SqliteError.Corrupt,
            else => SqliteError.StepFailed,
        };
    }

    pub fn reset(self: *Statement) void {
        _ = c.sqlite3_reset(self.stmt);
        _ = c.sqlite3_clear_bindings(self.stmt);
    }
};

/// Execute a function within a transaction.
/// Commits on success, rolls back on error.
pub fn transaction(db: *Database, ctx: anytype, comptime f: fn (@TypeOf(ctx), *Database) anyerror!void) !void {
    try db.exec("BEGIN IMMEDIATE");
    f(ctx, db) catch |err| {
        db.exec("ROLLBACK") catch {};
        return err;
    };
    try db.exec("COMMIT");
}

/// Execute a function within a transaction (no context version).
pub fn transactionSimple(db: *Database, comptime f: fn (*Database) anyerror!void) !void {
    try db.exec("BEGIN IMMEDIATE");
    f(db) catch |err| {
        db.exec("ROLLBACK") catch {};
        return err;
    };
    try db.exec("COMMIT");
}

test "Database open and close in-memory" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();
}

test "Database exec creates table" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT)");
    try db.exec("INSERT INTO test (name) VALUES ('hello')");

    const count = db.changes();
    try std.testing.expectEqual(@as(i32, 1), count);
}

test "Statement prepare, bind, and step" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT, value INTEGER)");

    var insert_stmt = try db.prepare("INSERT INTO test (name, value) VALUES (?1, ?2)");
    defer insert_stmt.deinit();

    try insert_stmt.bindText(1, "test_name");
    try insert_stmt.bindInt(2, 42);
    const has_row = try insert_stmt.step();
    try std.testing.expect(!has_row);

    const row_id = db.lastInsertRowId();
    try std.testing.expectEqual(@as(i64, 1), row_id);

    var select_stmt = try db.prepare("SELECT id, name, value FROM test WHERE id = ?1");
    defer select_stmt.deinit();

    try select_stmt.bindInt(1, 1);
    const found = try select_stmt.step();
    try std.testing.expect(found);

    const id = select_stmt.columnInt(0);
    const name = select_stmt.columnText(1);
    const value = select_stmt.columnInt(2);

    try std.testing.expectEqual(@as(i64, 1), id);
    try std.testing.expectEqualStrings("test_name", name.?);
    try std.testing.expectEqual(@as(i64, 42), value);
}

test "Statement bind null and columnOptionalInt" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE test (id INTEGER PRIMARY KEY, optional_val INTEGER)");

    var insert_stmt = try db.prepare("INSERT INTO test (optional_val) VALUES (?1)");
    defer insert_stmt.deinit();

    try insert_stmt.bindNull(1);
    _ = try insert_stmt.step();

    var select_stmt = try db.prepare("SELECT optional_val FROM test WHERE id = 1");
    defer select_stmt.deinit();

    const found = try select_stmt.step();
    try std.testing.expect(found);

    const val = select_stmt.columnOptionalInt(0);
    try std.testing.expect(val == null);
}

test "Statement reset allows reuse" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT)");

    var stmt = try db.prepare("INSERT INTO test (name) VALUES (?1)");
    defer stmt.deinit();

    try stmt.bindText(1, "first");
    _ = try stmt.step();
    stmt.reset();

    try stmt.bindText(1, "second");
    _ = try stmt.step();

    var count_stmt = try db.prepare("SELECT COUNT(*) FROM test");
    defer count_stmt.deinit();
    _ = try count_stmt.step();
    const count = count_stmt.columnInt(0);
    try std.testing.expectEqual(@as(i64, 2), count);
}

test "transaction commits on success" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT)");

    try transactionSimple(&db, struct {
        fn run(d: *Database) !void {
            try d.exec("INSERT INTO test (name) VALUES ('in_transaction')");
        }
    }.run);

    var stmt = try db.prepare("SELECT COUNT(*) FROM test");
    defer stmt.deinit();
    _ = try stmt.step();
    try std.testing.expectEqual(@as(i64, 1), stmt.columnInt(0));
}

test "transaction rolls back on error" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT)");

    const result = transactionSimple(&db, struct {
        fn run(d: *Database) !void {
            try d.exec("INSERT INTO test (name) VALUES ('should_rollback')");
            return error.IntentionalFailure;
        }
    }.run);
    try std.testing.expectError(error.IntentionalFailure, result);

    var stmt = try db.prepare("SELECT COUNT(*) FROM test");
    defer stmt.deinit();
    _ = try stmt.step();
    try std.testing.expectEqual(@as(i64, 0), stmt.columnInt(0));
}

test "PRAGMA settings applied correctly" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(db_path);
    const full_path = try std.fmt.allocPrint(allocator, "{s}/test.db", .{db_path});
    defer allocator.free(full_path);

    var db = try Database.open(allocator, full_path);
    defer db.close();

    var fk_stmt = try db.prepare("PRAGMA foreign_keys");
    defer fk_stmt.deinit();
    _ = try fk_stmt.step();
    try std.testing.expectEqual(@as(i64, 1), fk_stmt.columnInt(0));

    var timeout_stmt = try db.prepare("PRAGMA busy_timeout");
    defer timeout_stmt.deinit();
    _ = try timeout_stmt.step();
    try std.testing.expectEqual(@as(i64, 5000), timeout_stmt.columnInt(0));
}

test "bindBool helper" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE test (id INTEGER PRIMARY KEY, flag INTEGER)");

    var stmt = try db.prepare("INSERT INTO test (flag) VALUES (?1)");
    defer stmt.deinit();

    try stmt.bindBool(1, true);
    _ = try stmt.step();
    stmt.reset();

    try stmt.bindBool(1, false);
    _ = try stmt.step();

    var select_stmt = try db.prepare("SELECT flag FROM test ORDER BY id");
    defer select_stmt.deinit();

    _ = try select_stmt.step();
    try std.testing.expect(select_stmt.columnBool(0));

    _ = try select_stmt.step();
    try std.testing.expect(!select_stmt.columnBool(0));
}
