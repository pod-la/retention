# Retention Script

This script helps keep a directory from growing indefinitely by automatically removing older files and organizing the remaining ones into time-based buckets.

## What it does

`retention.sh` scans a target directory and keeps a rolling set of recent files while deleting or archiving older ones according to day/week/month retention rules.

By default, it keeps:
- the newest files for the last 7 days
- the newest file per ISO week for the last 4 weeks
- the newest file per month for the last 12 months

The script supports two modes:

1. Standard archive mode (default)
   - Moves loose files from the base directory into `daily/`
   - Keeps only the newest file for each day in `daily/`
   - Promotes older daily files into `weekly/`
   - Keeps only the newest file for each week in `weekly/`
   - Promotes older weekly files into `monthly/`
   - Keeps only the newest file for each month in `monthly/`
   - Deletes older monthly files beyond the configured month cutoff

2. Keep-in-place mode (`-k`)
   - Does not create the `daily/`, `weekly/`, or `monthly/` folders
   - Deletes files older than the overall monthly cutoff immediately
   - Keeps only the newest file per day/week/month within the configured time windows in the base directory itself

## Usage

```bash
./retention.sh [-d DAYS] [-w WEEKS] [-m MONTHS] [-k] BASE_DIR
```

### Options

- `-d DAYS`: keep the newest daily files for this many days (default: `7`)
- `-w WEEKS`: keep the newest weekly files for this many weeks (default: `4`)
- `-m MONTHS`: keep the newest monthly files for this many months (default: `12`)
- `-k`: keep files in `BASE_DIR` instead of moving them into `daily/`, `weekly/`, and `monthly/`
- `-h`: show usage help

## Example

```bash
./retention.sh -d 14 -w 8 -m 24 /var/backups
```

This keeps the most recent files for the last 14 days, the newest per week for the last 8 weeks, and the newest per month for the last 24 months in `/var/backups` using the standard archive layout.

## Notes

- The script preserves original modification times when moving files across directories.
- It keeps only one file per time bucket (day, week, or month) in the archive layers.
- It prints a summary at the end showing how many files were kept and how many were deleted.

This is useful for cleanup jobs where you want to retain recent backups or logs without filling disk space with very old files.
