#!/bin/bash
# Compte les transferts d'une phase A/B en lisant le journal du demon.
#
# "demarre"  = opendrop a commence a lire un corps d'upload
# "complet"  = POST /Upload a repondu 200
# Un transfert demarre et jamais complete est un BLOCAGE, le mode d'echec
# qu'on cherche a departager entre strategies.
L=/run/user/1000/airdropd/airdropd.log
s=$(grep -c 'Receiving file' "$L" 2>/dev/null); s=${s:-0}
c=$(grep -c 'POST /Upload HTTP/1.1" 200' "$L" 2>/dev/null); c=${c:-0}
printf 'strategie=%-9s demarres=%-3s complets=%-3s bloques=%s\n' \
  "$(cat ~/.config/airdrop/strategy 2>/dev/null)" "$s" "$c" "$((s - c))"
