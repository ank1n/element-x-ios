#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
work=$(mktemp -d /tmp/stalk-native-otp.XXXXXX)
trap 'rm -rf "$work"' EXIT
sed '/^import MatrixRustSDK$/d' "$root/ElementX/Sources/Services/Authentication/HeadlessOIDCAuthenticator.swift" > "$work/Authenticator.swift"
xcrun swiftc -swift-version 5 -parse-as-library "$work/Authenticator.swift" "$root/Tools/Tests/native-otp.swift" -o "$work/tests"
"$work/tests"
