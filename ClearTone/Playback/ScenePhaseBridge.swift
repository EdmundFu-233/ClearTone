import SwiftUI

/// 跨平台的场景阶段抽象。
///
/// `PlayerController` 不应 import SwiftUI（它已经依赖 AVFoundation/Combine，
/// 再引入 UI 框架会让它无法在非 UI 上下文里用），所以用一个三态枚举接收
/// 场景变化，iOS 入口处再从 `SwiftUI.ScenePhase` 转换过来。
public enum ScenePhaseBridge: Sendable, Equatable {
    case active
    case inactive
    case background
}

#if os(iOS)
import SwiftUI
extension ScenePhaseBridge {
    init(_ phase: ScenePhase) {
        switch phase {
        case .active: self = .active
        case .inactive: self = .inactive
        case .background: self = .background
        @unknown default: self = .inactive
        }
    }
}
#endif
