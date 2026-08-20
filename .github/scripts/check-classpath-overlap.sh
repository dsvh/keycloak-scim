#!/usr/bin/env bash
#
# Fails if the shaded plugin jar would shadow ANY library the Keycloak server already provides.
#
# Why this exists
# ---------------
# Keycloak loads provider jars from /opt/keycloak/providers onto its OWN classpath. A package that
# exists both in the plugin jar and in Keycloak's lib/ is therefore resolved from ONE of them for
# the whole server - and which one wins is not something the plugin controls.
#
# This went off in production on 2026-08-20 (Keycloak 26.4.6): the plugin bundled jackson-core
# 2.17.2, which shadowed Keycloak's newer copy. Keycloak's webauthn4j is compiled against the newer
# one, so every passkey login threw NoSuchMethodError and returned HTTP 500. Password and IdP logins
# were unaffected, which is exactly why nothing caught it before users did.
#
# build.gradle has a fast local guard (`verifyNoClasspathPollution`) but it checks a HARDCODED list
# of package prefixes, so it only knows about libraries someone already thought of. This check is
# the durable version: it derives the forbidden set from the real Keycloak distribution, so a new
# transitive dependency that happens to collide is caught the day it is added, by name, without
# anyone having to predict it.
#
# Usage: check-classpath-overlap.sh [path/to/plugin.jar] [keycloak-version]
# Defaults: the built shadow jar, and keycloakServerVersion from gradle.properties.
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

kc_version="${2:-$(grep -E '^keycloakServerVersion=' "$repo_root/gradle.properties" | cut -d= -f2)}"
if [[ -z "$kc_version" ]]; then
  echo "error: could not determine Keycloak version (gradle.properties: keycloakServerVersion)." >&2
  exit 2
fi

image="quay.io/keycloak/keycloak:${kc_version}"
# Everything the plugin is allowed to own. Relocated copies live under sh/libre/scim/shaded/, so
# this one prefix covers them too.
own_prefix="sh/libre/scim"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "plugin jar : $jar"
echo "keycloak   : $image"
echo

# Java packages inside a jar, one per line, as slash-separated paths.
#
# Multi-release jars keep a second copy of some classes under META-INF/versions/<N>/; strip that
# prefix so a collision hiding in there is still seen. Directory entries and top-level classes
# (no '/') are dropped.
packages_of() {
  unzip -Z1 "$1" 2>/dev/null \
    | grep '\.class$' \
    | sed -E 's#^META-INF/versions/[0-9]+/##' \
    | grep '/' \
    | sed 's#/[^/]*$##'
}

echo "==> extracting Keycloak's classpath from $image"
docker pull -q "$image" >/dev/null
cid="$(docker create "$image")"
docker cp "$cid:/opt/keycloak/lib" "$work/lib" >/dev/null
docker rm -f "$cid" >/dev/null

find "$work/lib" -name '*.jar' -print0 | xargs -0 -n1 -- bash -c 'unzip -Z1 "$0" 2>/dev/null || true' \
  | grep '\.class$' \
  | sed -E 's#^META-INF/versions/[0-9]+/##' \
  | grep '/' \
  | sed 's#/[^/]*$##' \
  | sort -u > "$work/keycloak.txt"

packages_of "$jar" | sort -u > "$work/plugin.txt"

kc_jars=$(find "$work/lib" -name '*.jar' | wc -l | tr -d ' ')
echo "    $kc_jars jars, $(wc -l < "$work/keycloak.txt" | tr -d ' ') packages on Keycloak's classpath"
echo "    $(wc -l < "$work/plugin.txt" | tr -d ' ') packages in the plugin jar"
echo

comm -12 "$work/keycloak.txt" "$work/plugin.txt" | grep -v "^${own_prefix}" > "$work/overlap.txt" || true

if [[ -s "$work/overlap.txt" ]]; then
  echo "FAIL: the plugin jar bundles packages Keycloak also provides."
  echo
  echo "These would shadow Keycloak's own copies for the ENTIRE server, and can break server"
  echo "features that have nothing to do with SCIM:"
  echo
  total=$(wc -l < "$work/overlap.txt" | tr -d ' ')
  sed 's#/#.#g; s#^#  - #' "$work/overlap.txt" | head -25
  if (( total > 25 )); then
    echo "  ... and $(( total - 25 )) more ($total colliding packages in total)"
  fi
  echo
  echo "Fix in build.gradle's shadowJar block, choosing per library:"
  echo "  * relocate(...)  - the plugin needs its own private copy (e.g. Jackson for scim-sdk)"
  echo "  * exclude(...)   - the server's copy is the right one, or is a shared contract"
  echo "                     (Jakarta EE APIs, slf4j-api, BouncyCastle's signed JCE provider)"
  exit 1
fi

echo "PASS: no package in the plugin jar collides with Keycloak ${kc_version}'s classpath."
