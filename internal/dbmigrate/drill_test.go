package dbmigrate_test

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"maps"
	"math"
	"math/rand/v2"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"testing/fstest"
	"text/tabwriter"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"

	"github.com/anhnvcoder/svp-backend/internal/dbmigrate"
	"github.com/anhnvcoder/svp-backend/internal/pgtest"
)

// The rename drill renames items.title to name in the expand/contract steps, one release per step, while "pods"
// (goroutines running exactly one release's SQL) read and write the table. The migrations of the steps are in
// renameDir; the other two folders hold the wrong ways the drill compares with.
const (
	renameDir  = "testdata/rename"
	naiveDir   = "testdata/rename-naive"
	lockOffDir = "testdata/lock-timeout-off"
)

const (
	// drillRowsEnv names the variable holding how many rows items has before the first step.
	drillRowsEnv     = "SVP_DRILL_ROWS"
	defaultDrillRows = 20_000
	// podWorkers is how many goroutines of a pod read and write at once.
	podWorkers = 4
	// callTimeout bounds each operation of a pod as the gateway's call timeout bounds a request.
	callTimeout = 3 * time.Second
	// overlap is how long the pods of the release before and of the new one run together after the migration.
	overlap = 500 * time.Millisecond
	// drillLockHold is how long the lock test's transaction holds its lock: over callTimeout, so a migration
	// waiting for it without a bound makes the queries queued behind it time out.
	drillLockHold = 4 * time.Second
)

const (
	writeTitle = "INSERT INTO items (title) VALUES ($1)"
	writeBoth  = "INSERT INTO items (title, name) VALUES ($1, $1)"
	writeName  = "INSERT INTO items (name) VALUES ($1)"
	// The reads scan into a string, so a NULL where the release expects a value is an error too.
	readTitle = "SELECT title FROM items WHERE id >= $1 ORDER BY id LIMIT 1"
	readName  = "SELECT name FROM items WHERE id >= $1 ORDER BY id LIMIT 1"
)

// release is one release of the code: the last migration version it ships and the SQL its pods run.
type release struct {
	name  string
	last  int64
	write string // inserts one row, the text in $1
	read  string // reads one text column of the first row from id $1 on
}

// renameReleases are the steps of the rename, from the release before it to the end of the contract.
var renameReleases = []release{
	{name: "(0) before", last: 1, write: writeTitle, read: readTitle},
	{name: "(1) expand", last: 2, write: writeTitle, read: readTitle},
	{name: "(2) dual write", last: 2, write: writeBoth, read: readTitle},
	{name: "(3) backfill", last: 6, write: writeBoth, read: readTitle},
	{name: "(4) read name", last: 6, write: writeBoth, read: readName},
	{name: "(5a) contract: DROP NOT NULL", last: 7, write: writeName, read: readName},
	{name: "(5b) contract: DROP COLUMN", last: 8, write: writeName, read: readName},
}

// releaseFS returns the migrations of dir with a version up to last, at the root of the result as goose expects.
func releaseFS(t *testing.T, last int64, dir string) fstest.MapFS {
	t.Helper()
	fsys := os.DirFS(dir)
	names, err := fs.Glob(fsys, "*.sql")
	if err != nil {
		t.Fatal(err)
	}
	out := fstest.MapFS{}
	for _, name := range names {
		prefix, _, _ := strings.Cut(name, "_")
		version, err := strconv.ParseInt(prefix, 10, 64)
		if err != nil {
			t.Fatalf("migration %s/%s: no version prefix: %v", dir, name, err)
		}
		if version > last {
			continue
		}
		data, err := fs.ReadFile(fsys, name)
		if err != nil {
			t.Fatal(err)
		}
		out[name] = &fstest.MapFile{Data: data}
	}
	return out
}

// drillRows reads drillRowsEnv, defaultDrillRows when unset.
func drillRows(t *testing.T) int64 {
	t.Helper()
	v := os.Getenv(drillRowsEnv)
	if v == "" {
		return defaultDrillRows
	}
	n, err := strconv.ParseInt(v, 10, 64)
	if err != nil || n < 1 {
		t.Fatalf("%s=%q: want a positive number of rows", drillRowsEnv, v)
	}
	return n
}

// seed fills items with rows rows in one statement, so a million rows load as fast as Postgres writes them.
func seed(t *testing.T, pool *pgxpool.Pool, rows int64) {
	t.Helper()
	if _, err := pool.Exec(t.Context(),
		"INSERT INTO items (title) SELECT 'item ' || g FROM generate_series(1, $1::bigint) AS g", rows); err != nil {
		t.Fatalf("seed %d rows: %v", rows, err)
	}
}

