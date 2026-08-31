import XCTest
import Security

final class TranslationXPCConnectionPolicyTests: XCTestCase {
    func testAdHocRequirementAllowsOnlyKnownHostIdentifiers() {
        XCTAssertEqual(
            TranslationXPCConnectionPolicy.codeSigningRequirement(teamIdentifier: nil),
            "(identifier \"app.lurume.Lurume\" or identifier \"app.lurume.TranslationProbe\")"
        )
    }

    func testSignedRequirementAlsoRequiresAppleAnchorAndMatchingTeam() {
        XCTAssertEqual(
            TranslationXPCConnectionPolicy.codeSigningRequirement(teamIdentifier: "TEAM123"),
            "(identifier \"app.lurume.Lurume\" or identifier \"app.lurume.TranslationProbe\") "
                + "and anchor apple generic and certificate leaf[subject.OU] = \"TEAM123\""
        )
    }

    func testDynamicTeamIdentifierIsEscapedForRequirementSyntax() {
        let requirement = TranslationXPCConnectionPolicy.codeSigningRequirement(
            teamIdentifier: "TEAM\"\\VALUE"
        )
        XCTAssertTrue(requirement.hasSuffix("= \"TEAM\\\"\\\\VALUE\""))
    }

    func testGeneratedRequirementsCompileWithSecurityFramework() {
        for teamIdentifier in [nil, "TEAM123"] as [String?] {
            let source = TranslationXPCConnectionPolicy.codeSigningRequirement(
                teamIdentifier: teamIdentifier
            )
            var requirement: SecRequirement?
            XCTAssertEqual(
                SecRequirementCreateWithString(source as CFString, SecCSFlags(), &requirement),
                errSecSuccess
            )
            XCTAssertNotNil(requirement)
        }
    }
}
