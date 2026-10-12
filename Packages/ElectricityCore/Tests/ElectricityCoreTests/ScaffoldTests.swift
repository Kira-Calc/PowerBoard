import Foundation
import Testing
@testable import ElectricityCore

@Suite struct ScaffoldTests {
    @Test func appIdentityIsDefined() {
        #expect(!AppIdentity.displayName.isEmpty)
        #expect(!AppIdentity.bundleID.isEmpty)
        #expect(!AppIdentity.cliName.isEmpty)
        #expect(!AppIdentity.supportDirName.isEmpty)
    }

    @Test(arguments: BundledResource.allCases)
    func bundledResourceIsValidJSON(_ resource: BundledResource) throws {
        let data = try resource.data()
        let object = try JSONSerialization.jsonObject(with: data)
        #expect(object is [String: Any])
    }
}
