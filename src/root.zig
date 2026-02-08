//! zqlite - Zig SQLite bindings
//!
//! Provides a safe Zig interface to SQLite with:
//! - Connection management with WAL mode
//! - Prepared statement binding and execution
//! - Transaction support with automatic rollback

const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("sqlite3.h");
});

// SQLITE_STATIC (null) instead of SQLITE_TRANSIENT which Zig cannot
// represent as a function pointer on cross-compile targets (alignment).
const SQLITE_STATIC: c.sqlite3_destructor_type = null;

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

pub const SqliteError = error{
    // Primary result codes
    Error, // SQLITE_ERROR (1)
    Internal, // SQLITE_INTERNAL (2)
    Perm, // SQLITE_PERM (3)
    Abort, // SQLITE_ABORT (4)
    Busy, // SQLITE_BUSY (5)
    Locked, // SQLITE_LOCKED (6)
    NoMem, // SQLITE_NOMEM (7)
    ReadOnly, // SQLITE_READONLY (8)
    Interrupt, // SQLITE_INTERRUPT (9)
    IoErr, // SQLITE_IOERR (10)
    Corrupt, // SQLITE_CORRUPT (11)
    NotFound, // SQLITE_NOTFOUND (12)
    Full, // SQLITE_FULL (13)
    CantOpen, // SQLITE_CANTOPEN (14)
    Protocol, // SQLITE_PROTOCOL (15)
    Schema, // SQLITE_SCHEMA (17)
    TooBig, // SQLITE_TOOBIG (18)
    Constraint, // SQLITE_CONSTRAINT (19)
    Mismatch, // SQLITE_MISMATCH (20)
    Misuse, // SQLITE_MISUSE (21)
    Auth, // SQLITE_AUTH (23)
    Range, // SQLITE_RANGE (25)
    NotADb, // SQLITE_NOTADB (26)

    // Extended: constraint subtypes
    ConstraintCheck,
    ConstraintCommitHook,
    ConstraintForeignKey,
    ConstraintNotNull,
    ConstraintPrimaryKey,
    ConstraintTrigger,
    ConstraintUnique,
    ConstraintRowId,

    // Extended: busy subtypes
    BusyRecovery,
    BusySnapshot,
    BusyTimeout,

    // Debug-only
    MultipleStatements,
};

/// Extended result codes must be matched before their primary codes
/// because SQLite extended codes embed the primary code in the low byte.
pub fn errorFromCode(rc: c_int) SqliteError {
    return switch (rc) {
        c.SQLITE_CONSTRAINT_CHECK => SqliteError.ConstraintCheck,
        c.SQLITE_CONSTRAINT_COMMITHOOK => SqliteError.ConstraintCommitHook,
        c.SQLITE_CONSTRAINT_FOREIGNKEY => SqliteError.ConstraintForeignKey,
        c.SQLITE_CONSTRAINT_NOTNULL => SqliteError.ConstraintNotNull,
        c.SQLITE_CONSTRAINT_PRIMARYKEY => SqliteError.ConstraintPrimaryKey,
        c.SQLITE_CONSTRAINT_TRIGGER => SqliteError.ConstraintTrigger,
        c.SQLITE_CONSTRAINT_UNIQUE => SqliteError.ConstraintUnique,
        c.SQLITE_CONSTRAINT_ROWID => SqliteError.ConstraintRowId,

        c.SQLITE_BUSY_RECOVERY => SqliteError.BusyRecovery,
        c.SQLITE_BUSY_SNAPSHOT => SqliteError.BusySnapshot,
        c.SQLITE_BUSY_TIMEOUT => SqliteError.BusyTimeout,

        c.SQLITE_ERROR => SqliteError.Error,
        c.SQLITE_INTERNAL => SqliteError.Internal,
        c.SQLITE_PERM => SqliteError.Perm,
        c.SQLITE_ABORT => SqliteError.Abort,
        c.SQLITE_BUSY => SqliteError.Busy,
        c.SQLITE_LOCKED => SqliteError.Locked,
        c.SQLITE_NOMEM => SqliteError.NoMem,
        c.SQLITE_READONLY => SqliteError.ReadOnly,
        c.SQLITE_INTERRUPT => SqliteError.Interrupt,
        c.SQLITE_IOERR => SqliteError.IoErr,
        c.SQLITE_CORRUPT => SqliteError.Corrupt,
        c.SQLITE_NOTFOUND => SqliteError.NotFound,
        c.SQLITE_FULL => SqliteError.Full,
        c.SQLITE_CANTOPEN => SqliteError.CantOpen,
        c.SQLITE_PROTOCOL => SqliteError.Protocol,
        c.SQLITE_SCHEMA => SqliteError.Schema,
        c.SQLITE_TOOBIG => SqliteError.TooBig,
        c.SQLITE_CONSTRAINT => SqliteError.Constraint,
        c.SQLITE_MISMATCH => SqliteError.Mismatch,
        c.SQLITE_MISUSE => SqliteError.Misuse,
        c.SQLITE_AUTH => SqliteError.Auth,
        c.SQLITE_RANGE => SqliteError.Range,
        c.SQLITE_NOTADB => SqliteError.NotADb,

        else => SqliteError.Error,
    };
}

pub fn isUnique(err: SqliteError) bool {
    return err == SqliteError.ConstraintUnique;
}

