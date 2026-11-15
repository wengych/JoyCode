#!/bin/bash
# Show JoyCode diagnostics from the macOS unified log (no files are written).
#   bash logs.sh            # last 30 minutes
#   bash logs.sh 2h         # any `log show --last` value: 90s, 10m, 2h, 1d
#   bash logs.sh errors     # user-visible failures only, last 1 day
#   bash logs.sh stream     # follow live while pressing buttons
set -euo pipefail
PREDICATE='subsystem == "local.weng.XboxAgentRemote"'
case "${1:-30m}" in
    stream) exec log stream --level info --style compact --predicate "$PREDICATE" ;;
    errors) exec log show --last 1d --style compact --predicate "$PREDICATE AND messageType == error" ;;
    *) exec log show --last "${1:-30m}" --info --style compact --predicate "$PREDICATE" ;;
esac
