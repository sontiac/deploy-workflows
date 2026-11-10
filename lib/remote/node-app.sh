# shellcheck shell=bash
# Remote job for type "node-app": a git checkout on the VPS whose processes
# pm2 runs. One checkout can hold several processes (mythology runs a
# frontend and a backend from one repo); they are built together, restarted
# together, health-checked together and rolled back together.
#
# Extra parameters from the generated header (parallel arrays, one entry per process):
#   PROC_NAMES PROC_PORTS PROC_DIRS PROC_BUILDS PROC_PRISMA (empty: no prisma)

# install_and_build migrate|no-migrate
install_and_build() {
  local mode=$1 i name dir
  for i in "${!PROC_NAMES[@]}"; do
    name=${PROC_NAMES[$i]}
    dir="$REMOTE_PATH/${PROC_DIRS[$i]}"
    section "$name: npm ci (in ${PROC_DIRS[$i]})"
    (cd "$dir" && npm ci --no-audit --no-fund) || return 1
    if [ "$mode" = migrate ] && [ -n "${PROC_PRISMA[$i]}" ]; then
      section "$name: prisma migrate deploy (in ${PROC_PRISMA[$i]})"
      (cd "$REMOTE_PATH/${PROC_PRISMA[$i]}" && npx prisma migrate deploy) || return 1
    fi
    section "$name: build: ${PROC_BUILDS[$i]}"
    (cd "$dir" && bash -eo pipefail -c "${PROC_BUILDS[$i]}") || return 1
  done
}

restart_processes() {
  local i
  for i in "${!PROC_NAMES[@]}"; do
    section "pm2 restart ${PROC_NAMES[$i]}"
    (cd "$REMOTE_PATH/${PROC_DIRS[$i]}" && pm2 restart "${PROC_NAMES[$i]}" --update-env) || return 1
  done
  section "pm2 save"
  pm2 save || return 1
}

pm2_status() {
  pm2 jlist 2>/dev/null | node -e '
    let input = "";
    process.stdin.on("data", (chunk) => (input += chunk)).on("end", () => {
      let status = "unknown";
      try {
        const proc = JSON.parse(input).find((p) => p.name === process.argv[1]);
        status = proc ? proc.pm2_env.status : "missing";
      } catch {}
      console.log(status);
    });' "$1"
}

port_listening() {
  timeout 3 bash -c 'exec 3<>"/dev/tcp/127.0.0.1/$1"' _ "$1" 2>/dev/null
}

# Healthy = every process is online in pm2 and accepting connections on its
# port, and health_url answers 2xx/3xx.
health_probe() {
  local failed=0 i status port code detail=""
  for i in "${!PROC_NAMES[@]}"; do
    status=$(pm2_status "${PROC_NAMES[$i]}")
    port=${PROC_PORTS[$i]}
    if port_listening "$port"; then
      detail+="${PROC_NAMES[$i]}=$status,:$port open  "
    else
      detail+="${PROC_NAMES[$i]}=$status,:$port closed  "
      failed=1
    fi
    [ "$status" = online ] || failed=1
  done
  code=$(http_status "$HEALTH_URL")
  http_ok "$code" || failed=1
  printf '%sHTTP %s' "$detail" "$code"
  return "$failed"
}

release() {
  section "checkout ${SHA:0:12}"
  git -C "$REMOTE_PATH" reset --hard "$SHA" || return 1
  install_and_build migrate || return 1
  restart_processes
}

rollback() {
  local prev=$1
  section "ROLLBACK to ${prev:0:12}"
  if git -C "$REMOTE_PATH" reset --hard "$prev" &&
    install_and_build no-migrate &&
    restart_processes &&
    { section "health check after rollback"; check_health; }; then
    log "ROLLED BACK: production is on ${prev:0:12} again and healthy."
    record_history rolled-back
    return "$EXIT_ROLLED_BACK"
  fi
  log "ROLLBACK FAILED: production may be down. Look now: pm2 status; pm2 logs <process>; cd $REMOTE_PATH && git log -1"
  record_history rollback-failed
  return "$EXIT_ROLLBACK_FAILED"
}

job_main() {
  local prev
  section "deploy $NAME ${SHA:0:12} to $REMOTE_PATH (run $RUN_ID, by $DEPLOYED_BY)"

  prev=$(git -C "$REMOTE_PATH" rev-parse HEAD) || { refuse "$REMOTE_PATH is not a git checkout"; return; }
  if [ "$prev" != "$EXPECTED_PREV" ]; then
    refuse "production is at ${prev:0:12}, but this deploy was planned against ${EXPECTED_PREV:0:12}. Someone deployed in between; run deploy again to see the new plan."
    return
  fi

  section "git fetch ${SHA:0:12}"
  git -C "$REMOTE_PATH" fetch --depth=1 origin "$SHA" || { refuse "could not fetch ${SHA:0:12} from origin"; return; }

  # From here on production changes, so every failure ends in a rollback.
  if release; then
    section "health check"
    if check_health; then
      log "DEPLOYED: $NAME is on ${SHA:0:12} and healthy (was ${prev:0:12})."
      record_history deployed
      return "$EXIT_OK"
    fi
    log "FAILED: the health check did not pass."
  else
    log "FAILED: a release step failed (see above)."
  fi
  rollback "$prev"
}
