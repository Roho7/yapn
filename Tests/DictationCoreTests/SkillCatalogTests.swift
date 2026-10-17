import Testing
@testable import DictationCore

struct SkillCatalogTests {
    @Test func listsDirectoriesThatHoldASkillFile() throws {
        let names = try withTempSkillsDirectory(["grill-me": true, "code-review": true, "synced": false]) { directory in
            SkillCatalog.load(from: [directory])
        }
        #expect(names == ["code-review", "grill-me"])
    }

    @Test func mergesDirectoriesAndSkipsMissingOnes() throws {
        let names = try withTempSkillsDirectory(["grill-me": true]) { first in
            try withTempSkillsDirectory(["grill-me": true, "why": true]) { second in
                SkillCatalog.load(from: [first, missingDirectory(), second])
            }
        }
        #expect(names == ["grill-me", "why"])
    }
}
