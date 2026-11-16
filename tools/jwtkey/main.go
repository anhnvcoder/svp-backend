// Command jwtkey makes the Ed25519 JWT keys of the services and rotates them in an env file.
//
// With no argument it prints a new key pair as the three environment variable lines that
// `make env` appends to .env:
//
//	JWT_SIGNING_KID=<kid>
//	JWT_SIGNING_KEY=<standard base64 of the 32-byte seed>
//	JWT_VERIFY_KEYS=<kid>:<standard base64 of the 32-byte public key>
//
// The kid is the UTC date plus 4 random bytes in hex (e.g. 20261011-3fa2c91b): the date shows
// how old a key is when rotating, the random part keeps two keys made on the same day apart.
// It writes only to stdout, never to a file.
//
// "jwtkey rotate <add|sign|drop> <env file>" runs one step of docs/runbooks/jwt-key-rotation.md
// on the env file (`make jwt-rotate`):
//
//   - add makes a new key pair, keeps its three lines in .env.jwt-next next to the env file (the
//     pending key) and appends its verify key to JWT_VERIFY_KEYS;
//   - sign sets JWT_SIGNING_KID and JWT_SIGNING_KEY to the pending key;
//   - drop removes every verify key but the one of the signing kid, then the pending key.
//
// Each step refuses to run out of that order and writes nothing then. It replaces only the lines
// of the three variables, leaving every other byte of the env file as it was, and writes each
// file (mode 600) to a temporary file in the same directory that it then renames. It prints kids
// and the commands that apply the step, never a key, not even in an error.
package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/anhnvcoder/svp-backend/internal/authtoken"
)

const usage = "usage: jwtkey | jwtkey rotate <add|sign|drop> <env file>"

func main() {
	var err error
	switch {
	case len(os.Args) == 1:
		err = run(os.Stdout, time.Now())
	case len(os.Args) == 4 && os.Args[1] == "rotate":
		err = rotate(os.Stdout, os.Args[2], os.Args[3], time.Now())
	default:
		err = errors.New(usage)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "jwtkey:", err)
		os.Exit(1)
	}
}

func run(w io.Writer, now time.Time) error {
	key, err := authtoken.GenerateKey()
	if err != nil {
		return err
	}
	suffix := make([]byte, 4)
	_, _ = rand.Read(suffix) // crypto/rand.Read never returns an error (Go 1.24+).
	kid := now.UTC().Format("20060102") + "-" + hex.EncodeToString(suffix)
	pub := key.Public().(ed25519.PublicKey)

	_, err = fmt.Fprintf(w, "JWT_SIGNING_KID=%s\nJWT_SIGNING_KEY=%s\nJWT_VERIFY_KEYS=%s:%s\n",
		kid,
		base64.StdEncoding.EncodeToString(key.Seed()),
		kid, base64.StdEncoding.EncodeToString(pub))
	return err
}

const (
	signingKID = "JWT_SIGNING_KID"
	signingKey = "JWT_SIGNING_KEY"
	verifyKeys = "JWT_VERIFY_KEYS"
	// pendingName is the pending key's file, next to the env file. It matches the .env.* rule of
	// .gitignore, so it is never committed.
	pendingName = ".env.jwt-next"
)

// applyCommands bring a changed env file to the running services, as in the runbook; the waits
// that follow them need a person reading pod state and the clock, so each step only names them.
const applyCommands = `  compose: make up OBS=lgtm
  k3d:     make k8s-secrets
  EKS:     AWS_PROFILE=anhnv-<env> make eks-secrets CONTEXT=svp-<env>
`

// envFile is an env file split into lines, with the line of each of the three JWT variables.
type envFile struct {
	path  string
	lines []string
	at    map[string]int
	value map[string]string
}

func (e *envFile) set(name, value string) { e.lines[e.at[name]] = name + "=" + value }

func (e *envFile) bytes() []byte { return []byte(strings.Join(e.lines, "\n")) }

// verifyEntry is one kid:base64 entry of JWT_VERIFY_KEYS, kept as written.
type verifyEntry struct {
	kid, text string
	key       ed25519.PublicKey
}

// keySet is the three JWT variables of a file, checked.
type keySet struct {
	kid    string
	seed   ed25519.PrivateKey
	verify []verifyEntry
}

func rotate(w io.Writer, step, envPath string, now time.Time) error {
	if step != "add" && step != "sign" && step != "drop" {
		return fmt.Errorf("unknown step %q; %s", step, usage)
	}
	pendingPath := filepath.Join(filepath.Dir(envPath), pendingName)
	env, cur, err := load(envPath)
	if err != nil {
		return err
	}
	switch step {
	case "add":
		return rotateAdd(w, env, cur, pendingPath, now)
	case "sign":
		return rotateSign(w, env, cur, pendingPath)
	default:
		return rotateDrop(w, env, cur, pendingPath)
	}
}

