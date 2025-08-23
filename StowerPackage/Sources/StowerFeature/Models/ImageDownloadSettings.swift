import Foundation
import SwiftData

@Model
public final class ImageDownloadSettings {
    public var globalAutoDownload: Bool = true
    public var alwaysDownloadDomains: [String] = []
    public var neverDownloadDomains: [String] = []
    public var askForNewDomains: Bool = false
    public var maxImageSizeKB: Int = 5000 // 5MB default limit
    public var downloadOnCellular: Bool = false
    public var lastUpdated: Date = Date()
    
    public init(
        globalAutoDownload: Bool = true,
        alwaysDownloadDomains: [String] = [],
        neverDownloadDomains: [String] = [],
        askForNewDomains: Bool = false,
        maxImageSizeKB: Int = 5000,
        downloadOnCellular: Bool = false
    ) {
        self.globalAutoDownload = globalAutoDownload
        self.alwaysDownloadDomains = alwaysDownloadDomains
        self.neverDownloadDomains = neverDownloadDomains
        self.askForNewDomains = askForNewDomains
        self.maxImageSizeKB = maxImageSizeKB
        self.downloadOnCellular = downloadOnCellular
        self.lastUpdated = Date()
    }
    
    /// Determines if images should be downloaded for a given domain
    public func shouldDownloadImages(for domain: String?) -> ImageDownloadDecision {
        guard let domain = domain else {
            return .skip("No domain provided")
        }
        
        // Check never download list first (highest priority)
        if neverDownloadDomains.contains(domain) {
            return .skip("Domain is in never download list")
        }
        
        // Check always download list
        if alwaysDownloadDomains.contains(domain) {
            return .download("Domain is in always download list")
        }
        
        // Check global setting
        if globalAutoDownload {
            return .download("Global auto-download is enabled")
        }
        
        // Ask for new domains if configured
        if askForNewDomains {
            return .ask("New domain requires user decision")
        }
        
        // Default to skip if no global setting and not asking
        return .skip("No explicit permission for domain")
    }
    
    /// Adds a domain to the always download list
    public func addToAlwaysDownload(_ domain: String) {
        let cleanDomain = domain.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove from never download if present
        neverDownloadDomains.removeAll { $0 == cleanDomain }
        
        // Add to always download if not already present
        if !alwaysDownloadDomains.contains(cleanDomain) {
            alwaysDownloadDomains.append(cleanDomain)
        }
        
        lastUpdated = Date()
    }
    
    /// Adds a domain to the never download list
    public func addToNeverDownload(_ domain: String) {
        let cleanDomain = domain.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove from always download if present
        alwaysDownloadDomains.removeAll { $0 == cleanDomain }
        
        // Add to never download if not already present
        if !neverDownloadDomains.contains(cleanDomain) {
            neverDownloadDomains.append(cleanDomain)
        }
        
        lastUpdated = Date()
    }
    
    /// Removes a domain from all lists (resets to default behavior)
    public func removeDomain(_ domain: String) {
        let cleanDomain = domain.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        alwaysDownloadDomains.removeAll { $0 == cleanDomain }
        neverDownloadDomains.removeAll { $0 == cleanDomain }
        
        lastUpdated = Date()
    }
    
    /// Gets the current preference for a domain
    public func getDomainPreference(_ domain: String?) -> DomainImagePreference {
        guard let domain = domain else { return .default }
        
        let cleanDomain = domain.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        if alwaysDownloadDomains.contains(cleanDomain) {
            return .always
        } else if neverDownloadDomains.contains(cleanDomain) {
            return .never
        } else {
            return .default
        }
    }
    
    /// Clears all domain preferences
    public func clearAllDomainPreferences() {
        alwaysDownloadDomains.removeAll()
        neverDownloadDomains.removeAll()
        lastUpdated = Date()
    }
    
    /// Gets statistics about domain preferences
    public var domainStats: DomainStats {
        return DomainStats(
            alwaysCount: alwaysDownloadDomains.count,
            neverCount: neverDownloadDomains.count,
            totalManaged: alwaysDownloadDomains.count + neverDownloadDomains.count
        )
    }
}

// A Sendable, value-type snapshot of settings for cross-actor use
public struct ImageDownloadSettingsSnapshot: Sendable {
    public let globalAutoDownload: Bool
    public let alwaysDownloadDomains: [String]
    public let neverDownloadDomains: [String]
    public let askForNewDomains: Bool
    public let maxImageSizeKB: Int
    public let downloadOnCellular: Bool
}

public extension ImageDownloadSettings {
    // Create a Sendable snapshot for background work
    func snapshot() -> ImageDownloadSettingsSnapshot {
        ImageDownloadSettingsSnapshot(
            globalAutoDownload: globalAutoDownload,
            alwaysDownloadDomains: alwaysDownloadDomains,
            neverDownloadDomains: neverDownloadDomains,
            askForNewDomains: askForNewDomains,
            maxImageSizeKB: maxImageSizeKB,
            downloadOnCellular: downloadOnCellular
        )
    }
}

public extension ImageDownloadSettingsSnapshot {
    /// Determines if images should be downloaded for a given domain
    func shouldDownloadImages(for domain: String?) -> ImageDownloadDecision {
        guard let domain = domain else {
            return .skip("No domain provided")
        }

        if neverDownloadDomains.contains(domain) {
            return .skip("Domain is in never download list")
        }

        if alwaysDownloadDomains.contains(domain) {
            return .download("Domain is in always download list")
        }

        if globalAutoDownload {
            return .download("Global auto-download is enabled")
        }

        if askForNewDomains {
            return .ask("New domain requires user decision")
        }

        return .skip("No explicit permission for domain")
    }
}

public enum ImageDownloadDecision {
    case download(String)  // Reason for downloading
    case skip(String)      // Reason for skipping
    case ask(String)       // Reason for asking user
    
    public var shouldDownload: Bool {
        switch self {
        case .download: return true
        case .skip, .ask: return false
        }
    }
    
    public var shouldAsk: Bool {
        switch self {
        case .ask: return true
        case .download, .skip: return false
        }
    }
    
    public var reason: String {
        switch self {
        case .download(let reason), .skip(let reason), .ask(let reason):
            return reason
        }
    }
}

public enum DomainImagePreference: String, CaseIterable, Sendable {
    case always = "always"
    case never = "never"
    case `default` = "default"
    
    public var displayName: String {
        switch self {
        case .always: return "Always Download"
        case .never: return "Never Download"
        case .default: return "Use Global Setting"
        }
    }
    
    public var systemImage: String {
        switch self {
        case .always: return "checkmark.circle.fill"
        case .never: return "xmark.circle.fill"
        case .default: return "circle"
        }
    }
    
    public var color: String {
        switch self {
        case .always: return "green"
        case .never: return "red"
        case .default: return "secondary"
        }
    }
}

public struct DomainStats {
    public let alwaysCount: Int
    public let neverCount: Int
    public let totalManaged: Int
    
    public var hasPreferences: Bool {
        return totalManaged > 0
    }
}
