package migrations_test

import (
	"testing"
	"uuid"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"

	"github.com/anhnvcoder/svp-backend/internal/pgtest"
	"github.com/anhnvcoder/svp-backend/services/feed-service/migrations"
)

// tables reports whether follows, videos and timeline all exist, and whether any of them does.
func tables(t *testing.T, pool *pgxpool.Pool) (all, some bool) {
	t.Helper()
	var n int
	err := pool.QueryRow(t.Context(),
		"SELECT (to_regclass('public.follows') IS NOT NULL)::int + (to_regclass('public.videos') IS NOT NULL)::int"+
			" + (to_regclass('public.timeline') IS NOT NULL)::int",
	).Scan(&n)
	if err != nil {
		t.Fatal(err)
	}
	return n == 3, n > 0
}

// premiumColumn reports whether videos has the premium column of 00002.
func premiumColumn(t *testing.T, pool *pgxpool.Pool) bool {
	t.Helper()
	var n int
	err := pool.QueryRow(t.Context(), `SELECT count(*) FROM information_schema.columns
		WHERE table_schema = 'public' AND table_name = 'videos' AND column_name = 'premium'`).Scan(&n)
	if err != nil {
		t.Fatal(err)
	}
	return n == 1
}

func newProvider(t *testing.T, pool *pgxpool.Pool) *goose.Provider {
	t.Helper()
	db := stdlib.OpenDBFromPool(pool)
	t.Cleanup(func() { _ = db.Close() })
	// The version table internal/dbmigrate uses.
	provider, err := goose.NewProvider(goose.DialectPostgres, db, migrations.FS,
		goose.WithDisableGlobalRegistry(true),
		goose.WithTableName("goose.goose_db_version"),
		goose.WithLogger(goose.NopLogger()))
	if err != nil {
		t.Fatal(err)
	}
	return provider
}

// Every migration goes down and up again cleanly after pgtest applied them.
func TestMigrationsDownAndUp(t *testing.T) {
	pool := pgtest.New(t, "svp_feed_migrations_test", migrations.FS)
	if all, _ := tables(t, pool); !all || !premiumColumn(t, pool) {
		t.Fatal("after up: want follows, videos with premium, and timeline")
	}
	provider := newProvider(t, pool)

	if _, err := provider.Down(t.Context()); err != nil {
		t.Fatalf("down 00002: %v", err)
	}
	if all, _ := tables(t, pool); !all || premiumColumn(t, pool) {
		t.Fatal("after down 00002: want follows, videos without premium, and timeline")
	}
	if _, err := provider.DownTo(t.Context(), 0); err != nil {
		t.Fatalf("down to 0: %v", err)
	}
	if _, some := tables(t, pool); some {
		t.Fatal("after down to 0: want no table left")
	}
	if _, err := provider.Up(t.Context()); err != nil {
		t.Fatalf("up again: %v", err)
	}
	if all, _ := tables(t, pool); !all || !premiumColumn(t, pool) {
		t.Fatal("after up again: want follows, videos with premium, and timeline")
	}
}

// insertOld stores a video the way the release before 00002 does, without naming premium.
func insertOld(t *testing.T, pool *pgxpool.Pool, id uuid.UUID) error {
	t.Helper()
	_, err := pool.Exec(t.Context(), `INSERT INTO videos (video_id, author_id, title, duration_ms, playlist_key,
		thumbnail_key, published_at) VALUES ($1, $2, 'Old release', 1000, 'media/x', 'media/y', now())`, id, uuid.NewV7())
	return err
}

// Rows stored before 00002 read as regular videos, the release before keeps storing videos on the
// new schema, and it works again after Down.
func TestPremiumMigrationKeepsRowsAndReleaseBefore(t *testing.T) {
	pool := pgtest.New(t, "svp_feed_migrations_premium_test", migrations.FS)
	ctx := t.Context()
	provider := newProvider(t, pool)
	if _, err := provider.DownTo(ctx, 1); err != nil {
		t.Fatalf("down to 00001: %v", err)
	}
	before := uuid.NewV7()
	if err := insertOld(t, pool, before); err != nil {
		t.Fatalf("insert before 00002: %v", err)
	}
	if _, err := provider.Up(ctx); err != nil {
		t.Fatalf("up 00002: %v", err)
	}
	after := uuid.NewV7()
	if err := insertOld(t, pool, after); err != nil {
		t.Fatalf("old-style insert after 00002: %v", err)
	}
	for name, id := range map[string]uuid.UUID{"row before 00002": before, "old-style row after 00002": after} {
		var premium bool
		if err := pool.QueryRow(ctx, "SELECT premium FROM videos WHERE video_id = $1", id).Scan(&premium); err != nil {
			t.Fatal(err)
		}
		if premium {
			t.Errorf("%s: premium = true, want false", name)
		}
	}
	if _, err := provider.DownTo(ctx, 1); err != nil {
		t.Fatalf("down to 00001: %v", err)
	}
	if err := insertOld(t, pool, uuid.NewV7()); err != nil {
		t.Errorf("old-style insert after Down: %v", err)
	}
}
