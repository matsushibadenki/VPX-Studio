#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
baseline="$repo_dir/Config/ReleaseBaseline.json"
expected_xcode=$(/usr/bin/plutil -extract xcodeVersion raw "$baseline")
expected_swift=$(/usr/bin/plutil -extract swiftVersion raw "$baseline")
expected_arch=$(/usr/bin/plutil -extract macArchitecture raw "$baseline")
minimum_os=$(/usr/bin/plutil -extract macOSMinimum raw "$baseline")
minimum_memory_gib=$(/usr/bin/plutil -extract macMinimumMemoryGiB raw "$baseline")
actual_xcode=$(/usr/bin/xcodebuild -version | /usr/bin/sed -n '1s/^Xcode //p')
actual_swift=$(swift --version 2>&1)
actual_arch=$(/usr/bin/uname -m)
actual_os=$(/usr/bin/sw_vers -productVersion)
actual_memory=$(/usr/sbin/sysctl -n hw.memsize)

[[ "$actual_xcode" == "$expected_xcode" ]] || { echo "Xcode mismatch: expected $expected_xcode, found $actual_xcode"; exit 1; }
[[ "$actual_swift" == *"Apple Swift version $expected_swift "* ]] || { echo "Swift mismatch: expected $expected_swift"; exit 1; }
[[ "$actual_arch" == "$expected_arch" ]] || { echo "Architecture mismatch: expected $expected_arch, found $actual_arch"; exit 1; }
(( ${actual_os%%.*} >= ${minimum_os%%.*} )) || { echo "macOS below $minimum_os"; exit 1; }
(( actual_memory >= minimum_memory_gib * 1024 * 1024 * 1024 )) || { echo "Memory below ${minimum_memory_gib} GiB"; exit 1; }
echo "Release baseline verified: Xcode $actual_xcode, Swift $expected_swift, $actual_arch, macOS $actual_os"
