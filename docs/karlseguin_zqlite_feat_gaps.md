# Feature Gap Analysis: zqlite vs karlseguin/zqlite.zig

Comparison of our zqlite against [karlseguin/zqlite.zig](https://github.com/karlseguin/zqlite.zig) (147 stars, MIT, actively maintained as of Feb 2026).

Both are thin Zig wrappers around SQLite's C API. Same goal, different trade-offs.

---

## Table of Contents

- [Architectural Differences](#architectural-differences)
- [Feature Gaps (We Lack)](#feature-gaps-we-lack)
  - [P0 - High Value](#p0---high-value)
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
- [Implementation Notes](#implementation-notes)

---

## Architectural Differences

```
+---------------------+----------------------------+-------------------------------+
| Aspect              | Our zqlite                 | karlseguin/zqlite.zig         |
+---------------------+----------------------------+-------------------------------+
| SQLite bundling     | Bundled in vendor/         | Not bundled; consumer links   |
| Allocator           | Required for open()        | Not needed for core ops       |
| PRAGMA auto-config  | WAL, FK, busy_timeout, etc | None; consumer handles all    |
| Source layout        | 1 file (root.zig, ~430 ln) | 3 files (~1300 ln total)      |
| Open flags          | Hardcoded (sqlite3_open)   | 20+ flags (sqlite3_open_v2)   |
| Binding strategy    | Individual typed methods   | Comptime tuple dispatch       |
| Text/blob binding   | SQLITE_TRANSIENT (copies)  | SQLITE_STATIC (zero-copy)     |
| Error granularity   | 7 errors                   | 97 errors (primary+extended)  |
| Connection pooling  | Not implemented            | Built-in Pool type            |
+---------------------+----------------------------+-------------------------------+
```

---

## Feature Gaps (We Lack)

### P0 - High Value

These are gaps that limit real-world usage of our library.

#### 1. Granular Error Types

**Current state**: 7 flat errors (`OpenFailed`, `PrepareFailed`, `BindFailed`, `StepFailed`, `ExecuteFailed`, `BusyTimeout`, `Corrupt`).

**Problem**: Consumers cannot distinguish between failure modes. A unique constraint violation looks the same as a foreign key error -- both are `StepFailed`. This forces consumers to parse error messages or drop down to the raw C API.

**karlseguin's approach**: 97 distinct error values mapping all SQLite primary result codes (26) and extended result codes (71). Examples: `ConstraintUnique`, `ConstraintForeignKey`, `BusyTimeout`, `IoerrWrite`, `ReadonlyCantInit`.

```zig
// karlseguin -- consumers can handle specific failures:
conn.exec("INSERT ...", .{val}) catch |err| {
    if (zqlite.isUnique(err)) {
        // handle duplicate
    }
    return err;
};
```

**Recommendation**: Expand our error set to cover at least the 26 primary result codes. Extended codes can be added incrementally. Add an `errorFromCode(rc: c_int) SqliteError` helper. Consider a convenience `isUnique(err)` function.

**Scope**: Moderate. Touches error type definition, every `switch` on SQLite return codes, and the public API.

---

#### 2. Blob Binding and Extraction

**Current state**: Not implemented. On our roadmap.

**karlseguin's approach**: Marker type to distinguish blob from text at comptime:

```zig
pub const Blob = struct { value: []const u8 };

// Usage:
conn.exec("INSERT INTO t (img) VALUES (?1)", .{zqlite.blob(image_data)});

// Extraction:
const data = row.blob(0);         // []const u8
const maybe = row.nullableBlob(0); // ?[]const u8
```

**Recommendation**: Add `bindBlob(idx, []const u8)` and `columnBlob(idx)` methods. If we later add tuple binding, the marker type pattern is the right disambiguation approach.

**Scope**: Small. Two new methods on Statement, maps to `sqlite3_bind_blob` / `sqlite3_column_blob`.

---

#### 3. Float/Double Support

**Current state**: No `f64` binding or extraction at all.

**karlseguin's approach**: Full `f64` support via `sqlite3_bind_double` and `sqlite3_column_double`, with nullable variants.

**Recommendation**: Add `bindFloat(idx, f64)`, `columnFloat(idx) f64`, `columnOptionalFloat(idx) ?f64`. Any numerical workload needs this.

**Scope**: Small. Three new methods on Statement.

---

#### 4. Debug-Mode Multi-Statement Detection

**Current state**: We pass `null` for the `pz_tail` parameter of `sqlite3_prepare_v2`. If a user passes two SQL statements, the second is silently ignored.

**karlseguin's approach**: In debug builds only, checks if `pz_tail` points to a non-empty string after prepare. If so, returns `error.MultipleStatements`. The check is compiled out in release mode.

```zig
// karlseguin (debug only):
if (@import("builtin").mode == .Debug) {
    if (pz_tail[0] != 0) {
        // Try to prepare the tail -- if it produces a real statement,
        // not just trailing comments/whitespace, error out.
        return error.MultipleStatements;
    }
}
```

**Recommendation**: Adopt this pattern. It catches a real class of bugs (silent SQL truncation) with zero release-mode cost. Smart handling of trailing whitespace/comments is a nice touch.

**Scope**: Small. Add the check to `Statement.init()`.

---

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

### P1 - Medium Value

#### 6. Column Metadata

**Current state**: We have no way to inspect column names, counts, or types at runtime.

**karlseguin's approach**:
- `stmt.columnCount()` -- number of columns in result set
- `stmt.columnName(idx)` -- column name as string
- `stmt.columnType(idx)` -- returns `ColumnType` enum (`.int`, `.float`, `.text`, `.blob`, `.null`)

**Use cases**: Dynamic query builders, ORM-like layers, debugging, introspection tools.

**Scope**: Small. Wraps `sqlite3_data_count`, `sqlite3_column_name`, `sqlite3_column_type`.

---

#### 7. Expanded SQL for Debugging

**Current state**: No way to see a prepared statement with its bound values filled in.

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

#### 8. Configurable Open Flags

**Current state**: We use `sqlite3_open()` which has no flag parameter. Consumers cannot open read-only connections, use URI filenames, or control threading mode at open time.

**karlseguin's approach**: Exposes 20+ flags via an `OpenFlags` struct and uses `sqlite3_open_v2`:

```zig
const flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.ReadOnly;
var conn = try zqlite.open("/tmp/db.sqlite", flags);
```

Available flags include: `Create`, `ReadOnly`, `ReadWrite`, `Memory`, `Uri`, `NoMutex`, `FullMutex`, `SharedCache`, `PrivateCache`, `OpenWAL`, `NoFollow`, `EXResCode`, and more.

**Recommendation**: Switch to `sqlite3_open_v2` with a flags parameter. Provide a default flag set that matches our current behavior (`ReadWrite | Create`) so existing callers are unaffected.

**Scope**: Moderate. Changes the `open()` signature and internal implementation.

---

### P2 - Design Questions

These are not clear-cut improvements -- they involve trade-offs worth discussing.

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

**Current state**: We use `SQLITE_TRANSIENT` for text binding, meaning SQLite copies the data internally.

**karlseguin's approach**: Uses `SQLITE_STATIC`, meaning SQLite does NOT copy -- the caller's memory must remain valid until the statement finishes stepping.

**Trade-offs**:
- `SQLITE_TRANSIENT`: Safer by default, no lifetime concerns, slight allocation overhead
- `SQLITE_STATIC`: Zero-copy, faster, but footgun if memory is freed before step

**Recommendation**: Keep `SQLITE_TRANSIENT` as default (safety first). Consider offering a `bindTextStatic` variant for performance-sensitive paths where the caller guarantees lifetime.

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

---

## API Comparison

### Opening a Database

```
Ours:
    var db = try zqlite.Database.open(allocator, "mydb.sqlite");
    defer db.close();
    // WAL, FK, busy_timeout auto-configured

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
    try stmt.bindNull(4);
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
Ours:
    stmt.columnText(0)          // ?[]const u8
    stmt.columnInt(0)           // i64
    stmt.columnInt32(0)         // i32
    stmt.columnBool(0)          // bool
    stmt.columnOptionalInt(0)   // ?i64
    stmt.columnOptionalInt32(0) // ?i32
    -- NO float, blob, column metadata

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
    -- NO i32 methods
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
Ours (7 errors):
    SqliteError.OpenFailed
    SqliteError.PrepareFailed
    SqliteError.BindFailed
    SqliteError.StepFailed
    SqliteError.ExecuteFailed
    SqliteError.BusyTimeout
    SqliteError.Corrupt

karlseguin (97 errors, selected examples):
    Error.Abort, Error.Auth, Error.Busy, Error.Cantopen, Error.Constraint,
    Error.Corrupt, Error.Full, Error.Ioerr, Error.Locked, Error.Mismatch,
    Error.Misuse, Error.Nolfs, Error.Nomem, Error.Notfound, Error.Perm,
    Error.Protocol, Error.Range, Error.Readonly, Error.Schema,
    // Extended:
    Error.ConstraintUnique, Error.ConstraintForeignKey, Error.ConstraintCheck,
    Error.ConstraintNotNull, Error.ConstraintPrimaryKey, Error.BusyTimeout,
    Error.BusyRecovery, Error.IoerrRead, Error.IoerrWrite, Error.IoerrFsync,
    // ... 60+ more
```

---

## Implementation Notes

### Priority Order for Implementation

Based on impact and effort:

```
Phase 1 (Quick wins, small scope):
  [3] Float/double support
  [4] Multi-statement detection (debug only)
  [2] Blob binding/extraction

Phase 2 (Moderate scope):
  [1] Granular error types
  [8] Configurable open flags (sqlite3_open_v2)
  [6] Column metadata
  [7] expandedSql() for debugging

Phase 3 (Large scope, design work needed):
  [5] Connection pooling
  [9] Comptime tuple binding (additive, keep existing API)
  [12] Row/Rows iterator types

Phase 4 (Optional, discuss first):
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

*Analysis performed Feb 2026. karlseguin/zqlite.zig at latest master, our zqlite at commit 787830f.*
