#!/bin/bash
# Add the "Send via AirDrop" entry to Thunar's right-click menu, idempotently.
#
#   tools/install-thunar-action.sh            # install
#   tools/install-thunar-action.sh --remove   # take it out again
#
# WHY A SCRIPT RATHER THAN "paste this into uca.xml". Thunar REWRITES uca.xml
# from memory when it exits, so editing the file while Thunar is running is a
# race it usually wins - the edit vanishes and it looks as though the install
# silently failed. This refuses to touch the file while Thunar is running and
# says so, which is the only part of this that is not a two-line sed.
set -u

UCA="${UCA:-$HOME/.config/Thunar/uca.xml}"
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SNIPPET="$HERE/../daemon/thunar-action.xml"
ID="airdrop-mt7921-send"

if pgrep -x Thunar >/dev/null 2>&1; then
  echo "Thunar is running, and it rewrites uca.xml on exit - your edit would be lost."
  echo "Close it first:"
  echo "    thunar -q"
  echo "then run this again."
  exit 1
fi

if [ "${1:-}" = "--remove" ]; then
  [ -f "$UCA" ] || { echo "nothing to do - no $UCA"; exit 0; }
  if ! grep -q "$ID" "$UCA"; then echo "nothing to do - not installed"; exit 0; fi
  cp "$UCA" "$UCA.bak"
  # Delete the <action> block containing our unique-id, and nothing else. Range
  # addressing on <action>/</action> keeps this to the one block even though
  # the file holds several.
  awk -v id="$ID" '
    /<action>/ { buf = $0 ORS; inact = 1; next }
    inact      { buf = buf $0 ORS
                 if ($0 ~ /<\/action>/) {
                   if (buf !~ id) printf "%s", buf
                   inact = 0
                 }
                 next }
    { print }
  ' "$UCA" > "$UCA.tmp" && mv "$UCA.tmp" "$UCA"
  echo "removed (backup at $UCA.bak)"
  exit 0
fi

[ -f "$SNIPPET" ] || { echo "missing $SNIPPET" >&2; exit 1; }

command -v airdrop-send >/dev/null 2>&1 || {
  echo "WARNING: airdrop-send is not on PATH. The menu entry will appear and do"
  echo "  nothing. Install it first:"
  echo "      sudo install -m 755 daemon/airdrop-send /usr/local/bin/"
}

mkdir -p "$(dirname "$UCA")"
if [ ! -f "$UCA" ]; then
  { echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<actions>'
    grep -v '^<!--' "$SNIPPET" | sed '/^     /d;/^$/d'
    echo '</actions>'
  } > "$UCA"
  echo "created $UCA with the AirDrop action"
  exit 0
fi

if grep -q "$ID" "$UCA"; then
  echo "already installed - nothing to do"
  exit 0
fi

cp "$UCA" "$UCA.bak"
# Insert before the closing tag rather than appending: </actions> has to stay
# last or Thunar discards the whole file as malformed and the user loses every
# custom action they had, not just this one. Hence the backup above.
if ! grep -q '</actions>' "$UCA"; then
  echo "$UCA has no </actions> - refusing to guess where this goes." >&2
  exit 1
fi
{
  sed '$!b; /<\/actions>/d' "$UCA" | sed '/<\/actions>/d'
  grep -v '^<!--' "$SNIPPET" | sed '/^     /d;/^$/d'
  echo '</actions>'
} > "$UCA.tmp" && mv "$UCA.tmp" "$UCA"
echo "installed into $UCA (backup at $UCA.bak)"
