#!/bin/sh
# @TOOL@ was retired on @DATE@. This notice replaces its install script.
cat >&2 <<'TOOLS_KLAR_WS_EOF'

@TOOL@ is no longer distributed here (retired @DATE@).

@BLOCK@

TOOLS_KLAR_WS_EOF
exit 1
