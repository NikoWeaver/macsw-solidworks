import Foundation
import XCTest
@testable import MacSWCore

/// One test per row of the scrub table (sharing plan, C4), with planted values. Every value here
/// is made up: the serials are serial-shaped fixtures, the names and addresses are fakes.
final class DiagnosticsScrubberTests: XCTestCase {
    private let scrubber = DiagnosticsScrubber(context: .init(
        homePath: "/Users/fakeuser", userName: "fakeuser", fullName: "Fake Person",
        hostNames: ["Fake-MacBook-Pro.local", "Fake-MacBook-Pro", "Fake’s MacBook Pro"],
        cloudFolderNames: ["GoogleDrive-member@example.com", "OneDrive-Acme Corp", "Box-Box", "Dropbox"]))

    func testSerialShapedStringsInEveryForm() {
        for serial in ["ABCD1234EFGH5678JKLM9012", "ABCD-1234-EFGH-5678-JKLM-9012", "abcd 1234 efgh 5678 jklm 9012",
                       "0000 0000 0000 0000 0000 0000", "0000-2222-3333-4444-5555-6666"] {
            let text = scrubber.scrub("serial '\(serial)' accepted\nkey=\(serial);\nSN-\(serial) ok\nx \(serial)-1 y")
            XCTAssertFalse(text.uppercased().contains(serial.uppercased()), serial)
            XCTAssertEqual(text, "serial '<serial>' accepted\nkey=<serial>;\nSN-<serial> ok\nx <serial>-1 y", serial)
        }
        XCTAssertEqual(scrubber.scrub("ABCD-1234-EFGH-5678-JKLM-9012-MNOP"), "<serial>-MNOP", "seven groups: the first six go")
        XCTAssertEqual(scrubber.scrub("CustomActionData=ABCD1234EFGH5678JKLM9012_extra;x=ABCD 1234 EFGH 5678 JKLM 9012_extra"),
                       "CustomActionData=<serial>_extra;x=<serial>_extra")
        XCTAssertEqual(scrubber.scrub("ABCD1234EFGH5678JKLM9012X"), "ABCD1234EFGH5678JKLM9012X", "a longer run is not a serial")
        XCTAssertEqual(scrubber.scrub("{69EF7FA2-6705-47CF-AA78-2E4264D24EB3};ABCD-1234-EFGH-5678-JKLM-9012"),
                       "{69EF7FA2-6705-47CF-AA78-2E4264D24EB3};<serial>", "a serial next to a GUID")
    }

    func testInstallerPropertyLinesAreDropped() {
        let log = [
            "MSI (c) (1C:2C) [12:00:00:000]: Command Line: SOLIDWORKSSERIALNUMBER=FAKE ADDLOCAL=SolidWorks",
            "Property(S): SimulationSerialNumber = something",
            "MSI (s) (4C:50) [12:00:01:100]: PROPERTY CHANGE: Adding SERVERLIST property. Its value is 'x'.",
            "Action ended 12:00:02: InstallFinalize. Return value 3.",
            "MSI (s) (4C:50) [12:00:03:000]: MainEngineThread is returning 1603"
        ].joined(separator: "\r\n") + "\r\n"
        let text = scrubber.scrub(log)
        XCTAssertFalse(text.uppercased().contains("SERIALNUMBER"))
        XCTAssertFalse(text.uppercased().contains("SERVERLIST"))
        XCTAssertFalse(text.contains("ADDLOCAL"), "the whole command line goes")
        XCTAssertTrue(text.contains("Return value 3.\r\n"))
        XCTAssertEqual(InstallerDiagnostics.msiReturnCode(text), 1603)
    }

    func testEmailAddresses() {
        XCTAssertEqual(scrubber.scrub("activated by member.name+cad@example.edu on Monday"),
                       "activated by <email> on Monday")
    }

    func testMACAddressesButNotThePlaceholder() {
        XCTAssertEqual(scrubber.scrub("en0 02:11:22:33:44:55, Physical Address 02-AA-BB-CC-DD-EE"),
                       "en0 <mac>, Physical Address <mac>")
        XCTAssertEqual(scrubber.scrub("MACAddress 02:00:00:00:00:00 and 02-00-00-00-00-00"),
                       "MACAddress 02:00:00:00:00:00 and 02-00-00-00-00-00")
        XCTAssertEqual(scrubber.scrub("[12:00:01:000] fe80::1"), "[12:00:01:000] fe80::1")
    }

