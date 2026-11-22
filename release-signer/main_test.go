package main

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

func testConfig() config {
	return config{
		audience:     "usernet-release-signer",
		repository:   "localzet/UserNet",
		repositoryID: "1450469032",
		ref:          "refs/heads/main",
		workflowRef:  "localzet/UserNet/.github/workflows/desktop-builds.yml@refs/heads/main",
		subject:      "repo:localzet@33757217/UserNet@1450469032:environment:usernet-production",
		environment:  "usernet-production",
	}
}

func TestOIDCVerifierAcceptsProtectedMainRelease(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Unix(1_800_000_000, 0)
	verifier := newOIDCVerifier(testConfig())
	verifier.now = func() time.Time { return now }
	jwksServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"keys": []any{map[string]string{
				"kid": "release-key",
				"kty": "RSA",
				"alg": "RS256",
				"use": "sig",
				"n":   base64.RawURLEncoding.EncodeToString(key.PublicKey.N.Bytes()),
				"e":   base64.RawURLEncoding.EncodeToString(big.NewInt(int64(key.PublicKey.E)).Bytes()),
			}},
		})
	}))
	defer jwksServer.Close()
	verifier.client = jwksServer.Client()
	verifier.jwksURL = jwksServer.URL

	token := signedTestToken(t, key, now, map[string]any{"ref_protected": "true"})
	claims, err := verifier.verify(token)
	if err != nil {
		t.Fatalf("verify token: %v", err)
	}
	if claims.RunID != "123456789" || claims.RunAttempt != "2" || claims.SHA != "0123456789012345678901234567890123456789" {
		t.Fatalf("unexpected claims: %#v", claims)
	}
}

func TestOIDCVerifierRejectsWrongAudience(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Unix(1_800_000_000, 0)
	verifier, closeServer := verifierWithKey(t, key, now)
	defer closeServer()
	token := signedTestToken(t, key, now, map[string]any{"aud": "another-service"})
	if _, err := verifier.verify(token); err == nil {
		t.Fatal("token with another audience was accepted")
	}
}

func TestOIDCVerifierRejectsMutableRepositorySubject(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Unix(1_800_000_000, 0)
	verifier, closeServer := verifierWithKey(t, key, now)
	defer closeServer()
	token := signedTestToken(t, key, now, map[string]any{
		"sub": "repo:localzet/UserNet:environment:usernet-production",
	})
	if _, err := verifier.verify(token); err == nil {
		t.Fatal("mutable repository subject was accepted")
	}
}

func TestOIDCVerifierRejectsUnprotectedRef(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Unix(1_800_000_000, 0)
	verifier, closeServer := verifierWithKey(t, key, now)
	defer closeServer()
	token := signedTestToken(t, key, now, map[string]any{"ref_protected": false})
	if _, err := verifier.verify(token); err == nil {
		t.Fatal("token from an unprotected ref was accepted")
	}
}

func TestOIDCVerifierRejectsInvalidSignature(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Unix(1_800_000_000, 0)
	verifier, closeServer := verifierWithKey(t, key, now)
	defer closeServer()
	parts := stringsSplitToken(signedTestToken(t, key, now, nil))
	parts[2] = base64.RawURLEncoding.EncodeToString(make([]byte, 256))
	if _, err := verifier.verify(parts[0] + "." + parts[1] + "." + parts[2]); err == nil {
		t.Fatal("token with an invalid signature was accepted")
	}
}

func TestUnknownKeyRefreshIsRateLimited(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		requests.Add(1)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"keys": []any{map[string]string{
				"kid": "known-key",
				"kty": "RSA",
				"alg": "RS256",
				"use": "sig",
				"n":   base64.RawURLEncoding.EncodeToString(key.PublicKey.N.Bytes()),
				"e":   base64.RawURLEncoding.EncodeToString(big.NewInt(int64(key.PublicKey.E)).Bytes()),
			}},
		})
	}))
	defer server.Close()

	verifier := newOIDCVerifier(testConfig())
	verifier.client = server.Client()
	verifier.jwksURL = server.URL
	verifier.now = func() time.Time { return time.Unix(1_800_000_000, 0) }

	for _, kid := range []string{"missing-1", "missing-2", "missing-3"} {
		if _, err := verifier.publicKey(kid); err == nil {
			t.Fatalf("unknown key %q was accepted", kid)
		}
	}
	if got := requests.Load(); got != 1 {
		t.Fatalf("JWKS requests=%d, want 1", got)
	}
}

func TestReplayStoreRejectsSecondUse(t *testing.T) {
	store := replayStore{dir: t.TempDir()}
	if err := store.consume("opaque-token-id"); err != nil {
		t.Fatal(err)
	}
	if err := store.consume("opaque-token-id"); err == nil {
		t.Fatal("replayed token was accepted")
	}
	entries, err := os.ReadDir(store.dir)
	if err != nil || len(entries) != 1 || filepath.Ext(entries[0].Name()) != ".used" {
		t.Fatalf("unexpected replay store contents: %v, %v", entries, err)
	}
}

func TestRequestWithoutOIDCTokenIsRejected(t *testing.T) {
	cfg := testConfig()
	svc := newService(cfg)
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/v1/sign?version=0.5.13&build=2026112201", nil)
	request.Header.Set("Content-Type", "application/vnd.android.package-archive")
	svc.handler().ServeHTTP(recorder, request)
	if recorder.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d, want %d", recorder.Code, http.StatusUnauthorized)
	}
}

