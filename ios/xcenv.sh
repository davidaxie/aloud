# Shared xcodebuild environment — the single source of truth for the
# toolchain and the pinned simulator. Sourced by build.sh and xcb.sh; edit
# constants here, never in the scripts.
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

XCB_SIM_ID="73B6C851-3A20-4D4C-94F7-ED63D6740EB8"
XCB_DEST="platform=iOS Simulator,id=$XCB_SIM_ID"
XCB_BUNDLE_ID="com.davidxie.Aloud"
XCB_DERIVED=".derived"

# The Mac app (schemes AloudMac and AloudMacUI): this Mac on Apple silicon;
# derived data outside OneDrive, whose extended attributes codesign rejects;
# and the Debug identity every Mac test runs under (never the shipping
# com.davidxie.Aloud.mac, testing D1).
XCB_MAC_DEST="platform=macOS,arch=arm64"
XCB_MAC_DERIVED="$HOME/Library/Developer/Xcode/DerivedData/Aloud-mac"
XCB_MAC_BUNDLE_ID="com.davidxie.Aloud.mac.dev"
