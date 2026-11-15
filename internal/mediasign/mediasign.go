// Package mediasign signs the URLs of the segments of a premium video, so that a CDN or the object
// store serves them only to the viewer the playlist was written for, until an expiry rounded up to
// a 15-minute frame. Two signers sit behind one interface, picked by MEDIA_SIGNER: "cloudfront"
// (a CloudFront signed URL with a custom policy covering every segment of one rendition) and "s3"
// (a SigV4 presigned GET of each segment, where no CDN runs).
//
// Design notes: docs/explanation/premium-playback.md
package mediasign

import (
	"context"
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"time"

	"github.com/anhnvcoder/svp-backend/internal/envcfg"
	"github.com/anhnvcoder/svp-backend/internal/ids"
	"github.com/anhnvcoder/svp-backend/internal/objstore"
	"github.com/anhnvcoder/svp-backend/internal/secret"
)

// Signer kinds, the values of MEDIA_SIGNER.
const (
	SignerS3         = "s3"
	SignerCloudFront = "cloudfront"
)

const (
	// expiryFrame is the step every expiry is rounded up to: everyone who asks for the same
	// rendition within one frame gets the same CloudFront URL.
	expiryFrame = 15 * time.Minute
	// expiryMargin is added to the length of the video, so that a viewer who starts at once can
	// watch it to the end, with time to load and to pause briefly.
	expiryMargin = 5 * time.Minute
	// minKeyBits is the smallest RSA key accepted; CloudFront takes RSA 2048 keys.
	minKeyBits = 2048
)

// ErrScope is returned for a Rendition outside the layout of premium objects, and by a SignFunc
// for a segment outside the rendition it signs.
var ErrScope = errors.New("mediasign: outside the premium layout of the rendition")

// Rendition names the segments one signature covers: those of rendition Name in the attempt
// directory premium/<VideoID>/<Version>/<Attempt>/, named index_<Name>_<...>.
type Rendition struct {
	VideoID string
	Version string
	Attempt string
	Name    string
}

// dir is the directory of the rendition's segments.
func (r Rendition) dir() string {
	return objstore.PremiumPrefix + r.VideoID + "/" + r.Version + "/" + r.Attempt + "/"
}

// segmentPrefix starts the name of every segment of the rendition. The "_" after the name keeps
// 360p apart from 3600p.
func (r Rendition) segmentPrefix() string {
	return r.dir() + "index_" + r.Name + "_"
}

// check reports ErrScope unless VideoID, Version and Attempt are canonical UUIDs, as every key of
// the layout has them, and Name is lowercase letters and digits.
func (r Rendition) check() error {
	if r.Name == "" || strings.ContainsFunc(r.Name, func(c rune) bool { return (c < 'a' || c > 'z') && (c < '0' || c > '9') }) {
		return ErrScope
	}
	for _, id := range []string{r.VideoID, r.Version, r.Attempt} {
		if _, err := ids.Parse(id); err != nil {
			return ErrScope
		}
	}
	return nil
}

// SignFunc returns the absolute URL that lets its holder GET the segment named segment (the URI
// of a media playlist, such as index_360p_00001.ts), until the expiry of the signature. The URL
// grants read access: never log it.
type SignFunc func(segment string) (string, error)

// Signer signs the segments of one rendition at a time.
type Signer interface {
	// Rendition returns the SignFunc for the segments of r of a video of the given length, valid
	// until Expiry of the signer's clock and length.
	Rendition(ctx context.Context, r Rendition, length time.Duration) (SignFunc, error)
}

// Expiry returns the expiry of a signature made at now for a video of the given length: the
// smallest multiple of 15 minutes (Unix time) that is at least now + length + 5 minutes.
func Expiry(now time.Time, length time.Duration) time.Time {
	t := now.Add(length + expiryMargin)
	secs := t.Unix()
	if t.Nanosecond() > 0 {
		secs++
	}
	frame := int64(expiryFrame / time.Second)
	if r := secs % frame; r != 0 {
		secs += frame - r
	}
	return time.Unix(secs, 0).UTC()
}

// Config is the signing configuration of video-service, read from the environment by ReadEnv.
type Config struct {
	// Signer is SignerS3 or SignerCloudFront; the other fields are for SignerCloudFront only.
	Signer string
	// BaseURL is the https origin of the CDN the signed URLs point to, such as
	// https://media.svp.example, with no path, query or trailing "/".
	BaseURL string
	// KeyID is the ID CloudFront gave the public key of Key.
	KeyID string
	// Key is the PEM of the PKCS#8 RSA private key, of at least 2048 bits.
	Key secret.String
}

