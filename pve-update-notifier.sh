#!/usr/bin/env bash
# ------------------------------------------------------------------
#  PVE Update Notifier — Proxmox helper script
#  Checkt dagelijks openstaande (security-)updates op de PVE-host en
#  in alle LXC's, en meldt ze aan Home Assistant via MQTT.
#
#  Gebruik (op de Proxmox-host, als root):
#    bash -c "$(curl -fsSL https://raw.githubusercontent.com/<org>/<repo>/main/pve-update-notifier.sh)"
# ------------------------------------------------------------------
set -euo pipefail

APP="PVE Update Notifier"
BIN=/usr/local/sbin/pve-update-check.sh
ENV_FILE=/etc/pve-update-check.env
SVC=/etc/systemd/system/pve-update-check.service
TMR=/etc/systemd/system/pve-update-check.timer

YW=$'\033[33m'; GN=$'\033[1;92m'; RD=$'\033[01;31m'; BL=$'\033[36m'; CL=$'\033[m'
msg_info()  { echo -e " ${YW}…${CL} $1"; }
msg_ok()    { echo -e " ${GN}✔${CL} $1"; }
msg_error() { echo -e " ${RD}✖${CL} $1"; }
die()       { msg_error "$1"; exit 1; }

header() {
  clear
  printf '%s' "$BL"
  cat <<'EOF'
   ___ _   _____   _   _          _      _         _  _     _   _  __ _
  | _ \ \ / / __| | | | |_ __  __| |__ _| |_ ___  | \| |___| |_(_)/ _(_)___ _ _
  |  _/\ V /| _|  | |_| | '_ \/ _` / _` |  _/ -_) | .` / _ \  _| |  _| / -_) '_|
  |_|   \_/ |___|  \___/| .__/\__,_\__,_|\__\___| |_|\_\___/\__|_|_| |_\___|_|
                        |_|
EOF
  printf '%s\n' "$CL"
}

# ---------- checks ----------
[ "$(id -u)" -eq 0 ] || die "Draai dit script als root."
command -v pveversion >/dev/null 2>&1 || die "Dit is geen Proxmox VE-host."
command -v whiptail  >/dev/null 2>&1 || apt-get install -y whiptail >/dev/null