pub fn isConstraint(err: SqliteError) bool {
    return switch (err) {
        SqliteError.Constraint,
        SqliteError.ConstraintCheck,
        SqliteError.ConstraintCommitHook,
        SqliteError.ConstraintForeignKey,
        SqliteError.ConstraintNotNull,
        SqliteError.ConstraintPrimaryKey,
        SqliteError.ConstraintTrigger,
        SqliteError.ConstraintUnique,
        SqliteError.ConstraintRowId,
        => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Open Flags (for sqlite3_open_v2)
// ---------------------------------------------------------------------------

pub const OpenFlags = struct {
    pub const READONLY: c_int = c.SQLITE_OPEN_READONLY;
    pub const READWRITE: c_int = c.SQLITE_OPEN_READWRITE;
    pub const CREATE: c_int = c.SQLITE_OPEN_CREATE;
    pub const URI: c_int = c.SQLITE_OPEN_URI;
    pub const MEMORY: c_int = c.SQLITE_OPEN_MEMORY;
    pub const NOMUTEX: c_int = c.SQLITE_OPEN_NOMUTEX;
    pub const FULLMUTEX: c_int = c.SQLITE_OPEN_FULLMUTEX;
    pub const SHAREDCACHE: c_int = c.SQLITE_OPEN_SHAREDCACHE;
    pub const PRIVATECACHE: c_int = c.SQLITE_OPEN_PRIVATECACHE;
    pub const NOFOLLOW: c_int = c.SQLITE_OPEN_NOFOLLOW;
    pub const EXRESCODE: c_int = c.SQLITE_OPEN_EXRESCODE;

    pub const DEFAULT: c_int = READWRITE | CREATE | EXRESCODE;
};

// ---------------------------------------------------------------------------
// Column Type
// ---------------------------------------------------------------------------

pub const ColumnType = enum(c_int) {
    integer = c.SQLITE_INTEGER,
    float = c.SQLITE_FLOAT,
    text = c.SQLITE3_TEXT,
    blob = c.SQLITE_BLOB,
    null = c.SQLITE_NULL,
};

/// Marker type for binding blob data via comptime tuple binding.
/// Use Blob{.data = slice} to distinguish blob from text ([]const u8).
pub const Blob = struct {
    data: ?[]const u8,
};

// ---------------------------------------------------------------------------
// Database
// ---------------------------------------------------------------------------

pub const Database = struct {
    handle: *c.sqlite3,
    allocator: std.mem.Allocator,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Database {
        return openWithFlags(allocator, path, OpenFlags.DEFAULT);
    }

    pub fn openWithFlags(allocator: std.mem.Allocator, path: []const u8, flags: c_int) !Database {
        var db: ?*c.sqlite3 = null;
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        const rc = c.sqlite3_open_v2(path_z, &db, flags, null);
        if (rc != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            return errorFromCode(rc);
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
        if (err_msg) |msg| c.sqlite3_free(msg);
        if (rc != c.SQLITE_OK) return errorFromCode(rc);
    }

    pub fn prepare(self: *Database, sql: []const u8) !Statement {
        return Statement.init(self, sql);
    }

    /// Prepare, bind, and execute a single DML statement (INSERT/UPDATE/DELETE).
    pub fn execDml(self: *Database, sql: []const u8, args: anytype) !void {
        var stmt = try self.prepare(sql);
        defer stmt.deinit();
        try stmt.bind(args);
        _ = try stmt.step();
    }

    /// Prepare and bind a query, returning the statement ready for stepping.
    /// Caller owns the returned Statement and must call deinit().
    pub fn query(self: *Database, sql: []const u8, args: anytype) !Statement {
        var stmt = try self.prepare(sql);
        try stmt.bind(args);
        return stmt;
    }

    /// Execute a query and return an iterator over the result rows.
    /// Caller must call deinit() on the returned Rows.
    pub fn rows(self: *Database, sql: []const u8, args: anytype) !Rows {
        var stmt = try self.prepare(sql);
        errdefer stmt.deinit();
        try stmt.bind(args);
        return Rows{ .stmt = stmt };
    }

    /// Execute a query expecting at most one row.
    /// Returns a Rows iterator -- call next() once to get the Row, then deinit().
    /// Pattern:
    ///   var result = try db.row("SELECT ... WHERE id = ?1", .{id});
    ///   defer result.deinit();
    ///   if (result.next()) |r| { const name = r.text(0); }
    pub fn row(self: *Database, sql: []const u8, args: anytype) !Rows {
        return self.rows(sql, args);
    }

    pub fn lastInsertRowId(self: *Database) i64 {
        return c.sqlite3_last_insert_rowid(self.handle);
    }

    pub fn changes(self: *Database) i32 {
        return @intCast(c.sqlite3_changes(self.handle));
    }

    pub fn getErrorMessage(self: *Database) []const u8 {
        const msg = c.sqlite3_errmsg(self.handle) orelse return "unknown error";
        return std.mem.sliceTo(msg, 0);
    }
};

// ---------------------------------------------------------------------------
// Statement
// ---------------------------------------------------------------------------

pub const Statement = struct {
    stmt: *c.sqlite3_stmt,
    db: *Database,

    pub fn init(db: *Database, sql: []const u8) !Statement {
        var stmt: ?*c.sqlite3_stmt = null;
        var tail: [*c]const u8 = undefined;
        const rc = c.sqlite3_prepare_v2(
            db.handle,
            sql.ptr,
            @intCast(sql.len),
            &stmt,
            &tail,
        );
        if (rc != c.SQLITE_OK or stmt == null) {
            return errorFromCode(if (rc != c.SQLITE_OK) rc else c.SQLITE_ERROR);
        }

        if (comptime builtin.mode == .Debug) {
            const sql_end = @intFromPtr(sql.ptr) + sql.len;
            const tail_addr = @intFromPtr(tail);
            if (tail_addr < sql_end) {
                var tail_stmt: ?*c.sqlite3_stmt = null;
                _ = c.sqlite3_prepare_v2(db.handle, tail, @intCast(sql_end - tail_addr), &tail_stmt, null);
                if (tail_stmt) |ts| {
                    _ = c.sqlite3_finalize(ts);
                    _ = c.sqlite3_finalize(stmt.?);
                    return SqliteError.MultipleStatements;
                }
            }
        }

        return .{ .stmt = stmt.?, .db = db };
    }

    pub fn deinit(self: *Statement) void {
        _ = c.sqlite3_finalize(self.stmt);
    }

    // -- Binding --

    pub fn bindText(self: *Statement, idx: u32, value: ?[]const u8) !void {
        const rc = if (value) |v|
            c.sqlite3_bind_text(
                self.stmt,
                @intCast(idx),
                v.ptr,
                @intCast(v.len),
                SQLITE_STATIC,
            )
        else
            c.sqlite3_bind_null(self.stmt, @intCast(idx));
        if (rc != c.SQLITE_OK) return errorFromCode(rc);
    }

    pub fn bindBlob(self: *Statement, idx: u32, value: ?[]const u8) !void {
        const rc = if (value) |v|
            c.sqlite3_bind_blob(
                self.stmt,
                @intCast(idx),
                @ptrCast(v.ptr),
                @intCast(v.len),
                SQLITE_STATIC,
            )
        else
            c.sqlite3_bind_null(self.stmt, @intCast(idx));
        if (rc != c.SQLITE_OK) return errorFromCode(rc);
    }

    pub fn bindInt(self: *Statement, idx: u32, value: i64) !void {
        const rc = c.sqlite3_bind_int64(self.stmt, @intCast(idx), value);
        if (rc != c.SQLITE_OK) return errorFromCode(rc);
    }

    pub fn bindInt32(self: *Statement, idx: u32, value: i32) !void {
        const rc = c.sqlite3_bind_int(self.stmt, @intCast(idx), value);
        if (rc != c.SQLITE_OK) return errorFromCode(rc);
    }

    pub fn bindFloat(self: *Statement, idx: u32, value: f64) !void {
        const rc = c.sqlite3_bind_double(self.stmt, @intCast(idx), value);
        if (rc != c.SQLITE_OK) return errorFromCode(rc);
    }

    pub fn bindNull(self: *Statement, idx: u32) !void {
        const rc = c.sqlite3_bind_null(self.stmt, @intCast(idx));
        if (rc != c.SQLITE_OK) return errorFromCode(rc);
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

    pub fn bindOptionalFloat(self: *Statement, idx: u32, value: ?f64) !void {
        if (value) |v| {
            try self.bindFloat(idx, v);
        } else {
            try self.bindNull(idx);
        }
    }

    pub fn bindBool(self: *Statement, idx: u32, value: bool) !void {
        try self.bindInt(idx, if (value) 1 else 0);
    }

    // -- Comptime tuple binding --

    /// Bind all fields of a tuple to positional parameters (1-indexed).
    pub fn bind(self: *Statement, args: anytype) !void {
        const Args = @TypeOf(args);
        const fields = @typeInfo(Args).@"struct".fields;
        inline for (fields, 0..) |field, i| {
            const idx: u32 = @intCast(i + 1);
            try self.bindField(idx, field.type, @field(args, field.name));
        }
    }

    fn bindField(self: *Statement, idx: u32, comptime T: type, value: T) !void {
        switch (@typeInfo(T)) {
            .null => try self.bindNull(idx),
            .bool => try self.bindBool(idx, value),
            .int => |int_info| {
                if (int_info.bits <= 32 and int_info.signedness == .signed) {
                    try self.bindInt32(idx, @intCast(value));
                } else {
                    try self.bindInt(idx, @intCast(value));
                }
            },
            .comptime_int => {
                if (value >= std.math.minInt(i32) and value <= std.math.maxInt(i32)) {
                    try self.bindInt32(idx, @intCast(value));
                } else {
                    try self.bindInt(idx, @intCast(value));
                }
            },
            .float, .comptime_float => try self.bindFloat(idx, @floatCast(value)),
            .optional => {
                if (value) |v| {
                    try self.bindField(idx, @TypeOf(v), v);
                } else {
                    try self.bindNull(idx);
                }
            },
            .@"struct" => {
                if (T == Blob) {
                    try self.bindBlob(idx, value.data);
                } else {
                    @compileError("unsupported struct type for binding");
                }
            },
            .pointer => |ptr| {
                if (ptr.size == .slice and ptr.child == u8) {
                    try self.bindText(idx, value);
                } else if (ptr.size == .one) {
                    const child_info = @typeInfo(ptr.child);
                    if (child_info == .array and child_info.array.child == u8) {
                        try self.bindText(idx, value);
                    } else {
                        @compileError("unsupported pointer type for binding");
                    }
                } else {
                    @compileError("unsupported pointer type for binding");
                }
            },
            else => @compileError("unsupported type for binding: " ++ @typeName(T)),
        }
    }

    // -- Column extraction --

    pub fn columnText(self: *Statement, idx: u32) ?[]const u8 {
        const col: c_int = @intCast(idx);
        const ptr = c.sqlite3_column_text(self.stmt, col) orelse return null;
        const len = c.sqlite3_column_bytes(self.stmt, col);
        if (len <= 0) return null;
        return ptr[0..@intCast(len)];
    }

    pub fn columnBlob(self: *Statement, idx: u32) ?[]const u8 {
        const col: c_int = @intCast(idx);
        const raw = c.sqlite3_column_blob(self.stmt, col) orelse return null;
        const len = c.sqlite3_column_bytes(self.stmt, col);
        if (len <= 0) return null;
        const ptr: [*]const u8 = @ptrCast(raw);
        return ptr[0..@intCast(len)];
    }

    pub fn columnInt(self: *Statement, idx: u32) i64 {
        return c.sqlite3_column_int64(self.stmt, @intCast(idx));
    }

    pub fn columnInt32(self: *Statement, idx: u32) i32 {
        return c.sqlite3_column_int(self.stmt, @intCast(idx));
    }

    pub fn columnFloat(self: *Statement, idx: u32) f64 {
        return c.sqlite3_column_double(self.stmt, @intCast(idx));
    }

    pub fn columnIsNull(self: *Statement, idx: u32) bool {
        return self.columnType(idx) == .null;
    }

    pub fn columnOptionalInt(self: *Statement, idx: u32) ?i64 {
        return if (self.columnIsNull(idx)) null else self.columnInt(idx);
    }

    pub fn columnOptionalInt32(self: *Statement, idx: u32) ?i32 {
        return if (self.columnIsNull(idx)) null else self.columnInt32(idx);
    }

    pub fn columnOptionalFloat(self: *Statement, idx: u32) ?f64 {
        return if (self.columnIsNull(idx)) null else self.columnFloat(idx);
    }

    pub fn columnBool(self: *Statement, idx: u32) bool {
        return self.columnInt(idx) != 0;
    }

    // -- Column metadata --

    pub fn columnCount(self: *Statement) u32 {
        return @intCast(c.sqlite3_column_count(self.stmt));
    }

    pub fn columnName(self: *Statement, idx: u32) ?[]const u8 {
        const name = c.sqlite3_column_name(self.stmt, @intCast(idx)) orelse return null;
        return std.mem.sliceTo(name, 0);
    }

    pub fn columnType(self: *Statement, idx: u32) ColumnType {
        return @enumFromInt(c.sqlite3_column_type(self.stmt, @intCast(idx)));
    }

    // -- Expanded SQL --

    pub fn expandedSql(self: *Statement, allocator: std.mem.Allocator) ![]const u8 {
        const ptr = c.sqlite3_expanded_sql(self.stmt) orelse return SqliteError.NoMem;
        defer c.sqlite3_free(ptr);
        const slice = std.mem.sliceTo(ptr, 0);
        return allocator.dupe(u8, slice);
    }

    // -- Step and reset --

    pub fn step(self: *Statement) !bool {
        const rc = c.sqlite3_step(self.stmt);
        return switch (rc) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => errorFromCode(rc),
        };
    }

    pub fn reset(self: *Statement) void {
        _ = c.sqlite3_reset(self.stmt);
        _ = c.sqlite3_clear_bindings(self.stmt);
    }
};

// ---------------------------------------------------------------------------
// Row / Rows
// ---------------------------------------------------------------------------

pub const Row = struct {
    stmt: *Statement,

    pub fn text(self: Row, idx: u32) ?[]const u8 {
        return self.stmt.columnText(idx);
    }

    pub fn blob(self: Row, idx: u32) ?[]const u8 {
        return self.stmt.columnBlob(idx);
    }

    pub fn int(self: Row, idx: u32) i64 {
        return self.stmt.columnInt(idx);
    }

    pub fn int32(self: Row, idx: u32) i32 {
        return self.stmt.columnInt32(idx);
    }

    pub fn float(self: Row, idx: u32) f64 {
        return self.stmt.columnFloat(idx);
    }

    pub fn boolean(self: Row, idx: u32) bool {
        return self.stmt.columnBool(idx);
    }

    pub fn isNull(self: Row, idx: u32) bool {
        return self.stmt.columnIsNull(idx);
    }

    pub fn optionalInt(self: Row, idx: u32) ?i64 {
        return self.stmt.columnOptionalInt(idx);
    }

    pub fn optionalInt32(self: Row, idx: u32) ?i32 {
        return self.stmt.columnOptionalInt32(idx);
    }

    pub fn optionalFloat(self: Row, idx: u32) ?f64 {
        return self.stmt.columnOptionalFloat(idx);
    }

    pub fn columnCount(self: Row) u32 {
        return self.stmt.columnCount();
    }

    pub fn columnName(self: Row, idx: u32) ?[]const u8 {
        return self.stmt.columnName(idx);
    }

    pub fn columnType(self: Row, idx: u32) ColumnType {
        return self.stmt.columnType(idx);
    }
};

pub const Rows = struct {
    stmt: Statement,
    err: ?anyerror = null,
    done: bool = false,

    pub fn deinit(self: *Rows) void {
        self.stmt.deinit();
    }

    pub fn next(self: *Rows) ?Row {
        if (self.done or self.err != null) return null;
        const has_row = self.stmt.step() catch |e| {
            self.err = e;
            return null;
        };
        if (!has_row) {
            self.done = true;
            return null;
        }
        return Row{ .stmt = &self.stmt };
    }
};

// ---------------------------------------------------------------------------
// Connection Pool
// ---------------------------------------------------------------------------

pub const Pool = struct {
    allocator: std.mem.Allocator,
    connections: []Database,
    available: []usize,
    count: usize,
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,

    pub const Config = struct {
        size: usize,
        path: []const u8,
        flags: c_int = OpenFlags.DEFAULT,
        on_connection: ?*const fn (*Database) anyerror!void = null,
        on_first_connection: ?*const fn (*Database) anyerror!void = null,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !Pool {
        const connections = try allocator.alloc(Database, config.size);
        errdefer allocator.free(connections);
        const available = try allocator.alloc(usize, config.size);
        errdefer allocator.free(available);

        var initialized: usize = 0;
        errdefer {
            var j: usize = 0;
            while (j < initialized) : (j += 1) {
                connections[j].close();
            }
        }

        for (connections, 0..) |*conn, i| {
            conn.* = try Database.openWithFlags(allocator, config.path, config.flags);
            initialized = i + 1;

            if (i == 0) {
                if (config.on_first_connection) |cb| {
                    try cb(conn);
                }
            }
            if (config.on_connection) |cb| {
                try cb(conn);
            }
            available[i] = i;
        }

        return .{
            .allocator = allocator,
            .connections = connections,
            .available = available,
            .count = config.size,
            .mutex = .{},
            .cond = .{},
        };
    }

    pub fn deinit(self: *Pool) void {
        for (self.connections) |*conn| {
            conn.close();
        }
        self.allocator.free(self.connections);
        self.allocator.free(self.available);
    }

    pub fn acquire(self: *Pool) Conn {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.count == 0) {
            self.cond.wait(&self.mutex);
        }

        self.count -= 1;
        const idx = self.available[self.count];
        return .{
            .db = &self.connections[idx],
            .idx = idx,
            .pool = self,
        };
    }

    pub fn release(self: *Pool, conn: Conn) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.available[self.count] = conn.idx;
        self.count += 1;
        self.cond.signal();
    }
};

pub const Conn = struct {
    db: *Database,
    idx: usize,
    pool: *Pool,

    pub fn release(self: Conn) void {
        self.pool.release(self);
    }

    pub fn exec(self: Conn, sql: []const u8) !void {
        return self.db.exec(sql);
    }

    pub fn execZ(self: Conn, sql: [:0]const u8) !void {
        return self.db.execZ(sql);
    }

    pub fn prepare(self: Conn, sql: []const u8) !Statement {
        return self.db.prepare(sql);
    }

    pub fn execDml(self: Conn, sql: []const u8, args: anytype) !void {
        return self.db.execDml(sql, args);
    }

    pub fn query(self: Conn, sql: []const u8, args: anytype) !Statement {
        return self.db.query(sql, args);
    }

    pub fn rows(self: Conn, sql: []const u8, args: anytype) !Rows {
        return self.db.rows(sql, args);
    }

    pub fn row(self: Conn, sql: []const u8, args: anytype) !Rows {
        return self.db.row(sql, args);
    }

    pub fn lastInsertRowId(self: Conn) i64 {
        return self.db.lastInsertRowId();
    }

    pub fn changes(self: Conn) i32 {
        return self.db.changes();
    }

    pub fn getErrorMessage(self: Conn) []const u8 {
        return self.db.getErrorMessage();
    }
};

// ---------------------------------------------------------------------------
// Transactions
// ---------------------------------------------------------------------------

pub fn transaction(db: *Database, ctx: anytype, comptime f: fn (@TypeOf(ctx), *Database) anyerror!void) !void {
    try db.exec("BEGIN IMMEDIATE");
    f(ctx, db) catch |err| {
        db.exec("ROLLBACK") catch {};
        return err;
    };
    try db.exec("COMMIT");
}

pub fn transactionSimple(db: *Database, comptime f: fn (*Database) anyerror!void) !void {
    try db.exec("BEGIN IMMEDIATE");
    f(db) catch |err| {
        db.exec("ROLLBACK") catch {};
        return err;
    };
    try db.exec("COMMIT");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Tests: Granular Error Types
// ---------------------------------------------------------------------------

test "errorFromCode maps known codes correctly" {
    try std.testing.expectEqual(SqliteError.ConstraintUnique, errorFromCode(c.SQLITE_CONSTRAINT_UNIQUE));
    try std.testing.expectEqual(SqliteError.ConstraintForeignKey, errorFromCode(c.SQLITE_CONSTRAINT_FOREIGNKEY));
    try std.testing.expectEqual(SqliteError.ConstraintPrimaryKey, errorFromCode(c.SQLITE_CONSTRAINT_PRIMARYKEY));
    try std.testing.expectEqual(SqliteError.ConstraintNotNull, errorFromCode(c.SQLITE_CONSTRAINT_NOTNULL));
    try std.testing.expectEqual(SqliteError.ConstraintCheck, errorFromCode(c.SQLITE_CONSTRAINT_CHECK));
    try std.testing.expectEqual(SqliteError.BusyTimeout, errorFromCode(c.SQLITE_BUSY_TIMEOUT));
    try std.testing.expectEqual(SqliteError.BusyRecovery, errorFromCode(c.SQLITE_BUSY_RECOVERY));
    try std.testing.expectEqual(SqliteError.Corrupt, errorFromCode(c.SQLITE_CORRUPT));
    try std.testing.expectEqual(SqliteError.Misuse, errorFromCode(c.SQLITE_MISUSE));
}

test "errorFromCode maps unknown code to Error" {
    try std.testing.expectEqual(SqliteError.Error, errorFromCode(9999));
}

test "isUnique returns true for ConstraintUnique" {
    try std.testing.expect(isUnique(SqliteError.ConstraintUnique));
}

test "isUnique returns false for other errors" {
    try std.testing.expect(!isUnique(SqliteError.ConstraintForeignKey));
    try std.testing.expect(!isUnique(SqliteError.ConstraintPrimaryKey));
    try std.testing.expect(!isUnique(SqliteError.Constraint));
    try std.testing.expect(!isUnique(SqliteError.Error));
    try std.testing.expect(!isUnique(SqliteError.Busy));
}

test "isConstraint returns true for all constraint variants" {
    try std.testing.expect(isConstraint(SqliteError.Constraint));
    try std.testing.expect(isConstraint(SqliteError.ConstraintCheck));
    try std.testing.expect(isConstraint(SqliteError.ConstraintCommitHook));
    try std.testing.expect(isConstraint(SqliteError.ConstraintForeignKey));
    try std.testing.expect(isConstraint(SqliteError.ConstraintNotNull));
    try std.testing.expect(isConstraint(SqliteError.ConstraintPrimaryKey));
    try std.testing.expect(isConstraint(SqliteError.ConstraintTrigger));
    try std.testing.expect(isConstraint(SqliteError.ConstraintUnique));
    try std.testing.expect(isConstraint(SqliteError.ConstraintRowId));
}

test "isConstraint returns false for non-constraint errors" {
    try std.testing.expect(!isConstraint(SqliteError.Error));
    try std.testing.expect(!isConstraint(SqliteError.Busy));
    try std.testing.expect(!isConstraint(SqliteError.BusyTimeout));
    try std.testing.expect(!isConstraint(SqliteError.Corrupt));
}

test "unique constraint violation produces ConstraintUnique" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE uniq_test (id INTEGER PRIMARY KEY, val TEXT UNIQUE)");
    try db.exec("INSERT INTO uniq_test (val) VALUES ('duplicate')");

    var stmt = try db.prepare("INSERT INTO uniq_test (val) VALUES (?1)");
    defer stmt.deinit();

    try stmt.bindText(1, "duplicate");
    const result = stmt.step();
    try std.testing.expectError(SqliteError.ConstraintUnique, result);
}

test "foreign key violation produces ConstraintForeignKey" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE parent (id INTEGER PRIMARY KEY)");
    try db.exec("CREATE TABLE child (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES parent(id))");

    var stmt = try db.prepare("INSERT INTO child (parent_id) VALUES (?1)");
    defer stmt.deinit();

    try stmt.bindInt(1, 999);
    const result = stmt.step();
    try std.testing.expectError(SqliteError.ConstraintForeignKey, result);
}

// ---------------------------------------------------------------------------
// Tests: Blob Binding/Extraction
// ---------------------------------------------------------------------------

test "bindBlob and columnBlob round-trip" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE blob_test (id INTEGER PRIMARY KEY, data BLOB)");

    const blob_data = &[_]u8{ 0x00, 0x01, 0x02, 0xFF, 0xFE, 0x00, 0x42 };

    var insert_stmt = try db.prepare("INSERT INTO blob_test (data) VALUES (?1)");
    defer insert_stmt.deinit();
    try insert_stmt.bindBlob(1, blob_data);
    _ = try insert_stmt.step();

    var select_stmt = try db.prepare("SELECT data FROM blob_test WHERE id = 1");
    defer select_stmt.deinit();
    const has_row = try select_stmt.step();
    try std.testing.expect(has_row);

    const result = select_stmt.columnBlob(0);
    try std.testing.expect(result != null);
    try std.testing.expectEqualSlices(u8, blob_data, result.?);
}

