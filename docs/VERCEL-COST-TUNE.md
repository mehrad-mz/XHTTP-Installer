# Vercel cost tuning (server script)

Use **`scripts/tune-vercel-cost.sh`** on the VPS after a successful XHTTP install. It applies strict (low-cost) relay limits on Vercel and redeploys production.

**Safe for 3x-ui:** the script only talks to Vercel (env vars + `deploy/vercel` deploy). It does **not** change Xray, `x-ui`, or `/usr/local/etc/xray/config.json`.

## Quick start

```bash
cd /root/XHTTP-Installer   # or your clone path
sudo bash scripts/tune-vercel-cost.sh --save-secrets
```

First run prompts for:

- Vercel API token ([account tokens](https://vercel.com/account/tokens))
- Project name (same as install, e.g. `relay-xxxxx`)

With `--save-secrets`, credentials are stored in `/etc/xhttp-installer/vercel.api` (mode `600`).

Install CLI shortcut:

```bash
sudo bash scripts/tune-vercel-cost.sh --install-bin
sudo xhttp-vercel-tune --save-secrets
```

## Profiles

| Profile | MAX_DOWN_BPS | MAX_INFLIGHT | maxDuration | Use case |
|---------|--------------|--------------|-------------|----------|
| `strict` (default) | 512 KB/s shared | 12 | 25s | Maximum savings |
| `budget` | 1 MB/s shared | 32 | 30s | ~10 users, moderate savings |
| `balanced` | 1.5 MB/s shared | 48 | 45s | Slightly faster, higher cost |

```bash
sudo xhttp-vercel-tune --profile budget
sudo xhttp-vercel-tune --profile balanced
```

## Options

| Flag | Meaning |
|------|---------|
| `--dry-run` | Print plan only; no Vercel changes |
| `--no-deploy` | Set env vars only; skip `vercel deploy` |
| `--no-duration-tune` | Do not edit `maxDuration` in repo files |
| `--skip-probe` | Skip HTTPS check to `VERCEL_HOST` |
| `--save-secrets` | Write `/etc/xhttp-installer/vercel.api` |

## Logs

Every run writes a full log:

```text
/var/log/xhttp-installer/vercel-tune-YYYYMMDD-HHMMSS.log
```

The same output is printed to the terminal (`tee`).

## What the script sets (Production env)

- `MAX_INFLIGHT`, `MAX_UP_BPS`, `MAX_DOWN_BPS`
- `UPSTREAM_TIMEOUT_MS`
- `SUCCESS_LOG_SAMPLE_RATE`, `SUCCESS_LOG_MIN_DURATION_MS`, `ERROR_LOG_MIN_INTERVAL_MS`

It does **not** change `TARGET_DOMAIN`, `RELAY_PATH`, `PUBLIC_RELAY_PATH`, or padding keys.

## Credentials file

`/etc/xhttp-installer/vercel.api`:

```bash
VERCEL_TOKEN=your_token_here
VERCEL_PROJECT=your-project-name
VERCEL_SCOPE=optional-team-slug
```

```bash
chmod 600 /etc/xhttp-installer/vercel.api
```

## Verify

1. Log file shows `verified value: MAX_DOWN_BPS=...` (or `vercel env ls` lists names).
2. Vercel dashboard → empty value field is normal (values are hidden).
3. Test VPN after deploy.
4. Usage → **Fluid Provisioned Memory** over 24–48 hours.

## 3x-ui note

After the script, check port 443 is owned by **one** service only:

```bash
ss -tlnp | grep ':443 '
systemctl is-active xray x-ui
```

If both fight for 443, fix in the panel — unrelated to this script.

## Rollback

- Vercel dashboard: raise `MAX_*` or remove overrides, redeploy.
- Or: `sudo xhttp-vercel-tune --profile budget` or `--profile balanced`
