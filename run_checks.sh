#!/bin/bash
# Runs pub get, analyzer and the full test suite, writing everything to
# check_results.txt so results can be reviewed afterwards.
cd "$(dirname "$0")"
FLUTTER=${FLUTTER:-$HOME/flutter-sdk/flutter/bin/flutter}
{
  echo "=== flutter --version ==="
  "$FLUTTER" --version
  echo
  echo "=== pub get ==="
  "$FLUTTER" pub get
  echo
  echo "=== analyze ==="
  "$FLUTTER" analyze
  echo
  echo "=== test ==="
  "$FLUTTER" test -r expanded
  echo
  echo "=== exit status: $? ==="
} > check_results.txt 2>&1
echo "done, results in check_results.txt"
