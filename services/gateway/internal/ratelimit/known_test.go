package ratelimit

import (
	"context"
	"strings"
	"testing"
	"time"
)

func TestKnownPair(t *testing.T) {
	client, prefix := testRedis(t)
	l := New(client, prefix, WithStoreTimeout(testStoreTimeout))
	ctx := t.Context()
	const email = "a@example.com"
	for _, ip := range []string{"192.0.2.1", "2001:db8::/64"} {
		if l.KnownPair(ctx, ip, email) {
			t.Fatalf("pair (%s, email) known before any login", ip)
		}
		l.RememberPair(ctx, ip, email)
		if !l.KnownPair(ctx, ip, "  A@Example.COM ") {
			t.Errorf("pair (%s, email) unknown after RememberPair, with the email written another way", ip)
		}
		key := prefix + "login-known:" + ip + ":" + EmailHash(email)
		v, err := client.Get(ctx, key).Result()
		if err != nil || v != "1" {
			t.Errorf("GET %s = %q, %v; want 1", key, v, err)
		}
		ttl, err := client.PTTL(ctx, key).Result()
		if err != nil {
			t.Fatal(err)
		}
		if ttl <= 30*24*time.Hour-time.Minute || ttl > 30*24*time.Hour {
			t.Errorf("PTTL %s = %v, want 30 days", key, ttl)
		}
	}
	if l.KnownPair(ctx, "192.0.2.2", email) || l.KnownPair(ctx, "192.0.2.1", "b@example.com") {
		t.Error("another IP or email shares the pair")
	}
	for _, key := range scanKeys(t, client, prefix) {
		if strings.Contains(key, "example") || strings.Contains(key, ":rl:") {
			t.Errorf("key %s holds the email or sits under rl:", key)
		}
	}
	if keys := scanKeys(t, client, prefix); len(keys) != 2 {
		t.Errorf("keys = %v, want the two pairs", keys)
	}
}

// TestKnownPairRedisDown: while Redis fails a pair is unknown, so LoginAccount applies, and
// RememberPair only warns.
func TestKnownPairRedisDown(t *testing.T) {
	logs := captureLog(t)
	l := New(downClient(t), "svp:test:down:")
	l.RememberPair(t.Context(), "192.0.2.1", "a@example.com")
	if l.KnownPair(t.Context(), "192.0.2.1", "a@example.com") {
		t.Error("pair known while Redis fails")
	}
	if n := strings.Count(logs.String(), "rate limit store unavailable, using fallback"); n != 1 {
		t.Errorf("WARN logged %d times, want once per %v:\n%s", n, warnEvery, logs)
	}
}

// TestKnownPairGoneRequest: a request already cancelled or past its deadline writes no pair,
// finds none, and logs nothing, while Redis is healthy.
func TestKnownPairGoneRequest(t *testing.T) {
	client, prefix := testRedis(t)
	expired, cancelExpired := context.WithDeadline(t.Context(), time.Now().Add(-time.Second))
	defer cancelExpired()
	cancelled, cancel := context.WithCancel(t.Context())
	cancel()
	for name, ctx := range map[string]context.Context{"cancelled": cancelled, "deadline exceeded": expired} {
		t.Run(name, func(t *testing.T) {
			logs := captureLog(t)
			l := New(client, prefix, WithStoreTimeout(testStoreTimeout))
			l.RememberPair(ctx, "192.0.2.1", "a@example.com")
			if keys := scanKeys(t, client, prefix); len(keys) != 0 {
				t.Errorf("keys = %v, want none", keys)
			}
			l.RememberPair(t.Context(), "192.0.2.1", "a@example.com")
			if l.KnownPair(ctx, "192.0.2.1", "a@example.com") {
				t.Error("pair known to a request that was gone")
			}
			if logs.Len() != 0 {
				t.Errorf("logged for a request that was gone:\n%s", logs)
			}
			deleteKeys(t, client, prefix)
		})
	}
}

func TestKnownPairStoreTimeout(t *testing.T) {
	captureLog(t)
	client, prefix := testRedis(t)
	writer := New(client, prefix, WithStoreTimeout(testStoreTimeout))
	writer.RememberPair(t.Context(), "192.0.2.1", "a@example.com")
	// A GET that cannot finish within the bound counts as Redis failing: the pair is unknown.
	if New(client, prefix, WithStoreTimeout(time.Nanosecond)).KnownPair(t.Context(), "192.0.2.1", "a@example.com") {
		t.Error("pair known past the store timeout")
	}
}
