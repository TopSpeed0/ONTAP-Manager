# S3 Client Operations Reference — AWS CLI, Scripts & Troubleshooting

## AWS CLI Setup for ONTAP S3

### Install
```powershell
winget install Amazon.AWSCLI
```

### Configure Profile
```powershell
aws configure set aws_access_key_id <ACCESS_KEY> --profile <PROFILE_NAME>
aws configure set aws_secret_access_key <SECRET_KEY> --profile <PROFILE_NAME>
aws configure set region us-east-1 --profile <PROFILE_NAME>
```

### Test Connectivity
```powershell
Test-NetConnection -ComputerName <S3_ENDPOINT_IP> -Port 443
```

### Common Operations
```powershell
$env:PYTHONWARNINGS = "ignore"  # suppress SSL warnings for self-signed certs

# List buckets
aws s3 ls --endpoint-url https://<ENDPOINT> --profile <PROFILE> --no-verify-ssl

# List objects in bucket
aws s3 ls s3://<BUCKET>/ --endpoint-url https://<ENDPOINT> --profile <PROFILE> --no-verify-ssl

# Upload file
aws s3 cp myfile.txt s3://<BUCKET>/ --endpoint-url https://<ENDPOINT> --profile <PROFILE> --no-verify-ssl

# Download file
aws s3 cp s3://<BUCKET>/myfile.txt ./myfile.txt --endpoint-url https://<ENDPOINT> --profile <PROFILE> --no-verify-ssl

# List objects (API)
aws s3api list-objects-v2 --bucket <BUCKET> --endpoint-url https://<ENDPOINT> --profile <PROFILE> --no-verify-ssl

# List object versions (versioned bucket)
aws s3api list-object-versions --bucket <BUCKET> --endpoint-url https://<ENDPOINT> --profile <PROFILE> --no-verify-ssl --max-items 10

# Recursive upload
aws s3 sync ./local-folder s3://<BUCKET>/prefix/ --endpoint-url https://<ENDPOINT> --profile <PROFILE> --no-verify-ssl

# Recursive download
aws s3 sync s3://<BUCKET>/prefix/ ./local-folder --endpoint-url https://<ENDPOINT> --profile <PROFILE> --no-verify-ssl

# Recursive delete
aws s3 rm s3://<BUCKET>/ --recursive --endpoint-url https://<ENDPOINT> --profile <PROFILE> --no-verify-ssl
```

### ONTAP-Specific Settings (MANDATORY for uploads)
```powershell
# ⚠️ REQUIRED for any upload/put operation — without these, aws s3 cp fails with:
#   "x-amz-content-sha256 must be UNSIGNED-PAYLOAD, STREAMING-AWS4-HMAC-SHA256-PAYLOAD or a valid sha256 value"
# Confirmed on ONTAP 9.13.1P9 with AWS CLI 1.42.x / 2.x

# PowerShell:
$env:AWS_REQUEST_CHECKSUM_CALCULATION = "WHEN_REQUIRED"
$env:AWS_RESPONSE_CHECKSUM_VALIDATION = "WHEN_REQUIRED"

# Linux/macOS (bash):
# export AWS_REQUEST_CHECKSUM_CALCULATION=WHEN_REQUIRED
# export AWS_RESPONSE_CHECKSUM_VALIDATION=WHEN_REQUIRED
# (add to ~/.bashrc to make permanent)

# Note: List buckets, list objects, and download work WITHOUT these vars.
# Only upload/put operations are affected.
```

## rclone Setup (Faster for Bulk Operations)

### Install
```powershell
winget install Rclone.Rclone --accept-package-agreements --accept-source-agreements
```

### Configure Remote
```powershell
rclone config create <REMOTE_NAME> s3 provider=Other endpoint=https://<S3_ENDPOINT> access_key_id=<ACCESS_KEY> secret_access_key="<SECRET_KEY>" no_check_bucket=true
```

