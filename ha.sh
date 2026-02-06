#!/bin/bash
# cd to the script's directory, so the .env file is found where the script is
cd "$(dirname "$0")"

if [ ! -f .env ]; then
  echo "Error: .env not found. Create it from .env.sample and bind-mount it in Docker if you use Docker." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
. ./.env
set +a

INTERVAL_SECONDS="${INTERVAL_SECONDS:-30}"
if ! [[ "$INTERVAL_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "Error: INTERVAL_SECONDS must be a non-negative integer." >&2
  exit 1
fi

required_vars=(HA_API_TOKEN HA_SENSOR_MATCH HA_SENSOR_PREFIX HA_SENSOR_MAP APRS_CALLSIGN APRS_LATITUDE APRS_LONGITUDE APRS_USERNAME APRS_PASSWORD)
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

CACHE_FILE=".cache"
LUX_EFFICACY="${LUX_EFFICACY:-110}"

run_once() {
  json_output=$(curl -sS -X GET \
    -H "Authorization: Bearer $HA_API_TOKEN" \
    -H "Content-Type: application/json" \
    "${HA_HOST:-http://homeassistant.local:8123}"/api/states 2>/dev/null)

  # Capture the jq output into shell variables (avoid jq features that may be missing in older versions).
  sensor_lines=$(echo "$json_output" | jq -r \
    --arg match "$HA_SENSOR_MATCH" \
    --arg prefix "$HA_SENSOR_PREFIX" \
    '
    .[]
    | select(.entity_id | index($match))
    | "\((.entity_id | sub($prefix; "")))=\(.state | tostring)"
  ')

  declare -A sensor_values=()
  while IFS='=' read -r key value; do
    if [ -n "$key" ]; then
      sensor_values["$key"]="$value"
    fi
  done <<< "$sensor_lines"

  for pair in $HA_SENSOR_MAP; do
    var_name=${pair%%:*}
    ha_key=${pair#*:}
    value="${sensor_values[$ha_key]}"
    printf -v "$var_name" '%s' "$value"
  done

  if [ -f "$CACHE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CACHE_FILE"
  fi

  now_ts=$(date +%s)
  today=$(date +%F)

  if [ -n "$RAIN_TOTAL_MM_LAST" ] && [ -n "$rain_total" ] && awk "BEGIN{exit !($rain_total < $RAIN_TOTAL_MM_LAST)}"; then
    RAIN_HISTORY=""
    MIDNIGHT_DATE="$today"
    MIDNIGHT_TOTAL="$rain_total"
  fi

  if [ -z "$MIDNIGHT_DATE" ] || [ "$MIDNIGHT_DATE" != "$today" ] || [ -z "$MIDNIGHT_TOTAL" ]; then
    MIDNIGHT_DATE="$today"
    MIDNIGHT_TOTAL="$rain_total"
  fi

  calc_delta_mm() {
    awk -v cur="$1" -v base="$2" 'BEGIN{d=cur-base; if (d<0) d=0; printf "%.3f", d}'
  }

  mm_to_in() {
    awk -v mm="$1" 'BEGIN{printf "%.3f", mm/25.4}'
  }

  c_to_f() {
    awk -v c="$1" 'BEGIN{if (c=="") {print ""} else {printf "%.1f", (c*9/5)+32}}'
  }

  kmh_to_mph() {
    awk -v kmh="$1" 'BEGIN{printf "%.2f", kmh*0.621371}'
  }

  meters_to_feet() {
    awk -v m="$1" 'BEGIN{printf "%.0f", m*3.28084}'
  }

  lux_to_wm2() {
    awk -v lux="$1" -v eff="$LUX_EFFICACY" 'BEGIN{if (eff==0) {print ""} else {printf "%.2f", lux/eff}}'
  }

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

  new_history+="$now_ts:$rain_total"
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

  since_midnight_mm=$(calc_delta_mm "$rain_total" "$MIDNIGHT_TOTAL")
  last_hour_mm=""
  last_day_mm=""

  if [ -n "$hour_total" ]; then
    last_hour_mm=$(calc_delta_mm "$rain_total" "$hour_total")
  fi

  if [ -n "$day_total" ]; then
    last_day_mm=$(calc_delta_mm "$rain_total" "$day_total")
  fi

  RAIN_TOTAL_MM_LAST="$rain_total"
  RAIN_HISTORY="$new_history"

  {
    printf 'RAIN_TOTAL_MM_LAST=%s\n' "$RAIN_TOTAL_MM_LAST"
    printf 'MIDNIGHT_DATE=%s\n' "$MIDNIGHT_DATE"
    printf 'MIDNIGHT_TOTAL=%s\n' "$MIDNIGHT_TOTAL"
    printf 'RAIN_HISTORY=%q\n' "$RAIN_HISTORY"
  } > "$CACHE_FILE"

  wind_speed_mph=""
  wind_gust_mph=""
  if [ -n "$wind_speed" ]; then
    wind_speed_mph=$(kmh_to_mph "$wind_speed")
  fi
  if [ -n "$wind_max_speed" ]; then
    wind_gust_mph=$(kmh_to_mph "$wind_max_speed")
  fi

  rain_since_midnight_in=""
  rain_last_hour_in=""
  rain_last_day_in=""
  if [ -n "$since_midnight_mm" ]; then
    rain_since_midnight_in=$(mm_to_in "$since_midnight_mm")
  fi
  if [ -n "$last_hour_mm" ]; then
    rain_last_hour_in=$(mm_to_in "$last_hour_mm")
  fi
  if [ -n "$last_day_mm" ]; then
    rain_last_day_in=$(mm_to_in "$last_day_mm")
  fi

  luminosity_wm2=""
  if [ -n "$outside_luminance" ]; then
    luminosity_wm2=$(lux_to_wm2 "$outside_luminance")
  fi

  temperature_f=""
  if [ -n "$temperature" ]; then
    temperature_f=$(c_to_f "$temperature")
  fi

  altitude_ft=""
  if [ -n "$APRS_ALTITUDE" ]; then
    altitude_ft=$(meters_to_feet "$APRS_ALTITUDE")
  fi

  add_arg() {
    local key="$1"
    local value="$2"
    if [ -n "$value" ]; then
      aprs_cmd+=("$key" "$value")
    fi
  }

  # Prepare the aprs-weather-submit command with values from jq variables.
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

  add_arg --altitude "$altitude_ft"
  add_arg --wind-direction "${wind_direction:-}"
  add_arg --wind-speed "$wind_speed_mph"
  add_arg --gust "$wind_gust_mph"
  add_arg --humidity "${humidity:-}"
  add_arg --temperature-celsius "${temperature:-}"
  add_arg --rainfall-last-hour "$rain_last_hour_in"
  add_arg --rainfall-last-24-hours "$rain_last_day_in"
  add_arg --rainfall-since-midnight "$rain_since_midnight_in"
  add_arg --luminosity "$luminosity_wm2"

  printf '[%s]: temp=%sC/%sF humidity=%s%% wind=%skmh/%smph gust=%skmh/%smph dir=%s rain_1h=%smm/%sin rain_24h=%smm/%sin rain_midnight=%smm/%sin luminosity=%slux/%sWm2\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    "${temperature:-}" \
    "${temperature_f:-}" \
    "${humidity:-}" \
    "${wind_speed:-}" \
    "${wind_speed_mph:-}" \
    "${wind_max_speed:-}" \
    "${wind_gust_mph:-}" \
    "${wind_direction:-}" \
    "${last_hour_mm:-}" \
    "${rain_last_hour_in:-}" \
    "${last_day_mm:-}" \
    "${rain_last_day_in:-}" \
    "${since_midnight_mm:-}" \
    "${rain_since_midnight_in:-}" \
    "${outside_luminance:-}" \
    "${luminosity_wm2:-}"

  "${aprs_cmd[@]}"
}

while true; do
  run_once
  if [ "$INTERVAL_SECONDS" -eq 0 ] 2>/dev/null; then
    exit 0
  fi
  sleep "$INTERVAL_SECONDS"
done


# the jq command will output these lines:
# battery: 100
# temperature: 7.2
# humidity: 97.0
# wind_speed: 1.9
# wind_max_speed: 3.33333
# wind_direction: 168.0
# rain_total: 36.81
# uv_index: 0.0
# outside_luminance: 0
