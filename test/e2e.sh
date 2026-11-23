#!/usr/bin/env bash
# End-to-end test of bin/deploy against a Docker container standing in for
# the VPS. Nothing touches the real VPS.
#
# A fake `ssh` on PATH routes every ssh call (the deploy's own and git's)
# into the container; pm2 is a stub that runs `node server.js`; git, npm,
# flock, setsid, GNU tail, rsync, PostgreSQL 16 (pg_dump, pg_restore, psql)
# and prisma are real.
#
# Covers, for every app: a good deploy, a failed build and a failed health
# check (both rolled back), a held lock, unpushed commits, an invalid
# deploy.json, a static site's deploy and rollback, and that the job
# generated for an app without "migrations": "offline" is the job the tool
# generated before offline migrations existed plus one dead branch.
#
# Covers, for an app with "migrations": "offline" (a tiny real prisma app on a
# real PostgreSQL 16, the database owned by a role that is not a superuser
# and cannot create databases, like production's):
#   - the dry run prints the offline plan and changes nothing
#   - nothing pending: no stop, no dump, a restart
#   - pending migrations succeed: the app was stopped while they ran, the
#     dump exists (modes 700/600), the new schema is live and healthy
#   - the second of two pending migrations fails: the database is restored
#     exactly (schema fingerprint, every table's contents, _prisma_migrations),
#     the previous code is healthy, exit 20
#   - the migrations succeed (one drops a column that holds data) but the new
#     version fails its health check: the column and its data come back, exit 20
#   - the build fails: the app was never stopped, the database is untouched, exit 20
#   - preflight refusals, each exit 10 with nothing changed: an extra schema,
#     a missing pg_dump, an object another role owns, a failed migration
#     already recorded, a DATABASE_URL parameter the tools cannot honour, a
#     schema other than public in it, a grant on a shared object, a large object
#   - the password appears neither in the run logs and job scripts nor in the
#     process list during the three pauses, and never reaches the app's environment
#   - retention keeps the newest five dumps
#   - the restore fails (the dump is damaged after it was taken): exit 30, nothing
#     is started, the true process state and `job.sh --recover` are printed,
#     nothing is half restored; recovering with the dump still damaged ends in
#     30 with nothing changed; with the good dump back it ends in 20 and the
#     database is exact
#   - retention picks by the host's modification time and never removes the current dump
#   - the Prisma schema of the new commit must use env("DATABASE_URL") and no directUrl
#   - an OFFLINE_SCHEMA_DIR in the remote environment does not turn an online app offline
#   - sequence positions are restored too
#   - deploy.json validation of "migrations"
#
# Not covered: a real pm2 (its stop/restart-from-stopped behaviour was checked
# by hand against pm2 7 and the stub copies it), a non-root deploy user, a
# database on another host, TLS (sslmode), a database larger than a few
# kilobytes (free-space and timing limits are read, not exercised), macOS.
#
# Needs docker and network access (image pull, apt, npm, prisma engines,
# npm audit). Run: test/e2e.sh
# E2E_SCENARIOS=legacy|offline runs only that half while developing.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DEPLOY="$ROOT/bin/deploy"
CONTAINER="deploy-e2e-$$"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/deploy-e2e.XXXXXX")
FAILURES=0
SCENARIOS=${E2E_SCENARIOS:-all}
# The last commit before offline migrations existed: its tool is the baseline for the "same job" check.
BASELINE_COMMIT=fd9b573

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

on_box() { docker exec -i -w /root "$CONTAINER" bash -c "$1"; }

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

# expect_deploy <description> <expected exit code> [deploy args...]; run in the app repo
expect_deploy() {
  local description=$1 expected=$2 rc=0
  shift 2
  # DEPLOY_VIA=/bin/bash runs the command under macOS's bash 3.2.
  "${DEPLOY_VIA:-$DEPLOY}" ${DEPLOY_VIA:+"$DEPLOY"} "$@" >"$WORK/last.log" 2>&1 || rc=$?
  cat "$WORK/last.log" >>"$WORK/all.log"
  if [ "$rc" -eq "$expected" ]; then pass "$description (exit $rc)"; else
    fail "$description: expected exit $expected, got $rc"
    sed 's/^/      /' "$WORK/last.log"
  fi
}

expect_equal() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$3', got '$2'"; fi
}

# expect_log <description> <fixed text>: the last deploy's output contains the text
expect_log() {
  if grep -qF -- "$2" "$WORK/last.log"; then pass "$1"; else
    fail "$1: the output does not contain '$2'"
    sed 's/^/      /' "$WORK/last.log"
  fi
}

expect_no_log() {
  if grep -qF -- "$2" "$WORK/last.log"; then fail "$1: the output contains '$2'"; else pass "$1"; fi
}

commit_and_push() { git add -A && git commit -qm "$1" && git push -q origin main; }

# ------------------------------------------------------------- the fake VPS

mkdir -p "$WORK/bin"
cat >"$WORK/bin/ssh" <<EOF
#!/usr/bin/env bash
# Test double for ssh: run the remote command in the container, from the home directory.
while [ \$# -gt 0 ]; do
  case \$1 in
    -o | -e | -i | -p | -l) shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
shift # the host
exec docker exec -i -w /root \${E2E_DOCKER_ARGS:-} $CONTAINER bash -c "\$*"
EOF
chmod +x "$WORK/bin/ssh"
export PATH="$WORK/bin:$PATH"

docker run -d --init --name "$CONTAINER" node:22-bookworm sleep infinity >/dev/null
on_box 'apt-get update -qq >/dev/null && apt-get install -y -qq rsync >/dev/null'
on_box 'cat >/usr/local/bin/pm2 && chmod +x /usr/local/bin/pm2' <<'EOF'
#!/usr/bin/env bash
# Test double for pm2: one `node server.js` per name, started from the current directory.
# Like pm2 7 (checked by hand): restart also starts a stopped process, stop keeps the entry
# with status "stopped" and fails for an unknown name. Every call is logged to calls.log.
state=/tmp/fake-pm2
mkdir -p "$state"
printf '%s %s\n' "$(date +%s.%N)" "$*" >>"$state/calls.log"

