# Backster - MySQL S3 Backup Script

A secure, robust, and feature-rich shell script for backing up MariaDB/MySQL databases to S3-compatible storage with encryption, compression, extensive error handling, and Slack notifications.

## Features

- **Secure Database Backup**: Uses non-locking backup strategy to avoid production impact
- **Comprehensive Error Handling**: Detailed error capture and reporting
- **Encryption Support**: Optional age-based encryption for sensitive data
- **Compression**: Reduces storage costs and transfer times
- **S3 Compatibility**: Works with any S3-compatible storage (AWS S3, MinIO, DigitalOcean Spaces, etc.)
- **Slack Notifications**: Real-time backup status alerts with detailed reports
- **Progress Monitoring**: Visual progress bar for large databases when `pv` is installed
- **Backup Verification**: Multi-stage verification to ensure backup integrity
- **Concurrency Protection**: Prevents multiple backup processes from running simultaneously
- **Automatic Cleanup**: Removes temporary files after successful or failed backups
- **Detailed Logging**: Comprehensive backup logs for troubleshooting and audit
- **Upload Retry Logic**: Automatically retries failed uploads
- **Timeout Protection**: Prevents runaway backup processes
- **Zero Deletion Permissions**: Operates with minimal S3 permissions, manages retention with S3 lifecycle policies

## Security First

