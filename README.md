# deploy-workflows

`deploy`: ship an app's `origin/main` to the `sontiac` VPS from your Mac.

Since Nov 9, 2026 apps no longer deploy through GitHub Actions. Pushing does
not deploy anything. Run `deploy` from the app's repository instead.

## Install (once per Mac)

```bash
gh repo clone sontiac/deploy-workflows ~/Code/deploy-workflows
ln -s ~/Code/deploy-workflows/bin/deploy ~/.local/bin/deploy   # ~/.local/bin must be on PATH
```

Needs `git`, `jq`, `npm`, `ssh` (with a working `ssh sontiac`) and, for
static sites, `rsync`. Install `gitleaks` (`brew install gitleaks`) to get the
secret scan; without it `deploy` says the scan was skipped.

## Use

```bash
cd ~/Code/<app>
deploy --dry-run   # the plan: what ships, what is live now, every step. Changes nothing.
deploy             # do it
```

`deploy` always ships the current `origin/main`, never your working tree or
branch. It refuses when local `main` has commits that are not pushed.

What happens:

1. **On the Mac:** `git fetch`, read `deploy.json` from the commit being
   deployed, print the plan, then run `npm audit --omit=dev` (blocking at
   `audit_fail_on`) and `gitleaks` over a clean export of that commit.
