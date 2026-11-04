package callerid

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"

	"github.com/anhnvcoder/svp-backend/internal/authtoken"
	"github.com/anhnvcoder/svp-backend/internal/grpcerr"
	"github.com/anhnvcoder/svp-backend/internal/logx"
)

const (
	loginMethod  = "/svp.user.v1.UserService/Login"
	followMethod = "/svp.user.v1.UserService/Follow"
	statsMethod  = "/svp.engagement.v1.EngagementService/GetStats"
	userID       = "01928c6e-7b3a-7cde-8f01-23456789abcd"
	otherUserID  = "01928c6e-7b3a-7cde-8f01-000000000000"
	testKID      = "k1"
)

var (
	testKey      = newKey()
	attackerKey  = newKey()
	testVerifier = authtoken.NewVerifier(map[string]ed25519.PublicKey{testKID: testKey.Public().(ed25519.PublicKey)})
)

func newKey() ed25519.PrivateKey {
	k, err := authtoken.GenerateKey()
	if err != nil {
		panic(err)
	}
	return k
}

// claims returns the claims user-service writes for sub, as a map a test can change.
func claims(sub string) jwt.MapClaims {
	now := time.Now()
	return jwt.MapClaims{
		"iss": authtoken.IssuerName,
		"aud": []string{authtoken.Audience},
		"sub": sub,
		"iat": now.Unix(),
		"exp": now.Add(authtoken.TTL).Unix(),
	}
}

func sign(t *testing.T, key ed25519.PrivateKey, kid string, c jwt.MapClaims) string {
	t.Helper()
	tok := jwt.NewWithClaims(jwt.SigningMethodEdDSA, c)
	tok.Header["kid"] = kid
	s, err := tok.SignedString(key)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func validToken(t *testing.T) string {
	t.Helper()
	return sign(t, testKey, testKID, claims(userID))
}

// call runs the interceptor of m for method with the given incoming metadata pairs (no metadata
// when pairs is nil) and reports whether the handler ran and with which caller.
func call(t *testing.T, m Methods, method string, pairs ...string) (ran bool, caller string, err error) {
	t.Helper()
	ctx := context.Background()
	if pairs != nil {
		ctx = metadata.NewIncomingContext(ctx, metadata.Pairs(pairs...))
	}
	handler := func(ctx context.Context, _ any) (any, error) {
		ran = true
		caller, _ = FromContext(ctx)
		return "ok", nil
	}
	_, err = NewUnaryServerInterceptor(testVerifier, m)(ctx, nil, &grpc.UnaryServerInfo{FullMethod: method}, handler)
	return ran, caller, err
}

// required is the interceptor of a service whose only public RPC is Login.
var required = Methods{Public: []string{loginMethod}}

// optional adds GetStats as an RPC whose caller is optional.
var optional = Methods{Public: []string{loginMethod}, OptionalCaller: []string{statsMethod}}

func wantUnauthenticated(t *testing.T, ran bool, err error) {
	t.Helper()
	if ran {
		t.Error("handler ran")
	}
	if status.Code(err) != codes.Unauthenticated || grpcerr.Reason(err) != ReasonUnauthenticatedCaller {
		t.Errorf("err = %v (reason %q), want UNAUTHENTICATED with %s", err, grpcerr.Reason(err), ReasonUnauthenticatedCaller)
	}
	if got := status.Convert(err).Message(); got != "missing or invalid caller identity" {
		t.Errorf("message = %q, want the same for every failure", got)
	}
}

func TestValidTokenReachesHandler(t *testing.T) {
	for _, scheme := range []string{"Bearer ", "bearer "} {
		ran, caller, err := call(t, required, followMethod, AuthorizationKey, scheme+validToken(t))
		if err != nil || !ran {
			t.Fatalf("%q: ran = %v, err = %v; want handler to run", scheme, ran, err)
		}
		if caller != userID {
			t.Errorf("%q: FromContext() = %q, want %q", scheme, caller, userID)
		}
	}
}

// invalidAuthorization lists metadata a client might send instead of one valid token. Each must
// fail the same way.
func invalidAuthorization(t *testing.T) []struct {
	name  string
	pairs []string
} {
	t.Helper()
	valid := validToken(t)
	expired := claims(userID)
	expired["iat"] = time.Now().Add(-2 * authtoken.TTL).Unix()
	expired["exp"] = time.Now().Add(-authtoken.Leeway - time.Minute).Unix()
	wrongAud := claims(userID)
	wrongAud["aud"] = []string{"other-api"}
	wrongIss := claims(userID)
	wrongIss["iss"] = "other-issuer"
	return []struct {
		name  string
		pairs []string
	}{
		{"forged x-user-id without a token", []string{"x-user-id", userID}},
		{"empty", []string{AuthorizationKey, ""}},
		{"token without Bearer", []string{AuthorizationKey, valid}},
		{"Basic scheme", []string{AuthorizationKey, "Basic dXNlcjpwYXNz"}},
		{"Bearer without token", []string{AuthorizationKey, "Bearer "}},
		{"two values", []string{AuthorizationKey, "Bearer " + valid, AuthorizationKey, "Bearer " + sign(t, testKey, testKID, claims(otherUserID))}},
		{"two equal values", []string{AuthorizationKey, "Bearer " + valid, AuthorizationKey, "Bearer " + valid}},
		{"signed by another key", []string{AuthorizationKey, "Bearer " + sign(t, attackerKey, testKID, claims(userID))}},
		{"unknown kid", []string{AuthorizationKey, "Bearer " + sign(t, testKey, "k2", claims(userID))}},
		{"expired", []string{AuthorizationKey, "Bearer " + sign(t, testKey, testKID, expired)}},
		{"wrong aud", []string{AuthorizationKey, "Bearer " + sign(t, testKey, testKID, wrongAud)}},
		{"wrong iss", []string{AuthorizationKey, "Bearer " + sign(t, testKey, testKID, wrongIss)}},
		{"sub not a UUID", []string{AuthorizationKey, "Bearer " + sign(t, testKey, testKID, claims("admin"))}},
		{"garbage", []string{AuthorizationKey, "Bearer not.a.token"}},
	}
}

func TestInvalidCallerIsUnauthenticated(t *testing.T) {
	cases := append(invalidAuthorization(t), struct {
		name  string
		pairs []string
	}{"no metadata", nil}, struct {
		name  string
		pairs []string
	}{"metadata without authorization", []string{"other", "x"}})
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ran, _, err := call(t, required, followMethod, tc.pairs...)
			wantUnauthenticated(t, ran, err)
		})
	}
}

