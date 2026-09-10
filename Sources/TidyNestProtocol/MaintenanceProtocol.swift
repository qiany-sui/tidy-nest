import Foundation

public enum MaintenanceKind: String, Codable, Sendable, Hashable { case clean, uninstall }
public enum PlanSelection: String, Codable, Sendable, Hashable { case optional, required, blocked }
public enum MaintenanceItemKind: String, Codable, Sendable, Hashable { case file, application }
public enum MaintenanceAction: String, Codable, Sendable, Hashable { case trashItem }
public enum MaintenanceStatus: String, Codable, Sendable, Hashable { case completed, partial, cancelled, blocked, failed, unknown }
public enum ItemOutcome: String, Codable, Sendable, Hashable { case trashed, skipped, failed, cancelled, unknown }
public enum MaintenanceEventKind: String, Codable, Sendable, Hashable { case progress, candidate, itemResult, result }

public struct PlanIssue: Codable, Sendable, Hashable {
    public let path: String
    public let reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public struct MaintenanceItem: Codable, Sendable, Hashable, Identifiable {
    public let itemID: String
    public let ruleID: String
    public let path: String
    public let displayName: String
    public let kind: MaintenanceItemKind
    public let action: MaintenanceAction
    public let estimatedBytes: UInt64?
    public let reason: String
    public let impact: String
    public let selection: PlanSelection
    public let blockedReason: String?
    public let dependsOnItemIDs: [String]
    public let requiresAuthorization: Bool?
    public var id: String { itemID }

    public init(itemID: String, ruleID: String, path: String, displayName: String, kind: MaintenanceItemKind, action: MaintenanceAction, estimatedBytes: UInt64?, reason: String, impact: String, selection: PlanSelection, blockedReason: String?, dependsOnItemIDs: [String], requiresAuthorization: Bool? = nil) {
        self.itemID = itemID
        self.ruleID = ruleID
        self.path = path
        self.displayName = displayName
        self.kind = kind
        self.action = action
        self.estimatedBytes = estimatedBytes
        self.reason = reason
        self.impact = impact
        self.selection = selection
        self.blockedReason = blockedReason
        self.dependsOnItemIDs = dependsOnItemIDs
        self.requiresAuthorization = requiresAuthorization
    }
}

public struct MaintenancePlan: Codable, Sendable, Hashable, Identifiable {
    public let schemaVersion: Int
    public let planID: String
    public let runID: String
    public let kind: MaintenanceKind
    public let title: String
    public let engineVersion: String
    public let engineDigest: String
    public let rulesVersion: String
    public let configurationDigest: String
    public let createdAt: Date
    public let scopeRoots: [String]
    public let scanComplete: Bool
    public let scanIssues: [PlanIssue]
    public let items: [MaintenanceItem]
    public var id: String { planID }

    public init(schemaVersion: Int, planID: String, runID: String, kind: MaintenanceKind, title: String, engineVersion: String, engineDigest: String, rulesVersion: String, configurationDigest: String, createdAt: Date, scopeRoots: [String], scanComplete: Bool, scanIssues: [PlanIssue], items: [MaintenanceItem]) {
        self.schemaVersion = schemaVersion
        self.planID = planID
        self.runID = runID
        self.kind = kind
        self.title = title
        self.engineVersion = engineVersion
        self.engineDigest = engineDigest
        self.rulesVersion = rulesVersion
        self.configurationDigest = configurationDigest
        self.createdAt = createdAt
        self.scopeRoots = scopeRoots
        self.scanComplete = scanComplete
        self.scanIssues = scanIssues
        self.items = items
    }
}

public struct MaintenanceItemResult: Codable, Sendable, Hashable, Identifiable {
    public let itemID: String
    public let path: String
    public let outcome: ItemOutcome
    public let reason: String?
    public let trashPath: String?
    public let retainedPath: String?
    public let estimatedBytes: UInt64?
    public var id: String { itemID }

    public init(itemID: String, path: String, outcome: ItemOutcome, reason: String?, trashPath: String?, retainedPath: String?, estimatedBytes: UInt64?) {
        self.itemID = itemID
        self.path = path
        self.outcome = outcome
        self.reason = reason
        self.trashPath = trashPath
        self.retainedPath = retainedPath
        self.estimatedBytes = estimatedBytes
    }
}

public struct MaintenanceResult: Codable, Sendable, Hashable, Identifiable {
    public let planID: String
    public let runID: String
    public let title: String
    public let status: MaintenanceStatus
    public let startedAt: Date
    public let finishedAt: Date
    public let items: [MaintenanceItemResult]
    public let selectedBytes: UInt64
    public let trashedBytes: UInt64
    public let freeBytesDelta: Int64?
    public let message: String?
    public var id: String { runID }

