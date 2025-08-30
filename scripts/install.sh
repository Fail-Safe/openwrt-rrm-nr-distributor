#!/bin/sh
#
# install.sh - helper to deploy the rrm_nr distributor onto a running OpenWrt system
#
# Usage (on your workstation):
#   scp -r openwrt-rrm-nr-distributor root@ap:/tmp/rrm_nr_src
#   ssh root@ap 'sh /tmp/rrm_nr_src/scripts/install.sh'
#
# Or copy just this script & required files, then run it on the target device.
#
# Idempotent: safe to re-run; will not overwrite existing /etc/config/rrm_nr unless --force-config given.
#
# License: GPL-2.0 (see top-level LICENSE)
#
# Environment variables (advanced / test):
#   RRM_NR_TEST_MODE=1  - enable wireless config validation inside --prefix root (not just live /etc)

set -eu

PREFIX=""
FORCE_CONFIG=0
START_SERVICE=1
ADD_SYSUPGRADE=0
DEPS_MODE="prompt"       # prompt | yes | no
INSTALL_OPTIONAL=0        # install optional deps automatically
FIX_WIRELESS=0            # auto-add missing ieee80211k/bss_transition

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)
      PREFIX=$2; shift 2 ;;
    --force-config)
      FORCE_CONFIG=1; shift ;;
    --no-start)
      START_SERVICE=0; shift ;;
    --add-sysupgrade)
      ADD_SYSUPGRADE=1; shift ;;
    --deps-auto-yes)
      DEPS_MODE="yes"; shift ;;
    --deps-auto-no)
      DEPS_MODE="no"; shift ;;
    --install-optional)
      INSTALL_OPTIONAL=1; shift ;;
    --fix-wireless)
      FIX_WIRELESS=1; shift ;;
    -h|--help)
      cat <<EOF
Install rrm_nr distributor files.
Options:
  --prefix <dir>       Install root (default "", i.e. /). Useful for staging (e.g. image build rootfs overlay).
  --force-config       Overwrite existing /etc/config/rrm_nr with bundled default.
  --no-start           Do not enable/start the init service after install.
  --add-sysupgrade     Append file paths to /etc/sysupgrade.conf (persist across firmware upgrades).
  --deps-auto-yes      Install missing required dependencies without prompting.
  --deps-auto-no       Skip installing dependencies (just warn if missing).
  --install-optional   Also install optional enhancements (high-res sleep: coreutils-sleep/coreutils).
  --fix-wireless       Auto-add missing ieee80211k '1' / bss_transition '1' to active wifi-iface stanzas.
  -h, --help           Show this help.
Examples:
  sh scripts/install.sh
  sh scripts/install.sh --no-start --prefix /builder/root
EOF
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Resolve repo root (directory containing this script)
CDPATH="" SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd -P)
REPO_ROOT=$(dirname "$SCRIPT_DIR")

dest() { printf '%s%s' "$PREFIX" "$1"; }

copy_file() {
  src=$1 dst=$2 mode=$3
  install -d "$(dirname "$(dest "$dst")")"
  install -m "$mode" "$REPO_ROOT/$src" "$(dest "$dst")"
}

echo "[rrm_nr] Installing files (prefix='${PREFIX:-/}')"

# ---------------- Dependency Handling ----------------

detect_pkg_mgr() {
  if command -v opkg >/dev/null 2>&1; then echo opkg; return 0; fi
  if command -v apk  >/dev/null 2>&1; then echo apk;  return 0; fi
  echo none; return 0
}

pkg_mgr=$(detect_pkg_mgr)
REQ_PKGS="umdns jsonfilter iwinfo"
# ubus typically built-in (base-files / busybox), so we don't test it here.
OPT_PKG_OPKG="coreutils-sleep"   # provides higher-resolution sleep (usleep or fractional)
OPT_PKG_APK="coreutils"

have_pkg_opkg() { opkg list-installed 2>/dev/null | grep -q "^$1 -"; }
have_pkg_apk()  { apk info -e "$1" >/dev/null 2>&1; }

missing_required=""
if [ "$pkg_mgr" = opkg ]; then
  for p in $REQ_PKGS; do have_pkg_opkg "$p" || missing_required="$missing_required $p"; done
elif [ "$pkg_mgr" = apk ]; then
  for p in $REQ_PKGS; do have_pkg_apk "$p" || missing_required="$missing_required $p"; done
fi

