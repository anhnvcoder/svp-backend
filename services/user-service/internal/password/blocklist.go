package password

import (
	_ "embed"
	"errors"
	"slices"
	"strings"
	"sync"

	"github.com/anhnvcoder/svp-backend/internal/secret"
)

// ErrBlocklisted means a password is a common or breached one, or equals the account's email, the part of the email
// before the @, or the picked handle; the service answers INVALID_ARGUMENT.
var ErrBlocklisted = errors.New("password: too common, breached or the same as the email or handle")

// blocklistText is the list blocklist.sh writes: one lowercase entry per line, sorted by byte, no duplicates, each
// MinLength to MaxLength characters.
//
//go:embed blocklist.txt
var blocklistText string

// blocklist splits blocklistText once, on first use. The entries are substrings of the embedded text, so the slice
// headers are the only memory added.
var blocklist = sync.OnceValue(func() []string {
	return strings.Split(strings.TrimSuffix(blocklistText, "\n"), "\n")
})

// CheckBlocklist returns ErrBlocklisted when the lowercase pw is in the embedded blocklist or equals the lowercase
// email, the part of email before its last @, or handle when handle is not empty. The whole password is compared, never
// a substring, as NIST SP 800-63B-4 §3.1.1.2 asks.
//
// The blocklist holds the entries of MinLength to MaxLength characters of the 100 000 most used passwords that the UK
// NCSC published from Have I Been Pwned data, without the ones shaped like an email address, taken by blocklist.sh
// from SecLists at a pinned commit:
// https://github.com/danielmiessler/SecLists/tree/1a7bb9127eca9e6ff2fc0301c597fe6e16a0cb56. Contains public sector
// information licensed under the Open Government Licence v3.0:
// https://www.nationalarchives.gov.uk/doc/open-government-licence/version/3/. It is checked in memory, so registering
// sends nothing out of the service and needs no outside network.
//
// The service calls it after CheckLength only when a password is set, as NIST asks for a new secret: Login does not
// call it, so an account whose password was set before an entry was listed can still log in.
func CheckBlocklist(pw secret.String, email, handle string) error {
	p := strings.ToLower(pw.Reveal())
	email = strings.ToLower(email)
	if _, found := slices.BinarySearch(blocklist(), p); found {
		return ErrBlocklisted
	}
	if p == email {
		return ErrBlocklisted
	}
	if i := strings.LastIndexByte(email, '@'); i >= 0 && p == email[:i] {
		return ErrBlocklisted
	}
	if handle != "" && p == strings.ToLower(handle) {
		return ErrBlocklisted
	}
	return nil
}
