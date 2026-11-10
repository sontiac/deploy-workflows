# shellcheck shell=bash
# Shared part of every remote deploy job.
#
# bin/deploy generates one self-contained job script per run: a parameter
# block, this file, the file for the app's type (node-app.sh or
# static-site.sh), and a final `job_entry "$@"`. The job runs on the VPS,
# detached from the SSH session, so a laptop that sleeps or drops off the
# network cannot interrupt a deploy halfway.
#
# The job does not use `set -e`; every step checks its own status, so the
# rollback logic cannot be silently disabled by errexit's context rules.
#
# Parameters every job gets from the generated header:
#   DEPLOY_HOME RUN_ID RUN_DIR NAME SHA EXPECTED_PREV HEALTH_URL REMOTE_PATH DEPLOYED_BY
# The type file must define:
#   job_main      the deploy itself; returns one of the EXIT_* codes below
#   health_probe  one health observation; prints a short detail, returns 0 when healthy

# Exit codes. bin/deploy mirrors these; keep the two lists in sync.
# shellcheck disable=SC2034 # used by the type files
EXIT_OK=0
EXIT_REFUSED=10          # refused before changing anything
EXIT_LOCKED=11           # another deploy of this app holds the lock; nothing changed
EXIT_ROLLED_BACK=20      # the release failed; production is back on the previous version
EXIT_ROLLBACK_FAILED=30  # the release failed and the rollback failed too

HEALTH_ATTEMPTS=6
HEALTH_INTERVAL_SECONDS=5
RUN_RETENTION_DAYS=30

log() { printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$*"; }
section() { log "==> $*"; }

refuse() {
  log "REFUSED: $*"
  log "Production was not changed."
  record_history refused
  return "$EXIT_REFUSED"
}

record_history() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$NAME" "$SHA" "$1" "$RUN_ID" "$DEPLOYED_BY" \
    >>"$DEPLOY_HOME/history.tsv"
}

# Prints the HTTP status of a GET, or 000 when the request fails outright.
# -k because this checks the app, not the certificate (same as the old workflow).
http_status() {
  local code
  code=$(curl -k -s -o /dev/null --max-time 10 -w '%{http_code}' "$1") || code=000
  printf '%s' "$code"
}

http_ok() { [[ $1 =~ ^[23][0-9][0-9]$ ]]; }

# Polls health_probe until it passes, HEALTH_ATTEMPTS times, HEALTH_INTERVAL_SECONDS apart.
check_health() {
  local attempt detail
  for ((attempt = 1; attempt <= HEALTH_ATTEMPTS; attempt++)); do
    sleep "$HEALTH_INTERVAL_SECONDS"
    if detail=$(health_probe); then
      log "health $attempt/$HEALTH_ATTEMPTS: OK  $detail"
      return 0
    fi
    log "health $attempt/$HEALTH_ATTEMPTS: not yet  $detail"
  done
  return 1
}

# Entry point. Without arguments: take this app's lock and re-run the job
# while holding it. `flock -o` keeps the lock in flock's own process, so
# nothing the job starts (npm, a pm2 daemon spawned on demand) can inherit
# it and keep the app locked after the deploy ends.
job_entry() {
  if [ "${1:-}" = "--locked" ]; then
    printf 'run:   %s\nby:    %s\nsince: %s\n' "$RUN_ID" "$DEPLOYED_BY" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      >"$DEPLOY_HOME/locks/$NAME.holder"
    job_main
    exit $?
  fi

  mkdir -p "$DEPLOY_HOME/locks" "$DEPLOY_HOME/state"
  find "$DEPLOY_HOME/runs" -mindepth 1 -maxdepth 1 -type d -mtime "+$RUN_RETENTION_DAYS" -exec rm -rf {} + 2>/dev/null

  local rc
  flock -n -o -E "$EXIT_LOCKED" "$DEPLOY_HOME/locks/$NAME.lock" bash "$RUN_DIR/job.sh" --locked
  rc=$?
  if [ "$rc" -eq "$EXIT_LOCKED" ]; then
    log "REFUSED: another deploy of $NAME is running:"
    sed 's/^/    /' "$DEPLOY_HOME/locks/$NAME.holder" 2>/dev/null
    log "Production was not changed by this run."
    record_history locked
  fi
  printf '%s\n' "$rc" >"$RUN_DIR/exit-code"
  exit "$rc"
}
