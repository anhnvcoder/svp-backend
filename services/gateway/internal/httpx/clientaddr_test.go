package httpx

import (
	"net/http"
	"net/http/httptest"
	"net/netip"
	"testing"
)

func TestClientAddr(t *testing.T) {
	t.Parallel()
	pods := []netip.Prefix{netip.MustParsePrefix("10.42.0.0/16"), netip.MustParsePrefix("fd00:42::/56")}
	envoy := NewClientAddr(1, pods)
	twoHops := NewClientAddr(2, pods)
	for _, tt := range []struct {
		name   string
		from   ClientAddr
		remote string
		xff    []string // one X-Forwarded-For header per element
		want   string
	}{
		{"no proxy ignores the header", ClientAddr{}, "192.0.2.1:5000", []string{"203.0.113.7"}, "192.0.2.1"},
		{"no proxy, ipv6 connection", ClientAddr{}, "[2001:db8::1]:5000", []string{"203.0.113.7"}, "2001:db8::1"},
		{"no proxy, connection without port", ClientAddr{}, "192.0.2.1", nil, "192.0.2.1"},
		{"no proxy, connection not an address", ClientAddr{}, "pipe", nil, "pipe"},
		{"trusted proxy, one element", envoy, "10.42.0.7:5000", []string{"198.51.100.9"}, "198.51.100.9"},
		{"trusted proxy, forged element before the real one", envoy, "10.42.0.7:5000", []string{"203.0.113.7, 198.51.100.9"}, "198.51.100.9"},
		{"trusted proxy, forged name before the real one", envoy, "10.42.0.7:5000", []string{"a@example.com, 198.51.100.9"}, "198.51.100.9"},
		{"several headers make one list", envoy, "10.42.0.7:5000", []string{"203.0.113.7, 203.0.113.8", "198.51.100.9"}, "198.51.100.9"},
		{"spaces and tabs are trimmed", envoy, "10.42.0.7:5000", []string{"  203.0.113.7 ,\t198.51.100.9  "}, "198.51.100.9"},
		{"ipv4-mapped element is unmapped", envoy, "10.42.0.7:5000", []string{"::ffff:198.51.100.9"}, "198.51.100.9"},
		{"ipv4-mapped connection is trusted", envoy, "[::ffff:10.42.0.7]:5000", []string{"198.51.100.9"}, "198.51.100.9"},
		{"ipv6 proxy and ipv6 client", envoy, "[fd00:42::7]:5000", []string{"2001:db8::9"}, "2001:db8::9"},
		{"ipv6 element with a zone", envoy, "10.42.0.7:5000", []string{"fe80::1%eth0"}, "fe80::1%eth0"},
		{"connection with a zone is not trusted", NewClientAddr(1, []netip.Prefix{netip.MustParsePrefix("fe80::/10")}), "[fe80::1%en0]:5000", []string{"198.51.100.9"}, "fe80::1%en0"},
		{"ipv4 element with a port", envoy, "10.42.0.7:5000", []string{"198.51.100.9:443"}, "10.42.0.7"},
		{"ipv6 element with a port", envoy, "10.42.0.7:5000", []string{"[2001:db8::9]:443"}, "10.42.0.7"},
		{"element not an address", envoy, "10.42.0.7:5000", []string{"unknown"}, "10.42.0.7"},
		{"empty last element", envoy, "10.42.0.7:5000", []string{"198.51.100.9,"}, "10.42.0.7"},
		{"no header", envoy, "10.42.0.7:5000", nil, "10.42.0.7"},
		{"untrusted connection ignores the header", envoy, "192.0.2.1:5000", []string{"198.51.100.9"}, "192.0.2.1"},
		{"connection just outside the range", envoy, "10.43.0.7:5000", []string{"198.51.100.9"}, "10.43.0.7"},
		{"two hops take the second from the right", twoHops, "10.42.0.7:5000", []string{"203.0.113.7, 198.51.100.9, 10.0.0.5"}, "198.51.100.9"},
		{"two hops over headers", twoHops, "10.42.0.7:5000", []string{"198.51.100.9", "10.0.0.5"}, "198.51.100.9"},
		{"list shorter than the hops", twoHops, "10.42.0.7:5000", []string{"198.51.100.9"}, "10.42.0.7"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			r := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/x", nil)
			r.RemoteAddr = tt.remote
			for _, v := range tt.xff {
				r.Header.Add("X-Forwarded-For", v)
			}
			r.Header.Set("X-Real-IP", "203.0.113.8")
			r.Header.Set("Forwarded", "for=203.0.113.9")
			if got := tt.from.Of(r); got != tt.want {
				t.Errorf("Of = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestClientAddrFromHeader(t *testing.T) {
	t.Parallel()
	const header = "CloudFront-Viewer-Address"
	vpc := NewClientAddrFromHeader(header, []netip.Prefix{netip.MustParsePrefix("10.0.0.0/16"), netip.MustParsePrefix("fd00:42::/56")})
	for _, tt := range []struct {
		name   string
		from   ClientAddr
		remote string
		values []string // one header per element
		want   string
	}{
		{"ipv4 with port", vpc, "10.0.3.7:5000", []string{"198.51.100.9:46532"}, "198.51.100.9"},
		{"ipv6 without brackets", vpc, "10.0.3.7:5000", []string{"2001:db8::9:60776"}, "2001:db8::9"},
		{"ipv6 in brackets", vpc, "10.0.3.7:5000", []string{"[2001:db8::9]:60776"}, "2001:db8::9"},
		{"ipv6 in canonical form", vpc, "10.0.3.7:5000", []string{"2001:0DB8:0:0::9:443"}, "2001:db8::9"},
		{"ipv4-mapped is unmapped", vpc, "10.0.3.7:5000", []string{"::ffff:198.51.100.9:80"}, "198.51.100.9"},
		{"ipv4-mapped in brackets is unmapped", vpc, "10.0.3.7:5000", []string{"[::ffff:198.51.100.9]:80"}, "198.51.100.9"},
		{"port zero", vpc, "10.0.3.7:5000", []string{"10.0.9.4:0"}, "10.0.9.4"},
		{"spaces and tabs are trimmed", vpc, "10.0.3.7:5000", []string{" \t198.51.100.9:443\t "}, "198.51.100.9"},
		{"ipv6 proxy", vpc, "[fd00:42::7]:5000", []string{"198.51.100.9:443"}, "198.51.100.9"},
		{"ipv4-mapped connection is trusted", vpc, "[::ffff:10.0.3.7]:5000", []string{"198.51.100.9:443"}, "198.51.100.9"},
		{"without port", vpc, "10.0.3.7:5000", []string{"198.51.100.9"}, "10.0.3.7"},
		{"ipv6 without port", vpc, "10.0.3.7:5000", []string{"[2001:db8::9]"}, "10.0.3.7"},
		{"empty port", vpc, "10.0.3.7:5000", []string{"198.51.100.9:"}, "10.0.3.7"},
		{"port not a number", vpc, "10.0.3.7:5000", []string{"198.51.100.9:https"}, "10.0.3.7"},
		{"port with a sign", vpc, "10.0.3.7:5000", []string{"198.51.100.9:+443"}, "10.0.3.7"},
		{"port above 65535", vpc, "10.0.3.7:5000", []string{"198.51.100.9:65536"}, "10.0.3.7"},
		{"zone", vpc, "10.0.3.7:5000", []string{"fe80::1%eth0:443"}, "10.0.3.7"},
		{"zone in brackets", vpc, "10.0.3.7:5000", []string{"[fe80::1%eth0]:443"}, "10.0.3.7"},
		{"name instead of an address", vpc, "10.0.3.7:5000", []string{"example.com:443"}, "10.0.3.7"},
		{"empty value", vpc, "10.0.3.7:5000", []string{""}, "10.0.3.7"},
		{"two headers", vpc, "10.0.3.7:5000", []string{"203.0.113.7:1", "198.51.100.9:443"}, "10.0.3.7"},
		{"two headers, same value", vpc, "10.0.3.7:5000", []string{"198.51.100.9:443", "198.51.100.9:443"}, "10.0.3.7"},
		{"comma in one header", vpc, "10.0.3.7:5000", []string{"203.0.113.7:1, 198.51.100.9:443"}, "10.0.3.7"},
		{"trailing comma", vpc, "10.0.3.7:5000", []string{"198.51.100.9:443,"}, "10.0.3.7"},
		{"missing header ignores X-Forwarded-For", vpc, "10.0.3.7:5000", nil, "10.0.3.7"},
		{"untrusted connection ignores the header", vpc, "192.0.2.1:5000", []string{"198.51.100.9:443"}, "192.0.2.1"},
		{"connection just outside the range", vpc, "10.1.0.7:5000", []string{"198.51.100.9:443"}, "10.1.0.7"},
		{"connection not an address", vpc, "pipe", []string{"198.51.100.9:443"}, "pipe"},
		{"no trusted range trusts nothing", NewClientAddrFromHeader(header, nil), "10.0.3.7:5000", []string{"198.51.100.9:443"}, "10.0.3.7"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			r := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/x", nil)
			r.RemoteAddr = tt.remote
			for _, v := range tt.values {
				r.Header.Add(header, v)
			}
			r.Header.Set("X-Forwarded-For", "203.0.113.7, 198.51.100.8")
			r.Header.Set("X-Real-IP", "203.0.113.8")
			r.Header.Set("Forwarded", "for=203.0.113.9")
			if got := tt.from.Of(r); got != tt.want {
				t.Errorf("Of = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestClientAddrFromHeaderMatchesAnyCase(t *testing.T) {
	t.Parallel()
	c := NewClientAddrFromHeader("cloudfront-viewer-address", []netip.Prefix{netip.MustParsePrefix("10.0.0.0/16")})
	r := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/x", nil)
	r.RemoteAddr = "10.0.3.7:5000"
	r.Header.Set("CloudFront-Viewer-Address", "198.51.100.9:443")
	if got := c.Of(r); got != "198.51.100.9" {
		t.Errorf("Of = %q, want 198.51.100.9", got)
	}
}
