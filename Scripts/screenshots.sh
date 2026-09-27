#!/bin/sh
# Regenerates the README screenshots in Screenshots/ from the example apps' UI tests.
set -eu
cd "$(dirname "$0")/../Example"
xcodegen generate --quiet
dir=$(mktemp -d)
xcodebuild test -project TVCompanionDemo.xcodeproj -scheme DemoTV \
  -destination "platform=tvOS Simulator,name=Apple TV 4K (3rd generation) (at 1080p)" \
  -only-testing:DemoTVUITests/ScreenshotTests -resultBundlePath "$dir/tv.xcresult" -quiet
xcodebuild test -project TVCompanionDemo.xcodeproj -scheme DemoPhone \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro" \
  -only-testing:DemoPhoneUITests/ScreenshotTests -resultBundlePath "$dir/phone.xcresult" -quiet
../Scripts/export-screenshots.sh "$dir/tv.xcresult" ../Screenshots
../Scripts/export-screenshots.sh "$dir/phone.xcresult" ../Screenshots
