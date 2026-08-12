#!/usr/bin/env bash
#
# End-to-end repair for studies affected by the synchronizeStudy() StudyDate/StudyTime
# bug (commit 82dc38a0): FETCH the affected list from production Postgres, DRY RUN the
# proposed dcm4chee changes, then APPLY only after an explicit interactive confirmation
# (or --yes to skip the prompt for unattended runs).
#
# STAGES (always run in this order, every run):
#   1. FETCH   - runs identify-affected-studies.sql (read-only) against the production
#                Postgres backing dcm4chee/RIS/FHIR, via `kubectl exec psql`. Writes
#                affected-studies-<timestamp>.csv. Never modifies the database.
#   2. DRY RUN - for every row, fetches the study's current full attribute set from
#                dcm4chee and prints current vs. proposed StudyDate/StudyTime. No writes.
#   3. CONFIRM - prints a summary and asks "type APPLY to proceed" (skipped with --yes).
#   4. APPLY   - only reached after confirmation. For each row: re-fetches the study's
#                current state immediately before writing (protects against drift between
#                dry run and apply), sends a PUT with every existing field copied through
#                verbatim plus the corrected StudyDate/StudyTime, then re-fetches and
#                verifies the write. Lesson learned the hard way in dev/staging: dcm4chee's
#                PUT /studies/{uid} REPLACES the whole attribute set - any tag you omit
#                gets WIPED, not left alone. Stops immediately on any write failure or
#                verification mismatch unless --continue-on-mismatch is passed.
#
# Every stage is appended to a single timestamped log file for an audit trail.
#
# REQUIREMENTS: curl, jq, kubectl (with a working context reaching the db/arc pods)
#
# USAGE
#   Runs directly, no arguments required - defaults to --base-url
#   http://10.0.0.11/dcm4chee-arc/aets/DCM4CHEE/rs and --bug-introduced-at
#   "2026-07-28 04:58:37+00" (the last confirmed values for this deployment):
#     ./backfill-study-datetime-prod.sh
#
#   Override either default explicitly, e.g. investigating a different window:
#     ./backfill-study-datetime-prod.sh --bug-introduced-at "2026-06-01 00:00:00+00"
#
#   Non-interactive (e.g. re-running a previously-reviewed window unattended):
#     ./backfill-study-datetime-prod.sh --yes
#
#   Skip the fetch stage and reuse a CSV you already have:
#     ./backfill-study-datetime-prod.sh --input-csv affected.csv
#
#   Apply one row at a time, confirming each write before moving on (with the option to
#   switch to running the rest automatically once you trust the results):
#     ./backfill-study-datetime-prod.sh --step
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_FILE="$SCRIPT_DIR/identify-affected-studies.sql"

DEFAULT_BASE_URL="http://10.0.0.11/dcm4chee-arc/aets/DCM4CHEE/rs"
DEFAULT_BUG_INTRODUCED_AT="2026-07-28 04:58:37+00"

BASE_URL="$DEFAULT_BASE_URL"
TOKEN=""
INPUT_CSV=""
BUG_INTRODUCED_AT="$DEFAULT_BUG_INTRODUCED_AT"
BUG_FIXED_AT="now()"
YES=0
CONTINUE_ON_MISMATCH=0

BATCH_SIZE=25
BATCH_DELAY=5
MAX_RETRIES=4
RETRY_DELAY=2
CURL_TIMEOUT=30
STEP=0

DB_NAMESPACE="supabase"
DB_DEPLOY="deploy/visionx-supabase-db"
DB_NAME="postgres"
DB_USER="supabase_admin"
CRED_NAMESPACE="dcm4chee"
CRED_DEPLOY="deploy/arc"
CRED_ENV_VAR="POSTGRES_PASSWORD"

