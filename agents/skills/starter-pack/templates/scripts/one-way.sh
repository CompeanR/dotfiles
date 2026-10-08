#!/usr/bin/env bash
set -euo pipefail

grep -E '^(Makefile|\.github/|\.githooks/)|{{ONE_WAY_FILES}}' || true