test "bindBlob with null" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE blob_test (id INTEGER PRIMARY KEY, data BLOB)");

    var insert_stmt = try db.prepare("INSERT INTO blob_test (data) VALUES (?1)");
    defer insert_stmt.deinit();
    try insert_stmt.bindBlob(1, null);
    _ = try insert_stmt.step();

    var select_stmt = try db.prepare("SELECT data FROM blob_test WHERE id = 1");
    defer select_stmt.deinit();
    _ = try select_stmt.step();

    const result = select_stmt.columnBlob(0);
    try std.testing.expect(result == null);
}

test "bindBlob binary data with zero bytes" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE blob_test (id INTEGER PRIMARY KEY, data BLOB)");

    const binary = &[_]u8{ 0x00, 0x00, 0x00, 0x01, 0x00, 0x00 };

    var insert_stmt = try db.prepare("INSERT INTO blob_test (data) VALUES (?1)");
    defer insert_stmt.deinit();
    try insert_stmt.bindBlob(1, binary);
    _ = try insert_stmt.step();

    var select_stmt = try db.prepare("SELECT data FROM blob_test WHERE id = 1");
    defer select_stmt.deinit();
    _ = try select_stmt.step();

    const result = select_stmt.columnBlob(0);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 6), result.?.len);
    try std.testing.expectEqualSlices(u8, binary, result.?);
}