// counts is what one release's pod did during one step.
type counts struct {
	ops, errs atomic.Int64
	mu        sync.Mutex
	first     error
}

func (c *counts) record(err error) {
	c.ops.Add(1)
	if err == nil {
		return
	}
	c.errs.Add(1)
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.first == nil {
		c.first = err
	}
}

func (c *counts) firstErr() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.first
}

// recorder keeps the latency of every pod operation that ends while a migration runs.
type recorder struct {
	active atomic.Bool
	mu     sync.Mutex
	lat    []time.Duration
}

func (r *recorder) start() {
	r.mu.Lock()
	r.lat = nil
	r.mu.Unlock()
	r.active.Store(true)
}

func (r *recorder) stop() []time.Duration {
	r.active.Store(false)
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.lat
}

func (r *recorder) add(d time.Duration) {
	if !r.active.Load() {
		return
	}
	r.mu.Lock()
	r.lat = append(r.lat, d)
	r.mu.Unlock()
}

// pod runs one release's SQL on items from podWorkers goroutines, each writing and reading in turn, until stopped.
type pod struct {
	rel     release
	pool    *pgxpool.Pool
	rows    int64 // reads pick a start id among the seeded rows
	rec     *recorder
	cur     atomic.Pointer[counts]
	done    chan struct{}
	wg      sync.WaitGroup
	stopped sync.Once
}

