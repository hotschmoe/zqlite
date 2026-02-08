<!-- BEGIN:header -->
# CLAUDE.md

we love you, Claude! do your best today
<!-- END:header -->

<!-- BEGIN:rule-1-no-delete -->
## RULE 1 - NO DELETIONS (ARCHIVE INSTEAD)

You may NOT delete any file or directory. Instead, move deprecated files to `.archive/`.

**When you identify files that should be removed:**
1. Create `.archive/` directory if it doesn't exist
2. Move the file: `mv path/to/file .archive/`
3. Notify me: "Moved `path/to/file` to `.archive/` - deprecated because [reason]"

**Rules:**
- This applies to ALL files, including ones you just created (tests, tmp files, scripts, etc.)
- You do not get to decide that something is "safe" to delete
- The `.archive/` directory is gitignored - I will review and permanently delete when ready
- If `.archive/` doesn't exist and you can't create it, ask me before proceeding

**Only I can run actual delete commands** (`rm`, `git clean`, etc.) after reviewing `.archive/`.
<!-- END:rule-1-no-delete -->

<!-- BEGIN:irreversible-actions -->
### IRREVERSIBLE GIT & FILESYSTEM ACTIONS

Absolutely forbidden unless I give the **exact command and explicit approval** in the same message:

- `git reset --hard`
- `git clean -fd`
- `rm -rf`
- Any command that can delete or overwrite code/data

Rules:

1. If you are not 100% sure what a command will delete, do not propose or run it. Ask first.
2. Prefer safe tools: `git status`, `git diff`, `git stash`, copying to backups, etc.
3. After approval, restate the command verbatim, list what it will affect, and wait for confirmation.
4. When a destructive command is run, record in your response:
   - The exact user text authorizing it
   - The command run
   - When you ran it

If that audit trail is missing, then you must act as if the operation never happened.
<!-- END:irreversible-actions -->

<!-- BEGIN:code-discipline -->
### Code Editing Discipline

- Do **not** run scripts that bulk-modify code (codemods, invented one-off scripts, giant `sed`/regex refactors).
- Large mechanical changes: break into smaller, explicit edits and review diffs.
- Subtle/complex changes: edit by hand, file-by-file, with careful reasoning.
- **NO EMOJIS** - do not use emojis or non-textual characters.
- ASCII diagrams are encouraged for visualizing flows.
- Keep in-line comments to a minimum. Use external documentation for complex logic.
- In-line commentary should be value-add, concise, and focused on info not easily gleaned from the code.
<!-- END:code-discipline -->

<!-- BEGIN:no-legacy -->
### No Legacy Code - Full Migrations Only

We optimize for clean architecture, not backwards compatibility. **When we refactor, we fully migrate.**

- No "compat shims", "v2" file clones, or deprecation wrappers
- When changing behavior, migrate ALL callers and remove old code **in the same commit**
- No `_legacy` suffixes, no `_old` prefixes, no "will remove later" comments
- New files are only for genuinely new domains that don't fit existing modules
- The bar for adding files is very high

**Rationale**: Legacy compatibility code creates technical debt that compounds. A clean break is always better than a gradual migration that never completes.
<!-- END:no-legacy -->

<!-- BEGIN:dev-philosophy -->
## Development Philosophy

**Make it work, make it right, make it fast** - in that order.

**This codebase will outlive you** - every shortcut becomes someone else's burden. Patterns you establish will be copied. Corners you cut will be cut again.

**Fight entropy** - leave the codebase better than you found it.

**Inspiration vs. Recreation** - take the opportunity to explore unconventional or new ways to accomplish tasks. Do not be afraid to challenge assumptions or propose new ideas. BUT we also do not want to reinvent the wheel for the sake of it. If there is a well-established pattern or library take inspiration from it and make it your own. (or suggest it for inclusion in the codebase)
<!-- END:dev-philosophy -->

<!-- BEGIN:testing-philosophy -->
## Testing Philosophy: Diagnostics, Not Verdicts

**Tests are diagnostic tools, not success criteria.** A passing test suite does not mean the code is good. A failing test does not mean the code is wrong.

**When a test fails, ask three questions in order:**
1. Is the test itself correct and valuable?
2. Does the test align with our current design vision?
3. Is the code actually broken?

Only if all three answers are "yes" should you fix the code.

**Why this matters:**
- Tests encode assumptions. Assumptions can be wrong or outdated.
- Changing code to pass a bad test makes the codebase worse, not better.
- Evolving projects explore new territory - legacy testing assumptions don't always apply.

