import Foundation

@main
struct PrivacyFileProtectionPolicyTests {
    static func main() {
        assert(privacyFileProtectionVerified(dataProtectionVerified: true, backupExcluded: true, allowSimulatorStorage: false))
        assert(!privacyFileProtectionVerified(dataProtectionVerified: false, backupExcluded: true, allowSimulatorStorage: false))
        assert(!privacyFileProtectionVerified(dataProtectionVerified: true, backupExcluded: false, allowSimulatorStorage: true))
        #if targetEnvironment(simulator) && DEBUG
        assert(privacyFileProtectionVerified(dataProtectionVerified: false, backupExcluded: true, allowSimulatorStorage: true))
        #else
        assert(!privacyFileProtectionVerified(dataProtectionVerified: false, backupExcluded: true, allowSimulatorStorage: true))
        #endif
    }
}
