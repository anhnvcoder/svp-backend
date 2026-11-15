package migrations_test

import (
	"testing"
	"uuid"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"

	"github.com/anhnvcoder/svp-backend/internal/pgtest"
	"github.com/anhnvcoder/svp-backend/services/video-service/migrations"
)

// tables returns which of videos and outbox exist.
func tables(t *testing.T, pool *pgxpool.Pool) (videos, outbox bool) {
	t.Helper()
	err := pool.QueryRow(t.Context(),
		"SELECT to_regclass('public.videos') IS NOT NULL, to_regclass('public.outbox') IS NOT NULL",
	).Scan(&videos, &outbox)
	if err != nil {
		t.Fatal(err)
	}
	return videos, outbox
}

// uploadingIndexes returns how many of the partial indexes of 00003 exist.
func uploadingIndexes(t *testing.T, pool *pgxpool.Pool) int {
	t.Helper()
	var n int
	err := pool.QueryRow(t.Context(),
		`SELECT count(*) FROM pg_indexes WHERE schemaname = 'public' AND tablename = 'videos'
		   AND indexname IN ('videos_uploading_author_idx', 'videos_uploading_created_idx')`,
	).Scan(&n)
	if err != nil {
		t.Fatal(err)
	}
	return n
}

// hasProcessingAt reports whether videos has the processing_at column of 00004.
func hasProcessingAt(t *testing.T, pool *pgxpool.Pool) bool {
	t.Helper()
	var ok bool
	err := pool.QueryRow(t.Context(),
		`SELECT EXISTS (SELECT 1 FROM information_schema.columns
		   WHERE table_schema = 'public' AND table_name = 'videos' AND column_name = 'processing_at')`,
	).Scan(&ok)
	if err != nil {
		t.Fatal(err)
	}
	return ok
}

// hasAuthorIndex reports whether the index of 00005 exists.
func hasAuthorIndex(t *testing.T, pool *pgxpool.Pool) bool {
	t.Helper()
	var ok bool
	err := pool.QueryRow(t.Context(), "SELECT to_regclass('public.videos_author_created_idx') IS NOT NULL").Scan(&ok)
	if err != nil {
		t.Fatal(err)
	}
	return ok
}

// requestID returns whether videos has the request_id column and the unique index of 00006.
func requestID(t *testing.T, pool *pgxpool.Pool) (column, index bool) {
	t.Helper()
	err := pool.QueryRow(t.Context(),
		`SELECT EXISTS (SELECT 1 FROM information_schema.columns
		   WHERE table_schema = 'public' AND table_name = 'videos' AND column_name = 'request_id'),
		 to_regclass('public.videos_author_request_idx') IS NOT NULL`,
	).Scan(&column, &index)
	if err != nil {
		t.Fatal(err)
	}
	return column, index
}

// premium returns whether videos has the two columns of 00007 and whether video_entitlements
// exists.
func premium(t *testing.T, pool *pgxpool.Pool) (columns int, entitlements bool) {
	t.Helper()
	err := pool.QueryRow(t.Context(),
		`SELECT (SELECT count(*) FROM information_schema.columns
		   WHERE table_schema = 'public' AND table_name = 'videos' AND column_name IN ('premium', 'preview_playlist_key')),
		 to_regclass('public.video_entitlements') IS NOT NULL`,
	).Scan(&columns, &entitlements)
	if err != nil {
		t.Fatal(err)
	}
	return columns, entitlements
}

