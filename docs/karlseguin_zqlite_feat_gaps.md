# Feature Gap Analysis: zqlite vs karlseguin/zqlite.zig

Comparison of our zqlite against [karlseguin/zqlite.zig](https://github.com/karlseguin/zqlite.zig) (147 stars, MIT, actively maintained as of Feb 2026).

Both are thin Zig wrappers around SQLite's C API. Same goal, different trade-offs.

---

## Table of Contents

- [Architectural Differences](#architectural-differences)
- [Integrated Features](#integrated-features)
- [Remaining Gaps](#remaining-gaps)
  - [P1 - Medium Value](#p1---medium-value)
  - [P2 - Design Questions](#p2---design-questions)
- [Our Advantages](#our-advantages)
- [API Comparison](#api-comparison)
  - [Opening a Database](#opening-a-database)
  - [Parameter Binding](#parameter-binding)
  - [Column Extraction](#column-extraction)
  - [Row Iteration](#row-iteration)
  - [Transactions](#transactions)
  - [Error Handling](#error-handling)
- [Remaining Work](#remaining-work)

---

## Architectural Differences

```
+---------------------+----------------------------+-------------------------------+
| Aspect              | Our zqlite                 | karlseguin/zqlite.zig         |
+---------------------+----------------------------+-------------------------------+
| SQLite bundling     | Bundled in vendor/         | Not bundled; consumer links   |
| Allocator           | Required for open()        | Not needed for core ops       |
| PRAGMA auto-config  | WAL, FK, busy_timeout, etc | None; consumer handles all    |
| Source layout        | 1 file (root.zig, ~1050 ln)| 3 files (~1300 ln total)      |
| Open flags          | sqlite3_open_v2 + OpenFlags| 20+ flags (sqlite3_open_v2)   |
| Binding strategy    | Individual typed methods   | Comptime tuple dispatch       |
| Text/blob binding   | SQLITE_TRANSIENT (copies)  | SQLITE_STATIC (zero-copy)     |
| Error granularity   | 35 errors (primary+ext)    | 97 errors (primary+extended)  |
| Connection pooling  | Not implemented            | Built-in Pool type            |
+---------------------+----------------------------+-------------------------------+
```

---

## Integrated Features

These features from the original gap analysis have been implemented in v0.2.0.

### [DONE] 1. Granular Error Types

**Implemented in**: v0.2.0 (commit 2d1867a)

**What we built**: 35 typed errors covering 23 primary SQLite result codes, 8 extended constraint subtypes, 3 extended busy subtypes, and 1 debug-only error (`MultipleStatements`).

```zig
pub const SqliteError = error{
    // 23 primary codes: Error, Internal, Perm, Abort, Busy, Locked,
    // NoMem, ReadOnly, Interrupt, IoErr, Corrupt, NotFound, Full,
    // CantOpen, Protocol, Schema, TooBig, Constraint, Mismatch,
    // Misuse, Auth, Range, NotADb

    // 8 constraint subtypes: ConstraintCheck, ConstraintCommitHook,
    // ConstraintForeignKey, ConstraintNotNull, ConstraintPrimaryKey,
    // ConstraintTrigger, ConstraintUnique, ConstraintRowId

    // 3 busy subtypes: BusyRecovery, BusySnapshot, BusyTimeout

    // Debug: MultipleStatements
};
```

Helpers: `errorFromCode(rc)`, `isUnique(err)`, `isConstraint(err)`.

**Difference from karlseguin**: We cover 35 errors vs their 97. We omit the IOERR subtypes (IoerrRead, IoerrWrite, etc.), READONLY subtypes, and other rarely-needed extended codes. These can be added incrementally if needed. The `else => SqliteError.Error` fallback ensures unknown codes are handled.

**What remains**: Could expand to cover IOERR, READONLY, CANTOPEN extended codes if consumers need them.

---

### [DONE] 2. Blob Binding and Extraction

**Implemented in**: v0.2.0

```zig
// Bind blob data (or null)
try stmt.bindBlob(1, &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF });
try stmt.bindBlob(1, null);  // binds SQL NULL

// Extract blob data
const data: ?[]const u8 = stmt.columnBlob(0);
```

Uses `SQLITE_TRANSIENT` (safe default, SQLite copies the data). Returns `?[]const u8` -- null for SQL NULL or zero-length blobs.

**Parity with karlseguin**: Full parity. They use `SQLITE_STATIC` (zero-copy) which is faster but requires caller to manage lifetime.

---

### [DONE] 3. Float/Double Support

**Implemented in**: v0.2.0

```zig
try stmt.bindFloat(1, 3.14159);
try stmt.bindOptionalFloat(1, @as(?f64, null));

const val: f64 = stmt.columnFloat(0);
const maybe: ?f64 = stmt.columnOptionalFloat(0);
```

**Parity with karlseguin**: Full parity plus we offer `bindOptionalFloat` and `columnOptionalFloat` which they lack.

---

### [DONE] 4. Debug-Mode Multi-Statement Detection

**Implemented in**: v0.2.0

In debug builds, `Statement.init()` checks whether the SQL input contains multiple statements. If the tail after `sqlite3_prepare_v2` can itself be prepared as a valid statement, returns `SqliteError.MultipleStatements`. Compiled out in release mode (zero cost).

Handles trailing whitespace, semicolons, and comments correctly -- only errors if the tail contains a real preparable statement.

**Parity with karlseguin**: Full parity. Same approach (try-prepare the tail), same debug-only guard.

---

### [DONE] 6. Column Metadata

**Implemented in**: v0.2.0

```zig
const count: u32 = stmt.columnCount();
const name: ?[]const u8 = stmt.columnName(0);
const col_type: ColumnType = stmt.columnType(0);  // .integer, .float, .text, .blob, .null
```

Also added `columnIsNull(idx)` helper (not in karlseguin) for cleaner optional column checks.

**Parity with karlseguin**: Full parity. We use `sqlite3_column_count` (available after prepare) rather than `sqlite3_data_count` (only valid after step). Same ColumnType enum values.

---

### [DONE] 8. Configurable Open Flags

**Implemented in**: v0.2.0

```zig
// Default open (unchanged API, uses READWRITE | CREATE | EXRESCODE)
var db = try Database.open(allocator, "mydb.sqlite");

// Advanced open with explicit flags
var db = try Database.openWithFlags(allocator, "mydb.sqlite",
    OpenFlags.READONLY | OpenFlags.EXRESCODE);
```

Available flags: `READONLY`, `READWRITE`, `CREATE`, `URI`, `MEMORY`, `NOMUTEX`, `FULLMUTEX`, `SHAREDCACHE`, `PRIVATECACHE`, `NOFOLLOW`, `EXRESCODE`.

Default includes `EXRESCODE` so extended result codes work out of the box with our granular error types.

**Parity with karlseguin**: Full parity. Same flag set, same `sqlite3_open_v2` backend. We additionally auto-configure PRAGMAs after opening.

---

## Remaining Gaps

### P1 - Medium Value

#### 7. Expanded SQL for Debugging

**Current state**: Not implemented.

**karlseguin's approach**:

```zig
const sql = try stmt.expandedSql(allocator);
defer allocator.free(sql);
// e.g. "INSERT INTO t (name, age) VALUES ('Alice', 30)"
```

Wraps `sqlite3_expanded_sql`. This is the only method in karlseguin's library that takes an allocator -- it copies the result from SQLite's internal buffer and frees the original with `sqlite3_free`.

**Use cases**: Debugging, logging, error reporting.

**Scope**: Small. One new method.

---

### P2 - Design Questions

These are not clear-cut improvements -- they involve trade-offs worth discussing.

#### 5. Connection Pooling

**Current state**: Not implemented. On our roadmap.

**karlseguin's approach**: Fixed-size pool with `std.Thread.Mutex` and `std.Thread.Condition`:

```zig
var pool = try zqlite.Pool.init(allocator, .{
    .size = 5,
    .path = "/tmp/db.sqlite",
    .flags = zqlite.OpenFlags.Create,
    .on_connection = &initConn,       // runs per-connection (PRAGMAs, etc.)
    .on_first_connection = &initDB,   // runs once (schema setup)
});
defer pool.deinit();

const conn = pool.acquire();  // blocks until available
defer conn.release();
```

Design details:
- Fixed size, LIFO stack internally
- `acquire()` blocks via condvar when all connections are in use
- `release()` returns to pool and signals one waiter
- Each `Conn` has a `_pool` backpointer enabling `conn.release()`
- Callback system for per-connection and first-connection initialization

**Recommendation**: Good reference design. Our auto-PRAGMA system pairs well with `on_connection` callbacks. Consider whether we want fixed-size or growable pools.

**Scope**: Large. New type, threading primitives, integration with Database/Conn lifecycle.

---

#### 9. Comptime Tuple Binding

**karlseguin's approach**:
```zig
// One-shot: prepare + bind + step in a single call
try conn.exec("INSERT INTO t (a, b) VALUES (?1, ?2)", .{"Alice", 42});

// Or bind a tuple to an existing statement:
try stmt.bind(.{"Alice", 42});
```

Uses `inline for` over the tuple fields with `@TypeOf` dispatch at comptime. Zero runtime overhead.

**Trade-offs**:
- Pro: Dramatically more ergonomic for common cases
- Pro: Compile-time type checking, no runtime dispatch
- Con: Less flexible for dynamic/loop-based binding
- Con: Requires marker type for blob vs text disambiguation
- Con: Uses `SQLITE_STATIC` (caller must keep data alive until step)

**Recommendation**: Offer both. Keep our explicit `bindText`/`bindInt` methods and layer a `bind(tuple)` convenience on top. Also consider adding one-shot `exec(sql, params)` that prepares, binds, steps, and finalizes.

---

#### 10. Allocator-Free Core

**karlseguin's approach**: Avoids allocators entirely by requiring null-terminated paths (`[*:0]const u8`). Our approach accepts `[]const u8` and heap-allocates a null-terminated copy.

**Trade-offs**:
- Pro (karlseguin): No allocation in any core path
- Pro (ours): Friendlier for callers who have Zig slices
- Con (karlseguin): Caller must manage null termination
- Con (ours): Allocation on open (minor, but present)

**Recommendation**: Add an `openZ(path: [:0]const u8)` variant for callers who already have null-terminated strings. Keep the allocator-based `open()` as the primary API for ergonomics.

---

#### 11. SQLITE_STATIC vs SQLITE_TRANSIENT

**Current state**: We use `SQLITE_TRANSIENT` for text and blob binding, meaning SQLite copies the data internally.

**karlseguin's approach**: Uses `SQLITE_STATIC`, meaning SQLite does NOT copy -- the caller's memory must remain valid until the statement finishes stepping.

**Trade-offs**:
- `SQLITE_TRANSIENT`: Safer by default, no lifetime concerns, slight allocation overhead
- `SQLITE_STATIC`: Zero-copy, faster, but footgun if memory is freed before step

**Recommendation**: Keep `SQLITE_TRANSIENT` as default (safety first). Consider offering a `bindTextStatic`/`bindBlobStatic` variant for performance-sensitive paths where the caller guarantees lifetime.

---

#### 12. Row/Rows Separation

**karlseguin's approach**: Separate `Row` and `Rows` types wrapping the underlying `Stmt`:

```zig
// Single row -- caller must deinit
if (try conn.row("SELECT ...", .{id})) |row| {
    defer row.deinit();
    return row.text(0);
}

// Multiple rows -- iterator owns the statement
var rows = try conn.rows("SELECT ...", .{});
defer rows.deinit();
while (rows.next()) |row| {
    // Do NOT deinit row here
}
if (rows.err) |err| return err;
```

**Trade-offs**:
- Pro: Clean separation of single-row vs multi-row patterns
- Pro: Error accumulation in iterator avoids `!?Row` return type
- Con: Ownership rules differ between `row()` and `rows().next()` -- potential footgun
- Con: More types to learn and maintain

**Recommendation**: Worth considering as an ergonomic layer. The error accumulation pattern (check `rows.err` after loop) is particularly nice.

---

#### 13. Generic Column Getter

**karlseguin's approach**:
```zig
const id = row.get(i64, 0);
const name = row.get(?[]const u8, 1);
const data = row.get(Blob, 2);
```

Comptime dispatch based on the requested type. Complements the named methods (`row.int()`, `row.text()`, etc.).

**Recommendation**: Nice for generic/framework code. Low priority for direct usage where named methods are clearer.

---

## Our Advantages

Features and design choices where our library is ahead:

| Feature | Details |
|---------|---------|
| **Bundled SQLite** | Self-contained. `zig fetch --save` and done. karlseguin's consumers must figure out linking themselves. |
| **Auto PRAGMA config** | WAL, foreign keys, busy timeout, synchronous mode set out of the box. Sensible defaults. |
| **FTS5 + JSON1 enabled** | Compiled into our amalgamation. karlseguin leaves this to consumers. |
| **Dedicated i32 methods** | `bindInt32()`, `columnInt32()`, `columnOptionalInt32()`. karlseguin only has i64. |
| **SQLITE_TRANSIENT default** | Safer memory model -- no lifetime concerns for bound text/blob data. |
| **Closure-based transactions** | `transaction(ctx, fn)` pattern prevents forgotten rollbacks. karlseguin uses manual begin/commit/errdefer. |
| **columnIsNull helper** | Dedicated null-check method. karlseguin requires manual `columnType() == .null` check. |
| **Optional float support** | `bindOptionalFloat()`, `columnOptionalFloat()`. karlseguin has no optional float methods. |
| **EXRESCODE by default** | Extended result codes enabled out of the box via default open flags. karlseguin requires consumer to opt in. |

---

## API Comparison

### Opening a Database

```
Ours (default -- unchanged from v0.1.0):
    var db = try zqlite.Database.open(allocator, "mydb.sqlite");
    defer db.close();
    // WAL, FK, busy_timeout auto-configured
    // Extended result codes enabled via EXRESCODE flag

Ours (with flags -- new in v0.2.0):
    var db = try zqlite.Database.openWithFlags(allocator, "mydb.sqlite",
        zqlite.OpenFlags.READONLY | zqlite.OpenFlags.EXRESCODE);
    defer db.close();

karlseguin:
    const flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode;
    var conn = try zqlite.open("/tmp/db.sqlite", flags);
    defer conn.close();
    // Consumer must configure PRAGMAs manually
```

### Parameter Binding

```
Ours (individual methods):
    try stmt.bindText(1, "Alice");
    try stmt.bindInt(2, 42);
    try stmt.bindBool(3, true);
    try stmt.bindFloat(4, 3.14);       // NEW in v0.2.0
    try stmt.bindBlob(5, &raw_bytes);  // NEW in v0.2.0
    try stmt.bindNull(6);
    _ = try stmt.step();

karlseguin (tuple):
    try conn.exec("INSERT INTO t VALUES (?1,?2,?3,?4)",
        .{"Alice", 42, true, null});

karlseguin (individual, on Stmt):
    try stmt.bind(.{"Alice", 42, true, null});
    // or: try stmt.bindValue("Alice", 1);
```

### Column Extraction

```
Ours (v0.2.0):
    stmt.columnText(0)          // ?[]const u8
    stmt.columnBlob(0)          // ?[]const u8      NEW
    stmt.columnInt(0)           // i64
    stmt.columnInt32(0)         // i32
    stmt.columnFloat(0)         // f64              NEW
    stmt.columnBool(0)          // bool
    stmt.columnOptionalInt(0)   // ?i64
    stmt.columnOptionalInt32(0) // ?i32
    stmt.columnOptionalFloat(0) // ?f64             NEW
    stmt.columnIsNull(0)        // bool             NEW
    stmt.columnCount()          // u32              NEW
    stmt.columnName(0)          // ?[]const u8      NEW
    stmt.columnType(0)          // ColumnType        NEW

karlseguin:
    row.text(0)            // []const u8
    row.nullableText(0)    // ?[]const u8
    row.int(0)             // i64
    row.boolean(0)         // bool
    row.float(0)           // f64
    row.blob(0)            // []const u8
    row.columnName(0)      // []const u8
    row.columnType(0)      // ColumnType enum
    row.get(T, 0)          // generic comptime dispatch
    -- NO i32 methods, NO optional float
```

### Row Iteration

```
Ours:
    var stmt = try db.prepare("SELECT ...");
    defer stmt.deinit();
    try stmt.bindInt(1, id);
    while (try stmt.step()) {
        const name = stmt.columnText(0);
        // ...
    }

karlseguin (iterator):
    var rows = try conn.rows("SELECT ...", .{id});
    defer rows.deinit();
    while (rows.next()) |row| {
        const name = row.text(0);
    }
    if (rows.err) |err| return err;

karlseguin (single row):
    if (try conn.row("SELECT ...", .{id})) |row| {
        defer row.deinit();
        return row.text(0);
    }
```

### Transactions

```
Ours (closure-based):
    try transactionSimple(&db, struct {
        fn run(d: *Database) !void {
            try d.exec("INSERT INTO t (name) VALUES ('Alice')");
        }
    }.run);

karlseguin (manual):
    try conn.transaction();
    errdefer conn.rollback();
    try conn.exec("INSERT INTO t (name) VALUES (?1)", .{"Alice"});
    try conn.commit();
```

### Error Handling

```
Ours (35 errors, v0.2.0):
    // Primary codes:
    SqliteError.Error, SqliteError.Perm, SqliteError.Busy, SqliteError.Locked,
    SqliteError.NoMem, SqliteError.ReadOnly, SqliteError.IoErr,
    SqliteError.Corrupt, SqliteError.Full, SqliteError.CantOpen,
    SqliteError.Constraint, SqliteError.Mismatch, SqliteError.Misuse,
    SqliteError.Auth, SqliteError.Range, SqliteError.NotADb, ...

    // Extended constraint:
    SqliteError.ConstraintUnique, SqliteError.ConstraintForeignKey,
    SqliteError.ConstraintCheck, SqliteError.ConstraintNotNull,
    SqliteError.ConstraintPrimaryKey, SqliteError.ConstraintTrigger,
    SqliteError.ConstraintRowId, SqliteError.ConstraintCommitHook

    // Extended busy:
    SqliteError.BusyRecovery, SqliteError.BusySnapshot, SqliteError.BusyTimeout

    // Helpers:
    zqlite.errorFromCode(rc)      // raw code -> typed error
    zqlite.isUnique(err)          // true for ConstraintUnique
    zqlite.isConstraint(err)      // true for any constraint variant

karlseguin (97 errors, selected examples):
    Error.Abort, Error.Auth, Error.Busy, Error.Cantopen, Error.Constraint,
    Error.Corrupt, Error.Full, Error.Ioerr, Error.Locked, Error.Mismatch,
    Error.Misuse, Error.Nolfs, Error.Nomem, Error.Notfound, Error.Perm,
    Error.Protocol, Error.Range, Error.Readonly, Error.Schema,
    // Extended:
    Error.ConstraintUnique, Error.ConstraintForeignKey, Error.ConstraintCheck,
    Error.ConstraintNotNull, Error.ConstraintPrimaryKey, Error.BusyTimeout,
    Error.BusyRecovery, Error.IoerrRead, Error.IoerrWrite, Error.IoerrFsync,
    // ... 60+ more (IOERR subtypes, READONLY subtypes, etc.)
```

---

## Remaining Work

### Priority Order

```
Next up (small scope):
  [7] expandedSql() for debugging

Design work needed (large scope):
  [5]  Connection pooling
  [9]  Comptime tuple binding (additive, keep existing API)
  [12] Row/Rows iterator types

Optional (discuss first):
  [10] openZ() for null-terminated paths
  [11] SQLITE_STATIC variant methods
  [13] Generic column getter
```

### Principles

- Our bundled-SQLite, batteries-included philosophy is a differentiator -- do not abandon it.
- Auto-PRAGMA configuration is a feature, not a limitation -- but consider making it opt-out.
- Adding features should be additive -- do not break existing API consumers.
- Prefer safety by default (SQLITE_TRANSIENT, closure transactions) with opt-in performance variants.

---

*Original analysis performed Feb 2026. karlseguin/zqlite.zig at latest master.*
*Updated Feb 2026 after v0.2.0 integration (commit 37c1f05). 6 of 13 features integrated.*
