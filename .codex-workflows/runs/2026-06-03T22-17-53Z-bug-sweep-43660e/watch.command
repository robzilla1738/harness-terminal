#!/bin/zsh
printf '\033[8;42;190t'
cd '/Users/robert/Code/harness' || exit 1
exec '/Users/robert/.hermes/node/bin/node' '/Users/robert/.codex/plugins/cache/codex-workflows/codex-workflows/0.1.0/dist/cli.js' watch '2026-06-03T22-17-53Z-bug-sweep-43660e' --cwd '/Users/robert/Code/harness'
