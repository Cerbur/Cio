# Build and open NativeBrowser

- Always build the app from the repository root with `CONFIGURATION=Debug Scripts/build.sh`. The script regenerates the Xcode project and keeps DerivedData under this repository's `build/` directory. Do not use a separate `xcodebuild` app build or an external DerivedData directory.
- Open the resulting Debug app at `build/DerivedData/Build/Products/Debug/NativeBrowser.app`. When checking a new build, make sure an already running NativeBrowser instance is not reused in place of this freshly built app.
