// test-sync: integration test that exercises the full conflict lifecycle.
//
// Usage:
//   go run ./cmd/test-sync -url http://localhost:39811
//
// Steps simulated:
//   1. Register two test devices (A and B) against the same user.
//   2. Device A pushes one object → accepted, serverRev = R1.
//   3. Device B pushes the SAME object with different data, lastServerRev=0
//      → server detects conflict (R1 > 0), returns conflictSessionId.
//   4. Print push response (serverRev should be 0 here if no other objs).
//   5. Resolve conflict → "server wins" for all items.
//      Print resolveConflict response (serverRev — bug: returns 0 if all "server").
//   6. Device B pushes again (simulating client after resolution).
//      Print whether conflict recurs.
//
// Expected after fixes:
//   - Push response (step 3) serverRev = R1 (conflict objs' rev included).
//   - resolveConflict (step 5) serverRev = R1 (max rev of note objs).
//   - Re-push (step 6) → no conflict.

package main

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"time"
)

func newUUID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	h := hex.EncodeToString(b)
	return h[:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:]
}

var serverURL = flag.String("url", "http://localhost:39811", "base URL of notee-api")

func main() {
	flag.Parse()
	log.SetFlags(0)

	baseURL := *serverURL
	testEmail := fmt.Sprintf("test-sync-%d@example.com", time.Now().UnixMilli())
	testPass := "Test1234!"

	// ── 1. Register ──────────────────────────────────────────────────────────
	log.Println("=== 1. Register test user ===")
	tokens := mustRegister(baseURL, testEmail, testPass, "test-device-A")
	log.Printf("  access token (A): %s…\n", tokens.AccessToken[:12])
	log.Printf("  userId: %s\n", tokens.UserID)

	// ── 2. Device A: push one object ─────────────────────────────────────────
	noteID := newUUID()
	pageID := newUUID()
	layerID := newUUID()
	objID := newUUID()

	log.Println("\n=== 2. Device A pushes object (lastServerRev=0) ===")
	resp2 := mustPush(baseURL, tokens.AccessToken, noteID, pageID, layerID, objID,
		`{"color":"red"}`, 0)
	log.Printf("  serverRev=%d  conflictSessionId=%q\n", resp2.ServerRev, resp2.ConflictSessionID)
	if resp2.ConflictSessionID != "" {
		log.Fatalf("  UNEXPECTED conflict on first push")
	}

	// ── 3. Same user, second device: push conflicting data ───────────────────
	// Login as the SAME user but with a different deviceId to simulate
	// two devices that diverged. Device B hasn't synced since rev=0.
	log.Println("\n=== 3. Device B (same user, different deviceId) ===")
	tokensB := mustLogin(baseURL, testEmail, testPass, "test-device-B")
	log.Printf("  access token (B): %s…\n", tokensB.AccessToken[:12])

	log.Println("=== 3b. Device B pushes conflicting data (lastServerRev=0) ===")
	resp3 := mustPush(baseURL, tokensB.AccessToken, noteID, pageID, layerID, objID,
		`{"color":"blue"}`, 0)
	log.Printf("  serverRev=%d  conflictSessionId=%q\n", resp3.ServerRev, resp3.ConflictSessionID)

	sid := resp3.ConflictSessionID
	if sid == "" {
		log.Println("  No conflict from device B push (unexpected). Forcing via device A re-push from rev=0...")
		resp3 = mustPush(baseURL, tokens.AccessToken, noteID, pageID, layerID, objID,
			`{"color":"blue"}`, 0)
		log.Printf("  [forced] serverRev=%d  conflictSessionId=%q\n", resp3.ServerRev, resp3.ConflictSessionID)
		sid = resp3.ConflictSessionID
	}

	if sid == "" {
		log.Fatal("  FAILED: could not produce a conflict session")
	}

	// Use the token that owns the conflict session
	conflictOwnerToken := tokensB.AccessToken
	_ = conflictOwnerToken

	// ── 4. Inspect push response serverRev ───────────────────────────────────
	log.Printf("\n=== 4. Conflict detected ===")
	log.Printf("  conflictSessionId=%s\n", sid)
	log.Printf("  serverRev from conflicting push = %d\n", resp3.ServerRev)
	log.Println("  *** If serverRev=0 here, cursor won't advance → re-conflict guaranteed ***")

	// ── 5. List conflict items ────────────────────────────────────────────────
	log.Println("\n=== 5. GET conflict detail ===")
	detail := mustGetConflict(baseURL, tokensB.AccessToken, noteID, sid)
	log.Printf("  items count: %d\n", len(detail.Items))
	for _, it := range detail.Items {
		log.Printf("    item %s  localData=%s  serverData=%s\n",
			it.ID, it.LocalData, it.ServerData)
	}

	// ── 6. Resolve: ALL "server wins" ────────────────────────────────────────
	log.Println("\n=== 6. Resolve conflict (all server wins) ===")
	resolutions := make([]map[string]string, len(detail.Items))
	for i, it := range detail.Items {
		resolutions[i] = map[string]string{"itemId": it.ID, "resolution": "server"}
	}
	resolveResp := mustResolveConflict(baseURL, tokensB.AccessToken, noteID, sid, resolutions)
	log.Printf("  resolveConflict serverRev=%d\n", resolveResp.ServerRev)
	log.Println("  *** If serverRev=0 here, cursor update is skipped → re-conflict guaranteed ***")

	// ── 7. Re-push from same client (simulating syncNow after resolve) ────────
	// The client should now use lastServerRev = resolveResp.ServerRev (if fixed).
	// If not fixed, it uses lastServerRev = 0 or whatever stale value it had.
	log.Println("\n=== 7. Re-push after conflict resolution ===")

	// Simulate the BUG: client uses lastServerRev=0 (old cursor, not updated)
	log.Println("  [BUGGY] pushing with lastServerRev=0 ...")
	resp7bug := mustPush(baseURL, tokens.AccessToken, noteID, pageID, layerID, objID,
		`{"color":"red"}`, 0)
	if resp7bug.ConflictSessionID != "" {
		log.Printf("  [BUGGY] ❌ CONFLICT RECURRED  serverRev=%d  sid=%s\n",
			resp7bug.ServerRev, resp7bug.ConflictSessionID)
	} else {
		log.Printf("  [BUGGY] ✓ no conflict  serverRev=%d\n", resp7bug.ServerRev)
	}

	// Simulate the FIX: client uses lastServerRev = resolveResp.ServerRev
	correctCursor := resolveResp.ServerRev
	if correctCursor == 0 {
		log.Printf("  [FIX] resolveConflict returned serverRev=0, so correct cursor is UNKNOWN → still re-conflicts")
	}
	log.Printf("  [FIX] pushing with lastServerRev=%d (resolved serverRev) ...\n", correctCursor)
	resp7fix := mustPush(baseURL, tokens.AccessToken, noteID, pageID, layerID, objID,
		`{"color":"red"}`, correctCursor)
	if resp7fix.ConflictSessionID != "" {
		log.Printf("  [FIX] ❌ CONFLICT RECURRED  serverRev=%d  sid=%s\n",
			resp7fix.ServerRev, resp7fix.ConflictSessionID)
	} else {
		log.Printf("  [FIX] ✓ no conflict  serverRev=%d\n", resp7fix.ServerRev)
	}

	log.Println("\n=== SUMMARY ===")
	log.Printf("  Conflict push serverRev:     %d  (should be R1=%d, NOT 0)\n", resp3.ServerRev, resp2.ServerRev)
	log.Printf("  ResolveConflict serverRev:   %d  (should be >=R1=%d, NOT 0)\n", resolveResp.ServerRev, resp2.ServerRev)
	if resp7bug.ConflictSessionID != "" {
		log.Println("  Buggy re-push:               ❌ conflict recurred (as expected with bug)")
	} else {
		log.Println("  Buggy re-push:               ✓ no conflict (bug may be fixed)")
	}
	if resp7fix.ConflictSessionID != "" {
		log.Println("  Fixed re-push:               ❌ conflict recurred (server fix needed)")
	} else {
		log.Println("  Fixed re-push:               ✓ no conflict")
	}
}