alive() {
  local pid stat
  [ -f "$state/$1.pid" ] || return 1
  pid=$(cat "$state/$1.pid")
  stat=$(ps -o stat= -p "$pid" 2>/dev/null) || return 1
  [ -n "$stat" ] && [ "${stat:0:1}" != Z ]
}
terminate() {
  alive "$1" || return 0
  kill "$(cat "$state/$1.pid")"
  while alive "$1"; do sleep 0.1; done
}

case $1 in
  restart)
    terminate "$2"
    setsid nohup node server.js >"$state/$2.log" 2>&1 </dev/null &
    echo $! >"$state/$2.pid" ;;
  stop)
    [ -f "$state/$2.pid" ] || { echo "[PM2][ERROR] Process or Namespace $2 not found" >&2; exit 1; }
    terminate "$2" ;;
  save) ;;
  jlist)
    printf '['; sep=''
    for f in "$state"/*.pid; do
      [ -e "$f" ] || continue
      name=$(basename "$f" .pid)
      if alive "$name"; then s=online; else s=stopped; fi
      printf '%s{"name":"%s","pm2_env":{"status":"%s"}}' "$sep" "$name" "$s"; sep=,
    done
    printf ']\n' ;;
  *) echo "fake pm2: unsupported: $*" >&2; exit 1 ;;
esac
EOF
# Serves /srv/site; answers 500 when index.html says BROKEN.
on_box 'cat >/srv/static-server.js' <<'EOF'
const http = require("http"), fs = require("fs");
http.createServer((req, res) => {
  let body;
  try { body = fs.readFileSync("/srv/site/index.html", "utf8"); } catch { res.writeHead(404); return res.end(); }
  res.writeHead(body.includes("BROKEN") ? 500 : 200); res.end(body);
}).listen(4124, "127.0.0.1");
EOF
on_box 'git config --global init.defaultBranch main && git config --global safe.directory "*" &&
  git init -q --bare /srv/origin/app.git && git init -q --bare /srv/origin/site.git && git init -q --bare /srv/origin/offapp.git &&
  mkdir -p /srv/site && echo "site v0" >/srv/site/index.html &&
  (setsid nohup node /srv/static-server.js >/dev/null 2>&1 </dev/null &)'

live() { on_box 'git -C /srv/app rev-parse HEAD'; }
http_code() { on_box "curl -s -o /dev/null -w '%{http_code}' $1"; }

# The newest run's job script, with the lines that name the run, the person or the commit that was live removed.
latest_job() {
  on_box 'cat "$(ls -d ~/.deploy/runs/*/ | tail -n 1)job.sh"' |
    sed -E '/^# deploy job /d; s/^RUN_ID=.*/RUN_ID=<run>/; s/^DEPLOYED_BY=.*/DEPLOYED_BY=<by>/; s/^EXPECTED_PREV=.*/EXPECTED_PREV=<live commit>/'
}

# ------------------------------------------------------------- node-app and static-site

