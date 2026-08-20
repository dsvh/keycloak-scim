#!/usr/bin/env bash
#
# Boots a real Keycloak server with the built plugin jar in /opt/keycloak/providers and asserts the
# plugin actually loads.
#
# This is the complement to check-classpath-overlap.sh. That check stops the plugin from SHADOWING
# the server's libraries; this one stops the fix for that from going too far - if a `relocate` or
# `exclude` in build.gradle removes something the plugin genuinely needs, the SPIs silently fail to
# register or the server logs a linkage error, and this catches it before a release is cut.
#
# What it asserts:
#   1. Keycloak finishes its startup build and serves traffic with the jar present. `start-dev`
#      re-runs the augmentation step on every boot, so a jar that breaks provider loading (or that
#      breaks Keycloak itself) fails right here.
#   2. All three SPIs the plugin declares in META-INF/services are registered:
#      storage (user federation), eventsListener, and jpa-entity-provider.
#   3. The server log carries no LinkageError / NoSuchMethodError / NoClassDefFoundError /
#      ClassNotFoundException - the signature of a classpath collision.
#
# Usage: smoke-test-plugin.sh [path/to/plugin.jar] [keycloak-version]
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

jar="${1:-}"
if [[ -z "$jar" ]]; then
  jar="$(ls -1 "$repo_root"/build/libs/*-all.jar 2>/dev/null | head -1 || true)"
fi
if [[ -z "$jar" || ! -f "$jar" ]]; then
  echo "error: no plugin jar found. Run './gradlew shadowJar' first, or pass the jar path." >&2
  exit 2
fi
jar="$(cd "$(dirname "$jar")" && pwd)/$(basename "$jar")"

kc_version="${2:-$(grep -E '^keycloakServerVersion=' "$repo_root/gradle.properties" | cut -d= -f2)}"
image="quay.io/keycloak/keycloak:${kc_version}"

name="keycloak-scim-smoke-$$"
admin_user="admin"
admin_pass="admin"
port=18080

logfile="$(mktemp)"
cleanup() {
  echo
  echo "==> keycloak logs (tail)"
  docker logs "$name" 2>&1 | tail -40 || true
  docker rm -f "$name" >/dev/null 2>&1 || true
  rm -f "$logfile"
}
trap cleanup EXIT

echo "plugin jar : $jar"
echo "keycloak   : $image"
echo

echo "==> booting Keycloak with the plugin mounted"
docker run -d --name "$name" \
  -p "127.0.0.1:${port}:8080" \
  -v "$jar:/opt/keycloak/providers/keycloak-scim.jar:ro" \
  -e KC_BOOTSTRAP_ADMIN_USERNAME="$admin_user" \
  -e KC_BOOTSTRAP_ADMIN_PASSWORD="$admin_pass" \
  -e KC_HEALTH_ENABLED=true \
  "$image" start-dev >/dev/null

# 1. Keycloak becomes ready. Probing the OIDC discovery document rather than /health/ready keeps
#    this to the one published port - health lives on the separate management port 9000.
echo "==> waiting for Keycloak to serve traffic (up to 180s)"
ready=false
for _ in $(seq 1 90); do
  if ! docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -q true; then
    echo "FAIL: the Keycloak container exited during startup."
    exit 1
  fi
  if curl -sf "http://127.0.0.1:${port}/realms/master/.well-known/openid-configuration" >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 2
done
if [[ "$ready" != true ]]; then
  echo "FAIL: Keycloak did not become ready within 180s with the plugin present."
  exit 1
fi
echo "    ready"

# 2. The plugin's SPIs are registered.
echo "==> checking the plugin's SPIs are registered"
token="$(curl -sf -X POST \
  "http://127.0.0.1:${port}/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" -d "username=${admin_user}" -d "password=${admin_pass}" \
  -d "grant_type=password" | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')"

serverinfo="$(mktemp)"
curl -sf -H "Authorization: Bearer $token" \
  "http://127.0.0.1:${port}/admin/serverinfo" > "$serverinfo"

python3 - "$serverinfo" <<'PYEOF'
import json, sys

info = json.load(open(sys.argv[1]))
providers = info.get("providers", {})

# spi name -> (provider id the plugin registers, what it gives us) - for a readable failure.
# Note the ids differ: the storage and event SPIs use "scim", the JPA one uses "scim-resource".
expected = {
    "storage":             ("scim",          'user federation provider (provider_id = "scim" in Terraform)'),
    "eventsListener":      ("scim",          "realm event listener (real-time propagation)"),
    "jpa-entity-provider": ("scim-resource", "JPA entity provider (the scim_resource table)"),
}

missing = []
for spi, (provider_id, purpose) in expected.items():
    names = (providers.get(spi) or {}).get("providers", {})
    if provider_id not in names:
        missing.append((spi, provider_id, purpose, sorted(names)))

if missing:
    print("FAIL: the plugin jar loaded but did not register all of its SPIs.")
    print()
    for spi, provider_id, purpose, names in missing:
        print(f"  - SPI '{spi}' has no '{provider_id}' provider  -  {purpose}")
        print(f"    registered instead: {', '.join(names) or '(none)'}")
    print()
    print("This usually means a shadowJar relocate/exclude removed something the plugin needs,")
    print("or META-INF/services was not merged (see mergeServiceFiles() in build.gradle).")
    sys.exit(1)

for spi, (provider_id, _) in expected.items():
    print(f"    {spi}: '{provider_id}' registered")
PYEOF
rm -f "$serverinfo"

# 3. No linkage errors in the log. This is the exact signature the production incident produced.
echo "==> scanning the server log for linkage errors"
docker logs "$name" > "$logfile" 2>&1
if grep -nE 'LinkageError|NoSuchMethodError|NoSuchFieldError|NoClassDefFoundError|ClassNotFoundException|IncompatibleClassChangeError' "$logfile"; then
  echo
  echo "FAIL: the server log contains linkage errors (see the matching lines above)."
  echo "A jar that shadows one of Keycloak's own libraries is the usual cause -"
  echo "run .github/scripts/check-classpath-overlap.sh."
  exit 1
fi

echo
echo "PASS: the plugin loads cleanly on Keycloak ${kc_version} and registers all of its SPIs."
