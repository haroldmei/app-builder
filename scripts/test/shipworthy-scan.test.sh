#!/usr/bin/env bash
# shipworthy-scan.test.sh — functional test for scripts/shipworthy-scan.sh.
#
# Spins up two local fixture servers (a deliberately vulnerable app and a
# hardened one) and asserts the scanner scores them correctly. Network-free
# and deterministic. Run: scripts/test/shipworthy-scan.test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCAN="$ROOT/scripts/shipworthy-scan.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/shipworthy-test.XXXXXX")"
PIDS=()
cleanup() {
  for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done
  pkill -f "$TMP/secure_server.py" 2>/dev/null || true
  pkill -f "http.server $VPORT" 2>/dev/null || true
  rm -rf "$TMP"
}
VPORT=8731; CPORT=8732
trap cleanup EXIT

PASS=0; FAIL=0
ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

# ---- vulnerable fixture: leaks a service_role JWT + a Stripe key, has a .map ----
mkdir -p "$TMP/vuln"
# fake service_role JWT: header.{"role":"service_role","ref":"abcdefghijklmno"}.sig
SR_PAYLOAD='{"role":"service_role","ref":"abcdefghijklmno","iss":"supabase"}'
SR_JWT="eyJhbGciOiJIUzI1NiJ9.$(printf '%s' "$SR_PAYLOAD" | base64 -w0 | tr '+/' '-_' | tr -d '=').sig123"
cat >"$TMP/vuln/app.js" <<EOF
const STRIPE = "sk_live_ABCDEFGHIJ1234567890abcd";
const SUPA_KEY = "$SR_JWT";
console.log("boot");
//# sourceMappingURL=app.js.map
EOF
echo '{"version":3,"sources":["src/secret.ts"]}' >"$TMP/vuln/app.js.map"
cat >"$TMP/vuln/index.html" <<EOF
<!doctype html><html><head><title>vuln</title></head>
<body><script src="app.js"></script></body></html>
EOF

# ---- hardened fixture: no secrets, security headers, no source map ----
mkdir -p "$TMP/clean"
cat >"$TMP/clean/app.js" <<EOF
const PUBLIC_CFG = { feature: true };
console.log("boot");
EOF
cat >"$TMP/clean/index.html" <<EOF
<!doctype html><html><head><title>clean</title></head>
<body><script src="app.js"></script></body></html>
EOF

# hardened server: serves $TMP/clean with security headers
cat >"$TMP/secure_server.py" <<'PY'
import http.server, sys, os
DIR = sys.argv[1]; PORT = int(sys.argv[2])
class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k): super().__init__(*a, directory=DIR, **k)
    def end_headers(self):
        self.send_header("Content-Security-Policy", "default-src 'self'")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Strict-Transport-Security", "max-age=63072000")
        super().end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", PORT), H).serve_forever()
PY

python3 -m http.server "$VPORT" --bind 127.0.0.1 --directory "$TMP/vuln" >/dev/null 2>&1 & PIDS+=($!)
python3 "$TMP/secure_server.py" "$TMP/clean" "$CPORT" >/dev/null 2>&1 & PIDS+=($!)

# wait for servers
for _ in $(seq 1 30); do
  curl -s -o /dev/null "http://127.0.0.1:$VPORT/" && curl -s -o /dev/null "http://127.0.0.1:$CPORT/" && break
  sleep 0.2
done

echo "── scanning vulnerable fixture ──"
VJSON="$("$SCAN" "http://127.0.0.1:$VPORT" --no-active --json --timeout 5)"
echo "$VJSON" | jq -C '{score, verdict, counts}'
VSCORE="$(echo "$VJSON" | jq '.score')"
echo "── scanning hardened fixture ──"
CJSON="$("$SCAN" "http://127.0.0.1:$CPORT" --no-active --json --timeout 5)"
echo "$CJSON" | jq -C '{score, verdict, counts}'
CSCORE="$(echo "$CJSON" | jq '.score')"

echo "── assertions ──"
# 1. vuln must detect the service_role leak
echo "$VJSON" | jq -e '.findings[] | select(.code=="secret_service_role")' >/dev/null \
  && ok "detects exposed service_role JWT" || bad "missed service_role JWT"
# 2. vuln must detect the Stripe live key
echo "$VJSON" | jq -e '.findings[] | select(.code=="secret_stripe")' >/dev/null \
  && ok "detects Stripe live key" || bad "missed Stripe live key"
# 3. vuln must detect the source map
echo "$VJSON" | jq -e '.findings[] | select(.code=="sourcemap")' >/dev/null \
  && ok "detects exposed source map" || bad "missed source map"
# 4. clean must have ZERO secret findings (no false positives)
NSEC="$(echo "$CJSON" | jq '[.findings[]|select(.code|startswith("secret_"))]|length')"
[[ "$NSEC" -eq 0 ]] && ok "no false-positive secrets on clean app" || bad "false-positive secrets: $NSEC"
# 5. clean must satisfy the security-header checks (CSP/XFO/etc. present)
echo "$CJSON" | jq -e '[.findings[]|select(.code=="no_csp")]|length==0' >/dev/null \
  && ok "recognizes CSP header on hardened app" || bad "flagged CSP despite header present"
# 6. vuln score must be much lower than clean score
[[ "$VSCORE" -lt "$CSCORE" ]] && ok "vuln score ($VSCORE) < clean score ($CSCORE)" \
  || bad "vuln score ($VSCORE) not below clean ($CSCORE)"
# 7. vuln verdict must be NOT SHIPWORTHY
echo "$VJSON" | jq -e '.verdict=="NOT SHIPWORTHY"' >/dev/null \
  && ok "vuln verdict = NOT SHIPWORTHY" || bad "vuln verdict wrong: $(echo "$VJSON"|jq -r .verdict)"

echo "═══════════════════════════════════════════"
echo "  PASS: $PASS   FAIL: $FAIL"
echo "═══════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
