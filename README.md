# hadoop-ranger_admin_bakup_restore_tool
Bash-based backup, diff, and restore tool for Apache Ranger policies, roles, tag policies, and zones.

# ranger_admin_tool.sh

A Bash-based Apache Ranger administration tool for:

* backing up Ranger logical configuration through the API
* comparing a backup with the current Ranger state
* restoring a single policy, a full service, all services, roles, tag policies, and zones

This script was designed for Cloudera / Apache Ranger environments using **Basic Auth**.

---

## Features

### Backup

* exports all Ranger services
* exports resource policies per service
* exports tag policies per service
* exports roles
* exports zones
* generates a `manifest.json`
* generates normalized JSON files to make diffs cleaner and more stable

### Diff

* diff a single policy
* diff a full service
* diff everything
* diff roles
* diff tag policies

### Restore

* restore a single policy
* restore all policies for one service
* restore everything
* restore roles
* restore tag policies
* restore zones through `restore-all`

### Restore behavior

Restore operations use **create-or-update** logic:

* if the object does not exist in Ranger, it is **created**
* if the object exists and differs, it is **updated**
* if the object is already identical, nothing is changed

---

## Scope

This script is intended to back up and restore Ranger **logical configuration**, including:

* services
* resource policies
* tag policies
* roles
* zones

It preserves user, group, and role references found in policies and roles, but it does **not** create identities in LDAP, Active Directory, or any external IAM system.

---

## Requirements

The script requires at least:

* `bash` 4+
* `curl`
* `jq`
* `diff`
* `sort`
* `mktemp`
* `sed`
* `awk`
* `find`

The script checks for required tools at startup.

---

## Authentication

The script uses **Basic Auth** to connect to Ranger.

Configuration can be provided either:

1. through **environment variables**
2. through a **configuration file** passed with `--config-file`

### Expected environment variables

```bash
RANGER_URL="https://ranger-host:6182"
RANGER_USER="admin"
RANGER_PASS="secret"
VERIFY_TLS="true"
```

### Example configuration file

```bash
RANGER_URL="https://ranger-host:6182"
RANGER_USER="admin"
RANGER_PASS="secret"
VERIFY_TLS="true"
```

---

## Usage

### Syntax

```bash
./ranger_admin_tool.sh <command> [options]
```

### Available commands

* `backup-all`
* `list-backups`
* `validate-backup`
* `diff-policy`
* `restore-policy`
* `diff-service`
* `restore-service`
* `diff-all`
* `restore-all`
* `diff-roles`
* `restore-roles`
* `diff-tag-policies`
* `restore-tag-policies`

### Common options

* `--config-file <file>`
* `--output-dir <dir>`
* `--backup-dir <dir>`
* `--service <service>`
* `--policy <policy_name>`
* `--role <role_name>`
* `--zone <zone_name>`
* `--verify-tls true|false`
* `--dry-run`
* `--diff-only`
* `--verbose`
* `--debug`
* `--fail-fast`
* `--continue-on-error`

---

## Examples

### Full Ranger backup

```bash
./ranger_admin_tool.sh backup-all --config-file ./ranger_admin_tool.conf --output-dir /data/ranger-backups
```

This creates a timestamped backup directory such as:

```text
/data/ranger-backups/ranger_YYYYmmdd_HHMMSS
```

### List available backups

```bash
./ranger_admin_tool.sh list-backups --output-dir /data/ranger-backups
```

### Validate a backup

```bash
./ranger_admin_tool.sh validate-backup --backup-dir /data/ranger-backups/ranger_YYYYmmdd_HHMMSS
```

### Diff a single policy

```bash
./ranger_admin_tool.sh diff-policy \
  --config-file ./ranger_admin_tool.conf \
  --backup-dir /data/ranger-backups/ranger_YYYYmmdd_HHMMSS \
  --service cm_hdfs \
  --policy "finance_read_only"
```

### Restore a single policy

```bash
./ranger_admin_tool.sh restore-policy \
  --config-file ./ranger_admin_tool.conf \
  --backup-dir /data/ranger-backups/ranger_YYYYmmdd_HHMMSS \
  --service cm_hdfs \
  --policy "finance_read_only"
```

### Simulate a policy restore

```bash
./ranger_admin_tool.sh restore-policy \
  --config-file ./ranger_admin_tool.conf \
  --backup-dir /data/ranger-backups/ranger_YYYYmmdd_HHMMSS \
  --service cm_hdfs \
  --policy "finance_read_only" \
  --dry-run
```

### Diff a full service

```bash
./ranger_admin_tool.sh diff-service \
  --config-file ./ranger_admin_tool.conf \
  --backup-dir /data/ranger-backups/ranger_YYYYmmdd_HHMMSS \
  --service cm_hdfs
```

### Restore all policies for one service

```bash
./ranger_admin_tool.sh restore-service \
  --config-file ./ranger_admin_tool.conf \
  --backup-dir /data/ranger-backups/ranger_YYYYmmdd_HHMMSS \
  --service cm_hdfs
```