    public init(planID: String, runID: String, title: String, status: MaintenanceStatus, startedAt: Date, finishedAt: Date, items: [MaintenanceItemResult], selectedBytes: UInt64, trashedBytes: UInt64, freeBytesDelta: Int64?, message: String?) {
        self.planID = planID
        self.runID = runID
        self.title = title
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.items = items
        self.selectedBytes = selectedBytes
        self.trashedBytes = trashedBytes
        self.freeBytesDelta = freeBytesDelta
        self.message = message
    }
}

public struct EngineCapabilities: Codable, Sendable, Hashable {
    public let schemaVersion: Int
    public let engineVersion: String
    public let engineDigest: String
    public let rulesVersion: String
    public let supportedRuleIDs: [String]
    public let supportedActions: [MaintenanceAction]

    public init(schemaVersion: Int, engineVersion: String, engineDigest: String, rulesVersion: String, supportedRuleIDs: [String], supportedActions: [MaintenanceAction]) {
        self.schemaVersion = schemaVersion
        self.engineVersion = engineVersion
        self.engineDigest = engineDigest
        self.rulesVersion = rulesVersion
        self.supportedRuleIDs = supportedRuleIDs
        self.supportedActions = supportedActions
    }
}

public struct MaintenanceEvent: Codable, Sendable, Hashable {
    public let schemaVersion: Int
    public let runID: String
    public let sequence: Int
    public let type: MaintenanceEventKind
    public let message: String?
    public let candidate: MaintenanceItem?
    public let itemResult: MaintenanceItemResult?
    public let plan: MaintenancePlan?
    public let applyResult: MaintenanceResult?
    public let error: String?

    public init(schemaVersion: Int, runID: String, sequence: Int, type: MaintenanceEventKind, message: String?, candidate: MaintenanceItem?, itemResult: MaintenanceItemResult?, plan: MaintenancePlan?, applyResult: MaintenanceResult?, error: String?) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.sequence = sequence
        self.type = type
        self.message = message
        self.candidate = candidate
        self.itemResult = itemResult
        self.plan = plan
        self.applyResult = applyResult
        self.error = error
    }
}

public struct MaintenanceRequest: Codable, Sendable, Hashable {
    public let planID: String?
    public let selectedItemIDs: [String]?
    public let confirmed: Bool?
    public let appPath: String?
    public let expectedBundleID: String?
    public let protectedPath: String?

    public init(planID: String? = nil, selectedItemIDs: [String]? = nil, confirmed: Bool? = nil, appPath: String? = nil, expectedBundleID: String? = nil, protectedPath: String? = nil) {
        self.planID = planID
        self.selectedItemIDs = selectedItemIDs
        self.confirmed = confirmed
        self.appPath = appPath
        self.expectedBundleID = expectedBundleID
        self.protectedPath = protectedPath
    }
}

public enum MaintenanceLimits {
    public static let maximumRecordBytes = 32 * 1024 * 1024
}

public enum MaintenanceJSON {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func request(from data: Data, command: String) throws -> MaintenanceRequest {
        guard data.count <= MaintenanceLimits.maximumRecordBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MaintenanceProtocolError.invalidRequest
        }
        let allowed: Set<String>
        switch command {
        case "capabilities", "list-apps", "scan-clean", "history", "protections": allowed = []
        case "plan-uninstall": allowed = ["appPath", "expectedBundleID"]
        case "apply-plan": allowed = ["planID", "selectedItemIDs", "confirmed"]
        case "protect-path", "unprotect-path": allowed = ["protectedPath"]
        default: throw MaintenanceProtocolError.invalidCommand
        }
        guard Set(object.keys).isSubset(of: allowed) else { throw MaintenanceProtocolError.invalidRequest }
        let request = try decoder().decode(MaintenanceRequest.self, from: data)
        switch command {
        case "plan-uninstall":
            guard request.appPath != nil, request.expectedBundleID != nil else { throw MaintenanceProtocolError.invalidRequest }
        case "apply-plan":
            guard request.planID != nil, request.selectedItemIDs != nil, request.confirmed == true else { throw MaintenanceProtocolError.invalidRequest }
        case "protect-path", "unprotect-path":
            guard request.protectedPath != nil else { throw MaintenanceProtocolError.invalidRequest }
        default: break
        }
        return request
    }
}

public enum MaintenanceProtocolError: Error, LocalizedError, Sendable {
    case invalidCommand, invalidRequest
    public var errorDescription: String? {
        switch self {
        case .invalidCommand: "不支持的维护命令。"
        case .invalidRequest: "维护请求包含未知字段、缺少必需输入或超出长度限制。"
        }
    }
}
