#!/usr/bin/env bash
#
# backup.sh — snapshot both OctoPrint data directories.
#
# OctoPrint has its own backup feature (Settings > Backup), which is the thing
# to use for restoring a single instance. This script is the blunt, host-side
# complement: one tarball of both instances' config, plugins and logs, suitable
# for a cron job or copying off the Pi.
#
# Timelapse videos are excluded by default — they are large and are not needed
# to restore a working setup. Pass --include-uploads to keep them.
#
# Usage:
#   ./scripts/backup.sh                     # backups/octoprint-<timestamp>.tar.gz
#   ./scripts/backup.sh --include-uploads   # include uploads/ (large)
#   ./scripts/backup.sh --dest /mnt/storage/backups
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${REPO_DIR}/backups"
INCLUDE_UPLOADS=0

while [ $# -gt 0 ]; do
    case "$1" in
        --include-uploads) INCLUDE_UPLOADS=1; shift ;;
        --dest) DEST="${2:?--dest needs a path}"; shift 2 ;;
        -h|--help) sed -n '2,15p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${DEST%/}"
ARCHIVE="${OUT_DIR}/octoprint-${STAMP}.tar.gz"

if [ ! -d "${REPO_DIR}/data" ]; then
    echo "error: ${REPO_DIR}/data does not exist — have the containers run yet?" >&2
    exit 1
fi

missing=0
for instance in cr6se e3pro; do
    [ -d "${REPO_DIR}/data/${instance}" ] || {
        echo "warning: data/${instance} is missing, skipping" >&2
        missing=1
    }
done
[ "$missing" -eq 1 ] && [ ! -d "${REPO_DIR}/data/cr6se" ] && [ ! -d "${REPO_DIR}/data/e3pro" ] && {
    echo "error: no OctoPrint data directories found at all" >&2
    exit 1
}

mkdir -p "${OUT_DIR}"
cd "${REPO_DIR}"

# Build the file list rather than archiving data/ wholesale, so uploads can be
# skipped and so a missing instance does not fail the whole backup.
files=()
for instance in cr6se e3pro; do
    [ -d "data/${instance}" ] || continue
    # Either way the directory is archived wholesale; uploads are skipped by
    # tar's --exclude below rather than by enumerating files here.
    files+=("data/${instance}")
done

exclude=()
[ "$INCLUDE_UPLOADS" -eq 0 ] && exclude=(--exclude='data/*/uploads')

echo "Creating ${ARCHIVE}"
# "${exclude[@]+...}" keeps this working when the array is empty under `set -u`
# (bash < 4.4, e.g. stock macOS bash) — plain "${exclude[@]}" would abort there.
tar -czf "${ARCHIVE}" ${exclude[@]+"${exclude[@]}"} "${files[@]}"
echo "Done: $(du -h "${ARCHIVE}" | cut -f1)"

# Keep the 10 most recent archives so this is cron-safe without growing forever.
ls -1t "${OUT_DIR}"/octoprint-*.tar.gz 2>/dev/null | tail -n +11 | while read -r old; do
    echo "Pruning old backup: $(basename "$old")"
    rm -f "$old"
done

echo "Current backups in ${OUT_DIR}:"
ls -1t "${OUT_DIR}"/octoprint-*.tar.gz 2>/dev/null | head -10 | while read -r f; do
    echo "  $(basename "$f")  $(du -h "$f" | cut -f1)"
done
