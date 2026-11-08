package kafkax

// SCRAM-SHA-512 over TLS from KAFKA_SASL_USERNAME and KAFKA_SASL_PASSWORD. The tests set the
// environment with t.Setenv and the package's testRootCAs, so none of them runs in parallel.

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"errors"
	"fmt"
	"math/big"
	"net"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/twmb/franz-go/pkg/kerr"
	"github.com/twmb/franz-go/pkg/kfake"
	"github.com/twmb/franz-go/pkg/kgo"
	"github.com/twmb/franz-go/pkg/kmsg"
)

const (
	saslUser = "svc-user"
	saslPass = "s3cret-scram-pass"
)

// testCA is a certificate authority made for one test.
type testCA struct {
	cert *x509.Certificate
	key  *ecdsa.PrivateKey
}

func newTestCA(t *testing.T) *testCA {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "kafkax test CA"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	return &testCA{cert: cert, key: key}
}

// trust makes the clients NewClient builds trust ca alone until the test ends.
func (ca *testCA) trust(t *testing.T) {
	t.Helper()
	pool := x509.NewCertPool()
	pool.AddCert(ca.cert)
	prev := testRootCAs
	testRootCAs = pool
	t.Cleanup(func() { testRootCAs = prev })
}

// serverConfig returns a broker's TLS config with a certificate ca signs for the names and IPs.
func (ca *testCA) serverConfig(t *testing.T, names []string, ips []net.IP) *tls.Config {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(2), Subject: pkix.Name{CommonName: "kafkax test broker"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames: names, IPAddresses: ips,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, ca.cert, &key.PublicKey, ca.key)
	if err != nil {
		t.Fatal(err)
	}
	return &tls.Config{MinVersion: tls.VersionTLS12,
		Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}}}
}

// localhostIPs are the addresses an in-memory broker listens on.
var localhostIPs = []net.IP{net.IPv4(127, 0, 0, 1)}

// saslCluster starts an in-memory Kafka that accepts only TLS with SCRAM-SHA-512 as saslUser
// with saslPass, with one-partition topics and the extra opts, makes the clients trust its CA
// and returns it with its broker list.
func saslCluster(t *testing.T, topics []string, opts ...kfake.Opt) (*kfake.Cluster, string) {
	t.Helper()
	ca := newTestCA(t)
	ca.trust(t)
	return startSASLCluster(t, topics, append([]kfake.Opt{kfake.TLS(ca.serverConfig(t, nil, localhostIPs))}, opts...)...)
}

// startSASLCluster starts an in-memory Kafka that accepts SCRAM-SHA-512 as saslUser with
// saslPass, over TLS only when opts say so.
func startSASLCluster(t *testing.T, topics []string, opts ...kfake.Opt) (*kfake.Cluster, string) {
	t.Helper()
	c, err := kfake.NewCluster(append([]kfake.Opt{kfake.NumBrokers(1), kfake.SeedTopics(1, topics...),
		kfake.EnableSASL(), kfake.Superuser("SCRAM-SHA-512", saslUser, saslPass)}, opts...)...)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(c.Close)
	return c, strings.Join(c.ListenAddrs(), ",")
}

// With the right credentials every client NewClient builds connects over TLS and authenticates:
// a producer, a group consumer and the dead-letter producer inside it, and a reader. The broker
// accepts only TLS, so none of them got through in plain TCP.
func TestSASLRightPassword(t *testing.T) {
	_, brokers := saslCluster(t, []string{"in", "in.dlq"})
	t.Setenv(saslUsernameVar, saslUser)
	t.Setenv(saslPasswordVar, saslPass)

	produce(t, producer(t, brokers), &kgo.Record{Topic: "in", Value: []byte("bad")})
	start(t, ConsumerConfig{Brokers: brokers, Group: "g", Topics: []string{"in"},
		Handler: func(context.Context, *kgo.Record, Attempt) error {
			return Permanent(errors.New("bad event"))
		}})

	dlq := readTopic(t, brokers, "in.dlq", 1, 15*time.Second)
	if len(dlq) != 1 || string(dlq[0].Value) != "bad" {
		t.Fatalf("dead-letter topic = %v, want the record the consumer read", dlq)
	}
}

