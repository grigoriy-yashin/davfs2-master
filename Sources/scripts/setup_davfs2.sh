#!/usr/bin/env bash
set -Eeuo pipefail

# Flags & vars
BASE_URL=""
MAPS=()          # localuser:ncuser:/mnt/path
SECRETS=()       # ncuser:ENVVAR
AUTO=false       # systemd on-demand automount
PERSIST=false    # mount at boot (systemd mounts it)
NOLOCKS=false
INSECURE=false
SYSTEM_SECRETS=false  # also place creds in /etc/davfs2/secrets for boot mounts

usage() {
  cat <<'HLP'
Usage:
  sudo ./setup_davfs2.sh \
    --base-url https://cloud.example/remote.php/dav/files \
    --map localuser:ncuser:/mnt/webdav/user \
    [--map ...] \
    [--secret ncuser:ENVVAR] \
    [--auto | --persist] [--no-locks] [--insecure] [--system-secrets]

Notes:
  --auto       On-demand systemd automount (recommended for desktops).
  --persist    Mount at boot (systemd/root mounts it). Mutually exclusive with --auto.
  --system-secrets  Also write creds to /etc/davfs2/secrets (needed for --persist).
HLP
}

# --- helpers (same as before, trimmed for brevity) ---
req_root() { [ "$(id -u)" -eq 0 ] || { echo "Run as root."; exit 1; }; }
install_davfs2() {
  command -v mount.davfs >/dev/null && { echo "[ok] davfs2 present"; return; }
  echo "[i] installing davfs2…"
  if command -v apt-get >/dev/null; then apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y davfs2
  elif command -v dnf >/dev/null; then dnf install -y davfs2
  elif command -v yum >/dev/null; then yum install -y davfs2
  elif command -v apk >/dev/null; then apk add --no-cache davfs2
  elif command -v pacman >/dev/null; then pacman -Sy --noconfirm davfs2
  else echo "[!] no package manager found"; exit 1; fi
}
contains_line(){ [ -f "$1" ] && grep -Fqx -- "$2" "$1"; }
append_unique_line(){ local f="$1" l="$2"; touch "$f"; chmod 644 "$f"; contains_line "$f" "$l" || printf '%s\n' "$l" >>"$f"; }
ensure_group_membership(){ local u="$1"; getent group davfs2 >/dev/null || groupadd davfs2; id -nG "$u" | tr ' ' '\n' | grep -Fxq davfs2 || { usermod -aG davfs2 "$u"; echo "[i] added $u to davfs2"; }; }
user_home(){ getent passwd "$1" | cut -d: -f6; }

# --- parse args ---
while [ $# -gt 0 ]; do
  case "${1:-}" in
    --base-url) BASE_URL="${2:-}"; shift 2 ;;
    --map)      MAPS+=("${2:-}"); shift 2 ;;
    --secret)   SECRETS+=("${2:-}"); shift 2 ;;
    --auto)     AUTO=true; shift ;;
    --persist)  PERSIST=true; shift ;;
    --no-locks) NOLOCKS=true; shift ;;
    --insecure) INSECURE=true; shift ;;
    --system-secrets) SYSTEM_SECRETS=true; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

# --- validate ---
req_root
[ -n "$BASE_URL" ] || { echo "[!] --base-url required"; exit 1; }
[ "${#MAPS[@]}" -gt 0 ] || { echo "[!] at least one --map"; exit 1; }
$AUTO && $PERSIST && { echo "[!] --auto and --persist are mutually exclusive"; exit 1; }
install_davfs2

declare -A PASS_ENV_BY_NCUSER
for s in "${SECRETS[@]:-}"; do
  IFS=: read -r sec_ncuser sec_env <<<"$s" || true
  [ -n "${sec_ncuser:-}" ] && [ -n "${sec_env:-}" ] || { echo "[!] bad --secret $s"; exit 1; }
  PASS_ENV_BY_NCUSER["$sec_ncuser"]="$sec_env"
done

mkdir -p /etc/davfs2
touch /etc/davfs2/secrets
chmod 600 /etc/davfs2/secrets