func startPod(t *testing.T, dbURL string, rel release, rows int64, rec *recorder) *pod {
	t.Helper()
	cfg, err := pgxpool.ParseConfig(dbURL)
	if err != nil {
		t.Fatal(err)
	}
	cfg.MaxConns = podWorkers
	pool, err := pgxpool.NewWithConfig(t.Context(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	p := &pod{rel: rel, pool: pool, rows: rows, rec: rec, done: make(chan struct{})}
	p.cur.Store(&counts{})
	for range podWorkers {
		p.wg.Go(p.work)
	}
	t.Cleanup(func() { p.stop() })
	return p
}

func (p *pod) work() {
	for i := 0; ; i++ {
		select {
		case <-p.done:
			return
		default:
		}
		if i%2 == 0 {
			p.do(func(ctx context.Context) error {
				_, err := p.pool.Exec(ctx, p.rel.write, "item from "+p.rel.name)
				return err
			})
			continue
		}
		p.do(func(ctx context.Context) error {
			id := rand.Int64N(p.rows) + 1 //nolint:gosec // picks a row to read, not a secret
			var s string
			return p.pool.QueryRow(ctx, p.rel.read, id).Scan(&s)
		})
	}
}

// do runs one operation with its own deadline, not the pod's stop signal, so stopping a pod fails no operation.
func (p *pod) do(op func(ctx context.Context) error) {
	ctx, cancel := context.WithTimeout(context.Background(), callTimeout)
	defer cancel()
	start := time.Now()
	err := op(ctx)
	p.rec.add(time.Since(start))
	p.cur.Load().record(err)
}

// next starts a new count for the pod and returns it.
func (p *pod) next() *counts {
	c := &counts{}
	p.cur.Store(c)
	return c
}

// stop waits for the operations in flight, then closes the pod's pool.
func (p *pod) stop() {
	p.stopped.Do(func() {
		close(p.done)
		p.wg.Wait()
		p.pool.Close()
	})
}

// step is one row of the drill's table.
type step struct {
	name      string
	migration time.Duration
	before    *counts // the release before, from the start of the migration to the end of the step
	after     *counts // the new release, nil when the step starts none
	lat       []time.Duration
}

// runReleases starts a pod of rels[0], then for each later release migrates to it while the pod of the release
// before runs, starts its pod, lets both run for overlap and stops the one before.
func runReleases(t *testing.T, dbURL string, rows int64, rels []release, fsFor func(release) fs.FS) []step {
	t.Helper()
	rec := &recorder{}
	prev := startPod(t, dbURL, rels[0], rows, rec)
	var steps []step
	for _, rel := range rels[1:] {
		s := step{name: rel.name, before: prev.next()}
		rec.start()
		start := time.Now()
		err := dbmigrate.Up(t.Context(), dbURL, fsFor(rel))
		s.migration = time.Since(start)
		s.lat = rec.stop()
		if err != nil {
			t.Fatalf("step %s: migrate: %v", rel.name, err)
		}
		cur := startPod(t, dbURL, rel, rows, rec)
		s.after = cur.cur.Load()
		time.Sleep(overlap)
		prev.stop()
		steps = append(steps, s)
		prev = cur
	}
	prev.stop()
	return steps
}

// checkNoErrors fails the test for every release of every step that had an operation fail, or ran none.
func checkNoErrors(t *testing.T, steps []step, rels []release) {
	t.Helper()
	for i, s := range steps {
		for j, c := range []*counts{s.before, s.after} {
			name := rels[i+j].name
			if c.ops.Load() == 0 {
				t.Errorf("step %s: release %s ran no operation", s.name, name)
			}
			if n := c.errs.Load(); n > 0 {
				t.Errorf("step %s: release %s: %d of %d operations failed, first: %v", s.name, name, n, c.ops.Load(), c.firstErr())
			}
		}
	}
}

// logTable logs the drill's measures, one row per step, with the server's version and the seeded rows.
func logTable(t *testing.T, pool *pgxpool.Pool, rows int64, steps []step) {
	t.Helper()
	var version string
	if err := pool.QueryRow(t.Context(), "SHOW server_version").Scan(&version); err != nil {
		t.Fatal(err)
	}
	var b strings.Builder
	fmt.Fprintf(&b, "PostgreSQL %s, %d rows\n", version, rows)
	w := tabwriter.NewWriter(&b, 0, 0, 2, ' ', 0)
	_, _ = fmt.Fprintln(w, "step\tmigration\toperations\terrors (release before / new)\tp99 during migration\tmax during migration")
	for _, s := range steps {
		ops, errsAfter := s.before.ops.Load(), "-"
		if s.after != nil {
			ops += s.after.ops.Load()
			errsAfter = strconv.FormatInt(s.after.errs.Load(), 10)
		}
		p99, maxLat := percentile(s.lat, 0.99), percentile(s.lat, 1)
		_, _ = fmt.Fprintf(w, "%s\t%s\t%d\t%d / %s\t%s\t%s\n", s.name, s.migration.Round(time.Millisecond), ops,
			s.before.errs.Load(), errsAfter, p99.Round(time.Microsecond), maxLat.Round(time.Microsecond))
	}
	if err := w.Flush(); err != nil {
		t.Fatal(err)
	}
	t.Log("\n" + b.String())
}

// percentile returns the q quantile of lat (nearest rank), 0 when lat is empty.
func percentile(lat []time.Duration, q float64) time.Duration {
	if len(lat) == 0 {
		return 0
	}
	s := slices.Sorted(slices.Values(lat))
	i := int(math.Ceil(q*float64(len(s)))) - 1
	return s[max(0, i)]
}

func TestRenameDrill(t *testing.T) {
	rows := drillRows(t)
	pool := pgtest.New(t, "svp_migration_drill_test", releaseFS(t, renameReleases[0].last, renameDir))
	dbURL := pool.Config().ConnString()
	seed(t, pool, rows)

	steps := runReleases(t, dbURL, rows, renameReleases, func(r release) fs.FS { return releaseFS(t, r.last, renameDir) })
	logTable(t, pool, rows, steps)
	checkNoErrors(t, steps, renameReleases)

	// The Down sections are part of the example: going back to the release before the rename works too.
	db := stdlib.OpenDBFromPool(pool)
	t.Cleanup(func() { _ = db.Close() })
	last := renameReleases[len(renameReleases)-1].last
	provider, err := goose.NewProvider(goose.DialectPostgres, db, releaseFS(t, last, renameDir),
		goose.WithDisableGlobalRegistry(true), goose.WithTableName("goose.goose_db_version"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := provider.DownTo(t.Context(), renameReleases[0].last); err != nil {
		t.Fatalf("migrate down to the release before the rename: %v", err)
	}
	var title string
	if err := pool.QueryRow(t.Context(), writeTitle+" RETURNING title", "after down").Scan(&title); err != nil {
		t.Fatalf("release %s after down: %v", renameReleases[0].name, err)
	}
	var untitled int
	if err := pool.QueryRow(t.Context(), "SELECT count(*) FROM items WHERE title IS NULL").Scan(&untitled); err != nil {
		t.Fatal(err)
	}
	if untitled > 0 {
		t.Errorf("after down %d rows have no title, want every row to get it back from name", untitled)
	}
}

// TestBackfillKeyset runs the backfill of step (3) on its own: on an empty table, and on ids with gaps wider than a
// batch where some rows already have a name, as after a run that failed part way.
func TestBackfillKeyset(t *testing.T) {
	t.Parallel()
	expand, backfill := renameReleases[1].last, int64(3)

	t.Run("empty table", func(t *testing.T) {
		t.Parallel()
		pool := pgtest.New(t, "svp_migration_backfill_empty_test", releaseFS(t, expand, renameDir))
		if err := dbmigrate.Up(t.Context(), pool.Config().ConnString(), releaseFS(t, backfill, renameDir)); err != nil {
			t.Fatalf("backfill an empty table: %v", err)
		}
	})

	t.Run("gaps and a rerun", func(t *testing.T) {
		t.Parallel()
		pool := pgtest.New(t, "svp_migration_backfill_gaps_test", releaseFS(t, expand, renameDir))
		seed(t, pool, 50_000)
		for _, stmt := range []string{
			"DELETE FROM items WHERE id BETWEEN 5001 AND 22000 OR id % 13 = 0",
			"UPDATE items SET name = 'kept' WHERE id % 7 = 0",
		} {
			if _, err := pool.Exec(t.Context(), stmt); err != nil {
				t.Fatal(err)
			}
		}
		if err := dbmigrate.Up(t.Context(), pool.Config().ConnString(), releaseFS(t, backfill, renameDir)); err != nil {
			t.Fatalf("backfill: %v", err)
		}
		var missing, kept, copied, wrong int
		err := pool.QueryRow(t.Context(), `SELECT count(*) FILTER (WHERE name IS NULL),
			count(*) FILTER (WHERE name = 'kept'), count(*) FILTER (WHERE name = title),
			count(*) FILTER (WHERE name <> title AND name <> 'kept') FROM items`).Scan(&missing, &kept, &copied, &wrong)
		if err != nil {
			t.Fatal(err)
		}
		var want struct{ kept, copied int }
		err = pool.QueryRow(t.Context(), `SELECT count(*) FILTER (WHERE id % 7 = 0), count(*) FILTER (WHERE id % 7 <> 0)
			FROM items`).Scan(&want.kept, &want.copied)
		if err != nil {
			t.Fatal(err)
		}
		if missing != 0 || wrong != 0 || kept != want.kept || copied != want.copied {
			t.Errorf("after backfill: %d rows without name, %d wrong, %d kept (want %d), %d copied (want %d)",
				missing, wrong, kept, want.kept, copied, want.copied)
		}
	})
}

func TestRenameDrillNaive(t *testing.T) {
	rows := drillRows(t)
	before := renameReleases[0]
	pool := pgtest.New(t, "svp_migration_drill_naive_test", releaseFS(t, before.last, renameDir))
	dbURL := pool.Config().ConnString()
	seed(t, pool, rows)

	rels := []release{before, {name: "RENAME COLUMN in one release", last: 2, write: writeName, read: readName}}
	steps := runReleases(t, dbURL, rows, rels, func(r release) fs.FS {
		fsys := releaseFS(t, before.last, renameDir)
		maps.Copy(fsys, releaseFS(t, r.last, naiveDir))
		return fsys
	})
	logTable(t, pool, rows, steps)
	if n := steps[0].before.errs.Load(); n == 0 {
		t.Errorf("release %s had no error after the rename, want its reads and writes of title to fail", before.name)
	} else {
		t.Logf("release %s: %d of %d operations failed, first: %v", before.name, n, steps[0].before.ops.Load(),
			steps[0].before.firstErr())
	}
}

// holdAccessShare locks items in ACCESS SHARE mode in a transaction of its own for drillLockHold, as a long
// report query would. It returns once the lock is held, with a function that waits for the commit.
func holdAccessShare(t *testing.T, pool *pgxpool.Pool) func() {
	t.Helper()
	tx, err := pool.Begin(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(t.Context(), "LOCK TABLE items IN ACCESS SHARE MODE"); err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		time.Sleep(drillLockHold)
		if err := tx.Commit(context.Background()); err != nil {
			t.Errorf("commit the locking transaction: %v", err)
		}
	}()
	wait := func() { <-done }
	// A test that fails early still ends the transaction before its database is dropped.
	t.Cleanup(wait)
	return wait
}

func TestRenameDrillLockTimeout(t *testing.T) {
	rows := drillRows(t)
	before, expand := renameReleases[0], renameReleases[1]

	t.Run("lock_timeout of the runner", func(t *testing.T) {
		pool := pgtest.New(t, "svp_migration_drill_lock_test", releaseFS(t, before.last, renameDir))
		dbURL := pool.Config().ConnString()
		seed(t, pool, rows)
		rec := &recorder{}
		p := startPod(t, dbURL, before, rows, rec)

		held := step{name: "expand while a transaction holds ACCESS SHARE", before: p.next()}
		committed := holdAccessShare(t, pool)
		rec.start()
		start := time.Now()
		err := dbmigrate.Up(t.Context(), dbURL, releaseFS(t, expand.last, renameDir))
		held.migration = time.Since(start)
		held.lat = rec.stop()
		if pgErr, ok := errors.AsType[*pgconn.PgError](err); !ok || pgErr.Code != "55P03" {
			t.Errorf("migrate while the lock is held: %v, want 55P03 lock_not_available", err)
		}
		// The wait starts after the connection and the version table checks, so it fails no sooner than the bound.
		if held.migration < 2*time.Second || held.migration > 3*time.Second {
			t.Errorf("migrate failed after %s, want 2s to 3s: the runner's 2s lock_timeout and slack for -race", held.migration)
		}

		rerun := step{name: "expand again after the commit", before: p.next()}
		committed()
		rec.start()
		start = time.Now()
		err = dbmigrate.Up(t.Context(), dbURL, releaseFS(t, expand.last, renameDir))
		rerun.migration = time.Since(start)
		rerun.lat = rec.stop()
		if err != nil {
			t.Errorf("migrate again after the commit: %v", err)
		}
		time.Sleep(overlap)
		p.stop()

		steps := []step{held, rerun}
		logTable(t, pool, rows, steps)
		for _, s := range steps {
			if n := s.before.errs.Load(); n > 0 {
				t.Errorf("step %s: release %s: %d of %d operations failed, first: %v", s.name, before.name, n,
					s.before.ops.Load(), s.before.firstErr())
			}
		}
	})

	// The control: the same migration with no bound on its lock wait queues the app's queries past callTimeout.
	t.Run("lock_timeout 0 in the file", func(t *testing.T) {
		pool := pgtest.New(t, "svp_migration_drill_lock_test", releaseFS(t, before.last, renameDir))
		dbURL := pool.Config().ConnString()
		seed(t, pool, rows)
		rec := &recorder{}
		p := startPod(t, dbURL, before, rows, rec)

		s := step{name: "expand with lock_timeout 0 while a transaction holds ACCESS SHARE", before: p.next()}
		holdAccessShare(t, pool)
		fsys := releaseFS(t, before.last, renameDir)
		maps.Copy(fsys, releaseFS(t, expand.last, lockOffDir))
		rec.start()
		start := time.Now()
		err := dbmigrate.Up(t.Context(), dbURL, fsys)
		s.migration = time.Since(start)
		s.lat = rec.stop()
		if err != nil {
			t.Errorf("migrate with lock_timeout 0: %v, want it to wait for the lock and succeed", err)
		}
		p.stop()

		logTable(t, pool, rows, []step{s})
		if first := s.before.firstErr(); !errors.Is(first, context.DeadlineExceeded) {
			t.Errorf("release %s: first error %v (%d of %d failed), want operations past the %s deadline",
				before.name, first, s.before.errs.Load(), s.before.ops.Load(), callTimeout)
		}
	})
}

// TestDrillFilesInLintGlob checks that every migration the drill applies is one the lint and TestMigrationFiles
// read: both glob testdata/*/*.sql, which misses a file in a nested folder.
func TestDrillFilesInLintGlob(t *testing.T) {
	t.Parallel()
	globbed, err := filepath.Glob("testdata/*/*.sql")
	if err != nil {
		t.Fatal(err)
	}
	for _, dir := range []string{renameDir, naiveDir, lockOffDir} {
		applied, err := filepath.Glob(filepath.Join(dir, "*.sql"))
		if err != nil {
			t.Fatal(err)
		}
		if len(applied) == 0 {
			t.Errorf("%s holds no migration", dir)
		}
		for _, f := range applied {
			if !slices.Contains(globbed, f) {
				t.Errorf("%s is not matched by testdata/*/*.sql", f)
			}
		}
	}
	err = filepath.WalkDir("testdata", func(path string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() && filepath.Ext(path) == ".sql" && !slices.Contains(globbed, path) {
			t.Errorf("%s is not matched by testdata/*/*.sql", path)
		}
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
}
