// Package config loads runtime configuration from environment variables.
//
// All defaults target a local dev setup (docker-compose Postgres + MinIO).
// Production deployments must override values via env.
package config

import (
	"fmt"
	"os"
	"strconv"
	"time"
)

// Config holds the resolved runtime configuration.
type Config struct {
	HTTPAddr string

	DatabaseURL string

	S3Endpoint  string
	S3Region    string
	S3Bucket    string
	S3AccessKey string
	S3SecretKey string
	S3UseSSL    bool

	JWTSecret      string
	AccessTokenTTL time.Duration

	// hCaptcha is enabled iff HCaptchaSecret is non-empty.
	// HCaptchaSitekey is exposed to the client (it's public — the secret
	// stays server-side and is sent to api.hcaptcha.com/siteverify).
	HCaptchaSitekey string
	HCaptchaSecret  string
}

// Load resolves Config from process environment with safe dev defaults.
func Load() (*Config, error) {
	c := &Config{
		HTTPAddr: env("HTTP_ADDR", ":8080"),

		DatabaseURL: env("DATABASE_URL",
			"postgres://notee:notee@localhost:5432/notee?sslmode=disable"),

		S3Endpoint:  env("S3_ENDPOINT", "http://localhost:9000"),
		S3Region:    env("S3_REGION", "us-east-1"),
		S3Bucket:    env("S3_BUCKET", "notee-assets"),
		S3AccessKey: env("S3_ACCESS_KEY", "minioadmin"),
		S3SecretKey: env("S3_SECRET_KEY", "minioadmin"),
		S3UseSSL:    envBool("S3_USE_SSL", false),

		JWTSecret:      env("JWT_SECRET", "dev-only-not-secret"),
		AccessTokenTTL: envDuration("ACCESS_TOKEN_TTL", 365*24*time.Hour),

		HCaptchaSitekey: env("HCAPTCHA_SITEKEY", ""),
		HCaptchaSecret:  env("HCAPTCHA_SECRET", ""),
	}

	if c.JWTSecret == "dev-only-not-secret" && os.Getenv("APP_ENV") == "production" {
		return nil, fmt.Errorf("JWT_SECRET must be overridden in production")
	}

	return c, nil
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func envBool(key string, def bool) bool {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	b, err := strconv.ParseBool(v)
	if err != nil {
		return def
	}
	return b
}

func envDuration(key string, def time.Duration) time.Duration {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		return def
	}
	return d
}
