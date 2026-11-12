package httpx

import (
	"net"
	"net/http"
	"net/netip"
	"strconv"
	"strings"
)

// ClientAddr finds the client's address of a request. Every part of the gateway that needs it
// (the rate limits by IP, the client.address of spans) asks the same ClientAddr, so they never
// disagree on who the client is.
//
// X-Forwarded-For is a header the client writes too: anything a client puts there arrives
// first, and each proxy appends the address it received the request from. Only the elements
// appended by proxies the gateway runs behind are true, so the gateway must know how many
// there are (hops) and take the element the farthest of them appended: the hops-th from the
// right. Counting too few hops puts every client into one bucket, the address of the proxy in
// front; counting too many reads an element the client wrote, so a client gets a new IP on every
// request and slips past every limit by IP.
//
// A proxy that writes the client's address into a header of its own, which it overwrites rather
// than appends to (CloudFront-Viewer-Address), needs no hop count: the header mode reads that one
// header on connections from the trusted proxies and never X-Forwarded-For.
//
// The zero value trusts no proxy and takes the connection's address, ignoring every header: the
// safe choice when nothing is in front of the gateway (compose), since there any header comes
// straight from the client. X-Real-IP and Forwarded are never read.
type ClientAddr struct {
	hops    int
	header  string
	trusted []netip.Prefix
}

// NewClientAddr returns a ClientAddr that reads X-Forwarded-For only on connections from an
// address in trusted, and takes the hops-th element from the right. hops 0 trusts no proxy.
func NewClientAddr(hops int, trusted []netip.Prefix) ClientAddr {
	return ClientAddr{hops: hops, trusted: trusted}
}

// NewClientAddrFromHeader returns a ClientAddr in header mode: on connections from an address in
// trusted it takes the IP of the header named header, whose value is <ip>:<port> ([<ipv6>]:<port>
// accepted too), and it never reads X-Forwarded-For. trusted must not be empty, or no connection
// is ever trusted.
func NewClientAddrFromHeader(header string, trusted []netip.Prefix) ClientAddr {
	return ClientAddr{header: header, trusted: trusted}
}

// Of returns the client's address of r: an IP address, or the connection's host as it is when
// that does not parse. It falls back to the connection's address whenever the header cannot be
// trusted: the connection does not come from a trusted proxy (a client reaching the gateway
// directly), the X-Forwarded-For list has fewer than hops elements or its chosen element is not a
// bare IP address (a port or a name in it), or in header mode the header is missing, has more than
// one value or is not <ip>:<port>. Falling back puts such requests into the bucket of the
// connection, which is never an address the client chose.
func (c ClientAddr) Of(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	if c.hops == 0 && c.header == "" {
		return host
	}
	conn, err := netip.ParseAddr(host)
	if err != nil || !c.fromTrustedProxy(conn.Unmap()) {
		return host
	}
	if c.header != "" {
		if addr, ok := viewerAddr(r.Header.Values(c.header)); ok {
			return addr.String()
		}
		return host
	}
	// Several X-Forwarded-For headers make one list, in the order they arrive (RFC 9110 section
	// 5.3); the element a proxy appended may sit in the last header or in a header of its own.
	elems := strings.Split(strings.Join(r.Header.Values("X-Forwarded-For"), ","), ",")
	if len(elems) < c.hops {
		return host
	}
	addr, err := netip.ParseAddr(strings.TrimSpace(elems[len(elems)-c.hops]))
	if err != nil {
		return host
	}
	return addr.Unmap().String()
}

// viewerAddr parses the one value of a header written as <ip>:<port>: the port follows the last
// colon, so an IPv6 address may come with or without brackets. A value list (several headers, or
// a comma in one) means a second writer besides the proxy, so it is refused rather than guessed
// at; so is a zone, which no address across the internet carries.
func viewerAddr(values []string) (netip.Addr, bool) {
	if len(values) != 1 || strings.Contains(values[0], ",") {
		return netip.Addr{}, false
	}
	v := strings.TrimSpace(values[0])
	i := strings.LastIndexByte(v, ':')
	if i < 0 {
		return netip.Addr{}, false
	}
	if _, err := strconv.ParseUint(v[i+1:], 10, 16); err != nil {
		return netip.Addr{}, false
	}
	ip := v[:i]
	if strings.HasPrefix(ip, "[") && strings.HasSuffix(ip, "]") {
		ip = ip[1 : len(ip)-1]
	}
	addr, err := netip.ParseAddr(ip)
	if err != nil || addr.Zone() != "" {
		return netip.Addr{}, false
	}
	return addr.Unmap(), true
}

func (c ClientAddr) fromTrustedProxy(conn netip.Addr) bool {
	for _, p := range c.trusted {
		if p.Contains(conn) {
			return true
		}
	}
	return false
}