// ---------------------------------------------------------------------------
// Tests: Float/Double Support
// ---------------------------------------------------------------------------

test "bindFloat and columnFloat round-trip" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE float_test (id INTEGER PRIMARY KEY, val REAL)");

    var insert_stmt = try db.prepare("INSERT INTO float_test (val) VALUES (?1)");
    defer insert_stmt.deinit();
    try insert_stmt.bindFloat(1, 3.14159265358979);
    _ = try insert_stmt.step();

    var select_stmt = try db.prepare("SELECT val FROM float_test WHERE id = 1");
    defer select_stmt.deinit();
    _ = try select_stmt.step();

    const val = select_stmt.columnFloat(0);
    try std.testing.expectApproxEqRel(@as(f64, 3.14159265358979), val, 1e-12);
}

test "columnOptionalFloat returns null for NULL" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE float_test (id INTEGER PRIMARY KEY, val REAL)");
    try db.exec("INSERT INTO float_test (val) VALUES (NULL)");

    var stmt = try db.prepare("SELECT val FROM float_test WHERE id = 1");
    defer stmt.deinit();
    _ = try stmt.step();

    const val = stmt.columnOptionalFloat(0);
    try std.testing.expect(val == null);
}

test "columnOptionalFloat returns value for non-NULL" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE float_test (id INTEGER PRIMARY KEY, val REAL)");
    try db.exec("INSERT INTO float_test (val) VALUES (2.718281828)");

    var stmt = try db.prepare("SELECT val FROM float_test WHERE id = 1");
    defer stmt.deinit();
    _ = try stmt.step();

    const val = stmt.columnOptionalFloat(0);
    try std.testing.expect(val != null);
    try std.testing.expectApproxEqRel(@as(f64, 2.718281828), val.?, 1e-9);
}

