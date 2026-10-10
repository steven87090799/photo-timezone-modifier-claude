#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$PROJECT_DIR/scripts/prepare-jxl.py"
