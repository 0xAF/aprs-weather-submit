#!/bin/bash
# Convert weather inputs and send to APRS/Windy based on .env settings.
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
APRS_ENABLE="${APRS_ENABLE:-0}"
WINDY_ENABLE="${WINDY_ENABLE:-0}"
REPORT_INTERVAL="${REPORT_INTERVAL:-300}"
APRS_DRY_RUN="${APRS_DRY_RUN:-0}"
WINDY_DRY_RUN="${WINDY_DRY_RUN:-0}"
WINDY_URL="${WINDY_URL:-https://stations.windy.com/api/v2/observation/update}"
PWS_CACHE_FILE="${PWS_CACHE_FILE:-.pws-report.cache}"
LUX_EFFICACY="${LUX_EFFICACY:-110}"
REPORT_MIN_INTERVAL=300

FORCE_DRY_RUN=0
FORCE_SEND=0
LOG_FIELDS=0

warn() {
  printf 'Warning: %s\n' "$*" >&2
}

debug() {
  if [ "$DEBUG" -eq 1 ]; then
    printf 'DEBUG: %s\n' "$*" >&2
  fi
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

is_number() {
  [[ "$1" =~ ^-?[0-9]+([.][0-9]+)?$ ]]
}

c_to_f() {
  awk -v c="$1" 'BEGIN{printf "%.1f", (c*9/5)+32}'
}

f_to_c() {
  awk -v f="$1" 'BEGIN{printf "%.1f", (f-32)*5/9}'
}

mm_to_in() {
  awk -v mm="$1" 'BEGIN{printf "%.3f", mm/25.4}'
}

kmh_to_mph() {
  awk -v kmh="$1" 'BEGIN{printf "%.2f", kmh*0.621371}'
}

kmh_to_ms() {
  awk -v kmh="$1" 'BEGIN{printf "%.2f", kmh/3.6}'
}

ms_to_kmh() {
  awk -v ms="$1" 'BEGIN{printf "%.2f", ms*3.6}'
}

mph_to_kmh() {
  awk -v mph="$1" 'BEGIN{printf "%.2f", mph/0.621371}'
}

meters_to_feet() {
  awk -v m="$1" 'BEGIN{printf "%.0f", m*3.28084}'
}

lux_to_wm2() {
  awk -v lux="$1" -v eff="$LUX_EFFICACY" 'BEGIN{if (eff==0) {print ""} else {printf "%.2f", lux/eff}}'
}

calc_delta_mm() {
  awk -v cur="$1" -v base="$2" 'BEGIN{d=cur-base; if (d<0) d=0; printf "%.3f", d}'
}

rfc3339_local() {
  local offset
  offset=$(date +%z)
  printf '%s%s:%s' "$(date +%Y-%m-%dT%H:%M:%S)" "${offset:0:3}" "${offset:3:2}"
}

INPUT_KEYS=()
declare -A INPUT_VALUES

for arg in "$@"; do
  case "$arg" in
    --dry-run)
      FORCE_DRY_RUN=1
      ;;
    --log-fields)
      LOG_FIELDS=1
      ;;
    --force-send)
      FORCE_SEND=1
      ;;
    --help|-h)
      cat <<'EOF'
Usage: ./pws-report.sh [--dry-run] [--log-fields] [--force-send] key=value ...

Send weather observations to APRS and/or Windy based on .env settings.
EOF
      exit 0
      ;;
    *=*)
      key=${arg%%=*}
      value=${arg#*=}
      INPUT_KEYS+=("$key")
      INPUT_VALUES["$key"]="$value"
      ;;
    *)
      echo "Error: Invalid argument: $arg" >&2
      exit 1
      ;;
  esac
done

if [ "$LOG_FIELDS" -eq 1 ]; then
  if [ "${#INPUT_KEYS[@]}" -eq 0 ]; then
    echo "Fields:"
  else
    printf 'Fields: %s\n' "$(printf '%s\n' "${INPUT_KEYS[@]}" | sort | xargs)"
  fi
