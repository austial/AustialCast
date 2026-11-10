#!/bin/sh
# Strips ANSI colour codes and long compiler command lines from swift build output.
sed -E 's/\x1b\[[0-9;]*m//g' | grep -E "error:|warning: var|Test Case .* (failed|passed)|Executed|XCTAssert|fatal" | cut -c1-260