// ── HTTP helpers ────────────────────────────────────────────────────────────

type tokenResp struct {
	AccessToken  string `json:"accessToken"`
	RefreshToken string `json:"refreshToken"`
	UserID       string `json:"userId"`
}

type pushResp struct {
	ServerRev         int64  `json:"serverRev"`
	ConflictSessionID string `json:"conflictSessionId"`
}

type conflictDetail struct {
	Items []conflictItem `json:"items"`
}

type conflictItem struct {
	ID         string          `json:"id"`
	LocalData  json.RawMessage `json:"localData"`
	ServerData json.RawMessage `json:"serverData"`
}

type resolveResp struct {
	ServerRev int64 `json:"serverRev"`
}

func mustRegister(baseURL, email, pass, device string) tokenResp {
	body := map[string]any{
		"email":    email,
		"password": pass,
		"deviceId": device,
	}
	r := mustPost(baseURL+"/v1/auth/signup", "", body)
	var t tokenResp
	mustDecode(r, &t)
	return t
}

func mustLogin(baseURL, email, pass, device string) tokenResp {
	body := map[string]any{
		"email":    email,
		"password": pass,
		"deviceId": device,
	}
	r := mustPost(baseURL+"/v1/auth/login", "", body)
	var t tokenResp
	mustDecode(r, &t)
	return t
}

