#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p work
set --
if [[ "${BRUMA_SANITIZE:-0}" == 1 ]]; then set -- -fsanitize=address,undefined -fno-omit-frame-pointer
elif [[ "${BRUMA_THREAD_SANITIZE:-0}" == 1 ]]; then set -- -fsanitize=thread -fno-omit-frame-pointer
fi
xcrun clang++ -std=c++17 -fblocks -O2 "$@" Tests/BrumaDSPRegression.mm Shared/AudioUnit/Support/DSPKernel.mm -framework AudioToolbox -o work/bruma-dsp-regressions
work/bruma-dsp-regressions