// countSASLAuthenticate counts the SASLAuthenticate requests c receives from now on, leaving
// their handling to c.
func countSASLAuthenticate(c *kfake.Cluster) *atomic.Int32 {
	return countRequests(c, kmsg.SASLAuthenticate)
}

// countRequests counts the requests of key c receives from now on, leaving their handling to c.
func countRequests(c *kfake.Cluster, key kmsg.Key) *atomic.Int32 {
	var n atomic.Int32
	c.ControlKey(int16(key), func(kmsg.Request) (kmsg.Response, error, bool) {
		c.KeepControl()
		n.Add(1)
		return nil, nil, false
	})
	return &n
}

// tlsRefused checks that a client NewClient builds for brokers sends nothing to c, the
// SASLHandshake that starts authentication included, fails Produce at its deadline, and logs a
// connection WARN whose error contains wantErr, the password nowhere.
func tlsRefused(t *testing.T, c *kfake.Cluster, brokers, wantErr string) {
	t.Helper()
	const wrong = "never-sent-pass"
	t.Setenv(saslUsernameVar, saslUser)
	t.Setenv(saslPasswordVar, wrong)
	handshakes := countRequests(c, kmsg.SASLHandshake)
	logs := defaultLogs(t)
	// A broker without TLS reads the ClientHello as the size of a request and waits for the rest,
	// so the handshake ends only at the dial timeout, 10 s by default; a Kafka broker closes the
	// connection at once, as the size is over its socket.request.max.bytes.
	cl, err := NewClient(brokers, "test-producer", kgo.DialTimeout(250*time.Millisecond))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(cl.Close)
	ctx, cancel := context.WithTimeout(t.Context(), time.Second)
	defer cancel()

	err = produceWithin(t, 10*time.Second, ctx, cl, &kgo.Record{Topic: "out", Value: []byte("v")})
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Errorf("Produce() = %v, want the call's deadline", err)
	}
	if n := handshakes.Load(); n != 0 {
		t.Errorf("the broker got %d SASL handshakes, want none before TLS is set up", n)
	}
	var warned bool
	for _, prefix := range []string{"kafka client: unable to open connection to broker",
		"kafka client: unable to open connection to broker due to an immediate EOF, which often means the client is using TLS when the broker is not expecting it (is TLS misconfigured?)"} {
		for _, rec := range logs.records(t, prefix) {
			if rec["level"] == "WARN" && rec["addr"] == brokers && strings.Contains(fmt.Sprint(rec["err"]), wantErr) {
				warned = true
			}
		}
	}
	if !warned {
		t.Errorf("no connection WARN naming %q for %s; the log:\n%s", wantErr, brokers, logs)
	}
	if strings.Contains(logs.String(), wrong) {
		t.Error("the log carries the password")
	}
	if err != nil && strings.Contains(err.Error(), wrong) {
		t.Errorf("Produce() error %q carries the password", err)
	}
}

// A broker without TLS gets no request from a client with credentials: the client does not fall
// back to plain TCP, and the failed handshake shows in the log.
func TestTLSPlaintextBrokerRefused(t *testing.T) {
	c, brokers := startSASLCluster(t, []string{"out"})
	tlsRefused(t, c, brokers, "")
}

// A broker whose certificate does not name its host, or comes from a CA the client does not
// trust, is refused before any SASL request, and the log names the certificate error.
func TestTLSCertificateRefused(t *testing.T) {
	t.Run("wrong name", func(t *testing.T) {
		ca := newTestCA(t)
		ca.trust(t)
		c, brokers := startSASLCluster(t, []string{"out"},
			kfake.TLS(ca.serverConfig(t, []string{"kafka.example"}, nil)))
		tlsRefused(t, c, brokers, "certificate")
	})
	t.Run("unknown CA", func(t *testing.T) {
		newTestCA(t).trust(t)
		c, brokers := startSASLCluster(t, []string{"out"},
			kfake.TLS(newTestCA(t).serverConfig(t, nil, localhostIPs)))
		tlsRefused(t, c, brokers, "certificate")
	})
}

