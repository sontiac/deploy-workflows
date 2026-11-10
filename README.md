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
     --update-env` every process, `pm2 save`.
   - **static-site:** the site is built on the Mac from the clean export and
     uploaded first; the job keeps a copy of the live files and publishes the
     new ones with `rsync --delete`.
3. **Health check:** `health_url` must answer 2xx/3xx (node-app: and every
   process must be `online` in pm2 and accepting connections on its port).
   6 tries, 5 seconds apart.
4. **Rollback** on any failure after production was touched: node-app resets
   to the previous commit, reinstalls, rebuilds and restarts (migrations are
   not reverted); static-site restores the previous files.

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
| 20 | the deploy failed and was rolled back; production is healthy on the previous version |
| 30 | the deploy failed **and** the rollback failed; production may be down |
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

## Layout

- `bin/deploy`: the command (bash, also runs on macOS's bash 3.2).
- `lib/validate-config.jq`: the `deploy.json` checks.
- `lib/remote/`: the job that runs on the VPS; `common.sh` plus one file per type.

The reusable GitHub Actions workflows this repository used to hold
(`node-app.yml`, `static-site.yml`) were removed on Nov 9, 2026; they are in
the git history.