test "bindOptionalFloat with value and null" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE float_test (id INTEGER PRIMARY KEY, val REAL)");

    var stmt = try db.prepare("INSERT INTO float_test (val) VALUES (?1)");
    defer stmt.deinit();

    try stmt.bindOptionalFloat(1, @as(?f64, 1.5));
    _ = try stmt.step();
    stmt.reset();

    try stmt.bindOptionalFloat(1, @as(?f64, null));
    _ = try stmt.step();

    var select_stmt = try db.prepare("SELECT val FROM float_test ORDER BY id");
    defer select_stmt.deinit();

    _ = try select_stmt.step();
    const first = select_stmt.columnOptionalFloat(0);
    try std.testing.expect(first != null);
    try std.testing.expectApproxEqRel(@as(f64, 1.5), first.?, 1e-12);

    _ = try select_stmt.step();
    const second = select_stmt.columnOptionalFloat(0);
    try std.testing.expect(second == null);
}

// ---------------------------------------------------------------------------
// Tests: Multi-Statement Detection (Debug mode only)
// ---------------------------------------------------------------------------

test "multi-statement detection rejects multiple statements" {
    if (comptime builtin.mode == .Debug) {
        const allocator = std.testing.allocator;
        var db = try Database.open(allocator, ":memory:");
        defer db.close();

        const result = db.prepare("SELECT 1; SELECT 2");
        try std.testing.expectError(SqliteError.MultipleStatements, result);
    }
}

