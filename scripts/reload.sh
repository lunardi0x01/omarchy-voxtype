#!/usr/bin/env bash
# Load edited plugin files into the running shell. Quickshell caches compiled
# QML by file path, so disabling and re-enabling the plugin brings back the
# old code; only a shell restart picks up edits. The bar and panels restart
# for a moment; windows are not affected. Check the shell log for
# "lunardi0x01.voxtype: service started, build …" to see what's running.
set -euo pipefail
omarchy restart shell