legacy_scenarios() {
  mkdir -p "$WORK/app" && cd "$WORK/app"
  git init -q -b main && git remote add origin box:/srv/origin/app.git
  cat >package.json <<'EOF'
{ "name": "e2e-app", "version": "1.0.0", "private": true, "scripts": { "build": "node build.js" } }
EOF
  npm install --package-lock-only --silent
  cat >build.js <<'EOF'
const fs = require("fs");
if (fs.existsSync("fail-build")) { console.error("build fails on purpose"); process.exit(1); }
fs.writeFileSync("built.txt", fs.readFileSync("status.txt", "utf8").trim());
EOF
  cat >server.js <<'EOF'
const http = require("http"), fs = require("fs");
http.createServer((req, res) => { const code = Number(fs.readFileSync("built.txt", "utf8")); res.writeHead(code); res.end(); })
  .listen(4123, "127.0.0.1");
EOF
  echo 200 >status.txt
  printf 'built.txt\nnode_modules\n' >.gitignore
  cat >deploy.json <<'EOF'
{
  "name": "e2e-app",
  "type": "node-app",
  "host": "box",
  "remote_path": "/srv/app",
  "health_url": "http://127.0.0.1:4123/",
  "audit_fail_on": "critical",
  "processes": [
    { "pm2_name": "e2e-web", "port": 4123, "working_dir": ".", "build_cmd": "npm run build && echo \"it's built\"" }
  ]
}
EOF
  commit_and_push "A: initial"
  on_box 'git clone -q file:///srv/origin/app.git /srv/app && cd /srv/app && npm ci --silent && npm run build --silent && pm2 restart e2e-web'

  expect_deploy "dry run" 0 --dry-run
  echo "// B" >>server.js && commit_and_push "B: good"
  local B
  B=$(git rev-parse HEAD)
  expect_deploy "good deploy" 0
  expect_equal "good deploy: live commit" "$(live)" "$B"
  expect_equal "good deploy: app answers" "$(http_code http://127.0.0.1:4123/)" 200

  # An app without "migrations": "offline" gets the job this tool generated before offline migrations
  # existed, plus one branch that its jobs never take (OFFLINE_SCHEMA_DIR is only set for offline apps).
  local ours baseline added expected_branch
  ours=$(latest_job)
  mkdir -p "$WORK/baseline"
  git -C "$ROOT" archive "$BASELINE_COMMIT" | tar -x -C "$WORK/baseline"
  if "$WORK/baseline/bin/deploy" >"$WORK/last.log" 2>&1; then pass "baseline tool redeploys the same commit (exit 0)"; else
    fail "baseline tool redeploy"
    sed 's/^/      /' "$WORK/last.log"
  fi
  baseline=$(latest_job)
  expect_equal "online app: the job differs from the baseline's by insertions only" \
    "$(diff <(printf '%s\n' "$baseline") <(printf '%s\n' "$ours") | grep -c '^<' || true)" 0
  added=$(diff <(printf '%s\n' "$baseline") <(printf '%s\n' "$ours") | sed -n 's/^> //p' | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$' || true)
  expected_branch=$(printf '%s\n' "OFFLINE_SCHEMA_DIR=''" '  if [ -n "${OFFLINE_SCHEMA_DIR:-}" ]; then' '    offline_release "$prev"' '    return' '  fi')
  expect_equal "online app: the only added code is the always-empty OFFLINE_SCHEMA_DIR and the branch on it" "$added" "$expected_branch"
  expect_equal "online app: the job has none of the offline code" \
    "$(printf '%s\n' "$ours" | grep -c -e '^offline_preflight()' -e '^offline_entry()' | tr -d ' ')" 0
  # An OFFLINE_SCHEMA_DIR in the remote user's environment must not turn the offline path on for an app that did not opt in.
  E2E_DOCKER_ARGS='-e OFFLINE_SCHEMA_DIR=.' expect_deploy "online app with OFFLINE_SCHEMA_DIR exported on the host" 0
  expect_no_log "online app with OFFLINE_SCHEMA_DIR exported: no preflight ran" "preflight"

  touch fail-build && commit_and_push "C: build fails"
  expect_deploy "failed build rolls back" 20
  expect_equal "failed build: live commit is B again" "$(live)" "$B"
  expect_equal "failed build: app answers" "$(http_code http://127.0.0.1:4123/)" 200

  git rm -q fail-build && echo 500 >status.txt && commit_and_push "D: serves 500"
  expect_deploy "failed health check rolls back" 20
  expect_equal "failed health check: live commit is B again" "$(live)" "$B"
  expect_equal "failed health check: app answers" "$(http_code http://127.0.0.1:4123/)" 200

  echo 200 >status.txt && commit_and_push "E: fixed"
  docker exec -d -w /root "$CONTAINER" bash -c 'mkdir -p ~/.deploy/locks && flock ~/.deploy/locks/e2e-app.lock sleep 15'
  sleep 1
  expect_deploy "held lock refuses" 11
  expect_equal "held lock: live commit unchanged" "$(live)" "$B"
  sleep 15

  echo "// local" >>server.js && git commit -qam "local only"
  expect_deploy "unpushed main refuses" 1 --dry-run
  git reset -q --hard origin/main

  jq '.processes[0].port = "x" | .has_prisma = true' deploy.json >deploy.tmp && mv deploy.tmp deploy.json
  commit_and_push "F: invalid config"
  expect_deploy "invalid deploy.json refuses" 1 --dry-run

  # ----- static-site

  mkdir -p "$WORK/site" && cd "$WORK/site"
  git init -q -b main && git remote add origin box:/srv/origin/site.git
  cat >package.json <<'EOF'
{ "name": "e2e-site", "version": "1.0.0", "private": true, "scripts": { "build": "node build.js" } }
EOF
  npm install --package-lock-only --silent
  cat >build.js <<'EOF'
const fs = require("fs");
fs.mkdirSync("dist", { recursive: true });
fs.writeFileSync("dist/index.html", fs.readFileSync("content.txt", "utf8"));
EOF
  echo "site v1" >content.txt
  printf 'dist\nnode_modules\n' >.gitignore
  cat >deploy.json <<'EOF'
{
  "name": "e2e-site",
  "type": "static-site",
  "host": "box",
  "remote_path": "/srv/site",
  "health_url": "http://127.0.0.1:4124/",
  "audit_fail_on": "critical",
  "working_dir": ".",
  "build_cmd": "npm run build",
  "dist_dir": "dist"
}
EOF
  commit_and_push "S1"
  local S1
  S1=$(git rev-parse HEAD)
  site_commit() { on_box 'cat ~/.deploy/state/e2e-site.commit'; }
  site_body() { on_box 'cat /srv/site/index.html'; }

  expect_deploy "static site deploy" 0
  expect_equal "static site: files published" "$(site_body)" "site v1"
  expect_equal "static site: live commit recorded" "$(site_commit)" "$S1"

  echo "BROKEN v2" >content.txt && commit_and_push "S2: broken"
  expect_deploy "static site failed health check rolls back" 20
  expect_equal "static site rollback: previous files" "$(site_body)" "site v1"
  expect_equal "static site rollback: live commit" "$(site_commit)" "$S1"
}

# ------------------------------------------------------------- offline migrations

# The database role the offline app connects as: owns its database, no superuser, no CREATEDB.
readonly DB_PASSWORD='Zq7-p@ss/w:rd#9Xk'
readonly DB_PASSWORD_ENCODED='Zq7-p%40ss%2Fw%3Ard%239Xk'

install_postgres() {
  # Debian bookworm ships PostgreSQL 15; production runs 16 (from the PostgreSQL apt repository).
  on_box 'install -d /usr/share/postgresql-common/pgdg &&
    curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc &&
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" >/etc/apt/sources.list.d/pgdg.list &&
    apt-get update -qq >/dev/null && apt-get install -y -qq postgresql-16 >/dev/null 2>&1'
  on_box 'pg_ctlcluster 16 main start && for _ in $(seq 100); do pg_isready -q && exit 0; sleep 0.1; done; exit 1'
  on_box "su postgres -c 'psql -X -q -v ON_ERROR_STOP=1'" <<SQL
CREATE ROLE appuser LOGIN PASSWORD '$DB_PASSWORD';
CREATE DATABASE offdb OWNER appuser;
SQL
  # offsql: SQL on stdin or -c, as the app's role. offsnapshot: what the database looks like, for exact comparisons.
  on_box 'cat >/usr/local/bin/offsql && chmod +x /usr/local/bin/offsql' <<EOF
#!/usr/bin/env bash
export PGPASSWORD='$DB_PASSWORD'
exec psql -X -q -h 127.0.0.1 -U appuser -d offdb -A -t -v ON_ERROR_STOP=1 "\$@"
EOF
  on_box 'cat >/usr/local/bin/offsnapshot && chmod +x /usr/local/bin/offsnapshot' <<EOF
#!/usr/bin/env bash
export PGPASSWORD='$DB_PASSWORD' PGHOST=127.0.0.1 PGUSER=appuser PGDATABASE=offdb
echo "schema: \$(pg_dump --schema-only --restrict-key=snapshot | sha256sum)"
psql -X -q -A -t -c "select 'table ' || tablename || ' rows=' || (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I', tablename), false, true, '')))[1]::text || ' content=' || md5(query_to_xml(format('select * from %I order by 1', tablename), true, false, '')::text) from pg_tables where schemaname = 'public' order by tablename"
psql -X -q -A -t -c "select 'sequence ' || sequencename || ' ' || coalesce(last_value::text, 'unused') from pg_sequences where schemaname = 'public' order by sequencename"
psql -X -q -A -t -c "select 'owner ' || nspowner::regrole || ' ' || coalesce(nspacl::text, '') from pg_namespace where nspname = 'public'"
EOF
  # A sampler of the process list: every 50 ms, lines naming the password (raw or percent-encoded) go to /tmp/ps-hits.
  printf '%s\n%s\n' "$DB_PASSWORD" "$DB_PASSWORD_ENCODED" | on_box 'cat >/tmp/needles'
  on_box 'cat >/usr/local/bin/pssample && chmod +x /usr/local/bin/pssample' <<'EOF'
#!/usr/bin/env bash
: >/tmp/ps-hits
rm -f /tmp/ps-stop /tmp/ps-done
while [ ! -e /tmp/ps-stop ]; do
  ps -eo args= | grep -F -f /tmp/needles >>/tmp/ps-hits
  sleep 0.05
done
touch /tmp/ps-done
EOF
}

reset_pm2_calls() { on_box ': >/tmp/fake-pm2/calls.log'; }
pm2_call_count() { on_box "awk '\$2 == \"$1\"' /tmp/fake-pm2/calls.log | wc -l" | tr -d ' '; }
snapshot() { on_box offsnapshot; }
offsql() { on_box offsql; }
backup_dumps() { on_box 'ls ~/.deploy/backups/e2e-offline/ 2>/dev/null | grep -c "\.dump$" || true' | tr -d ' '; }

offline_scenarios() {
  install_postgres

  mkdir -p "$WORK/offapp" && cd "$WORK/offapp"
  git init -q -b main && git remote add origin box:/srv/origin/offapp.git
  cat >package.json <<'EOF'
{
  "name": "e2e-offapp",
  "version": "1.0.0",
  "private": true,
  "scripts": { "build": "node build.js" },
  "dependencies": { "pg": "8.13.1" },
  "devDependencies": { "prisma": "6.19.3" }
}
EOF
  npm install --package-lock-only --silent
  mkdir -p prisma/migrations/20260101000000_init
  # write_schema [datasource lines...]: the schema, with the datasource's url line unless others are given
  write_schema() {
    mkdir -p prisma
    {
      printf 'datasource db {\n  provider = "postgresql"\n'
      if [ $# -eq 0 ]; then printf '  url      = env("DATABASE_URL")\n'; else printf '  %s\n' "$@"; fi
      printf '}\n\nmodel Note {\n  id    Int     @id @default(autoincrement())\n  title String\n  body  String?\n}\n'
    } >prisma/schema.prisma
  }
  write_schema
  printf 'provider = "postgresql"\n' >prisma/migrations/migration_lock.toml
  cat >prisma/migrations/20260101000000_init/migration.sql <<'EOF'
CREATE TABLE "Note" ("id" SERIAL NOT NULL, "title" TEXT NOT NULL, "body" TEXT, CONSTRAINT "Note_pkey" PRIMARY KEY ("id"));
INSERT INTO "Note" ("title", "body") SELECT 'note ' || g, 'body ' || g FROM generate_series(1, 40) g;
EOF
  cat >build.js <<'EOF'
const fs = require("fs");
if (fs.existsSync("fail-build")) { console.error("build fails on purpose"); process.exit(1); }
fs.writeFileSync("built.txt", fs.readFileSync("status.txt", "utf8").trim());
EOF
  # Healthy (the HTTP status the build recorded) only when the database has the column this version needs.
  cat >server.js <<'EOF'
const http = require("http"), fs = require("fs"), os = require("os"), path = require("path");
const { Client } = require("pg");
process.loadEnvFile(".env");
const column = fs.readFileSync("column.txt", "utf8").trim();
const status = Number(fs.readFileSync("built.txt", "utf8"));
if (fs.existsSync("sabotage-backup")) { // test double: something damages the backups while this version starts
  const dir = path.join(os.homedir(), ".deploy/backups/e2e-offline");
  const good = path.join(os.homedir(), "good-dumps"); // the test keeps a good copy to hand back
  fs.mkdirSync(good, { recursive: true });
  for (const file of fs.readdirSync(dir)) {
    if (!file.endsWith(".dump")) continue;
    fs.copyFileSync(path.join(dir, file), path.join(good, file));
    fs.truncateSync(path.join(dir, file), 0);
  }
}
http.createServer(async (req, res) => {
  const client = new Client({ connectionString: process.env.DATABASE_URL });
  let code = 500;
  try {
    await client.connect();
    await client.query(`SELECT "${column}" FROM "Note" LIMIT 1`);
    code = status;
  } catch {
    // the database does not have what this version needs
  } finally {
    await client.end().catch(() => {});
  }
  res.writeHead(code);
  res.end();
}).listen(4125, "127.0.0.1");
EOF
  echo body >column.txt
  echo 200 >status.txt
  printf 'built.txt\nnode_modules\n.env\n' >.gitignore
  cat >deploy.json <<'EOF'
{
  "name": "e2e-offline",
  "type": "node-app",
  "host": "box",
  "remote_path": "/srv/offapp",
  "health_url": "http://127.0.0.1:4125/",
  "audit_fail_on": "critical",
  "processes": [
    { "pm2_name": "e2e-off", "port": 4125, "working_dir": ".", "build_cmd": "npm run build", "prisma_schema_dir": ".", "migrations": "offline" }
  ]
}
EOF
  commit_and_push "O1: initial"
  on_box 'git clone -q file:///srv/origin/offapp.git /srv/offapp'
  on_box 'cat >/srv/offapp/.env' <<EOF
DATABASE_URL="postgresql://appuser:$DB_PASSWORD_ENCODED@127.0.0.1:5432/offdb?schema=public&connection_limit=5"
EOF
  on_box 'cd /srv/offapp && cp .env /root/env.good && npm ci --silent --no-audit --no-fund && npx prisma migrate deploy >/dev/null && npm run build --silent && pm2 restart e2e-off'
  live_off() { on_box 'git -C /srv/offapp rev-parse HEAD'; }
  expect_equal "offline app: starts healthy on the initial schema" "$(http_code http://127.0.0.1:4125/)" 200

  # ----- the dry run
  local runs_before
  runs_before=$(on_box 'ls ~/.deploy/runs 2>/dev/null | wc -l' | tr -d ' ')
  reset_pm2_calls
  expect_deploy "offline dry run" 0 --dry-run
  cp "$WORK/last.log" "$WORK/plan.txt"
  DEPLOY_VIA=/bin/bash expect_deploy "offline dry run under /bin/bash ($(/bin/bash -c 'echo $BASH_VERSION'))" 0 --dry-run
  expect_equal "offline dry run: the same plan under /bin/bash" "$(cat "$WORK/last.log")" "$(cat "$WORK/plan.txt")"
  expect_log "offline dry run: prints the offline plan" "Migrations are OFFLINE"
  expect_log "offline dry run: names the pause" "pm2 stop every process; dump the database"
  expect_equal "offline dry run: starts no job" "$(on_box 'ls ~/.deploy/runs 2>/dev/null | wc -l' | tr -d ' ')" "$runs_before"
  expect_equal "offline dry run: pm2 untouched" "$(pm2_call_count restart)$(pm2_call_count stop)" "00"

  # ----- nothing pending: no stop, no dump
  echo "// O2: code only" >>server.js && commit_and_push "O2: code only"
  local O2
  O2=$(git rev-parse HEAD)
  reset_pm2_calls
  expect_deploy "offline, nothing pending" 0
  expect_log "nothing pending: said so" "no migration is pending"
  expect_equal "nothing pending: live commit" "$(live_off)" "$O2"
  expect_equal "nothing pending: never stopped" "$(pm2_call_count stop)" 0
  expect_equal "nothing pending: restarted once" "$(pm2_call_count restart)" 1
  expect_equal "nothing pending: no dump" "$(backup_dumps)" 0
  expect_equal "nothing pending: no trial dump left" "$(on_box 'ls ~/.deploy/backups/e2e-offline | wc -l' | tr -d ' ')" 0
  expect_equal "nothing pending: app answers" "$(http_code http://127.0.0.1:4125/)" 200

  # ----- pending migrations succeed
  mkdir prisma/migrations/20260102000000_add_tag
  cat >prisma/migrations/20260102000000_add_tag/migration.sql <<'EOF'
ALTER TABLE "Note" ADD COLUMN "tag" TEXT;
UPDATE "Note" SET "tag" = 'tag-' || "id";
EOF
  echo tag >column.txt
  commit_and_push "O3: add the tag column"
  local O3
  O3=$(git rev-parse HEAD)
  docker exec -d -w /root "$CONTAINER" pssample
  reset_pm2_calls
  DEPLOY_VIA=/bin/bash expect_deploy "offline, pending migrations succeed (run by /bin/bash $(/bin/bash -c 'echo $BASH_VERSION'))" 0
  expect_log "pending: preflight passed" "preflight passed"
  expect_log "pending: said it paused" "migrations are pending: pausing e2e-offline"
  expect_equal "pending: live commit" "$(live_off)" "$O3"
  expect_equal "pending: app answers" "$(http_code http://127.0.0.1:4125/)" 200
  expect_equal "pending: the new column holds data" "$(offsql <<<'select count(*) from "Note" where "tag" is not null')" 40
  expect_equal "pending: one dump" "$(backup_dumps)" 1
  expect_equal "pending: modes of backups/, its app directory and the dump (700 700 600)" \
    "$(on_box 'stat -c %a ~/.deploy/backups ~/.deploy/backups/e2e-offline ~/.deploy/backups/e2e-offline/*.dump' | paste -sd' ' -)" "700 700 600"
  expect_log "pending: the log names the dump and its size" "bytes); schema fingerprint"
  local stop_ts migration_times restart_ts
  stop_ts=$(on_box "awk '\$2 == \"stop\" { print \$1; exit }' /tmp/fake-pm2/calls.log")
  restart_ts=$(on_box "awk '\$2 == \"restart\" { t = \$1 } END { print t }' /tmp/fake-pm2/calls.log")
  migration_times=$(offsql <<<"select extract(epoch from started_at) || ' ' || extract(epoch from finished_at) from _prisma_migrations where migration_name = '20260102000000_add_tag'")
  expect_equal "pending: stopped before the migration ran and started after it finished" \
    "$(on_box "awk -v s=$stop_ts -v r=$restart_ts -v m='$migration_times' 'BEGIN { split(m, t, \" \"); print (s < t[1] && t[2] < r) ? \"yes\" : \"no\" }'")" yes
  expect_equal "pending: one stop, one start" "$(pm2_call_count stop)/$(pm2_call_count restart)" "1/1"
  expect_equal "pending: the app's environment holds no database credentials" \
    "$(on_box 'tr "\0" "\n" </proc/$(cat /tmp/fake-pm2/e2e-off.pid)/environ | grep -c -E "^(PG|DATABASE_URL)" || true' | tr -d ' ')" 0

  # ----- the second of two pending migrations fails
  mkdir prisma/migrations/20260103000000_extra prisma/migrations/20260104000000_bad
  cat >prisma/migrations/20260103000000_extra/migration.sql <<'EOF'
CREATE TYPE "Kind" AS ENUM ('a', 'b');
CREATE TABLE "Extra" ("id" SERIAL NOT NULL, "kind" "Kind" NOT NULL DEFAULT 'a', CONSTRAINT "Extra_pkey" PRIMARY KEY ("id"));
INSERT INTO "Extra" ("kind") VALUES ('a'), ('b');
INSERT INTO "Note" ("title", "body") VALUES ('made by the failed release', 'x'), ('and another', 'y');
ALTER TABLE "Note" ADD COLUMN "extra" INTEGER;
UPDATE "Note" SET "extra" = 0;
EOF
  cat >prisma/migrations/20260104000000_bad/migration.sql <<'EOF'
ALTER TABLE "Note" ADD COLUMN "doomed" TEXT;
SELECT * FROM a_table_that_does_not_exist;
EOF
  commit_and_push "O4: two migrations, the second fails"
  local before sequence_before
  before=$(snapshot)
  sequence_before=$(offsql <<<"select last_value from pg_sequences where sequencename = 'Note_id_seq'")
  reset_pm2_calls
  expect_deploy "offline, second migration fails: restored, rolled back" 20
  expect_log "second migration fails: the restore ran" "RESTORED: the database is back to what it was"
  expect_log "second migration fails: the restore was verified" "verified: the schema fingerprint, the row counts of every table and every sequence position"
  expect_equal "second migration fails: database identical (schema, every table's contents, _prisma_migrations)" "$(snapshot)" "$before"
  expect_equal "second migration fails: the Note sequence is back where it was ($sequence_before)" \
    "$(offsql <<<"select last_value from pg_sequences where sequencename = 'Note_id_seq'")" "$sequence_before"
  expect_equal "second migration fails: no row of the failed release" "$(offsql <<<'select count(*) from "Note"')" 40
  expect_equal "second migration fails: no table of the failed release" "$(offsql <<<"select count(*) from pg_tables where tablename = 'Extra'")" 0
  expect_equal "second migration fails: no type of the failed release" "$(offsql <<<"select count(*) from pg_type where typname = 'Kind'")" 0
  expect_equal "second migration fails: live commit is O3 again" "$(live_off)" "$O3"
  expect_equal "second migration fails: previous code healthy" "$(http_code http://127.0.0.1:4125/)" 200
  expect_equal "second migration fails: the dump is kept" "$(backup_dumps)" 2

  # ----- migrations succeed, drop a column that holds data, the new version fails its health check
  git rm -rq prisma/migrations/20260103000000_extra prisma/migrations/20260104000000_bad
  mkdir prisma/migrations/20260105000000_drop_tag
  cat >prisma/migrations/20260105000000_drop_tag/migration.sql <<'EOF'
ALTER TABLE "Note" DROP COLUMN "tag";
ALTER TABLE "Note" ADD COLUMN "slug" TEXT;
EOF
  echo slug >column.txt
  echo 500 >status.txt
  commit_and_push "O5: drops a column, serves 500"
  before=$(snapshot)
  expect_deploy "offline, migrated but unhealthy: restored, rolled back" 20
  expect_equal "unhealthy: the dropped column and its data are back" "$(offsql <<<'select count(*) from "Note" where "tag" is not null')" 40
  expect_equal "unhealthy: the new column is gone" "$(offsql <<<"select count(*) from information_schema.columns where table_name = 'Note' and column_name = 'slug'")" 0
  expect_equal "unhealthy: database identical" "$(snapshot)" "$before"
  expect_equal "unhealthy: live commit is O3 again" "$(live_off)" "$O3"
  expect_equal "unhealthy: previous code healthy" "$(http_code http://127.0.0.1:4125/)" 200

  # Control: the sampler does see a password on a command line. (Prisma's own schema-engine child is
  # known to put the URL on its command line during its connection check, in every release mode,
  # online or offline; that is prisma's, so it is left out of the assertion below.)
  on_box "psql 'postgresql://appuser:$DB_PASSWORD_ENCODED@127.0.0.1:5432/offdb' -X -q -c 'select pg_sleep(0.5)'"
  on_box 'touch /tmp/ps-stop; for _ in $(seq 100); do [ -e /tmp/ps-done ] && exit 0; sleep 0.1; done; exit 1'
  expect_equal "the sampler sees a password on a command line (control)" "$(on_box 'grep -q pg_sleep /tmp/ps-hits && echo yes || echo no')" yes
  expect_equal "the password was on no command line of ours during three pauses (prisma's schema-engine aside)" \
    "$(on_box 'grep -v -e schema-engine -e pg_sleep /tmp/ps-hits | wc -c' | tr -d ' ')" 0
  expect_equal "the password is in no run log or job script" "$(on_box 'grep -rlF -f /tmp/needles ~/.deploy/runs | wc -l' | tr -d ' ')" 0
  expect_equal "the password is in no output of the deploy command" "$(grep -cF -f <(printf '%s\n%s\n' "$DB_PASSWORD" "$DB_PASSWORD_ENCODED") "$WORK/all.log" || true)" 0
  expect_equal "no credentials file is left in a run directory" "$(on_box 'ls ~/.deploy/runs/*/database-url.fields 2>/dev/null | wc -l' | tr -d ' ')" 0

  # ----- the build fails: never stopped, database untouched
  git rm -rq prisma/migrations/20260105000000_drop_tag
  mkdir prisma/migrations/20260106000000_unused
  echo 'CREATE TABLE "Unused" ("id" INTEGER NOT NULL);' >prisma/migrations/20260106000000_unused/migration.sql
  echo tag >column.txt
  echo 200 >status.txt
  touch fail-build
  commit_and_push "O6: build fails, a migration is pending"
  before=$(snapshot)
  reset_pm2_calls
  expect_deploy "offline, build fails: rolled back" 20
  expect_equal "build fails: the app was never stopped" "$(pm2_call_count stop)" 0
  expect_equal "build fails: database untouched" "$(snapshot)" "$before"
  expect_equal "build fails: live commit is O3 again" "$(live_off)" "$O3"
  expect_equal "build fails: previous code healthy" "$(http_code http://127.0.0.1:4125/)" 200

  # ----- preflight refusals: exit 10, nothing changed
  git rm -q fail-build
  git rm -rq prisma/migrations/20260106000000_unused
  echo "// O7: a clean commit to refuse" >>server.js
  commit_and_push "O7: refusals"
  before=$(snapshot)
  refusal() { # <description> <text the log must contain>
    reset_pm2_calls
    expect_deploy "preflight refuses: $1" 10
    expect_log "preflight refuses: $1: says why" "$2"
    expect_equal "preflight refuses: $1: nothing stopped or restarted" "$(pm2_call_count stop)$(pm2_call_count restart)" "00"
    expect_equal "preflight refuses: $1: live commit unchanged" "$(live_off)" "$O3"
  }
  untouched() { expect_equal "preflight refuses: $1: database untouched" "$(snapshot)" "$before"; }
  on_box "su postgres -c 'psql -X -q -d offdb -c \"CREATE SCHEMA extra\"'"
  refusal "an extra schema" "schemas besides public (extra)"
  on_box "su postgres -c 'psql -X -q -d offdb -c \"DROP SCHEMA extra\"'"
  untouched "an extra schema"

  on_box 'mv /usr/bin/pg_dump /usr/bin/pg_dump.off'
  refusal "pg_dump missing" "pg_dump is not installed"
  on_box 'mv /usr/bin/pg_dump.off /usr/bin/pg_dump'
  untouched "pg_dump missing"

  on_box "su postgres -c 'psql -X -q -d offdb -c \"CREATE TABLE foreign_owned (i int); GRANT ALL ON foreign_owned TO appuser\"'"
  refusal "an object another role owns" "owned by another role than appuser: relation foreign_owned"
  on_box "su postgres -c 'psql -X -q -d offdb -c \"DROP TABLE foreign_owned\"'"
  untouched "an object another role owns"

  offsql <<<"insert into _prisma_migrations (id, checksum, migration_name, started_at, applied_steps_count) values ('failed-one', 'x', '20260199000000_failed', now(), 0)"
  refusal "a failed migration is already recorded" "1 failed migration(s) are recorded"
  offsql <<<"delete from _prisma_migrations where id = 'failed-one'"
  untouched "a failed migration is already recorded"

  on_box 'sed -i "s/connection_limit=5/connection_limit=5\&sslcert=x/" /srv/offapp/.env'
  refusal "a DATABASE_URL parameter the tools cannot honour" 'has the parameter "sslcert"'
  on_box 'cp /root/env.good /srv/offapp/.env'

  on_box 'sed -i "s/?schema=public/?schema=other/" /srv/offapp/.env'
  refusal "a schema other than public in DATABASE_URL" "only the public schema is supported"
  on_box 'cp /root/env.good /srv/offapp/.env'
  untouched "a bad DATABASE_URL"

  on_box "su postgres -c 'psql -X -q -c \"GRANT CONNECT ON DATABASE postgres TO appuser\"'"
  refusal "a privilege on a shared object" "was granted privileges on 1 database(s)"
  on_box "su postgres -c 'psql -X -q -c \"REVOKE CONNECT ON DATABASE postgres FROM appuser\"'"
  untouched "a privilege on a shared object"

  offsql <<<"select lo_create(424242)" >/dev/null
  refusal "a large object" "1 large object(s)"
  offsql <<<"select lo_unlink(424242)" >/dev/null
  untouched "a large object"

  # ----- the schema Prisma will load must be the one the backup is built from (checked on the new commit)
  write_schema 'url       = env("DATABASE_URL")' 'directUrl = env("DIRECT_URL")'
  commit_and_push "O7a: directUrl"
  refusal "a directUrl in the Prisma schema" "has a directUrl"
  git revert --no-edit HEAD >/dev/null && git push -q origin main
  write_schema 'url      = env("OTHER_URL")'
  commit_and_push "O7b: another variable"
  refusal "a datasource url from another variable" 'is not env("DATABASE_URL")'
  git revert --no-edit HEAD >/dev/null && git push -q origin main
  echo "export default {}" >prisma.config.ts
  commit_and_push "O7c: prisma.config"
  refusal "a prisma.config file" "a prisma.config file exists"
  git revert --no-edit HEAD >/dev/null && git push -q origin main
  untouched "a Prisma schema that differs"

  # ----- retention: the newest five dumps are kept
  mkdir prisma/migrations/20260107000000_audit
  echo 'CREATE TABLE "Audit" ("id" SERIAL NOT NULL, "note" TEXT, CONSTRAINT "Audit_pkey" PRIMARY KEY ("id"));' >prisma/migrations/20260107000000_audit/migration.sql
  commit_and_push "O8: a harmless migration"
  local O8 n
  O8=$(git rev-parse HEAD)
  for n in 1 2 3 4 5 6 7; do
    # names that sort AFTER this run's id, modification times long before it: only the time may decide
    on_box "install -m 600 /dev/null ~/.deploy/backups/e2e-offline/9999010100000${n}Z-fake-$n.dump && touch -d 2020-01-0$n ~/.deploy/backups/e2e-offline/9999010100000${n}Z-fake-$n.dump"
  done
  expect_equal "retention: ten dumps before the run (three real, seven made up)" "$(backup_dumps)" 10
  expect_deploy "offline, a harmless migration" 0
  expect_equal "retention: the newest five are kept" "$(backup_dumps)" 5
  expect_equal "retention: the dump with the oldest time is gone" "$(on_box 'ls ~/.deploy/backups/e2e-offline | grep -c 99990101000001Z || true' | tr -d ' ')" 0
  expect_equal "retention: the newest-by-time of the made-up dumps stays" "$(on_box 'ls ~/.deploy/backups/e2e-offline | grep -c 99990101000007Z || true' | tr -d ' ')" 1
  expect_equal "retention: this run's dump stays although its name sorts before the made-up ones" \
    "$(on_box 'ls ~/.deploy/backups/e2e-offline/"$(basename "$(ls -d ~/.deploy/runs/*/ | tail -n 1)")".dump | wc -l' | tr -d ' ')" 1

  # ----- the restore fails: exit 30, nothing started, one command to finish
  mkdir prisma/migrations/20260108000000_more
  echo 'ALTER TABLE "Audit" ADD COLUMN "extra" TEXT;' >prisma/migrations/20260108000000_more/migration.sql
  echo 500 >status.txt
  touch sabotage-backup
  commit_and_push "O9: serves 500 and damages the backup"
  local O9 run_id dump_name after_failure rc
  O9=$(git rev-parse HEAD)
  before=$(snapshot)
  expect_deploy "offline, restore fails" 30
  expect_log "restore fails: says so" "RESTORE FAILED"
  expect_log "restore fails: pg_restore's own failure is named" "pg_restore could not read the dump"
  expect_log "restore fails: names the dump" "/root/.deploy/backups/e2e-offline/"
  expect_log "restore fails: reports the process state as pm2 sees it" "e2e-off: stopped"
  expect_log "restore fails: prints the one recovery command" "job.sh --recover"
  expect_equal "restore fails: the process stays stopped" "$(on_box 'pm2 jlist' | grep -c '"status":"stopped"')" 1
  expect_equal "restore fails: nothing answers on the port" "$(http_code http://127.0.0.1:4125/)" 000
  expect_equal "restore fails: the aborted restore left the data in place (one transaction rolled back)" "$(offsql <<<'select count(*) from "Note"')" 40
  expect_equal "restore fails: history says restore-failed" "$(on_box 'tail -n 1 ~/.deploy/history.tsv | cut -f4')" restore-failed
  expect_equal "restore fails: the code was not rolled back" "$(live_off)" "$O9"

  run_id=$(on_box 'basename "$(ls -d ~/.deploy/runs/*/ | tail -n 1)"')
  dump_name="$run_id.dump"
  after_failure=$(snapshot)
  recover() { rc=0; on_box "bash ~/.deploy/runs/$run_id/job.sh --recover" >"$WORK/last.log" 2>&1 || rc=$?; }
  recover
  expect_equal "recover with the dump still damaged: exit 30 again" "$rc" 30
  expect_equal "recover with the dump still damaged: database unchanged" "$(snapshot)" "$after_failure"
  expect_equal "recover with the dump still damaged: still stopped, code untouched" \
    "$(on_box 'pm2 jlist' | grep -c '"status":"stopped"')/$(live_off)" "1/$O9"
  on_box "install -m 600 ~/good-dumps/$dump_name ~/.deploy/backups/e2e-offline/$dump_name"
  recover
  expect_equal "recover with the good dump back: exit 20" "$rc" 20
  expect_log "recover: the restore was verified" "verified: the schema fingerprint, the row counts of every table and every sequence position"
  expect_equal "recover: database exact (as before the failed release)" "$(snapshot)" "$before"
  expect_equal "recover: previous code is live" "$(live_off)" "$O8"
  expect_equal "recover: previous code healthy" "$(http_code http://127.0.0.1:4125/)" 200
  expect_equal "recover: exit code recorded beside the run" "$(on_box "cat ~/.deploy/runs/$run_id/recover-exit-code")" 20
  expect_equal "recover: the recovery state holds no password" "$(on_box 'grep -rlF -f /tmp/needles ~/.deploy/runs | wc -l' | tr -d ' ')" 0

  # ----- configuration
  cd "$WORK/offapp"
  jq 'del(.processes[0].prisma_schema_dir)' deploy.json >deploy.tmp && mv deploy.tmp deploy.json
  commit_and_push "O10: offline without prisma_schema_dir"
  expect_deploy "migrations offline without prisma_schema_dir refuses" 1 --dry-run
  expect_log "...and says why" 'needs prisma_schema_dir'
  jq '.processes[0].prisma_schema_dir = "." | .processes[0].migrations = "sideways"' deploy.json >deploy.tmp && mv deploy.tmp deploy.json
  commit_and_push "O11: migrations sideways"
  expect_deploy "migrations with another value refuses" 1 --dry-run
}

case $SCENARIOS in
  all | legacy) legacy_scenarios ;;
esac
case $SCENARIOS in
  all | offline) offline_scenarios ;;
esac

printf '\n'
if [ "$FAILURES" -eq 0 ]; then echo "e2e: all passed"; else echo "e2e: $FAILURES failure(s)"; exit 1; fi