### Common Operations
```powershell
# List files
rclone ls <REMOTE>:<BUCKET> --no-check-certificate

# Sync
rclone sync <REMOTE>:<BUCKET> ./local-folder --no-check-certificate -v

# Purge bucket (delete all objects + versions + markers)
rclone purge <REMOTE>:<BUCKET> --s3-versions --no-check-certificate -v
```

## Available PowerShell Scripts

Source: `<path-to-s3-scripts>/`

| Script | Purpose | Key Features |
|--------|---------|--------------|
| `compare-s3-buckets.ps1` | Compare objects between two buckets | ETag + Size comparison, CSV report, cross-endpoint support |
| `delete-s3.ps1` | Batch delete all objects from a bucket | Handles versions + delete markers, 1000/batch |
| `verify-bucket-isolation.ps1` | Prove bucket isolation on same volume | Deletes from one bucket, verifies other untouched |
| `create-s3-test-objects.ps1` | Create test objects for testing | Configurable count, size, prefix |
| `test-s3-replication.ps1` | Test S3 replication between endpoints | Creates on source, waits, verifies on destination |
| `remove-s3-via-netapp.sh` | ONTAP CLI lifecycle rules for cleanup | Fastest cleanup for large buckets |
| `test_s3_header_issue.py` | Reproduce x-amz-content-sha256 issue | SigV4 signing with/without header |

### Script Configuration Pattern
All scripts have a CONFIGURATION section at the top:
```powershell
$endpoint    = "https://your-s3-endpoint.example.com"
$bucket      = "your-bucket-name"
$profile     = "your-aws-profile"
```

### Credential Template (`Ps.cred.template`)
Dual-profile setup for source/destination operations:
```powershell
$profileSrc = "src"; $profileDst = "dst"
aws configure set aws_access_key_id "ACCESS_KEY" --profile $profileSrc
aws configure set aws_secret_access_key "SECRET_KEY" --profile $profileSrc
aws configure set region "us-east-1" --profile $profileSrc
# Repeat for $profileDst with destination credentials
```

### Script Details

#### `delete-s3.ps1` — Batch Delete (Versions + Markers)
Loops in rounds of 1000 objects, collecting both `Versions` and `DeleteMarkers` from `list-object-versions`, then batch-deletes via `delete-objects`. Continues until no objects remain. Handles versioned and non-versioned buckets.

#### `compare-s3-buckets.ps1` — Cross-Endpoint Replication Validation
Self-configures AWS profiles inline (source + destination), lists all objects on both endpoints, compares every object by **Key + ETag (MD5) + Size**. Exports a CSV report with differences. Supports optional prefix filter. Useful for validating SnapMirror S3 replication.

#### `verify-bucket-isolation.ps1` — 9-Test Bucket Isolation Suite
Proves that two buckets on the same FlexGroup volume are fully isolated:
1. Sample objects from both buckets, verify independent existence (ETag/Size match)
2. Count objects on both buckets before any changes
3. Delete ONE real object from target bucket
4. Verify source bucket object count unchanged
5. Verify deleted object still exists on source bucket
6. Re-upload deleted object to target bucket
7. Verify both buckets restored to original state
8. (Optional) Upload test object to one bucket, verify absent on other
9. (Optional) Clean up test object

**WARNING**: Deletes a real object as part of the test — use on test data only.

#### `test-s3-replication.ps1` — End-to-End Replication Test
Creates test objects on source endpoint, waits for replication, then verifies objects appear on destination with matching ETag/Size. Supports configurable wait intervals.

#### `test_s3_header_issue.py` — SigV4 Header Bug Reproducer
Python script using raw `botocore` SigV4 signing. Sends requests with and without `x-amz-content-sha256` header to prove ONTAP returns HTTP 500 when the header is missing. Prompts for endpoint, access key, secret key, and bucket name.

## Bucket Cleanup Guide

### Problem
Cannot delete S3 bucket on ONTAP when it contains objects, versions, or delete markers:
```
Cannot delete bucket "bucket_name" on Vserver "svm_name" because it is not empty.
```

