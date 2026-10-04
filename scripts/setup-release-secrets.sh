#!/usr/bin/env bash
# Store the secrets the Release workflow needs, without printing any of them.
#
# Before running: export your "Developer ID Application" certificate WITH its private key
# from Keychain Access (right-click the certificate → Export… → .p12, choose a password).
#
#   scripts/setup-release-secrets.sh ~/Desktop/DeveloperID.p12
set -euo pipefail
cd "$(dirname "$0")/.."

P12="${1:?usage: scripts/setup-release-secrets.sh <path-to-DeveloperID.p12>}"
[ -f "$P12" ] || { echo "No such file: $P12"; exit 1; }
command -v gh >/dev/null || { echo "gh not found: brew install gh"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Run 'gh auth login' first."; exit 1; }
git remote get-url origin >/dev/null 2>&1 || { echo "No 'origin' remote; create the GitHub repo first."; exit 1; }

TEAM=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 '"Developer ID Application:' | sed -nE 's/.*\(([A-Z0-9]{10})\)".*/\1/p' || true)
read -rp "Apple ID email: " APPLE_ID
read -rp "Team ID [${TEAM:-}]: " TEAM_IN; TEAM="${TEAM_IN:-$TEAM}"
read -rsp "App-specific password (from account.apple.com): " ASP; echo
read -rsp "Password of the .p12 file: " P12_PASSWORD; echo

# Check the .p12 opens with that password before uploading anything.
openssl pkcs12 -in "$P12" -passin "pass:$P12_PASSWORD" -nokeys -legacy >/dev/null 2>&1 \
  || openssl pkcs12 -in "$P12" -passin "pass:$P12_PASSWORD" -nokeys >/dev/null 2>&1 \
  || { echo "Could not open the .p12 with that password."; exit 1; }

base64 -i "$P12" | gh secret set DEVELOPER_ID_P12_BASE64
printf '%s' "$P12_PASSWORD" | gh secret set DEVELOPER_ID_P12_PASSWORD
printf '%s' "$APPLE_ID" | gh secret set APPLE_ID
printf '%s' "$TEAM" | gh secret set APPLE_TEAM_ID
printf '%s' "$ASP" | gh secret set APPLE_APP_SPECIFIC_PASSWORD
echo "Secrets set on $(gh repo view --json nameWithOwner -q .nameWithOwner). Tag a release with: git tag v0.2.0 && git push origin v0.2.0"