// Every migration goes down and up again cleanly after pgtest applied them.
func TestMigrationsDownAndUp(t *testing.T) {
	pool := pgtest.New(t, "svp_video_migrations_test", migrations.FS)
	if videos, outbox := tables(t, pool); !videos || !outbox {
		t.Fatalf("after up: videos %v, outbox %v, want both", videos, outbox)
	}
	if n := uploadingIndexes(t, pool); n != 2 {
		t.Fatalf("after up: %d UPLOADING indexes, want 2", n)
	}
	if !hasProcessingAt(t, pool) {
		t.Fatal("after up: videos has no processing_at")
	}
	if !hasAuthorIndex(t, pool) {
		t.Fatal("after up: no videos_author_created_idx")
	}
	if column, index := requestID(t, pool); !column || !index {
		t.Fatalf("after up: request_id column %v, index %v, want both", column, index)
	}
	if columns, entitlements := premium(t, pool); columns != 2 || !entitlements {
		t.Fatalf("after up: %d premium columns, video_entitlements %v, want 2 and true", columns, entitlements)
	}

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

	if _, err := provider.Down(t.Context()); err != nil {
		t.Fatalf("down 00007: %v", err)
	}
	if columns, entitlements := premium(t, pool); columns != 0 || entitlements {
		t.Fatalf("after down 00007: %d premium columns, video_entitlements %v, want neither", columns, entitlements)
	}
	if column, index := requestID(t, pool); !column || !index {
		t.Fatalf("after down 00007: request_id column %v, index %v, want both", column, index)
	}
	if _, err := provider.Down(t.Context()); err != nil {
		t.Fatalf("down 00006: %v", err)
	}
	if column, index := requestID(t, pool); column || index {
		t.Fatalf("after down 00006: request_id column %v, index %v, want neither", column, index)
	}
	if !hasAuthorIndex(t, pool) {
		t.Fatal("after down 00006: no videos_author_created_idx")
	}
	if _, err := provider.Down(t.Context()); err != nil {
		t.Fatalf("down 00005: %v", err)
	}
	if hasAuthorIndex(t, pool) {
		t.Fatal("after down 00005: videos_author_created_idx still exists")
	}
	if !hasProcessingAt(t, pool) {
		t.Fatal("after down 00005: videos has no processing_at")
	}
	if _, err := provider.Down(t.Context()); err != nil {
		t.Fatalf("down 00004: %v", err)
	}
	if hasProcessingAt(t, pool) {
		t.Fatal("after down 00004: videos still has processing_at")
	}
	if n := uploadingIndexes(t, pool); n != 2 {
		t.Fatalf("after down 00004: %d UPLOADING indexes, want 2", n)
	}
	if _, err := provider.Down(t.Context()); err != nil {
		t.Fatalf("down 00003: %v", err)
	}
	if videos, outbox := tables(t, pool); !videos || !outbox {
		t.Fatalf("after down 00003: videos %v, outbox %v, want both", videos, outbox)
	}
	if n := uploadingIndexes(t, pool); n != 0 {
		t.Fatalf("after down 00003: %d UPLOADING indexes, want 0", n)
	}
	if _, err := provider.Down(t.Context()); err != nil {
		t.Fatalf("down 00002: %v", err)
	}
	if videos, outbox := tables(t, pool); !videos || outbox {
		t.Fatalf("after down 00002: videos %v, outbox %v, want only videos", videos, outbox)
	}
	if _, err := provider.DownTo(t.Context(), 0); err != nil {
		t.Fatalf("down to 0: %v", err)
	}
	if videos, outbox := tables(t, pool); videos || outbox {
		t.Fatalf("after down to 0: videos %v, outbox %v, want neither", videos, outbox)
	}
	if _, err := provider.Up(t.Context()); err != nil {
		t.Fatalf("up again: %v", err)
	}
	if videos, outbox := tables(t, pool); !videos || !outbox {
		t.Fatalf("after up again: videos %v, outbox %v, want both", videos, outbox)
	}
	if n := uploadingIndexes(t, pool); n != 2 {
		t.Fatalf("after up again: %d UPLOADING indexes, want 2", n)
	}
	if !hasProcessingAt(t, pool) {
		t.Fatal("after up again: videos has no processing_at")
	}
	if !hasAuthorIndex(t, pool) {
		t.Fatal("after up again: no videos_author_created_idx")
	}
	if column, index := requestID(t, pool); !column || !index {
		t.Fatalf("after up again: request_id column %v, index %v, want both", column, index)
	}
	if columns, entitlements := premium(t, pool); columns != 2 || !entitlements {
		t.Fatalf("after up again: %d premium columns, video_entitlements %v, want 2 and true", columns, entitlements)
	}
}

// insertOld creates a video the way the release before 00007 does, naming neither premium nor
// preview_playlist_key.
func insertOld(t *testing.T, pool *pgxpool.Pool, id uuid.UUID) error {
	t.Helper()
	_, err := pool.Exec(t.Context(), `INSERT INTO videos (id, author_id, title, status, size_bytes, content_type, request_id)
		VALUES ($1, $2, 'Old release', 'UPLOADING', 1000, 'video/mp4', NULL)`, id, uuid.NewV7())
	return err
}

// The release before 00007, still serving during a rollout, keeps creating and publishing regular
// videos on the new schema, and works again after Down.
func TestPremiumMigrationKeepsReleaseBefore(t *testing.T) {
	pool := pgtest.New(t, "svp_video_migrations_premium_test", migrations.FS)
	ctx := t.Context()

	id := uuid.NewV7()
	if err := insertOld(t, pool, id); err != nil {
		t.Fatalf("old-style insert after 00007: %v", err)
	}
	// MarkVideoReady of the release before, which sets no preview_playlist_key.
	if _, err := pool.Exec(ctx, `UPDATE videos SET status = 'READY', duration_ms = 1000, playlist_key = 'media/x',
		thumbnail_key = 'media/y', published_at = now() WHERE id = $1`, id); err != nil {
		t.Fatalf("old-style ready after 00007: %v", err)
	}
	var isPremium bool
	var preview *string
	if err := pool.QueryRow(ctx, "SELECT premium, preview_playlist_key FROM videos WHERE id = $1", id).
		Scan(&isPremium, &preview); err != nil {
		t.Fatal(err)
	}
	if isPremium || preview != nil {
		t.Errorf("old-style video: premium %v, preview_playlist_key %v; want false and NULL", isPremium, preview)
	}
	// An entitlement needs an existing video and a known tier.
	if _, err := pool.Exec(ctx, "INSERT INTO video_entitlements (user_id, video_id, tier) VALUES ($1, $2, 'uhd')",
		uuid.NewV7(), id); err == nil {
		t.Error("entitlement with tier uhd was accepted")
	}
	if _, err := pool.Exec(ctx, "INSERT INTO video_entitlements (user_id, video_id, tier) VALUES ($1, $2, 'sd')",
		uuid.NewV7(), uuid.NewV7()); err == nil {
		t.Error("entitlement to a missing video was accepted")
	}

	db := stdlib.OpenDBFromPool(pool)
	t.Cleanup(func() { _ = db.Close() })
	provider, err := goose.NewProvider(goose.DialectPostgres, db, migrations.FS,
		goose.WithDisableGlobalRegistry(true),
		goose.WithTableName("goose.goose_db_version"),
		goose.WithLogger(goose.NopLogger()))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := provider.DownTo(ctx, 6); err != nil {
		t.Fatalf("down to 00006: %v", err)
	}
	if err := insertOld(t, pool, uuid.NewV7()); err != nil {
		t.Errorf("old-style insert after Down: %v", err)
	}
}
