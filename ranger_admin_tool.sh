#!/usr/bin/env bash

# Ranger Admin Backup / Diff / Restore Tool
# V1 - Bash only, Basic Auth, diff-before-restore, services/policies/tag-policies/roles/zones
#
# Requirements:
#   - bash 4+
#   - curl
#   - jq
#   - diff
#   - sort
#   - mktemp
#
# Configuration priority:
#   1) environment variables
#   2) config file passed via --config-file
#
# Environment variables:
#   RANGER_URL="https://ranger-host:6182"
#   RANGER_USER="admin"
#   RANGER_PASS="secret"
#   VERIFY_TLS="true"
#
# Examples:
#   ./ranger_admin_tool.sh backup-all --output-dir /data/ranger-backups
#   ./ranger_admin_tool.sh diff-policy --backup-dir /data/ranger-backups/ranger_20260414_101500 --service cm_hdfs --policy finance_read_only
#   ./ranger_admin_tool.sh restore-policy --backup-dir /data/ranger-backups/ranger_20260414_101500 --service cm_hdfs --policy finance_read_only
#   ./ranger_admin_tool.sh diff-service --backup-dir /data/ranger-backups/ranger_20260414_101500 --service cm_hdfs
#   ./ranger_admin_tool.sh restore-service --backup-dir /data/ranger-backups/ranger_20260414_101500 --service cm_hdfs --dry-run
#   ./ranger_admin_tool.sh diff-all --backup-dir /data/ranger-backups/ranger_20260414_101500
#   ./ranger_admin_tool.sh restore-all --backup-dir /data/ranger-backups/ranger_20260414_101500 --continue-on-error
#   ./ranger_admin_tool.sh diff-roles --backup-dir /data/ranger-backups/ranger_20260414_101500
#   ./ranger_admin_tool.sh restore-roles --backup-dir /data/ranger-backups/ranger_20260414_101500
#
# Notes:
#   - This script preserves user/group/role references found inside policies and roles.
#   - It does NOT create identities in LDAP/AD/external IAM.
#   - API endpoints may vary slightly across Ranger packaging; adjust endpoint constants if needed.

set -uo pipefail
umask 077

SCRIPT_VERSION="1.0.0"
DEFAULT_OUTPUT_DIR="./ranger-backups"
VERIFY_TLS="${VERIFY_TLS:-true}"
VERBOSE="false"
DEBUG="false"
DRY_RUN="false"
DIFF_ONLY="false"
FAIL_FAST="false"
CONTINUE_ON_ERROR="false"
CONFIG_FILE=""
OUTPUT_DIR="${DEFAULT_OUTPUT_DIR}"
BACKUP_DIR=""
SERVICE_NAME=""
POLICY_NAME=""
ROLE_NAME=""
ZONE_NAME=""
REPORTS_DIR=""
LOG_FILE=""
LAST_HTTP_CODE=""
LAST_HTTP_BODY=""
LAST_HTTP_HEADERS=""
TMP_DIR=""

RANGER_URL="<hadoop_ranger_url>"
RANGER_USER="<hadoop_ranger_admin_user>"
RANGER_PASS="<hadoop_ranger_admin_password>"

EXIT_OK=0
EXIT_FUNCTIONAL=1
EXIT_CONFIG=2
EXIT_API=3
EXIT_INVALID_BACKUP=4
EXIT_DIFF_FOUND=5
EXIT_PARTIAL_RESTORE=6

# Conservative endpoint set for Ranger public v2 API.
API_BASE_PUBLIC_V2="/service/public/v2/api"
ENDPOINT_SERVICES="${API_BASE_PUBLIC_V2}/service"
ENDPOINT_POLICIES="${API_BASE_PUBLIC_V2}/policy"
ENDPOINT_ROLES="${API_BASE_PUBLIC_V2}/roles"
ENDPOINT_ZONES="${API_BASE_PUBLIC_V2}/zones"

# ------------------------- Logging ---------------------------------------
now_iso() {
  date '+%Y-%m-%dT%H:%M:%S%z'
}

log_init() {
  if [[ -n "${REPORTS_DIR}" ]]; then
    mkdir -p "${REPORTS_DIR}"
    LOG_FILE="${REPORTS_DIR}/$(date '+%Y%m%d_%H%M%S')_run.log"
    : > "${LOG_FILE}"
  fi
}

_mask_secret() {
  sed \
    -e "s/${RANGER_PASS//\//\\\/}/********/g" \
    -e 's/Authorization: Basic [A-Za-z0-9+\/=]*/Authorization: Basic ********/g'
}

_log() {
  local level="$1"; shift
  local msg="$*"
  printf '%s [%s] %s\n' "$(now_iso)" "${level}" "${msg}" >&2
  if [[ -n "${LOG_FILE}" ]]; then
    printf '%s [%s] %s\n' "$(now_iso)" "${level}" "${msg}" | _mask_secret >> "${LOG_FILE}"
  fi
}

log_info()  { _log INFO  "$*"; }
log_warn()  { _log WARN  "$*"; }
log_error() { _log ERROR "$*"; }
log_debug() { [[ "${DEBUG}" == "true" ]] && _log DEBUG "$*"; }

fatal() {
  local code="$1"; shift
  log_error "$*"
  cleanup
  exit "${code}"
}

# ------------------------- Utilities -------------------------------------
cleanup() {
  [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]] && rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

require_tools() {
  local missing=0
  local tools=(bash curl jq diff sort mktemp sed awk find tr head dirname basename)
  for t in "${tools[@]}"; do
    command -v "${t}" >/dev/null 2>&1 || { log_error "Missing required tool: ${t}"; missing=1; }
  done
  [[ "${missing}" -eq 0 ]] || fatal "${EXIT_CONFIG}" "Install required tools before running this script."
}

usage() {
  cat <<'EOF'
Usage:
  ranger_admin_tool.sh <command> [options]

Commands:
  backup-all
  list-backups
  validate-backup
  diff-policy
  restore-policy
  diff-service
  restore-service
  diff-all
  restore-all
  diff-roles
  restore-roles
  diff-tag-policies
  restore-tag-policies

Common options:
  --config-file <file>
  --output-dir <dir>
  --backup-dir <dir>
  --service <service>
  --policy <policy_name>
  --role <role_name>
  --zone <zone_name>
  --verify-tls true|false
  --dry-run
  --diff-only
  --verbose
  --debug
  --fail-fast
  --continue-on-error
  -h, --help
EOF
}