install_required() {
  [ -z "$missing_required" ] && return 0
  echo "[rrm_nr] Installing required packages: $missing_required"
  if [ "$pkg_mgr" = opkg ]; then
    opkg update || true
    # shellcheck disable=SC2086
    opkg install $missing_required || true
  elif [ "$pkg_mgr" = apk ]; then
    apk update || true
    # shellcheck disable=SC2086
    apk add $missing_required || true
  fi
}

maybe_install_required() {
  [ -z "$missing_required" ] && return 0
  case "$DEPS_MODE" in
    yes) install_required ;;
    no)  echo "[rrm_nr] WARNING: Missing required packages (not installing due to --deps-auto-no):$missing_required" ;;
    *)
      if [ -t 0 ]; then
        printf '[rrm_nr] Missing required packages:%s\nInstall now? [Y/n] ' "$missing_required"
        read -r ans || ans=""
        case "$ans" in n|N) echo "[rrm_nr] Skipping required package install (may fail at runtime)." ;; *) install_required ;; esac
      else
        echo "[rrm_nr] Non-interactive: required packages missing:$missing_required (use --deps-auto-yes to auto-install)."
      fi
    ;;
  esac
}

maybe_install_optional() {
  [ "$INSTALL_OPTIONAL" -eq 0 ] && return 0
  opt_pkg=""
  [ "$pkg_mgr" = opkg ] && opt_pkg="$OPT_PKG_OPKG"
  [ "$pkg_mgr" = apk ] && opt_pkg="$OPT_PKG_APK"
  [ -z "$opt_pkg" ] && return 0
  have=0
  if [ "$pkg_mgr" = opkg ]; then have_pkg_opkg "$opt_pkg" && have=1; fi
  if [ "$pkg_mgr" = apk ]; then have_pkg_apk "$opt_pkg" && have=1; fi
  [ $have -eq 1 ] && return 0
  echo "[rrm_nr] Installing optional package: $opt_pkg (for high-resolution sleep)"
  if [ "$pkg_mgr" = opkg ]; then
    opkg update || true
    opkg install "$opt_pkg" || true
  elif [ "$pkg_mgr" = apk ]; then
    apk update || true
    apk add "$opt_pkg" || true
  fi
}

if [ "$pkg_mgr" = none ]; then
  echo "[rrm_nr] NOTE: No supported package manager (opkg/apk) detected; ensure dependencies exist: $REQ_PKGS" >&2
else
  [ -n "$missing_required" ] && echo "[rrm_nr] Detected package manager: $pkg_mgr" || true
  maybe_install_required
  maybe_install_optional
fi

# -------------- End Dependency Handling -------------

# ---------------- Wireless 802.11k/v Sanity Check ----------------

check_wireless_rrm() {
  # If prefix set we normally skip, unless in explicit test mode
  if [ -n "$PREFIX" ] && [ "${RRM_NR_TEST_MODE:-0}" != 1 ]; then
    return 0
  fi
  if [ "${RRM_NR_TEST_MODE:-0}" = 1 ]; then
    wcfg="${PREFIX}/etc/config/wireless"
  else
    wcfg=/etc/config/wireless
  fi
  [ ! -f "$wcfg" ] && { echo "[rrm_nr] WARNING: $wcfg not found; cannot verify 802.11k/v options" >&2; return 0; }
    awk '
      function flush(){
        if(sec != "" && disabled == 0){
          iface=sec; gsub("'\''","",iface);
          if(ieee==0 || bss==0){ printf("MISSING_IFACE %s %d %d\n", iface, ieee, bss); }
        }
      }
      /^config[[:space:]]+wifi-iface/ { flush(); sec=$3; ieee=0; bss=0; disabled=0; next }
      /option[[:space:]]+ieee80211k/ { v=$3; gsub("'\''","",v); if(v==1) ieee=1 }
      /option[[:space:]]+bss_transition/ { v=$3; gsub("'\''","",v); if(v==1) bss=1 }
      /option[[:space:]]+disabled/ { v=$3; gsub("'\''","",v); if(v==1) disabled=1 }
      END{ flush() }
    ' "$wcfg" 2>/dev/null | while read -r tag iface has_ieee has_bss; do
      [ "$tag" = MISSING_IFACE ] || continue
      msg="[rrm_nr] WARNING: wifi-iface $iface missing required 802.11 options:";
      [ "$has_ieee" -eq 0 ] && msg="$msg ieee80211k=1";
      [ "$has_bss" -eq 0 ] && msg="$msg bss_transition=1";
      echo "$msg" >&2
    done
}

check_wireless_rrm

