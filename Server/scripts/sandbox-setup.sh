#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# sandbox-setup.sh — Bootstrap a local dev environment for Plaid sandbox testing
#
# Prerequisites:
#   - Docker running (for Postgres via docker-compose)
#   - .env filled with Plaid sandbox credentials + generated secrets
#
# Usage:
#   cd Server
#   chmod +x scripts/sandbox-setup.sh
#   ./scripts/sandbox-setup.sh
# ---------------------------------------------------------------------------

set -euo pipefail

BASE_URL="${SERVER_URL:-http://localhost:3000}"
API="$BASE_URL/v1"
TEST_EMAIL="test@hyperfin.dev"
TEST_PASSWORD="Sandbox123!"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[sandbox]${NC} $1"; }
warn()  { echo -e "${YELLOW}[sandbox]${NC} $1"; }
error() { echo -e "${RED}[sandbox]${NC} $1"; }

# ── Step 1: Start Postgres ─────────────────────────────────────────────────
info "Starting Postgres via docker compose..."
docker compose up -d 2>/dev/null || docker-compose up -d 2>/dev/null

info "Waiting for Postgres to be ready..."
for i in $(seq 1 30); do
  if pg_isready -h localhost -p 5432 -U hyperfin -q 2>/dev/null; then
    info "Postgres is ready."
    break
  fi
  if [ "$i" -eq 30 ]; then
    error "Postgres did not become ready in 30 seconds."
    exit 1
  fi
  sleep 1
done

# ── Step 2: Check .env ─────────────────────────────────────────────────────
if [ ! -f .env ]; then
  error ".env file not found. Copy .env.example to .env and fill in values."
  exit 1
fi

# Source .env to check key vars (won't override already-set vars)
set -a
source .env
set +a

if [ "${JWT_SECRET:-}" = "your-jwt-secret-here" ] || [ -z "${JWT_SECRET:-}" ]; then
  warn "JWT_SECRET is not set. Generating random secrets..."
  JWT_SEC=$(openssl rand -hex 32)
  JWT_REF=$(openssl rand -hex 32)
  sed -i.bak "s|JWT_SECRET=.*|JWT_SECRET=$JWT_SEC|" .env
  sed -i.bak "s|JWT_REFRESH_SECRET=.*|JWT_REFRESH_SECRET=$JWT_REF|" .env
  info "Generated JWT_SECRET and JWT_REFRESH_SECRET."
fi

if [ "${PLAID_TOKEN_ENCRYPTION_KEY:-}" = "your-64-char-hex-key-here" ] || [ -z "${PLAID_TOKEN_ENCRYPTION_KEY:-}" ]; then
  ENC_KEY=$(openssl rand -hex 32)
  sed -i.bak "s|PLAID_TOKEN_ENCRYPTION_KEY=.*|PLAID_TOKEN_ENCRYPTION_KEY=$ENC_KEY|" .env
  info "Generated PLAID_TOKEN_ENCRYPTION_KEY."
fi

# Clean up sed backups
rm -f .env.bak

# ── Step 3: Start server ───────────────────────────────────────────────────
info "Starting server in background..."
npm run dev &
SERVER_PID=$!

# Wait for server to be ready
for i in $(seq 1 20); do
  if curl -sf "$BASE_URL/health" >/dev/null 2>&1 || curl -sf "$API/config" >/dev/null 2>&1; then
    info "Server is ready (PID $SERVER_PID)."
    break
  fi
  if [ "$i" -eq 20 ]; then
    warn "Server didn't respond to health check, but may still be starting. Continuing..."
    break
  fi
  sleep 1
done

# ── Step 4: Register test user ─────────────────────────────────────────────
info "Registering test user ($TEST_EMAIL)..."
REGISTER_RESPONSE=$(curl -sf -X POST "$API/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$TEST_EMAIL\",\"password\":\"$TEST_PASSWORD\"}" 2>&1) || true

if echo "$REGISTER_RESPONSE" | grep -q "accessToken"; then
  info "Test user registered successfully."
else
  info "Registration failed (user may already exist). Trying login..."
  REGISTER_RESPONSE=$(curl -sf -X POST "$API/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$TEST_EMAIL\",\"password\":\"$TEST_PASSWORD\"}" 2>&1) || true
fi

ACCESS_TOKEN=$(echo "$REGISTER_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['accessToken'])" 2>/dev/null || echo "")
REFRESH_TOKEN=$(echo "$REGISTER_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['refreshToken'])" 2>/dev/null || echo "")

if [ -n "$ACCESS_TOKEN" ]; then
  echo ""
  info "=== Sandbox Ready ==="
  echo ""
  echo "  Test user:     $TEST_EMAIL"
  echo "  Password:      $TEST_PASSWORD"
  echo "  Access token:  ${ACCESS_TOKEN:0:30}..."
  echo "  Refresh token: ${REFRESH_TOKEN:0:30}..."
  echo ""
  info "=== Plaid Sandbox Credentials ==="
  echo ""
  echo "  Institution:   First Platypus Bank"
  echo "  Username:      user_good"
  echo "  Password:      pass_good"
  echo "  MFA code:      1234 (if prompted)"
  echo ""

  # Check Plaid mode
  if [ "${PLAID_CLIENT_ID:-your-plaid-client-id}" != "your-plaid-client-id" ] && [ -n "${PLAID_CLIENT_ID:-}" ]; then
    info "Plaid mode: SANDBOX (real credentials configured)"
  else
    warn "Plaid mode: MOCK (no Plaid credentials — will use canned fixtures)"
  fi

  echo ""
  info "Server running on PID $SERVER_PID. Press Ctrl+C to stop."
  echo ""
else
  error "Could not obtain auth tokens. Check server logs."
fi

# Keep script running (server is in background)
wait $SERVER_PID