usage() {
  cat <<EOF
Usage: backfill-study-datetime-prod.sh [options]

Runs with no arguments using these defaults, so it can be launched directly:
  --base-url             $DEFAULT_BASE_URL
  --bug-introduced-at    $DEFAULT_BUG_INTRODUCED_AT

IMPORTANT: --bug-introduced-at defaults to the last confirmed value for THIS
deployment. If the bug window changes (e.g. investigating a different/wider
incident), pass --bug-introduced-at explicitly rather than trusting the default.

Fetch stage (skip with --input-csv):
  --bug-introduced-at TS     UTC timestamp the buggy synchronizeStudy() first shipped to
                              THIS production deployment.
  --bug-fixed-at TS          UTC timestamp the fix was deployed (default: now()).
  --db-namespace NS          k8s namespace of the Postgres pod (default: supabase)
  --db-deploy NAME           k8s deploy/pod ref for Postgres, e.g. deploy/visionx-supabase-db
  --cred-namespace NS        k8s namespace of a pod whose env has the DB password (default: dcm4chee)
  --cred-deploy NAME         k8s deploy/pod ref to read POSTGRES_PASSWORD from (default: deploy/arc)
  --input-csv FILE           Skip the fetch stage and use this CSV instead.

Common:
  --base-url URL             dcm4chee REST base URL (default: $DEFAULT_BASE_URL)
  --token TOKEN               Bearer token, only if dcm4chee requires auth.
  --yes                       Skip the interactive confirmation before applying writes.
  --continue-on-mismatch      Keep processing remaining rows after a verification mismatch.

Throttling & retries (both DRY RUN and APPLY):
  --batch-size N              Rows per batch before pausing (default: $BATCH_SIZE).
  --batch-delay SECONDS       Pause between batches (default: $BATCH_DELAY).
  --max-retries N             Retries per HTTP call on timeout/connection error/5xx
                                (default: $MAX_RETRIES). 4xx responses are not retried.
  --retry-delay SECONDS       Base delay before the first retry; doubles each attempt
                                (default: $RETRY_DELAY).
  --curl-timeout SECONDS      Per-request curl timeout (default: $CURL_TIMEOUT).

Step mode:
  --step                      APPLY one row at a time. After each write, pause and ask
                                whether to continue one-by-one, run all remaining rows
                                automatically, or quit. Lets you confirm the first few
                                writes look right before trusting the rest to run.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url) BASE_URL="$2"; shift 2 ;;
    --token) TOKEN="$2"; shift 2 ;;
    --input-csv) INPUT_CSV="$2"; shift 2 ;;
    --bug-introduced-at) BUG_INTRODUCED_AT="$2"; shift 2 ;;
    --bug-fixed-at) BUG_FIXED_AT="$2"; shift 2 ;;
    --db-namespace) DB_NAMESPACE="$2"; shift 2 ;;
    --db-deploy) DB_DEPLOY="$2"; shift 2 ;;
    --cred-namespace) CRED_NAMESPACE="$2"; shift 2 ;;
    --cred-deploy) CRED_DEPLOY="$2"; shift 2 ;;
    --yes) YES=1; shift ;;
    --continue-on-mismatch) CONTINUE_ON_MISMATCH=1; shift ;;
    --batch-size) BATCH_SIZE="$2"; shift 2 ;;
    --batch-delay) BATCH_DELAY="$2"; shift 2 ;;
    --max-retries) MAX_RETRIES="$2"; shift 2 ;;
    --retry-delay) RETRY_DELAY="$2"; shift 2 ;;
    --curl-timeout) CURL_TIMEOUT="$2"; shift 2 ;;
    --step) STEP=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
command -v jq   >/dev/null || { echo "jq is required"   >&2; exit 1; }

TS="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$SCRIPT_DIR/backfill-study-datetime-prod-$TS.log"
log() { printf '%s  %s\n' "$(date -Is)" "$*" | tee -a "$LOG_FILE"; }

log "base-url: $BASE_URL$([[ "$BASE_URL" == "$DEFAULT_BASE_URL" ]] && echo ' (default)')"
if [[ -z "$INPUT_CSV" ]]; then
  log "bug-introduced-at: $BUG_INTRODUCED_AT$([[ "$BUG_INTRODUCED_AT" == "$DEFAULT_BUG_INTRODUCED_AT" ]] && echo ' (default - pass --bug-introduced-at explicitly if investigating a different window)')"
fi

AUTH_HEADER=()
if [[ -n "$TOKEN" ]]; then
  AUTH_HEADER=(-H "Authorization: Bearer $TOKEN")
  log "dcm4chee auth: bearer token supplied"
else
  log "dcm4chee auth: none (unauthenticated endpoint)"
fi

# ---------------------------------------------------------------------------
# Stage 1: FETCH (read-only) - reuse --input-csv if given
# ---------------------------------------------------------------------------
if [[ -n "$INPUT_CSV" ]]; then
  [[ -f "$INPUT_CSV" ]] || { echo "Input CSV not found: $INPUT_CSV" >&2; exit 1; }
  log "FETCH: skipped, reusing existing CSV: $INPUT_CSV"
