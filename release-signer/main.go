package main

import (
	"bytes"
	"context"
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"math/big"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	githubIssuer  = "https://token.actions.githubusercontent.com"
	githubJWKSURL = "https://token.actions.githubusercontent.com/.well-known/jwks"
	maxTokenBytes = 16 * 1024
	maxAPKBytes   = 512 << 20
	maxOTABundle  = 2 << 30
)

var (
	versionPattern = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+$`)
	buildPattern   = regexp.MustCompile(`^[0-9]{10}$`)
	shaPattern     = regexp.MustCompile(`^[0-9a-fA-F]{40}$`)
	packagePattern = regexp.MustCompile(`(?m)^package: name='([^']+)' versionCode='([0-9]+)' versionName='([^']*)'`)
	digestPattern  = regexp.MustCompile(`(?m)^Signer #[0-9]+ certificate SHA-256 digest: ([0-9a-fA-F]{64})$`)
)

type config struct {
	listenAddr       string
	audience         string
	repository       string
	repositoryID     string
	ref              string
	workflowRef      string
	subject          string
	environment      string
	expectedCertHash string
	keystorePath     string
	passwordPath     string
	keystoreAlias    string
	apksignerPath    string
	aaptPath         string
	pythonPath       string
	otaScriptPath    string
	otaRoot          string
	stateDir         string
	tmpDir           string
}

func loadConfig() (config, error) {
	cfg := config{
		listenAddr:       envOr("USERNET_SIGNER_ADDR", ":8080"),
		audience:         os.Getenv("USERNET_SIGNER_AUDIENCE"),
		repository:       os.Getenv("USERNET_SIGNER_REPOSITORY"),
		repositoryID:     os.Getenv("USERNET_SIGNER_REPOSITORY_ID"),
		ref:              os.Getenv("USERNET_SIGNER_REF"),
		workflowRef:      os.Getenv("USERNET_SIGNER_WORKFLOW_REF"),
		subject:          os.Getenv("USERNET_SIGNER_SUBJECT"),
		environment:      os.Getenv("USERNET_SIGNER_ENVIRONMENT"),
		expectedCertHash: normalizeDigest(os.Getenv("USERNET_SIGNER_CERT_SHA256")),
		keystorePath:     os.Getenv("USERNET_SIGNER_KEYSTORE"),
		passwordPath:     os.Getenv("USERNET_SIGNER_PASSWORD_FILE"),
		keystoreAlias:    envOr("USERNET_SIGNER_KEY_ALIAS", "usernet"),
		apksignerPath:    os.Getenv("USERNET_SIGNER_APKSIGNER"),
		aaptPath:         os.Getenv("USERNET_SIGNER_AAPT"),
		pythonPath:       envOr("USERNET_SIGNER_PYTHON", "python3"),
		otaScriptPath:    os.Getenv("USERNET_SIGNER_OTA_SCRIPT"),
		otaRoot:          os.Getenv("USERNET_SIGNER_OTA_ROOT"),
		stateDir:         os.Getenv("USERNET_SIGNER_STATE_DIR"),
		tmpDir:           envOr("USERNET_SIGNER_TMP_DIR", "/tmp"),
	}
	for name, value := range map[string]string{
		"USERNET_SIGNER_AUDIENCE":      cfg.audience,
		"USERNET_SIGNER_REPOSITORY":    cfg.repository,
		"USERNET_SIGNER_REPOSITORY_ID": cfg.repositoryID,
		"USERNET_SIGNER_REF":           cfg.ref,
		"USERNET_SIGNER_WORKFLOW_REF":  cfg.workflowRef,
		"USERNET_SIGNER_SUBJECT":       cfg.subject,
		"USERNET_SIGNER_ENVIRONMENT":   cfg.environment,
		"USERNET_SIGNER_CERT_SHA256":   cfg.expectedCertHash,
		"USERNET_SIGNER_KEYSTORE":      cfg.keystorePath,
		"USERNET_SIGNER_PASSWORD_FILE": cfg.passwordPath,
		"USERNET_SIGNER_APKSIGNER":     cfg.apksignerPath,
		"USERNET_SIGNER_AAPT":          cfg.aaptPath,
		"USERNET_SIGNER_OTA_SCRIPT":    cfg.otaScriptPath,
		"USERNET_SIGNER_OTA_ROOT":      cfg.otaRoot,
		"USERNET_SIGNER_STATE_DIR":     cfg.stateDir,
	} {
		if value == "" {
			return config{}, fmt.Errorf("missing required setting %s", name)
		}
	}
	if !isHexDigest(cfg.expectedCertHash) {
		return config{}, errors.New("invalid expected APK signer fingerprint")
	}
	if cfg.audience != "usernet-release-signer" ||
		cfg.repository != "localzet/UserNet" || cfg.repositoryID != "1450469032" ||
		cfg.ref != "refs/heads/main" ||
		cfg.workflowRef != "localzet/UserNet/.github/workflows/desktop-builds.yml@refs/heads/main" ||
		cfg.subject != "repo:localzet@33757217/UserNet@1450469032:environment:usernet-production" ||
		cfg.environment != "usernet-production" ||
		!isPositiveDecimal(cfg.repositoryID) {
		return config{}, errors.New("invalid signer configuration")
	}
	for name, path := range map[string]string{
		"keystore":      cfg.keystorePath,
		"password file": cfg.passwordPath,
		"apksigner":     cfg.apksignerPath,
		"aapt":          cfg.aaptPath,
		"OTA script":    cfg.otaScriptPath,
	} {
		info, err := os.Lstat(path)
		if err != nil {
			return config{}, fmt.Errorf("%s path is unavailable", name)
		}
		if info.Mode()&os.ModeSymlink != 0 && (name == "apksigner" || name == "aapt") {
			resolved, resolveErr := filepath.EvalSymlinks(path)
			if resolveErr != nil {
				return config{}, fmt.Errorf("%s path is unavailable", name)
			}
			info, err = os.Stat(resolved)
			if err != nil {
				return config{}, fmt.Errorf("%s path is unavailable", name)
			}
			if name == "apksigner" {
				cfg.apksignerPath = resolved
			} else {
				cfg.aaptPath = resolved
			}
		} else if info.Mode()&os.ModeSymlink != 0 {
			return config{}, fmt.Errorf("%s path is unavailable", name)
		}
		if name == "OTA script" {
			if !info.Mode().IsRegular() {
				return config{}, errors.New("OTA script is not a regular file")
			}
		} else if name == "keystore" || name == "password file" {
			if !info.Mode().IsRegular() {
				return config{}, fmt.Errorf("%s is not a regular file", name)
			}
			if info.Mode().Perm()&0077 != 0 {
				return config{}, fmt.Errorf("%s permissions are too broad", name)
			}
		} else if !info.Mode().IsRegular() || info.Mode()&0111 == 0 {
			return config{}, fmt.Errorf("%s is not executable", name)
		}
	}
	otaInfo, err := os.Stat(cfg.otaRoot)
	if err != nil || !otaInfo.IsDir() {
		return config{}, errors.New("OTA release directory is unavailable")
	}
	if err := os.MkdirAll(cfg.stateDir, 0700); err != nil {
		return config{}, errors.New("signer state directory is unavailable")
	}
	if err := os.Chmod(cfg.stateDir, 0700); err != nil {
		return config{}, errors.New("signer state directory permissions are invalid")
	}
	if err := os.MkdirAll(cfg.tmpDir, 0700); err != nil {
		return config{}, errors.New("signer temporary directory is unavailable")
	}
	return cfg, nil
}

func envOr(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

type idClaims struct {
	Issuer       string          `json:"iss"`
	Audience     json.RawMessage `json:"aud"`
	Subject      string          `json:"sub"`
	Repository   string          `json:"repository"`
	RepositoryID string          `json:"repository_id"`
	Ref          string          `json:"ref"`
	WorkflowRef  string          `json:"workflow_ref"`
	Environment  string          `json:"environment"`
	EventName    string          `json:"event_name"`
	SHA          string          `json:"sha"`
	JTI          string          `json:"jti"`
	RunID        json.RawMessage `json:"run_id"`
	RunAttempt   json.RawMessage `json:"run_attempt"`
	IssuedAt     int64           `json:"iat"`
	NotBefore    int64           `json:"nbf"`
	ExpiresAt    int64           `json:"exp"`
	RefProtected json.RawMessage `json:"ref_protected"`
}

type tokenClaims struct {
	RunID      string
	RunAttempt string
	SHA        string
	JTI        string
}

type jwtHeader struct {
	Algorithm string `json:"alg"`
	KeyID     string `json:"kid"`
	Type      string `json:"typ"`
}

type jwks struct {
	Keys []jwk `json:"keys"`
}

type jwk struct {
	KeyID     string `json:"kid"`
	KeyType   string `json:"kty"`
	Algorithm string `json:"alg"`
	Use       string `json:"use"`
	Modulus   string `json:"n"`
	Exponent  string `json:"e"`
}

type oidcVerifier struct {
	cfg                config
	client             *http.Client
	keysMu             sync.Mutex
	keys               map[string]*rsa.PublicKey
	keysUntil          time.Time
	lastRefreshAttempt time.Time
	jwksURL            string
	now                func() time.Time
}

func newOIDCVerifier(cfg config) *oidcVerifier {
	return &oidcVerifier{
		cfg:     cfg,
		client:  &http.Client{Timeout: 10 * time.Second},
		keys:    make(map[string]*rsa.PublicKey),
		jwksURL: githubJWKSURL,
		now:     time.Now,
	}
}

func (v *oidcVerifier) verify(token string) (tokenClaims, error) {
	if len(token) == 0 || len(token) > maxTokenBytes {
		return tokenClaims{}, errors.New("invalid token size")
	}
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return tokenClaims{}, errors.New("malformed token")
	}
	headerBytes, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return tokenClaims{}, errors.New("malformed token header")
	}
	var header jwtHeader
	if err := json.Unmarshal(headerBytes, &header); err != nil ||
		header.Algorithm != "RS256" || header.KeyID == "" || header.Type != "JWT" {
		return tokenClaims{}, errors.New("unsupported token header")
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return tokenClaims{}, errors.New("malformed token payload")
	}
	var claims idClaims
	if err := json.Unmarshal(payload, &claims); err != nil {
		return tokenClaims{}, errors.New("malformed token claims")
	}
	key, err := v.publicKey(header.KeyID)
	if err != nil {
		return tokenClaims{}, errors.New("unknown token signing key")
	}
	signature, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return tokenClaims{}, errors.New("malformed token signature")
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if err := rsa.VerifyPKCS1v15(key, crypto.SHA256, digest[:], signature); err != nil {
		return tokenClaims{}, errors.New("invalid token signature")
	}
	if err := v.validateClaims(claims); err != nil {
		return tokenClaims{}, err
	}
	runID, err := rawStringOrNumber(claims.RunID)
	if err != nil || !isPositiveDecimal(runID) {
		return tokenClaims{}, errors.New("invalid workflow run identity")
	}
	runAttempt, err := rawStringOrNumber(claims.RunAttempt)
	if err != nil || !isPositiveDecimal(runAttempt) {
		return tokenClaims{}, errors.New("invalid workflow attempt identity")
	}
	return tokenClaims{RunID: runID, RunAttempt: runAttempt, SHA: claims.SHA, JTI: claims.JTI}, nil
}

