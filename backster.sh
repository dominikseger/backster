#!/bin/bash
set -e

# Set up logging
LOG_DIR="/var/log/db_backups"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/backup_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "====== Database Backup Started at $(date) ======"

# Use dedicated temp directory with proper permissions
TEMP_DIR="/tmp/backups"
mkdir -p "$TEMP_DIR"
chmod 700 "$TEMP_DIR"
cd "$TEMP_DIR"

# Record start time
start_time=$(date +%s)

# Create lockfile to prevent concurrent backups
LOCK_FILE="/tmp/db_backup_${DB_NAME}.lock"

if [ -e "$LOCK_FILE" ]; then
  # Check if process is still running
  PID=$(cat "$LOCK_FILE")
  if ps -p $PID >/dev/null 2>&1; then
    echo "Error: Another backup process (PID: $PID) is already running"
    exit 1
  else
    echo "Warning: Found stale lock file. Previous backup may have failed."
    rm -f "$LOCK_FILE"
  fi
fi

# Create lock file
echo $$ >"$LOCK_FILE"

# Cleanup function for lock file and temp files
cleanup() {
  local exit_code=$?
  rm -f "$LOCK_FILE"

  if [ -f "$FILENAME" ]; then rm -f "$FILENAME"; fi
  if [ -f "$COMPRESSED_FILENAME" ]; then rm -f "$COMPRESSED_FILENAME"; fi
  if [ -f "${COMPRESSED_FILENAME}.age" ]; then rm -f "${COMPRESSED_FILENAME}.age"; fi
  if [ -f "${FILENAME}.age" ]; then rm -f "${FILENAME}.age"; fi
  if [ -f "$TEMP_DIR/.s3cfg" ]; then rm -f "$TEMP_DIR/.s3cfg"; fi

  echo "====== Database Backup Finished at $(date) ======"
  exit $exit_code
}
trap cleanup EXIT

# Default parameters for mysqldump (non-locking priority)
DEFAULT_MYSQLDUMP_PARAMS="--single-transaction --quick --no-tablespaces --skip-lock-tables --skip-add-locks"
# Generate timestamp for filename
TIMESTAMP=$(date +%Y%m%d%H%M%S)
FILENAME="${FILENAME_PREFIX:-backup}_${DB_NAME}_${TIMESTAMP}.sql"
COMPRESSED_FILENAME="${FILENAME}.gz"
ENCRYPTED_FILENAME="${FILENAME}.age"
FINAL_FILENAME="${FILENAME}"

# Validate required environment variables
if [ -z "$DB_NAME" ] || [ -z "$DB_HOST" ] || [ -z "$DB_USERNAME" ] || [ -z "$DB_PASSWORD" ]; then
  echo "Error: Required database environment variables not set"
  exit 1
fi
if [ -z "$S3_HOST" ] || [ -z "$S3_ACCESS_KEY" ] || [ -z "$S3_SECRET_KEY" ] || [ -z "$S3_BUCKET" ]; then
  echo "Error: Required S3 environment variables not set"
  exit 1
fi

# Slack notification configuration
SLACK_ENABLED="${SLACK_ENABLED:-false}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
SLACK_CHANNEL="${SLACK_CHANNEL:-#server-alerts}"
SLACK_USERNAME="${SLACK_USERNAME:-Backup Bot}"
SLACK_NOTIFY_ON_SUCCESS="${SLACK_NOTIFY_ON_SUCCESS:-false}"

# Validate Slack configuration if enabled
if [ "$SLACK_ENABLED" = "true" ] && [ -z "$SLACK_WEBHOOK_URL" ]; then
  echo "Error: SLACK_WEBHOOK_URL must be provided when SLACK_ENABLED is true"
  exit 1
fi

