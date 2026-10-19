import Foundation

/// Simulator files live on the development Mac and cannot attest iPhone data
/// protection. Only an explicit debug-simulator opt-in may use that storage.
func privacyFileProtectionVerified(
    dataProtectionVerified: Bool,
    backupExcluded: Bool,
    allowSimulatorStorage: Bool
) -> Bool {
    guard backupExcluded else { return false }
    if dataProtectionVerified { return true }
    #if targetEnvironment(simulator) && DEBUG
    return allowSimulatorStorage
    #else
    return false
    #endif
}
