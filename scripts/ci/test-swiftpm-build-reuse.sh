#!/usr/bin/env bash
# Exercise the installed SwiftPM consumer, including a real archived build tree.
# Uses an owned temp package so this is a consumer contract check on the
# toolchain itself, not a read of this repo's actual cache behavior.
set -euo pipefail
probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/swiftpm-reuse.XXXXXX")
trap 'rm -rf "$probe_dir"' EXIT
cd "$probe_dir"
mkdir -p Sources/Probe Sources/ProbeValue
cat > Package.swift <<'SWIFT'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "ReuseProbe", products: [.executable(name: "Probe", targets: ["Probe"])], targets: [.target(name: "ProbeValue"), .executableTarget(name: "Probe", dependencies: ["ProbeValue"])])
SWIFT
printf 'public let value = "before"\n' > Sources/ProbeValue/Value.swift
printf 'import ProbeValue\nprint(value)\n' > Sources/Probe/main.swift
swift build
binary_dir=$(swift build --show-bin-path)
test "$("$binary_dir/Probe")" = before
tar -cf build.tar .build
rm -rf .build
tar -xf build.tar
# Exact restore remains runnable, then a changed dependency source must rebuild.
swift build
test "$("$binary_dir/Probe")" = before
printf 'public let value = "after"\n' > Sources/ProbeValue/Value.swift
swift build
test "$("$binary_dir/Probe")" = after
# Deletion must fail compilation; stale object files must not rescue the import.
rm Sources/ProbeValue/Value.swift
if swift build > deleted-source.log 2>&1; then
  echo 'Deleted dependency source unexpectedly built from stale state' >&2
  exit 1
fi
# Reconcile the manifest too: remove the dependency and rebuild a standalone CLI.
cat > Package.swift <<'SWIFT'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "ReuseProbe", products: [.executable(name: "Probe", targets: ["Probe"])], targets: [.executableTarget(name: "Probe")])
SWIFT
printf 'print("manifest changed")\n' > Sources/Probe/main.swift
swift build
test "$("$binary_dir/Probe")" = 'manifest changed'
echo 'SwiftPM archive restore, changed/deleted sources, and changed manifest verified'
