#!/usr/bin/env bash
#
# Yggdrasil service entrypoint.
#
# Yggdrasil fails fast at startup if any of its CouchDB databases are
# missing, and the statusdb seed runs in the background after CouchDB
# answers /_up. This entrypoint therefore verifies the environment is
# actually usable before firing the daemon:
#
#   1. CouchDB answers /_up
#   2. the seeded `projects` database exists
#   3. the yggdrasil / yggdrasil_plans / yggdrasil_ops databases exist
#   4. the demux_sample_info / flowcell_status databases exist (dmx_realm)
#   5. (optional) a test scenario document is injected into the stack
#   6. (optional) genomics-status is reachable, when it is part of this stack
#
# It then hands over to the requested yggdrasil command (default: `--dev daemon`).
#
# Environment:
#   YGG_COUCH_URL     CouchDB base URL (default http://statusdb:5984)
#   YGG_COUCH_USER    CouchDB username (required)
#   YGG_COUCH_PASS    CouchDB password (required)
#   YGG_INJECT_TEST_SCENARIO  "true" (default) to inject the scenario seed
#   YGG_SCENARIO_ID   document id for the scenario (default test_scenario:compose-demo)

set -euo pipefail

COUCH_URL="${YGG_COUCH_URL:-http://statusdb:5984}"
COUCH_USER="${YGG_COUCH_USER:?YGG_COUCH_USER must be set}"
COUCH_PASS="${YGG_COUCH_PASS:?YGG_COUCH_PASS must be set}"
AUTH=(-u "${COUCH_USER}:${COUCH_PASS}")

log() { printf '[yggdrasil-entrypoint] %s\n' "$*"; }

wait_for_http() {
    # $1 = url, $2 = name, $3 = timeout seconds
    local url="$1" name="$2" timeout="${3:-180}" waited=0
    log "Waiting for ${name} at ${url} (timeout ${timeout}s)..."
    until curl -sf -o /dev/null "${AUTH[@]}" "${url}" 2>/dev/null; do
        sleep 2
        waited=$((waited + 2))
        if [ "${waited}" -ge "${timeout}" ]; then
            log "ERROR: ${name} did not become ready at ${url} within ${timeout}s"
            return 1
        fi
    done
    log "${name} is ready"
}

wait_for_db() {
    # $1 = database name, $2 = timeout seconds
    local db="$1" timeout="${2:-300}" waited=0
    log "Waiting for database '${db}'..."
    until curl -sf -o /dev/null "${AUTH[@]}" "${COUCH_URL}/${db}" 2>/dev/null; do
        sleep 2
        waited=$((waited + 2))
        if [ "${waited}" -ge "${timeout}" ]; then
            log "ERROR: database '${db}' did not appear within ${timeout}s"
            return 1
        fi
    done
    log "database '${db}' is available"
}

create_db() {
    # $1 = database name (idempotent: 201 = created, 412 = already exists)
    local db="$1" code
    code="$(curl -s -o /dev/null -w '%{http_code}' -X PUT "${AUTH[@]}" "${COUCH_URL}/${db}")"
    case "${code}" in
        201 | 412) log "database '${db}' ready (HTTP ${code})" ;;
        *) log "ERROR: failed to create database '${db}' (HTTP ${code})"; return 1 ;;
    esac
}

wait_for_service() {
    # Wait for an optional service on the compose network.
    # If the host does not resolve, the service is not part of this
    # stack and the wait is skipped.
    # $1 = host, $2 = port, $3 = name, $4 = timeout seconds
    local host="$1" port="$2" name="$3" timeout="${4:-300}" waited=0 resolvable=0
    # Retry DNS resolution briefly: a freshly (re)started container may need
    # a moment before the compose DNS records for peer services resolve.
    for _ in 1 2 3 4 5 6; do
        if getent hosts "${host}" >/dev/null 2>&1; then
            resolvable=1
            break
        fi
        sleep 2
    done
    if [ "${resolvable}" -ne 1 ]; then
        log "${name} (${host}) is not part of this stack; skipping readiness wait"
        return 0
    fi
    log "Waiting for ${name} at http://${host}:${port}/ (timeout ${timeout}s)..."
    until curl -sf -o /dev/null "http://${host}:${port}/" 2>/dev/null; do
        sleep 2
        waited=$((waited + 2))
        if [ "${waited}" -ge "${timeout}" ]; then
            log "ERROR: ${name} did not become ready within ${timeout}s"
            return 1
        fi
    done
    log "${name} is ready"
}

inject_scenario() {
    local id="${YGG_SCENARIO_ID:-test_scenario:compose-demo}"
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' "${AUTH[@]}" "${COUCH_URL}/yggdrasil/${id}")"
    if [ "${code}" = "404" ]; then
        curl -sf -X PUT "${AUTH[@]}" \
            -H 'Content-Type: application/json' \
            --data-binary @/app/scenario_seed.json \
            "${COUCH_URL}/yggdrasil/${id}" >/dev/null
        log "Injected test scenario '${id}' into the yggdrasil database"
    else
        log "Test scenario '${id}' already present (HTTP ${code}); skipping injection"
    fi
}

# 1. CouchDB must be up.
wait_for_http "${COUCH_URL}/_up" "CouchDB" 180

# 2. Seeded projects database (statusdb seeds it in the background).
wait_for_db "projects" 300

# 3. Yggdrasil's own databases.
create_db "yggdrasil"
create_db "yggdrasil_plans"
create_db "yggdrasil_ops"

# 4. Databases watched by the dmx_realm realm (demux_realm package).
create_db "demux_sample_info"
create_db "flowcell_status"

# 5. Optional test scenario.
if [ "${YGG_INJECT_TEST_SCENARIO:-true}" = "true" ]; then
    inject_scenario
else
    log "YGG_INJECT_TEST_SCENARIO=false; not injecting a test scenario"
fi

# 6. Optional UI service (only present with --profile full).
wait_for_service "genomics-status" 9761 "genomics-status" 300

# 7. Hand over to yggdrasil.
log "Starting: yggdrasil $*"
exec yggdrasil "$@"