func canceledContext() context.Context {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	return ctx
}

func TestBusySignerDoesNotConsumeOIDCToken(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Unix(1_800_000_000, 0)
	verifier, closeServer := verifierWithKey(t, key, now)
	defer closeServer()

	stateDir := t.TempDir()
	cfg := testConfig()
	cfg.stateDir = stateDir
	svc := newService(cfg)
	svc.verifier = verifier
	svc.busy <- struct{}{}
	token := signedTestToken(t, key, now, nil)
	request := httptest.NewRequest(http.MethodPost, "/v1/sign?version=0.5.13&build=2026112201", nil)
	request = request.WithContext(canceledContext())
	request.Header.Set("Content-Type", "application/vnd.android.package-archive")
	request.Header.Set("Authorization", "Bearer "+token)
	recorder := httptest.NewRecorder()
	svc.handler().ServeHTTP(recorder, request)
	if recorder.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d, want %d", recorder.Code, http.StatusServiceUnavailable)
	}
	entries, err := os.ReadDir(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("busy request consumed OIDC replay token: %v", entries)
	}
}

func TestParseVersionBuildRejectsUnsafeValues(t *testing.T) {
	request := httptest.NewRequest(http.MethodPost, "/v1/sign?version=0.5.13%2F..&build=2026112201", nil)
	if _, _, err := parseVersionBuild(request); err == nil {
		t.Fatal("unsafe release version was accepted")
	}
}

func verifierWithKey(t *testing.T, key *rsa.PrivateKey, now time.Time) (*oidcVerifier, func()) {
	t.Helper()
	verifier := newOIDCVerifier(testConfig())
	verifier.now = func() time.Time { return now }
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{
			"keys": []any{map[string]string{
				"kid": "release-key",
				"kty": "RSA",
				"alg": "RS256",
				"use": "sig",
				"n":   base64.RawURLEncoding.EncodeToString(key.PublicKey.N.Bytes()),
				"e":   base64.RawURLEncoding.EncodeToString(big.NewInt(int64(key.PublicKey.E)).Bytes()),
			}},
		})
	}))
	verifier.client = server.Client()
	verifier.jwksURL = server.URL
	return verifier, server.Close
}

func signedTestToken(t *testing.T, key *rsa.PrivateKey, now time.Time, overrides map[string]any) string {
	t.Helper()
	claims := map[string]any{
		"iss":           githubIssuer,
		"aud":           "usernet-release-signer",
		"sub":           "repo:localzet@33757217/UserNet@1450469032:environment:usernet-production",
		"repository":    "localzet/UserNet",
		"repository_id": "1450469032",
		"ref":           "refs/heads/main",
		"workflow_ref":  "localzet/UserNet/.github/workflows/desktop-builds.yml@refs/heads/main",
		"environment":   "usernet-production",
		"event_name":    "push",
		"sha":           "0123456789012345678901234567890123456789",
		"jti":           "unique-token-id",
		"run_id":        "123456789",
		"run_attempt":   "2",
		"ref_protected": true,
		"iat":           now.Unix(),
		"nbf":           now.Unix(),
		"exp":           now.Add(5 * time.Minute).Unix(),
	}
	for name, value := range overrides {
		claims[name] = value
	}
	header := map[string]string{"alg": "RS256", "kid": "release-key", "typ": "JWT"}
	encodedHeader, err := json.Marshal(header)
	if err != nil {
		t.Fatal(err)
	}
	encodedClaims, err := json.Marshal(claims)
	if err != nil {
		t.Fatal(err)
	}
	input := base64.RawURLEncoding.EncodeToString(encodedHeader) + "." + base64.RawURLEncoding.EncodeToString(encodedClaims)
	digest := sha256.Sum256([]byte(input))
	signature, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	return input + "." + base64.RawURLEncoding.EncodeToString(signature)
}

func stringsSplitToken(token string) []string {
	return []string{
		token[:stringsIndex(token, '.')],
		token[stringsIndex(token, '.')+1 : stringsLastIndex(token, '.')],
		token[stringsLastIndex(token, '.')+1:],
	}
}

func stringsIndex(value string, target byte) int {
	for index := range value {
		if value[index] == target {
			return index
		}
	}
	return -1
}

func stringsLastIndex(value string, target byte) int {
	for index := len(value) - 1; index >= 0; index-- {
		if value[index] == target {
			return index
		}
	}
	return -1
}

func TestNormalizeDigest(t *testing.T) {
	if got := normalizeDigest("AA:BB"); got != "aabb" {
		t.Fatalf("normalizeDigest()=%q", got)
	}
	if !isHexDigest(hex.EncodeToString(make([]byte, 32))) {
		t.Fatal("valid fingerprint rejected")
	}
}

func TestLimitedBufferCapsAndReportsTruncation(t *testing.T) {
	var buffer limitedBuffer
	buffer.limit = 4
	if written, err := buffer.Write([]byte("123456")); err != nil || written != 6 {
		t.Fatalf("Write()=(%d, %v), want (6, nil)", written, err)
	}
	if buffer.String() != "1234" || !buffer.truncated {
		t.Fatalf("buffer=%q truncated=%t", buffer.String(), buffer.truncated)
	}
}