fi

validate_bool "DEBUG" "$DEBUG"
validate_bool "APRS_ENABLE" "$APRS_ENABLE"
validate_bool "WINDY_ENABLE" "$WINDY_ENABLE"
validate_bool "APRS_DRY_RUN" "$APRS_DRY_RUN"
validate_bool "WINDY_DRY_RUN" "$WINDY_DRY_RUN"
validate_positive_int "REPORT_INTERVAL" "$REPORT_INTERVAL"

if [ "$APRS_ENABLE" -eq 1 ]; then
  aprs_required_vars=(APRS_CALLSIGN APRS_LATITUDE APRS_LONGITUDE APRS_USERNAME APRS_PASSWORD)
  aprs_missing=()
  for var in "${aprs_required_vars[@]}"; do
    if [ -z "${!var}" ]; then
      aprs_missing+=("$var")
    fi
  done
  if [ "${#aprs_missing[@]}" -ne 0 ]; then
    printf 'Error: Required APRS variables not set: %s\n' "${aprs_missing[*]}" >&2
    exit 1
  fi
fi

if [ "$WINDY_ENABLE" -eq 1 ]; then
  windy_required_vars=(WINDY_STATION_ID WINDY_PASSWORD)
  windy_missing=()
  for var in "${windy_required_vars[@]}"; do
    if [ -z "${!var}" ]; then
      windy_missing+=("$var")
    fi
  done
  if [ "${#windy_missing[@]}" -ne 0 ]; then
    printf 'Error: Required Windy variables not set: %s\n' "${windy_missing[*]}" >&2
    exit 1
  fi
fi

if [ "$DEBUG" -eq 1 ]; then
  debug "Destinations enabled: APRS=${APRS_ENABLE}, WINDY=${WINDY_ENABLE}"
fi

if [ "$APRS_ENABLE" -eq 0 ] && [ "$WINDY_ENABLE" -eq 0 ]; then
  warn "No destinations enabled. Defaulting to dry-run mode."
  FORCE_DRY_RUN=1
fi

if [ "$FORCE_DRY_RUN" -eq 1 ]; then
  APRS_DRY_RUN=1
  WINDY_DRY_RUN=1
fi

effective_interval="$REPORT_INTERVAL"
if [ "$REPORT_INTERVAL" -lt "$REPORT_MIN_INTERVAL" ]; then
  warn "REPORT_INTERVAL too low (${REPORT_INTERVAL}). Using ${REPORT_MIN_INTERVAL} seconds."
  effective_interval="$REPORT_MIN_INTERVAL"
fi

# Load cache
if [ -f "$PWS_CACHE_FILE" ]; then
  # shellcheck disable=SC1090
  . "$PWS_CACHE_FILE"
fi

now_ts=$(date +%s)

temperature_c="${INPUT_VALUES[temperatureC]}"
temperature_f="${INPUT_VALUES[temperatureF]}"
if [ -z "$temperature_c" ] && [ -n "$temperature_f" ] && is_number "$temperature_f"; then
  temperature_c=$(f_to_c "$temperature_f")
fi
if [ -z "$temperature_f" ] && [ -n "$temperature_c" ] && is_number "$temperature_c"; then
  temperature_f=$(c_to_f "$temperature_c")
fi

dewpoint_c="${INPUT_VALUES[dewpointC]}"
dewpoint_f="${INPUT_VALUES[dewpointF]}"
if [ -z "$dewpoint_c" ] && [ -n "$dewpoint_f" ] && is_number "$dewpoint_f"; then
  dewpoint_c=$(f_to_c "$dewpoint_f")
fi
if [ -z "$dewpoint_f" ] && [ -n "$dewpoint_c" ] && is_number "$dewpoint_c"; then
  dewpoint_f=$(c_to_f "$dewpoint_c")
fi

humidity="${INPUT_VALUES[humidity]}"
wind_dir_deg="${INPUT_VALUES[windDirDeg]}"
uv_index="${INPUT_VALUES[uvIndex]}"