# ---------- het check-script zelf ----------
write_check_script() {
cat > "$BIN" <<'__CHECK_EOF__'
#!/usr/bin/env bash
# pve-update-check.sh
# Checkt openstaande pakket-updates op de Proxmox-host en in alle draaiende LXC's,
# publiceert per container een sensor naar Home Assistant (MQTT discovery) en
# stuurt een samenvatting naar pve-updates/<node>/report (HA-automation -> Telegram).
#
# Vereist op de host:  apt install jq mosquitto-clients
# Config:              /etc/pve-update-check.env  (MQTT_HOST, MQTT_PORT, MQTT_USER, MQTT_PASS)
# Nieuwe containers worden automatisch opgepikt; verwijderde worden uit HA opgeruimd.
# Er wordt NIETS geüpdatet, alleen gecheckt (apt-get update + apt list --upgradable).

set -uo pipefail

ENV_FILE=/etc/pve-update-check.env
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
: "${MQTT_HOST:?MQTT_HOST ontbreekt in $ENV_FILE}"
MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_USER="${MQTT_USER:-}"
MQTT_PASS="${MQTT_PASS:-}"
TIMEOUT="${CHECK_TIMEOUT:-300}"      # max seconden per container
NODE="$(hostname -s)"
BASE="pve-updates/${NODE}"
DISC="homeassistant"
STATE_DIR="${STATE_DIR:-/var/lib/pve-update-check}"
KNOWN="${STATE_DIR}/known"
mkdir -p "$STATE_DIR"

pub() { # pub <topic> <payload> [retain]
  local a=(-h "$MQTT_HOST" -p "$MQTT_PORT" -t "$1" -q 1)
  if [ -n "$2" ]; then a+=(-m "$2"); else a+=(-n); fi   # -n = leeg bericht (wist retained topic)
  [ -n "$MQTT_USER" ] && a+=(-u "$MQTT_USER" -P "$MQTT_PASS")
  [ "${3:-}" = retain ] && a+=(-r)
  mosquitto_pub "${a[@]}" || echo "WARN: mqtt publish naar $1 mislukt" >&2
}

# Draait binnen de container (of op de host). Output: "PKG <naam> <1=security|0>" of "ERR <tekst>".
read -r -d '' CHECK <<'EOF'
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1 || echo "ERR apt-get update mislukt"
  apt list --upgradable 2>/dev/null | awk -F'[/ ]' '/upgradable/ {print "PKG", $1, ($2 ~ /security/) ? 1 : 0}'
elif command -v apk >/dev/null 2>&1; then
  apk update -q >/dev/null 2>&1 || echo "ERR apk update mislukt"
  apk list -u 2>/dev/null | awk '{print "PKG", $1, 0}'
else
  echo "ERR onbekende package manager"
fi
echo "DONE"
EOF

discovery() { # discovery <key> <device-name>
  local key="$1" dev="$2" uid="pveupd_${NODE}_${1}"
  local device; device=$(jq -nc --arg id "$uid" --arg n "$dev" --arg node "$NODE" \
    '{identifiers:[$id], name:$n, manufacturer:"Proxmox", model:("LXC op " + $node)}')
  pub "${DISC}/sensor/${uid}/updates/config" "$(jq -nc --arg u "${uid}_updates" --arg t "${BASE}/${key}/state" --argjson d "$device" \
    '{name:"Updates", unique_id:$u, state_topic:$t, value_template:"{{ value_json.updates }}",
      json_attributes_topic:$t, unit_of_measurement:"updates", state_class:"measurement",
      icon:"mdi:package-up", device:$d}')" retain
  pub "${DISC}/sensor/${uid}/security/config" "$(jq -nc --arg u "${uid}_security" --arg t "${BASE}/${key}/state" --argjson d "$device" \
    '{name:"Security-updates", unique_id:$u, state_topic:$t, value_template:"{{ value_json.security }}",
      unit_of_measurement:"updates", state_class:"measurement", icon:"mdi:shield-alert", device:$d}')" retain
}

forget() { # forget <key> : haalt sensoren van een verdwenen container weg uit HA
  local uid="pveupd_${NODE}_${1}"
  pub "${DISC}/sensor/${uid}/updates/config" "" retain
  pub "${DISC}/sensor/${uid}/security/config" "" retain
  pub "${BASE}/${1}/state" "" retain
}

if [ "${1:-}" = "--purge" ]; then   # gebruikt door de uninstaller
  [ -f "$KNOWN" ] && while read -r k; do [ -n "$k" ] && forget "$k"; done < "$KNOWN"
  rm -f "$KNOWN"; echo "Alle sensoren van ${NODE} verwijderd uit Home Assistant."; exit 0
fi

now=$(date -Iseconds)
current=(host)
lines=(); total=0; sec_total=0; with_updates=0; checked=0; skipped=()

check_one() { # check_one <key> <naam> <cmd...>
  local key="$1" name="$2"; shift 2
  local out upd sec pkgs err
  out=$(timeout "$TIMEOUT" "$@" sh -c "$CHECK" 2>/dev/null) || true
  upd=$(grep -c '^PKG ' <<<"$out" || true)
  sec=$(grep -c '^PKG .* 1$' <<<"$out" || true)
  err=$(grep '^ERR ' <<<"$out" | cut -c5- | paste -sd';' -)
  grep -q '^DONE' <<<"$out" || err="${err:-check niet afgerond (timeout of pct-fout)}"
  pkgs=$(grep '^PKG ' <<<"$out" | awk '{print $2 ($3==1?" [S]":"")}' | head -n 50 | jq -Rsc 'split("\n")|map(select(length>0))')

  discovery "$key" "$name"
  pub "${BASE}/${key}/state" "$(jq -nc --argjson u "$upd" --argjson s "$sec" --argjson p "$pkgs" \
     --arg e "$err" --arg c "$now" '{updates:$u, security:$s, packages:$p, error:$e, checked_at:$c}')" retain

  checked=$((checked+1)); total=$((total+upd)); sec_total=$((sec_total+sec))
  if [ -n "$err" ]; then
    lines+=("⚠️ ${name}: ${err}")
  elif [ "$upd" -gt 0 ]; then
    with_updates=$((with_updates+1))
    if [ "$sec" -gt 0 ]; then lines+=("🔴 ${name}: ${upd} updates, waarvan ${sec} security")
    else lines+=("🟡 ${name}: ${upd} updates"); fi
  fi
}