func (v *oidcVerifier) validateClaims(c idClaims) error {
	now := v.now().Unix()
	if c.Issuer != githubIssuer || c.Subject != v.cfg.subject || c.Repository != v.cfg.repository ||
		c.RepositoryID != v.cfg.repositoryID || c.Ref != v.cfg.ref || c.WorkflowRef != v.cfg.workflowRef ||
		c.Environment != v.cfg.environment || c.JTI == "" || !shaPattern.MatchString(c.SHA) {
		return errors.New("token is outside the authorized release identity")
	}
	if c.EventName != "push" && c.EventName != "workflow_dispatch" {
		return errors.New("token event is not a main-branch release")
	}
	if !rawTrue(c.RefProtected) {
		return errors.New("token ref is not protected")
	}
	if !audienceContains(c.Audience, v.cfg.audience) {
		return errors.New("token audience is not authorized")
	}
	if c.ExpiresAt <= now || c.IssuedAt > now+60 || c.NotBefore > now+60 || c.IssuedAt <= 0 || c.ExpiresAt <= c.IssuedAt {
		return errors.New("token is outside its validity period")
	}
	if c.ExpiresAt-c.IssuedAt > 15*60 || now-c.IssuedAt > 15*60 {
		return errors.New("token validity window is too long")
	}
	return nil
}