// With a wrong password kfake checks the SCRAM proof, fails it with "invalid password" and drops
// the connection. franz-go takes that as a broken connection and retries it with backoff, so
// Produce fails at its deadline, not earlier with an authentication error; neither its error nor
// the client's debug log carries a password. A Kafka broker answers the proof with an error
// instead, which the client logs: TestSASLAuthenticationFailedIsLogged.
func TestSASLWrongPassword(t *testing.T) {
	brokerLog := &lockedBuffer{}
	_, brokers := saslCluster(t, []string{"out"}, kfake.WithLogger(kfake.BasicLogger(brokerLog, kfake.LogLevelInfo)))
	const wrong = "wrong-scram-pass"
	t.Setenv(saslUsernameVar, saslUser)
	t.Setenv(saslPasswordVar, wrong)
	logs := &lockedBuffer{}
	cl, err := NewClient(brokers, "test-producer", kgo.WithLogger(kgo.BasicLogger(logs, kgo.LogLevelDebug, nil)))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(cl.Close)
	const deadline = time.Second
	ctx, cancel := context.WithTimeout(t.Context(), deadline)
	defer cancel()

	started := time.Now()
	err = produceWithin(t, 10*time.Second, ctx, cl, &kgo.Record{Topic: "out", Value: []byte("v")})
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Errorf("Produce() = %v, want the call's deadline", err)
	}
	if elapsed, limit := time.Since(started), deadline+2*time.Second; elapsed > limit {
		t.Errorf("Produce() returned after %v, want at most %v", elapsed, limit)
	}
	// kfake returns this error only once the proof does not match the stored SCRAM key, so the
	// client got through the whole exchange and the broker refused the password itself.
	if !strings.Contains(brokerLog.String(), "request unable to be handled: invalid password") {
		t.Errorf("the broker never refused the SCRAM proof; its log:\n%s", brokerLog)
	}
	if err != nil && strings.Contains(err.Error(), wrong) {
		t.Errorf("Produce() error %q carries the password", err)
	}
	if strings.Contains(logs.String(), wrong) {
		t.Error("the client's debug log carries the password")
	}
}

// answerAuthenticationFailed makes c answer the client's SCRAM proof with
// SASL_AUTHENTICATION_FAILED, as a Kafka broker answers a wrong password (KIP-152: every
// SaslAuthenticate request gets a response, a failed one an error code and message).
func answerAuthenticationFailed(c *kfake.Cluster) {
	c.ControlKey(int16(kmsg.SASLAuthenticate), func(kr kmsg.Request) (kmsg.Response, error, bool) {
		c.KeepControl()
		req := kr.(*kmsg.SASLAuthenticateRequest)
		// The client-final-message, the one carrying the proof, starts with its channel binding;
		// kfake handles the client-first-message as usual.
		if !bytes.HasPrefix(req.SASLAuthBytes, []byte("c=")) {
			return nil, nil, false
		}
		resp := req.ResponseKind().(*kmsg.SASLAuthenticateResponse)
		resp.ErrorCode = kerr.SaslAuthenticationFailed.Code
		msg := "Authentication failed: invalid credentials"
		resp.ErrorMessage = &msg
		return resp, nil, true
	})
}