func mustPush(baseURL, token, noteID, pageID, layerID, objID, data string, lastServerRev int64) pushResp {
	now := time.Now().UTC().Format(time.RFC3339)
	body := map[string]any{
		"lastServerRev": lastServerRev,
		"note": map[string]any{
			"id": noteID, "title": "test", "scrollAxis": "vertical",
			"inputDrawMode": "any",
			"defaultPageSpec": map[string]any{
				"widthPt": 595.0, "heightPt": 841.0, "kind": "a4",
				"background": map[string]any{"kind": "blank"},
			},
			"rev": 1, "updatedAt": now,
		},
		"pages": []map[string]any{{
			"id": pageID, "noteId": noteID, "index": 0,
			"spec": map[string]any{
				"widthPt": 595.0, "heightPt": 841.0, "kind": "a4",
				"background": map[string]any{"kind": "blank"},
			},
			"rev": 1, "updatedAt": now, "deleted": false,
		}},
		"layers": []map[string]any{{
			"id": layerID, "pageId": pageID, "z": 0,
			"name": "Layer 1", "visible": true, "locked": false, "opacity": 1.0,
			"rev": 1, "deleted": false, "updatedAt": now,
		}},
		"changes": []map[string]any{{
			"id":        objID,
			"pageId":    pageID,
			"layerId":   layerID,
			"kind":      "stroke",
			"data":      json.RawMessage(data),
			"bbox":      []float64{0, 0, 100, 100},
			"rev":       1,
			"deleted":   false,
			"updatedAt": now,
		}},
	}
	r := mustPost(baseURL+"/v1/sync/"+noteID+"/push", token, body)
	var p pushResp
	mustDecode(r, &p)
	return p
}

func mustGetConflict(baseURL, token, noteID, sid string) conflictDetail {
	req, _ := http.NewRequest("GET", baseURL+"/v1/sync/"+noteID+"/conflicts/"+sid, nil)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		log.Fatalf("GET conflict: %v", err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 300 {
		log.Fatalf("GET conflict %d: %s", resp.StatusCode, b)
	}
	var d conflictDetail
	if err := json.Unmarshal(b, &d); err != nil {
		log.Fatalf("decode conflictDetail: %v — body: %s", err, b)
	}
	return d
}

func mustResolveConflict(baseURL, token, noteID, sid string, resolutions []map[string]string) resolveResp {
	body := map[string]any{"resolutions": resolutions}
	r := mustPost(baseURL+"/v1/sync/"+noteID+"/conflicts/"+sid+"/resolve", token, body)
	var rv resolveResp
	mustDecode(r, &rv)
	return rv
}

func mustPost(url, token string, body any) []byte {
	b, _ := json.Marshal(body)
	req, _ := http.NewRequest("POST", url, bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		log.Fatalf("POST %s: %v", url, err)
	}
	defer resp.Body.Close()
	rb, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 300 {
		log.Fatalf("POST %s → %d: %s", url, resp.StatusCode, rb)
	}
	return rb
}

func mustDecode(b []byte, v any) {
	if err := json.Unmarshal(b, v); err != nil {
		log.Fatalf("decode: %v — body: %s", err, b)
	}
}