### Diff everything

```bash
./ranger_admin_tool.sh diff-all \
  --config-file ./ranger_admin_tool.conf \
  --backup-dir /data/ranger-backups/ranger_YYYYmmdd_HHMMSS
```

### Restore everything

```bash
./ranger_admin_tool.sh restore-all \
  --config-file ./ranger_admin_tool.conf \
  --backup-dir /data/ranger-backups/ranger_YYYYmmdd_HHMMSS
```

### Diff roles

```bash
./ranger_admin_tool.sh diff-roles \
  --config-file ./ranger_admin_tool.conf \
  --backup-dir /data/ranger-backups/ranger_YYYYmmdd_HHMMSS
```

### Restore roles

```bash
./ranger_admin_tool.sh restore-roles \
  --config-file ./ranger_admin_tool.conf \
  --backup-dir /data/ranger-backups/ranger_YYYYmmdd_HHMMSS
```

### Diff tag policies for one service

```bash
./ranger_admin_tool.sh diff-tag-policies \
  --config-file ./ranger_admin_tool.conf \
  --backup-dir /data/ranger-backups/ranger_YYYYmmdd_HHMMSS \
  --service cm_tag
```

### Restore tag policies for one service

```bash
./ranger_admin_tool.sh restore-tag-policies \
  --config-file ./ranger_admin_tool.conf \
  --backup-dir /data/ranger-backups/ranger_YYYYmmdd_HHMMSS \
  --service cm_tag
```

---

## Backup structure

Each backup is stored in a timestamped directory.

Example:

```text
ranger_YYYYmmdd_HHMMSS/
├── manifest.json
├── config_snapshot.json
├── services/
│   ├── services.raw.json
│   ├── services.normalized.json
│   └── by-name/
├── roles/
│   ├── roles.raw.json
│   ├── roles.normalized.json
│   └── by-name/
├── zones/
│   ├── zones.raw.json
│   ├── zones.normalized.json
│   └── by-name/
├── policies/
│   └── <service>/
│       ├── resource_policies.raw.json
│       ├── resource_policies.normalized.json
│       ├── by-name/
│       └── by-guid/
├── tag-policies/
│   └── <service>/
│       ├── tag_policies.raw.json
│       ├── tag_policies.normalized.json
│       ├── by-name/
│       └── by-guid/
└── reports/
```

### File meaning

* `*.raw.json`: raw objects returned by Ranger
* `*.normalized.json`: normalized version used for diffs
* `by-name/`: per-object files indexed by name
* `by-guid/`: per-policy files indexed by GUID when available
* `manifest.json`: backup summary

---

## Normalization

The script normalizes objects to avoid noisy or misleading diffs.

### Policies

Server-generated or purely technical fields are removed from the diff, such as:

* `id`
* `guid`
* `version`
* `createTime`
* `updateTime`
* `createdBy`
* `updatedBy`
* `serviceId`
* `zoneId`
* `policyText`
* `policyLabels`
* `resourceSignature`

The script also normalizes and sorts items such as:

* `conditions`
* `users`
* `groups`
* `roles`
* `accesses`
* `policyConditions`
* `resources`

### Roles

Memberships are sorted and technical metadata is excluded from comparisons.

### Zones

Lists and resources are normalized and sorted to keep diffs stable.

---

## `--dry-run`

`--dry-run` simulates a restore without modifying Ranger.

It is mainly useful with restore commands:

* `restore-policy`
* `restore-service`
* `restore-all`
* `restore-roles`
* `restore-tag-policies`

The script computes the diff, decides what it would do, then stops before sending `POST` or `PUT` requests.

---

## `--diff-only`

`--diff-only` forces read-only comparison mode.

Use it when you want to inspect differences without attempting any restore action.

---

## Exit codes

The script uses the following exit codes:

* `0`: success
* `1`: functional error
* `2`: configuration error
* `3`: API error
* `4`: invalid backup
* `5`: diff found
* `6`: partial restore

---

## Logging

The script writes:

* runtime messages to `stderr`
* a run log inside `reports/` when `BACKUP_DIR` is defined

Secrets are masked in log output.

---

## Security notes

The script sets:

```bash
umask 077
```

so newly created files are private by default.

Recommendations:

* do not hardcode Ranger credentials in the script
* prefer a protected config file or environment variables
* keep `VERIFY_TLS=true` whenever possible

---

## Operational recommendations

Before running any restore, the recommended workflow is:

1. `validate-backup`
2. `diff-*`
3. `restore-* --dry-run`
4. `restore-*`

For scheduled backups, it is recommended to use a wrapper script that:

* runs `backup-all`
* archives the backup
* sends the archive to remote storage such as S3
* enforces local retention

---

## Known limitations

* exact Ranger API behavior may vary slightly depending on version and packaging
* some environments may require endpoint adjustments for roles or zones
* the script restores Ranger configuration, not external identities
* this is a Ranger API backup/restore tool, not a full Ranger database dump tool

---

## License

This project is licensed under the MIT License. See the `LICENSE` file for details.
