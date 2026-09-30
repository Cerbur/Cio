# Build and validate NativeBrowser

- Always build the app from the repository root with `CONFIGURATION=Debug Scripts/build.sh`. The script regenerates the Xcode project and keeps DerivedData under this repository's `build/` directory. Do not use a separate `xcodebuild` app build or an external DerivedData directory.
- For subsequent changes, validation defaults to running the build script above. If the build completes successfully with no compilation errors, deliver the changes to the user; no additional validation or app launch is required by default.
- Use computer use for validation only when the user explicitly requests it. In that case, open the resulting Debug app at `build/DerivedData/Build/Products/Debug/NativeBrowser.app` and make sure an already running NativeBrowser instance is not reused in place of this freshly built app.
- For explicitly requested computer-use checks, resolve `build/DerivedData/Build/Products/Debug/NativeBrowser.app` relative to the repository root and connect to that Debug app, not by the generic NativeBrowser app name. Verify the inspected window belongs to the freshly built instance.
