// Package callerid finds the caller of a gRPC call: the gateway forwards the access token it
// verified in the authorization metadata ("Bearer <token>"), and the service verifies that token
// again with the same public keys, so a client that reaches the service directly cannot claim
// to be anyone without a token signed by user-service (threat model IN-1, IN-2).
//
// There is deliberately no helper that copies incoming metadata onward: the gateway builds
// outgoing metadata from scratch with only the values it sets.
package callerid

import (
	"context"
	"errors"
	"log/slog"
	"slices"
	"strings"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"

	"github.com/anhnvcoder/svp-backend/internal/authtoken"
	"github.com/anhnvcoder/svp-backend/internal/grpcerr"
	"github.com/anhnvcoder/svp-backend/internal/logx"
)

// AuthorizationKey is the gRPC metadata key carrying "Bearer <access token>".
const AuthorizationKey = "authorization"

// ReasonUnauthenticatedCaller is the ErrorInfo reason when the access token is missing or invalid.
const ReasonUnauthenticatedCaller = "UNAUTHENTICATED_CALLER"

type ctxKey struct{}

// Methods lists, by full method name (e.g. "/svp.user.v1.UserService/Login"), the RPCs that do
// not require a caller. Every other RPC does.
type Methods struct {
	// Public RPCs ignore authorization: they never have a caller, whatever the metadata holds.
	Public []string
	// OptionalCaller RPCs have no caller when the metadata holds no authorization. A present
	// authorization is checked as for an RPC that requires one, and an invalid one fails with
	// UNAUTHENTICATED: it is never quietly served as an anonymous call.
	OptionalCaller []string
}

// UnaryServerInterceptor requires a caller on every RPC except the full method names in public
// (e.g. "/svp.user.v1.UserService/Login"). Unless public, an RPC whose metadata does not hold
// exactly one authorization value "Bearer <token>" with a token verifier accepts fails with
// UNAUTHENTICATED before the handler runs; otherwise the token's subject goes into the context
// (FromContext) and into the log attributes as user_id. Public RPCs ignore authorization.
func UnaryServerInterceptor(verifier *authtoken.Verifier, public ...string) grpc.UnaryServerInterceptor {
	return NewUnaryServerInterceptor(verifier, Methods{Public: public})
}

// NewUnaryServerInterceptor is UnaryServerInterceptor with RPCs whose caller is optional as well
// as public ones: see Methods.
//
// Every failure (no token, two values, another scheme, a bad signature, an expired token, an
// unknown kid) answers the same status, reason and message; the detail goes to the log at INFO,
// never the token itself.
func NewUnaryServerInterceptor(verifier *authtoken.Verifier, m Methods) grpc.UnaryServerInterceptor {
	public, optional := slices.Clone(m.Public), slices.Clone(m.OptionalCaller)
	return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		if slices.Contains(public, info.FullMethod) {
			return handler(ctx, req)
		}
		md, _ := metadata.FromIncomingContext(ctx)
		values := md.Get(AuthorizationKey)
		if len(values) == 0 && slices.Contains(optional, info.FullMethod) {
			return handler(ctx, req)
		}
		userID, err := authenticate(verifier, values)
		if err != nil {
			slog.InfoContext(ctx, "caller token rejected",
				slog.String("method", info.FullMethod),
				slog.String("error", err.Error()),
			)
			return nil, unauthenticated()
		}
		ctx = context.WithValue(ctx, ctxKey{}, userID)
		ctx = logx.With(ctx, slog.String("user_id", userID))
		return handler(ctx, req)
	}
}

// authenticate returns the user id of the one "Bearer <token>" value in values. Its errors never
// hold the token.
func authenticate(verifier *authtoken.Verifier, values []string) (string, error) {
	if len(values) != 1 {
		return "", errors.New("want exactly one authorization value")
	}
	scheme, token, _ := strings.Cut(values[0], " ")
	if !strings.EqualFold(scheme, "Bearer") || token == "" {
		return "", errors.New("authorization scheme is not Bearer")
	}
	return verifier.Verify(token)
}

// FromContext returns the caller's user id put into ctx by UnaryServerInterceptor, and false
// when there is none (a public RPC, or an RPC with an optional caller called without one).
func FromContext(ctx context.Context) (string, bool) {
	id, ok := ctx.Value(ctxKey{}).(string)
	return id, ok
}

func unauthenticated() error {
	return grpcerr.New(codes.Unauthenticated, ReasonUnauthenticatedCaller, "missing or invalid caller identity")
}