# 1) de host zelf
check_one "host" "PVE-host ${NODE}" env

# 2) alle LXC's
while read -r vmid status _ name; do
  [ -z "$vmid" ] && continue
  current+=("$vmid")
  if [ "$status" != "running" ]; then skipped+=("${name:-$vmid} (${vmid})"); continue; fi
  check_one "$vmid" "${name:-lxc-$vmid} (${vmid})" pct exec "$vmid" --
done < <(pct list | awk 'NR>1 {print $1, $2, $3, $NF}')

# 3) opruimen: containers die sinds de vorige run verwijderd zijn
if [ -f "$KNOWN" ]; then
  while read -r k; do
    [ -z "$k" ] && continue
    printf '%s\n' "${current[@]}" | grep -qx "$k" || { forget "$k"; lines+=("🗑 container ${k} bestaat niet meer, sensoren verwijderd"); }
  done < "$KNOWN"
fi
printf '%s\n' "${current[@]}" > "$KNOWN"

# 4) samenvatting
if [ "$sec_total" -gt 0 ]; then head="🔴"; elif [ "$total" -gt 0 ]; then head="🟡"; else head="✅"; fi
summary="${head} <b>${NODE}</b>: ${with_updates} van ${checked} systemen hebben updates (${total} pakketten, ${sec_total} security)"
for l in "${lines[@]}"; do summary+=$'\n'"$l"; done
[ "${#skipped[@]}" -gt 0 ] && summary+=$'\n'"⏸ niet gecheckt (gestopt): $(IFS=,; echo "${skipped[*]}")"

pub "${BASE}/report" "$(jq -nc --arg n "$NODE" --arg c "$now" --arg s "$summary" \
  --argjson t "$total" --argjson sec "$sec_total" --argjson w "$with_updates" --argjson k "$checked" \
  '{node:$n, checked_at:$c, total:$t, security:$sec, systems_with_updates:$w, checked:$k, summary:$s}')"

echo "$summary"
__CHECK_EOF__
chmod 0755 "$BIN"
}