pressure_hpa="${INPUT_VALUES[pressureHpa]}"
if [ -z "$pressure_hpa" ]; then
  pressure_hpa="${INPUT_VALUES[pressureMb]}"
fi
if [ -z "$pressure_hpa" ] && [ -n "${INPUT_VALUES[pressurePa]}" ] && is_number "${INPUT_VALUES[pressurePa]}"; then
  pressure_hpa=$(awk -v pa="${INPUT_VALUES[pressurePa]}" 'BEGIN{printf "%.1f", pa/100}')
fi

wind_speed_kph="${INPUT_VALUES[windSpeedKph]}"
if [ -z "$wind_speed_kph" ] && [ -n "${INPUT_VALUES[windSpeedMps]}" ] && is_number "${INPUT_VALUES[windSpeedMps]}"; then
  wind_speed_kph=$(ms_to_kmh "${INPUT_VALUES[windSpeedMps]}")
fi
if [ -z "$wind_speed_kph" ] && [ -n "${INPUT_VALUES[windSpeedMph]}" ] && is_number "${INPUT_VALUES[windSpeedMph]}"; then
  wind_speed_kph=$(mph_to_kmh "${INPUT_VALUES[windSpeedMph]}")
fi

wind_gust_kph="${INPUT_VALUES[windGustKph]}"
if [ -z "$wind_gust_kph" ] && [ -n "${INPUT_VALUES[windGustMps]}" ] && is_number "${INPUT_VALUES[windGustMps]}"; then
  wind_gust_kph=$(ms_to_kmh "${INPUT_VALUES[windGustMps]}")
fi
if [ -z "$wind_gust_kph" ] && [ -n "${INPUT_VALUES[windGustMph]}" ] && is_number "${INPUT_VALUES[windGustMph]}"; then
  wind_gust_kph=$(mph_to_kmh "${INPUT_VALUES[windGustMph]}")
fi

wind_speed_mph=""
wind_speed_ms=""
if [ -n "$wind_speed_kph" ] && is_number "$wind_speed_kph"; then
  wind_speed_mph=$(kmh_to_mph "$wind_speed_kph")
  wind_speed_ms=$(kmh_to_ms "$wind_speed_kph")
fi

wind_gust_mph=""
wind_gust_ms=""
if [ -n "$wind_gust_kph" ] && is_number "$wind_gust_kph"; then
  wind_gust_mph=$(kmh_to_mph "$wind_gust_kph")
  wind_gust_ms=$(kmh_to_ms "$wind_gust_kph")
fi

outside_luminance_lux="${INPUT_VALUES[outsideLuminanceLux]}"
if [ -z "$outside_luminance_lux" ]; then
  outside_luminance_lux="${INPUT_VALUES[luminosityLux]}"
fi

luminosity_wm2=""
if [ -n "$outside_luminance_lux" ] && is_number "$outside_luminance_lux"; then
  luminosity_wm2=$(lux_to_wm2 "$outside_luminance_lux")
fi

rain_total_mm="${INPUT_VALUES[rainTotalMm]}"
if [ -n "$rain_total_mm" ] && ! is_number "$rain_total_mm"; then
  warn "rainTotalMm is not numeric; skipping rain history update."
  rain_total_mm=""
fi