**What tests ARE good for:**
- **Regression detection**: Did a refactor break dependent modules? Did API changes break integrations?
- **Sanity checks**: Does initialization complete? Do core operations succeed? Does the happy path work?
- **Behavior documentation**: Tests show what the code currently does, not necessarily what it should do.

**What tests are NOT:**
- A definition of correctness
- A measure of code quality
- Something to "make pass" at all costs
- A specification to code against

**The real success metric**: Does the code further our project's vision and goals?
<!-- END:testing-philosophy -->

<!-- BEGIN:footer -->
---

we love you, Claude! do your best today
<!-- END:footer -->


---

## Project-Specific Content

<!-- Add your project's toolchain, architecture, workflows here -->
<!-- This section will not be touched by haj.sh -->

# zqlite - Zig SQLite Wrapper

Safe, idiomatic Zig bindings to SQLite3. Bundles the SQLite amalgamation directly -- no external dependencies.

- **Minimum Zig**: 0.15.2
- **Dependencies**: None (SQLite amalgamation bundled in `vendor/`)
- **License**: MIT

---

## Philosophy

- **Thin wrapper, not an ORM** - Direct access to SQLite's power without abstraction overhead.
- **Type-safe bindings** - Dedicated methods for each data type, no generic "bind any" footguns.
- **Sensible defaults** - WAL mode, foreign keys enabled, busy timeout configured out of the box.
- **Self-contained** - The SQLite amalgamation ships with the package. Consumers need nothing else.

---

## Zig Toolchain

```bash
zig build                       # Build library + demo
zig build test                  # Run all tests
zig build run                   # Run the demo executable
zig fmt src/                    # Format before commits
```

---

## Architecture

```
+--------------------------------------------------+
|              YOUR APPLICATION                     |
|  Open database, prepare statements, bind, step   |
+--------------------------------------------------+
                      |
                      v
+--------------------------------------------------+
|                  zqlite                           |
|  Database    Connection management, PRAGMA setup  |
|  Statement   Prepare, bind, step, column extract  |
|  Transaction Automatic commit/rollback            |
|  Errors      Typed error set (SqliteError)        |
+--------------------------------------------------+
                      |
                      v
+--------------------------------------------------+
|              SQLite3 (bundled amalgamation)        |
|  sqlite3.c + sqlite3.h in vendor/                 |
+--------------------------------------------------+
```

---

## Source Layout

| File | Purpose |
|------|---------|
| `src/root.zig` | Main library: Database, Statement, transactions, errors |
| `src/main.zig` | Demo executable showing usage patterns |
| `vendor/sqlite3.c` | SQLite amalgamation source |
| `vendor/sqlite3.h` | SQLite header |
| `scripts/setup-vendor.sh` | Downloads SQLite amalgamation if not present |

---

## Core API

### Database

```zig
var db = try zqlite.Database.open(allocator, "mydb.sqlite");
defer db.close();

// Execute raw SQL
try db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");

// Get metadata
const row_id = db.lastInsertRowId();
const affected = db.changes();
```

**Auto-configured PRAGMAs on open:**
- `journal_mode = WAL` (concurrent reads)
- `foreign_keys = ON`
- `busy_timeout = 5000` (5 seconds)
- `synchronous = NORMAL`

### Prepared Statements

```zig
var stmt = try db.prepare("INSERT INTO users (name, age) VALUES (?1, ?2)");
defer stmt.deinit();

try stmt.bindText(1, "Alice");
try stmt.bindInt32(2, 30);
_ = try stmt.step();

stmt.reset();  // Reuse for next row
```

### Binding Methods

| Method | Zig Type | SQLite Type |
|--------|----------|-------------|
| `bindText(pos, val)` | `[]const u8` | TEXT |
| `bindInt(pos, val)` | `i64` | INTEGER (64-bit) |
| `bindInt32(pos, val)` | `i32` | INTEGER (32-bit) |
| `bindBool(pos, val)` | `bool` | INTEGER (0/1) |
| `bindNull(pos)` | - | NULL |
| `bindOptionalInt(pos, val)` | `?i64` | INTEGER or NULL |
| `bindOptionalInt32(pos, val)` | `?i32` | INTEGER or NULL |

### Column Extraction

| Method | Returns |
|--------|---------|
| `columnText(idx)` | `?[]const u8` |
| `columnInt(idx)` | `i64` |
| `columnInt32(idx)` | `i32` |
| `columnBool(idx)` | `bool` |
| `columnOptionalInt(idx)` | `?i64` |
| `columnOptionalInt32(idx)` | `?i32` |

### Transactions