auto_fix_wireless() {
  [ "$FIX_WIRELESS" -eq 1 ] || return 0
  if [ -n "$PREFIX" ] && [ "${RRM_NR_TEST_MODE:-0}" = 1 ]; then
    wcfg="${PREFIX}/etc/config/wireless"
  elif [ -n "$PREFIX" ]; then
    # Do not modify non-live prefix roots silently
    return 0
  else
    wcfg=/etc/config/wireless
  fi
  [ ! -f "$wcfg" ] && return 0
  tmp=$(mktemp 2>/dev/null || mktemp -t rrmnrfix)
  changed=0
  awk '
    function flush(){
      if(inf && disabled==0){
        if(has_k==0){ print "  option ieee80211k '\''1'\''  # added by rrm_nr"; changed=1 }
        if(has_v==0){ print "  option bss_transition '\''1'\''  # added by rrm_nr"; changed=1 }
      }
    }
    BEGIN{inf=0;changed=0}
    /^config[[:space:]]+wifi-iface/ { flush(); inf=1; has_k=0; has_v=0; disabled=0; print; next }
    inf && /option[[:space:]]+ieee80211k/ { if($3 ~ /(^'?1'?$)/) has_k=1 }
    inf && /option[[:space:]]+bss_transition/ { if($3 ~ /(^'?1'?$)/) has_v=1 }
    inf && /option[[:space:]]+disabled/ { if($3 ~ /(^'?1'?$)/) disabled=1 }
    { print }
    END{ flush(); if(changed){ print "# rrm_nr wireless auto-fix applied" } }
  ' "$wcfg" >"$tmp" || { rm -f "$tmp"; return 1; }
  if grep -q "rrm_nr wireless auto-fix applied" "$tmp"; then
    cp "$wcfg" "$wcfg.rrm_nr.bak" 2>/dev/null || true
    mv "$tmp" "$wcfg"
    echo "[rrm_nr] Applied wireless auto-fix (backup at ${wcfg}.rrm_nr.bak)"
  else
    rm -f "$tmp"
  echo "[rrm_nr] Wireless auto-fix: no changes needed"
  fi
}

auto_fix_wireless

# -------------- End Wireless Sanity Check -------------

copy_file service/rrm_nr.init /etc/init.d/rrm_nr 0755
copy_file bin/rrm_nr /usr/bin/rrm_nr 0755
if [ -f "$REPO_ROOT/lib/rrm_nr_common.sh" ]; then
  copy_file lib/rrm_nr_common.sh /lib/rrm_nr_common.sh 0644
fi

# Provide default UCI config if absent or forced.
if [ ! -f "$(dest /etc/config/rrm_nr)" ] || [ "$FORCE_CONFIG" -eq 1 ]; then
  install -d "$(dest /etc/config)"
  cat >"$(dest /etc/config/rrm_nr)" <<'EOC'
config rrm_nr 'global'
  option enabled '1'
  option update_interval '60'
  option jitter_max '10'
  option debug '0'
  option umdns_refresh_interval '30'
  option umdns_settle_delay '0'
  # option skip_ifaces ''   # space separated list e.g. "wlan1-1 wlan0"
EOC
  echo "[rrm_nr] Installed default /etc/config/rrm_nr"
else
  echo "[rrm_nr] Keeping existing /etc/config/rrm_nr (use --force-config to overwrite)"
fi

if [ "$START_SERVICE" -eq 1 ]; then
  if command -v /etc/init.d/rrm_nr >/dev/null 2>&1; then
    /etc/init.d/rrm_nr enable || true
    /etc/init.d/rrm_nr restart || /etc/init.d/rrm_nr start || true
    /etc/init.d/rrm_nr status || true
  else
    echo "[rrm_nr] WARNING: init script not found at /etc/init.d/rrm_nr after install" >&2
  fi
else
  echo "[rrm_nr] Skipped service enable/start (--no-start given)"
fi

if [ "$ADD_SYSUPGRADE" -eq 1 ]; then
  PERSIST_FILE="$(dest /etc/sysupgrade.conf)"
  # Ensure file exists
  touch "$PERSIST_FILE" 2>/dev/null || true
  add_entry() {
    path=$1
    grep -q "^$path$" "$PERSIST_FILE" 2>/dev/null || echo "$path" >>"$PERSIST_FILE"
  }
  add_entry /etc/init.d/rrm_nr
  add_entry /usr/bin/rrm_nr
  add_entry /lib/rrm_nr_common.sh
  echo "[rrm_nr] Added persistence entries to /etc/sysupgrade.conf"
fi

echo "[rrm_nr] Done. Check: logread | grep rrm_nr"