else
  command -v kubectl >/dev/null || { echo "kubectl is required to fetch (or pass --input-csv)" >&2; exit 1; }
  [[ -f "$SQL_FILE" ]] || { echo "SQL file not found: $SQL_FILE" >&2; exit 1; }

  log "FETCH: bug_introduced_at=$BUG_INTRODUCED_AT bug_fixed_at=$BUG_FIXED_AT"
  log "FETCH: reading DB credentials from $CRED_NAMESPACE/$CRED_DEPLOY env:$CRED_ENV_VAR"

  DB_PASSWORD="$(kubectl exec -n "$CRED_NAMESPACE" "$CRED_DEPLOY" -- env 2>/dev/null \
    | grep "^${CRED_ENV_VAR}=" | cut -d= -f2-)"
  if [[ -z "$DB_PASSWORD" ]]; then
    echo "Could not read $CRED_ENV_VAR from $CRED_NAMESPACE/$CRED_DEPLOY" >&2
    exit 1
  fi

  INPUT_CSV="$SCRIPT_DIR/affected-studies-$TS.csv"
  log "FETCH: querying $DB_NAMESPACE/$DB_DEPLOY (read-only) -> $INPUT_CSV"

  if ! cat "$SQL_FILE" | kubectl exec -i -n "$DB_NAMESPACE" "$DB_DEPLOY" -- env PGPASSWORD="$DB_PASSWORD" \
      psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 \
      -v "bug_introduced_at=$BUG_INTRODUCED_AT" -v "bug_fixed_at=$BUG_FIXED_AT" \
      --csv > "$INPUT_CSV"; then
    echo "Fetch query failed - see output above." >&2
    exit 1
  fi
  unset DB_PASSWORD

  row_count=$(($(wc -l < "$INPUT_CSV") - 1))
  log "FETCH: $row_count affected study row(s) written to $INPUT_CSV"
  if [[ "$row_count" -le 0 ]]; then
    log "FETCH: no affected studies found for this window - nothing to do."
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# Stage 2: DRY RUN - always runs, never writes
# ---------------------------------------------------------------------------
PRESERVE_FIELDS="00100020,00080050,00081030,00080090,001021B0"
FIELD_LIST="${PRESERVE_FIELDS},00080020,00080030,0020000D"

strip_quotes() {
  local s="$1"
  s="${s%\"}"; s="${s#\"}"
  printf '%s' "$s"
}

# GET with retry/backoff on curl failure (timeout, connection reset, DNS, etc) -
# a non-2xx response also counts as failure via -f. Retries MAX_RETRIES times total.
http_get_retry() {
  local url="$1" attempt=1 out delay
  while true; do
    if out=$(curl -sf --max-time "$CURL_TIMEOUT" "${AUTH_HEADER[@]}" -H "Accept: application/dicom+json" "$url"); then
      printf '%s' "$out"
      return 0
    fi
    if [[ $attempt -ge $MAX_RETRIES ]]; then
      return 1
    fi
    delay=$((RETRY_DELAY * (2 ** (attempt - 1))))
    log "  GET failed, retry $attempt/$MAX_RETRIES in ${delay}s: $url"
    sleep "$delay"
    attempt=$((attempt + 1))
  done
}

# PUT with retry/backoff, but only on transient failures: curl-level errors (timeout,
# connection reset) or 5xx (server overwhelmed). A 4xx is a client-side/data problem and
# won't succeed on retry, so it's returned immediately. Sets http_code and resp_body.
http_put_retry() {
  local url="$1" payload="$2" attempt=1 delay resp_file
  while true; do
    resp_file=$(mktemp)
    http_code=$(curl -s -o "$resp_file" -w '%{http_code}' --max-time "$CURL_TIMEOUT" -X PUT \
      "${AUTH_HEADER[@]}" -H "Content-Type: application/json" "$url" -d "$payload")
    resp_body=$(cat "$resp_file")
    rm -f "$resp_file"

    if [[ "$http_code" -lt 300 ]]; then
      return 0
    fi
    if [[ "$http_code" -lt 500 || $attempt -ge $MAX_RETRIES ]]; then
      return 1
    fi
    delay=$((RETRY_DELAY * (2 ** (attempt - 1))))
    log "  PUT HTTP $http_code, retry $attempt/$MAX_RETRIES in ${delay}s: $url"
    sleep "$delay"
    attempt=$((attempt + 1))
  done
}

