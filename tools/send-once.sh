#!/bin/bash
# Envoyer un fichier, sans avoir a jongler avec le demon.
#
# POURQUOI CE SCRIPT EXISTE : airdropd et airdrop.sh veulent tous les deux la
# meme carte. Quand le demon tourne, il possede mon0/awdl0 et l'OWL de
# airdrop.sh meurt aussitot sur "Could not open device: awdl0" - un echec qui
# ressemble a un probleme de decouverte alors que rien n'a jamais demarre.
# Ca nous a coute trois runs. Ici le demon est arrete avant, et remis apres.
#
#   tools/send-once.sh <fichier>
#
# Pendant la recherche : ouvrir une feuille de partage sur l'iPhone, compter
# trois secondes, la refermer, attendre ~15 s, recommencer. Ouverte, le
# telephone est EMETTEUR et ne s'annonce jamais ; refermee avec l'AWDL encore
# chaud, il redevient receveur et s'annonce. C'est cette fenetre-la qu'on vise.
set -u

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
DAEMON="$HERE/daemon/airdropd"
BLE="$HERE/tools/blewake-dbus.py"

[ $# -ge 1 ] || { echo "usage: send-once.sh <fichier>" >&2; exit 2; }
[ -r "$1" ] || { echo "illisible: $1" >&2; exit 2; }

BLE_PID=""
DAEMON_WAS_UP=0

cleanup() {
  [ -n "$BLE_PID" ] && kill "$BLE_PID" 2>/dev/null
  if [ "$DAEMON_WAS_UP" = 1 ]; then
    echo "--- relance du demon (reception) ---"
    setsid env AIRDROP_ALWAYS=1 AIRDROP_DUALCHAN=1 "$DAEMON" run >/dev/null 2>&1 &
  fi
}
trap cleanup EXIT INT TERM

if "$DAEMON" status 2>/dev/null | grep -q '"state":"off"'; then
  echo "demon deja arrete"
else
  echo "--- arret du demon (il possede la carte) ---"
  DAEMON_WAS_UP=1
  "$DAEMON" stop >/dev/null 2>&1
  sleep 4
fi

# L'annonce BLE se reenregistre toute seule : la puce est un combo Wi-Fi/BT et
# la couche 1 de airdrop.sh reset le controleur partage, ce qui tue une
# annonce posee une seule fois.
if [ -x "$BLE" ]; then
  "$BLE" >/dev/null 2>&1 &
  BLE_PID=$!
  echo "--- annonce BLE demarree (pid $BLE_PID) ---"
fi

# 180s plutot que 45 : le telephone ne s'annonce que par breves fenetres, et
# une capture de 95s l'a entendu la ou le browse de 45s ne trouvait rien.
echo "--- recherche pendant ${FIND_TIME:-180}s : ouvre/ferme une feuille de partage regulierement ---"
FIND_TIME="${FIND_TIME:-180}" "$HERE/airdrop.sh" send "$@"
