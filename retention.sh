#!/usr/bin/env bash
set -euo pipefail

# retention.sh [-d DAYS] [-w WEEKS] [-m MONTHS] [-k] BASE_DIR
# Defaults: DAYS=7, WEEKS=4, MONTHS=12
# -k : keep files in BASE_DIR (do not move into daily/weekly/monthly subdirs)

DAYS=7
WEEKS=4
MONTHS=12
KEEP_IN_PLACE=0

usage() {
    echo "Usage: $0 [-d DAYS] [-w WEEKS] [-m MONTHS] [-k] BASE_DIR"
    echo "  -d DAYS   : keep newest daily files for this many days (default: $DAYS)"
    echo "  -w WEEKS  : keep newest weekly files for this many weeks (default: $WEEKS)"
    echo "  -m MONTHS : keep newest monthly files for this many months (default: $MONTHS)"
    echo "  -k        : keep files in BASE_DIR (do not move into daily/weekly/monthly subdirs)"
    exit 1
}

while getopts ":d:w:m:hk" opt; do
    case $opt in
        d) DAYS="$OPTARG" ;;
        w) WEEKS="$OPTARG" ;;
        m) MONTHS="$OPTARG" ;;
        h) usage ;;
        k) KEEP_IN_PLACE=1 ;;
        *) usage ;;
    esac
done
shift $((OPTIND-1))

