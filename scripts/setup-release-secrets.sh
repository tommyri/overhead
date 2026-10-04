#!/usr/bin/env bash
# Store the secrets the Release workflow needs, without printing any of them.
#
#   scripts/setup-release-secrets.sh                      # exports the signing identities from your login keychain
#   scripts/setup-release-secrets.sh ~/Desktop/Certs.p12  # or use a .p12 you exported yourself
#
# A .p12 must contain the "Developer ID Application" certificate together with its private
# key. Keychain Access only offers .p12 when you export from the "My Certificates" category
# (or expand the certificate and select it with its key); Xcode → Settings → Accounts →
# Manage Certificates… → right-click → Export Certificate… also produces one.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v gh >/dev/null || { echo "gh not found: brew install gh"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Run 'gh auth login' first."; exit 1; }
git remote get-url origin >/dev/null 2>&1 || { echo "No 'origin' remote; create the GitHub repo first."; exit 1; }

P12="${1:-}"
TMPDIR_EXPORT=""
if [ -z "$P12" ]; then
  # Export every code-signing identity (certificate + private key) from the login keychain.
  # The workflow picks "Developer ID Application" by name, so extra identities are harmless.
  # macOS will ask you to allow access to the private keys.
  TMPDIR_EXPORT=$(mktemp -d)
  P12="$TMPDIR_EXPORT/identities.p12"
  read -rsp "Choose a password to protect the exported certificate: " EXPORT_PW; echo
  security export -k "$HOME/Library/Keychains/login.keychain-db" -t identities -f pkcs12 -P "$EXPORT_PW" -o "$P12"
  P12_PASSWORD="$EXPORT_PW"
  echo "Exported identities to a temporary file (deleted when done)."
fi
[ -f "$P12" ] || { echo "No such file: $P12"; exit 1; }

TEAM=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 '"Developer ID Application:' | sed -nE 's/.*\(([A-Z0-9]{10})\)".*/\1/p' || true)
read -rp "Apple ID email: " APPLE_ID
read -rp "Team ID [${TEAM:-}]: " TEAM_IN; TEAM="${TEAM_IN:-$TEAM}"
read -rsp "App-specific password (from account.apple.com): " ASP; echo
if [ -z "${P12_PASSWORD:-}" ]; then read -rsp "Password of the .p12 file: " P12_PASSWORD; echo; fi

# Check the .p12 opens with that password before uploading anything.
openssl pkcs12 -in "$P12" -passin "pass:$P12_PASSWORD" -nokeys -legacy >/dev/null 2>&1 \
  || openssl pkcs12 -in "$P12" -passin "pass:$P12_PASSWORD" -nokeys >/dev/null 2>&1 \
  || { echo "Could not open the .p12 with that password."; exit 1; }

base64 -i "$P12" | gh secret set DEVELOPER_ID_P12_BASE64
printf '%s' "$P12_PASSWORD" | gh secret set DEVELOPER_ID_P12_PASSWORD
printf '%s' "$APPLE_ID" | gh secret set APPLE_ID
printf '%s' "$TEAM" | gh secret set APPLE_TEAM_ID
printf '%s' "$ASP" | gh secret set APPLE_APP_SPECIFIC_PASSWORD
[ -n "$TMPDIR_EXPORT" ] && rm -rf "$TMPDIR_EXPORT"
echo "Secrets set on $(gh repo view --json nameWithOwner -q .nameWithOwner). Tag a release with: git tag v0.2.0 && git push origin v0.2.0"