# Pause every BATCH_SIZE rows so a large run doesn't hammer the server continuously.
batch_pause() {
  local n="$1"
  if (( BATCH_SIZE > 0 && n % BATCH_SIZE == 0 )); then
    log "Batch pause: $n row(s) processed, sleeping ${BATCH_DELAY}s"
    sleep "$BATCH_DELAY"
  fi
}

# --step support: after each APPLY write outcome, ask the operator whether to continue.
# STEP_AUTO=1 once the operator chooses "all", so remaining rows run without asking again.
# STEP_QUIT=1 signals the APPLY loop to stop after the current row.
STEP_AUTO=0
STEP_QUIT=0
step_confirm() {
  local label="$1" choice
  [[ $STEP -eq 1 && $STEP_AUTO -ne 1 ]] || return 0
  echo
  read -r -p "$label -- [c]ontinue one at a time, [a]ll remaining automatically, [q]uit now: " choice
  case "$choice" in
    a|A) STEP_AUTO=1; log "STEP: operator chose to run remaining rows automatically." ;;
    q|Q) log "STEP: operator stopped after this row."; STEP_QUIT=1 ;;
    *) : ;;
  esac
}

fetch_current() {
  # sets: current_json, patient_id, cur_da, cur_tm, cur_acc, cur_desc, cur_ref, cur_clin
  local uid="$1"
  current_json=$(http_get_retry "$BASE_URL/studies?StudyInstanceUID=$uid&includefield=$FIELD_LIST") || return 1
  [[ "$(echo "$current_json" | jq 'length')" -gt 0 ]] || return 1
  patient_id=$(echo "$current_json" | jq -r '.[0]["00100020"].Value[0] // empty')
  [[ -n "$patient_id" ]] || return 1
  cur_da=$(echo "$current_json"   | jq -r '.[0]["00080020"].Value[0] // "(empty)"')
  cur_tm=$(echo "$current_json"   | jq -r '.[0]["00080030"].Value[0] // "(empty)"')
  cur_acc=$(echo "$current_json"  | jq -r '.[0]["00080050"].Value[0] // "(empty)"')
  cur_desc=$(echo "$current_json" | jq -r '.[0]["00081030"].Value[0] // "(empty)"')
  cur_ref=$(echo "$current_json"  | jq -r '.[0]["00080090"].Value[0].Alphabetic // "(empty)"')
  cur_clin=$(echo "$current_json" | jq -r '.[0]["001021B0"].Value[0] // "(empty)"')
  return 0
}

log "DRY RUN: previewing changes for $(($(wc -l < "$INPUT_CSV") - 1)) row(s), no writes yet"

dry_processed=0; dry_skipped=0; dry_row_num=0
while IFS=',' read -r accession_no study_iuid current_da current_tm new_da new_tm source_dt; do
  dry_row_num=$((dry_row_num + 1))
  accession_no=$(strip_quotes "$accession_no")
  study_iuid=$(strip_quotes "$study_iuid")
  new_da=$(strip_quotes "$new_da")
  new_tm=$(strip_quotes "$new_tm")

  if [[ -z "$new_da" || -z "$new_tm" ]]; then
    log "SKIP $accession_no ($study_iuid): no source exam date/time in CSV row - needs manual investigation."
    dry_skipped=$((dry_skipped + 1))
    batch_pause "$dry_row_num"
    continue
  fi

  if ! fetch_current "$study_iuid"; then
    log "SKIP $accession_no ($study_iuid): study not found, empty response, or no PatientID - refusing to touch."
    dry_skipped=$((dry_skipped + 1))
    batch_pause "$dry_row_num"
    continue
  fi

  log "---- $accession_no ($study_iuid) ----"
  log "  Current:  StudyDate=$cur_da StudyTime=$cur_tm Accession=$cur_acc Desc=$cur_desc RefPhysician=$cur_ref Clinical=$cur_clin"
  log "  Proposed: StudyDate=$new_da StudyTime=$new_tm  (all other fields preserved as-is)"
  dry_processed=$((dry_processed + 1))
  batch_pause "$dry_row_num"
done < <(tail -n +2 "$INPUT_CSV")

log "DRY RUN summary: previewed=$dry_processed skipped=$dry_skipped"

if [[ "$dry_processed" -le 0 ]]; then
  log "Nothing eligible to apply. Stopping."
  exit 0
fi

