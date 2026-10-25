import Foundation
import XCTest
@testable import MacSWCore

final class SilentInstallerPlanTests: XCTestCase {
    func testCoreArgumentsRunTheOfficialMSIQuietlyWithValidatedFeatureTree() {
        var serials = InstallSerials()
        serials[.solidWorks] = "0000 2222 3333 4444 5555 6666"
        let arguments = SilentInstallerPlan.coreInstallArguments(
            msi: URL(fileURLWithPath: "/media/swwi/data/solidworks.msi"),
            log: URL(fileURLWithPath: "/logs/install_msi.log"),
            serials: serials
        )
        XCTAssertEqual(arguments.prefix(8), [
            "msiexec", "/i", "/media/swwi/data/solidworks.msi", "/qb", "/norestart",
            "DISABLEROLLBACK=1", "/l*v", "/logs/install_msi.log"
        ])
        XCTAssertTrue(arguments.contains("INSTALLLEVEL=100"))
        XCTAssertTrue(arguments.contains(
            "ADDLOCAL=SolidWorks,ProgramFiles,i386_ProgramFiles,i386_ThirdPtyFiles,i386_DCubeFiles,i386_SWFiles,i386_VistaFiles,i386_CosmosXpressFiles"
        ))
        XCTAssertTrue(arguments.contains("TOOLBOXFOLDER=C:\\SWData"))
        XCTAssertTrue(arguments.contains("SOLIDWORKSSERIALNUMBER=000022223333444455556666"))
    }

    /// Toolbox is optional on the media: the MSI properties never name a Toolbox feature or
    /// turn off its setup, so the same arguments work with or without a Toolbox folder, and
    /// TOOLBOXFOLDER (absolute, no spaces) stays for WriteToolboxStandardsXML under Wine.
    func testCoreArgumentsDoNotDependOnToolboxMedia() {
        let arguments = SilentInstallerPlan.coreInstallArguments(
            msi: URL(fileURLWithPath: "/media/swwi/data/solidworks.msi"),
            log: URL(fileURLWithPath: "/logs/install_msi.log"),
            serials: InstallSerials()
        )
        let addLocal = arguments.first { $0.hasPrefix("ADDLOCAL=") } ?? ""
        XCTAssertFalse(addLocal.isEmpty)
        XCTAssertFalse(addLocal.lowercased().contains("toolbox"))
        XCTAssertFalse(arguments.contains { $0.uppercased().hasPrefix("NOTTOOLBOXSETUP") })
        XCTAssertTrue(arguments.contains("TOOLBOXFOLDER=C:\\SWData"))
    }

    func testWindowsVersionArgumentsRunWinecfgWithVersionName() {
        XCTAssertEqual(SilentInstallerPlan.windowsVersionArguments(.windows11), ["winecfg", "/v", "win11"])
        XCTAssertEqual(SilentInstallerPlan.windowsVersionArguments(.windows10), ["winecfg", "/v", "win10"])
    }

    func testInteractiveArgumentsLeaveTheOfficialWizardInCharge() {
        let arguments = SilentInstallerPlan.interactiveInstallArguments(
            msi: URL(fileURLWithPath: "/media/swwi/data/solidworks.msi"),
            log: URL(fileURLWithPath: "/logs/install_msi.log")
        )
        XCTAssertEqual(arguments, [
            "msiexec", "/i", "/media/swwi/data/solidworks.msi", "DISABLEROLLBACK=1",
            "/l*v", "/logs/install_msi.log"
        ])
    }

    func testLanguageArgumentsCarryNoCoreFeatureSelection() {
        let arguments = SilentInstallerPlan.languageInstallArguments(
            msi: URL(fileURLWithPath: "/media/swwi/lang/chinese-simplified/chinese-simplified.msi"),
            log: URL(fileURLWithPath: "/logs/language.log")
        )
        XCTAssertFalse(arguments.contains { $0.hasPrefix("ADDLOCAL") })
        XCTAssertFalse(arguments.contains { $0.hasPrefix("INSTALLLEVEL") })
        // 语言包也只安静地装，但不再挑主体功能树。
        XCTAssertEqual(arguments.prefix(3), ["msiexec", "/i", "/media/swwi/lang/chinese-simplified/chinese-simplified.msi"])
        XCTAssertTrue(arguments.contains("/qb"))
        XCTAssertTrue(arguments.contains("/norestart"))
        XCTAssertTrue(arguments.contains("/logs/language.log"))
    }
}