- Secrets are never exposed in process lists or logs
- Uses environment variables for sensitive credentials
- Temporary files secured with appropriate permissions
- Supports state-of-the-art encryption with [age](https://github.com/FiloSottile/age)
- Credentials file securely removed after use
- Designed to work with least-privilege access policies

## Requirements

- Bash shell
- MySQL client tools (`mysql`, `mysqldump`)
- S3cmd for S3 operations
- Optional: age for encryption
- Optional: pv for progress visualization
- Optional: curl for Slack notifications

## Environment Variables

| Variable | Description | Required |
|----------|-------------|:--------:|
| `DB_NAME` | Database name to backup | Yes |
| `DB_HOST` | Database hostname/IP | Yes |
| `DB_USERNAME` | Database username | Yes |
| `DB_PASSWORD` | Database password | Yes |
| `S3_HOST` | S3 endpoint (e.g., s3.amazonaws.com) | Yes |
| `S3_ACCESS_KEY` | S3 access key | Yes | 
| `S3_SECRET_KEY` | S3 secret key | Yes |
| `S3_BUCKET` | S3 bucket name | Yes |
| `S3_PATH_PREFIX` | Path prefix in bucket | No |
| `FILENAME_PREFIX` | Prefix for backup files | No |
| `COMPRESSION` | Set to "gzip" to enable compression | No |
| `ENCRYPTION` | Set to "age" to enable encryption | No |
| `ENCRYPTION_KEY` | Age encryption key | Only with encryption |
| `ENCRYPTION_FILE` | Path to age recipients file | Only with encryption |
| `SLACK_ENABLED` | Set to "true" to enable Slack notifications | No |
| `SLACK_WEBHOOK_URL` | Slack webhook URL | Only with Slack |
| `SLACK_CHANNEL` | Slack channel for notifications | No |
| `SLACK_USERNAME` | Bot username in Slack | No |
| `SLACK_NOTIFY_ON_SUCCESS` | Send notifications on success | No |

## Usage

```bash
# Basic usage
DB_NAME=my_database DB_HOST=localhost DB_USERNAME=root DB_PASSWORD=secret \
S3_HOST=s3.amazonaws.com S3_ACCESS_KEY=key S3_SECRET_KEY=secret S3_BUCKET=my-bucket \
./mariadb-s3-backup.sh

# With compression and Slack notifications
DB_NAME=my_database DB_HOST=localhost DB_USERNAME=root DB_PASSWORD=secret \
S3_HOST=s3.amazonaws.com S3_ACCESS_KEY=key S3_SECRET_KEY=secret S3_BUCKET=my-bucket \
COMPRESSION=gzip SLACK_ENABLED=true SLACK_WEBHOOK_URL=https://hooks.slack.com/... \
./mariadb-s3-backup.sh

# With encryption
DB_NAME=my_database DB_HOST=localhost DB_USERNAME=root DB_PASSWORD=secret \
S3_HOST=s3.amazonaws.com S3_ACCESS_KEY=key S3_SECRET_KEY=secret S3_BUCKET=my-bucket \
COMPRESSION=gzip ENCRYPTION=age ENCRYPTION_KEY=age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p \
./mariadb-s3-backup.sh
```

## Docker Integration

This script is designed to work seamlessly in containerized environments. Example `docker-compose.yml` integration:

```yaml
services:
  backup:
    image: alpine:latest
    volumes:
      - ./mariadb-s3-backup.sh:/backup.sh
    environment:
      - DB_NAME=strapi
      - DB_HOST=mariadb
      - DB_USERNAME=strapi_user
      - DB_PASSWORD=password
      - S3_HOST=s3.amazonaws.com
      - S3_ACCESS_KEY=key
      - S3_SECRET_KEY=secret
      - S3_BUCKET=backups
      - COMPRESSION=gzip
      - SLACK_ENABLED=true
      - SLACK_WEBHOOK_URL=https://hooks.slack.com/services/xxx/yyy/zzz
    entrypoint: /bin/sh
    command: -c "apk add --no-cache mysql-client bash curl gzip s3cmd && /backup.sh"
```

## Managing Backup Retention

Rather than embedding retention policies in the script (which would require delete permissions), this script is designed to work with S3 lifecycle policies. This allows for more flexible retention strategies and follows the principle of least privilege by not requiring delete permissions for the backup process.

### Setting Up an S3 Lifecycle Policy

#### AWS S3 Console Method:

1. Go to the AWS S3 Console
2. Navigate to your backup bucket
3. Click on the "Management" tab
4. Click on "Create lifecycle rule"
5. Configure your lifecycle rule:
   - Name: `BackupRetention`
   - Scope: Limit to specific prefixes (enter your S3_PATH_PREFIX)
   - Actions: Check "Expire current versions of objects"
   - Expire after: Enter your desired retention period (e.g., 30 days)
6. Click "Create rule"

#### AWS CLI Method:

Create a lifecycle policy file (e.g., `lifecycle-policy.json`):

```json
{
  "Rules": [
    {
      "ID": "BackupRetentionRule",
      "Status": "Enabled",
      "Filter": {
        "Prefix": "your-prefix/"
      },
      "Expiration": {
        "Days": 30
      }
    }
  ]
}
```

Apply it to your bucket:

```bash
aws s3api put-bucket-lifecycle-configuration --bucket your-bucket-name --lifecycle-configuration file://lifecycle-policy.json
```

## Scheduling Backups

### Using Cron:

```bash
# Run backup daily at 3 AM
0 3 * * * /path/to/mariadb-s3-backup.sh > /var/log/backups/backup-$(date +\%Y\%m\%d).log 2>&1
```

### Using Docker Scheduled Container:

For Docker setups, you can create a dedicated backup service that runs on a schedule:

```yaml
services:
  scheduled-backup:
    image: alpine:latest
    volumes:
      - ./mariadb-s3-backup.sh:/backup.sh
    environment:
      # ... your environment variables ...
    entrypoint: /bin/sh
    command: -c "apk add --no-cache mysql-client bash curl gzip s3cmd && (echo '0 3 * * * /backup.sh > /proc/1/fd/1 2>&1') | crontab - && crond -f -l 8"
```

## Restore Process

Restoring from a backup:

```bash
# For unencrypted backups
gunzip -c backup_file.sql.gz | mysql -h hostname -u username -p database_name

# For encrypted backups
age --decrypt -i key.txt backup_file.sql.gz.age | gunzip | mysql -h hostname -u username -p database_name
```