# --- per map ---
for m in "${MAPS[@]}"; do
  IFS=: read -r LUSER NCUSER MNT <<<"$m" || true
  [ -n "${LUSER:-}" ] && [ -n "${NCUSER:-}" ] && [ -n "${MNT:-}" ] || { echo "[!] bad --map $m"; exit 1; }
  id "$LUSER" >/dev/null 2>&1 || { echo "[!] local user $LUSER missing"; exit 1; }

  USER_URL="${BASE_URL%/}/${NCUSER}/"

  PW=""
  if [[ -n "${PASS_ENV_BY_NCUSER[$NCUSER]:-}" ]]; then
    envn="${PASS_ENV_BY_NCUSER[$NCUSER]}"
    PW="${!envn:-}"
    [ -n "$PW" ] || { echo "[!] ENV $envn is empty for $NCUSER"; exit 1; }
  else
    read -rsp "Password for Nextcloud user '$NCUSER': " PW; echo
    [ -n "$PW" ] || { echo "[!] empty password"; exit 1; }
  fi

  ensure_group_membership "$LUSER"
  install -d -o "$LUSER" -g "$LUSER" -m 0750 "$MNT"

  UHOME="$(user_home "$LUSER")"
  UCONF_DIR="$UHOME/.davfs2"; USEC="$UCONF_DIR/secrets"; UCF="$UCONF_DIR/davfs2.conf"
  install -d -o "$LUSER" -g "$LUSER" -m 0700 "$UCONF_DIR"
  touch "$USEC"; chown "$LUSER:$LUSER" "$USEC"; chmod 600 "$USEC"

  # per-user secret
  SECRET_LINE="${USER_URL}  ${NCUSER}  ${PW}"
  if ! su - "$LUSER" -c "grep -Fq \"${USER_URL}  ${NCUSER}  \" \"$USEC\" 2>/dev/null"; then
    echo "$SECRET_LINE" >> "$USEC"
  else
    su - "$LUSER" -c "awk -v url=\"${USER_URL}\" -v u=\"${NCUSER}\" 'BEGIN{OFS=FS=\"  \"} {if(\$1==url && \$2==u){next} print}' \"$USEC\" > \"$USEC.tmp\" && mv \"$USEC.tmp\" \"$USEC\""
    echo "$SECRET_LINE" >> "$USEC"
  fi

  # system secrets (for boot mounting)
  if $SYSTEM_SECRETS; then
    # replace any existing line for this URL/user
    if grep -Fq "${USER_URL}  ${NCUSER}  " /etc/davfs2/secrets 2>/dev/null; then
      awk -v url="${USER_URL}" -v u="${NCUSER}" 'BEGIN{OFS=FS="  "} {if($1==url && $2==u){next} print}' /etc/davfs2/secrets > /etc/davfs2/secrets.tmp && mv /etc/davfs2/secrets.tmp /etc/davfs2/secrets
    fi
    echo "$SECRET_LINE" >> /etc/davfs2/secrets
    chmod 600 /etc/davfs2/secrets
  fi

  # per-user davfs2.conf tweaks
  if $NOLOCKS || $INSECURE; then
    touch "$UCF"; chown "$LUSER:$LUSER" "$UCF"; chmod 600 "$UCF"
    $NOLOCKS && append_unique_line "$UCF" "use_locks 0"
    $INSECURE && append_unique_line "$UCF" "trust_server_cert 1"
  fi

  UIDNUM="$(id -u "$LUSER")"; GIDNUM="$(id -g "$LUSER")"

  # fstab options — note: 'users' so any user can mount/umount; root can always do it.
  if $AUTO; then
    FOPTS="rw,users,uid=${UIDNUM},gid=${GIDNUM},dir_mode=0750,file_mode=0640,_netdev,x-systemd.automount,x-systemd.idle-timeout=600,defaults,nofail"
  elif $PERSIST; then
    FOPTS="rw,users,uid=${UIDNUM},gid=${GIDNUM},dir_mode=0750,file_mode=0640,_netdev,defaults,nofail"
  else
    # manual mounts (no auto behavior)
    FOPTS="rw,users,uid=${UIDNUM},gid=${GIDNUM},dir_mode=0750,file_mode=0640,_netdev,noauto"
  fi

  FSTAB_LINE="${USER_URL}  ${MNT}  davfs  ${FOPTS}  0  0"

  # De-duplicate existing fstab line for this mountpoint
  TMP="$(mktemp)"
  awk -v mnt="$MNT" '($2==mnt && $3=="davfs"){next} {print}' /etc/fstab > "$TMP" && mv "$TMP" /etc/fstab
  append_unique_line /etc/fstab "$FSTAB_LINE"

  echo "[ok] Configured ${MNT} → ${USER_URL} (as ${LUSER})"
done

echo
echo "[i] Done."
echo "    Manual mount:   mount /path/to/mountpoint"
echo "    Manual umount:  umount /path/to/mountpoint"
echo "    Boot mount:     use --persist (and --system-secrets so root can mount at boot)."
echo
