# forge-backup

Auto-discovery backup of WordPress and Joomla sites on Laravel Forge servers to DigitalOcean Spaces. Databases are not touched (Forge backs those up). Media folders are synced incrementally and full site archives are streamed straight to Spaces with no local disk usage.

## What it does

Two modes:

* `uploads`: incremental sync of media folders only. WordPress `wp-content/uploads`, Joomla `images`, `media`, `attachments`. Uses `rclone copy`.
* `full`: a dated `.tar.gz` of the whole site, streamed directly to Spaces (`tar | rclone rcat`). Caches, `node_modules`, `.git`, and logs are excluded.

It scans every home under `/home`, finds each WordPress and Joomla install (nested installs included), and backs each one up under a per server namespace in the bucket.

## Requirements

* A Laravel Forge server (Ubuntu, bash 5+).
* A DigitalOcean Spaces bucket plus access key, secret key, and endpoint.
* `rclone` (the installer offers to install it if missing).

## Install

Run on each server. Pick a unique `SERVER_NAME` per server (server-1, server-2, ...).

```bash
curl -fsSL https://raw.githubusercontent.com/<owner>/forge-backup/main/install.sh | sudo bash
```

The installer checks dependencies, prompts for the server name, bucket, and Spaces credentials, writes the rclone config and the forge-backup config, installs the command to `/usr/local/bin/forge-backup`, and schedules cron. It finishes with a dry run so you can confirm discovery and connectivity.

Re-running the installer is safe. It updates the config and cron in place without duplicating anything.

## Manual usage

```bash
forge-backup uploads            # incremental media sync
forge-backup full               # dated full archives
forge-backup uploads --dry-run  # show what would happen, transfer nothing
```

## Configuration

Config lives at `/etc/forge-backup/config` (mode `0600`). It is sourced as bash. See `config.example` for the full template.

| Key | Meaning |
| --- | --- |
| `REMOTE` | rclone remote name (matches `rclone.conf`). |
| `BUCKET` | Spaces bucket name. |
| `SERVER_NAME` | Unique per server. Namespaces objects in the bucket. |
| `SITES_ROOT` | Root scanned for sites. Default `/home`. |
| `LOG` | Log file path. |
| `WP_UPLOADS` | WordPress media dir, relative to a site root. |
| `JOOMLA_DIRS` | Joomla media dirs, relative to a site root. |

## Cron schedule

The installer writes `/etc/cron.d/forge-backup`:

* `uploads` daily at 02:30.
* `full` weekly on Sunday at 03:30.

Edit that file to change timing.

## Retention (DigitalOcean Spaces lifecycle)

The script never deletes old archives. Set retention with a Spaces lifecycle rule so storage does not grow forever.

1. Open the DigitalOcean control panel, go to your Space, then Settings.
2. Add a lifecycle rule scoped to the prefix `full-archives/`.
3. Set it to expire objects after N days (for example 30).

The `uploads-mirror/` prefix is a live mirror of current media, so leave it without an expiry rule.

## Restore

Full archive:

```bash
rclone copy spaces:<bucket>/full-archives/<server>/<owner>/<site>/<date>.tar.gz .
tar xzf <date>.tar.gz -C /path/to/restore
```

Media only:

```bash
rclone copy spaces:<bucket>/uploads-mirror/<server>/<owner>/<site>/ /path/to/site/wp-content/uploads/
```

## Bucket layout

```
<bucket>/
  uploads-mirror/<server>/<owner>/<site>/<label>/   # live media mirror
  full-archives/<server>/<owner>/<site>/<date>.tar.gz
```

## Troubleshooting

* Log file: `/home/forge/forge-backup.log`.
* Dry run to debug discovery and connectivity: `forge-backup uploads --dry-run`.
* "config not found": the installer did not complete, or `/etc/forge-backup/config` is missing.
* rclone auth errors: check the endpoint and credentials in `~/.config/rclone/rclone.conf`.