# ---------- configuratie ----------
configure() {
  # bestaande waarden als default
  MQTT_HOST=""; MQTT_PORT="1883"; MQTT_USER=""; MQTT_PASS=""; SCHEDULE="18:00"
  # shellcheck disable=SC1090
  [ -f "$ENV_FILE" ] && . "$ENV_FILE"

  MQTT_HOST=$(whiptail --title "$APP" --inputbox "MQTT broker (IP of hostname van Home Assistant / Mosquitto):" 10 70 "$MQTT_HOST" 3>&1 1>&2 2>&3) || exit 1
  [ -n "$MQTT_HOST" ] || die "MQTT host is verplicht."
  MQTT_PORT=$(whiptail --title "$APP" --inputbox "MQTT poort:" 10 70 "$MQTT_PORT" 3>&1 1>&2 2>&3) || exit 1
  MQTT_USER=$(whiptail --title "$APP" --inputbox "MQTT gebruikersnaam (leeg = geen auth):" 10 70 "$MQTT_USER" 3>&1 1>&2 2>&3) || exit 1
  if [ -n "$MQTT_USER" ]; then
    local p
    p=$(whiptail --title "$APP" --passwordbox "MQTT wachtwoord${MQTT_PASS:+ (leeg = huidige behouden)}:" 10 70 3>&1 1>&2 2>&3) || exit 1
    [ -n "$p" ] && MQTT_PASS="$p"
  else
    MQTT_PASS=""
  fi
  SCHEDULE=$(whiptail --title "$APP" --inputbox "Hoe laat dagelijks checken? (HH:MM)" 10 70 "$SCHEDULE" 3>&1 1>&2 2>&3) || exit 1
  [[ "$SCHEDULE" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "Ongeldige tijd: $SCHEDULE"

  umask 077
  cat > "$ENV_FILE" <<EOF
MQTT_HOST="$MQTT_HOST"
MQTT_PORT="$MQTT_PORT"
MQTT_USER="$MQTT_USER"
MQTT_PASS="$MQTT_PASS"
SCHEDULE="$SCHEDULE"
EOF
  umask 022
  msg_ok "Configuratie opgeslagen in $ENV_FILE"

  msg_info "MQTT-verbinding testen"
  local a=(-h "$MQTT_HOST" -p "$MQTT_PORT" -t "pve-updates/$(hostname -s)/hello" -m "$(date -Iseconds)")
  [ -n "$MQTT_USER" ] && a+=(-u "$MQTT_USER" -P "$MQTT_PASS")
  if mosquitto_pub "${a[@]}" 2>/tmp/pve-upd-mqtt.err; then msg_ok "MQTT-verbinding werkt"
  else msg_error "MQTT-test mislukt: $(cat /tmp/pve-upd-mqtt.err)"; fi
}

write_units() {
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  cat > "$SVC" <<EOF
[Unit]
Description=$APP - check openstaande updates in PVE-host en LXC's
After=network-online.target pve-guests.service

[Service]
Type=oneshot
ExecStart=$BIN
Nice=10
IOSchedulingClass=idle
EOF
  cat > "$TMR" <<EOF
[Unit]
Description=$APP - dagelijkse check

[Timer]
OnCalendar=*-*-* ${SCHEDULE}:00
RandomizedDelaySec=15m
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now pve-update-check.timer >/dev/null 2>&1
  msg_ok "Timer actief: dagelijks rond ${SCHEDULE}"
}

install() {
  header
  msg_info "Afhankelijkheden installeren (jq, mosquitto-clients)"
  apt-get update -qq >/dev/null && apt-get install -y -qq jq mosquitto-clients >/dev/null
  msg_ok "Afhankelijkheden geïnstalleerd"
  configure
  write_check_script; msg_ok "Script geplaatst in $BIN"
  write_units
  if whiptail --title "$APP" --yesno "Nu direct een eerste check draaien?\n(Duurt even: apt-get update in elke container.)" 10 70; then
    run_now
  fi
  echo; msg_ok "${GN}$APP is geïnstalleerd.${CL}"
  echo -e "   In Home Assistant verschijnt per container een device met 'Updates' en 'Security-updates'."
  echo -e "   Meldingen lopen via MQTT-topic ${BL}pve-updates/<node>/report${CL}."
}

run_now() {
  msg_info "Check draait…"
  "$BIN" || true
  msg_ok "Check klaar"
}

uninstall() {
  if whiptail --title "$APP" --yesno "Ook alle sensoren van deze host uit Home Assistant verwijderen?" 10 70; then
    [ -x "$BIN" ] && "$BIN" --purge || true
  fi
  systemctl disable --now pve-update-check.timer >/dev/null 2>&1 || true
  rm -f "$SVC" "$TMR" "$BIN" "$ENV_FILE"
  rm -rf /var/lib/pve-update-check
  systemctl daemon-reload
  msg_ok "$APP verwijderd (jq en mosquitto-clients zijn blijven staan)."
}

# ---------- menu ----------
if [ -x "$BIN" ] && [ -f "$ENV_FILE" ]; then
  header
  CHOICE=$(whiptail --title "$APP" --menu "$APP is al geïnstalleerd. Wat wil je doen?" 16 70 5 \
    "1" "Script updaten naar deze versie" \
    "2" "Configuratie wijzigen (MQTT / tijdstip)" \
    "3" "Nu een check draaien" \
    "4" "Status van de timer tonen" \
    "5" "Verwijderen" 3>&1 1>&2 2>&3) || exit 0
  case "$CHOICE" in
    1) write_check_script; msg_ok "Script bijgewerkt" ;;
    2) configure; write_units ;;
    3) run_now ;;
    4) systemctl list-timers pve-update-check.timer --no-pager; echo; journalctl -u pve-update-check.service -n 20 --no-pager ;;
    5) uninstall ;;
  esac
else
  install
fi
