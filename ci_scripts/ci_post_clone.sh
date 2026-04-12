#!/bin/sh

# Xcode Cloud doesn't automatically trust Swift macro targets from
# third-party packages. This script applies the default settings to
# allow them, matching what happens when you click "Trust & Enable"
# in Xcode locally.

defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES
