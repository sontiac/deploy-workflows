# shellcheck shell=bash
# Remote job for type "static-site": files served straight from a directory
# (Caddy file_server). bin/deploy builds the site on the Mac from a clean
# export of the commit and uploads it to $RUN_DIR/dist before starting this
# job; the job publishes it, health-checks it and restores the previous files
# if the check fails.
#
# The commit currently live is recorded in $DEPLOY_HOME/state/$NAME.commit
# ("unknown" until the first deploy made by this tool).

STATE_FILE="$DEPLOY_HOME/state/$NAME.commit"

live_commit() {
  if [ -f "$STATE_FILE" ]; then cat "$STATE_FILE"; else printf 'unknown\n'; fi
}

set_live_commit() {
  if [ "$1" = unknown ]; then
    rm -f "$STATE_FILE"
  else
    printf '%s\n' "$1" >"$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  fi
}

health_probe() {
  local code
  code=$(http_status "$HEALTH_URL")
  printf 'HTTP %s' "$code"
  http_ok "$code"
}

publish() {
  section "publish to $REMOTE_PATH"
  rsync -a --delete "$RUN_DIR/dist/" "$REMOTE_PATH/" || return 1
  set_live_commit "$SHA"
}

rollback() {
  local prev=$1
  section "ROLLBACK to the previous files (${prev:0:12})"
  if rsync -a --delete "$RUN_DIR/previous/" "$REMOTE_PATH/" &&
    set_live_commit "$prev" &&
    { section "health check after rollback"; check_health; }; then
    log "ROLLED BACK: the previous files are live again and healthy."
    record_history rolled-back
    return "$EXIT_ROLLED_BACK"
  fi
  log "ROLLBACK FAILED: the site may be down. The previous files are in $RUN_DIR/previous."
  record_history rollback-failed
  return "$EXIT_ROLLBACK_FAILED"
}

job_main() {
  local prev
  section "deploy $NAME ${SHA:0:12} to $REMOTE_PATH (run $RUN_ID, by $DEPLOYED_BY)"

  [ -d "$REMOTE_PATH" ] || { refuse "$REMOTE_PATH does not exist"; return; }
  prev=$(live_commit)
  if [ "$prev" != "$EXPECTED_PREV" ]; then
    refuse "production is at ${prev:0:12}, but this deploy was planned against ${EXPECTED_PREV:0:12}. Someone deployed in between; run deploy again to see the new plan."
    return
  fi
  [ -n "$(ls -A "$RUN_DIR/dist" 2>/dev/null)" ] || { refuse "the uploaded build in $RUN_DIR/dist is missing or empty"; return; }

  section "keep the current files for rollback"
  rsync -a --delete "$REMOTE_PATH/" "$RUN_DIR/previous/" || { refuse "could not copy the current files"; return; }

  # From here on production changes, so every failure ends in a rollback.
  if publish; then
    section "health check"
    if check_health; then
      rm -rf "$RUN_DIR/dist" "$RUN_DIR/previous"
      log "DEPLOYED: $NAME is on ${SHA:0:12} and healthy (was ${prev:0:12})."
      record_history deployed
      return "$EXIT_OK"
    fi
    log "FAILED: the health check did not pass."
  else
    log "FAILED: publishing the files failed (see above)."
  fi
  rollback "$prev"
}
