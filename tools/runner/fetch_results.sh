#!/usr/bin/env bash
# Downloads the results (final archive, or the latest snapshot if the run is not finished) and packs them
# into results_<date>.zip – send this file for the evaluation of tables 2.15–2.17.
set -euo pipefail
cd "$(dirname "$0")/../.."
source tools/runner/common.sh
NAME=results/results.tar.gz
[ "$(az storage blob exists --account-name "$RACC" -c runner -n "$NAME" --auth-mode login --query exists -o tsv)" = "true" ] \
  || { NAME=results/snapshot.tar.gz; echo "Run not finished – downloading the latest snapshot."; }
DIR="results_$(date -u +%Y%m%d)"
mkdir -p "$DIR"
az storage blob download --account-name "$RACC" -c runner -n "$NAME" -f /tmp/res.tgz --auth-mode login -o none
tar -xzf /tmp/res.tgz -C "$DIR"
cp -n build/config_checks.txt build/tf11_deploy.txt "$DIR/build/" 2>/dev/null || true
rm -rf "$DIR/build/A.8.24" "$DIR"/build/k2_run*      # downloaded evidence copies are not needed for the report
(cd "$DIR" && zip -qr "../$DIR.zip" .)
echo "Saved: $DIR.zip  (Cloud Shell: Manage files -> Download)"
cat "$DIR/build/STATUS.txt" 2>/dev/null || true
