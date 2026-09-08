import Foundation

public enum MoleInstallPhase: Sendable, Equatable {
    case preparing, downloading, verifying, installing, checking

    public var message: String {
        switch self {
        case .preparing: "正在检查安装环境…"
        case .downloading: "正在下载 Mole 1.53.0…"
        case .verifying: "正在校验下载文件…"
        case .installing: "正在安装 Mole…"
        case .checking: "正在验证安装结果…"
        }
    }
}

public enum MoleInstallError: Error, LocalizedError, Sendable {
    case download(String)
    case checksum
    case invalidPackage
    case destinationConflict
    case unsafeDirectory
    case busy
    case installation(String)

    public var errorDescription: String? {
        switch self {
        case .download(let detail): "下载 Mole 失败，请检查网络后重试。\(MoleError.safeDiagnostic(detail))"
        case .checksum: "下载文件校验未通过，未进行安装。请重新下载。"
        case .invalidPackage: "Mole 安装包不完整或版本不匹配，未发布安装结果。"
        case .destinationConflict: "Mole 安装目录已有内容，请重新检测；不会覆盖已有安装。"
        case .unsafeDirectory: "Mole 安装目录不是当前用户可安全写入的普通目录。"
        case .busy: "另一个拾净实例正在安装 Mole，请稍后重新检测。"
        case .installation(let detail): "Mole 安装未完成。\(MoleError.safeDiagnostic(detail))"
        }
    }
}