    func testHomeFolders() {
        XCTAssertEqual(scrubber.scrub("/Users/fakeuser/Library/Application Support/MacSW/bottle"),
                       "~/Library/Application Support/MacSW/bottle")
        XCTAssertEqual(scrubber.scrub("open /Users/otheruser/Desktop/a.txt and /Users/Shared/b"),
                       "open ~/Desktop/a.txt and /Users/Shared/b")
        XCTAssertEqual(scrubber.scrub(#"C:\users\fakeuser\Desktop and Z:\Users\fakeuser\Box and C:\users\Public"#),
                       #"C:\users\<user>\Desktop and Z:\Users\<user>\Box and C:\users\Public"#)
        XCTAssertEqual(scrubber.scrub(#""C:\\users\\someone\\AppData""#), #""C:\\users\\<user>\\AppData""#)
        XCTAssertEqual(scrubber.scrub("drive_c/users/fakeuser/Box"), "drive_c/users/<user>/Box")
    }

    func testComputerAndHostNames() {
        XCTAssertEqual(scrubber.scrub("host Fake-MacBook-Pro.local, wine FAKE-MACBOOK-PR, name Fake’s MacBook Pro"),
                       "host <host>, wine <host>, name <host>")
        XCTAssertEqual(scrubber.scrub("Property(S): ComputerName = OLDNAME-PC"), "Property(S): ComputerName = <host>")
        XCTAssertEqual(scrubber.hostNameForms.first, "Fake-MacBook-Pro.local", "longest first")
        XCTAssertTrue(scrubber.hostNameForms.contains("FAKE-MACBOOK-PR"), "Wine: first label, upper case, 15 characters")
    }

    func testTheUsersNames() {
        XCTAssertEqual(scrubber.scrub("Property(C): USERNAME = Fake Person\nProperty(C): LogonUser = fakeuser"),
                       "Property(C): USERNAME = <user>\nProperty(C): LogonUser = <user>")
        XCTAssertEqual(scrubber.scrub("LogonUser = someoneelse"), "LogonUser = <user>")
        XCTAssertEqual(scrubber.scrub("fakeusers stays"), "fakeusers stays", "whole words only")
    }

    func testCloudFolderNamesKeepOnlyTheProvider() {
        XCTAssertEqual(scrubber.scrub("~/Library/CloudStorage/GoogleDrive-member@example.com/Parts"),
                       "~/Library/CloudStorage/GoogleDrive/Parts")
        XCTAssertEqual(scrubber.scrub("cloud:OneDrive-Acme Corp -> Y:"), "cloud:OneDrive -> Y:")
        XCTAssertEqual(scrubber.scrub("CloudStorage/Box-Box and CloudStorage/Dropbox"), "CloudStorage/Box and CloudStorage/Dropbox")
        XCTAssertEqual(scrubber.scrub(#"Library\CloudStorage\Dropbox-Unknown Team"#), #"Library\CloudStorage\Dropbox Team"#,
                       "an unknown folder loses its account up to the first space")
    }

    func testLicenceServersBeforeEmail() {
        XCTAssertEqual(scrubber.scrub("SW_D_LICENSE_FILE=25734@license.example.edu;27000@[fd00::1] 1234@srv"),
                       "SW_D_LICENSE_FILE=<server>;<server> <server>")
        XCTAssertEqual(scrubber.scrub("user25734@example.edu"), "<email>")
    }

    func testDiagnosticValuesSurvive() {
        let kept = [
            "<string>c66e2090343dcd727f7f7fd2f87ee0bfb0b118790c1d745ab7b8a4c3a4197f2f</string>",
            "<string>3873d67a1b2c3d4e5f60718293a4b5c6d7e8f901</string>",
            "{69EF7FA2-6705-47CF-AA78-2E4264D24EB3}",
            // Its last five groups have the serial's shape.
            "ProductCode {12345678-1234-1234-1234-123456789012}, component 12345678-1234-1234-1234-123456789012.",
            "Installer\\Products\\2AF7FE965076FC74AA87E24246D4E43B",
            "MSI (s) (4C:50) [12:00:03:000]: MainEngineThread is returning 1603",
            "SLDWORKS.exe sldworks_fs.exe wineserver",
            "Wine 11.16, Mono 11.3.0, SOLIDWORKS 2026 SP4.1 (34.4.1.1011)"
        ].joined(separator: "\n")
        XCTAssertEqual(scrubber.scrub(kept), kept)
    }
}
