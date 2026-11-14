package ratelimit

import (
	"context"
	"errors"
	"time"

	"github.com/redis/go-redis/v9"
)

// knownPairTTL is how long a successful login keeps its (IP, email) pair known: as long as the
// refresh token family it started (RefreshFamilyTTL of user-service), so a session that has not
// ended yet never meets LoginAccount on its own address.
const knownPairTTL = 30 * 24 * time.Hour

// KnownPair reports whether email logged in successfully from ip within knownPairTTL (see
// RememberPair).
//
// A known pair skips LoginAccount. That class holds every login of one email, so anyone can spend
// its bucket and keep the owner out from everywhere; letting through the addresses the owner
// already logged in from bounds that lockout to new addresses, while LoginIP and LoginEmail still
// hold a known pair. When the GET fails or takes longer than storeTimeout the pair counts as
// unknown, and LoginAccount decides as for any unknown pair: on Redis, taking its fallback only
// when its own call fails too.
func (l *Limiter) KnownPair(ctx context.Context, ip, email string) bool {
	storeCtx, cancel := context.WithTimeout(ctx, l.storeTimeout)
	defer cancel()
	err := l.client.Get(storeCtx, l.knownKey(ip, email)).Err()
	if errors.Is(err, redis.Nil) {
		return false
	}
	if err != nil {
		l.warnUnlessGone(ctx, err)
		return false
	}
	return true
}

// RememberPair marks (ip, email) known for knownPairTTL after a successful login. It is
// best-effort: a failure is only logged, and a request already cancelled or past its deadline
// writes nothing.
func (l *Limiter) RememberPair(ctx context.Context, ip, email string) {
	if ctx.Err() != nil {
		return
	}
	storeCtx, cancel := context.WithTimeout(ctx, l.storeTimeout)
	defer cancel()
	if err := l.client.Set(storeCtx, l.knownKey(ip, email), 1, knownPairTTL).Err(); err != nil {
		l.warnUnlessGone(ctx, err)
	}
}

// knownKey is outside rl: since it holds no bucket.
func (l *Limiter) knownKey(ip, email string) string {
	return l.prefix + "login-known:" + LoginEmailID(ip, email)
}
