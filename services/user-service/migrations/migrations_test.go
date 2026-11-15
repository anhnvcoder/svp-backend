package migrations_test

import (
	"io/fs"
	"strings"
	"testing"
	"testing/fstest"
	"uuid"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"

	"github.com/anhnvcoder/svp-backend/internal/dbmigrate"
	"github.com/anhnvcoder/svp-backend/internal/pgtest"
	"github.com/anhnvcoder/svp-backend/services/user-service/migrations"
)

// upTo returns the migrations up to and including version, named as goose expects.
func upTo(t *testing.T, version string) fs.FS {
	t.Helper()
	files, err := fs.Glob(migrations.FS, "*.sql")
	if err != nil {
		t.Fatal(err)
	}
	out := fstest.MapFS{}
	for _, f := range files {
		if f[:len(version)] > version {
			continue
		}
		data, err := fs.ReadFile(migrations.FS, f)
		if err != nil {
			t.Fatal(err)
		}
		out[f] = &fstest.MapFile{Data: data}
	}
	return out
}

// insertOld inserts a user the way the release before the profile migration does, naming
// neither handle nor display_name.
func insertOld(t *testing.T, pool *pgxpool.Pool, id uuid.UUID) error {
	t.Helper()
	_, err := pool.Exec(t.Context(), "INSERT INTO users (id, email, password_hash) VALUES ($1, $2, 'hash')",
		id, "user-"+id.String()+"@example.io")
	return err
}

func profile(t *testing.T, pool *pgxpool.Pool, id uuid.UUID) (handle, displayName string) {
	t.Helper()
	if err := pool.QueryRow(t.Context(), "SELECT handle, display_name FROM users WHERE id = $1", id).
		Scan(&handle, &displayName); err != nil {
		t.Fatal(err)
	}
	return handle, displayName
}

func generated(id uuid.UUID) string {
	s := id.String()
	return "u_" + s[len(s)-12:]
}

