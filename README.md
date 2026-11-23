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
| 30 | the deploy failed **and** the rollback failed; production may be down. With offline migrations also: the database restore failed and the app was left stopped on purpose |
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

1. **Preflight**, before anything changes. Any failure is a refusal (exit 10,
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
   of `pg_dump --schema-only`) and the row count of every table; dump the
   database (`pg_dump -Fc`) to `~/.deploy/backups/<name>/<run id>.dump`; `prisma
   migrate deploy`; `pm2 restart` every process (which starts a stopped
   one); health check. The newest five dumps are kept; the log prints the dump's
   path and size.
5. **Any failure once the dump exists:** stop the processes, restore the dump
   in **one transaction** (`DROP OWNED BY CURRENT_USER`, which removes
   everything the failed release created, then the dump replayed; `COMMIT` is
   only sent when `pg_restore` read the whole dump, so an unreadable dump
   changes nothing), check that the schema fingerprint and every table's row
   count equal the recorded ones, then the usual code rollback (reset, `npm
   ci`, build, restart, health check). Exit 20 when it all works.

### When the restore fails (exit 30)

The app is **left stopped** on purpose: the old code must not run on a
database in an unknown state. The log prints the dump's path and the commands
to finish by hand. They are:

```bash
export PGHOST=<host> PGPORT=<port> PGUSER=<user> PGDATABASE=<database>
read -rs -p 'database password: ' PGPASSWORD; export PGPASSWORD   # DATABASE_URL's, in .env
{ echo "BEGIN; SET LOCAL lock_timeout = '60s'; DROP OWNED BY CURRENT_USER;"
  pg_restore -f - ~/.deploy/backups/<name>/<run id>.dump && echo 'COMMIT;'
} | psql -X -q -o /dev/null -v ON_ERROR_STOP=1 -f -
git -C <remote_path> reset --hard <previous commit>
# per process: npm ci, its build command, pm2 restart <name> --update-env; then pm2 save
```

A failed restore changes nothing (the transaction rolls back), so it can be
retried. `history.tsv` records the run as `restore-failed`.

### Limits

- PostgreSQL through Prisma, one database, one schema (`public`), no
  extensions, no large objects. Each is refused in the preflight, not
  half-supported. Static sites have no offline mode.
- The datasource must use `env("DATABASE_URL")`, with `DATABASE_URL` written
  out in `.env` in `prisma_schema_dir`: no `$` (variable expansion), no
  `schema` other than `public`. Besides `schema` and Prisma's own parameters
  (`connection_limit`, `pool_timeout`, `connect_timeout`, `socket_timeout`,
  `pgbouncer`, `statement_cache_size`, `max_connection_lifetime`,
  `max_idle_connection_lifetime`) only `sslmode` is accepted. The job passes
  Prisma exactly the URL the backup uses, so both always target one database.
- The password reaches `pg_dump`, `pg_restore` and `psql` through their
  environment only, never an argument or the log. Prisma's own CLI starts its
  schema engine with the URL on the command line during its connection check
  (Prisma 6.19, online migrations too), so other users of the host can see it
  in `ps` for that moment. That is Prisma's behaviour; this tool cannot change it.
- There is no maintenance page: while the app is stopped, requests fail. The
  pause lasts the dump, the migrations and the start (seconds for a small
  database; the dump of a large one takes longer).
- A release that changes the owner, privileges or comment of schema `public`
  itself is not undone by the restore; the verification notices and the run
  ends in exit 30.
- Rows written between the dump and a failed release are not possible (the app is
  stopped), but anything that writes to the database from elsewhere in that window is lost
  by the restore.
- The pm2 processes are stopped and started with `pm2 stop` and `pm2 restart`;
  `pm2 save` runs after the start, not after the stop.

## Layout

- `bin/deploy`: the command (bash, also runs on macOS's bash 3.2).
- `lib/validate-config.jq`: the `deploy.json` checks.
- `lib/remote/`: the job that runs on the VPS; `common.sh` plus one file per type. `node-app-offline.sh` is appended after `node-app.sh` only for apps with an offline process.
- `test/e2e.sh`: end-to-end test against a Docker container standing in for the VPS (good deploy, failed build, failed health check, lock, refusals, static site, and the offline-migrations scenarios against a real PostgreSQL 16 and Prisma). Run it after changing the tool; it never touches the real VPS. The header of the file says what it does and does not cover.

The reusable GitHub Actions workflows this repository used to hold
(`node-app.yml`, `static-site.yml`) were removed on Nov 9, 2026; they are in
the git history.
