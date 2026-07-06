source "https://rubygems.org"

# Pessimistic patch-level constraints (~> x.y allows x.y.* only).
# This prevents a minor-version bump in fastlane or cocoapods from silently
# changing signing, gym, or pod install behavior between CI runs.
#
# To upgrade: bump the minor version here, run `bundle lock` on macOS to
# regenerate Gemfile.lock, then commit both files together.
gem "fastlane",   "~> 2.224"
gem "cocoapods",  "~> 1.16"
# xcodeproj is a transitive dep of cocoapods but pinned explicitly here so
# `require 'xcodeproj'` in the Fastfile is guaranteed to resolve even if a
# future CocoaPods release drops or renames the dependency.
gem "xcodeproj",  "~> 1.26"