func (v *oidcVerifier) publicKey(kid string) (*rsa.PublicKey, error) {
	v.keysMu.Lock()
	defer v.keysMu.Unlock()
	now := v.now()
	if key := v.keys[kid]; key != nil && now.Before(v.keysUntil) {
		return key, nil
	}
	if !v.lastRefreshAttempt.IsZero() && now.Sub(v.lastRefreshAttempt) < time.Minute {
		return nil, errors.New("signing key is not available")
	}
	v.lastRefreshAttempt = now
	if err := v.refreshKeys(); err != nil {
		return nil, err
	}
	key := v.keys[kid]
	if key == nil {
		return nil, errors.New("key id not present in GitHub JWKS")
	}
	return key, nil
}

func (v *oidcVerifier) refreshKeys() error {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, v.jwksURL, nil)
	if err != nil {
		return err
	}
	response, err := v.client.Do(req)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("JWKS returned HTTP %d", response.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, 64*1024+1))
	if err != nil || len(data) > 64*1024 {
		return errors.New("invalid JWKS response")
	}
	var set jwks
	if err := json.Unmarshal(data, &set); err != nil || len(set.Keys) == 0 || len(set.Keys) > 20 {
		return errors.New("invalid JWKS document")
	}
	keys := make(map[string]*rsa.PublicKey)
	for _, candidate := range set.Keys {
		if candidate.KeyID == "" || candidate.KeyType != "RSA" ||
			(candidate.Algorithm != "" && candidate.Algorithm != "RS256") ||
			(candidate.Use != "" && candidate.Use != "sig") {
			continue
		}
		modulus, modErr := base64.RawURLEncoding.DecodeString(candidate.Modulus)
		exponent, expErr := base64.RawURLEncoding.DecodeString(candidate.Exponent)
		if modErr != nil || expErr != nil || len(exponent) == 0 || len(exponent) > 4 {
			continue
		}
		e := 0
		for _, b := range exponent {
			e = e<<8 | int(b)
		}
		n := new(big.Int).SetBytes(modulus)
		if n.BitLen() < 2048 || e < 3 || e%2 == 0 {
			continue
		}
		keys[candidate.KeyID] = &rsa.PublicKey{N: n, E: e}
	}
	if len(keys) == 0 {
		return errors.New("JWKS has no usable RSA signing keys")
	}
	v.keys = keys
	v.keysUntil = v.now().Add(30 * time.Minute)
	return nil
}

