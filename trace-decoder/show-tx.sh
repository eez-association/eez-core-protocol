#!/usr/bin/env bash
# Shows the cross-chain call flow and sequence diagram for one transaction.
#
#   trace-decoder/show-tx.sh <TX_HASH> [--env-file FILE] [decoder options]
#
# The hash may be on L1 or L2; the decoder finds the related settlement and delivery
# transactions on the other chain. The page is written to tmp/flow-diagrams/<hash>.html
# and opened in the default browser. Everything is read-only.
set -euo pipefail

if [[ $# -lt 1 || "$1" == "-h" || "$1" == "--help" ]]; then
  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec node "$here/flow/render-flow.mjs" --views flow,sequence "$@" --open
