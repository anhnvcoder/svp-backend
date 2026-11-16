package httpx

import "net/http"

// apiContentSecurityPolicy lets a response load nothing and be framed by no page: the gateway
// serves JSON only. It is the same policy the edge sets on the API in the cloud, so a response
// carries one value whichever of the two wrote it last.
const apiContentSecurityPolicy = "default-src 'none'; frame-ancestors 'none'"

// SecurityHeaders sets the security headers of a JSON API (OWASP REST Security Cheat Sheet,
// Security Headers) on every response of next, before next runs, so error responses written by
// any inner middleware carry them too:
//
//   - X-Content-Type-Options: nosniff, so a browser never reads a JSON body as another type.
//   - Content-Security-Policy: apiContentSecurityPolicy, so a body a browser does render as a
//     page can run nothing and cannot be framed.
//   - Cache-Control: no-store, since login and refresh answer with tokens (RFC 6749 section
//     5.1) and other answers belong to one caller. A handler whose answer a cache may keep sets
//     its own Cache-Control, which replaces this one.
//
// Strict-Transport-Security and X-Frame-Options are left to the edge: HSTS means something only
// on the HTTPS connection a browser sees, which ends in front of the gateway, and frame-ancestors
// already does what X-Frame-Options did for browsers that read CSP. Pragma is not set, although
// RFC 6749 asks for Pragma: no-cache: RFC 9111 section 5.4 deprecates it and every cache reads
// Cache-Control. Referrer-Policy and Permissions-Policy only matter to pages, and CORS headers
// are not set because browsers call the web server on its own origin, never the gateway.
func SecurityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Content-Security-Policy", apiContentSecurityPolicy)
		h.Set("Cache-Control", "no-store")
		next.ServeHTTP(w, r)
	})
}
