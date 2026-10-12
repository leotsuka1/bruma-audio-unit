# Bruma

Bruma is a stereo Audio Unit v3 effects suite for GarageBand on macOS. Its signal chain includes EQ, overdrive, compression, chorus/flanger, tempo-synced delay, and hybrid reverb with Reverse Gate.

## Features

- Six bypassable, automatable effects in a fixed signal chain.
- Eight overdrive characters and five compressor models.
- Stereo, ping-pong, dual-mono, and wide delay modes with tempo divisions.
- Room, Hall, Plate, Spring, Shimmer, IR Hybrid, and Reverse Gate reverb modes.
- Import WAV or AIFF impulse responses, with background preparation and a relink option if a file is moved.
- Factory presets and user presets.

## Build and use

1. Open `AUv3Filter.xcodeproj` in Xcode and build the `AUv3Filter macOS` scheme.
2. Open Bruma once to register its Audio Unit extension with macOS.
3. If GarageBand was already open, restart it so it refreshes its Audio Units list.
4. Add Bruma from **Audio Units → Ltsk → Leotsuka: Bruma** on an audio track.

The container app also provides a standalone preview of the effect interface.

## Release installer

The release script is `scripts/build-release-installer.sh`. Its default `local` mode builds an unsigned installer for local use. The `public` mode signs the app and installer with Developer ID, submits the package to Apple for notarization, staples the ticket, and checks the result. It requires valid `Developer ID Application` and `Developer ID Installer` identities and a configured `notarytool` keychain profile.

## Compatibility

- macOS 12 or later
- Intel and Apple Silicon
- GarageBand Audio Unit v3 hosts

The Audio Unit identifiers and parameter addresses are retained for existing sessions.

## Regression scripts

The repository includes focused regression scripts for the DSP kernel, AU state and presets, and impulse-response import:

- `scripts/run-dsp-regressions.sh`
- `scripts/run-au-state-regressions.sh`
- `scripts/run-ir-import-regressions.sh`

The project includes Apple's AUv3 sample-code license in `LICENSE/LICENSE.txt`.