parse_args() {
  [[ $# -ge 1 ]] || { usage; exit "${EXIT_CONFIG}"; }
  COMMAND="$1"
  shift

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config-file) CONFIG_FILE="$2"; shift 2 ;;
      --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
      --backup-dir) BACKUP_DIR="$2"; shift 2 ;;
      --service) SERVICE_NAME="$2"; shift 2 ;;
      --policy) POLICY_NAME="$2"; shift 2 ;;
      --role) ROLE_NAME="$2"; shift 2 ;;
      --zone) ZONE_NAME="$2"; shift 2 ;;
      --verify-tls) VERIFY_TLS="$2"; shift 2 ;;
      --dry-run) DRY_RUN="true"; shift ;;
      --diff-only) DIFF_ONLY="true"; shift ;;
      --verbose) VERBOSE="true"; shift ;;
      --debug) DEBUG="true"; shift ;;
      --fail-fast) FAIL_FAST="true"; shift ;;
      --continue-on-error) CONTINUE_ON_ERROR="true"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) fatal "${EXIT_CONFIG}" "Unknown argument: $1" ;;
    esac
  done
}

load_config() {
  if [[ -n "${CONFIG_FILE}" ]]; then
    [[ -f "${CONFIG_FILE}" ]] || fatal "${EXIT_CONFIG}" "Config file not found: ${CONFIG_FILE}"
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"
  fi

  RANGER_URL="${RANGER_URL:-}"
  RANGER_USER="${RANGER_USER:-}"
  RANGER_PASS="${RANGER_PASS:-}"
  VERIFY_TLS="${VERIFY_TLS:-true}"

  case "${VERIFY_TLS}" in
    true|false) ;;
    *) fatal "${EXIT_CONFIG}" "--verify-tls must be true or false" ;;
  esac

  case "${COMMAND}" in
    backup-all|diff-policy|restore-policy|diff-service|restore-service|diff-all|restore-all|diff-roles|restore-roles|diff-tag-policies|restore-tag-policies)
      [[ -n "${RANGER_URL}" ]] || fatal "${EXIT_CONFIG}" "RANGER_URL is required"
      [[ -n "${RANGER_USER}" ]] || fatal "${EXIT_CONFIG}" "RANGER_USER is required"
      [[ -n "${RANGER_PASS}" ]] || fatal "${EXIT_CONFIG}" "RANGER_PASS is required"
      ;;
  esac
}

safe_name() {
  echo "$1" | tr ' /:' '___' | sed 's/[^A-Za-z0-9_.-]/_/g'
}

ensure_dir() {
  mkdir -p "$1"
}

json_pretty() {
  jq '.' "$1"
}

write_json() {
  local target="$1"
  local content="$2"
  printf '%s\n' "${content}" > "${target}"
}

init_runtime() {
  TMP_DIR="$(mktemp -d)"
  if [[ -n "${BACKUP_DIR}" ]]; then
    REPORTS_DIR="${BACKUP_DIR}/reports"
  fi
  log_init
}

# ------------------------- HTTP layer ------------------------------------
api_request() {
  local method="$1"
  local url="$2"
  local data_file="${3:-}"
  local body_file header_file curl_args tls_flag

  body_file="${TMP_DIR}/body.$RANDOM.json"
  header_file="${TMP_DIR}/headers.$RANDOM.txt"
  LAST_HTTP_BODY="${body_file}"
  LAST_HTTP_HEADERS="${header_file}"

  tls_flag=()
  [[ "${VERIFY_TLS}" == "false" ]] && tls_flag=(-k)

  curl_args=(
    -sS
    -u "${RANGER_USER}:${RANGER_PASS}"
    -D "${header_file}"
    -o "${body_file}"
    -w '%{http_code}'
    -X "${method}"
    -H 'Accept: application/json'
  )

  if [[ -n "${data_file}" ]]; then
    curl_args+=( -H 'Content-Type: application/json' --data-binary "@${data_file}" )
  fi

  log_debug "HTTP ${method} ${url}"
  LAST_HTTP_CODE="$(curl "${tls_flag[@]}" "${curl_args[@]}" "${url}")" || return 1
  return 0
}

api_check_http() {
  local expected_family="$1"
  local code="${LAST_HTTP_CODE}"

  case "${expected_family}" in
    2xx) [[ "${code}" =~ ^2[0-9][0-9]$ ]] ;;
    200) [[ "${code}" == "200" ]] ;;
    201) [[ "${code}" == "201" ]] ;;
    204) [[ "${code}" == "204" ]] ;;
    *) fatal "${EXIT_CONFIG}" "Unsupported expected HTTP family: ${expected_family}" ;;
  esac
}

api_get() {
  local path="$1"
  api_request GET "${RANGER_URL}${path}" || return 1
}

api_post_file() {
  local path="$1" file="$2"
  api_request POST "${RANGER_URL}${path}" "${file}" || return 1
}

api_put_file() {
  local path="$1" file="$2"
  api_request PUT "${RANGER_URL}${path}" "${file}" || return 1
}

api_delete() {
  local path="$1"
  api_request DELETE "${RANGER_URL}${path}" || return 1
}

read_last_body() {
  cat "${LAST_HTTP_BODY}"
}

require_json_response() {
  jq empty "${LAST_HTTP_BODY}" >/dev/null 2>&1 || {
    log_error "Response body is not valid JSON (HTTP ${LAST_HTTP_CODE})"
    [[ -f "${LAST_HTTP_BODY}" ]] && sed -n '1,120p' "${LAST_HTTP_BODY}" >&2
    return 1
  }
}

# ------------------------- Normalization ---------------------------------
normalize_json_sort_arrays() {
  jq '
    def sort_strings: if type == "array" and all(.[]?; type == "string") then sort else . end;
    walk(sort_strings)
  ' "$1"
}

