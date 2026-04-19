#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
CONFIG_FILE="$SCRIPT_DIR/backup-config.env"
SCOPE="${1:-}"

if [ -z "$SCOPE" ]; then
  echo "Usage: $0 daily|weekly|monthly"
  exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Missing backup-config.env. Copy backup-config.env.example and fill it in first."
  exit 1
fi

# shellcheck disable=SC1090
. "$CONFIG_FILE"

if [ -z "${APP_URL:-}" ] || [ -z "${BACKUP_API_TOKEN:-}" ]; then
  echo "APP_URL and BACKUP_API_TOKEN must be set in backup-config.env"
  exit 1
fi

TMP_JSON=$(mktemp)
TMP_ERR=$(mktemp)
cleanup() {
  rm -f "$TMP_JSON" "$TMP_ERR"
}
trap cleanup EXIT

HTTP_CODE=$(curl -sS -o "$TMP_JSON" -w "%{http_code}" \
  -X POST \
  -H "Content-Type: application/json" \
  -H "X-Backup-Token: $BACKUP_API_TOKEN" \
  --data "{\"scope\":\"$SCOPE\"}" \
  "$APP_URL/api/admin/backup-export" 2>"$TMP_ERR" || true)

if [ "$HTTP_CODE" != "200" ]; then
  echo "Backup request failed with HTTP $HTTP_CODE"
  cat "$TMP_ERR"
  cat "$TMP_JSON"
  exit 1
fi

FILENAME=$(ruby -rjson -e 'payload = JSON.parse(File.read(ARGV[0])); print payload.fetch("filename")' "$TMP_JSON")
CSV_CONTENT=$(ruby -rjson -e 'payload = JSON.parse(File.read(ARGV[0])); print payload.fetch("csv")' "$TMP_JSON")

STAMP=$(date +"%Y-%m-%d_%H-%M-%S")

write_backup() {
  target_root="$1"
  [ -n "$target_root" ] || return 0
  expanded_root=$(eval "printf '%s' \"$target_root\"")
  target_dir="$expanded_root/$SCOPE"
  mkdir -p "$target_dir"
  target_file="$target_dir/${STAMP}_$FILENAME"
  printf '%s' "$CSV_CONTENT" > "$target_file"
  echo "Saved backup: $target_file"
}

write_backup "${LOCAL_BACKUP_DIR:-}"
write_backup "${ONEDRIVE_BACKUP_DIR:-}"
write_backup "${NETWORK_BACKUP_DIR:-}"
