# Feature Gap Analysis: zqlite vs karlseguin/zqlite.zig

Comparison of our zqlite against [karlseguin/zqlite.zig](https://github.com/karlseguin/zqlite.zig) (147 stars, MIT, actively maintained as of Feb 2026).

Both are thin Zig wrappers around SQLite's C API. Same goal, different trade-offs.

---

## Table of Contents

- [Architectural Differences](#architectural-differences)
- [Integrated Features](#integrated-features)
- [Remaining Gaps](#remaining-gaps)
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
| Source layout        | 1 file (root.zig, ~1900 ln)| 3 files (~1300 ln total)      |
| Open flags          | sqlite3_open_v2 + OpenFlags| 20+ flags (sqlite3_open_v2)   |
| Binding strategy    | Individual + comptime tuple| Comptime tuple dispatch       |
| Text/blob binding   | SQLITE_TRANSIENT (copies)  | SQLITE_STATIC (zero-copy)     |
| Error granularity   | 35 errors (primary+ext)    | 97 errors (primary+extended)  |
| Connection pooling  | Built-in Pool/Conn types   | Built-in Pool type            |
| Row iteration       | Row/Rows + raw Statement   | Row/Rows types                |
+---------------------+----------------------------+-------------------------------+
```

---

## Integrated Features

Features from the original gap analysis implemented across v0.2.0 and v0.3.0.

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

### [DONE] 7. Expanded SQL for Debugging

**Implemented in**: v0.3.0 (commit 42089dd)

```zig
const expanded = try stmt.expandedSql(allocator);
defer allocator.free(expanded);
// e.g. "INSERT INTO t (name, age) VALUES ('Alice', 30)"
```

Wraps `sqlite3_expanded_sql`. Returns caller-owned memory (freed with `allocator.free`). The SQLite-allocated string is freed internally with `sqlite3_free` after copying. Returns `SqliteError.NoMem` if SQLite cannot generate the expansion.

**Parity with karlseguin**: Full parity. Same approach -- allocator-based copy of the SQLite-managed string.

---

### [DONE] 5. Connection Pooling

**Implemented in**: v0.3.0 (commit 42089dd)

```zig
var pool = try zqlite.Pool.init(allocator, .{
    .size = 5,
    .path = "/tmp/db.sqlite",
    .on_connection = &initConn,
    .on_first_connection = &initDB,
});
defer pool.deinit();

var conn = pool.acquire();
defer conn.release();
try conn.execDml("INSERT INTO t (a) VALUES (?1)", .{"hello"});
```

**What we built**: Fixed-size pool with `std.Thread.Mutex` and `std.Thread.Condition`. LIFO stack internally. `acquire()` blocks via condvar when exhausted. `Conn` wrapper delegates the full Database API surface including the new `execDml`, `query`, and `rows` convenience methods.

Pool.Config supports:
- `size` -- number of connections
- `path` -- database file path
- `flags` -- OpenFlags (defaults to DEFAULT)
- `on_connection` -- callback per connection (PRAGMAs, etc.)
- `on_first_connection` -- callback on first connection only (schema setup)

**Difference from karlseguin**: Similar design (fixed-size, mutex/condvar, LIFO, callbacks). Our `Conn` additionally exposes `execDml`, `query`, `rows` from our comptime tuple binding layer. Our auto-PRAGMA system runs automatically on each connection via `Database.openWithFlags`.

---

### [DONE] 9. Comptime Tuple Binding

**Implemented in**: v0.3.0 (commit 42089dd)

```zig
// Bind a tuple to positional parameters
try stmt.bind(.{ "Alice", 42, 3.14, true });

// One-shot DML (prepare + bind + step + finalize)
try db.execDml("INSERT INTO t (a, b) VALUES (?1, ?2)", .{ "Alice", 42 });

// Prepare + bind, return statement for stepping
var stmt = try db.query("SELECT * FROM t WHERE a = ?1", .{"Alice"});
defer stmt.deinit();
```

**What we built**: `Statement.bind(tuple)` using `inline for` with comptime `@TypeOf` dispatch. Supports `[]const u8` (text), string literals, `i32`, `i64`, `f64`, `bool`, `null`, optionals, and `Blob` marker type for blob disambiguation. `Database.execDml()` for one-shot DML. `Database.query()` for prepare+bind.

**Difference from karlseguin**: We kept the explicit `bindText`/`bindInt` methods alongside the tuple API (both available). We use `SQLITE_TRANSIENT` (safe default) vs their `SQLITE_STATIC`. Our `Blob` marker type serves the same purpose as theirs for blob/text disambiguation.

---

### [DONE] 12. Row/Rows Separation

**Implemented in**: v0.3.0 (commit 42089dd)

```zig
// Multiple rows
var result = try db.rows("SELECT name, score FROM players", .{});
defer result.deinit();
while (result.next()) |row| {
    const name = row.text(0);
    const score = row.int(1);
    _ = .{ name, score };
}
if (result.err) |err| return err;

// Single row
var result = try db.row("SELECT name FROM players WHERE id = ?1", .{id});
defer result.deinit();
if (result.next()) |row| {
    const name = row.text(0);
    _ = name;
}
```

**What we built**: `Row` (non-owning view with short method names: `text`, `int`, `float`, `boolean`, `blob`, `isNull`, etc.) and `Rows` (owning iterator with `next() -> ?Row`, error accumulation via `err` field, `done` flag to prevent re-stepping after exhaustion). `Database.rows()` and `Database.row()` convenience methods.

**Difference from karlseguin**: Our `Row` is always non-owning (no deinit) -- simpler ownership rules. `Database.row()` returns `Rows` (call `next()` once) rather than `?Row`, avoiding the ownership problem of who finalizes the statement when no row matches. Our `Rows` has a `done` flag to prevent undefined behavior from stepping after `SQLITE_DONE`.

---

## Remaining Gaps

### Optional -- Discuss First

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
| **Dual binding API** | Both individual typed methods (`bindText`, `bindInt`) and comptime tuple `bind()`. karlseguin has tuple only. |
| **TRANSIENT tuple binding** | Our `bind(tuple)` uses `SQLITE_TRANSIENT` (safe). karlseguin uses `SQLITE_STATIC` (caller manages lifetime). |
| **Simpler Row ownership** | Row is always non-owning. No deinit needed on Row, only on Rows. karlseguin has different ownership rules for `row()` vs `rows().next()`. |
| **Pool auto-PRAGMAs** | Pool connections get auto-PRAGMA config (WAL, FK, etc.) via Database.openWithFlags. karlseguin requires manual on_connection setup. |

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
    try stmt.bindFloat(4, 3.14);
    try stmt.bindBlob(5, &raw_bytes);
    try stmt.bindNull(6);
    _ = try stmt.step();

Ours (tuple -- NEW in v0.3.0):
    try stmt.bind(.{ "Alice", 42, true, 3.14, Blob{.data = &raw_bytes}, null });
    _ = try stmt.step();

Ours (one-shot -- NEW in v0.3.0):
    try db.execDml("INSERT INTO t VALUES (?1,?2)", .{ "Alice", 42 });

karlseguin (tuple):
    try conn.exec("INSERT INTO t VALUES (?1,?2,?3,?4)",
        .{"Alice", 42, true, null});

karlseguin (individual, on Stmt):
    try stmt.bind(.{"Alice", 42, true, null});
```

### Column Extraction

```
Ours (on Statement):
    stmt.columnText(0)          // ?[]const u8
    stmt.columnBlob(0)          // ?[]const u8
    stmt.columnInt(0)           // i64
    stmt.columnInt32(0)         // i32
    stmt.columnFloat(0)         // f64
    stmt.columnBool(0)          // bool
    stmt.columnOptionalInt(0)   // ?i64
    stmt.columnOptionalInt32(0) // ?i32
    stmt.columnOptionalFloat(0) // ?f64
    stmt.columnIsNull(0)        // bool
    stmt.columnCount()          // u32
    stmt.columnName(0)          // ?[]const u8
    stmt.columnType(0)          // ColumnType

Ours (on Row -- NEW in v0.3.0, short names):
    row.text(0)                 // ?[]const u8
    row.blob(0)                 // ?[]const u8
    row.int(0)                  // i64
    row.int32(0)                // i32
    row.float(0)                // f64
    row.boolean(0)              // bool
    row.optionalInt(0)          // ?i64
    row.optionalInt32(0)        // ?i32
    row.optionalFloat(0)        // ?f64
    row.isNull(0)               // bool
    row.columnCount()           // u32
    row.columnName(0)           // ?[]const u8
    row.columnType(0)           // ColumnType

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
Ours (raw Statement -- still available):
    var stmt = try db.prepare("SELECT ...");
    defer stmt.deinit();
    try stmt.bindInt(1, id);
    while (try stmt.step()) {
        const name = stmt.columnText(0);
    }

Ours (Rows iterator -- NEW in v0.3.0):
    var result = try db.rows("SELECT ...", .{id});
    defer result.deinit();
    while (result.next()) |row| {
        const name = row.text(0);
    }
    if (result.err) |err| return err;

Ours (single row -- NEW in v0.3.0):
    var result = try db.row("SELECT ...", .{id});
    defer result.deinit();
    if (result.next()) |row| {
        return row.text(0);
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
Optional (discuss first):
  [10] openZ() for null-terminated paths
  [11] SQLITE_STATIC variant methods (bindTextStatic, bindBlobStatic)
  [13] Generic column getter (row.get(T, idx))
```

10 of 13 features from the original analysis are now integrated. The 3 remaining are all optional enhancements that involve trade-offs worth discussing before implementation.

### Principles

- Our bundled-SQLite, batteries-included philosophy is a differentiator -- do not abandon it.
- Auto-PRAGMA configuration is a feature, not a limitation -- but consider making it opt-out.
- Adding features should be additive -- do not break existing API consumers.
- Prefer safety by default (SQLITE_TRANSIENT, closure transactions) with opt-in performance variants.

---

*Original analysis performed Feb 2026. karlseguin/zqlite.zig at latest master.*
*Updated Feb 2026 after v0.2.0 integration (commit 37c1f05). 6 of 13 features integrated.*
*Updated Feb 2026 after v0.3.0 integration (commit 42089dd). 10 of 13 features integrated.*
