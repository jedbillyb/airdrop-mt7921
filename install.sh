#!/bin/bash
# Install AND update airdrop-mt7921. Run it once to set up, and again after
# every `git pull`:
#
#   ./install.sh            # everything below, asking before it touches sudoers
#   ./install.sh --yes      # same, without the question
#
# It exists because three pieces of this project are COPIES made at install
# time, and a `git pull` updates none of them:
#
#   1. owl, built from source         - an old build rejects newer flags (-S)
#   2. the patched OpenDrop venv      - the patches live here, not in the venv
#   3. the root-owned helper and owl  - root-owned on purpose (see
#                                       daemon/README.md), so never in the repo
#
# On 2026-10-05 all three were stale at once on the maintainer's own machine
# and every symptom pointed somewhere else. Each step below checks its own
# result rather than trusting the command that produced it.
set -euo pipefail

REPO="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
YES=0
[ "${1:-}" = "--yes" ] && YES=1

# The patch series, in order. Must match README.md and patches/README.md.
PATCHES=(ios26-airdrop recv-window py314-send mdns-repeat find-report tls-keylog
         upload-arms ask-confirm mdns-reannounce threaded-server url-items
         zeroconf-update-service salvage-truncated salvage-trim
         send-multifile send-status send-stall)
OPENDROP_VERSION=0.13.0

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '    ok: %s\n' "$*"; }
warn() { printf '    \033[33mwarning:\033[0m %s\n' "$*"; }
die()  { printf '    \033[31mFAILED:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" != 0 ] || die "run as your normal user; it uses sudo where it needs root"

# ---------------------------------------------------------------- prerequisites
step "Checking prerequisites"
missing=()
for c in git cmake make cc python3 iw ip tcpdump nmcli sudo visudo; do
  command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done
[ "${#missing[@]}" = 0 ] || die "missing commands: ${missing[*]}"
python3 -c 'import venv' 2>/dev/null || die "python3 has no venv module"
ok "all present"
# Collected first, then matched: `grep -q` in a pipe exits on the first hit,
# and under pipefail the writer's SIGPIPE turns a found card into "not found".
drivers=$(for d in /sys/class/net/*/device/driver; do readlink -f "$d"; done 2>/dev/null || true)
if ! printf '%s\n' "$drivers" | grep -q mt7921; then
  warn "no mt7921-driven Wi-Fi card found (MT7921/MT7922 use that driver)."
  warn "Continuing, but nothing here has been tested on other cards."
fi

# ------------------------------------------------------------------------ owl
step "owl (AWDL)"
OWL_DIR="${OWL_DIR:-}"
if [ -z "$OWL_DIR" ]; then
  for d in "$(dirname "$REPO")/owl" "$HOME/owl"; do
    [ -d "$d/.git" ] && { OWL_DIR="$d"; break; }
  done
fi
if [ -z "$OWL_DIR" ]; then
  # Beside this repo, which is where airdropd and airdrop.sh look first.
  OWL_DIR="$(dirname "$REPO")/owl"
  git clone --recurse-submodules https://github.com/jedbillyb/owl.git "$OWL_DIR"
fi
ok "using $OWL_DIR"
git -C "$OWL_DIR" submodule update --init --recursive >/dev/null 2>&1 || true
[ -f "$OWL_DIR/build/CMakeCache.txt" ] \
  || cmake -S "$OWL_DIR" -B "$OWL_DIR/build" -DCMAKE_BUILD_TYPE=Release >/dev/null
# Only the owl target. A full build also compiles the bundled googletest, which
# fails under current GCC (-Werror=maybe-uninitialized) and is not needed here.
cmake --build "$OWL_DIR/build" --target owl -j"$(nproc)" >/dev/null \
  || die "owl did not build - run: cmake --build $OWL_DIR/build --target owl"
OWL_BIN="$OWL_DIR/build/daemon/owl"
owl_help=$("$OWL_BIN" -S intersect -h 2>&1 || true)
case "$owl_help" in *"invalid option"*) die "$OWL_BIN does not understand -S; is $OWL_DIR an old checkout?" ;; esac
ok "built $OWL_BIN"

# ------------------------------------------------------------- OpenDrop venv
step "OpenDrop $OPENDROP_VERSION, patched"
VENV="$OWL_DIR/.venv-opendrop"
# Fingerprint of everything the venv is built from. Unchanged = nothing to do;
# changed (a pull touched a patch) = rebuild from scratch, because the patches
# are a series and do not apply on top of an older patched tree.
want=$( { echo "$OPENDROP_VERSION $(python3 -V 2>&1)"
          for p in "${PATCHES[@]}"; do sha256sum "$REPO/patches/opendrop-$p.patch"; done
        } | sha256sum | cut -c1-16)
have=$(cat "$VENV/.airdrop-patches" 2>/dev/null || true)
if [ "$want" = "$have" ] && [ -x "$VENV/bin/opendrop" ]; then
  ok "already current"
else
  [ -n "$have" ] && ok "patches changed since the last install - rebuilding"
  rm -rf "$VENV"
  # Built at its final path: a venv's scripts hard-code it, so building
  # elsewhere and moving it in leaves a "bad interpreter" behind.
  python3 -m venv "$VENV"
  # setuptools<81: OpenDrop imports pkg_resources, which 81 removed.
  "$VENV/bin/pip" install -q "opendrop==$OPENDROP_VERSION" 'setuptools<81' \
    || die "pip install failed"
  SITE=$(echo "$VENV"/lib/python*/site-packages)
  for p in "${PATCHES[@]}"; do
    # GIT_DIR points nowhere ON PURPOSE. The venv sits inside the owl checkout,
    # and `git apply` run inside a repository applies paths relative to the
    # repo root and SILENTLY SKIPS anything outside the current directory -
    # exit 0, no output, nothing patched. That is how a stock OpenDrop passed
    # for a patched one for weeks.
    ( cd "$SITE" && GIT_DIR=/nonexistent-airdrop-install git apply \
        "$REPO/patches/opendrop-$p.patch" ) || die "patch $p did not apply"
  done
  # Prove they landed, rather than trusting git apply's exit code: one marker
  # from the first patch and one from the last.
  grep -q 'trailing CRLF of the final chunk' "$SITE/opendrop/server.py" \
    || die "the patches did not land in $SITE (ios26-airdrop missing)"
  grep -q 'application/x-dvzip' "$SITE/opendrop/server.py" \
    || die "the patches did not land in $SITE (dvzip support missing)"
  "$VENV/bin/python" -m py_compile "$SITE"/opendrop/*.py || die "patched OpenDrop does not compile"
  echo "$want" > "$VENV/.airdrop-patches"
  ok "built $VENV with ${#PATCHES[@]} patches"
fi

# ------------------------------------------------------------- root copies
step "Root-owned copies in /usr/local/bin"
install_root() {
  local src="$1" dst="$2"
  if sudo cmp -s "$src" "$dst" 2>/dev/null; then
    ok "$dst unchanged"
  else
    sudo install -o root -g root -m 755 "$src" "$dst"
    sudo cmp -s "$src" "$dst" || die "could not install $dst"
    ok "$dst updated"
  fi
}
install_root "$REPO/daemon/airdrop-helper" /usr/local/bin/airdrop-helper
install_root "$REPO/daemon/ble-watch"      /usr/local/bin/airdrop-ble-watch
install_root "$OWL_BIN"                    /usr/local/bin/airdrop-owl

# ----------------------------------------------------------------- sudoers
step "Passwordless sudo for the helper (waybar has no terminal to ask in)"
RULES="$USER ALL=(root) NOPASSWD: /usr/local/bin/airdrop-helper
$USER ALL=(root) NOPASSWD: /usr/local/bin/airdrop-ble-watch"
if sudo -n /usr/local/bin/airdrop-helper status >/dev/null 2>&1; then
  ok "already allowed"
else
  echo "    This adds /etc/sudoers.d/zz-airdrop:"
  printf '%s\n' "$RULES" | sed 's/^/      /'
  echo "    Both are fixed root-owned paths that take no free-form arguments;"
  echo "    see daemon/README.md#security for why it is safe."
  if [ "$YES" != 1 ]; then
    read -r -p "    Add it? [y/N] " a
    case "$a" in y|Y|yes) ;; *) die "skipped - the waybar switch cannot work without it" ;; esac
  fi
  TMP=$(mktemp)
  printf '%s\n' "$RULES" > "$TMP"
  # Validate before installing: a malformed sudoers file can lock you out of sudo.
  sudo visudo -cf "$TMP" >/dev/null || { rm -f "$TMP"; die "sudoers rule failed validation"; }
  sudo install -o root -g root -m 440 "$TMP" /etc/sudoers.d/zz-airdrop
  rm -f "$TMP"
  sudo visudo -c >/dev/null || die "sudo config invalid after install - remove /etc/sudoers.d/zz-airdrop"
  sudo -n /usr/local/bin/airdrop-helper status >/dev/null 2>&1 || die "rule installed but sudo -n still asks"
  ok "added"
fi

# ------------------------------------------------------------------ config
step "Config"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/airdrop/config"
if [ -e "$CONF" ]; then
  ok "$CONF exists - left as it is"
else
  mkdir -p "$(dirname "$CONF")"
  reg=$(iw reg get 2>/dev/null | awk '/^country/{sub(":","",$2); print $2; exit}')
  case "$reg" in [A-Z][A-Z]) ;; *) reg="" ;; esac
  {
    echo '# airdrop-mt7921 settings. Sourced by airdrop.sh and airdropd.'
    echo '# Use ${VAR:-value} so a real environment variable still wins.'
    echo
    echo '# exclusive: the waybar switch drops your Wi-Fi while it is on and brings'
    echo '# it back by itself after a transfer. Works on any network. Remove this'
    echo '# line for the shared mode, which keeps Wi-Fi up but only finds the phone'
    echo '# when both share a channel (see daemon/README.md).'
    echo 'AIRDROP_MODE="${AIRDROP_MODE:-exclusive}"'
    echo
    echo '# Your two-letter country. Needed once Wi-Fi is down, or channel 149 is'
    echo '# transmit-forbidden and the phone never hears this machine.'
    if [ -n "$reg" ]; then
      echo "AIRDROP_REG=\"\${AIRDROP_REG:-$reg}\""
    else
      echo '#AIRDROP_REG="${AIRDROP_REG:-NZ}"   # <- set this'
    fi
    echo
    echo '# Name shown on the phone. No apostrophes (it goes into a TLS cert subject).'
    echo "#AIRDROP_NAME=\"\${AIRDROP_NAME:-$(id -un)s Linux Laptop}\""
    echo
    echo '# Where received files land.'
    echo '#RECV_DIR="${RECV_DIR:-$HOME/Downloads}"'
  } > "$CONF"
  ok "wrote $CONF"
  [ -n "$reg" ] || warn "could not detect your country - set AIRDROP_REG in $CONF"
fi

# ------------------------------------------------------------------ waybar
step "waybar"
WB="${XDG_CONFIG_HOME:-$HOME/.config}/waybar"
if [ -d "$WB" ]; then
  if [ "$(readlink -f "$WB/airdrop-status.sh" 2>/dev/null)" = "$REPO/waybar/airdrop-status.sh" ]; then
    ok "module linked"
  else
    ln -sf "$REPO/waybar/airdrop-status.sh" "$WB/airdrop-status.sh"
    ok "linked $WB/airdrop-status.sh"
  fi
  if ! grep -rqs 'airdrop-status.sh' "$WB"/config*; then
    echo "    Add this to your waybar config (and \"custom/airdrop\" to a modules list):"
    cat <<'EOF'
      "custom/airdrop": {
          "exec": "~/.config/waybar/airdrop-status.sh",
          "return-type": "json",
          "interval": 2,
          "on-click": "~/.config/waybar/airdrop-status.sh toggle"
      }
EOF
  fi
else
  ok "no waybar config - use ./airdrop.sh receive, or daemon/airdropd run"
fi

step "Done"
echo "    Receive: click the AirDrop switch on the bar (or run ./airdrop.sh receive)."
echo "    On the phone: AirDrop -> Everyone for 10 Minutes, then share to this machine."
echo "    After every git pull, run ./install.sh again."
