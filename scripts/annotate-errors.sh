#!/usr/bin/env bash
# Turns compiler/test failures in an xcodebuild log into GitHub annotations (readable via the API).
LOG="$1"
grep -E "error:|: error|XCTAssert|failed \(|Test Case .* failed|\*\* (BUILD|TEST) FAILED|Testing failed|Could not|Unable to" "$LOG" \
  | grep -v "^\s*$" | sort -u | head -n 60 | while IFS= read -r line; do
    msg=$(echo "$line" | sed -e 's/%/%25/g' | cut -c1-900)
    echo "::error::$msg"
  done
echo "----- last 40 lines -----"; tail -n 40 "$LOG"