test "multi-statement detection allows single statement" {
    if (comptime builtin.mode == .Debug) {
        const allocator = std.testing.allocator;
        var db = try Database.open(allocator, ":memory:");
        defer db.close();

        var stmt = try db.prepare("SELECT 1");
        defer stmt.deinit();
        const has_row = try stmt.step();
        try std.testing.expect(has_row);
    }
}

test "multi-statement detection allows trailing whitespace and semicolons" {
    if (comptime builtin.mode == .Debug) {
        const allocator = std.testing.allocator;
        var db = try Database.open(allocator, ":memory:");
        defer db.close();

        var stmt1 = try db.prepare("SELECT 1;");
        defer stmt1.deinit();

        var stmt2 = try db.prepare("SELECT 1;  ");
        defer stmt2.deinit();

        var stmt3 = try db.prepare("SELECT 1 ");
        defer stmt3.deinit();
    }
}

// ---------------------------------------------------------------------------
// Tests: Configurable Open Flags
// ---------------------------------------------------------------------------

test "openWithFlags with default flags" {
    const allocator = std.testing.allocator;
    var db = try Database.openWithFlags(allocator, ":memory:", OpenFlags.DEFAULT);
    defer db.close();

    try db.exec("CREATE TABLE test (id INTEGER PRIMARY KEY)");
}

test "openWithFlags with READONLY on existing database" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(db_path);
    const full_path = try std.fmt.allocPrint(allocator, "{s}/readonly_test.db", .{db_path});
    defer allocator.free(full_path);

    {
        var db = try Database.open(allocator, full_path);
        try db.exec("CREATE TABLE test (id INTEGER PRIMARY KEY, val TEXT)");
        try db.exec("INSERT INTO test (val) VALUES ('hello')");
        db.close();
    }

    var ro_db = try Database.openWithFlags(allocator, full_path, OpenFlags.READONLY | OpenFlags.EXRESCODE);
    defer ro_db.close();

    var stmt = try ro_db.prepare("SELECT val FROM test");
    defer stmt.deinit();
    const has_row = try stmt.step();
    try std.testing.expect(has_row);
    try std.testing.expectEqualStrings("hello", stmt.columnText(0).?);
}

test "OpenFlags constants are non-zero" {
    try std.testing.expect(OpenFlags.READONLY != 0);
    try std.testing.expect(OpenFlags.READWRITE != 0);
    try std.testing.expect(OpenFlags.CREATE != 0);
    try std.testing.expect(OpenFlags.URI != 0);
    try std.testing.expect(OpenFlags.MEMORY != 0);
    try std.testing.expect(OpenFlags.NOMUTEX != 0);
    try std.testing.expect(OpenFlags.FULLMUTEX != 0);
    try std.testing.expect(OpenFlags.EXRESCODE != 0);
    try std.testing.expect(OpenFlags.DEFAULT != 0);
}

// ---------------------------------------------------------------------------
// Tests: Column Metadata
// ---------------------------------------------------------------------------

test "columnCount returns correct count" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE meta_test (a INTEGER, b TEXT, c REAL)");

    var stmt = try db.prepare("SELECT a, b, c FROM meta_test");
    defer stmt.deinit();

    try std.testing.expectEqual(@as(u32, 3), stmt.columnCount());
}

test "columnName returns expected names" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE meta_test (alpha INTEGER, beta TEXT, gamma REAL)");

    var stmt = try db.prepare("SELECT alpha, beta, gamma FROM meta_test");
    defer stmt.deinit();

    try std.testing.expectEqualStrings("alpha", stmt.columnName(0).?);
    try std.testing.expectEqualStrings("beta", stmt.columnName(1).?);
    try std.testing.expectEqualStrings("gamma", stmt.columnName(2).?);
}

test "columnType returns correct types after stepping" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE type_test (i INTEGER, f REAL, t TEXT, b BLOB, n INTEGER)");
    try db.exec("INSERT INTO type_test VALUES (42, 3.14, 'hello', X'DEADBEEF', NULL)");

    var stmt = try db.prepare("SELECT i, f, t, b, n FROM type_test");
    defer stmt.deinit();

    const has_row = try stmt.step();
    try std.testing.expect(has_row);

    try std.testing.expectEqual(ColumnType.integer, stmt.columnType(0));
    try std.testing.expectEqual(ColumnType.float, stmt.columnType(1));
    try std.testing.expectEqual(ColumnType.text, stmt.columnType(2));
    try std.testing.expectEqual(ColumnType.blob, stmt.columnType(3));
    try std.testing.expectEqual(ColumnType.null, stmt.columnType(4));
}

// ---------------------------------------------------------------------------
// Tests: Expanded SQL
// ---------------------------------------------------------------------------

test "expandedSql shows bound values" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE esql_test (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)");

    var stmt = try db.prepare("INSERT INTO esql_test (name, age) VALUES (?1, ?2)");
    defer stmt.deinit();

    try stmt.bindText(1, "Alice");
    try stmt.bindInt32(2, 30);

    const expanded = try stmt.expandedSql(allocator);
    defer allocator.free(expanded);

    try std.testing.expectEqualStrings("INSERT INTO esql_test (name, age) VALUES ('Alice', 30)", expanded);
}

test "expandedSql with null parameter" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE esql_test (id INTEGER PRIMARY KEY, val TEXT)");

    var stmt = try db.prepare("INSERT INTO esql_test (val) VALUES (?1)");
    defer stmt.deinit();

    try stmt.bindNull(1);

    const expanded = try stmt.expandedSql(allocator);
    defer allocator.free(expanded);

    try std.testing.expectEqualStrings("INSERT INTO esql_test (val) VALUES (NULL)", expanded);
}

// ---------------------------------------------------------------------------
// Tests: Comptime Tuple Binding
// ---------------------------------------------------------------------------

test "bind with mixed types" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE bind_test (name TEXT, age INTEGER, score REAL, active INTEGER)");

    var stmt = try db.prepare("INSERT INTO bind_test VALUES (?1, ?2, ?3, ?4)");
    defer stmt.deinit();

    try stmt.bind(.{ "Alice", @as(i32, 30), @as(f64, 95.5), true });
    _ = try stmt.step();

    var sel = try db.prepare("SELECT name, age, score, active FROM bind_test");
    defer sel.deinit();

    const has_row = try sel.step();
    try std.testing.expect(has_row);
    try std.testing.expectEqualStrings("Alice", sel.columnText(0).?);
    try std.testing.expectEqual(@as(i64, 30), sel.columnInt(1));
    try std.testing.expectApproxEqRel(@as(f64, 95.5), sel.columnFloat(2), 1e-12);
    try std.testing.expect(sel.columnBool(3));
}

test "execDml insert and verify" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE dml_test (id INTEGER PRIMARY KEY, name TEXT, value INTEGER)");

    try db.execDml("INSERT INTO dml_test (name, value) VALUES (?1, ?2)", .{ "Bob", @as(i64, 42) });
    try db.execDml("INSERT INTO dml_test (name, value) VALUES (?1, ?2)", .{ "Carol", @as(i64, 99) });

    var stmt = try db.prepare("SELECT COUNT(*) FROM dml_test");
    defer stmt.deinit();
    _ = try stmt.step();
    try std.testing.expectEqual(@as(i64, 2), stmt.columnInt(0));

    var sel = try db.prepare("SELECT name, value FROM dml_test ORDER BY id");
    defer sel.deinit();
    _ = try sel.step();
    try std.testing.expectEqualStrings("Bob", sel.columnText(0).?);
    try std.testing.expectEqual(@as(i64, 42), sel.columnInt(1));
}