# ---------------------------------------------------------------------------
# Stage 3: CONFIRM
# ---------------------------------------------------------------------------
if [[ $YES -ne 1 ]]; then
  echo
  echo "About to APPLY ${dry_processed} write(s) to production dcm4chee at $BASE_URL"
  echo "(${dry_skipped} row(s) will be skipped - see log above for why)."
  read -r -p "Type APPLY to proceed, anything else to abort: " confirm
  if [[ "$confirm" != "APPLY" ]]; then
    log "CONFIRM: aborted by operator (did not type APPLY)."
    exit 1
  fi
  log "CONFIRM: operator typed APPLY, proceeding."
else
  log "CONFIRM: --yes supplied, skipping interactive prompt."
fi

# ---------------------------------------------------------------------------
# Stage 4: APPLY - re-fetches immediately before each write, verifies after
# ---------------------------------------------------------------------------
applied=0; skipped=0; mismatches=0; total=0

while IFS=',' read -r accession_no study_iuid current_da current_tm new_da new_tm source_dt; do
  total=$((total + 1))
  accession_no=$(strip_quotes "$accession_no")
  study_iuid=$(strip_quotes "$study_iuid")
  new_da=$(strip_quotes "$new_da")
  new_tm=$(strip_quotes "$new_tm")

  if [[ -z "$new_da" || -z "$new_tm" ]]; then
    skipped=$((skipped + 1))
    batch_pause "$total"
    continue
  fi

  if ! fetch_current "$study_iuid"; then
    log "SKIP $accession_no ($study_iuid): study not found, empty response, or no PatientID at apply time."
    skipped=$((skipped + 1))
    batch_pause "$total"
    continue
  fi

  payload=$(echo "$current_json" | jq -c --arg uid "$study_iuid" --arg da "$new_da" --arg tm "$new_tm" '
    {
      "0020000D": {"vr":"UI","Value":[$uid]},
      "00080020": {"vr":"DA","Value":[$da]},
      "00080030": {"vr":"TM","Value":[$tm]},
      "00100020": .[0]["00100020"],
      "00080050": .[0]["00080050"],
      "00081030": .[0]["00081030"],
      "00080090": .[0]["00080090"],
      "001021B0": .[0]["001021B0"]
    }')

  if ! http_put_retry "$BASE_URL/studies/$study_iuid" "$payload"; then
    log "WRITE FAILED $accession_no ($study_iuid) HTTP $http_code: $resp_body"
    if [[ $CONTINUE_ON_MISMATCH -ne 1 ]]; then
      log "Stopping (pass --continue-on-mismatch to keep going)."
      break
    fi
    step_confirm "Row $total: $accession_no ($study_iuid) - WRITE FAILED"
    batch_pause "$total"
    [[ $STEP_QUIT -eq 1 ]] && break
    continue
  fi

  after_json=$(http_get_retry "$BASE_URL/studies?StudyInstanceUID=$study_iuid&includefield=$FIELD_LIST") || after_json='[]'
  after_da=$(echo "$after_json"   | jq -r '.[0]["00080020"].Value[0] // empty')
  after_tm=$(echo "$after_json"   | jq -r '.[0]["00080030"].Value[0] // empty')
  after_acc=$(echo "$after_json"  | jq -r '.[0]["00080050"].Value[0] // empty')
  after_desc=$(echo "$after_json" | jq -r '.[0]["00081030"].Value[0] // empty')

  ok=1
  [[ "$after_da" == "$new_da" ]]   || ok=0
  [[ "$after_tm" == "$new_tm" ]]   || ok=0
  [[ "$after_acc" == "$cur_acc" ]] || ok=0
  [[ "$after_desc" == "$cur_desc" ]] || ok=0

  if [[ $ok -eq 1 ]]; then
    log "OK $accession_no ($study_iuid): StudyDate/StudyTime backfilled and verified."
    applied=$((applied + 1))
    step_confirm "Row $total: $accession_no ($study_iuid) - OK"
  else
    log "MISMATCH $accession_no ($study_iuid) after write! Accession=$after_acc Desc=$after_desc DA=$after_da TM=$after_tm"
    mismatches=$((mismatches + 1))
    if [[ $CONTINUE_ON_MISMATCH -ne 1 ]]; then
      log "Stopping due to mismatch (pass --continue-on-mismatch to keep going after review)."
      break
    fi
    step_confirm "Row $total: $accession_no ($study_iuid) - MISMATCH"
  fi
  batch_pause "$total"
  [[ $STEP_QUIT -eq 1 ]] && break
done < <(tail -n +2 "$INPUT_CSV")

log "==== Summary: total_rows=$total applied=$applied skipped=$skipped mismatches=$mismatches ===="
