#!/bin/bash

set -e

CUSTOMIZER_URL="https://github.com/mejacobarussell/ConsolidationTool"
CUSTOMIZER_BIN="ConsolidationTool"

# Download the customizer binary
curl -L -o "$CUSTOMIZER_BIN" "$CUSTOMIZER_URL"

# Make it executable
chmod +x "$CUSTOMIZER_BIN"

# Run the customizer
./"$CUSTOMIZER_BIN"