// x-user-id is never read: a valid token's subject is the caller, whatever x-user-id says.
func TestTokenWinsOverForgedUserID(t *testing.T) {
	ran, caller, err := call(t, required, followMethod, AuthorizationKey, "Bearer "+validToken(t), "x-user-id", otherUserID)
	if err != nil || !ran || caller != userID {
		t.Errorf("ran = %v, caller = %q, err = %v; want the token's %s", ran, caller, err, userID)
	}
}

func TestPublicMethodIgnoresAuthorization(t *testing.T) {
	for name, pairs := range map[string][]string{
		"no metadata":   nil,
		"broken token":  {AuthorizationKey, "Bearer not.a.token"},
		"two values":    {AuthorizationKey, "x", AuthorizationKey, "y"},
		"valid token":   {AuthorizationKey, "Bearer " + validToken(t)},
		"forged caller": {"x-user-id", userID},
	} {
		ran, caller, err := call(t, required, loginMethod, pairs...)
		if err != nil || !ran {
			t.Errorf("%s: ran = %v, err = %v; want handler to run", name, ran, err)
		}
		if caller != "" {
			t.Errorf("%s: caller = %q, want none", name, caller)
		}
	}
}

func TestOptionalCallerAbsentRunsWithoutCaller(t *testing.T) {
	for name, pairs := range map[string][]string{
		"no metadata":                    nil,
		"metadata without authorization": {"other", "x"},
		// A forged x-user-id is not an authorization: the call stays anonymous.
		"forged x-user-id": {"x-user-id", userID},
	} {
		ran, caller, err := call(t, optional, statsMethod, pairs...)
		if err != nil || !ran {
			t.Errorf("%s: ran = %v, err = %v; want handler to run", name, ran, err)
		}
		if caller != "" {
			t.Errorf("%s: caller = %q, want none", name, caller)
		}
	}
}

func TestOptionalCallerPresentAndValidReachesHandler(t *testing.T) {
	ran, caller, err := call(t, optional, statsMethod, AuthorizationKey, "Bearer "+validToken(t))
	if err != nil || !ran {
		t.Fatalf("ran = %v, err = %v; want handler to run", ran, err)
	}
	if caller != userID {
		t.Errorf("FromContext() = %q, want %q", caller, userID)
	}
}