// ReadEnv reads Config from the environment and checks it:
//
//	MEDIA_SIGNER           s3 or cloudfront, required
//	MEDIA_SIGNED_BASE_URL  cloudfront: the https origin of the CDN (no path, query)
//	MEDIA_SIGNING_KEY_ID   cloudfront: the ID of the CloudFront public key
//	MEDIA_SIGNING_KEY      cloudfront: PEM of the PKCS#8 RSA private key, at least 2048 bits
//
// With s3 the three cloudfront variables must be unset. Errors name the variable, never its value.
func ReadEnv() (Config, error) {
	cfg := Config{Signer: envcfg.String("MEDIA_SIGNER", "")}
	cloudFrontVars := []string{"MEDIA_SIGNED_BASE_URL", "MEDIA_SIGNING_KEY_ID", "MEDIA_SIGNING_KEY"}
	switch cfg.Signer {
	case SignerS3:
		// A key left over would look like the one that signs while nothing uses it.
		for _, name := range cloudFrontVars {
			if envcfg.String(name, "") != "" {
				return Config{}, fmt.Errorf("%s must not be set when MEDIA_SIGNER is %s", name, SignerS3)
			}
		}
		return cfg, nil
	case SignerCloudFront:
		values := make([]string, len(cloudFrontVars))
		for i, name := range cloudFrontVars {
			v, err := envcfg.Required(name)
			if err != nil {
				return Config{}, err
			}
			values[i] = v
		}
		cfg.BaseURL, cfg.KeyID, cfg.Key = values[0], values[1], secret.New(values[2])
		if err := checkBaseURL(cfg.BaseURL); err != nil {
			return Config{}, fmt.Errorf("MEDIA_SIGNED_BASE_URL %w", err)
		}
		if err := checkKeyID(cfg.KeyID); err != nil {
			return Config{}, fmt.Errorf("MEDIA_SIGNING_KEY_ID %w", err)
		}
		if _, err := ParsePrivateKey(cfg.Key); err != nil {
			return Config{}, fmt.Errorf("MEDIA_SIGNING_KEY %w", err)
		}
		return cfg, nil
	default:
		return Config{}, fmt.Errorf("MEDIA_SIGNER must be %s or %s", SignerS3, SignerCloudFront)
	}
}

// checkBaseURL accepts an https origin and nothing else: the URL ends where the key starts, and
// the signed resource is this origin followed by the key.
func checkBaseURL(raw string) error {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.Host == "" || raw != "https://"+u.Host {
		return errors.New("must be an https origin with no path, query or trailing /, such as https://media.svp.example")
	}
	return nil
}

// checkKeyID accepts letters and digits, the form of CloudFront key IDs; the ID goes into the URL
// as it is.
func checkKeyID(id string) error {
	if id == "" || strings.ContainsFunc(id, func(c rune) bool {
		return (c < 'A' || c > 'Z') && (c < 'a' || c > 'z') && (c < '0' || c > '9')
	}) {
		return errors.New("must be letters and digits only")
	}
	return nil
}

// ParsePrivateKey reads one PEM block holding a PKCS#8 RSA private key of at least 2048 bits.
// Errors say what is wrong and never carry any part of the key.
func ParsePrivateKey(pemKey secret.String) (*rsa.PrivateKey, error) {
	block, rest := pem.Decode([]byte(pemKey.Reveal()))
	switch {
	case block == nil:
		return nil, errors.New("is not a PEM block")
	case strings.TrimSpace(string(rest)) != "":
		return nil, errors.New("holds more than one PEM block")
	case block.Type == "RSA PRIVATE KEY":
		return nil, errors.New("is PKCS#1 (BEGIN RSA PRIVATE KEY); convert it to PKCS#8 (BEGIN PRIVATE KEY)")
	case block.Type != "PRIVATE KEY":
		return nil, errors.New("is not a PKCS#8 private key (BEGIN PRIVATE KEY)")
	}
	// The parser's error is not wrapped: only the message above leaves this function.
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, errors.New("is not a valid PKCS#8 private key")
	}
	key, ok := parsed.(*rsa.PrivateKey)
	if !ok {
		return nil, errors.New("is not an RSA key")
	}
	if bits := key.N.BitLen(); bits < minKeyBits {
		return nil, fmt.Errorf("is an RSA key of %d bits, want at least %d", bits, minKeyBits)
	}
	return key, nil
}

// Presigner is what the s3 signer needs of the object store: objstore.Store.PresignGet.
type Presigner interface {
	PresignGet(ctx context.Context, key string, ttl time.Duration) (string, error)
}