func rotateAdd(w io.Writer, env *envFile, cur keySet, pendingPath string, now time.Time) error {
	if _, err := os.Lstat(pendingPath); err == nil { // #nosec G703 -- beside the env file the user names.
		return fmt.Errorf("%s exists: a rotation is under way; finish it with sign, then drop", pendingPath)
	} else if !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	var pair bytes.Buffer
	if err := run(&pair, now); err != nil {
		return err
	}
	pending, next, err := parse(pendingPath, pair.Bytes())
	if err != nil {
		return err
	}
	if _, dup := find(cur.verify, next.kid); dup {
		return fmt.Errorf("%s of %s already has new kid %s; run make jwt-rotate STEP=add again", verifyKeys, env.path, next.kid)
	}
	if err := writeFile(pendingPath, pair.Bytes()); err != nil {
		return err
	}
	env.set(verifyKeys, env.value[verifyKeys]+","+pending.value[verifyKeys])
	if err := writeFile(env.path, env.bytes()); err != nil {
		// Without its verify key in the env file the pending key could never be signed with.
		_ = os.Remove(pendingPath) // #nosec G703 -- beside the env file the user names.
		return err
	}
	_, err = fmt.Fprintf(w, "add: %s of %s now also has kid %s (kids before: %s); its signing key waits in %s\n"+
		"Apply it, then wait until every gateway and gRPC service pod is new and Ready (runbook, step 1):\n%s"+
		"Next: make jwt-rotate STEP=sign\n", verifyKeys, env.path, next.kid, kids(cur.verify), pendingPath, applyCommands)
	return err
}

func rotateSign(w io.Writer, env *envFile, cur keySet, pendingPath string) error {
	pending, next, err := loadPending(pendingPath)
	if err != nil {
		return err
	}
	if cur.kid == next.kid {
		return fmt.Errorf("%s of %s is already %s; next: make jwt-rotate STEP=drop", signingKID, env.path, next.kid)
	}
	entry, ok := find(cur.verify, next.kid)
	if !ok || !entry.key.Equal(next.seed.Public()) {
		return fmt.Errorf("%s of %s lacks the verify key of pending kid %s, so its tokens would be rejected; "+
			"remove %s and run make jwt-rotate STEP=add again", verifyKeys, env.path, next.kid, pendingPath)
	}
	env.set(signingKID, pending.value[signingKID])
	env.set(signingKey, pending.value[signingKey])
	if err := writeFile(env.path, env.bytes()); err != nil {
		return err
	}
	_, err = fmt.Fprintf(w, "sign: user-service of %s now signs with kid %s instead of %s\n"+
		"Apply it, then wait for the rollout of user-service (runbook, step 2):\n%s"+
		"Next, once the last user-service pod with kid %s stopped at least 15 min 30 s ago: make jwt-rotate STEP=drop\n",
		env.path, next.kid, cur.kid, applyCommands, cur.kid)
	return err
}

func rotateDrop(w io.Writer, env *envFile, cur keySet, pendingPath string) error {
	_, next, err := loadPending(pendingPath)
	if err != nil {
		return err
	}
	if cur.kid != next.kid {
		return fmt.Errorf("%s of %s is %s, not pending kid %s; run make jwt-rotate STEP=sign first",
			signingKID, env.path, cur.kid, next.kid)
	}
	var kept, dropped []verifyEntry
	for _, e := range cur.verify {
		if e.kid == cur.kid {
			kept = append(kept, e)
		} else {
			dropped = append(dropped, e)
		}
	}
	if len(kept) == 0 {
		return fmt.Errorf("%s of %s lacks signing kid %s", verifyKeys, env.path, cur.kid)
	}
	if len(dropped) > 0 {
		env.set(verifyKeys, kept[0].text)
		if err := writeFile(env.path, env.bytes()); err != nil {
			return err
		}
	}
	if err := os.Remove(pendingPath); err != nil { // #nosec G703 -- beside the env file the user names.
		return err
	}
	_, err = fmt.Fprintf(w, "drop: %s of %s keeps only kid %s (dropped: %s); removed %s\n"+
		"Apply it, then check as in the runbook (section Khôi phục và xác nhận):\n%s",
		verifyKeys, env.path, cur.kid, kids(dropped), pendingPath, applyCommands)
	return err
}

