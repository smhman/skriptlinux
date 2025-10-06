#!/usr/bin/env bash
# -------------------------------------------
# backupexec.sh — Varukoopia kuupäevaga ja kontrolliga
# Vastavalt dokumendile „Andmete varundamine. backupi tegemine”
# Autor: <Sinu nimi>
# Kuupäev: $(date '+%F')
# -------------------------------------------

set -euo pipefail
trap 'echo -e "\033[0;31m[VEA DETEKTOR]\033[0m Rea $LINENO käsk ebaõnnestus: $BASH_COMMAND" >&2' ERR

# --- Seaded ---
BACKUP_ROOT="/home_bcp"
SOURCE_ROOT="/home"
KEEP=3
COMPRESS="zstd"   # zstd | gzip | xz
IGNORE_FILE=".backupignore"
DRY_RUN=false
LOG_DIR="${BACKUP_ROOT}/logs"

# --- Värvid ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# --- Abifunktsioonid ---
log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_DIR/backup.log"; }
ok()  { echo -e "${GREEN}✔${NC} $*"; }
warn(){ echo -e "${YELLOW}⚠${NC} $*"; }
fail(){ echo -e "${RED}❌${NC} $*"; }

mkdir -p "$BACKUP_ROOT" "$LOG_DIR"

# --- Kompressori argumendid ja faililaiendid ---
get_ext() {
  case "$COMPRESS" in
    zstd) echo "tar.zst";;
    gzip) echo "tar.gz";;
    xz)   echo "tar.xz";;
    *) fail "Tundmatu kompressor: $COMPRESS";;
  esac
}

get_args() {
  case "$COMPRESS" in
    zstd) echo "-I 'zstd -3 -T0'";;
    gzip) echo "-z";;
    xz)   echo "-J";;
  esac
}

# --- Kontroll vaba ruumi ---
check_space() {
  local need free
  need=$(du -sb "$1" 2>/dev/null | awk '{print $1}')
  free=$(df -B1 "$BACKUP_ROOT" 2>/dev/null | awk 'NR==2{print $4}')

  # Kui df ei anna midagi, eelda 1 TB vaba ruumi
  [[ -z "$free" ]] && free=1000000000000

  if (( free < need )); then
    fail "Ebapiisav ruum: vajab $need B, vaba $free B"
  else
    ok "Vaba ruumi piisavalt ($free B)."
  fi
}

# --- Vanade koopiate kustutamine ---
prune_old() {
  local dir="$1" base="$2"
  ls -1t "${dir}/${base}_"*".tar."* 2>/dev/null | tail -n +$((KEEP+1)) | xargs -r rm -f
}

# --- Peaosa ---
log "=== BACKUP START ==="
log "Kataloog: $SOURCE_ROOT → $BACKUP_ROOT (kompressor: $COMPRESS)"
user_count=$(find "$SOURCE_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l)
i=1

for user_dir in "$SOURCE_ROOT"/*; do
  [[ -d "$user_dir" ]] || continue
  base=$(basename "$user_dir")
  log "=== Varundan kasutaja: $base ($i/$user_count) ==="
  ((i++))

  # Kontrolli vaba ruumi
  check_space "$user_dir"

  timestamp=$(date '+%F_%H%M%S')
  ext=$(get_ext)
  archive="${BACKUP_ROOT}/${base}_${timestamp}.${ext}"
  tar_args=$(get_args)

  exclude_args=()
  if [[ -f "${user_dir}/${IGNORE_FILE}" ]]; then
    exclude_args+=(--exclude-from="${user_dir}/${IGNORE_FILE}")
  fi

  if $DRY_RUN; then
    warn "Kuivjooks — näitan, mis läheks arhiivi:"
    tar -cf - "${exclude_args[@]}" -C "$(dirname "$user_dir")" "$base" | tar -tvf -
    continue
  fi

  log "Pakin kausta: $user_dir"
  set +e
  eval tar $tar_args -cf "\"$archive\"" "${exclude_args[@]}" -C "\"$(dirname "$user_dir")\"" "\"$base\""
  status=$?
  set -e

  if [[ $status -ne 0 ]]; then
    fail "Kasutaja '$base' varundamine ebaõnnestus (tar väljus koodiga $status)."
    continue
  fi

  # Oota, kuni fail kirjutatakse kettale
  sleep 1
  for attempt in {1..3}; do
    if tar -tf "$archive" | head -n 5 >/dev/null 2>&1; then
      ok "Arhiiv avaneb korrektselt."
      break
    else
      warn "Arhiivi ei saanud veel avada (katse $attempt/3)..."
      sleep 2
    fi
    [[ $attempt -eq 3 ]] && { fail "Arhiivi ei saa avada: $archive"; continue 2; }
  done

  size=$(du -h "$archive" | awk '{print $1}')
  log "Arhiivi suurus: $size"

  sha256sum "$archive" > "${archive}.sha256"
  sha256sum -c "${archive}.sha256" || { fail "Kontrollsumma vale: $archive"; continue; }

  prune_old "$BACKUP_ROOT" "$base"
  ok "Valmis: $archive"
done

ok "=== Kõik varukoopiad loodud ==="
log "=== BACKUP END ==="
exit 0