normalize_policy_json() {
  local input="$1"
  jq '
    def norm_accesses:
      if . == null then . else
        map(
          del(.isAllowed) |
          del(.id) |
          .users = ((.users // []) | sort) |
          .groups = ((.groups // []) | sort) |
          .roles = ((.roles // []) | sort) |
          .conditions = ((.conditions // []) | sort_by((.type // "") + "|" + ((.values // []) | join(",")))) |
          .accesses = ((.accesses // []) | sort_by(.type // ""))
        )
        | sort_by(((.accesses // []) | map(.type // "") | join(",")) + "|" + ((.users // []) | join(",")) + "|" + ((.groups // []) | join(",")) + "|" + ((.roles // []) | join(",")))
      end;

    def norm_items:
      if . == null then . else
        map(.values = ((.values // []) | sort))
        | sort_by(.type // "")
      end;

    def norm_resources:
      if . == null then . else
        with_entries(
          .value |= (
            .values = ((.values // []) | sort) |
            .excludes = (.excludes // false) |
            .isRecursive = (.isRecursive // false)
          )
        )
      end;

    if type == "array" then
      map(
        del(.id, .guid, .version, .createTime, .updateTime, .createdBy, .updatedBy, .serviceId, .zoneId, .policyText, .policyLabels, .isDenyAllElse, .rowFilterPolicyItemsCount, .dataMaskPolicyItemsCount, .policyPriority, .policyTypeName, .resourceSignature) |
        .name = (.name // "") |
        .service = (.service // "") |
        .conditions = (.conditions // []) |

        .isEnabled = (.isEnabled // true) |
        .isAuditEnabled = (.isAuditEnabled // true) |
        .resources |= norm_resources |
        .policyItems |= norm_accesses |
        .denyPolicyItems |= norm_accesses |
        .allowExceptions |= norm_accesses |
        .denyExceptions |= norm_accesses |
        .dataMaskPolicyItems |= norm_accesses |
        .rowFilterPolicyItems |= norm_accesses |
        .policyConditions |= norm_items
      ) | sort_by((.service // "") + "|" + (.name // "") + "|" + ((.policyType // 0)|tostring))
    else
      del(.id, .guid, .version, .createTime, .updateTime, .createdBy, .updatedBy, .serviceId, .zoneId, .policyText, .policyLabels, .isDenyAllElse, .rowFilterPolicyItemsCount, .dataMaskPolicyItemsCount, .policyPriority, .policyTypeName, .resourceSignature) |
      .name = (.name // "") |
      .service = (.service // "") |
      .conditions = (.conditions // []) |

      .isEnabled = (.isEnabled // true) |
      .isAuditEnabled = (.isAuditEnabled // true) |
      .resources |= norm_resources |
      .policyItems |= norm_accesses |
      .denyPolicyItems |= norm_accesses |
      .allowExceptions |= norm_accesses |
      .denyExceptions |= norm_accesses |
      .dataMaskPolicyItems |= norm_accesses |
      .rowFilterPolicyItems |= norm_accesses |
      .policyConditions |= norm_items
    end
  ' "$input"
}

normalize_role_json() {
  local input="$1"
  jq '
    def norm_principals:
      if . == null then [] else
        map(if type=="string" then {name:.} else . end)
        | map(del(.id,.createTime,.updateTime,.createdBy,.updatedBy,.userId,.groupId))
        | sort_by(.name // "")
      end;

    if type == "array" then
      map(
        del(.id,.guid,.version,.createTime,.updateTime,.createdBy,.updatedBy,.options) |
        .name = (.name // "") |
        .description = (.description // "") |
        .isEnabled = (.isEnabled // true) |
        .users |= norm_principals |
        .groups |= norm_principals |
        .roles |= norm_principals |
        .adminUsers |= norm_principals |
        .adminGroups |= norm_principals |
        .adminRoles |= norm_principals
      ) | sort_by(.name // "")
    else
      del(.id,.guid,.version,.createTime,.updateTime,.createdBy,.updatedBy,.options) |
      .name = (.name // "") |
      .description = (.description // "") |
      .isEnabled = (.isEnabled // true) |
      .users |= norm_principals |
      .groups |= norm_principals |
      .roles |= norm_principals |
      .adminUsers |= norm_principals |
      .adminGroups |= norm_principals |
      .adminRoles |= norm_principals
    end
  ' "$input"
}

normalize_zone_json() {
  local input="$1"
  jq '
    def norm_resources:
      if . == null then {} else
        with_entries(
          .value |= (
            map(
              .values = ((.values // []) | sort) |
              .isRecursive = (.isRecursive // false) |
              .isExcludes = (.isExcludes // false)
            )
            | sort_by(.name // "")
          )
        )
      end;

    if type == "array" then
      map(
        del(.id,.guid,.version,.createTime,.updateTime,.createdBy,.updatedBy) |
        .name = (.name // "") |
        .adminUsers = ((.adminUsers // []) | sort) |
        .adminUserGroups = ((.adminUserGroups // []) | sort) |
        .auditUsers = ((.auditUsers // []) | sort) |
        .auditUserGroups = ((.auditUserGroups // []) | sort) |
        .services = if (.services // null) == null then {} else (.services | with_entries(.value.resources |= norm_resources)) end
      ) | sort_by(.name // "")
    else
      del(.id,.guid,.version,.createTime,.updateTime,.createdBy,.updatedBy) |
      .name = (.name // "") |
      .adminUsers = ((.adminUsers // []) | sort) |
      .adminUserGroups = ((.adminUserGroups // []) | sort) |
      .auditUsers = ((.auditUsers // []) | sort) |
      .auditUserGroups = ((.auditUserGroups // []) | sort) |
      .services = if (.services // null) == null then {} else (.services | with_entries(.value.resources |= norm_resources)) end
    end
  ' "$input"
}

# ------------------------- Backup validation -----------------------------
require_backup_dir() {
  [[ -n "${BACKUP_DIR}" ]] || fatal "${EXIT_CONFIG}" "--backup-dir is required"
  [[ -d "${BACKUP_DIR}" ]] || fatal "${EXIT_INVALID_BACKUP}" "Backup directory not found: ${BACKUP_DIR}"
}

validate_backup() {
  require_backup_dir
  local missing=0
  local required=(
    "${BACKUP_DIR}/manifest.json"
    "${BACKUP_DIR}/services/services.raw.json"
    "${BACKUP_DIR}/roles/roles.raw.json"
    "${BACKUP_DIR}/zones/zones.raw.json"
  )
  for f in "${required[@]}"; do
    [[ -f "${f}" ]] || { log_error "Missing backup file: ${f}"; missing=1; }
  done
  [[ "${missing}" -eq 0 ]] || fatal "${EXIT_INVALID_BACKUP}" "Backup validation failed"
  log_info "Backup looks structurally valid: ${BACKUP_DIR}"
}

# ------------------------- Fetch API resources ---------------------------
fetch_services() {
  api_get "${ENDPOINT_SERVICES}" || return 1
  api_check_http 2xx || return 1
  require_json_response || return 1
  cat "${LAST_HTTP_BODY}"
}

fetch_all_policies_for_service_type() {
  local service="$1" policy_type="$2"
  api_get "${ENDPOINT_POLICIES}?serviceName=$(printf '%s' "${service}" | jq -sRr @uri)&policyType=${policy_type}" || return 1
  api_check_http 2xx || return 1
  require_json_response || return 1
  cat "${LAST_HTTP_BODY}"
}

fetch_roles() {
  api_get "${ENDPOINT_ROLES}" || return 1
  api_check_http 2xx || return 1
  require_json_response || return 1
  cat "${LAST_HTTP_BODY}"
}

fetch_zones() {
  api_get "${ENDPOINT_ZONES}" || return 1
  api_check_http 2xx || return 1
  require_json_response || return 1
  cat "${LAST_HTTP_BODY}"
}

get_policy_by_service_and_name_current() {
  local service="$1" name="$2" policy_type="$3"
  local tmp="$TMP_DIR/policies_lookup.$RANDOM.json"
  if ! fetch_all_policies_for_service_type "${service}" "${policy_type}" > "${tmp}"; then
    return 1
  fi
  jq --arg n "${name}" 'map(select(.name == $n)) | .[0] // empty' "${tmp}"
}

get_role_by_name_current() {
  local name="$1"
  local tmp="$TMP_DIR/roles_lookup.$RANDOM.json"
  if ! fetch_roles > "${tmp}"; then
    return 1
  fi
  jq --arg n "${name}" 'map(select(.name == $n)) | .[0] // empty' "${tmp}"
}

get_zone_by_name_current() {
  local name="$1"
  local tmp="$TMP_DIR/zones_lookup.$RANDOM.json"
  if ! fetch_zones > "${tmp}"; then
    return 1
  fi
  jq --arg n "${name}" 'map(select(.name == $n)) | .[0] // empty' "${tmp}"
}

service_exists_current() {
  local service="$1"
  local tmp="$TMP_DIR/services_lookup.$RANDOM.json"
  if ! fetch_services > "${tmp}"; then
    return 1
  fi
  jq -e --arg s "${service}" 'map(select(.name == $s)) | length > 0' "${tmp}" >/dev/null
}

# ------------------------- Backup ----------------------------------------
make_backup_root() {
  local ts
  ts="$(date '+%Y%m%d_%H%M%S')"
  BACKUP_DIR="${OUTPUT_DIR}/ranger_${ts}"
  ensure_dir "${BACKUP_DIR}"
  ensure_dir "${BACKUP_DIR}/services/by-name"
  ensure_dir "${BACKUP_DIR}/roles/by-name"
  ensure_dir "${BACKUP_DIR}/zones/by-name"
  ensure_dir "${BACKUP_DIR}/policies"
  ensure_dir "${BACKUP_DIR}/tag-policies"
  ensure_dir "${BACKUP_DIR}/reports"
  REPORTS_DIR="${BACKUP_DIR}/reports"
  log_init
}

save_services_backup() {
  local raw="${BACKUP_DIR}/services/services.raw.json"
  local norm="${BACKUP_DIR}/services/services.normalized.json"
  fetch_services > "${raw}" || return 1
  jq 'map(del(.id,.tagService,.createDate,.updateDate,.configs,.policyVersion,.policyUpdateTime,.description)) | sort_by(.name // "")' "${raw}" > "${norm}"
  jq -c '.[]' "${raw}" | while read -r obj; do
    local name safe
    name="$(printf '%s' "${obj}" | jq -r '.name')"
    safe="$(safe_name "${name}")"
    printf '%s\n' "${obj}" > "${BACKUP_DIR}/services/by-name/${safe}.json"
  done
}

save_roles_backup() {
  local raw="${BACKUP_DIR}/roles/roles.raw.json"
  local norm="${BACKUP_DIR}/roles/roles.normalized.json"
  fetch_roles > "${raw}" || return 1
  normalize_role_json "${raw}" > "${norm}"
  jq -c '.[]' "${raw}" | while read -r obj; do
    local name safe
    name="$(printf '%s' "${obj}" | jq -r '.name')"
    safe="$(safe_name "${name}")"
    printf '%s\n' "${obj}" > "${BACKUP_DIR}/roles/by-name/${safe}.json"
  done
}

save_zones_backup() {
  local raw="${BACKUP_DIR}/zones/zones.raw.json"
  local norm="${BACKUP_DIR}/zones/zones.normalized.json"
  if fetch_zones > "${raw}"; then
    normalize_zone_json "${raw}" > "${norm}"
    jq -c '.[]' "${raw}" | while read -r obj; do
      local name safe
      name="$(printf '%s' "${obj}" | jq -r '.name')"
      safe="$(safe_name "${name}")"
      printf '%s\n' "${obj}" > "${BACKUP_DIR}/zones/by-name/${safe}.json"
    done
  else
    log_warn "Zones endpoint unavailable or failed; writing empty zone set"
    printf '[]\n' > "${raw}"
    printf '[]\n' > "${norm}"
  fi
}

save_policies_for_service() {
  local service="$1" policy_type="$2" rootdir raw norm subdir byname byguid
  if [[ "${policy_type}" == "0" ]]; then
    subdir="${BACKUP_DIR}/policies/${service}"
    raw="${subdir}/resource_policies.raw.json"
    norm="${subdir}/resource_policies.normalized.json"
  else
    subdir="${BACKUP_DIR}/tag-policies/${service}"
    raw="${subdir}/tag_policies.raw.json"
    norm="${subdir}/tag_policies.normalized.json"
  fi
  byname="${subdir}/by-name"
  byguid="${subdir}/by-guid"
  ensure_dir "${subdir}"
  ensure_dir "${byname}"
  ensure_dir "${byguid}"

  fetch_all_policies_for_service_type "${service}" "${policy_type}" > "${raw}" || return 1
  normalize_policy_json "${raw}" > "${norm}"

  jq -c '.[]' "${raw}" | while read -r obj; do
    local name guid safe
    name="$(printf '%s' "${obj}" | jq -r '.name')"
    guid="$(printf '%s' "${obj}" | jq -r '.guid // empty')"
    safe="$(safe_name "${name}")"
    printf '%s\n' "${obj}" > "${byname}/${safe}.json"
    [[ -n "${guid}" ]] && printf '%s\n' "${obj}" > "${byguid}/${guid}.json"
  done
}

write_manifest() {
  local services_count resource_policies_count tag_policies_count roles_count zones_count status
  services_count="$(jq 'length' "${BACKUP_DIR}/services/services.raw.json")"
  roles_count="$(jq 'length' "${BACKUP_DIR}/roles/roles.raw.json")"
  zones_count="$(jq 'length' "${BACKUP_DIR}/zones/zones.raw.json")"
  resource_policies_count="$(find "${BACKUP_DIR}/policies" -type f -path '*/by-name/*.json' 2>/dev/null | wc -l | awk '{print $1}')"
  tag_policies_count="$(find "${BACKUP_DIR}/tag-policies" -type f -path '*/by-name/*.json' 2>/dev/null | wc -l | awk '{print $1}')"
  status="complete"

  jq -n \
    --arg ts "$(now_iso)" \
    --arg url "${RANGER_URL}" \
    --arg version "${SCRIPT_VERSION}" \
    --argjson sc "${services_count}" \
    --argjson rpc "${resource_policies_count}" \
    --argjson tpc "${tag_policies_count}" \
    --argjson rc "${roles_count}" \
    --argjson zc "${zones_count}" \
    --arg status "${status}" \
    '{backup_timestamp:$ts,ranger_url:$url,script_version:$version,services_count:$sc,resource_policies_count:$rpc,tag_policies_count:$tpc,roles_count:$rc,zones_count:$zc,status:$status}' \
    > "${BACKUP_DIR}/manifest.json"

  jq -n \
    --arg verify_tls "${VERIFY_TLS}" \
    --arg output_dir "${OUTPUT_DIR}" \
    '{verify_tls:$verify_tls,output_dir:$output_dir}' > "${BACKUP_DIR}/config_snapshot.json"

  {
    echo "Backup summary"
    echo "Backup dir: ${BACKUP_DIR}"
    echo "Services: ${services_count}"
    echo "Resource policies: ${resource_policies_count}"
    echo "Tag policies: ${tag_policies_count}"
    echo "Roles: ${roles_count}"
    echo "Zones: ${zones_count}"
  } > "${BACKUP_DIR}/reports/backup_summary.txt"
}

backup_all() {
  make_backup_root
  log_info "Starting Ranger backup into ${BACKUP_DIR}"

  save_services_backup || fatal "${EXIT_API}" "Unable to fetch services"
  save_roles_backup || fatal "${EXIT_API}" "Unable to fetch roles"
  save_zones_backup || {
    if [[ "${FAIL_FAST}" == "true" ]]; then
      fatal "${EXIT_API}" "Unable to fetch zones"
    else
      log_warn "Zones backup failed; continuing"
    fi
  }

  jq -r '.[].name' "${BACKUP_DIR}/services/services.raw.json" | while read -r service; do
    [[ -n "${service}" ]] || continue
    log_info "Backing up service: ${service}"
    if ! save_policies_for_service "${service}" 0; then
      log_error "Failed to backup resource policies for ${service}"
      [[ "${FAIL_FAST}" == "true" ]] && fatal "${EXIT_API}" "Backup aborted"
    fi

    # Best-effort support for tag policies. Some services may have none or endpoint may return empty array.
    if ! save_policies_for_service "${service}" 1; then
      log_warn "Tag policies fetch failed for ${service}; writing empty set"
      ensure_dir "${BACKUP_DIR}/tag-policies/${service}"
      ensure_dir "${BACKUP_DIR}/tag-policies/${service}/by-name"
      ensure_dir "${BACKUP_DIR}/tag-policies/${service}/by-guid"
      printf '[]\n' > "${BACKUP_DIR}/tag-policies/${service}/tag_policies.raw.json"
      printf '[]\n' > "${BACKUP_DIR}/tag-policies/${service}/tag_policies.normalized.json"
    fi
  done

  write_manifest
  log_info "Backup completed: ${BACKUP_DIR}"
}

list_backups() {
  ensure_dir "${OUTPUT_DIR}"
  find "${OUTPUT_DIR}" -maxdepth 1 -mindepth 1 -type d -name 'ranger_*' | sort
}

# ------------------------- File lookup helpers ---------------------------
policy_type_dir_from_name() {
  local kind="$1"
  if [[ "${kind}" == "resource" ]]; then
    echo "policies"
  else
    echo "tag-policies"
  fi
}

find_policy_in_backup() {
  local kind="$1" service="$2" policy_name="$3" path
  path="${BACKUP_DIR}/$(policy_type_dir_from_name "${kind}")/${service}/by-name/$(safe_name "${policy_name}").json"
  [[ -f "${path}" ]] || return 1
  echo "${path}"
}

find_role_in_backup() {
  local path="${BACKUP_DIR}/roles/by-name/$(safe_name "${ROLE_NAME}").json"
  [[ -f "${path}" ]] || return 1
  echo "${path}"
}

find_zone_in_backup_by_name() {
  local name="$1" path
  path="${BACKUP_DIR}/zones/by-name/$(safe_name "${name}").json"
  [[ -f "${path}" ]] || return 1
  echo "${path}"
}

# ------------------------- Comparison helpers ----------------------------
json_diff_files() {
  local left="$1" right="$2"
  diff -u "$left" "$right" || true
}

compare_normalized_json() {
  local left="$1" right="$2"
  cmp -s "$left" "$right"
}

write_tmp_normalized_policy() {
  local input="$1" out="$2"
  normalize_policy_json "$input" > "$out"
}

write_tmp_normalized_role() {
  local input="$1" out="$2"
  normalize_role_json "$input" > "$out"
}

write_tmp_normalized_zone() {
  local input="$1" out="$2"
  normalize_zone_json "$input" > "$out"
}

# ------------------------- Policy diff/apply -----------------------------
diff_one_policy_kind() {
  local kind="$1" service="$2" policy_name="$3" policy_type current_raw backup_raw current_norm backup_norm status
  [[ "${kind}" == "resource" ]] && policy_type=0 || policy_type=1

  backup_raw="$(find_policy_in_backup "${kind}" "${service}" "${policy_name}")" || {
    log_error "Policy not found in backup (${kind}): service=${service}, name=${policy_name}"
    return 1
  }

  backup_norm="${TMP_DIR}/backup_policy_norm.$RANDOM.json"
  current_raw="${TMP_DIR}/current_policy_raw.$RANDOM.json"
  current_norm="${TMP_DIR}/current_policy_norm.$RANDOM.json"

  write_tmp_normalized_policy "${backup_raw}" "${backup_norm}"

  if get_policy_by_service_and_name_current "${service}" "${policy_name}" "${policy_type}" > "${current_raw}" 2>/dev/null && [[ -s "${current_raw}" ]]; then
    write_tmp_normalized_policy "${current_raw}" "${current_norm}"
    if compare_normalized_json "${backup_norm}" "${current_norm}"; then
      status="IDENTICAL"
    else
      status="DIFFERENT"
    fi
  else
    status="MISSING_IN_TARGET"
  fi

  echo "STATUS=${status}"
  echo "KIND=${kind}"
  echo "SERVICE=${service}"
  echo "POLICY=${policy_name}"

  if [[ "${status}" == "DIFFERENT" ]]; then
    echo "--- DIFF BEGIN ---"
    json_diff_files "${current_norm}" "${backup_norm}"
    echo "--- DIFF END ---"
  fi
}

diff_policy() {
  require_backup_dir
  [[ -n "${SERVICE_NAME}" ]] || fatal "${EXIT_CONFIG}" "--service is required"
  [[ -n "${POLICY_NAME}" ]] || fatal "${EXIT_CONFIG}" "--policy is required"

  local found=1 rc=0
  if find_policy_in_backup resource "${SERVICE_NAME}" "${POLICY_NAME}" >/dev/null 2>&1; then
    diff_one_policy_kind resource "${SERVICE_NAME}" "${POLICY_NAME}"
    found=0
  fi
  if find_policy_in_backup tag "${SERVICE_NAME}" "${POLICY_NAME}" >/dev/null 2>&1; then
    diff_one_policy_kind tag "${SERVICE_NAME}" "${POLICY_NAME}"
    found=0
  fi

  [[ "${found}" -eq 0 ]] || fatal "${EXIT_INVALID_BACKUP}" "Policy not found in backup in resource or tag-policies"
  return "${rc}"
}

prepare_policy_payload_for_create() {
  local src="$1" dst="$2"
  jq 'del(.id,.guid,.version,.createTime,.updateTime,.createdBy,.updatedBy,.serviceId,.zoneId)' "$src" > "$dst"
}

prepare_policy_payload_for_update() {
  local src="$1" current="$2" dst="$3"
  local current_id
  current_id="$(jq -r '.id // empty' "$current")"
  jq --argjson id "${current_id:-null}" '
    del(.guid,.version,.createTime,.updateTime,.createdBy,.updatedBy,.serviceId,.zoneId) |
    if $id == null then del(.id) else .id = $id end
  ' "$src" > "$dst"
}

apply_one_policy_kind() {
  local kind="$1" service="$2" policy_name="$3" policy_type backup_raw current_raw payload status
  [[ "${kind}" == "resource" ]] && policy_type=0 || policy_type=1

  backup_raw="$(find_policy_in_backup "${kind}" "${service}" "${policy_name}")" || {
    log_error "Policy not found in backup (${kind}): ${service}/${policy_name}"
    return 1
  }

  status="$(diff_one_policy_kind "${kind}" "${service}" "${policy_name}" | awk -F= '/^STATUS=/{print $2; exit}')"
  log_info "Policy ${kind} ${service}/${policy_name} => ${status}"

  [[ "${DIFF_ONLY}" == "true" ]] && return 0
  [[ "${status}" == "IDENTICAL" ]] && return 0

  current_raw="${TMP_DIR}/current_policy_apply.$RANDOM.json"
  payload="${TMP_DIR}/policy_payload.$RANDOM.json"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "DRY-RUN: would apply policy ${kind} ${service}/${policy_name} (${status})"
    return 0
  fi

  if [[ "${status}" == "MISSING_IN_TARGET" ]]; then
    prepare_policy_payload_for_create "${backup_raw}" "${payload}"
    api_post_file "${ENDPOINT_POLICIES}" "${payload}" || return 1
    api_check_http 2xx || {
      log_error "Create failed for policy ${service}/${policy_name} (HTTP ${LAST_HTTP_CODE})"
      return 1
    }
    require_json_response || return 1
    log_info "Created policy ${kind} ${service}/${policy_name}"
  else
    get_policy_by_service_and_name_current "${service}" "${policy_name}" "${policy_type}" > "${current_raw}" || return 1
    [[ -s "${current_raw}" ]] || return 1
    prepare_policy_payload_for_update "${backup_raw}" "${current_raw}" "${payload}"
    local current_id
    current_id="$(jq -r '.id' "${current_raw}")"
    api_put_file "${ENDPOINT_POLICIES}/${current_id}" "${payload}" || return 1
    api_check_http 2xx || {
      log_error "Update failed for policy ${service}/${policy_name} (HTTP ${LAST_HTTP_CODE})"
      return 1
    }
    require_json_response || return 1
    log_info "Updated policy ${kind} ${service}/${policy_name}"
  fi
}

restore_policy() {
  require_backup_dir
  [[ -n "${SERVICE_NAME}" ]] || fatal "${EXIT_CONFIG}" "--service is required"
  [[ -n "${POLICY_NAME}" ]] || fatal "${EXIT_CONFIG}" "--policy is required"
  service_exists_current "${SERVICE_NAME}" || fatal "${EXIT_FUNCTIONAL}" "Service missing in target Ranger: ${SERVICE_NAME}"

  local rc=0 applied=0
  if find_policy_in_backup resource "${SERVICE_NAME}" "${POLICY_NAME}" >/dev/null 2>&1; then
    apply_one_policy_kind resource "${SERVICE_NAME}" "${POLICY_NAME}" || rc=1
    applied=1
  fi
  if find_policy_in_backup tag "${SERVICE_NAME}" "${POLICY_NAME}" >/dev/null 2>&1; then
    apply_one_policy_kind tag "${SERVICE_NAME}" "${POLICY_NAME}" || rc=1
    applied=1
  fi
  [[ "${applied}" -eq 1 ]] || fatal "${EXIT_INVALID_BACKUP}" "Policy not found in backup"
  [[ "${rc}" -eq 0 ]] || exit "${EXIT_PARTIAL_RESTORE}"
}

# ------------------------- Service diff/restore --------------------------
diff_service_kind() {
  local kind="$1" service="$2" dir type_label report file name status current_names backup_names
  [[ "${kind}" == "resource" ]] && dir="${BACKUP_DIR}/policies/${service}/by-name" || dir="${BACKUP_DIR}/tag-policies/${service}/by-name"
  [[ -d "${dir}" ]] || { log_warn "No backup directory for ${kind} policies of service ${service}"; return 0; }

  while IFS= read -r file; do
    [[ -f "${file}" ]] || continue
    name="$(jq -r '.name' "${file}")"
    diff_one_policy_kind "${kind}" "${service}" "${name}"
  done < <(find "${dir}" -type f -name '*.json' | sort)
}

diff_service() {
  require_backup_dir
  [[ -n "${SERVICE_NAME}" ]] || fatal "${EXIT_CONFIG}" "--service is required"
  log_info "Diffing service ${SERVICE_NAME}"
  diff_service_kind resource "${SERVICE_NAME}"
  diff_service_kind tag "${SERVICE_NAME}"
}

restore_service() {
  require_backup_dir
  [[ -n "${SERVICE_NAME}" ]] || fatal "${EXIT_CONFIG}" "--service is required"
  service_exists_current "${SERVICE_NAME}" || fatal "${EXIT_FUNCTIONAL}" "Service missing in target Ranger: ${SERVICE_NAME}"

  local rc=0 file name dir
  for dir in "${BACKUP_DIR}/policies/${SERVICE_NAME}/by-name" "${BACKUP_DIR}/tag-policies/${SERVICE_NAME}/by-name"; do
    [[ -d "${dir}" ]] || continue
    while IFS= read -r file; do
      [[ -f "${file}" ]] || continue
      name="$(jq -r '.name' "${file}")"
      if [[ "${dir}" == *"/tag-policies/"* ]]; then
        apply_one_policy_kind tag "${SERVICE_NAME}" "${name}" || rc=1
      elif [[ "${dir}" == *"/tag-policies/"* ]]; then
        apply_one_policy_kind tag "${SERVICE_NAME}" "${name}" || rc=1
      else
        apply_one_policy_kind resource "${SERVICE_NAME}" "${name}" || rc=1
      fi
      if [[ "${rc}" -ne 0 && "${FAIL_FAST}" == "true" ]]; then
        exit "${EXIT_PARTIAL_RESTORE}"
      fi
    done < <(find "${dir}" -type f -name '*.json' | sort)
  done
  [[ "${rc}" -eq 0 ]] || exit "${EXIT_PARTIAL_RESTORE}"
}

diff_all() {
  require_backup_dir
  local service
  jq -r '.[].name' "${BACKUP_DIR}/services/services.raw.json" | while read -r service; do
    [[ -n "${service}" ]] || continue
    echo "### SERVICE ${service} ###"
    diff_service_kind resource "${service}"
    diff_service_kind tag "${service}"
    echo
  done
}

restore_all() {
  require_backup_dir
  local rc=0 service zonefile zonename rolefile rolename

  # Zones first
  if [[ -d "${BACKUP_DIR}/zones/by-name" ]]; then
    while IFS= read -r zonefile; do
      zonename="$(jq -r '.name' "${zonefile}")"
      restore_one_zone "${zonename}" || rc=1
      [[ "${rc}" -ne 0 && "${FAIL_FAST}" == "true" ]] && exit "${EXIT_PARTIAL_RESTORE}"
    done < <(find "${BACKUP_DIR}/zones/by-name" -type f -name '*.json' | sort)
  fi

  # Roles second
  if [[ -d "${BACKUP_DIR}/roles/by-name" ]]; then
    while IFS= read -r rolefile; do
      rolename="$(jq -r '.name' "${rolefile}")"
      restore_one_role "${rolename}" || rc=1
      [[ "${rc}" -ne 0 && "${FAIL_FAST}" == "true" ]] && exit "${EXIT_PARTIAL_RESTORE}"
    done < <(find "${BACKUP_DIR}/roles/by-name" -type f -name '*.json' | sort)
  fi

  # Policies third/fourth
  jq -r '.[].name' "${BACKUP_DIR}/services/services.raw.json" | while read -r service; do
    [[ -n "${service}" ]] || continue
    SERVICE_NAME="${service}"
    restore_service || rc=1
    [[ "${rc}" -ne 0 && "${FAIL_FAST}" == "true" ]] && exit "${EXIT_PARTIAL_RESTORE}"
  done

  [[ "${rc}" -eq 0 ]] || exit "${EXIT_PARTIAL_RESTORE}"
}

# ------------------------- Roles diff/restore ----------------------------
diff_one_role() {
  local role_name="$1" backup_raw backup_norm current_raw current_norm status
  backup_raw="${BACKUP_DIR}/roles/by-name/$(safe_name "${role_name}").json"
  [[ -f "${backup_raw}" ]] || { log_error "Role not found in backup: ${role_name}"; return 1; }

  backup_norm="${TMP_DIR}/role_backup_norm.$RANDOM.json"
  current_raw="${TMP_DIR}/role_current_raw.$RANDOM.json"
  current_norm="${TMP_DIR}/role_current_norm.$RANDOM.json"

  write_tmp_normalized_role "${backup_raw}" "${backup_norm}"

  if get_role_by_name_current "${role_name}" > "${current_raw}" 2>/dev/null && [[ -s "${current_raw}" ]]; then
    write_tmp_normalized_role "${current_raw}" "${current_norm}"
    if compare_normalized_json "${backup_norm}" "${current_norm}"; then
      status="IDENTICAL"
    else
      status="DIFFERENT_MEMBERS"
    fi
  else
    status="MISSING_IN_TARGET"
  fi

  echo "STATUS=${status}"
  echo "ROLE=${role_name}"
  if [[ "${status}" == "DIFFERENT_MEMBERS" ]]; then
    echo "--- DIFF BEGIN ---"
    json_diff_files "${current_norm}" "${backup_norm}"
    echo "--- DIFF END ---"
  fi
}

prepare_role_payload_for_create() {
  local src="$1" dst="$2"
  jq 'del(.id,.guid,.version,.createTime,.updateTime,.createdBy,.updatedBy)' "$src" > "$dst"
}

prepare_role_payload_for_update() {
  local src="$1" current="$2" dst="$3"
  local current_id
  current_id="$(jq -r '.id // empty' "$current")"
  jq --argjson id "${current_id:-null}" 'del(.guid,.version,.createTime,.updateTime,.createdBy,.updatedBy) | if $id == null then del(.id) else .id = $id end' "$src" > "$dst"
}

restore_one_role() {
  local role_name="$1" backup_raw current_raw payload status current_id
  backup_raw="${BACKUP_DIR}/roles/by-name/$(safe_name "${role_name}").json"
  [[ -f "${backup_raw}" ]] || { log_error "Role not found in backup: ${role_name}"; return 1; }

  status="$(diff_one_role "${role_name}" | awk -F= '/^STATUS=/{print $2; exit}')"
  log_info "Role ${role_name} => ${status}"

  [[ "${DIFF_ONLY}" == "true" ]] && return 0
  [[ "${status}" == "IDENTICAL" ]] && return 0
  [[ "${DRY_RUN}" == "true" ]] && { log_info "DRY-RUN: would apply role ${role_name}"; return 0; }

  payload="${TMP_DIR}/role_payload.$RANDOM.json"
  current_raw="${TMP_DIR}/role_current_apply.$RANDOM.json"

  if [[ "${status}" == "MISSING_IN_TARGET" ]]; then
    prepare_role_payload_for_create "${backup_raw}" "${payload}"
    api_post_file "${ENDPOINT_ROLES}" "${payload}" || return 1
    api_check_http 2xx || return 1
    require_json_response || return 1
    log_info "Created role ${role_name}"
  else
    get_role_by_name_current "${role_name}" > "${current_raw}" || return 1
    current_id="$(jq -r '.id' "${current_raw}")"
    prepare_role_payload_for_update "${backup_raw}" "${current_raw}" "${payload}"
    api_put_file "${ENDPOINT_ROLES}/${current_id}" "${payload}" || return 1
    api_check_http 2xx || return 1
    require_json_response || return 1
    log_info "Updated role ${role_name}"
  fi
}

diff_roles() {
  require_backup_dir
  local file rolename rc=0
  while IFS= read -r file; do
    [[ -f "${file}" ]] || continue
    rolename="$(jq -r '.name' "${file}")"
    diff_one_role "${rolename}" || rc=1
  done < <(find "${BACKUP_DIR}/roles/by-name" -type f -name '*.json' | sort)
  return "${rc}"
}

restore_roles() {
  require_backup_dir
  local file rolename rc=0
  while IFS= read -r file; do
    [[ -f "${file}" ]] || continue
    rolename="$(jq -r '.name' "${file}")"
    restore_one_role "${rolename}" || rc=1
    [[ "${rc}" -ne 0 && "${FAIL_FAST}" == "true" ]] && exit "${EXIT_PARTIAL_RESTORE}"
  done < <(find "${BACKUP_DIR}/roles/by-name" -type f -name '*.json' | sort)
  [[ "${rc}" -eq 0 ]] || exit "${EXIT_PARTIAL_RESTORE}"
}

# ------------------------- Zones diff/restore ----------------------------
diff_one_zone() {
  local zone_name="$1" backup_raw backup_norm current_raw current_norm status
  backup_raw="${BACKUP_DIR}/zones/by-name/$(safe_name "${zone_name}").json"
  [[ -f "${backup_raw}" ]] || { log_error "Zone not found in backup: ${zone_name}"; return 1; }

  backup_norm="${TMP_DIR}/zone_backup_norm.$RANDOM.json"
  current_raw="${TMP_DIR}/zone_current_raw.$RANDOM.json"
  current_norm="${TMP_DIR}/zone_current_norm.$RANDOM.json"

  write_tmp_normalized_zone "${backup_raw}" "${backup_norm}"

  if get_zone_by_name_current "${zone_name}" > "${current_raw}" 2>/dev/null && [[ -s "${current_raw}" ]]; then
    write_tmp_normalized_zone "${current_raw}" "${current_norm}"
    if compare_normalized_json "${backup_norm}" "${current_norm}"; then
      status="IDENTICAL"
    else
      status="DIFFERENT"
    fi
  else
    status="MISSING_IN_TARGET"
  fi

  echo "STATUS=${status}"
  echo "ZONE=${zone_name}"
  if [[ "${status}" == "DIFFERENT" ]]; then
    echo "--- DIFF BEGIN ---"
    json_diff_files "${current_norm}" "${backup_norm}"
    echo "--- DIFF END ---"
  fi
}

prepare_zone_payload_for_create() {
  local src="$1" dst="$2"
  jq 'del(.id,.guid,.version,.createTime,.updateTime,.createdBy,.updatedBy)' "$src" > "$dst"
}

prepare_zone_payload_for_update() {
  local src="$1" current="$2" dst="$3"
  local current_id
  current_id="$(jq -r '.id // empty' "$current")"
  jq --argjson id "${current_id:-null}" 'del(.guid,.version,.createTime,.updateTime,.createdBy,.updatedBy) | if $id == null then del(.id) else .id = $id end' "$src" > "$dst"
}

restore_one_zone() {
  local zone_name="$1" backup_raw current_raw payload status current_id
  backup_raw="${BACKUP_DIR}/zones/by-name/$(safe_name "${zone_name}").json"
  [[ -f "${backup_raw}" ]] || { log_error "Zone not found in backup: ${zone_name}"; return 1; }

  status="$(diff_one_zone "${zone_name}" | awk -F= '/^STATUS=/{print $2; exit}')"
  log_info "Zone ${zone_name} => ${status}"

  [[ "${DIFF_ONLY}" == "true" ]] && return 0
  [[ "${status}" == "IDENTICAL" ]] && return 0
  [[ "${DRY_RUN}" == "true" ]] && { log_info "DRY-RUN: would apply zone ${zone_name}"; return 0; }

  payload="${TMP_DIR}/zone_payload.$RANDOM.json"
  current_raw="${TMP_DIR}/zone_current_apply.$RANDOM.json"

  if [[ "${status}" == "MISSING_IN_TARGET" ]]; then
    prepare_zone_payload_for_create "${backup_raw}" "${payload}"
    api_post_file "${ENDPOINT_ZONES}" "${payload}" || return 1
    api_check_http 2xx || return 1
    require_json_response || return 1
    log_info "Created zone ${zone_name}"
  else
    get_zone_by_name_current "${zone_name}" > "${current_raw}" || return 1
    current_id="$(jq -r '.id' "${current_raw}")"
    prepare_zone_payload_for_update "${backup_raw}" "${current_raw}" "${payload}"
    api_put_file "${ENDPOINT_ZONES}/${current_id}" "${payload}" || return 1
    api_check_http 2xx || return 1
    require_json_response || return 1
    log_info "Updated zone ${zone_name}"
  fi
}

# ------------------------- Tag policies commands -------------------------
diff_tag_policies() {
  require_backup_dir
  [[ -n "${SERVICE_NAME}" ]] || fatal "${EXIT_CONFIG}" "--service is required"
  diff_service_kind tag "${SERVICE_NAME}"
}

restore_tag_policies() {
  require_backup_dir
  [[ -n "${SERVICE_NAME}" ]] || fatal "${EXIT_CONFIG}" "--service is required"
  local dir file name rc=0
  dir="${BACKUP_DIR}/tag-policies/${SERVICE_NAME}/by-name"
  [[ -d "${dir}" ]] || fatal "${EXIT_INVALID_BACKUP}" "No tag-policies backup for service ${SERVICE_NAME}"
  while IFS= read -r file; do
    [[ -f "${file}" ]] || continue
    name="$(jq -r '.name' "${file}")"
    apply_one_policy_kind tag "${SERVICE_NAME}" "${name}" || rc=1
    [[ "${rc}" -ne 0 && "${FAIL_FAST}" == "true" ]] && exit "${EXIT_PARTIAL_RESTORE}"
  done < <(find "${dir}" -type f -name '*.json' | sort)
  [[ "${rc}" -eq 0 ]] || exit "${EXIT_PARTIAL_RESTORE}"
}

# ------------------------- Main ------------------------------------------
main() {
  parse_args "$@"
  require_tools
  load_config
  init_runtime

  case "${COMMAND}" in
    backup-all)
      backup_all
      ;;
    list-backups)
      list_backups
      ;;
    validate-backup)
      validate_backup
      ;;
    diff-policy)
      diff_policy
      ;;
    restore-policy)
      restore_policy
      ;;
    diff-service)
      diff_service
      ;;
    restore-service)
      restore_service
      ;;
    diff-all)
      diff_all
      ;;
    restore-all)
      restore_all
      ;;
    diff-roles)
      diff_roles
      ;;
    restore-roles)
      restore_roles
      ;;
    diff-tag-policies)
      diff_tag_policies
      ;;
    restore-tag-policies)
      restore_tag_policies
      ;;
    *)
      usage
      exit "${EXIT_CONFIG}"
      ;;
  esac
}

main "$@"