func audienceContains(raw json.RawMessage, want string) bool {
	var single string
	if json.Unmarshal(raw, &single) == nil {
		return subtle.ConstantTimeCompare([]byte(single), []byte(want)) == 1
	}
	var values []string
	if json.Unmarshal(raw, &values) != nil {
		return false
	}
	for _, value := range values {
		if subtle.ConstantTimeCompare([]byte(value), []byte(want)) == 1 {
			return true
		}
	}
	return false
}

func rawTrue(raw json.RawMessage) bool {
	var value bool
	if json.Unmarshal(raw, &value) == nil {
		return value
	}
	var text string
	return json.Unmarshal(raw, &text) == nil && text == "true"
}

func rawStringOrNumber(raw json.RawMessage) (string, error) {
	var text string
	if json.Unmarshal(raw, &text) == nil {
		return text, nil
	}
	var number json.Number
	if json.Unmarshal(raw, &number) == nil {
		return number.String(), nil
	}
	return "", errors.New("claim is neither string nor number")
}

func isPositiveDecimal(value string) bool {
	if value == "" {
		return false
	}
	for _, digit := range value {
		if digit < '0' || digit > '9' {
			return false
		}
	}
	number, err := strconv.ParseUint(value, 10, 64)
	return err == nil && number > 0
}