since_midnight_mm=""
last_hour_mm=""
last_day_mm=""
if [ -n "$rain_total_mm" ]; then
  today=$(date +%F)

  if [ -n "$RAIN_TOTAL_MM_LAST" ] && [ -n "$rain_total_mm" ] && awk "BEGIN{exit !($rain_total_mm < $RAIN_TOTAL_MM_LAST)}"; then
    RAIN_HISTORY=""
    MIDNIGHT_DATE="$today"
    MIDNIGHT_TOTAL="$rain_total_mm"
  fi

  if [ -z "$MIDNIGHT_DATE" ] || [ "$MIDNIGHT_DATE" != "$today" ] || [ -z "$MIDNIGHT_TOTAL" ]; then
    MIDNIGHT_DATE="$today"
    MIDNIGHT_TOTAL="$rain_total_mm"
  fi

  history="${RAIN_HISTORY:-}"
  new_history=""
  cutoff_keep=$((now_ts - 90000))

  for entry in $history; do
    ts=${entry%%:*}
    total=${entry#*:}
    if [ -n "$ts" ] && [ "$ts" -ge "$cutoff_keep" ] 2>/dev/null; then
      new_history+="$ts:$total "
    fi
  done

  new_history+="$now_ts:$rain_total_mm"
  new_history="$(echo "$new_history" | awk '{$1=$1;print}')"

  find_snapshot_total() {
    local target_ts="$1"
    local snap_total=""
    local entry ts total
    for entry in $new_history; do
      ts=${entry%%:*}
      total=${entry#*:}
      if [ "$ts" -le "$target_ts" ] 2>/dev/null; then
        snap_total="$total"
      fi
    done
    echo "$snap_total"
  }

  hour_target=$((now_ts - 3600))
  day_target=$((now_ts - 86400))

  hour_total=$(find_snapshot_total "$hour_target")
  day_total=$(find_snapshot_total "$day_target")

  since_midnight_mm=$(calc_delta_mm "$rain_total_mm" "$MIDNIGHT_TOTAL")

  if [ -n "$hour_total" ]; then
    last_hour_mm=$(calc_delta_mm "$rain_total_mm" "$hour_total")
  fi

  if [ -n "$day_total" ]; then
    last_day_mm=$(calc_delta_mm "$rain_total_mm" "$day_total")
  fi

  RAIN_TOTAL_MM_LAST="$rain_total_mm"
  RAIN_HISTORY="$new_history"
fi

rain_since_midnight_in=""
rain_last_hour_in=""
rain_last_day_in=""
if [ -n "$since_midnight_mm" ] && is_number "$since_midnight_mm"; then
  rain_since_midnight_in=$(mm_to_in "$since_midnight_mm")
fi
if [ -n "$last_hour_mm" ] && is_number "$last_hour_mm"; then
  rain_last_hour_in=$(mm_to_in "$last_hour_mm")
fi
if [ -n "$last_day_mm" ] && is_number "$last_day_mm"; then
  rain_last_day_in=$(mm_to_in "$last_day_mm")
fi

altitude_ft=""
if [ -n "$APRS_ALTITUDE_M" ] && is_number "$APRS_ALTITUDE_M"; then
  altitude_ft=$(meters_to_feet "$APRS_ALTITUDE_M")
fi

aprs_due=0
windy_due=0
if [ "$APRS_ENABLE" -eq 1 ]; then
  if [ "$FORCE_SEND" -eq 1 ]; then
    aprs_due=1
  elif [ -z "$APRS_LAST_TS" ] || [ "$now_ts" -ge $((APRS_LAST_TS + effective_interval)) ]; then
    aprs_due=1
  fi
  if [ "$DEBUG" -eq 1 ]; then
    debug "APRS last=${APRS_LAST_TS:-none} interval=${effective_interval} due=${aprs_due}"
  fi
fi

if [ "$WINDY_ENABLE" -eq 1 ]; then
  if [ -n "$WINDY_RETRY_AFTER_TS" ] && [ "$now_ts" -lt "$WINDY_RETRY_AFTER_TS" ]; then
    windy_due=0
  elif [ "$FORCE_SEND" -eq 1 ]; then
    windy_due=1
  elif [ -z "$WINDY_LAST_TS" ] || [ "$now_ts" -ge $((WINDY_LAST_TS + effective_interval)) ]; then
    windy_due=1
  fi
  if [ "$DEBUG" -eq 1 ]; then
    debug "Windy last=${WINDY_LAST_TS:-none} retry_after=${WINDY_RETRY_AFTER_TS:-none} interval=${effective_interval} due=${windy_due}"
  fi
fi

has_any() {
  local key
  for key in "$@"; do
    if [ -n "${INPUT_VALUES[$key]}" ]; then
      return 0
    fi
  done
  return 1
}

warn_missing_fields_aprs() {
  local -a missing=()
  if [ -z "$humidity" ]; then
    missing+=("humidity")
  fi
  if ! has_any windSpeedKph windSpeedMps windSpeedMph; then
    missing+=("windSpeedKph|windSpeedMps|windSpeedMph")
  fi
  if [ -z "$wind_dir_deg" ]; then
    missing+=("windDirDeg")
  fi
  if ! has_any temperatureC temperatureF; then
    missing+=("temperatureC|temperatureF")
  fi
  if [ -z "$rain_total_mm" ]; then
    missing+=("rainTotalMm")
  fi
  if [ "${#missing[@]}" -ne 0 ]; then
    warn "APRS missing fields: ${missing[*]}"
  fi
}

warn_missing_fields_windy() {
  local -a missing=()
  if [ -z "$humidity" ]; then
    missing+=("humidity")
  fi
  if ! has_any windSpeedKph windSpeedMps windSpeedMph; then
    missing+=("windSpeedKph|windSpeedMps|windSpeedMph")
  fi
  if [ -z "$wind_dir_deg" ]; then
    missing+=("windDirDeg")
  fi
  if ! has_any temperatureC temperatureF; then
    missing+=("temperatureC|temperatureF")
  fi
  if [ -z "$pressure_hpa" ]; then
    missing+=("pressureHpa")
  fi
  if [ -z "$rain_total_mm" ]; then
    missing+=("rainTotalMm")
  fi
  if [ "${#missing[@]}" -ne 0 ]; then
    warn "Windy missing fields: ${missing[*]}"
  fi
}

any_output=0

if [ "$aprs_due" -eq 1 ]; then
  if [ "$DEBUG" -eq 1 ]; then
    debug "APRS send due; preparing payload."
  fi
  warn_missing_fields_aprs

  aprs_cmd=(
    ./aprs-weather-submit
    --callsign "${APRS_CALLSIGN:-}"
    --latitude "${APRS_LATITUDE:-}"
    --longitude "${APRS_LONGITUDE:-}"
    --server "${APRS_SERVER:-rotate.aprs2.net}"
    --port "${APRS_PORT:-14580}"
    --username "${APRS_USERNAME:-}"
    --password "${APRS_PASSWORD:-}"
  )

  aprs_log=(
    ./aprs-weather-submit
    --callsign "${APRS_CALLSIGN:-}"
    --latitude "${APRS_LATITUDE:-}"
    --longitude "${APRS_LONGITUDE:-}"
    --server "${APRS_SERVER:-rotate.aprs2.net}"
    --port "${APRS_PORT:-14580}"
    --username "REDACTED"
    --password "REDACTED"
  )

  add_arg() {
    local key="$1"
    local value="$2"
    if [ -n "$value" ]; then
      aprs_cmd+=("$key" "$value")
      aprs_log+=("$key" "$value")
    fi
  }

  add_arg --altitude "$altitude_ft"
  add_arg --wind-direction "$wind_dir_deg"
  add_arg --wind-speed "$wind_speed_mph"
  add_arg --gust "$wind_gust_mph"
  add_arg --humidity "$humidity"
  if [ -n "$temperature_c" ]; then
    add_arg --temperature-celsius "$temperature_c"
  elif [ -n "$temperature_f" ]; then
    add_arg --temperature "$temperature_f"
  fi
  add_arg --rainfall-last-hour "$rain_last_hour_in"
  add_arg --rainfall-last-24-hours "$rain_last_day_in"
  add_arg --rainfall-since-midnight "$rain_since_midnight_in"
  add_arg --luminosity "$luminosity_wm2"

  if [ "$DEBUG" -eq 1 ]; then
    printf '[%s]: sending data to aprs: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${aprs_log[*]}"
  fi
  if [ "$APRS_DRY_RUN" -eq 1 ]; then
    printf '[%s]: aprs dry-run: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${aprs_log[*]}"
    any_output=1
  else
    if "${aprs_cmd[@]}"; then
      any_output=1
    else
      warn "APRS send failed."
    fi
  fi

  APRS_LAST_TS="$now_ts"
fi

if [ "$windy_due" -eq 1 ]; then
  if [ "$DEBUG" -eq 1 ]; then
    debug "Windy send due; preparing payload."
  fi
  warn_missing_fields_windy

  observation_time=$(rfc3339_local)
  query_args=()
  query_log=()

  add_query() {
    local key="$1"
    local value="$2"
    local log_value="$value"
    if [ "$key" = "PASSWORD" ]; then
      log_value="REDACTED"
    fi
    if [ -n "$value" ]; then
      query_args+=("--data-urlencode" "${key}=${value}")
      query_log+=("${key}=${log_value}")
    fi
  }

  add_query "id" "${WINDY_STATION_ID:-}"
  add_query "PASSWORD" "${WINDY_PASSWORD:-}"
  add_query "time" "$observation_time"
  add_query "wind" "$wind_speed_ms"
  add_query "gust" "$wind_gust_ms"
  add_query "winddir" "$wind_dir_deg"
  add_query "humidity" "$humidity"
  add_query "temp" "$temperature_c"
  add_query "dewpoint" "$dewpoint_c"
  add_query "pressure" "$pressure_hpa"
  add_query "precip" "$last_hour_mm"
  add_query "uv" "$uv_index"
  add_query "solarradiation" "$luminosity_wm2"

  if [ "$DEBUG" -eq 1 ]; then
    printf '[%s]: sending data to windy: %s params: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$WINDY_URL" "${query_log[*]}"
  fi
  if [ "$WINDY_DRY_RUN" -eq 1 ]; then
    printf '[%s]: windy dry-run: %s params: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$WINDY_URL" "${query_log[*]}"
    any_output=1
  else
    if ! response=$(curl -sS -G "$WINDY_URL" "${query_args[@]}" -H "Accept: application/json" -w "\n%{http_code}"); then
      warn "Windy upload failed (curl error)."
    else
      http_code=$(echo "$response" | tail -n 1)
      body=$(echo "$response" | sed '$d')

      if [ "$http_code" -eq 429 ]; then
        retry_after=$(echo "$body" | jq -r '.retry_after // empty' 2>/dev/null)
        if [ -n "$retry_after" ]; then
          retry_after_ts=$(date -d "$retry_after" +%s 2>/dev/null)
          if [ -n "$retry_after_ts" ]; then
            WINDY_RETRY_AFTER_TS="$retry_after_ts"
          fi
        fi
        warn "Windy rate limit exceeded (HTTP 429)."
      elif [ "$http_code" -ne 200 ]; then
        warn "Windy upload failed (HTTP ${http_code}): ${body}"
      else
        any_output=1
      fi
    fi
  fi

  WINDY_LAST_TS="$now_ts"
fi

# Update cache
{
  printf 'RAIN_TOTAL_MM_LAST=%s\n' "${RAIN_TOTAL_MM_LAST:-}"
  printf 'MIDNIGHT_DATE=%s\n' "${MIDNIGHT_DATE:-}"
  printf 'MIDNIGHT_TOTAL=%s\n' "${MIDNIGHT_TOTAL:-}"
  printf 'RAIN_HISTORY=%q\n' "${RAIN_HISTORY:-}"
  printf 'APRS_LAST_TS=%s\n' "${APRS_LAST_TS:-}"
  printf 'WINDY_LAST_TS=%s\n' "${WINDY_LAST_TS:-}"
  printf 'WINDY_RETRY_AFTER_TS=%s\n' "${WINDY_RETRY_AFTER_TS:-}"
} > "$PWS_CACHE_FILE"

if [ "$any_output" -eq 0 ]; then
  exit 2
fi

exit 0