### Solution 1: rclone purge (Fastest)
```powershell
rclone purge <REMOTE>:<BUCKET> --s3-versions --no-check-certificate -v
```

| Object Count | Estimated Time |
|-------------|----------------|
| 100K | 5-15 min |
| 200K | 10-30 min |
| 1M | 30-90 min |

### Solution 2: PowerShell batch delete (delete-s3.ps1)
Uses `aws s3api delete-objects` in batches of 1000. Handles versions + delete markers.

### Solution 3: ONTAP Lifecycle Rules (Best for very large buckets)
```
# Create rules to expire everything after 1 day
vserver object-store-server bucket lifecycle-management-rule create -vserver <SVM> -bucket <BUCKET> -action Expiration -index 1 -is-enabled true -obj-age-days 1 -rule-id 1
vserver object-store-server bucket lifecycle-management-rule create -vserver <SVM> -bucket <BUCKET> -action NoncurrentVersionExpiration -index 2 -is-enabled true -non-curr-days 1 -rule-id 1
vserver object-store-server bucket lifecycle-management-rule create -vserver <SVM> -bucket <BUCKET> -action AbortIncompleteMultipartUpload -index 3 -is-enabled true -after-initiation-days 1 -rule-id 1

# Check progress
vserver object-store-server bucket show -vserver <SVM> -bucket <BUCKET> -fields object-count

# IMPORTANT: Remove lifecycle rules after cleanup
vserver object-store-server bucket lifecycle-management-rule delete -vserver <SVM> -bucket <BUCKET> -index 1
vserver object-store-server bucket lifecycle-management-rule delete -vserver <SVM> -bucket <BUCKET> -index 2
vserver object-store-server bucket lifecycle-management-rule delete -vserver <SVM> -bucket <BUCKET> -index 3

# Then delete the empty bucket
vserver object-store-server bucket delete -vserver <SVM> -bucket <BUCKET>
```

## Known ONTAP S3 Issues

### x-amz-content-sha256 Header (HTTP 500 Bug)

**Symptom:** Client receives HTTP 500 InternalError on S3 requests
**Root Cause:** Missing mandatory `x-amz-content-sha256` header in SigV4-signed requests. ONTAP returns 500 instead of the correct 403 SignatureDoesNotMatch.

**Fix (client-side):** Include the header in all requests:
```
X-Amz-Content-SHA256: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
```
Or use:
```
X-Amz-Content-SHA256: UNSIGNED-PAYLOAD
```

**Key facts:**
- AWS CLI always includes this header automatically — not affected
- Affects custom S3 clients using raw SigV4 signing (e.g., JFrog)
- ONTAP accepts the header value without validation (treats any value like UNSIGNED-PAYLOAD)
- This is a known behavioral difference vs AWS S3 (which returns 403)
- No ONTAP configuration to disable the requirement
- Use `test_s3_header_issue.py` to reproduce/verify

### SSL Self-Signed Certificates
ONTAP S3 uses self-signed certificates by default. All clients must disable cert verification:
- AWS CLI: `--no-verify-ssl`
- rclone: `--no-check-certificate`
- Python requests: `verify=False`
- PowerShell: `-SkipCertificateCheck`
- Suppress Python warnings: `$env:PYTHONWARNINGS = "ignore"`

### put-object Checksum Errors
If `aws s3api put-object` fails on ONTAP, use `aws s3 cp` instead, or set:
```powershell
$env:AWS_REQUEST_CHECKSUM_CALCULATION = "WHEN_REQUIRED"
$env:AWS_RESPONSE_CHECKSUM_VALIDATION = "WHEN_REQUIRED"
```

## Ansible Automation

Playbook available at `ansible/s3-bucket-provision/` — see main SKILL.md for details.

Key modules: `na_ontap_s3_buckets`, `na_ontap_s3_users`, `na_ontap_s3_services`, `na_ontap_s3_groups`, `na_ontap_s3_policies`.
