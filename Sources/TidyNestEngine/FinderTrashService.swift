import Foundation
import AppKit

enum SystemTrashError: Error, LocalizedError {
    case cancelled, denied, uncertain(String), rejected(String)

    static func appleEventFailure(code: Int, message: String) -> SystemTrashError {
        switch code {
        case -128: .cancelled
        case -1743: .denied
        case -43, -50, -54, -5000, -10004, -10006, -1700, -1703, -1708: .rejected(message)
        // 未收到回执不表示 Finder 已停止，包括取消等待、连接中断和未知错误。
        default: .uncertain(message)
        }
    }

    var errorDescription: String? {
        switch self {
        case .cancelled: "已取消系统授权，应用保留。"
        case .denied: "未允许拾净与 Finder 协作，应用保留。可在系统设置的「隐私与安全性 → 自动化」中允许后重新检查。"
        case .uncertain(let message): "系统操作结果待核对，请检查原位置和废纸篓，勿直接重试。" + message
        case .rejected(let message): "系统未完成移入废纸篓：" + message
        }
    }
}

// 固定 Finder 命令只接收结构化文件引用，不拼接路径为脚本或 shell。
@MainActor
enum FinderTrashService {
    static func trash(_ url: URL, snapshot: ObjectSnapshot) async throws -> URL {
        try Task.checkCancellation()
        let source = try DirectoryFD(path: url.path)
        defer { withExtendedLifetime(source) {} }
        guard let script = NSAppleScript(source: scriptSource) else { throw SystemTrashError.rejected("无法创建系统请求。") }
        let reference = try targetReference(source)
        guard snapshot.members.first?.identity == source.identities.last,
              snapshot.matches(try ObjectSnapshot.capture(url.path, application: true)) else {
            throw SystemTrashError.rejected("应用在交接前发生变化，请重新检查。")
        }
        try Task.checkCancellation()
        let event = NSAppleEventDescriptor(eventClass: 0x61736372, eventID: 0x70736272, targetDescriptor: nil, returnID: -1, transactionID: 0)
        event.setParam(NSAppleEventDescriptor(string: "moveTarget"), forKeyword: 0x736e616d)
        let arguments = NSAppleEventDescriptor.list()
        arguments.insert(reference, at: 1)
        event.setParam(arguments, forKeyword: 0x2d2d2d2d)
        var error: NSDictionary?
        let result = script.executeAppleEvent(event, error: &error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
            let message = error[NSAppleScript.errorMessage] as? String ?? "系统错误 \(code)"
            throw SystemTrashError.appleEventFailure(code: code, message: message)
        }
        guard let path = result.stringValue, path.hasPrefix("/"), !path.contains("\0") else {
            throw SystemTrashError.uncertain("系统未返回有效的废纸篓位置。")
        }
        return URL(fileURLWithPath: path)
    }

    static func targetReference(_ source: DirectoryFD) throws -> NSAppleEventDescriptor {
        var info = stat()
        guard fstat(source.fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw SystemTrashError.rejected("无法读取已绑定的应用身份。")
        }
        // FD 在整个交接期间存活；生成引用前后独立比较系统不透明身份，
        // 不解析私有标识格式，也不重新按应用原路径寻找目标。
        let descriptorURL = URL(fileURLWithPath: "/dev/fd/\(source.fd)") as CFURL
        let expectedID = try resourceValue(kCFURLFileResourceIdentifierKey, at: descriptorURL)
        guard let reference = CFURLCreateFileReferenceURL(nil, descriptorURL, nil)?.takeRetainedValue(),
              CFURLIsFileReferenceURL(reference) else {
            throw SystemTrashError.rejected("无法绑定应用的文件身份，请重新检查。")
        }
        try verifyReference(reference, resourceID: expectedID, inode: info.st_ino)
        // 必须保留 CF 原始引用文本；转成 Swift URL 或路径 alias 会丢失身份。
        let text = CFURLGetString(reference)! as String
        guard let descriptor = NSAppleEventDescriptor(descriptorType: 0x6675726c, data: Data(text.utf8)) else {
            throw SystemTrashError.rejected("无法创建系统文件引用。")
        }
        return descriptor
    }

    static func verifyReference(_ reference: CFURL, resourceID: CFTypeRef, inode: UInt64) throws {
        let actualID = try resourceValue(kCFURLFileResourceIdentifierKey, at: reference)
        let actualInode = try resourceValue(kCFURLFileIdentifierKey, at: reference)
        guard CFEqual(resourceID, actualID), let number = actualInode as? NSNumber,
              number.uint64Value == inode else {
            throw SystemTrashError.rejected("系统文件引用与选中的应用不一致，应用保留。")
        }
    }

    private static func resourceValue(_ key: CFString, at url: CFURL) throws -> CFTypeRef {
        var value: Unmanaged<CFTypeRef>?
        guard CFURLCopyResourcePropertyForKey(url, key, &value, nil), let value else {
            throw SystemTrashError.rejected("无法完整核对系统文件引用，应用保留。")
        }
        return value.takeRetainedValue()
    }

    private static let scriptSource = """
    on moveTarget(targetReference)
        with timeout of 600 seconds
            tell application id "com.apple.finder"
                set trashedItem to delete targetReference
                return POSIX path of (trashedItem as alias)
            end tell
        end timeout
    end moveTarget
    """
}