// A present authorization must be valid: an invalid one is never served as an anonymous call.
func TestOptionalCallerPresentButInvalidIsUnauthenticated(t *testing.T) {
	for _, tc := range invalidAuthorization(t) {
		if tc.pairs[0] != AuthorizationKey {
			continue
		}
		t.Run(tc.name, func(t *testing.T) {
			ran, _, err := call(t, optional, statsMethod, tc.pairs...)
			wantUnauthenticated(t, ran, err)
		})
	}
}

// Listing some RPCs as optional or public changes nothing for the others.
func TestOptionalCallerLeavesOtherModesAlone(t *testing.T) {
	if ran, _, err := call(t, optional, followMethod); ran || status.Code(err) != codes.Unauthenticated {
		t.Errorf("required caller without a token: ran = %v, err = %v; want UNAUTHENTICATED", ran, err)
	}
	if ran, caller, err := call(t, optional, followMethod, AuthorizationKey, "Bearer "+validToken(t)); err != nil || !ran || caller != userID {
		t.Errorf("required caller with a token: ran = %v, caller = %q, err = %v", ran, caller, err)
	}
	if ran, caller, err := call(t, optional, loginMethod, AuthorizationKey, "garbage"); err != nil || !ran || caller != "" {
		t.Errorf("public method with a broken token: ran = %v, caller = %q, err = %v; want handler to run without caller", ran, caller, err)
	}
}

func TestUnaryServerInterceptorTakesPublicMethods(t *testing.T) {
	ctx := context.Background()
	ran := false
	handler := func(context.Context, any) (any, error) { ran = true; return nil, nil }
	if _, err := UnaryServerInterceptor(testVerifier, loginMethod)(ctx, nil, &grpc.UnaryServerInfo{FullMethod: loginMethod}, handler); err != nil || !ran {
		t.Errorf("public method: ran = %v, err = %v", ran, err)
	}
	ran = false
	_, err := UnaryServerInterceptor(testVerifier, loginMethod)(ctx, nil, &grpc.UnaryServerInfo{FullMethod: followMethod}, handler)
	wantUnauthenticated(t, ran, err)
}

// captureDefaultLog sends slog.Default to a buffer, through logx as in the services, until the
// test ends.
func captureDefaultLog(t *testing.T) *bytes.Buffer {
	t.Helper()
	var buf bytes.Buffer
	prev := slog.Default()
	slog.SetDefault(slog.New(logx.NewHandler(slog.NewJSONHandler(&buf, nil))))
	t.Cleanup(func() { slog.SetDefault(prev) })
	return &buf
}

func TestCallerInLogAttributes(t *testing.T) {
	logs := captureDefaultLog(t)
	token := validToken(t)
	ctx := metadata.NewIncomingContext(context.Background(), metadata.Pairs(AuthorizationKey, "Bearer "+token))
	handler := func(ctx context.Context, _ any) (any, error) {
		slog.InfoContext(ctx, "in handler")
		return nil, nil
	}
	if _, err := UnaryServerInterceptor(testVerifier)(ctx, nil, &grpc.UnaryServerInfo{FullMethod: followMethod}, handler); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(logs.String(), `"user_id":"`+userID+`"`) {
		t.Errorf("log line has no user_id: %s", logs)
	}
	if strings.Contains(logs.String(), token) {
		t.Errorf("log contains the token: %s", logs)
	}
}

// A rejected token is logged with the reason, never with the token or any part of it.
func TestRejectionLogNeverHoldsToken(t *testing.T) {
	for _, tc := range invalidAuthorization(t) {
		t.Run(tc.name, func(t *testing.T) {
			logs := captureDefaultLog(t)
			ran, _, err := call(t, required, followMethod, tc.pairs...)
			wantUnauthenticated(t, ran, err)
			if !strings.Contains(logs.String(), `"msg":"caller token rejected"`) || !strings.Contains(logs.String(), `"error":`) {
				t.Errorf("no rejection line with its reason: %s", logs)
			}
			for i := 1; i < len(tc.pairs); i += 2 {
				for _, part := range strings.FieldsFunc(tc.pairs[i], func(r rune) bool { return r == ' ' || r == '.' }) {
					if len(part) >= 8 && strings.Contains(logs.String(), part) {
						t.Errorf("log contains part %q of the token: %s", part, logs)
					}
				}
			}
			if strings.Contains(status.Convert(err).Message(), "Bearer") {
				t.Errorf("error message holds the authorization value: %v", err)
			}
		})
	}
}

func TestFromContextWithoutCaller(t *testing.T) {
	if id, ok := FromContext(context.Background()); ok || id != "" {
		t.Errorf("FromContext() = (%q, %v), want (\"\", false)", id, ok)
	}
}