// New returns the signer of cfg, which ReadEnv checked. store is used by SignerS3 only; now is the
// clock expiries are computed from (time.Now outside tests).
func New(cfg Config, store Presigner, now func() time.Time) (Signer, error) {
	switch cfg.Signer {
	case SignerS3:
		if store == nil {
			return nil, errors.New("mediasign: the s3 signer needs an object store")
		}
		return &s3Signer{store: store, now: now}, nil
	case SignerCloudFront:
		if err := checkBaseURL(cfg.BaseURL); err != nil {
			return nil, fmt.Errorf("mediasign: BaseURL %w", err)
		}
		if err := checkKeyID(cfg.KeyID); err != nil {
			return nil, fmt.Errorf("mediasign: KeyID %w", err)
		}
		key, err := ParsePrivateKey(cfg.Key)
		if err != nil {
			return nil, fmt.Errorf("mediasign: Key %w", err)
		}
		return &cloudFrontSigner{baseURL: cfg.BaseURL, keyID: cfg.KeyID, key: key, now: now}, nil
	default:
		return nil, fmt.Errorf("mediasign: Signer must be %s or %s", SignerS3, SignerCloudFront)
	}
}

// segmentKey returns the key of segment of r, or ErrScope when it is not a plain file name under
// the rendition's prefix.
func segmentKey(r Rendition, segment string) (string, error) {
	key := r.dir() + segment
	if strings.Contains(segment, "/") || !strings.HasPrefix(key, r.segmentPrefix()) ||
		!objstore.IsKeyUnder(objstore.PremiumPrefix, key, r.VideoID) {
		return "", ErrScope
	}
	return key, nil
}

// cloudFrontSigner makes CloudFront signed URLs with a custom policy.
type cloudFrontSigner struct {
	baseURL string
	keyID   string
	// A pointer, so printing the signer shows an address and not the key.
	key *rsa.PrivateKey
	now func() time.Time
}

// The custom policy, as CloudFront reads it; encoding/json writes it with no white space and the
// fields in this order.
type (
	cfPolicy struct {
		Statement []cfStatement `json:"Statement"`
	}
	cfStatement struct {
		Resource  string      `json:"Resource"`
		Condition cfCondition `json:"Condition"`
	}
	cfCondition struct {
		DateLessThan cfEpoch `json:"DateLessThan"`
	}
	cfEpoch struct {
		EpochTime int64 `json:"AWS:EpochTime"`
	}
)

// cfBase64 is the base64 CloudFront expects in a URL: standard base64 with "+", "=" and "/"
// replaced by "-", "_" and "~".
var cfBase64 = strings.NewReplacer("+", "-", "=", "_", "/", "~")

// Rendition signs one policy whose resource is every segment of r and appends the same query to
// each segment's URL.
func (s *cloudFrontSigner) Rendition(_ context.Context, r Rendition, length time.Duration) (SignFunc, error) {
	if err := r.check(); err != nil {
		return nil, err
	}
	exp := Expiry(s.now(), length)
	policy, err := json.Marshal(cfPolicy{Statement: []cfStatement{{
		Resource:  s.baseURL + "/" + r.segmentPrefix() + "*",
		Condition: cfCondition{DateLessThan: cfEpoch{EpochTime: exp.Unix()}},
	}}})
	if err != nil {
		return nil, fmt.Errorf("mediasign: policy: %w", err)
	}
	digest := sha256.Sum256(policy)
	// PKCS#1 v1.5 needs no randomness: the same policy always gets the same signature.
	sig, err := rsa.SignPKCS1v15(nil, s.key, crypto.SHA256, digest[:])
	if err != nil {
		return nil, fmt.Errorf("mediasign: sign: %w", err)
	}
	query := "Policy=" + cfBase64.Replace(base64.StdEncoding.EncodeToString(policy)) +
		"&Signature=" + cfBase64.Replace(base64.StdEncoding.EncodeToString(sig)) +
		"&Key-Pair-Id=" + s.keyID + "&Hash-Algorithm=SHA256"
	return func(segment string) (string, error) {
		key, err := segmentKey(r, segment)
		if err != nil {
			return "", err
		}
		return s.baseURL + "/" + key + "?" + query, nil
	}, nil
}

// s3Signer presigns a GET of each segment on the object store.
type s3Signer struct {
	store Presigner
	now   func() time.Time
}

// Rendition presigns each segment of r for the time left until the expiry. Each URL carries the
// time it was signed, so unlike CloudFront two requests get two URLs; only the expiry is shared.
func (s *s3Signer) Rendition(ctx context.Context, r Rendition, length time.Duration) (SignFunc, error) {
	if err := r.check(); err != nil {
		return nil, err
	}
	now := s.now()
	ttl := Expiry(now, length).Sub(now)
	return func(segment string) (string, error) {
		key, err := segmentKey(r, segment)
		if err != nil {
			return "", err
		}
		u, err := s.store.PresignGet(ctx, key, ttl)
		if err != nil {
			return "", fmt.Errorf("mediasign: presign %q: %w", segment, err)
		}
		return u, nil
	}, nil
}
