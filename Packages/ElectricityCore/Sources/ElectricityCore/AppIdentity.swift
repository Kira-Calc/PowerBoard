/// Single source of truth for replaceable product identifiers (SPEC 2.2).
/// `project.yml` holds the matching PRODUCT_NAME and PRODUCT_BUNDLE_IDENTIFIER.
public enum AppIdentity {
    public static let displayName = "PowerBoard"
    public static let bundleID = "io.github.kira-calc.powerboard"
    public static let cliName = "powerboard"
    public static let supportDirName = "PowerBoard"
    public static let version = "0.1.0"
    /// Test release: shown next to the version in the app and marked as a pre-release on GitHub.
    public static let isBeta = true
    /// Identifiers used before the rename to PowerBoard, read once to move existing data (see `LegacyMigration`).
    public static let legacyBundleID = "dev.placeholder.aielectricity"
    public static let legacySupportDirName = "AIElectricity"
    /// Shown in exports as the place to read the method.
    public static let repositoryURL = "https://github.com/Kira-Calc/PowerBoard"
    /// Calculation method, linked from exported reports.
    public static let methodologyURL = repositoryURL + "/blob/main/docs/METHODOLOGY.md"
}