type replayStore struct {
	dir string
}

func (s replayStore) consume(jti string) error {
	digest := sha256.Sum256([]byte(jti))
	path := filepath.Join(s.dir, hex.EncodeToString(digest[:])+".used")
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if errors.Is(err, os.ErrExist) {
		return errors.New("token replay rejected")
	}
	if err != nil {
		return errors.New("replay store unavailable")
	}
	defer file.Close()
	_, err = fmt.Fprintf(file, "%d\n", time.Now().Unix())
	return err
}

type service struct {
	cfg      config
	verifier *oidcVerifier
	replays  replayStore
	busy     chan struct{}
}

func newService(cfg config) *service {
	return &service{
		cfg:      cfg,
		verifier: newOIDCVerifier(cfg),
		replays:  replayStore{dir: cfg.stateDir},
		busy:     make(chan struct{}, 1),
	}
}

func (s *service) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, "ok\n")
	})
	mux.HandleFunc("POST /v1/sign", s.signAPK)
	mux.HandleFunc("POST /v1/publish", s.publishOTA)
	return mux
}

func (s *service) authorize(r *http.Request) (tokenClaims, error) {
	value := r.Header.Get("Authorization")
	if !strings.HasPrefix(value, "Bearer ") {
		return tokenClaims{}, errors.New("missing bearer token")
	}
	token := strings.TrimSpace(strings.TrimPrefix(value, "Bearer "))
	claims, err := s.verifier.verify(token)
	if err != nil {
		return tokenClaims{}, err
	}
	return claims, nil
}

func (s *service) acquire(ctx context.Context) error {
	timer := time.NewTimer(30 * time.Second)
	defer timer.Stop()
	select {
	case s.busy <- struct{}{}:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return errors.New("signer busy timeout")
	}
}

func (s *service) release() {
	<-s.busy
}

func (s *service) signAPK(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get("Content-Type") != "application/vnd.android.package-archive" {
		writeError(w, http.StatusUnsupportedMediaType, "APK content type rejected")
		return
	}
	version, build, err := parseVersionBuild(r)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid release version")
		return
	}
	claims, err := s.authorize(r)
	if err != nil {
		log.Printf("operation=sign result=unauthorized")
		writeError(w, http.StatusUnauthorized, "release identity rejected")
		return
	}
	if err := s.acquire(r.Context()); err != nil {
		writeError(w, http.StatusServiceUnavailable, "signer is busy")
		return
	}
	defer s.release()
	if err := s.replays.consume(claims.JTI); err != nil {
		writeError(w, http.StatusUnauthorized, "release identity rejected")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Minute)
	defer cancel()
	temp, err := os.MkdirTemp(s.cfg.tmpDir, "usernet-sign-")
	if err != nil {
		writeError(w, http.StatusInternalServerError, "signer temporary storage unavailable")
		return
	}
	defer os.RemoveAll(temp)
	if err := os.Chmod(temp, 0700); err != nil {
		writeError(w, http.StatusInternalServerError, "signer temporary storage unavailable")
		return
	}
	unsignedPath := filepath.Join(temp, "unsigned.apk")
	if r.ContentLength > maxAPKBytes {
		writeError(w, http.StatusRequestEntityTooLarge, "APK exceeds size limit")
		return
	}
	input, err := os.OpenFile(unsignedPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "signer temporary storage unavailable")
		return
	}
	count, copyErr := io.Copy(input, http.MaxBytesReader(w, r.Body, maxAPKBytes))
	closeErr := input.Close()
	if copyErr != nil || closeErr != nil || count == 0 {
		var maxErr *http.MaxBytesError
		if errors.As(copyErr, &maxErr) {
			writeError(w, http.StatusRequestEntityTooLarge, "APK exceeds size limit")
		} else {
			writeError(w, http.StatusBadRequest, "APK upload incomplete")
		}
		return
	}
	if err := s.verifyAPKMetadata(ctx, unsignedPath, version, build); err != nil {
		log.Printf("operation=sign run_id=%s result=apk_metadata_rejected", claims.RunID)
		writeError(w, http.StatusUnprocessableEntity, "APK metadata does not match release")
		return
	}
	if err := s.signFile(ctx, unsignedPath, filepath.Join(temp, "signed.apk")); err != nil {
		log.Printf("operation=sign run_id=%s result=signing_failed", claims.RunID)
		writeError(w, http.StatusInternalServerError, "APK signing failed")
		return
	}
	signedPath := filepath.Join(temp, "signed.apk")
	if err := s.verifySignedAPK(ctx, signedPath); err != nil {
		log.Printf("operation=sign run_id=%s result=signature_rejected", claims.RunID)
		writeError(w, http.StatusInternalServerError, "signed APK verification failed")
		return
	}
	file, err := os.Open(signedPath)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "signed APK unavailable")
		return
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || info.Size() == 0 || info.Size() > maxAPKBytes {
		writeError(w, http.StatusInternalServerError, "signed APK has invalid size")
		return
	}
	digest, err := fileSHA256(file)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "signed APK checksum unavailable")
		return
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		writeError(w, http.StatusInternalServerError, "signed APK unavailable")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/vnd.android.package-archive")
	w.Header().Set("Content-Disposition", fmt.Sprintf("attachment; filename=UserNet-%s-%s.apk", version, build))
	w.Header().Set("X-Content-SHA256", digest)
	w.Header().Set("Content-Length", strconv.FormatInt(info.Size(), 10))
	w.WriteHeader(http.StatusOK)
	if _, err := io.Copy(w, file); err != nil {
		log.Printf("operation=sign run_id=%s result=response_interrupted", claims.RunID)
		return
	}
	log.Printf("operation=sign run_id=%s version=%s build=%s result=success sha256=%s", claims.RunID, version, build, digest)
}