test "query with params" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE query_test (id INTEGER PRIMARY KEY, name TEXT, score INTEGER)");
    try db.execDml("INSERT INTO query_test (name, score) VALUES (?1, ?2)", .{ "Alice", @as(i32, 90) });
    try db.execDml("INSERT INTO query_test (name, score) VALUES (?1, ?2)", .{ "Bob", @as(i32, 80) });
    try db.execDml("INSERT INTO query_test (name, score) VALUES (?1, ?2)", .{ "Carol", @as(i32, 70) });

    var stmt = try db.query("SELECT name, score FROM query_test WHERE score >= ?1", .{@as(i32, 80)});
    defer stmt.deinit();

    var count: u32 = 0;
    while (try stmt.step()) {
        count += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), count);
}

test "bind with null values" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE null_test (id INTEGER PRIMARY KEY, name TEXT, value INTEGER)");

    try db.execDml("INSERT INTO null_test (name, value) VALUES (?1, ?2)", .{ null, @as(?i64, null) });

    var stmt = try db.prepare("SELECT name, value FROM null_test WHERE id = 1");
    defer stmt.deinit();
    _ = try stmt.step();

    try std.testing.expect(stmt.columnText(0) == null);
    try std.testing.expect(stmt.columnIsNull(1));
}

test "bind with Blob marker" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE blob_bind_test (id INTEGER PRIMARY KEY, data BLOB)");

    const blob_data = &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    try db.execDml("INSERT INTO blob_bind_test (data) VALUES (?1)", .{Blob{ .data = blob_data }});

    var stmt = try db.prepare("SELECT data FROM blob_bind_test WHERE id = 1");
    defer stmt.deinit();
    _ = try stmt.step();

    const result = stmt.columnBlob(0);
    try std.testing.expect(result != null);
    try std.testing.expectEqualSlices(u8, blob_data, result.?);
}

test "bind with Blob null" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE blob_bind_test (id INTEGER PRIMARY KEY, data BLOB)");

    try db.execDml("INSERT INTO blob_bind_test (data) VALUES (?1)", .{Blob{ .data = null }});

    var stmt = try db.prepare("SELECT data FROM blob_bind_test WHERE id = 1");
    defer stmt.deinit();
    _ = try stmt.step();

    try std.testing.expect(stmt.columnBlob(0) == null);
}

test "bind with optional values" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE opt_test (id INTEGER PRIMARY KEY, val INTEGER, name TEXT)");

    // With values present
    try db.execDml(
        "INSERT INTO opt_test (val, name) VALUES (?1, ?2)",
        .{ @as(?i64, 123), @as(?[]const u8, "present") },
    );

    // With null values
    try db.execDml(
        "INSERT INTO opt_test (val, name) VALUES (?1, ?2)",
        .{ @as(?i64, null), @as(?[]const u8, null) },
    );

    var stmt = try db.prepare("SELECT val, name FROM opt_test ORDER BY id");
    defer stmt.deinit();

    _ = try stmt.step();
    try std.testing.expectEqual(@as(?i64, 123), stmt.columnOptionalInt(0));
    try std.testing.expectEqualStrings("present", stmt.columnText(1).?);

    _ = try stmt.step();
    try std.testing.expect(stmt.columnOptionalInt(0) == null);
    try std.testing.expect(stmt.columnText(1) == null);
}

// ---------------------------------------------------------------------------
// Tests: Row/Rows Iterators
// ---------------------------------------------------------------------------

test "Rows iterates over multiple rows" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE rows_test (id INTEGER PRIMARY KEY, name TEXT)");
    try db.execDml("INSERT INTO rows_test (name) VALUES (?1)", .{"Alice"});
    try db.execDml("INSERT INTO rows_test (name) VALUES (?1)", .{"Bob"});
    try db.execDml("INSERT INTO rows_test (name) VALUES (?1)", .{"Carol"});

    const expected = [_][]const u8{ "Alice", "Bob", "Carol" };
    var result = try db.rows("SELECT name FROM rows_test ORDER BY id", .{});
    defer result.deinit();

    var count: u32 = 0;
    while (result.next()) |row| {
        try std.testing.expectEqualStrings(expected[count], row.text(0).?);
        count += 1;
    }

    try std.testing.expectEqual(@as(u32, 3), count);
}

test "Rows returns null when exhausted" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE rows_test (id INTEGER PRIMARY KEY, name TEXT)");
    try db.execDml("INSERT INTO rows_test (name) VALUES (?1)", .{"only"});

    var result = try db.rows("SELECT name FROM rows_test", .{});
    defer result.deinit();

    const first = result.next();
    try std.testing.expect(first != null);
    try std.testing.expectEqualStrings("only", first.?.text(0).?);

    const second = result.next();
    try std.testing.expect(second == null);

    const third = result.next();
    try std.testing.expect(third == null);
}

test "Row accessors delegate correctly" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE row_test (t TEXT, b BLOB, i INTEGER, f REAL, flag INTEGER, n INTEGER)");
    const blob_data = &[_]u8{ 0xDE, 0xAD };
    try db.execDml(
        "INSERT INTO row_test VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        .{ "hello", Blob{ .data = blob_data }, @as(i64, 42), @as(f64, 3.14), true, null },
    );

    var result = try db.rows("SELECT t, b, i, f, flag, n FROM row_test", .{});
    defer result.deinit();

    const row = result.next().?;
    try std.testing.expectEqualStrings("hello", row.text(0).?);
    try std.testing.expectEqualSlices(u8, blob_data, row.blob(1).?);
    try std.testing.expectEqual(@as(i64, 42), row.int(2));
    try std.testing.expectApproxEqRel(@as(f64, 3.14), row.float(3), 1e-12);
    try std.testing.expect(row.boolean(4));
    try std.testing.expect(row.isNull(5));
    try std.testing.expect(row.optionalInt(5) == null);
}

test "Rows err is null on success" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE rows_test (id INTEGER PRIMARY KEY)");
    try db.execDml("INSERT INTO rows_test DEFAULT VALUES", .{});

    var result = try db.rows("SELECT id FROM rows_test", .{});
    defer result.deinit();

    while (result.next()) |_| {}

    try std.testing.expect(result.err == null);
}

test "Database.rows convenience" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE rows_test (id INTEGER PRIMARY KEY, score INTEGER)");
    try db.execDml("INSERT INTO rows_test (score) VALUES (?1)", .{@as(i32, 90)});
    try db.execDml("INSERT INTO rows_test (score) VALUES (?1)", .{@as(i32, 80)});
    try db.execDml("INSERT INTO rows_test (score) VALUES (?1)", .{@as(i32, 70)});

    var result = try db.rows("SELECT score FROM rows_test WHERE score >= ?1", .{@as(i32, 80)});
    defer result.deinit();

    var count: u32 = 0;
    while (result.next()) |_| {
        count += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), count);
}