# Function to send Slack notifications
send_slack_notification() {
  if [ "$SLACK_ENABLED" != "true" ] || [ -z "$SLACK_WEBHOOK_URL" ]; then
    return 0
  fi

  local status="$1"
  local message="$2"
  local color="$3"
  local host=$(hostname)

  # Create the JSON payload
  local payload=$(
    cat <<EOF
{
  "channel": "${SLACK_CHANNEL}",
  "username": "${SLACK_USERNAME}",
  "icon_emoji": ":floppy_disk:",
  "attachments": [
    {
      "color": "${color}",
      "title": "Database Backup ${status}",
      "fields": [
        {
          "title": "Server",
          "value": "${host}",
          "short": true
        },
        {
          "title": "Database",
          "value": "${DB_NAME}",
          "short": true
        },
        {
          "title": "Timestamp",
          "value": "$(date +'%Y-%m-%d %H:%M:%S')",
          "short": true
        }
      ],
      "text": "${message}"
    }
  ]
}
EOF
  )

  # Send the notification
  curl -s -X POST -H 'Content-type: application/json' --data "${payload}" "${SLACK_WEBHOOK_URL}" >/dev/null
}

# Function to notify about backup success
notify_success() {
  local message="$1"
  if [ "$SLACK_NOTIFY_ON_SUCCESS" = "true" ]; then
    send_slack_notification "Success" "$message" "good"
  fi
}

# Function to notify about backup failure
notify_failure() {
  local message="$1"
  send_slack_notification "FAILED" "$message" "danger"
}

# Enhanced success notification with backup details
backup_success() {
  local size=$(du -h "${FINAL_FILENAME}" | cut -f1)
  local duration=$(($(date +%s) - start_time))
  local message="✅ Backup completed successfully\n"
  message+="• Database: ${DB_NAME}\n"
  message+="• Backup file: ${FINAL_FILENAME}\n"
  message+="• Size: ${size}\n"
  message+="• Duration: $(date -u -d @${duration} +"%H:%M:%S")\n"
  message+="• S3 Location: ${S3_BUCKET}/${S3_PATH_PREFIX}/${FINAL_FILENAME}"

  notify_success "$message"
}

# Improved error handling with Slack notification
handle_error() {
  local exit_code=$?
  local duration=$(($(date +%s) - start_time))
  local error_message="🚨 Backup FAILED for ${DB_NAME}\n"
  error_message+="• Error code: ${exit_code}\n"
  error_message+="• Location: Line $(caller)\n"
  error_message+="• Duration: $(date -u -d @${duration} +"%H:%M:%S")\n"
  error_message+="• Please check the server logs for details."

  echo "ERROR: Backup failed with exit code $exit_code at line $(caller)"
  notify_failure "$error_message"
  exit $exit_code
}

# Set up error trap
trap 'handle_error' ERR

# Validate encryption settings
if [ "$ENCRYPTION" = "age" ]; then
  if [ -z "$ENCRYPTION_KEY" ] && [ -z "$ENCRYPTION_FILE" ]; then
    echo "Error: ENCRYPTION_KEY or ENCRYPTION_FILE must be provided when ENCRYPTION is set to 'age'"
    exit 1
  fi
  if [ -n "$ENCRYPTION_KEY" ] && [ -n "$ENCRYPTION_FILE" ]; then
    echo "Error: ENCRYPTION_KEY and ENCRYPTION_FILE are mutually exclusive"
    exit 1
  fi
fi

# Combine default and custom mysqldump parameters
MYSQLDUMP_PARAMS="$DEFAULT_MYSQLDUMP_PARAMS"
if [ -n "$MYSQLDUMP_PARAMETERS" ]; then
  MYSQLDUMP_PARAMS="$MYSQLDUMP_PARAMETERS"
fi

# Verify database connection before backup
echo "Verifying database connection..."
if ! MYSQL_PWD="$DB_PASSWORD" mysql -h "$DB_HOST" -u "$DB_USERNAME" -e "SELECT 1" "$DB_NAME" >/dev/null 2>&1; then
  echo "Error: Could not connect to database. Please check credentials and connectivity."
  exit 1
fi

# Get database size for progress estimation
echo "Estimating database size..."
DB_SIZE=$(MYSQL_PWD="$DB_PASSWORD" mysql -h "$DB_HOST" -u "$DB_USERNAME" -N -e "
SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) 
FROM information_schema.tables 
WHERE table_schema = '$DB_NAME'
GROUP BY table_schema;" "$DB_NAME")
echo "Estimated database size: ${DB_SIZE} MB"