if [ $# -ne 1 ]; then
    usage
fi

BASE_DIR="$1"
if [ ! -d "$BASE_DIR" ]; then
    echo "Base directory does not exist: $BASE_DIR" >&2
    exit 2
fi

DAILY_DIR="$BASE_DIR/daily"
WEEKLY_DIR="$BASE_DIR/weekly"
MONTHLY_DIR="$BASE_DIR/monthly"
if [ "$KEEP_IN_PLACE" -eq 0 ]; then
    mkdir -p "$DAILY_DIR" "$WEEKLY_DIR" "$MONTHLY_DIR"
fi

# --- Globals --------------------------------------------------------------
deleted_count=0

# --- Helpers --------------------------------------------------------------

# preserve mtime when moving (works across filesystems)
safe_move() {
    local src="$1" dst_dir="$2"
    cp -p -- "$src" "$dst_dir/" && rm -f -- "$src"
}

# return epoch of file
file_epoch() {
    stat -c %Y -- "$1"
}

# increment global deleted counter
increment_deleted() {
    deleted_count=$((deleted_count + 1))
}

# Keep only the newest file per tag in dir.
# Args: dir, strftime-format (e.g. "%Y-%m-%d" or "%G%V" or "%Y%m")
keep_only_newest() {
    local dir="$1" fmt="$2"
    declare -A seen=()
    # iterate newest-first; entries are "<epoch> <path>\0"
    while IFS= read -r -d '' entry; do
        epoch=${entry%% *}
        file=${entry#* }
        tag=$(date -d "@$epoch" +"$fmt")
        if [ -z "${seen[$tag]:-}" ]; then
            seen[$tag]="$file"
        else
            rm -f -- "$file" && increment_deleted
        fi
    done < <(find "$dir" -maxdepth 1 -type f -printf '%T@ %p\0' | sort -z -nr)
}

# Keep only newest per tag from a pre-sorted (newest-first) null-separated stream of "epoch path\0"
# Args: strftime-format
keep_only_newest_stream() {
    local fmt="$1"
    declare -A seen=()
    while IFS= read -r -d '' entry; do
        epoch=${entry%% *}
        file=${entry#* }
        tag=$(date -d "@$epoch" +"$fmt")
        if [ -z "${seen[$tag]:-}" ]; then
            seen[$tag]="$file"
        else
            rm -f -- "$file" && increment_deleted
        fi
    done
}

# Move files older than cutoff (seconds since epoch) from src_dir to dst_dir
move_older_than_epoch() {
    local src="$1" dst="$2" cutoff="$3"
    while IFS= read -r -d '' f; do
        epoch=$(file_epoch "$f")
        if (( epoch < cutoff )); then
            safe_move "$f" "$dst"
        fi
    done < <(find "$src" -maxdepth 1 -type f -print0)
}

# Delete files older than cutoff (seconds since epoch) in dir
delete_older_than_epoch() {
    local dir="$1" cutoff="$2"
    while IFS= read -r -d '' f; do
        epoch=$(file_epoch "$f")
        if (( epoch < cutoff )); then
            rm -f -- "$f" && increment_deleted
        fi
    done < <(find "$dir" -maxdepth 1 -type f -print0)
}

# Count files (non-recursive) in a directory
count_files() {
    local dir="$1" c=0
    while IFS= read -r -d '' f; do
        c=$((c+1))
    done < <(find "$dir" -maxdepth 1 -type f -print0)
    echo "$c"
}

# Convenience epoch calculators
epoch_days_ago() { date -d "$1 days ago" +%s; }
epoch_weeks_ago(){ date -d "$1 weeks ago" +%s; }
epoch_months_ago(){ date -d "$1 months ago" +%s; }

# --- Helpers for keep-in-place consolidation -------------------------------

# Stream files in BASE_DIR whose epoch is >= min_epoch and (< max_epoch if max_epoch > 0)
# Output: "<epoch> <path>\0" sorted newest-first to stdout
# Args: min_epoch max_epoch
stream_files_in_range() {
    local min_epoch="$1" max_epoch="$2"
    # build stream
    find "$BASE_DIR" -maxdepth 1 -type f -print0 \
    | while IFS= read -r -d '' f; do
        epoch=$(file_epoch "$f")
        if (( epoch >= min_epoch )) && { [ "$max_epoch" -eq 0 ] || (( epoch < max_epoch )); }; then
            printf '%s %s\0' "$epoch" "$f"
        fi
    done | sort -z -nr
}

# Process a time-range in BASE_DIR: keep only newest per tag (strftime fmt)
# Args: min_epoch max_epoch fmt
process_time_range() {
    local min_epoch="$1" max_epoch="$2" fmt="$3"
    stream_files_in_range "$min_epoch" "$max_epoch" | keep_only_newest_stream "$fmt"
}

# --- Retention lifecycle --------------------------------------------------

# Compute cutoffs up-front (seconds since epoch)
cutoff_daily=$(epoch_days_ago "$DAYS")
cutoff_weekly=$(epoch_weeks_ago "$WEEKS")
cutoff_monthly=$(epoch_months_ago "$MONTHS")

if [ "$KEEP_IN_PLACE" -eq 0 ]; then
    # Original behavior ---------------------------------------------------

    # 1) Move any loose files from BASE_DIR (excluding retention subdirs) into daily
    while IFS= read -r -d '' f; do
        # skip if inside retention dirs
        case "$f" in
            "$DAILY_DIR"/*|"$WEEKLY_DIR"/*|"$MONTHLY_DIR"/*) continue ;;
        esac
        safe_move "$f" "$DAILY_DIR"
    done < <(find "$BASE_DIR" -maxdepth 1 -type f -print0)

    # 2) Keep only newest file per day in daily
    keep_only_newest "$DAILY_DIR" "%Y-%m-%d"

    # 3) Promote daily files older than DAYS to weekly
    move_older_than_epoch "$DAILY_DIR" "$WEEKLY_DIR" "$cutoff_daily"

    # 4) In weekly: keep only newest file per ISO-week (year+week)
    keep_only_newest "$WEEKLY_DIR" "%G%V"

    # 5) Promote weekly files older than WEEKS to monthly
    move_older_than_epoch "$WEEKLY_DIR" "$MONTHLY_DIR" "$cutoff_weekly"

    # 6) In monthly: keep only newest file per month
    keep_only_newest "$MONTHLY_DIR" "%Y%m"

    # 7) Delete monthly files older than MONTHS
    delete_older_than_epoch "$MONTHLY_DIR" "$cutoff_monthly"

    # Optional: cleanup any daily/weekly files older than overall monthly cutoff
    delete_older_than_epoch "$DAILY_DIR" "$cutoff_monthly"
    delete_older_than_epoch "$WEEKLY_DIR" "$cutoff_monthly"

else
    # Keep-in-place behavior (consolidated helpers) -------------------------

    # 1) Delete files older than overall monthly cutoff immediately
    delete_older_than_epoch "$BASE_DIR" "$cutoff_monthly"

    # 2) For files in the last DAYS -> keep only newest per day
    process_time_range "$cutoff_daily" 0 "%Y-%m-%d"

    # 3) For files older than DAYS but within WEEKS -> keep only newest per ISO-week
    process_time_range "$cutoff_weekly" "$cutoff_daily" "%G%V"

    # 4) For files older than WEEKS but within MONTHS -> keep only newest per month
    process_time_range "$cutoff_monthly" "$cutoff_weekly" "%Y%m"
fi

# --- Summary --------------------------------------------------------------
if [ "$KEEP_IN_PLACE" -eq 0 ]; then
    daily_count=$(count_files "$DAILY_DIR")
    weekly_count=$(count_files "$WEEKLY_DIR")
    monthly_count=$(count_files "$MONTHLY_DIR")
else
    daily_count=$(count_files "$BASE_DIR")
    weekly_count=0
    monthly_count=0
fi
total_kept=$((daily_count + weekly_count + monthly_count))

echo "Retention completed."
echo "  Kept:  daily=$daily_count  weekly=$weekly_count  monthly=$monthly_count  total=$total_kept"
echo "  Deleted files: $deleted_count"