```zig
// With context parameter
try db.transaction(MyContext, &ctx, struct {
    fn run(context: *MyContext) !void {
        // All operations here are atomic
        // Automatic rollback on error, commit on success
    }
}.run);

// Without context
try db.transactionSimple(struct {
    fn run() !void {
        // ...
    }
}.run);
```

### Error Types

```zig
const SqliteError = error{
    OpenFailed,
    PrepareFailed,
    BindFailed,
    StepFailed,
    ExecuteFailed,
    BusyTimeout,
    Corrupt,
};
```

---

## SQLite Build Flags

The bundled SQLite is compiled with these flags:

| Flag | Effect |
|------|--------|
| `SQLITE_DQS=0` | Disable double-quoted string literals |
| `SQLITE_THREADSAFE=2` | Multi-thread mode (serialized) |
| `SQLITE_ENABLE_FTS5` | Full-text search v5 |
| `SQLITE_ENABLE_JSON1` | JSON1 extension |
| Various `OMIT_*` flags | Strip unused features for smaller binary |

---

## Bug Severity

### Critical - Must Fix Immediately

- `.?` on null (panics)
- `unreachable` reached at runtime
- Index out of bounds
- Integer overflow in release builds (undefined behavior)
- Use-after-free or double-free
- Memory leaks in long-running paths
- SQLite resource leaks (unclosed statements or connections)
- Data corruption from missing transaction boundaries

### Important - Fix Before Merge

- Missing error handling (`try` without proper catch/return)
- `catch unreachable` without justification
- Ignoring return values from `!T` functions
- Unchecked SQLite error codes

### Contextual - Address When Convenient

- TODO/FIXME comments
- Unused imports or variables
- Suboptimal comptime usage
- Excessive debug output

---

## Version Updates (SemVer)

When making commits, update `version` in `build.zig.zon`:

- **MAJOR** (X.0.0): Breaking changes or incompatible API modifications
- **MINOR** (0.X.0): New features, backward-compatible additions
- **PATCH** (0.0.X): Bug fixes, small improvements, documentation

---

## Roadmap

- [x] Database open/close with WAL mode
- [x] Prepared statement API (bind, step, column)
- [x] Type-safe parameter binding (text, int, int32, bool, null, optionals)
- [x] Transaction support with automatic rollback
- [x] Bundled SQLite amalgamation
- [x] Cross-platform CI (Linux, macOS, Windows)
- [x] FTS5 and JSON1 extensions enabled
- [ ] Blob binding and extraction
- [ ] Named parameter binding (`:name`, `@name`, `$name`)
- [ ] Connection pooling for multi-threaded applications
- [ ] Migration helper utilities


<!-- br-agent-instructions-v1 -->

---

## Beads Workflow Integration

This project uses [beads_rust](https://github.com/Dicklesworthstone/beads_rust) (`br`/`bd`) for issue tracking. Issues are stored in `.beads/` and tracked in git.

### Essential Commands

```bash
# View ready issues (unblocked, not deferred)
br ready              # or: bd ready

# List and search
br list --status=open # All open issues
br show <id>          # Full issue details with dependencies
br search "keyword"   # Full-text search

# Create and update
br create --title="..." --description="..." --type=task --priority=2
br update <id> --status=in_progress
br close <id> --reason="Completed"
br close <id1> <id2>  # Close multiple issues at once

# Sync with git
br sync --flush-only  # Export DB to JSONL
br sync --status      # Check sync status
```

### Workflow Pattern

1. **Start**: Run `br ready` to find actionable work
2. **Claim**: Use `br update <id> --status=in_progress`
3. **Work**: Implement the task
4. **Complete**: Use `br close <id>`
5. **Sync**: Always run `br sync --flush-only` at session end

### Key Concepts

- **Dependencies**: Issues can block other issues. `br ready` shows only unblocked work.
- **Priority**: P0=critical, P1=high, P2=medium, P3=low, P4=backlog (use numbers 0-4, not words)
- **Types**: task, bug, feature, epic, chore, docs, question
- **Blocking**: `br dep add <issue> <depends-on>` to add dependencies

### Session Protocol

**Before ending any session, run this checklist:**

```bash
git status              # Check what changed
git add <files>         # Stage code changes
br sync --flush-only    # Export beads changes to JSONL
git commit -m "..."     # Commit everything
git push                # Push to remote
```

### Best Practices

- Check `br ready` at session start to find available work
- Update status as you work (in_progress -> closed)
- Create new issues with `br create` when you discover tasks
- Use descriptive titles and set appropriate priority/type
- Always sync before ending session

<!-- end-br-agent-instructions -->
