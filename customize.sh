#!/bin/bash

set -e

CUSTOMIZER_URL="https://github.com/dkaser/unraid-plugin-template-customizer/releases/download/v1.0.0/unraid-plugin-customizer"
CUSTOMIZER_BIN="unraid-plugin-customizer"

# Download the customizer binary
curl -L -o "$CUSTOMIZER_BIN" "$CUSTOMIZER_URL"

# Make it executable
chmod +x "$CUSTOMIZER_BIN"

# Run the customizer
./"$CUSTOMIZER_BIN"