final class InstallationMediaTests: XCTestCase {
    private var root: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appendingPathComponent("MacSW-Media-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: root)
    }

    private func write(_ relativePath: String, contents: String = "payload") throws {
        let url = root.appendingPathComponent(relativePath)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    private func completeMedia() throws {
        for component in InstallationMedia.requiredComponents {
            try write(component.relativePath)
        }
        try write("PreReqs/dotNetFx/ndp48-x86-x64-allos-enu.exe")
        try write("Toolbox/ToolboxUpdates.zip")
    }

    func testCompleteMediaReportsNothingMissing() throws {
        try completeMedia()
        XCTAssertTrue(InstallationMedia.missingComponents(in: root, language: nil).isEmpty)
    }

    func testEmptyFileCountsAsMissing() throws {
        try write("swwi/data/solidworks.msi", contents: "")
        for component in InstallationMedia.requiredComponents.dropFirst() { try write(component.relativePath) }
        try write("PreReqs/dotNetFx/ndp48-x86-x64-allos-enu.exe")
        try write("PreReqs/dotNetFx/ndp48-x86-x64-allos-enu.exe")
        try write("Toolbox/ToolboxUpdates.zip")
        XCTAssertEqual(
            InstallationMedia.missingComponents(in: root, language: nil),
            [InstallationMedia.Component(
                relativePath: "swwi/data/solidworks.msi",
                label: "SOLIDWORKS core MSI"
            )]
        )
    }

    func testDirectoryInPlaceOfMSICountsAsMissing() throws {
        try fileManager.createDirectory(
            at: root.appendingPathComponent("swwi/data/solidworks.msi"),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(InstallationMedia.missingComponents(in: root, language: nil).contains {
            $0.relativePath == "swwi/data/solidworks.msi"
        })
    }

    func testDotNetInstallerAcceptsEitherVersionAndPrefers481() throws {
        try completeMedia()
        XCTAssertEqual(
            InstallationMedia.dotNetInstaller(in: root)?.lastPathComponent,
            "ndp48-x86-x64-allos-enu.exe"
        )
        try write("PreReqs/dotNetFx/ndp481-x86-x64-allos-enu.exe")
        XCTAssertEqual(
            InstallationMedia.dotNetInstaller(in: root)?.lastPathComponent,
            "ndp481-x86-x64-allos-enu.exe"
        )
        XCTAssertTrue(InstallationMedia.missingComponents(in: root, language: nil).isEmpty)
    }

    func testMissingOrEmptyDotNetInstallerIsReported() throws {
        try completeMedia()
        try fileManager.removeItem(at: root.appendingPathComponent("PreReqs/dotNetFx/ndp48-x86-x64-allos-enu.exe"))
        try write("PreReqs/dotNetFx/ndp481-x86-x64-allos-enu.exe", contents: "")
        try write("PreReqs/dotNetFx/readme.exe")
        XCTAssertNil(InstallationMedia.dotNetInstaller(in: root))
        XCTAssertEqual(
            InstallationMedia.missingComponents(in: root, language: nil),
            [InstallationMedia.dotNetComponent]
        )
    }

    /// Toolbox is optional: media copied without it (or with no usable zip) is complete,
    /// and the install skips the Toolbox step instead of failing the media check.
    func testToolboxIsOptionalInMediaCheck() throws {
        try completeMedia()
        XCTAssertTrue(InstallationMedia.hasToolboxPayload(in: root))

        // Folder present but no non-empty regular zip (directory named *.zip, empty zip, other extension).
        try fileManager.removeItem(at: root.appendingPathComponent("Toolbox/ToolboxUpdates.zip"))
        try fileManager.createDirectory(at: root.appendingPathComponent("Toolbox/empty.zip"), withIntermediateDirectories: true)
        try write("Toolbox/zero.zip", contents: "")
        try write("Toolbox/readme.txt")
        XCTAssertTrue(InstallationMedia.missingComponents(in: root, language: nil).isEmpty)
        XCTAssertFalse(InstallationMedia.hasToolboxPayload(in: root))

        // No Toolbox folder at all.
        try fileManager.removeItem(at: root.appendingPathComponent("Toolbox"))
        XCTAssertTrue(InstallationMedia.missingComponents(in: root, language: nil).isEmpty)
        XCTAssertFalse(InstallationMedia.hasToolboxPayload(in: root))

        // Adding the folder later makes the payload visible again.
        try write("Toolbox/ToolboxUpdates.zip")
        XCTAssertTrue(InstallationMedia.hasToolboxPayload(in: root))
    }

    func testRequiredComponentsStillReportedWithoutToolbox() throws {
        for component in InstallationMedia.requiredComponents.dropFirst() { try write(component.relativePath) }
        try write("PreReqs/dotNetFx/ndp48-x86-x64-allos-enu.exe")
        XCTAssertEqual(
            InstallationMedia.missingComponents(in: root, language: nil).map(\.relativePath),
            ["swwi/data/solidworks.msi"]
        )
        XCTAssertFalse(InstallationMedia.requiredComponents.contains { $0.relativePath.hasPrefix(InstallationMedia.toolboxDirectory) })
    }

    func testSelectedLanguageMSIIsVerifiedAgainstMedia() throws {
        try completeMedia()
        let language = SolidWorksLanguage(
            directoryName: "chinese-simplified",
            msiFileName: "chinese-simplified.msi",
            displayName: "简体中文"
        )
        XCTAssertEqual(
            InstallationMedia.missingComponents(in: root, language: language).map(\.relativePath),
            ["swwi/lang/chinese-simplified/chinese-simplified.msi"]
        )
        try write("swwi/lang/chinese-simplified/chinese-simplified.msi")
        XCTAssertTrue(InstallationMedia.missingComponents(in: root, language: language).isEmpty)
    }
}

final class InstallerDiagnosticsTests: XCTestCase {
    func testErrorSummaryKeepsMSIFailureLines() {
        let log = """
        Action 0:00:12. WriteToolboxStandardsXML.
        SW MESSAGE|ERROR|0|1603|||Error 1639. invalid command line argument
        Info 1603. Source file not found: somecab.cab
        Property(S): cannot find the requested registry value
        Out of scope chatter about nothing.
        """
        let summary = InstallerDiagnostics.msiErrorSummary(log)
        XCTAssertEqual(summary.count, 3)
        XCTAssertTrue(summary[0].hasPrefix("SW MESSAGE|ERROR|"))
    }

    /// 进程退出码只剩低 8 位，失败说明必须带上日志里的真实 MSI 返回码。
    func testFailureDetailCarriesTheRealMSIReturnCodeAndErrorLines() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacSW-msi-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = directory.appendingPathComponent("install_msi.log")
        try """
        Info 1603. Error 1603. Configuration failure Failed to install assembly
        MSI (s) (CC:2C) [12:34:56:789]: MainEngineThread is returning 1603
        """.data(using: .utf8)!.write(to: log)
        let detail = InstallerDiagnostics.failureDetail(log: log)
        XCTAssertTrue(detail.contains("MSI returned 1603."), detail)
        XCTAssertTrue(detail.contains("Configuration failure"), detail)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("install_msi_errors.log").path))
        XCTAssertTrue(
            InstallerDiagnostics.failureDetail(log: directory.appendingPathComponent("absent.log"))
                .contains("See ")
        )
    }

    func testErrorSummaryNeverLeaksSerialNumbersOrLicenseServers() {
        let log = """
        Property(S): SOLIDWORKSSERIALNUMBER = AAAA BBBB CCCC DDDD EEEE FFFF cannot find
        Property(S): SERVERLIST = 25734@licenses.example.edu Error 1639
        """
        XCTAssertTrue(InstallerDiagnostics.msiErrorSummary(log).isEmpty)
    }

    func testMissingRequirementsAreCaseInsensitive() {
        let output = #"InprocServer32    REG_SZ    mscoree.dll\nClass    REG_SZ    sldLoginManager.LoginManager"#
        XCTAssertEqual(
            InstallerDiagnostics.missingRequirements(
                output: output.uppercased(),
                required: InstallerDiagnostics.loginManagerRequirements
            ),
            ["sldLoginManager.dll"]
        )
        XCTAssertTrue(InstallerDiagnostics.missingRequirements(
            output: output,
            required: ["MSCOREE.DLL", "sldloginmanager.loginmanager"]
        ).isEmpty)
    }

    func testRegisteredCLSIDReadsOnlyTheGUIDValue() {
        let output = """
        HKEY_CLASSES_ROOT\\SldWorks.Application\\CLSID
            (Default)    REG_SZ    {DA0BCE20-060A-4807-9C53-A46527C57EF1}
        """
        XCTAssertEqual(
            InstallerDiagnostics.registeredCLSID(fromQuery: output),
            "{DA0BCE20-060A-4807-9C53-A46527C57EF1}"
        )
        XCTAssertNil(InstallerDiagnostics.registeredCLSID(fromQuery: "REG_SZ    not-a-guid"))
    }
}
