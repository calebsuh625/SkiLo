// swift-testing host for machines that only have the Command Line Tools.
//
// `swift test` under DEVELOPER_DIR=/Library/Developer/CommandLineTools builds the test bundle and then
// silently runs NOTHING (exit 0, no output): SwiftPM looks for the `xctest` host via xcrun, CLT does not
// ship it, and no error is reported. This 20-line host replaces it: it dlopen()s the SwiftPM-built
// .xctest bundle binary and hands control to swift-testing's entry point, which discovers every
// @Test in the loaded images. Arguments (e.g. --filter REGEX, --verbose, --list-tests) pass through.
// Built and invoked by tools/run_tests.sh.
import Foundation
import Testing

guard let bundle = ProcessInfo.processInfo.environment["HT_TEST_BUNDLE"], !bundle.isEmpty else {
    FileHandle.standardError.write(Data("usage: HT_TEST_BUNDLE=/path/to/X.xctest/Contents/MacOS/X testhost [--filter REGEX] [--verbose]\n".utf8))
    exit(64)
}
guard dlopen(bundle, RTLD_NOW | RTLD_GLOBAL) != nil else {
    FileHandle.standardError.write(Data("dlopen failed: \(String(cString: dlerror()))\n".utf8))
    exit(2)
}
let code: CInt = await __swiftPMEntryPoint()
exit(code)