func TestProfileMigrationBackfillsExistingUsers(t *testing.T) {
	pool := pgtest.New(t, "svp_user_migrations_test", upTo(t, "00004"))
	ctx := t.Context()
	existing := []uuid.UUID{uuid.NewV7(), uuid.NewV7(), uuid.NewV7()}
	for _, id := range existing {
		if err := insertOld(t, pool, id); err != nil {
			t.Fatal(err)
		}
	}

	if err := dbmigrate.Up(ctx, pool.Config().ConnString(), migrations.FS); err != nil {
		t.Fatalf("migrate to the latest version: %v", err)
	}
	seen := map[string]bool{}
	for _, id := range existing {
		handle, name := profile(t, pool, id)
		if handle != generated(id) || name != handle {
			t.Errorf("user %s: handle %q, display name %q; want both %q", id, handle, name, generated(id))
		}
		if seen[handle] {
			t.Errorf("handle %q repeats", handle)
		}
		seen[handle] = true
	}

	// The previous release, still serving during a rollout, inserts without the new columns.
	old := uuid.NewV7()
	if err := insertOld(t, pool, old); err != nil {
		t.Fatalf("old-style insert after the migration: %v", err)
	}
	if handle, name := profile(t, pool, old); handle != generated(old) || name != handle {
		t.Errorf("old-style insert got handle %q, display name %q; want both %q", handle, name, generated(old))
	}
	// Values the current release sends are kept as given.
	picked := uuid.NewV7()
	if _, err := pool.Exec(ctx,
		"INSERT INTO users (id, email, password_hash, handle, display_name) VALUES ($1, 'picked@example.io', 'hash', 'picked', 'Picked Name')",
		picked); err != nil {
		t.Fatal(err)
	}
	if handle, name := profile(t, pool, picked); handle != "picked" || name != "Picked Name" {
		t.Errorf("explicit insert got handle %q, display name %q", handle, name)
	}

	// Down removes both columns and the trigger, and the release before works again.
	db := stdlib.OpenDBFromPool(pool)
	t.Cleanup(func() { _ = db.Close() })
	provider, err := goose.NewProvider(goose.DialectPostgres, db, migrations.FS,
		goose.WithDisableGlobalRegistry(true), goose.WithTableName("goose.goose_db_version"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := provider.DownTo(ctx, 4); err != nil {
		t.Fatalf("migrate down to version 4: %v", err)
	}
	var columns int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM information_schema.columns
		WHERE table_name = 'users' AND column_name IN ('handle', 'display_name')`).Scan(&columns); err != nil {
		t.Fatal(err)
	}
	if columns != 0 {
		t.Errorf("%d profile columns left after Down", columns)
	}
	if err := insertOld(t, pool, uuid.NewV7()); err != nil {
		t.Errorf("insert after Down: %v", err)
	}
	if _, err := provider.Up(ctx); err != nil {
		t.Fatalf("migrate up again after Down: %v", err)
	}
}

// Two existing users whose ids end in the same 12 hex digits get the same handle: the migration
// fails as a whole and leaves the table as it was.
func TestProfileMigrationFailsWholeOnDuplicateHandle(t *testing.T) {
	pool := pgtest.New(t, "svp_user_migrations_dup_test", upTo(t, "00004"))
	first := uuid.NewV7()
	s := uuid.NewV7().String()
	second := uuid.MustParse(s[:len(s)-12] + first.String()[24:])
	for _, id := range []uuid.UUID{first, second} {
		if err := insertOld(t, pool, id); err != nil {
			t.Fatal(err)
		}
	}

	err := dbmigrate.Up(t.Context(), pool.Config().ConnString(), migrations.FS)
	if err == nil || !strings.Contains(err.Error(), "users_handle_key") {
		t.Fatalf("migrate = %v, want a users_handle_key violation", err)
	}
	var columns int
	if err := pool.QueryRow(t.Context(), `SELECT count(*) FROM information_schema.columns
		WHERE table_name = 'users' AND column_name IN ('handle', 'display_name')`).Scan(&columns); err != nil {
		t.Fatal(err)
	}
	if columns != 0 {
		t.Errorf("%d profile columns exist after the failed migration, want none", columns)
	}
}

// oldRelay runs what the outbox code of the release before the failed columns does: insert an
// event the way outbox.Write did, read the unsent rows the way the relay did, and mark them sent.
// It returns the ids it read.
func oldRelay(t *testing.T, pool *pgxpool.Pool) []int64 {
	t.Helper()
	ctx := t.Context()
	if _, err := pool.Exec(ctx, `INSERT INTO outbox (event_id, topic, record_key, payload, headers)
		VALUES (gen_random_uuid(), 'user.follows.v1', 'k', '\x00', '{}')`); err != nil {
		t.Fatalf("old insert: %v", err)
	}
	rows, err := pool.Query(ctx, "SELECT id FROM outbox WHERE published_at IS NULL ORDER BY id LIMIT 100")
	if err != nil {
		t.Fatalf("old read: %v", err)
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[int64])
	if err != nil {
		t.Fatalf("old read: %v", err)
	}
	if _, err := pool.Exec(ctx, "UPDATE outbox SET published_at = now() WHERE id = ANY($1)", ids); err != nil {
		t.Fatalf("old mark sent: %v", err)
	}
	return ids
}

// outboxFailed returns how many of the columns of the failed-rows migration exist and whether
// its index does.
func outboxFailed(t *testing.T, pool *pgxpool.Pool) (columns int, index bool) {
	t.Helper()
	err := pool.QueryRow(t.Context(),
		`SELECT (SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public'
		           AND table_name = 'outbox' AND column_name IN ('failed_at', 'last_error')),
		        to_regclass('public.outbox_pending_idx') IS NOT NULL`,
	).Scan(&columns, &index)
	if err != nil {
		t.Fatal(err)
	}
	return columns, index
}

// The release before keeps writing and relaying events on the table the failed-rows migration
// changed, and the rows it writes are unfailed, so the current relay reads them too.
func TestOutboxFailedMigrationKeepsReleaseBefore(t *testing.T) {
	pool := pgtest.New(t, "svp_user_outbox_failed_test", upTo(t, "00005"))
	ctx := t.Context()
	if got := oldRelay(t, pool); len(got) != 1 {
		t.Fatalf("old relay before the migration read %v, want one row", got)
	}

	if err := dbmigrate.Up(ctx, pool.Config().ConnString(), migrations.FS); err != nil {
		t.Fatalf("migrate to the latest version: %v", err)
	}
	if columns, index := outboxFailed(t, pool); columns != 2 || !index {
		t.Fatalf("after up: %d failed columns, index %v; want 2 and the index", columns, index)
	}
	if got := oldRelay(t, pool); len(got) != 1 {
		t.Errorf("old relay after the migration read %v, want only its new row", got)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO outbox (event_id, topic, record_key, payload)
		VALUES (gen_random_uuid(), 'user.follows.v1', 'k', '\x00')`); err != nil {
		t.Fatal(err)
	}
	var pending int
	if err := pool.QueryRow(ctx,
		"SELECT count(*) FROM outbox WHERE published_at IS NULL AND failed_at IS NULL").Scan(&pending); err != nil {
		t.Fatal(err)
	}
	if pending != 1 {
		t.Errorf("current relay sees %d pending rows, want the one the release before wrote", pending)
	}

	// Down removes both columns and the index, and the release before works again.
	db := stdlib.OpenDBFromPool(pool)
	t.Cleanup(func() { _ = db.Close() })
	provider, err := goose.NewProvider(goose.DialectPostgres, db, migrations.FS,
		goose.WithDisableGlobalRegistry(true), goose.WithTableName("goose.goose_db_version"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := provider.DownTo(ctx, 5); err != nil {
		t.Fatalf("migrate down to version 5: %v", err)
	}
	if columns, index := outboxFailed(t, pool); columns != 0 || index {
		t.Errorf("after Down: %d failed columns, index %v; want neither", columns, index)
	}
	if got := oldRelay(t, pool); len(got) != 2 {
		t.Errorf("old relay after Down read %v, want the two unsent rows", got)
	}
	if _, err := provider.Up(ctx); err != nil {
		t.Fatalf("migrate up again after Down: %v", err)
	}
}
