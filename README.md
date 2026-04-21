# deploy-workflows

Reusable GitHub Actions workflows for sontiac projects. Each workflow runs:
1. **Security scan** — `npm audit` (block on high/critical) + `gitleaks` (block on committed secrets). Blocks deploy if anything fails.
2. **Deploy** — SSH to VPS, pull commit, `npm ci`, `prisma migrate deploy` (optional), build, `pm2 restart --update-env`.
3. **Health check** — curl the production URL; on failure, auto-rollback to previous commit.

## Workflows

### `node-app.yml` — Next.js / NestJS / any long-running Node process under pm2

```yaml
name: Deploy
on:
  push:
    branches: [main]
jobs:
  call:
    uses: sontiac/deploy-workflows/.github/workflows/node-app.yml@main
    with:
      app_name: mindstory
      app_port: 3400
      health_url: https://mindstory.ai/
      remote_path: /home/kenneth/apps/mindstory
      has_prisma: true
      prisma_schema_dir: .
    secrets:
      DEPLOY_SSH_KEY: ${{ secrets.DEPLOY_SSH_KEY }}
```

### `static-site.yml` — Vite / pre-rendered sites served by Caddy `file_server`

```yaml
name: Deploy
on:
  push:
    branches: [main]
jobs:
  call:
    uses: sontiac/deploy-workflows/.github/workflows/static-site.yml@main
    with:
      app_name: genesis
      health_url: https://genesis.sontiac.com/
      dist_dir: dist
      remote_path: /home/kenneth/apps/genesis/dist
    secrets:
      DEPLOY_SSH_KEY: ${{ secrets.DEPLOY_SSH_KEY }}
```

## Per-repo setup

1. Copy the relevant snippet above into `.github/workflows/deploy.yml` of your project.
2. In your repo's Settings → Secrets and variables → Actions, add `DEPLOY_SSH_KEY` (the private key matching the deploy public key on the VPS).
3. Push to `main`. CI takes over.

## Emergency overrides

To ship without the security gate (use sparingly):

```yaml
with:
  skip_security: true
```