func parseVersionBuild(r *http.Request) (string, string, error) {
	version := r.URL.Query().Get("version")
	build := r.URL.Query().Get("build")
	if !versionPattern.MatchString(version) || !buildPattern.MatchString(build) {
		return "", "", errors.New("invalid version or build")
	}
	return version, build, nil
}

func (s *service) verifyAPKMetadata(ctx context.Context, apkPath, version, build string) error {
	command := exec.CommandContext(ctx, s.cfg.aaptPath, "dump", "badging", apkPath)
	var stdout, stderr limitedBuffer
	stdout.limit = 256 * 1024
	stderr.limit = 64 * 1024
	command.Stdout = &stdout
	command.Stderr = &stderr
	if err := command.Run(); err != nil || stdout.truncated || stderr.truncated {
		return errors.New("aapt metadata read failed")
	}
	match := packagePattern.FindSubmatch(stdout.Bytes())
	if len(match) != 4 || string(match[1]) != "com.userlay.usernet" ||
		string(match[2]) != build || string(match[3]) != version {
		return errors.New("APK metadata mismatch")
	}
	return nil
}

func (s *service) signFile(ctx context.Context, unsignedPath, signedPath string) error {
	verify := exec.CommandContext(ctx, s.cfg.apksignerPath, "verify", "--verbose", unsignedPath)
	if err := verify.Run(); err == nil {
		return errors.New("input APK is already signed")
	}
	passwordArg := "file:" + s.cfg.passwordPath
	command := exec.CommandContext(ctx, s.cfg.apksignerPath,
		"sign",
		"--ks", s.cfg.keystorePath,
		"--ks-type", "PKCS12",
		"--ks-key-alias", s.cfg.keystoreAlias,
		"--ks-pass", passwordArg,
		"--key-pass", passwordArg,
		"--v1-signing-enabled", "true",
		"--v2-signing-enabled", "true",
		"--v3-signing-enabled", "true",
		"--out", signedPath,
		unsignedPath,
	)
	var stdout, stderr limitedBuffer
	stdout.limit = 64 * 1024
	stderr.limit = 64 * 1024
	command.Stdout = &stdout
	command.Stderr = &stderr
	if err := command.Run(); err != nil || stdout.truncated || stderr.truncated {
		return errors.New("apksigner failed")
	}
	return nil
}

