// Package auth handles JWT issuance and verification + bcrypt password hashing.
package auth

import (
	"errors"
	"fmt"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

type Claims struct {
	UserID   string `json:"sub"`
	DeviceID string `json:"did,omitempty"`
	jwt.RegisteredClaims
}

type Issuer struct {
	Secret    []byte
	AccessTTL time.Duration
}

func NewIssuer(secret string, accessTTL time.Duration) *Issuer {
	return &Issuer{Secret: []byte(secret), AccessTTL: accessTTL}
}

// Sign returns a signed access token for the given user/device.
func (i *Issuer) Sign(userID, deviceID string, now time.Time) (string, error) {
	claims := Claims{
		UserID:   userID,
		DeviceID: deviceID,
		RegisteredClaims: jwt.RegisteredClaims{
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(now.Add(i.AccessTTL)),
			Issuer:    "notee",
		},
	}
	t := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	return t.SignedString(i.Secret)
}

// Verify checks signature + expiry and returns the claims.
func (i *Issuer) Verify(token string) (*Claims, error) {
	parsed, err := jwt.ParseWithClaims(token, &Claims{}, func(t *jwt.Token) (any, error) {
		if t.Method != jwt.SigningMethodHS256 {
			return nil, fmt.Errorf("unexpected signing method")
		}
		return i.Secret, nil
	})
	if err != nil {
		return nil, err
	}
	c, ok := parsed.Claims.(*Claims)
	if !ok || !parsed.Valid {
		return nil, errors.New("invalid token")
	}
	return c, nil
}