# Perform database backup with timeout and progress
echo "Starting backup of database $DB_NAME from $DB_HOST..."
if command -v pv >/dev/null 2>&1 && [ -n "$DB_SIZE" ]; then
  timeout 7200 MYSQL_PWD="$DB_PASSWORD" mysqldump -h "$DB_HOST" -u "$DB_USERNAME" $MYSQLDUMP_PARAMS "$DB_NAME" | pv -s "${DB_SIZE}M" >"$FILENAME"
else
  timeout 7200 MYSQL_PWD="$DB_PASSWORD" mysqldump -h "$DB_HOST" -u "$DB_USERNAME" $MYSQLDUMP_PARAMS "$DB_NAME" >"$FILENAME"
fi

# Verify backup integrity
echo "Verifying backup integrity..."
BACKUP_SIZE=$(stat -c%s "$FILENAME")
if [ "$BACKUP_SIZE" -lt 1000 ]; then
  echo "Error: Backup file is suspiciously small ($BACKUP_SIZE bytes)"
  exit 1
fi

# Check for specific database structures to ensure backup contains expected data
grep -q "CREATE TABLE" "$FILENAME" || {
  echo "Error: Backup doesn't contain table definitions"
  exit 1
}

echo "Database backup completed: $FILENAME ($(du -h "$FILENAME" | cut -f1))"

# Compression
if [ "$COMPRESSION" = "gzip" ]; then
  echo "Compressing backup file..."
  gzip -f "$FILENAME"
  FINAL_FILENAME="${COMPRESSED_FILENAME}"
  echo "Compression completed: $FINAL_FILENAME ($(du -h "$FINAL_FILENAME" | cut -f1))"
fi

# Encryption
if [ "$ENCRYPTION" = "age" ]; then
  echo "Encrypting backup file..."
  if [ -n "$ENCRYPTION_KEY" ]; then
    echo "$ENCRYPTION_KEY" | age -R - -o "${FINAL_FILENAME}.age" "$FINAL_FILENAME"
  else
    age -R "$ENCRYPTION_FILE" -o "${FINAL_FILENAME}.age" "$FINAL_FILENAME"
  fi
  rm -f "$FINAL_FILENAME"
  FINAL_FILENAME="${FINAL_FILENAME}.age"
  echo "Encryption completed: $FINAL_FILENAME ($(du -h "$FINAL_FILENAME" | cut -f1))"
fi

# Configure s3cmd
echo "Configuring S3 client..."
cat >$TEMP_DIR/.s3cfg <<EOF
host_base = $S3_HOST
host_bucket = $S3_HOST/$S3_BUCKET
access_key = $S3_ACCESS_KEY
secret_key = $S3_SECRET_KEY
use_https = True
check_ssl_certificate = True
check_ssl_hostname = True
signature_v2 = False
EOF
chmod 600 $TEMP_DIR/.s3cfg

# Upload to S3
S3_DEST="s3://$S3_BUCKET"
if [ -n "$S3_PATH_PREFIX" ]; then
  S3_DEST="$S3_DEST/$S3_PATH_PREFIX"
fi
S3_FULL_PATH="$S3_DEST/$FINAL_FILENAME"
echo "Uploading backup to $S3_FULL_PATH..."

# Add retry logic for S3 upload
MAX_RETRIES=3
RETRY_COUNT=0

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  if s3cmd -c $TEMP_DIR/.s3cfg put "$FINAL_FILENAME" "$S3_FULL_PATH"; then
    echo "Upload completed successfully"
    break
  else
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
      echo "Upload failed, retrying in 5 seconds (attempt $RETRY_COUNT of $MAX_RETRIES)..."
      sleep 5
    else
      echo "Error: Upload failed after $MAX_RETRIES attempts"
      exit 1
    fi
  fi
done

# Verify upload success by listing the file on S3
echo "Verifying uploaded file..."
if ! s3cmd -c $TEMP_DIR/.s3cfg ls "$S3_FULL_PATH" >/dev/null; then
  echo "Error: Cannot verify uploaded file on S3"
  exit 1
fi

# Calculate total duration
end_time=$(date +%s)
duration=$((end_time - start_time))
echo "Backup process completed successfully in $(date -u -d @${duration} +"%H:%M:%S")"

# Remove local backup files
rm -f "$FILENAME" "$COMPRESSED_FILENAME" "${COMPRESSED_FILENAME}.age" "${FILENAME}.age"

# Send success notification
backup_success

exit 0