func loadPending(path string) (*envFile, keySet, error) {
	if _, err := os.Lstat(path); errors.Is(err, fs.ErrNotExist) { // #nosec G703 -- beside the env file the user names.
		return nil, keySet{}, fmt.Errorf("%s does not exist: no rotation under way; start one with make jwt-rotate STEP=add",
			path)
	}
	pending, next, err := load(path)
	if err != nil {
		return nil, keySet{}, err
	}
	if len(next.verify) != 1 || next.verify[0].kid != next.kid || !next.verify[0].key.Equal(next.seed.Public()) {
		return nil, keySet{}, fmt.Errorf("%s is not one key pair of tools/jwtkey", path)
	}
	return pending, next, nil
}

func load(path string) (*envFile, keySet, error) {
	data, err := os.ReadFile(path) // #nosec G304 G703 -- the env file the person rotating names, or its pending key.
	if err != nil {
		return nil, keySet{}, err
	}
	return parse(path, data)
}

// parse finds the three variables in data and checks them. Its errors name the file, the variable
// and the entry's position, never a value: any value may hold a key.
func parse(path string, data []byte) (*envFile, keySet, error) {
	e := &envFile{path: path, lines: strings.Split(string(data), "\n"), at: map[string]int{}, value: map[string]string{}}
	for i, line := range e.lines {
		for _, name := range []string{signingKID, signingKey, verifyKeys} {
			v, ok := strings.CutPrefix(line, name+"=")
			if !ok {
				continue
			}
			if first, dup := e.at[name]; dup {
				return nil, keySet{}, fmt.Errorf("%s:%d: %s is set again (first on line %d)", path, i+1, name, first+1)
			}
			e.at[name] = i
			e.value[name] = unquote(v)
		}
	}
	for _, name := range []string{signingKID, signingKey, verifyKeys} {
		v := e.value[name]
		if v == "" {
			return nil, keySet{}, fmt.Errorf("%s lacks %s or has it empty", path, name)
		}
		if strings.IndexFunc(v, func(r rune) bool { return r < '!' || r > '~' || strings.ContainsRune("\"'\\", r) }) >= 0 {
			return nil, keySet{}, fmt.Errorf("%s:%d: %s has a blank, quote, \\, CR or non-ASCII character in its value",
				path, e.at[name]+1, name)
		}
	}
	var ks keySet
	ks.kid = e.value[signingKID]
	seed, err := authtoken.ParseSigningKey(ks.kid, e.value[signingKey])
	if err != nil {
		return nil, keySet{}, fmt.Errorf("%s: %s and %s are not a kid and the standard base64 of a 32-byte seed",
			path, signingKID, signingKey)
	}
	ks.seed = seed
	for i, text := range strings.Split(e.value[verifyKeys], ",") {
		keys, err := authtoken.ParseVerifyKeys(text)
		if err != nil {
			return nil, keySet{}, fmt.Errorf("%s: entry %d of %s is not kid:<standard base64 of a 32-byte key>",
				path, i+1, verifyKeys)
		}
		for kid, key := range keys {
			if _, dup := find(ks.verify, kid); dup {
				return nil, keySet{}, fmt.Errorf("%s: %s has kid %s twice", path, verifyKeys, kid)
			}
			ks.verify = append(ks.verify, verifyEntry{kid: kid, text: text, key: key})
		}
	}
	return e, ks, nil
}

// unquote drops one pair of matching quotes, as compose reads NAME="value" and NAME='value'.
func unquote(v string) string {
	if len(v) >= 2 && (v[0] == '"' || v[0] == '\'') && v[len(v)-1] == v[0] {
		return v[1 : len(v)-1]
	}
	return v
}

func find(entries []verifyEntry, kid string) (verifyEntry, bool) {
	for _, e := range entries {
		if e.kid == kid {
			return e, true
		}
	}
	return verifyEntry{}, false
}

func kids(entries []verifyEntry) string {
	names := make([]string, len(entries))
	for i, e := range entries {
		names[i] = e.kid
	}
	return strings.Join(names, ", ")
}

// writeFile replaces path with data through a temporary file in the same directory, so a failed
// write leaves the old file whole and a reader never sees half of the new one.
func writeFile(path string, data []byte) (err error) {
	f, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".tmp.*")
	if err != nil {
		return err
	}
	defer func() {
		if err != nil {
			_ = f.Close()
			_ = os.Remove(f.Name()) // #nosec G703 -- the env file the person rotating names, or its temporary file.
		}
	}()
	if err = f.Chmod(0o600); err != nil {
		return err
	}
	if _, err = f.Write(data); err != nil {
		return err
	}
	if err = f.Sync(); err != nil {
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	return os.Rename(f.Name(), path) // #nosec G703 -- the env file the person rotating names, or its temporary file.
}
