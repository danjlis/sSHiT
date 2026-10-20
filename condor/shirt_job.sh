#!/bin/bash
# shirt_job.sh <shirt.sh arguments...> | <script.sh> [arguments...] -- condor wrapper, run from the sSHiT checkout:
#   shirt_job.sh run dst --test -v
#   shirt_job.sh checks/dst/make_runlists.sh -v
# The sPHENIX environment is set up by the scripts themselves (SHIRT_SPHENIX_SETUP in shirt.conf).
cd "$(dirname "$0")/.." || exit 1
echo "shirt job on $(hostname) at $(date): $*"
case "$1" in
  *.sh) exec "$@" ;;
  *) exec ./shirt.sh "$@" ;;
esac
