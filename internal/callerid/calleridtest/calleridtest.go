// Package calleridtest gives the tests of the gRPC services a caller: an access token signed with
// a key made for the test binary, the Verifier that accepts it, and contexts carrying it in the
// authorization metadata, as the gateway sends it.
package calleridtest

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"google.golang.org/grpc/metadata"

	"github.com/anhnvcoder/svp-backend/internal/authtoken"
	"github.com/anhnvcoder/svp-backend/internal/callerid"
)

const kid = "calleridtest"

var key = mustKey()

func mustKey() ed25519.PrivateKey {
	k, err := authtoken.GenerateKey()
	if err != nil {
		panic(err)
	}
	return k
}

// Verifier returns a Verifier that accepts the tokens of Token.
func Verifier() *authtoken.Verifier {
	return authtoken.NewVerifier(map[string]ed25519.PublicKey{kid: key.Public().(ed25519.PublicKey)})
}

// VerifyKeys returns the test key in the JWT_VERIFY_KEYS format, for a test that starts a
// service's main.
func VerifyKeys() string {
	return kid + ":" + base64.StdEncoding.EncodeToString(key.Public().(ed25519.PublicKey))
}

// Token returns an access token for sub with the claims user-service writes, signed with the
// test key. sub need not be a UUID, so a test can check that a malformed subject is refused.
func Token(sub string) string {
	now := time.Now()
	t := jwt.NewWithClaims(jwt.SigningMethodEdDSA, jwt.MapClaims{
		"iss": authtoken.IssuerName,
		"aud": []string{authtoken.Audience},
		"sub": sub,
		"iat": now.Unix(),
		"exp": now.Add(authtoken.TTL).Unix(),
	})
	t.Header["kid"] = kid
	s, err := t.SignedString(key)
	if err != nil {
		panic(err)
	}
	return s
}

// Authorization returns the authorization metadata value for sub: "Bearer " + Token(sub).
func Authorization(sub string) string {
	return "Bearer " + Token(sub)
}

// IncomingContext returns ctx with incoming metadata holding only Authorization(sub), as a
// handler called through the interceptor directly sees it.
func IncomingContext(ctx context.Context, sub string) context.Context {
	return metadata.NewIncomingContext(ctx, metadata.Pairs(callerid.AuthorizationKey, Authorization(sub)))
}

// OutgoingContext returns ctx with Authorization(sub) appended to its outgoing metadata, for a
// call through a gRPC client.
func OutgoingContext(ctx context.Context, sub string) context.Context {
	return metadata.AppendToOutgoingContext(ctx, callerid.AuthorizationKey, Authorization(sub))
}
