package password

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/anhnvcoder/svp-backend/internal/secret"
)

// scriptValue returns the value of name=value in blocklist.sh, which records the line count and sha256 of the file it
// writes.
func scriptValue(t *testing.T, name string) string {
	t.Helper()
	script, err := os.ReadFile("blocklist.sh")
	if err != nil {
		t.Fatal(err)
	}
	m := regexp.MustCompile(`(?m)^` + name + `=(\S+)$`).FindSubmatch(script)
	if m == nil {
		t.Fatalf("blocklist.sh has no %s= line", name)
	}
	return string(m[1])
}

func TestBlocklistFile(t *testing.T) {
	t.Parallel()
	sum := sha256.Sum256([]byte(blocklistText))
	if got, want := hex.EncodeToString(sum[:]), scriptValue(t, "want_sha256"); got != want {
		t.Errorf("sha256(blocklist.txt) = %s, want %s from blocklist.sh", got, want)
	}
	if !strings.HasSuffix(blocklistText, "\n") {
		t.Error("blocklist.txt does not end with a newline")
	}
	list := blocklist()
	want, err := strconv.Atoi(scriptValue(t, "want_lines"))
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != want || want == 0 {
		t.Fatalf("blocklist has %d entries, want %d from blocklist.sh and more than 0", len(list), want)
	}
	emailShaped := regexp.MustCompile(`^[^@]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z][a-z]+$`)
	for i, e := range list {
		if emailShaped.MatchString(e) {
			t.Errorf("entry %d %q is shaped like an email address", i, e)
		}
		if !utf8.ValidString(e) || e != strings.ToLower(e) {
			t.Errorf("entry %d %q is not lowercase valid UTF-8", i, e)
		}
		if n := utf8.RuneCountInString(e); n < MinLength || n > MaxLength {
			t.Errorf("entry %d %q has %d characters, want %d to %d", i, e, n, MinLength, MaxLength)
		}
		if i > 0 && list[i-1] >= e {
			t.Errorf("entry %d %q is not after entry %d %q: not sorted by byte or a duplicate", i, e, i-1, list[i-1])
		}
	}
}

func TestCheckBlocklist(t *testing.T) {
	t.Parallel()
	list := blocklist()
	email := "alice.smith@example.io"
	blocked := []struct{ pw, email, handle string }{
		{"password", email, ""},
		{"PassWord", email, ""},
		{list[0], email, ""},
		{strings.ToUpper(list[len(list)-1]), email, ""},
		{email, email, ""},
		{"Alice.Smith@Example.IO", email, ""},
		{"alice.smith", email, ""},
		{"ALICE.SMITH", "Alice.Smith@Example.io", ""},
		{"alice_wonder", "someone@example.io", "alice_wonder"},
		{"Alice_Wonder", "someone@example.io", "alice_wonder"},
	}
	for _, c := range blocked {
		if err := CheckBlocklist(secret.New(c.pw), c.email, c.handle); !errors.Is(err, ErrBlocklisted) {
			t.Errorf("CheckBlocklist(%q, %q, %q) = %v, want ErrBlocklisted", c.pw, c.email, c.handle, err)
		}
	}

	allowed := []struct{ pw, email, handle string }{
		{rand.Text(), email, "alice_wonder"},
		// The whole password is compared: a listed entry inside a longer one does not block it.
		{"password" + rand.Text(), email, ""},
		{"alice.smith.2", email, ""},
		{"alice_wonder1", email, "alice_wonder"},
		// No handle picked: nothing to compare with.
		{"no-handle-picked-zq", "x@example.io", ""},
	}
	for _, c := range allowed {
		if err := CheckBlocklist(secret.New(c.pw), c.email, c.handle); err != nil {
			t.Errorf("CheckBlocklist(%q, %q, %q) = %v, want nil", c.pw, c.email, c.handle, err)
		}
	}
}
