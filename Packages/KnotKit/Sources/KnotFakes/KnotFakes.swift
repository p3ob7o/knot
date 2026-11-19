// Every file of this module sits inside `#if DEBUG`.
//
// Xcode links a package product into every configuration of the app that depends on it,
// so a release app would otherwise carry the fakes. Compiled for release, this module is
// empty. `scripts/verify.sh --only packaging` fails when a release binary holds any of its
// symbols, and the release script fails in the same case.
#if DEBUG
    /// KnotFakes holds a fake for every leaf port, the fixture builders and the preview
    /// environment (docs/architecture.md §3). It imports no test framework. Debug builds of
    /// the apps link it; release builds do not hold it.
    public enum KnotFakes {
        /// The module name, which the release check looks for in a binary's symbols.
        public static let moduleName = "KnotFakes"
    }
#endif
