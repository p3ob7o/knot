import Testing

extension Tag {
    /// A test that docs/architecture.md §17 or docs/plan/named-tests.txt requires by name.
    /// Its display name is the slug from docs/plan/named-tests.txt.
    @Tag public static var named: Self

    /// A test that runs one of the shared contract suites.
    @Tag public static var contract: Self
}
