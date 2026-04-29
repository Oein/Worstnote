package auth

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/rs/zerolog/log"
)

// Service bundles dependencies for the auth handlers.
type Service struct {
	DB     *pgxpool.Pool
	Issuer *Issuer

	// hCaptcha. If HCaptchaSecret is non-empty, signup requires a
	// captchaToken in the request body which is verified against
	// api.hcaptcha.com/siteverify before the user row is created.
	HCaptchaSitekey string
	HCaptchaSecret  string

	// HTTPClient used for hCaptcha verification. Tests inject a stub.
	HTTPClient *http.Client
}

func NewService(db *pgxpool.Pool, issuer *Issuer) *Service {
	return &Service{
		DB:         db,
		Issuer:     issuer,
		HTTPClient: &http.Client{Timeout: 10 * time.Second},
	}
}

// CaptchaConfig is the public configuration the client fetches before
// rendering the captcha widget. The secret never leaves the server.
func (s *Service) CaptchaConfig(w http.ResponseWriter, r *http.Request) {
	enabled := s.HCaptchaSecret != "" && s.HCaptchaSitekey != ""
	resp := map[string]any{
		"enabled":  enabled,
		"provider": "hcaptcha",
		"sitekey":  s.HCaptchaSitekey,
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(resp)
}

// verifyHCaptcha posts the token to api.hcaptcha.com/siteverify and returns
// nil iff the response says success=true.
func (s *Service) verifyHCaptcha(token, remoteIP string) error {
	if s.HCaptchaSecret == "" {
		return nil // captcha disabled — accept anything
	}
	if token == "" {
		return errors.New("missing captcha token")
	}
	form := url.Values{}
	form.Set("secret", s.HCaptchaSecret)
	form.Set("response", token)
	if s.HCaptchaSitekey != "" {
		form.Set("sitekey", s.HCaptchaSitekey)
	}
	if remoteIP != "" {
		form.Set("remoteip", remoteIP)
	}
	client := s.HTTPClient
	if client == nil {
		client = &http.Client{Timeout: 10 * time.Second}
	}
	req, err := http.NewRequest(http.MethodPost,
		"https://api.hcaptcha.com/siteverify",
		strings.NewReader(form.Encode()))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	var body struct {
		Success    bool     `json:"success"`
		ErrorCodes []string `json:"error-codes"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return err
	}
	if !body.Success {
		return errors.New("captcha rejected: " + strings.Join(body.ErrorCodes, ","))
	}
	return nil
}

type signupReq struct {
	Email        string `json:"email"`
	Password     string `json:"password"`
	DeviceID     string `json:"deviceId"`
	CaptchaToken string `json:"captchaToken"`
}

type tokenResp struct {
	UserID      string `json:"userId"`
	AccessToken string `json:"accessToken"`
	ExpiresIn   int64  `json:"expiresIn"`
}

// Signup creates a new user (email + password). Returns access/refresh tokens.
func (s *Service) Signup(w http.ResponseWriter, r *http.Request) {
	var req signupReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid_body", err.Error())
		return
	}
	req.Email = strings.TrimSpace(strings.ToLower(req.Email))
	if !validEmail(req.Email) {
		writeErr(w, http.StatusBadRequest, "invalid_email", "")
		return
	}
	if len(req.Password) < 8 {
		writeErr(w, http.StatusBadRequest, "weak_password", "min 8 chars")
		return
	}
	if req.DeviceID == "" {
		writeErr(w, http.StatusBadRequest, "missing_device_id", "")
		return
	}
	// hCaptcha verification — only enforced when HCaptchaSecret is set.
	// Use X-Forwarded-For first hop if present (Caddy/reverse proxy).
	if err := s.verifyHCaptcha(req.CaptchaToken, clientIP(r)); err != nil {
		log.Warn().Err(err).Msg("captcha verification failed")
		writeErr(w, http.StatusForbidden, "captcha_failed", err.Error())
		return
	}
	hash, err := HashPassword(req.Password)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "hash_failed", "")
		return
	}
	var userID string
	err = s.DB.QueryRow(r.Context(),
		`INSERT INTO users(email, password_hash) VALUES($1,$2) RETURNING id`,
		req.Email, hash).Scan(&userID)
	if err != nil {
		if isUniqueViolation(err) {
			writeErr(w, http.StatusConflict, "email_taken", "")
			return
		}
		log.Error().Err(err).Msg("signup insert")
		writeErr(w, http.StatusInternalServerError, "db_error", "")
		return
	}
	s.issueAndRespond(w, r, userID, req.DeviceID)
}

type loginReq struct {
	Email    string `json:"email"`
	Password string `json:"password"`
	DeviceID string `json:"deviceId"`
}

func (s *Service) Login(w http.ResponseWriter, r *http.Request) {
	var req loginReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid_body", err.Error())
		return
	}
	req.Email = strings.TrimSpace(strings.ToLower(req.Email))
	if req.Email == "" || req.Password == "" || req.DeviceID == "" {
		writeErr(w, http.StatusBadRequest, "missing_fields", "")
		return
	}
	var userID, hash string
	err := s.DB.QueryRow(r.Context(),
		`SELECT id, password_hash FROM users WHERE email=$1`,
		req.Email).Scan(&userID, &hash)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && !VerifyPassword(hash, req.Password)) {
		writeErr(w, http.StatusUnauthorized, "invalid_credentials", "")
		return
	}
	if err != nil {
		log.Error().Err(err).Msg("login lookup")
		writeErr(w, http.StatusInternalServerError, "db_error", "")
		return
	}
	s.issueAndRespond(w, r, userID, req.DeviceID)
}

func (s *Service) Logout(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusNoContent)
}

// issueAndRespond signs a 1-year access token and writes the tokenResp body.
func (s *Service) issueAndRespond(w http.ResponseWriter, _ *http.Request, userID, deviceID string) {
	now := time.Now().UTC()
	access, err := s.Issuer.Sign(userID, deviceID, now)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "sign_failed", "")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(tokenResp{
		UserID:      userID,
		AccessToken: access,
		ExpiresIn:   int64(s.Issuer.AccessTTL.Seconds()),
	})
}

// clientIP extracts the most likely client IP from common proxy headers,
// falling back to RemoteAddr. Used by captcha verification (remoteip arg).
func clientIP(r *http.Request) string {
	if v := r.Header.Get("X-Forwarded-For"); v != "" {
		if comma := strings.IndexByte(v, ','); comma >= 0 {
			return strings.TrimSpace(v[:comma])
		}
		return strings.TrimSpace(v)
	}
	if v := r.Header.Get("X-Real-IP"); v != "" {
		return v
	}
	addr := r.RemoteAddr
	if i := strings.LastIndexByte(addr, ':'); i >= 0 {
		return addr[:i]
	}
	return addr
}

func validEmail(s string) bool {
	at := strings.IndexByte(s, '@')
	return at > 0 && at < len(s)-3 && strings.Contains(s[at:], ".")
}

func isUniqueViolation(err error) bool {
	return strings.Contains(err.Error(), "23505")
}

type apiError struct {
	Error struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}

func writeErr(w http.ResponseWriter, status int, code, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	var e apiError
	e.Error.Code = code
	e.Error.Message = msg
	_ = json.NewEncoder(w).Encode(e)
}
