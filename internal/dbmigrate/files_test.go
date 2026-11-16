package dbmigrate_test

import (
	"io/fs"
	"os"
	"regexp"
	"slices"
	"strings"
	"testing"
	"testing/fstest"
)

var (
	gooseNoTransaction = regexp.MustCompile(`(?im)^--\s*\+goose\s+NO\s+TRANSACTION\s*$`)
	squawkNoAssumeTx   = regexp.MustCompile(`(?m)^--\s*squawk-disable-assume-in-transaction\s*$`)
	sqlComment         = regexp.MustCompile(`--[^\n]*`)
	concurrently       = regexp.MustCompile(`(?i)\bCONCURRENTLY\b`)
	commit             = regexp.MustCompile(`(?i)\bCOMMIT\b`)
	validateConstraint = regexp.MustCompile(`(?i)\bVALIDATE\s+CONSTRAINT\b`)
	addConstraint      = regexp.MustCompile(`(?i)\bADD\s+CONSTRAINT\b`)
)

// fileProblems checks every migration in fsys matching pattern against the rules on how a file
// runs: outside a transaction exactly when it needs to, with the marker squawk reads for the same
// fact, and VALIDATE CONSTRAINT apart from the ADD CONSTRAINT whose lock would cover its scan. It
// returns the files it read and one line, starting with the file name, per rule a file breaks.
func fileProblems(t *testing.T, fsys fs.FS, pattern string) (files, problems []string) {
	t.Helper()
	files, err := fs.Glob(fsys, pattern)
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range files {
		data, err := fs.ReadFile(fsys, name)
		if err != nil {
			t.Fatal(err)
		}
		noTx := gooseNoTransaction.Match(data)
		// Keywords count in statements only, not in comments that mention them.
		code := sqlComment.ReplaceAll(data, nil)
		if concurrently.Match(code) && !noTx {
			problems = append(problems, name+": CONCURRENTLY needs -- +goose NO TRANSACTION")
		}
		if noTx && !concurrently.Match(code) && !commit.Match(code) {
			problems = append(problems, name+": -- +goose NO TRANSACTION without CONCURRENTLY or a batched COMMIT")
		}
		if noTx != squawkNoAssumeTx.Match(data) {
			problems = append(problems, name+": -- +goose NO TRANSACTION and -- squawk-disable-assume-in-transaction go together")
		}
		if validateConstraint.Match(code) && addConstraint.Match(code) {
			problems = append(problems, name+": VALIDATE CONSTRAINT in the same file as ADD CONSTRAINT")
		}
	}
	return files, problems
}

const (
	indexInTransaction = `-- +goose Up
CREATE INDEX CONCURRENTLY IF NOT EXISTS items_name_idx ON items (name);
-- +goose Down
DROP INDEX CONCURRENTLY IF EXISTS items_name_idx;
`
	noTransactionForNothing = `-- +goose NO TRANSACTION
-- squawk-disable-assume-in-transaction
-- +goose Up
-- Not CONCURRENTLY, and no COMMIT: this file has no reason to run outside a transaction.
ALTER TABLE items ADD COLUMN size bigint;
-- +goose Down
ALTER TABLE items DROP COLUMN size;
`
	batchedBackfill = `-- +goose NO TRANSACTION
-- squawk-disable-assume-in-transaction
-- +goose Up
-- +goose StatementBegin
DO $$
DECLARE
  last_id bigint := 0;
  batch_end bigint;
BEGIN
  LOOP
    SELECT max(id) INTO batch_end FROM (SELECT id FROM items WHERE id > last_id ORDER BY id LIMIT 10000) AS batch;
    EXIT WHEN batch_end IS NULL;
    UPDATE items SET name = title WHERE id > last_id AND id <= batch_end AND name IS NULL;
    last_id := batch_end;
    COMMIT;
  END LOOP;
END $$;
-- +goose StatementEnd
-- +goose Down
SELECT 1;
`
	addAndValidate = `-- +goose Up
ALTER TABLE items ADD CONSTRAINT items_name_not_null CHECK (name IS NOT NULL) NOT VALID;
ALTER TABLE items VALIDATE CONSTRAINT items_name_not_null;
-- +goose Down
ALTER TABLE items DROP CONSTRAINT items_name_not_null;
`
	addNotValid = `-- +goose Up
ALTER TABLE items ADD CONSTRAINT items_name_not_null CHECK (name IS NOT NULL) NOT VALID;
-- +goose Down
ALTER TABLE items DROP CONSTRAINT items_name_not_null;
`
	validateOnly = `-- +goose Up
ALTER TABLE items VALIDATE CONSTRAINT items_name_not_null;
-- +goose Down
SELECT 1;
`
	gooseMarkerOnly = `-- +goose NO TRANSACTION
-- +goose Up
CREATE INDEX CONCURRENTLY IF NOT EXISTS items_name_idx ON items (name);
-- +goose Down
DROP INDEX CONCURRENTLY IF EXISTS items_name_idx;
`
	squawkMarkerOnly = `-- squawk-disable-assume-in-transaction
-- +goose Up
ALTER TABLE items ADD COLUMN size bigint;
-- +goose Down
ALTER TABLE items DROP COLUMN size;
`
)

func TestFileProblems(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name string
		sql  string
		want string // the problem reported for the file; empty when the file is right
	}{
		{name: "CONCURRENTLY in a transaction", sql: indexInTransaction, want: "CONCURRENTLY needs"},
		{name: "NO TRANSACTION without a reason", sql: noTransactionForNothing, want: "without CONCURRENTLY or a batched COMMIT"},
		{name: "VALIDATE with ADD CONSTRAINT", sql: addAndValidate, want: "VALIDATE CONSTRAINT in the same file"},
		{name: "goose marker without squawk marker", sql: gooseMarkerOnly, want: "go together"},
		{name: "squawk marker without goose marker", sql: squawkMarkerOnly, want: "go together"},
		{name: "CREATE INDEX CONCURRENTLY outside a transaction", sql: indexConcurrently},
		{name: "batched backfill outside a transaction", sql: batchedBackfill},
		{name: "ADD CONSTRAINT NOT VALID alone", sql: addNotValid},
		{name: "VALIDATE CONSTRAINT alone", sql: validateOnly},
		{name: "plain migration in a transaction", sql: addName},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			const name = "00002_change.sql"
			_, problems := fileProblems(t, fstest.MapFS{name: file(tt.sql)}, "*.sql")
			if tt.want == "" {
				if len(problems) > 0 {
					t.Errorf("problems = %q, want none", problems)
				}
				return
			}
			if len(problems) != 1 || !strings.HasPrefix(problems[0], name+": ") || !strings.Contains(problems[0], tt.want) {
				t.Errorf("problems = %q, want one starting %q and saying %q", problems, name+": ", tt.want)
			}
		})
	}
}

// TestMigrationFiles runs fileProblems on the services' migrations and the test migrations here.
func TestMigrationFiles(t *testing.T) {
	t.Parallel()
	services, problems := fileProblems(t, os.DirFS("../.."), "services/*/migrations/*.sql")
	if len(services) == 0 {
		t.Fatal("found no migration under services/*/migrations")
	}
	testdata, more := fileProblems(t, os.DirFS("."), "testdata/*/*.sql")
	problems = append(problems, more...)
	for _, p := range problems {
		t.Error(p)
	}
	t.Logf("checked %d files", len(slices.Concat(services, testdata)))
}