// A broker refusing the credentials shows in the service's log: through the default slog logger
// the client logs an ERROR naming SASL_AUTHENTICATION_FAILED for each attempt, at franz-go's
// retry backoff, and neither that log nor Produce's error carries the password.
func TestSASLAuthenticationFailedIsLogged(t *testing.T) {
	c, brokers := saslCluster(t, []string{"out"})
	answerAuthenticationFailed(c)
	const wrong = "wrong-scram-pass"
	t.Setenv(saslUsernameVar, saslUser)
	t.Setenv(saslPasswordVar, wrong)
	logs := defaultLogs(t)
	cl := producer(t, brokers)
	ctx, cancel := context.WithTimeout(t.Context(), time.Second)
	defer cancel()

	err := produceWithin(t, 10*time.Second, ctx, cl, &kgo.Record{Topic: "out", Value: []byte("v")})
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Errorf("Produce() = %v, want the call's deadline", err)
	}
	failures := logs.records(t, "kafka client: unable to initialize sasl")
	// Measured: 6 in 10 s, the backoff growing after each attempt; a client retrying in a tight
	// loop would log thousands.
	if n := len(failures); n == 0 || n > 10 {
		t.Errorf("%d SASL failures logged in %v, want some, at most 10", n, time.Second)
	}
	for _, rec := range failures {
		if rec["level"] != "ERROR" || !strings.Contains(fmt.Sprint(rec["err"]), "SASL_AUTHENTICATION_FAILED") {
			t.Errorf("SASL failure logged as %v, want an ERROR naming SASL_AUTHENTICATION_FAILED", rec)
		}
	}
	if strings.Contains(logs.String(), wrong) {
		t.Error("the log carries the password")
	}
	if err != nil && strings.Contains(err.Error(), wrong) {
		t.Errorf("Produce() error %q carries the password", err)
	}
}

// A consumer with a wrong password retries authentication at the client's backoff instead of
// spinning, handles nothing, and stops cleanly when asked.
func TestSASLWrongPasswordConsumerBacksOff(t *testing.T) {
	c, brokers := saslCluster(t, []string{"in", "in.dlq"})
	t.Setenv(saslUsernameVar, saslUser)
	t.Setenv(saslPasswordVar, "wrong-scram-pass")
	attempts := countSASLAuthenticate(c)
	var calls atomic.Int32
	r := start(t, ConsumerConfig{Brokers: brokers, Group: "g", Topics: []string{"in"},
		Handler: func(context.Context, *kgo.Record, Attempt) error {
			calls.Add(1)
			return nil
		}})

	const window = 3 * time.Second
	time.Sleep(window)
	// Measured: about 6 a second, paced by franz-go's retry backoff; a client spinning on the
	// error would make thousands.
	if n := attempts.Load(); n == 0 || n > 60 {
		t.Errorf("%d SASL authentications in %v, want some, at most 60", n, window)
	}
	if err := r.stop(t); err != nil {
		t.Errorf("Run() = %v, want nil once stopped", err)
	}
	if n := calls.Load(); n != 0 {
		t.Errorf("handler called %d times without an authenticated connection", n)
	}
}

// Only one of the two variables set: NewClient fails, naming the missing variable and carrying
// no value. An empty variable counts as unset.
func TestNewClientSASLMissingVariable(t *testing.T) {
	tests := []struct {
		name, user, pass, missing string
	}{
		{"password unset", saslUser, "", saslPasswordVar},
		{"username unset", "", saslPass, saslUsernameVar},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Setenv(saslUsernameVar, tt.user)
			t.Setenv(saslPasswordVar, tt.pass)
			cl, err := NewClient("127.0.0.1:9092", "svc")
			if err == nil {
				cl.Close()
				t.Fatal("NewClient() = nil error, want the missing variable")
			}
			if msg := err.Error(); !strings.Contains(msg, tt.missing+" is not") ||
				strings.Contains(msg, saslPass) || strings.Contains(msg, saslUser) {
				t.Errorf("NewClient() error = %q, want it to name %s and carry no value", msg, tt.missing)
			}
		})
	}
}

// Both variables set but empty count as unset: no SASL and no TLS, so a broker without
// authentication, as only the in-memory brokers of the tests are, takes the client.
func TestNewClientSASLEmptyVariables(t *testing.T) {
	t.Setenv(saslUsernameVar, "")
	t.Setenv(saslPasswordVar, "")
	produce(t, producer(t, cluster(t, 1, "out")), &kgo.Record{Topic: "out", Value: []byte("v")})
}
