#!/usr/bin/env bash
#
# Runs the AI service integration tests against a local mock provider.
#
#   scripts/run_ai_integration.sh
#
# Everything is compiled into a throwaway binary, so the shipped app is not
# touched and no API key is required.

set -euo pipefail

PORT="${1:-8931}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"; [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null || true' EXIT

echo "==> starting mock provider on 127.0.0.1:$PORT"
python3 "$ROOT/scripts/mock_ai_provider.py" "$PORT" > "$BUILD_DIR/mock.log" 2>&1 &
MOCK_PID=$!
sleep 1.5

if ! kill -0 "$MOCK_PID" 2>/dev/null; then
  echo "mock provider failed to start:"
  cat "$BUILD_DIR/mock.log"
  exit 1
fi

cat > "$BUILD_DIR/main.swift" <<SWIFT
import Foundation

let base = "http://127.0.0.1:${PORT}/v1"
let passed = await AIServiceIntegrationTests.run(baseURL: base)
exit(passed ? 0 : 1)
SWIFT

SRC=(
  "$ROOT/notchprompt/AIService.swift"
  "$ROOT/notchprompt/SSEStreamParser.swift"
  "$ROOT/notchprompt/AIProviderSetup.swift"
  "$ROOT/notchprompt/KeychainStore.swift"
  "$ROOT/notchprompt/AnswerCache.swift"
  "$ROOT/notchprompt/IncrementalJSONStringField.swift"
  "$ROOT/notchprompt/ScriptQuoteLocator.swift"
  "$ROOT/notchprompt/ScriptTextMapper.swift"
  "$ROOT/notchprompt/ScriptPositionModel.swift"
  "$ROOT/notchprompt/AIServiceIntegrationTests.swift"
)

echo "==> compiling"
swiftc -o "$BUILD_DIR/integration" "${SRC[@]}" "$BUILD_DIR/main.swift"

echo "==> running"
"$BUILD_DIR/integration"