2. **On the VPS**, as a job detached from your terminal, holding the lock
   `~/.deploy/locks/<name>.lock` so two deploys of one app can never overlap:
   - **node-app:** check production is still on the commit the plan saw,
     `git fetch` + `reset --hard` to the commit, then per process `npm ci`,
     `prisma migrate deploy` (if configured) and the build; `pm2 restart
     --update-env` every process, `pm2 save`. With `"migrations": "offline"`
     the order is different, see [Offline migrations](#offline-migrations).
   - **static-site:** the site is built on the Mac from the clean export and
     uploaded first; the job keeps a copy of the live files and publishes the
     new ones with `rsync --delete`.
3. **Health check:** `health_url` must answer 2xx/3xx (node-app: and every
   process must be `online` in pm2 and accepting connections on its port).
   6 tries, 5 seconds apart.
4. **Rollback** on any failure after production was touched: node-app resets
   to the previous commit, reinstalls, rebuilds and restarts (migrations are
   not reverted, unless the app uses offline migrations, which restore a
   database backup first); static-site restores the previous files.

Ctrl-C, a sleeping laptop or a dropped connection only detaches your
terminal; the job finishes on the VPS. Each run keeps its job script, log and
exit code in `~/.deploy/runs/<run-id>/` on the VPS (kept 30 days), and
`~/.deploy/history.tsv` lists every run and its outcome.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | deployed and healthy |
| 1 | refused on the Mac (unpushed commits, bad config, failed security check, failed static build); nothing changed |
| 10 | refused on the VPS (production moved since the plan, fetch failed, ...); nothing changed |
| 11 | another deploy of this app is running; nothing changed |
| 20 | the deploy failed and was rolled back; production is healthy on the previous version (offline migrations: the database was restored too) |
| 30 | the deploy failed **and** the rollback failed; production may be down. With offline migrations also: the database restore failed and nothing was started on purpose (see "When the restore fails") |
| 40 | lost the connection (or Ctrl-C); the deploy keeps running on the VPS |
| 99 | the remote job ended unexpectedly; read its log |

## `deploy.json`

One file at the repository root, committed like code. `deploy` reads it from
the commit it deploys. Every key shown is required unless marked optional;
unknown keys are rejected.

### node-app (Next.js, NestJS, any process pm2 runs from a git checkout)

```json
{
  "name": "mythology",
  "type": "node-app",
  "host": "sontiac",
  "remote_path": "/home/kenneth/apps/mythology",
  "health_url": "https://mythology.sontiac.com/",
  "audit_fail_on": "critical",
  "processes": [
    {
      "pm2_name": "mythology-frontend",
      "port": 3100,
      "working_dir": ".",
      "build_cmd": "npm run build",
      "prisma_schema_dir": "."
    },
    {
      "pm2_name": "mythology-backend",
      "port": 4100,
      "working_dir": "backend",
      "build_cmd": "npm run build"
    }
  ]
}
```

| Key | Meaning |
|---|---|
| `name` | Identifies the app for the lock, run ids and history. Lowercase, digits, dashes. |
| `host` | The ssh host (an alias from `~/.ssh/config`). |
| `remote_path` | The app's git checkout on the host. |
| `health_url` | Public URL that must answer 2xx/3xx after the restart. |
| `audit_fail_on` | `never`, `low`, `moderate`, `high` or `critical`: the `npm audit` level that blocks a deploy. |
| `processes[].pm2_name` | The pm2 process to restart. |
| `processes[].port` | The port it listens on; checked during the health check. |
| `processes[].working_dir` | Where its `package.json` is, relative to the repo root. |
| `processes[].build_cmd` | Shell command run there after `npm ci`. |
| `processes[].prisma_schema_dir` | Optional. Where to run `npx prisma migrate deploy`; leave it out when there is no prisma. |
| `processes[].migrations` | Optional, `"online"` (default) or `"offline"`. `"offline"` needs `prisma_schema_dir` and releases with a short pause and a database backup; see [Offline migrations](#offline-migrations). Without the key an app deploys exactly as before. |

### static-site (Vite or other pre-built files served by Caddy `file_server`)

```json
{
  "name": "genesis",
  "type": "static-site",
  "host": "sontiac",
  "remote_path": "/home/kenneth/apps/genesis/dist",
  "health_url": "https://genesis.sontiac.com/",
  "audit_fail_on": "critical",
  "working_dir": ".",
  "build_cmd": "npm run build",
  "dist_dir": "dist"
}
```

`remote_path` is the directory Caddy serves; `dist_dir` is the build output
relative to `working_dir`. The live commit is recorded on the VPS in
`~/.deploy/state/<name>.commit`.

## Offline migrations

By default migrations run while the old version keeps serving (`online`). That
only works while the old code survives the new schema. When a release drops a
column, replaces an enum, or has a migration that assumes nothing is writing,
set `"migrations": "offline"` on the app's processes. The release then builds
first and pauses the app only for the migrations, with a database backup to go
back to:

```json
{ "pm2_name": "mindstory", "port": 3400, "working_dir": ".", "build_cmd": "npm run build",
  "prisma_schema_dir": ".", "migrations": "offline" }
```

One offline process makes the whole app offline: all its processes stop and
start together, as they already restart together. Every process that has a
`prisma_schema_dir` must then be offline and they must name the same one (one
database). `deploy --dry-run` prints the order below and, as always, changes
nothing.

### The order

1. **Preflight**, before anything changes (the Prisma schema is read from the new commit). Any failure is a refusal (exit 10,
   "Production was not changed") and the log says which check failed:
   - `pg_dump`, `pg_restore`, `psql` and `node` are installed;
   - `DATABASE_URL` can be read from `.env` in `prisma_schema_dir` and the
     database answers; `pg_dump` is not older than the server;
   - the only schema is `public`, no extension is installed (besides
     `plpgsql`), there are no large objects;
   - the connecting role owns the database and every object in `public` (the
     restore recreates them without a superuser);
   - no failed migration is recorded in `_prisma_migrations` (Prisma would
     refuse to migrate; fix it with `prisma migrate resolve` first);
   - the Prisma schema's datasource is `env("DATABASE_URL")` with no `directUrl`;
   - `~/.deploy/backups/<name>/` has at least three times the database size
     free, and a trial dump is written, listed with `pg_restore -l`, and deleted.
2. Reset to the new commit, `npm ci` and build every process **without
   migrating**. The old version keeps serving. A failure here rolls the code
   back as today; the database was never touched and the app was never stopped.
3. `npx prisma migrate status` in `prisma_schema_dir`. Exit 0 means up to date:
   `pm2 restart` and the health check as today, no pause, no dump. Any other
   exit means pending (Prisma exits 1 for pending, for a recorded failed
   migration and for an unreachable database alike; the preflight already
   excluded the last two).
4. **The pause.** `pm2 stop` every process; take a schema fingerprint (a hash
   of `pg_dump --schema-only`, with its GRANT and REVOKE lines sorted, since the order of an
   object's privilege entries is not part of the schema and a restore can change it), the row count of every table and the position of
   every sequence; dump the
   database (`pg_dump -Fc`) to `~/.deploy/backups/<name>/<run id>.dump`; `prisma
   migrate deploy`; `pm2 restart` every process (which starts a stopped
   one); health check. The log prints the dump's path and size. The newest five
   dumps by the host's file modification time are kept, never removing the current one.
5. **Any failure once the dump exists:** stop the processes, restore the dump
   in **one transaction** (`DROP OWNED BY CURRENT_USER`, which removes
   everything the failed release created, then the dump replayed; `COMMIT` is
   only sent when `pg_restore` read the whole dump, so an unreadable dump
   changes nothing), check that the schema fingerprint, every table's row
   count and every sequence position equal the recorded ones, then the usual code rollback (reset, `npm
   ci`, build, restart, health check). Exit 20 when it all works.

### When the restore fails (exit 30)

Nothing is started: the old code must not run on a database in an unknown
state. The log says what pm2 reports for each process at that moment, prints the
backup's path, and prints the one command that finishes the job:

```bash
ssh <host> 'bash ~/.deploy/runs/<run id>/job.sh --recover'
```

`--recover` takes the app's lock and runs the same sequence as a failure in the
pause, from the state saved when the dump was taken (dump path, previous
commit, schema fingerprint, row counts and sequence positions; no password):
stop the processes, restore the dump in one transaction, verify it, reset to
the previous commit, `npm ci`, build, restart, health check. Same exit codes
(20 when it works, 30 when it does not). A failed restore changes nothing (the
transaction rolls back), so run it again after fixing what failed. Only an
unfinished release can be recovered. A recovery opened by an older version of this tool
(schema fingerprint taken without sorting the privilege lines) is finished with that version:
the fingerprint recorded then is compared by this version's method, and a database with
several roles holding privileges would not match. Each app has one open recovery
(`~/.deploy/state/<name>.recovery`, the run id): it opens when a run takes its
dump, and closes only when that run ends healthy on the new version, when a
restore ends healthy on the previous one (automatic or by `--recover`), or when
you delete the file by hand after settling the database yourself. While one is
open the preflight of every later release refuses (exit 10, nothing changed)
and names the run, its recover command and the file to delete. If deleting the
file fails after a healthy release, the log warns loudly: delete it by hand and
do not run `--recover`. `--recover` refuses
(exit 10, nothing changed) unless it names that run, unless the saved state,
the dump and `pg_restore -l` are fine and `.env` still names the database that
was backed up, and if production has moved to another commit since the failed run. `history.tsv`
records the failed run as `restore-failed`; the recovery's exit code lands in
`~/.deploy/runs/<run id>/recover-exit-code`.

### Limits

- PostgreSQL through Prisma, one database, one schema (`public`), no
  extensions, no large objects. Each is refused in the preflight, not
  half-supported. Static sites have no offline mode.
- The Prisma schema of the commit being deployed (found where Prisma looks:
  `prisma/schema.prisma`, `schema.prisma`, `prisma/schema/`, or the path in
  `package.json`'s `prisma.schema`; exactly one) must declare one datasource
  with `url = env("DATABASE_URL")` and no `directUrl`, and there must be no
  `prisma.config` or `.config/prisma` file. `migrate status` and `migrate
  deploy` are given that same file with `--schema`. Why: Prisma migrates through `directUrl` when there is
  one, and through whatever variable `url` names. The backup is built from
  `DATABASE_URL`, so any other setup could back up one database and migrate
  another. The preflight refuses it.
- The datasource must use `env("DATABASE_URL")`, with `DATABASE_URL` written
  out in `.env` in `prisma_schema_dir`: no `$` (variable expansion), no
  `schema` other than `public`. Besides `schema` and Prisma's own parameters
  (`connection_limit`, `pool_timeout`, `connect_timeout`, `socket_timeout`,
  `pgbouncer`, `statement_cache_size`, `max_connection_lifetime`,
  `max_idle_connection_lifetime`) only `sslmode` is accepted. The job passes
  Prisma exactly the URL the backup uses, so both always target one database.
- The password reaches `pg_dump`, `pg_restore` and `psql` through their
  environment only, never an argument or the log. Prisma itself passes the
  database URL to its engine on a command line (every deploy, online ones too;
  seen with Prisma 6.19), so other users of the host can see it in `ps` while
  Prisma runs. That is Prisma's behaviour; this tool cannot change it.
- The new version takes traffic as soon as it starts. If it then fails its
  health check, anything users wrote in those seconds is lost when the
  backup is restored.
- If the host reboots during the pause, pm2 may start the new code against a
  database in any state. Stop it (`pm2 stop`) and run the recover command.
- There is no maintenance page: while the app is stopped, requests fail. The
  pause lasts the dump, the migrations and the start (seconds for a small
  database; the dump of a large one takes longer).
- A release that changes the owner, privileges or comment of schema `public`
  itself is not undone by the restore; the verification notices and the run
  ends in exit 30.
- The app is stopped from the dump until the new version starts, so it writes
  nothing before then. From the start on, the new version takes traffic, and
  anything it or anything else (a script, an admin tool) writes until a failed
  release is restored is lost by the restore.
- The role the app connects as must not hold grants on other databases or
  tablespaces: `DROP OWNED` would revoke them and no dump of this database can
  put them back. The preflight refuses.
- `pm2 restart` of a stopped process starts it (checked against pm2 7), so the
  start after the pause is the same call as the normal restart.

## Layout

- `bin/deploy`: the command (bash, also runs on macOS's bash 3.2).
- `lib/validate-config.jq`: the `deploy.json` checks.
- `lib/remote/`: the job that runs on the VPS; `common.sh` plus one file per type. `node-app-offline.sh` is appended after `node-app.sh` only for apps with an offline process.
- `test/e2e.sh`: end-to-end test against a Docker container standing in for the VPS (good deploy, failed build, failed health check, lock, refusals, static site, and the offline-migrations scenarios against a real PostgreSQL 16 and Prisma). Run it after changing the tool; it never touches the real VPS. The header of the file says what it does and does not cover.

The reusable GitHub Actions workflows this repository used to hold
(`node-app.yml`, `static-site.yml`) were removed on Nov 9, 2026; they are in
the git history.
