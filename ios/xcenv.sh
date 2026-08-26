# Shared xcodebuild environment — the single source of truth for the
# toolchain and the pinned simulator. Sourced by build.sh and xcb.sh; edit
# constants here, never in the scripts.
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

XCB_SIM_ID="73B6C851-3A20-4D4C-94F7-ED63D6740EB8"
XCB_DEST="platform=iOS Simulator,id=$XCB_SIM_ID"
XCB_BUNDLE_ID="com.davidxie.Aloud"
XCB_DERIVED=".derived"