test "Rows with empty result" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE rows_test (id INTEGER PRIMARY KEY, name TEXT)");

    var result = try db.rows("SELECT name FROM rows_test", .{});
    defer result.deinit();

    const first = result.next();
    try std.testing.expect(first == null);
    try std.testing.expect(result.err == null);
}

test "Database.row single-row convenience" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE row_conv (id INTEGER PRIMARY KEY, name TEXT, score INTEGER)");
    try db.execDml("INSERT INTO row_conv (name, score) VALUES (?1, ?2)", .{ "Alice", @as(i32, 95) });
    try db.execDml("INSERT INTO row_conv (name, score) VALUES (?1, ?2)", .{ "Bob", @as(i32, 80) });

    var result = try db.row("SELECT name, score FROM row_conv WHERE id = ?1", .{@as(i64, 1)});
    defer result.deinit();

    if (result.next()) |r| {
        try std.testing.expectEqualStrings("Alice", r.text(0).?);
        try std.testing.expectEqual(@as(i32, 95), r.int32(1));
    } else {
        return error.TestUnexpectedResult;
    }
}

test "Database.row returns null for no match" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE row_conv (id INTEGER PRIMARY KEY, name TEXT)");

    var result = try db.row("SELECT name FROM row_conv WHERE id = ?1", .{@as(i64, 999)});
    defer result.deinit();

    try std.testing.expect(result.next() == null);
    try std.testing.expect(result.err == null);
}

// ---------------------------------------------------------------------------
// Tests: Connection Pool
// ---------------------------------------------------------------------------

test "Pool init and deinit" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(db_path);
    const full_path = try std.fmt.allocPrint(allocator, "{s}/pool_test.db", .{db_path});
    defer allocator.free(full_path);

    var pool = try Pool.init(allocator, .{ .size = 2, .path = full_path });
    defer pool.deinit();

    try std.testing.expectEqual(@as(usize, 2), pool.count);
}

test "Pool acquire and release" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(db_path);
    const full_path = try std.fmt.allocPrint(allocator, "{s}/pool_test.db", .{db_path});
    defer allocator.free(full_path);

    var pool = try Pool.init(allocator, .{ .size = 2, .path = full_path });
    defer pool.deinit();

    const conn = pool.acquire();
    try conn.exec("CREATE TABLE IF NOT EXISTS acq_test (id INTEGER PRIMARY KEY)");
    conn.release();

    try std.testing.expectEqual(@as(usize, 2), pool.count);
}

test "Pool multiple acquire release cycles" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(db_path);
    const full_path = try std.fmt.allocPrint(allocator, "{s}/pool_test.db", .{db_path});
    defer allocator.free(full_path);

    var pool = try Pool.init(allocator, .{ .size = 2, .path = full_path });
    defer pool.deinit();

    {
        const conn = pool.acquire();
        try conn.exec("CREATE TABLE IF NOT EXISTS cycle_test (id INTEGER PRIMARY KEY, val TEXT)");
        try conn.exec("INSERT INTO cycle_test (val) VALUES ('first')");
        conn.release();
    }

    {
        const conn = pool.acquire();
        try conn.exec("INSERT INTO cycle_test (val) VALUES ('second')");
        conn.release();
    }

    {
        const conn = pool.acquire();
        var stmt = try conn.prepare("SELECT COUNT(*) FROM cycle_test");
        defer stmt.deinit();
        _ = try stmt.step();
        try std.testing.expectEqual(@as(i64, 2), stmt.columnInt(0));
        conn.release();
    }
}

fn poolTestOnConnection(db: *Database) anyerror!void {
    try db.exec("INSERT INTO pool_cb_track (source) VALUES ('on_connection')");
}

fn poolTestOnFirstConnection(db: *Database) anyerror!void {
    try db.exec("CREATE TABLE IF NOT EXISTS pool_cb_track (id INTEGER PRIMARY KEY, source TEXT)");
}

test "Pool on_connection callback fires" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(db_path);
    const full_path = try std.fmt.allocPrint(allocator, "{s}/pool_cb_test.db", .{db_path});
    defer allocator.free(full_path);

    var pool = try Pool.init(allocator, .{
        .size = 3,
        .path = full_path,
        .on_first_connection = &poolTestOnFirstConnection,
        .on_connection = &poolTestOnConnection,
    });
    defer pool.deinit();

    const conn = pool.acquire();
    var stmt = try conn.prepare("SELECT COUNT(*) FROM pool_cb_track WHERE source = 'on_connection'");
    defer stmt.deinit();
    _ = try stmt.step();
    try std.testing.expectEqual(@as(i64, 3), stmt.columnInt(0));
    conn.release();
}

test "Pool on_first_connection fires once" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(db_path);
    const full_path = try std.fmt.allocPrint(allocator, "{s}/pool_first_test.db", .{db_path});
    defer allocator.free(full_path);

    var pool = try Pool.init(allocator, .{
        .size = 3,
        .path = full_path,
        .on_first_connection = &poolTestOnFirstConnection,
        .on_connection = &poolTestOnConnection,
    });
    defer pool.deinit();

    // on_first_connection created the table, on_connection inserted 3 rows (one per connection).
    // The table existing proves on_first_connection ran. Having 3 rows proves on_connection
    // ran for each connection. If on_first_connection ran more than once, the CREATE TABLE
    // IF NOT EXISTS would still succeed, but having exactly 3 rows from on_connection
    // confirms on_connection ran 3 times total.
    const conn = pool.acquire();
    var stmt = try conn.prepare("SELECT COUNT(*) FROM pool_cb_track");
    defer stmt.deinit();
    _ = try stmt.step();
    try std.testing.expectEqual(@as(i64, 3), stmt.columnInt(0));
    conn.release();
}

test "Conn delegates to Database" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(db_path);
    const full_path = try std.fmt.allocPrint(allocator, "{s}/pool_delegate_test.db", .{db_path});
    defer allocator.free(full_path);

    var pool = try Pool.init(allocator, .{ .size = 1, .path = full_path });
    defer pool.deinit();

    const conn = pool.acquire();
    defer conn.release();

    // exec
    try conn.exec("CREATE TABLE delegate_test (id INTEGER PRIMARY KEY, name TEXT, score INTEGER)");

    // execDml
    try conn.execDml("INSERT INTO delegate_test (name, score) VALUES (?1, ?2)", .{ "Alice", @as(i32, 90) });
    try std.testing.expectEqual(@as(i32, 1), conn.changes());

    const row_id = conn.lastInsertRowId();
    try std.testing.expectEqual(@as(i64, 1), row_id);

    // prepare
    var stmt = try conn.prepare("INSERT INTO delegate_test (name, score) VALUES (?1, ?2)");
    defer stmt.deinit();
    try stmt.bind(.{ "Bob", @as(i32, 80) });
    _ = try stmt.step();

    // rows
    var result = try conn.rows("SELECT name FROM delegate_test ORDER BY id", .{});
    defer result.deinit();

    var count: u32 = 0;
    while (result.next()) |_| {
        count += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), count);
}
