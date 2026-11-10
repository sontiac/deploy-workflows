#!/usr/bin/env bash
# End-to-end test of bin/deploy against a Docker container standing in for
# the VPS. Nothing touches the real VPS.
#
# A fake `ssh` on PATH routes every ssh call (the deploy's own and git's)
# into the container; pm2 is a stub that runs `node server.js`; git, npm,
# flock, setsid, GNU tail and rsync are real.
#
# Covers: a good deploy, a failed build and a failed health check (both
# rolled back), a held lock, unpushed commits, an invalid deploy.json, and a
# static site's deploy and rollback. Needs docker and network access (image
# pull, npm audit). Run: test/e2e.sh

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DEPLOY="$ROOT/bin/deploy"
CONTAINER="deploy-e2e-$$"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/deploy-e2e.XXXXXX")
FAILURES=0

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
  "$DEPLOY" "$@" >"$WORK/last.log" 2>&1 || rc=$?
  if [ "$rc" -eq "$expected" ]; then pass "$description (exit $rc)"; else
    fail "$description: expected exit $expected, got $rc"
    sed 's/^/      /' "$WORK/last.log"
  fi
}

expect_equal() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$3', got '$2'"; fi
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
exec docker exec -i -w /root $CONTAINER bash -c "\$*"
EOF
chmod +x "$WORK/bin/ssh"
export PATH="$WORK/bin:$PATH"

docker run -d --name "$CONTAINER" node:22-bookworm sleep infinity >/dev/null
on_box 'apt-get update -qq >/dev/null && apt-get install -y -qq rsync >/dev/null'
on_box 'cat >/usr/local/bin/pm2 && chmod +x /usr/local/bin/pm2' <<'EOF'
#!/usr/bin/env bash
# Test double for pm2: one `node server.js` per name, started from the current directory.
state=/tmp/fake-pm2
mkdir -p "$state"
case $1 in
  restart)
    if [ -f "$state/$2.pid" ]; then kill "$(cat "$state/$2.pid")" 2>/dev/null; sleep 0.5; fi
    setsid nohup node server.js >"$state/$2.log" 2>&1 </dev/null &
    echo $! >"$state/$2.pid" ;;
  save) ;;
  jlist)
    printf '['; sep=''
    for f in "$state"/*.pid; do
      [ -e "$f" ] || continue
      if kill -0 "$(cat "$f")" 2>/dev/null; then s=online; else s=stopped; fi
      printf '%s{"name":"%s","pm2_env":{"status":"%s"}}' "$sep" "$(basename "$f" .pid)" "$s"; sep=,
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
  git init -q --bare /srv/origin/app.git && git init -q --bare /srv/origin/site.git &&
  mkdir -p /srv/site && echo "site v0" >/srv/site/index.html &&
  (setsid nohup node /srv/static-server.js >/dev/null 2>&1 </dev/null &)'

# ------------------------------------------------------------- node-app

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
live() { on_box 'git -C /srv/app rev-parse HEAD'; }
http_code() { on_box "curl -s -o /dev/null -w '%{http_code}' $1"; }

expect_deploy "dry run" 0 --dry-run
echo "// B" >>server.js && commit_and_push "B: good"
B=$(git rev-parse HEAD)
expect_deploy "good deploy" 0
expect_equal "good deploy: live commit" "$(live)" "$B"
expect_equal "good deploy: app answers" "$(http_code http://127.0.0.1:4123/)" 200

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

# ------------------------------------------------------------- static-site

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

# -------------------------------------------------------------

printf '\n'
if [ "$FAILURES" -eq 0 ]; then echo "e2e: all passed"; else echo "e2e: $FAILURES failure(s)"; exit 1; fi