func (s *service) verifySignedAPK(ctx context.Context, apkPath string) error {
	command := exec.CommandContext(ctx, s.cfg.apksignerPath, "verify", "--verbose", "--print-certs", apkPath)
	var stdout, stderr limitedBuffer
	stdout.limit = 256 * 1024
	stderr.limit = 64 * 1024
	command.Stdout = &stdout
	command.Stderr = &stderr
	if err := command.Run(); err != nil || stdout.truncated || stderr.truncated {
		return errors.New("APK signature verification failed")
	}
	matches := digestPattern.FindAllSubmatch(stdout.Bytes(), -1)
	if len(matches) != 1 {
		return errors.New("APK must have exactly one signer")
	}
	actual := normalizeDigest(string(matches[0][1]))
	if subtle.ConstantTimeCompare([]byte(actual), []byte(s.cfg.expectedCertHash)) != 1 {
		return errors.New("APK signer fingerprint mismatch")
	}
	return nil
}

func fileSHA256(file *os.File) (string, error) {
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return "", err
	}
	digest := sha256.New()
	if _, err := io.Copy(digest, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(digest.Sum(nil)), nil
}

func normalizeDigest(value string) string {
	return strings.ToLower(strings.ReplaceAll(strings.TrimSpace(value), ":", ""))
}

func isHexDigest(value string) bool {
	if len(value) != 64 {
		return false
	}
	_, err := hex.DecodeString(value)
	return err == nil
}

func (s *service) publishOTA(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get("Content-Type") != "application/gzip" {
		writeError(w, http.StatusUnsupportedMediaType, "OTA bundle content type rejected")
		return
	}
	claims, err := s.authorize(r)
	if err != nil {
		log.Printf("operation=publish result=unauthorized")
		writeError(w, http.StatusUnauthorized, "release identity rejected")
		return
	}
	if r.ContentLength > maxOTABundle {
		writeError(w, http.StatusRequestEntityTooLarge, "OTA bundle exceeds size limit")
		return
	}
	if err := s.acquire(r.Context()); err != nil {
		writeError(w, http.StatusServiceUnavailable, "signer is busy")
		return
	}
	defer s.release()
	if err := s.replays.consume(claims.JTI); err != nil {
		writeError(w, http.StatusUnauthorized, "release identity rejected")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Minute)
	defer cancel()
	stdin := http.MaxBytesReader(w, r.Body, maxOTABundle)
	command := exec.CommandContext(ctx, s.cfg.pythonPath, s.cfg.otaScriptPath, "receive", "--root", s.cfg.otaRoot)
	command.Stdin = stdin
	var stdout limitedBuffer
	var stderr limitedBuffer
	stdout.limit = 2048
	stderr.limit = 2048
	command.Stdout = &stdout
	command.Stderr = &stderr
	if err := command.Run(); err != nil {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			writeError(w, http.StatusRequestEntityTooLarge, "OTA bundle exceeds size limit")
			return
		}
		log.Printf("operation=publish run_id=%s result=receiver_failed", claims.RunID)
		writeError(w, http.StatusUnprocessableEntity, "OTA bundle rejected")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = io.WriteString(w, "{\"published\":true}\n")
	log.Printf("operation=publish run_id=%s result=success", claims.RunID)
}

type limitedBuffer struct {
	bytes.Buffer
	limit     int
	truncated bool
}

func (b *limitedBuffer) Write(data []byte) (int, error) {
	remaining := b.limit - b.Len()
	if remaining > 0 {
		if len(data) > remaining {
			_, _ = b.Buffer.Write(data[:remaining])
			b.truncated = true
		} else {
			_, _ = b.Buffer.Write(data)
		}
	} else if len(data) > 0 {
		b.truncated = true
	}
	return len(data), nil
}

func writeError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Cache-Control", "no-store")
	http.Error(w, message, status)
}

func main() {
	log.SetFlags(log.LstdFlags | log.LUTC)
	cfg, err := loadConfig()
	if err != nil {
		log.Fatalf("signer configuration rejected: %v", err)
	}
	svc := newService(cfg)
	server := &http.Server{
		Addr:              cfg.listenAddr,
		Handler:           svc.handler(),
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    16 * 1024,
	}
	log.Printf("UserNet release signer listening on %s", cfg.listenAddr)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("signer server stopped: %v", err)
	}
}
