#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bruma_products="${BRUMA_BUILD_PRODUCTS:-/tmp/BrumaDerived/Build/Products/Release}"
mkdir -p work
xcrun swiftc Tests/BrumaIRImportRegression.swift -F "$bruma_products" -framework AUv3FilterFramework -Xlinker -rpath -Xlinker "$bruma_products" -o work/bruma-ir-import-regressions
work/bruma-ir-import-regressions
