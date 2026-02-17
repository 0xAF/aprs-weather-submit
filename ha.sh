#!/bin/bash
# Home Assistant collector: fetch HA sensor data and call pws-report.sh
cd "$(dirname "$0")"

if [ ! -f .env ]; then
  echo "Error: .env not found. Create it from .env.sample and bind-mount it in Docker if you use Docker." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
. ./.env
set +a

DEBUG="${DEBUG:-0}"
DRY_RUN_HA="${DRY_RUN_HA:-0}"
WINDY_ENABLE="${WINDY_ENABLE:-0}"
APRS_ENABLE="${APRS_ENABLE:-0}"
REPORT_INTERVAL="${REPORT_INTERVAL:-300}"
HA_ENTITY_PREFIX="${HA_ENTITY_PREFIX:-}"

REPORT_MIN_INTERVAL=300

debug() {
  if [ "$DEBUG" -eq 1 ]; then
    printf 'DEBUG: %s\n' "$*" >&2
  fi
}

warn() {
  printf 'Warning: %s\n' "$*" >&2
}

validate_bool() {
  local name="$1"
  local value="$2"
  if ! [[ "$value" =~ ^[01]$ ]]; then
    echo "Error: ${name} must be 0 or 1." >&2
    exit 1
  fi
}

validate_positive_int() {
  local name="$1"
  local value="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "Error: ${name} must be a non-negative integer." >&2
    exit 1
  fi
  if [ "$value" -le 0 ]; then
    echo "Error: ${name} must be greater than zero." >&2
    exit 1
  fi
}

validate_bool "DEBUG" "$DEBUG"
validate_bool "DRY_RUN_HA" "$DRY_RUN_HA"
validate_bool "WINDY_ENABLE" "$WINDY_ENABLE"
validate_bool "APRS_ENABLE" "$APRS_ENABLE"
validate_positive_int "REPORT_INTERVAL" "$REPORT_INTERVAL"

required_vars=(HA_API_TOKEN HA_ENTITY_MATCH HA_ENTITY_MAP)
missing_vars=()
for var in "${required_vars[@]}"; do
  if [ -z "${!var}" ]; then
    missing_vars+=("$var")
  fi
done
if [ "${#missing_vars[@]}" -ne 0 ]; then
  printf 'Error: Required variables not set: %s\n' "${missing_vars[*]}" >&2
  exit 1
fi

collect_once() {
  local json_output sensor_lines
  local -a extra_args=("$@")
  json_output=$(curl -sS -X GET \
    -H "Authorization: Bearer $HA_API_TOKEN" \
    -H "Content-Type: application/json" \
    "${HA_HOST:-http://homeassistant.local:8123}"/api/states 2>/dev/null)

  sensor_lines=$(echo "$json_output" | jq -r \
    --arg match "$HA_ENTITY_MATCH" \
    --arg prefix "$HA_ENTITY_PREFIX" \
    '
    .[]
    | select(.entity_id | index($match))
    | .entity_id as $id
    | ($id | if $prefix != "" then sub($prefix; "") else . end) as $key
    | "\($key)=\(.state | tostring)"
  ')

  declare -A sensor_values=()
  while IFS='=' read -r key value; do
    if [ -n "$key" ]; then
      sensor_values["$key"]="$value"
    fi
  done <<< "$sensor_lines"

  declare -A mapped_values=()
  declare -A used_keys=()
  for pair in $HA_ENTITY_MAP; do
    param_name=${pair%%:*}
    ha_key=${pair#*:}
    value="${sensor_values[$ha_key]}"
    if [ -n "$value" ]; then
      mapped_values["$param_name"]="$value"
      used_keys["$ha_key"]=1
    fi
  done

  if [ "$DEBUG" -eq 1 ]; then
    for key in "${!sensor_values[@]}"; do
      if [ -z "${used_keys[$key]}" ]; then
        debug "Unmapped HA entity: $key"
      fi
    done
  fi

  report_args=()
  for pair in $HA_ENTITY_MAP; do
    param_name=${pair%%:*}
    value="${mapped_values[$param_name]}"
    if [ -n "$value" ]; then
      report_args+=("${param_name}=${value}")
    fi
  done

  if [ "$DEBUG" -eq 1 ]; then
    report_args+=("--log-fields")
  fi

  if [ "${#report_args[@]}" -eq 0 ]; then
    warn "No mapped HA values found to report."
  fi

  if [ "$DRY_RUN_HA" -eq 1 ]; then
    printf 'DRY_RUN_HA: would run:'
    printf ' %q' ./pws-report.sh "${extra_args[@]}" "${report_args[@]}"
    printf '\n'
    return 0
  fi

  ./pws-report.sh "${extra_args[@]}" "${report_args[@]}"
  report_status=$?
  if [ "$report_status" -ne 0 ] && [ "$report_status" -ne 2 ]; then
    warn "pws-report.sh exited with status ${report_status}."
  fi
}

effective_interval="$REPORT_INTERVAL"
if [ "$REPORT_INTERVAL" -lt "$REPORT_MIN_INTERVAL" ]; then
  warn "REPORT_INTERVAL too low (${REPORT_INTERVAL}). Using ${REPORT_MIN_INTERVAL} seconds."
  effective_interval="$REPORT_MIN_INTERVAL"
fi

printf 'Collector loop interval: %ss\n' "$effective_interval"

first_run=1
while true; do
  if [ "$first_run" -eq 1 ]; then
    FORCE_SEND_ARGS=("--force-send")
  else
    FORCE_SEND_ARGS=()
  fi

  collect_once "${FORCE_SEND_ARGS[@]}"
  first_run=0
  sleep "$effective_interval"
done
