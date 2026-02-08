# zqlite Feature Reference

This document covers the features added to zqlite beyond the original core API (open/close, basic bind/step/column, transactions). Each section includes rationale, API surface, and usage examples.

---

## Table of Contents

- [Granular Error Types](#granular-error-types)
- [Blob Support](#blob-support)
- [Float/Double Support](#floatdouble-support)
- [Multi-Statement Detection](#multi-statement-detection)
- [Configurable Open Flags](#configurable-open-flags)
- [Column Metadata](#column-metadata)
- [Expanded SQL](#expanded-sql)
- [Comptime Tuple Binding](#comptime-tuple-binding)
- [Row/Rows Iterators](#rowrows-iterators)
- [Connection Pool](#connection-pool)
- [API Quick Reference](#api-quick-reference)

---

## Granular Error Types

SQLite uses a two-level error code system: primary result codes (e.g. `SQLITE_CONSTRAINT`) and extended result codes (e.g. `SQLITE_CONSTRAINT_UNIQUE`). zqlite maps both levels into a single Zig error set so you can catch errors at the granularity you need.

### The SqliteError Enum

**Primary result codes** (22 errors):

| Error | SQLite Code | Meaning |
|-------|-------------|---------|
| `Error` | SQLITE_ERROR (1) | Generic SQL error |
| `Internal` | SQLITE_INTERNAL (2) | Internal SQLite malfunction |
| `Perm` | SQLITE_PERM (3) | Access permission denied |
| `Abort` | SQLITE_ABORT (4) | Callback requested abort |
| `Busy` | SQLITE_BUSY (5) | Database file locked |
| `Locked` | SQLITE_LOCKED (6) | Table locked |
| `NoMem` | SQLITE_NOMEM (7) | Allocation failed |
| `ReadOnly` | SQLITE_READONLY (8) | Write to read-only database |
| `Interrupt` | SQLITE_INTERRUPT (9) | Operation interrupted |
| `IoErr` | SQLITE_IOERR (10) | Disk I/O error |
| `Corrupt` | SQLITE_CORRUPT (11) | Database file is corrupt |
| `NotFound` | SQLITE_NOTFOUND (12) | Not used by SQLite core |
| `Full` | SQLITE_FULL (13) | Database or disk full |
| `CantOpen` | SQLITE_CANTOPEN (14) | Cannot open database file |
| `Protocol` | SQLITE_PROTOCOL (15) | WAL locking protocol error |
| `Schema` | SQLITE_SCHEMA (17) | Schema changed |
| `TooBig` | SQLITE_TOOBIG (18) | String or blob too large |
| `Constraint` | SQLITE_CONSTRAINT (19) | Generic constraint violation |
| `Mismatch` | SQLITE_MISMATCH (20) | Type mismatch |
| `Misuse` | SQLITE_MISUSE (21) | API misuse |
| `Auth` | SQLITE_AUTH (23) | Authorization denied |
| `Range` | SQLITE_RANGE (25) | Parameter index out of range |
| `NotADb` | SQLITE_NOTADB (26) | File is not a database |

**Extended constraint codes** (8 errors):

| Error | Meaning |
|-------|---------|
| `ConstraintCheck` | CHECK constraint failed |
| `ConstraintCommitHook` | Commit hook caused rollback |
| `ConstraintForeignKey` | Foreign key constraint failed |
| `ConstraintNotNull` | NOT NULL constraint failed |
| `ConstraintPrimaryKey` | PRIMARY KEY constraint failed |
| `ConstraintTrigger` | Trigger raised RAISE(ABORT) |
| `ConstraintUnique` | UNIQUE constraint failed |
| `ConstraintRowId` | Rowid is not unique |

**Extended busy codes** (3 errors):

| Error | Meaning |
|-------|---------|
| `BusyRecovery` | Busy during WAL recovery |
| `BusySnapshot` | Busy due to snapshot conflict |
| `BusyTimeout` | Busy timeout expired |

**Debug-only** (1 error):

| Error | Meaning |
|-------|---------|
| `MultipleStatements` | SQL string contains more than one statement (debug builds only) |

### errorFromCode()

Converts a raw SQLite integer result code into a typed `SqliteError`. Extended codes are checked first, so `SQLITE_CONSTRAINT_UNIQUE` maps to `ConstraintUnique` rather than the generic `Constraint`. Unknown codes fall back to `SqliteError.Error`.

```zig
const zqlite = @import("zqlite");

// You rarely call this directly -- it's used internally by
// Statement.step(), Database.exec(), etc. But it's public if
// you need it for interop with raw SQLite calls.
const err = zqlite.errorFromCode(raw_sqlite_rc);
```

### isUnique() and isConstraint()

Helper predicates for common constraint-handling patterns.

```zig
const zqlite = @import("zqlite");

// isUnique: true only for ConstraintUnique
// isConstraint: true for Constraint and ALL extended constraint subtypes
```

### Example: Catching a Unique Constraint Violation

```zig
var stmt = try db.prepare("INSERT INTO users (email) VALUES (?1)");
defer stmt.deinit();

try stmt.bindText(1, "alice@example.com");
_ = stmt.step() catch |err| {
    if (zqlite.isUnique(err)) {
        // Handle duplicate email -- e.g. return a user-friendly message
        std.log.warn("email already exists", .{});
        return;
    }
    return err;
};
```

### Example: General Constraint Handling

```zig
_ = stmt.step() catch |err| {
    if (zqlite.isConstraint(err)) {
        // Catches CHECK, FOREIGN KEY, NOT NULL, PRIMARY KEY,
        // UNIQUE, TRIGGER, ROWID, COMMIT HOOK, and generic CONSTRAINT.
        std.log.err("constraint violation: {}", .{err});
        return error.ValidationFailed;
    }
    return err;
};
```

---

## Blob Support

Bind and read raw byte data (images, serialized structs, protobuf, etc.) using `bindBlob()` and `columnBlob()`.

### bindBlob()

```zig
pub fn bindBlob(self: *Statement, idx: u32, value: ?[]const u8) !void
```

Binds a byte slice to a parameter position. Pass `null` to bind SQL NULL. Uses `SQLITE_TRANSIENT`, meaning SQLite makes its own copy of the data -- the caller's buffer can be freed or modified immediately after binding.

### columnBlob()

```zig
pub fn columnBlob(self: *Statement, idx: u32) ?[]const u8
```

Returns the blob value at the given column index, or `null` if the column is SQL NULL or has zero length. The returned slice points into SQLite-managed memory and is valid until the next call to `step()` or `reset()` on the same statement.

### Example: Storing and Retrieving Binary Data

```zig
try db.exec("CREATE TABLE files (id INTEGER PRIMARY KEY, data BLOB)");

// Write
var insert = try db.prepare("INSERT INTO files (data) VALUES (?1)");
defer insert.deinit();

const payload = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
try insert.bindBlob(1, &payload);
_ = try insert.step();

// Read
var select = try db.prepare("SELECT data FROM files WHERE id = ?1");
defer select.deinit();

try select.bindInt(1, 1);
if (try select.step()) {
    if (select.columnBlob(0)) |data| {
        // data is []const u8 -- process the bytes
        _ = data;
    }
}
```

### Binding a NULL Blob

```zig
try insert.bindBlob(1, null);
_ = try insert.step();
```

---

## Float/Double Support

Bind and read IEEE 754 double-precision floating-point values (`f64`), which map to SQLite's `REAL` affinity.

### Methods

| Method | Signature | Description |
|--------|-----------|-------------|
| `bindFloat` | `(idx: u32, value: f64) !void` | Bind an `f64` value |
| `bindOptionalFloat` | `(idx: u32, value: ?f64) !void` | Bind an `f64` or NULL |
| `columnFloat` | `(idx: u32) f64` | Read an `f64` (returns 0.0 if NULL) |
| `columnOptionalFloat` | `(idx: u32) ?f64` | Read an `f64` or `null` |

### Example: Binding and Reading Floats

```zig
try db.exec("CREATE TABLE measurements (id INTEGER PRIMARY KEY, value REAL)");

var insert = try db.prepare("INSERT INTO measurements (value) VALUES (?1)");
defer insert.deinit();

try insert.bindFloat(1, 3.14159);
_ = try insert.step();

var select = try db.prepare("SELECT value FROM measurements WHERE id = 1");
defer select.deinit();

if (try select.step()) {
    const value: f64 = select.columnFloat(0);
    _ = value; // 3.14159
}
```

### Example: Nullable Floats

```zig
// Bind: pass null to store SQL NULL
try insert.bindOptionalFloat(1, null);
_ = try insert.step();

// Read: returns null if column is SQL NULL
const maybe_value: ?f64 = select.columnOptionalFloat(0);
if (maybe_value) |v| {
    // Column had a real value
    _ = v;
} else {
    // Column was NULL
}
```

---

## Multi-Statement Detection

SQLite's `sqlite3_prepare_v2()` only compiles the **first** SQL statement in a string. Any additional statements are silently ignored. This is a well-known source of bugs:

```sql
-- Only the first statement executes. The second is silently dropped.
"CREATE TABLE a (id INT); CREATE TABLE b (id INT)"
```

### How zqlite Handles This

In **debug builds** (`-Doptimize=Debug`, the default for `zig build test`), `Statement.init()` checks whether the input SQL contains more than one statement. If it does, it returns `SqliteError.MultipleStatements` instead of silently ignoring the trailing SQL.

The detection works by examining the "tail" pointer returned by `sqlite3_prepare_v2()`. If the tail points to non-whitespace, non-comment content that can itself be prepared as a statement, the error is raised.

In **release builds** (`ReleaseSafe`, `ReleaseFast`, `ReleaseSmall`), this check is compiled out entirely. There is zero runtime cost in production.

### What Gets Caught

```zig
// ERROR in debug: two real statements
_ = try db.prepare("INSERT INTO t VALUES (1); INSERT INTO t VALUES (2)");

// OK: trailing whitespace and comments are fine
_ = try db.prepare("INSERT INTO t VALUES (1)  ");
_ = try db.prepare("INSERT INTO t VALUES (1) -- comment");
```

### Recommended Pattern

Use `db.exec()` for DDL or multi-statement SQL (it uses `sqlite3_exec`, which handles multiple statements). Use `db.prepare()` for parameterized single statements.

```zig
// Multi-statement DDL -- use exec()
try db.exec("CREATE TABLE a (id INT); CREATE TABLE b (id INT)");

// Single parameterized statement -- use prepare()
var stmt = try db.prepare("INSERT INTO a (id) VALUES (?1)");
defer stmt.deinit();
```

---

## Configurable Open Flags

The default `Database.open()` uses sensible flags (`READWRITE | CREATE | EXRESCODE`). For cases where you need more control -- read-only connections, URI filenames, shared cache -- use `openWithFlags()`.

### OpenFlags Constants

| Flag | Meaning |
|------|---------|
| `READONLY` | Open in read-only mode |
| `READWRITE` | Open for reading and writing |
| `CREATE` | Create the database if it doesn't exist |
| `URI` | Interpret the filename as a URI |
| `MEMORY` | Open an in-memory database |
| `NOMUTEX` | No mutex (single-thread mode) |
| `FULLMUTEX` | Full mutex (serialized mode) |
| `SHAREDCACHE` | Enable shared cache |
| `PRIVATECACHE` | Disable shared cache |
| `NOFOLLOW` | Do not follow symlinks |
| `EXRESCODE` | Enable extended result codes |

`OpenFlags.DEFAULT` is `READWRITE | CREATE | EXRESCODE`.

### Example: Read-Only Connection

```zig
const zqlite = @import("zqlite");

var db = try zqlite.Database.openWithFlags(
    allocator,
    "/path/to/existing.db",
    zqlite.OpenFlags.READONLY | zqlite.OpenFlags.EXRESCODE,
);
defer db.close();

// Writes will fail with SqliteError.ReadOnly
```

### Example: URI Filename Support

```zig
var db = try zqlite.Database.openWithFlags(
    allocator,
    "file:mydb.sqlite?mode=ro&cache=shared",
    zqlite.OpenFlags.READONLY | zqlite.OpenFlags.URI | zqlite.OpenFlags.EXRESCODE,
);
defer db.close();
```

### Default open() Still Works

```zig
// Equivalent to openWithFlags(allocator, path, OpenFlags.DEFAULT)
var db = try zqlite.Database.open(allocator, "mydb.sqlite");
defer db.close();
```

---

## Column Metadata

Inspect the shape and types of a result set at runtime using `columnCount()`, `columnName()`, and `columnType()`.

### Methods

| Method | Returns | Description |
|--------|---------|-------------|
| `columnCount()` | `u32` | Number of columns in the result set |
| `columnName(idx)` | `?[]const u8` | Name of the column at index `idx` |
| `columnType(idx)` | `ColumnType` | SQLite storage class of the current row's value at `idx` |

### The ColumnType Enum

```zig
pub const ColumnType = enum(c_int) {
    integer, // SQLITE_INTEGER
    float,   // SQLITE_FLOAT
    text,    // SQLITE3_TEXT
    blob,    // SQLITE_BLOB
    null,    // SQLITE_NULL
};
```

Note: `columnType()` returns the **storage class** of the value in the current row, not the declared column type. SQLite uses dynamic typing -- the same column can hold different types in different rows.

### Example: Inspecting a Result Set

```zig
var stmt = try db.prepare("SELECT id, name, score FROM players");
defer stmt.deinit();

// Column count is available immediately after prepare
const n = stmt.columnCount(); // 3

// Column names are available after prepare
var i: u32 = 0;
while (i < n) : (i += 1) {
    if (stmt.columnName(i)) |name| {
        std.debug.print("column {d}: {s}\n", .{ i, name });
    }
}
// Output:
//   column 0: id
//   column 1: name
//   column 2: score
```

### Example: Runtime Type Checking

```zig
if (try stmt.step()) {
    var i: u32 = 0;
    while (i < stmt.columnCount()) : (i += 1) {
        switch (stmt.columnType(i)) {
            .integer => std.debug.print("col {d}: int = {d}\n", .{ i, stmt.columnInt(i) }),
            .float => std.debug.print("col {d}: float = {d}\n", .{ i, stmt.columnFloat(i) }),
            .text => std.debug.print("col {d}: text = {s}\n", .{ i, stmt.columnText(i) orelse "(empty)" }),
            .blob => std.debug.print("col {d}: blob ({d} bytes)\n", .{ i, if (stmt.columnBlob(i)) |b| b.len else 0 }),
            .null => std.debug.print("col {d}: NULL\n", .{i}),
        }
    }
}
```

---

## Expanded SQL

Retrieve the SQL string with all bound parameter values substituted in. Wraps `sqlite3_expanded_sql()`. Useful for debugging, logging, and error reporting.

### Method

```zig
pub fn expandedSql(self: *Statement, allocator: std.mem.Allocator) ![]const u8
```

Returns a caller-owned slice. The caller must free it with `allocator.free()`.

Returns `SqliteError.NoMem` if SQLite cannot generate the expanded string (out of memory).

### Example: Logging Bound Queries

```zig
var stmt = try db.prepare("INSERT INTO users (name, age) VALUES (?1, ?2)");
defer stmt.deinit();

try stmt.bindText(1, "Alice");
try stmt.bindInt32(2, 30);

const expanded = try stmt.expandedSql(allocator);
defer allocator.free(expanded);
// expanded == "INSERT INTO users (name, age) VALUES ('Alice', 30)"

std.log.info("executing: {s}", .{expanded});
_ = try stmt.step();
```

---

## Comptime Tuple Binding

Bind parameters using a Zig tuple instead of individual `bindText`/`bindInt` calls. Uses `inline for` with comptime type dispatch -- zero runtime overhead.

This is an ergonomic layer on top of the existing individual bind methods, which remain available.

### Statement.bind()

```zig
pub fn bind(self: *Statement, args: anytype) !void
```

Binds each tuple field to a positional parameter (1-indexed). Type dispatch:

| Zig Type | Binds As |
|----------|----------|
| `[]const u8`, string literals | TEXT (via `bindText`) |
| `i32` and smaller signed ints | INTEGER 32-bit (via `bindInt32`) |
| `i64` and larger ints | INTEGER 64-bit (via `bindInt`) |
| `comptime_int` | i32 or i64 based on value range |
| `f64`, `comptime_float` | REAL (via `bindFloat`) |
| `bool` | INTEGER 0/1 (via `bindBool`) |
| `null` | NULL (via `bindNull`) |
| `?T` (optionals) | Unwraps to T or NULL |
| `Blob` | BLOB (via `bindBlob`) |

### Blob Marker Type

To distinguish blob data from text (both are `[]const u8`), use the `Blob` marker:

```zig
const zqlite = @import("zqlite");

try stmt.bind(.{ zqlite.Blob{ .data = &raw_bytes } });
try stmt.bind(.{ zqlite.Blob{ .data = null } }); // NULL blob
```

### Database.execDml()

```zig
pub fn execDml(self: *Database, sql: []const u8, args: anytype) !void
```

One-shot prepare + bind + step for INSERT/UPDATE/DELETE. The statement is automatically finalized.

```zig
try db.execDml("INSERT INTO users (name, age) VALUES (?1, ?2)", .{ "Alice", 30 });
try db.execDml("UPDATE users SET age = ?1 WHERE name = ?2", .{ 31, "Alice" });
try db.execDml("DELETE FROM users WHERE name = ?1", .{"Alice"});
```

### Database.query()

```zig
pub fn query(self: *Database, sql: []const u8, args: anytype) !Statement
```

Prepare + bind, returning the Statement ready for stepping. Caller owns the Statement.

```zig
var stmt = try db.query("SELECT name, age FROM users WHERE age > ?1", .{25});
defer stmt.deinit();

while (try stmt.step()) {
    const name = stmt.columnText(0);
    const age = stmt.columnInt32(1);
    _ = .{ name, age };
}
```

---

## Row/Rows Iterators

Ergonomic types for iterating query results. `Row` provides short method names for column access. `Rows` is an iterator that accumulates errors internally so callers can use a plain `while` loop.

### Row

A non-owning view over a Statement. Provides shorter method names that delegate to the underlying column methods.

| Method | Returns | Delegates To |
|--------|---------|-------------|
| `text(idx)` | `?[]const u8` | `columnText` |
| `blob(idx)` | `?[]const u8` | `columnBlob` |
| `int(idx)` | `i64` | `columnInt` |
| `int32(idx)` | `i32` | `columnInt32` |
| `float(idx)` | `f64` | `columnFloat` |
| `boolean(idx)` | `bool` | `columnBool` |
| `isNull(idx)` | `bool` | `columnIsNull` |
| `optionalInt(idx)` | `?i64` | `columnOptionalInt` |
| `optionalInt32(idx)` | `?i32` | `columnOptionalInt32` |
| `optionalFloat(idx)` | `?f64` | `columnOptionalFloat` |
| `columnCount()` | `u32` | `columnCount` |
| `columnName(idx)` | `?[]const u8` | `columnName` |
| `columnType(idx)` | `ColumnType` | `columnType` |

Row does **not** have a `deinit()` method. Its lifetime is tied to the parent Rows iterator.

### Rows

An iterator that owns a Statement. Accumulates errors internally so the iteration loop stays clean.

```zig
pub const Rows = struct {
    stmt: Statement,
    err: ?anyerror = null,
    done: bool = false,

    pub fn deinit(self: *Rows) void;
    pub fn next(self: *Rows) ?Row;
};
```

### Database.rows()

```zig
pub fn rows(self: *Database, sql: []const u8, args: anytype) !Rows
```

Prepare + bind + return a Rows iterator. Caller must call `deinit()`.

### Database.row()

```zig
pub fn row(self: *Database, sql: []const u8, args: anytype) !Rows
```

Convenience for single-row queries. Returns a Rows iterator -- call `next()` once.

### Example: Iterating Multiple Rows

```zig
var result = try db.rows("SELECT name, score FROM players WHERE score > ?1", .{100});
defer result.deinit();

while (result.next()) |r| {
    const name = r.text(0) orelse "(unknown)";
    const score = r.int(1);
    std.debug.print("{s}: {d}\n", .{ name, score });
}
if (result.err) |err| return err;
```

### Example: Single Row Lookup

```zig
var result = try db.row("SELECT name, age FROM users WHERE id = ?1", .{user_id});
defer result.deinit();

if (result.next()) |r| {
    const name = r.text(0);
    const age = r.int32(1);
    _ = .{ name, age };
} else {
    // No matching row
}
```

### Lifetime Note

The Row returned by `next()` borrows the Rows iterator's internal Statement. It is only valid until the next call to `next()` or `deinit()`. Do not store Row references across iterations.

---

## Connection Pool

Thread-safe fixed-size connection pool for multi-threaded applications. Uses `std.Thread.Mutex` and `std.Thread.Condition` for synchronization. LIFO stack internally (most recently released connection is next acquired).

### Pool.Config

```zig
pub const Config = struct {
    size: usize,                                              // Number of connections
    path: []const u8,                                         // Database file path
    flags: c_int = OpenFlags.DEFAULT,                         // Open flags
    on_connection: ?*const fn (*Database) anyerror!void = null,       // Runs per-connection
    on_first_connection: ?*const fn (*Database) anyerror!void = null, // Runs once on first
};
```

### Pool.init() / Pool.deinit()

```zig
var pool = try zqlite.Pool.init(allocator, .{
    .size = 5,
    .path = "/tmp/mydb.sqlite",
    .on_first_connection = &setupSchema,
    .on_connection = &configureConn,
});
defer pool.deinit();
```

`init()` opens all connections, runs `on_first_connection` on the first one, and `on_connection` on each. Uses `errdefer` to clean up partially initialized connections on failure.

### Pool.acquire() / Conn.release()

```zig
var conn = pool.acquire();  // Blocks if all connections in use
defer conn.release();

try conn.exec("INSERT INTO logs (msg) VALUES ('hello')");
```

`acquire()` blocks via condition variable when all connections are in use. `release()` returns the connection to the pool and signals one waiter.

### Conn

A pool-aware wrapper around `*Database`. Provides the same API surface:

| Method | Description |
|--------|-------------|
| `release()` | Return connection to pool |
| `exec(sql)` | Execute raw SQL |
| `execZ(sql)` | Execute null-terminated SQL |
| `prepare(sql)` | Prepare a statement |
| `execDml(sql, args)` | One-shot DML with tuple binding |
| `query(sql, args)` | Prepare + bind, return Statement |
| `rows(sql, args)` | Prepare + bind, return Rows iterator |
| `lastInsertRowId()` | Last inserted rowid |
| `changes()` | Rows affected by last DML |
| `getErrorMessage()` | Last SQLite error message |

### Example: Multi-Threaded Usage

```zig
const zqlite = @import("zqlite");

var pool = try zqlite.Pool.init(allocator, .{
    .size = 4,
    .path = "app.db",
    .on_first_connection = &struct {
        fn f(db: *zqlite.Database) !void {
            try db.exec("CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT)");
        }
    }.f,
});
defer pool.deinit();

// Each thread acquires its own connection
var conn = pool.acquire();
defer conn.release();

try conn.execDml("INSERT INTO kv (k, v) VALUES (?1, ?2)", .{ "key1", "value1" });

var result = try conn.rows("SELECT k, v FROM kv", .{});
defer result.deinit();
while (result.next()) |row| {
    _ = row.text(0);
}
```

---

## API Quick Reference

All methods added by the features documented above.

### Error Helpers

| Function | Signature | Description |
|----------|-----------|-------------|
| `errorFromCode` | `(rc: c_int) SqliteError` | Map raw SQLite code to typed error |
| `isUnique` | `(err: SqliteError) bool` | True if error is `ConstraintUnique` |
| `isConstraint` | `(err: SqliteError) bool` | True if error is any constraint violation |

### Database Methods

| Method | Signature | Description |
|--------|-----------|-------------|
| `openWithFlags` | `(allocator, path, flags: c_int) !Database` | Open with custom SQLite flags |
| `execDml` | `(sql, args) !void` | One-shot prepare + bind + step for DML |
| `query` | `(sql, args) !Statement` | Prepare + bind, return Statement |
| `rows` | `(sql, args) !Rows` | Prepare + bind, return Rows iterator |
| `row` | `(sql, args) !Rows` | Convenience for single-row queries |

### Statement Binding Methods

| Method | Signature | Description |
|--------|-----------|-------------|
| `bindBlob` | `(idx: u32, value: ?[]const u8) !void` | Bind raw bytes or NULL |
| `bindFloat` | `(idx: u32, value: f64) !void` | Bind a double |
| `bindOptionalFloat` | `(idx: u32, value: ?f64) !void` | Bind a double or NULL |
| `bind` | `(args: anytype) !void` | Bind all tuple fields to positional params |
| `expandedSql` | `(allocator) ![]const u8` | SQL with bound values substituted |

### Statement Column Methods

| Method | Signature | Description |
|--------|-----------|-------------|
| `columnBlob` | `(idx: u32) ?[]const u8` | Read blob data or null |
| `columnFloat` | `(idx: u32) f64` | Read a double (0.0 if NULL) |
| `columnOptionalFloat` | `(idx: u32) ?f64` | Read a double or null |
| `columnCount` | `() u32` | Number of result columns |
| `columnName` | `(idx: u32) ?[]const u8` | Name of column at index |
| `columnType` | `(idx: u32) ColumnType` | Storage class of current value |

### Row Methods

| Method | Signature | Description |
|--------|-----------|-------------|
| `text` | `(idx: u32) ?[]const u8` | Read text column |
| `blob` | `(idx: u32) ?[]const u8` | Read blob column |
| `int` | `(idx: u32) i64` | Read 64-bit integer |
| `int32` | `(idx: u32) i32` | Read 32-bit integer |
| `float` | `(idx: u32) f64` | Read double |
| `boolean` | `(idx: u32) bool` | Read boolean (0/1) |
| `isNull` | `(idx: u32) bool` | Check if column is NULL |
| `optionalInt` | `(idx: u32) ?i64` | Read nullable 64-bit integer |
| `optionalInt32` | `(idx: u32) ?i32` | Read nullable 32-bit integer |
| `optionalFloat` | `(idx: u32) ?f64` | Read nullable double |

### Rows Methods

| Method | Signature | Description |
|--------|-----------|-------------|
| `next` | `() ?Row` | Advance to next row, null when done |
| `deinit` | `() void` | Finalize underlying statement |

### Pool Methods

| Method | Signature | Description |
|--------|-----------|-------------|
| `Pool.init` | `(allocator, Config) !Pool` | Create pool with N connections |
| `Pool.deinit` | `() void` | Close all connections, free memory |
| `Pool.acquire` | `() Conn` | Get a connection (blocks if none available) |

### Conn Methods

| Method | Signature | Description |
|--------|-----------|-------------|
| `release` | `() void` | Return connection to pool |
| `exec` | `(sql) !void` | Execute raw SQL |
| `prepare` | `(sql) !Statement` | Prepare a statement |
| `execDml` | `(sql, args) !void` | One-shot DML with tuple binding |
| `query` | `(sql, args) !Statement` | Prepare + bind, return Statement |
| `rows` | `(sql, args) !Rows` | Prepare + bind, return Rows iterator |
