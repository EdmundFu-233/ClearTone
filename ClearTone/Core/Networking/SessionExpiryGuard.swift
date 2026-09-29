import Foundation

/// 「网易云会话真的失效了」的定罪闸门。
///
/// ## 为什么需要它
///
/// 辅助进程把上游的**业务码翻译成了 HTTP 状态码**：
/// `util/request.js:490` 是 `answer.status = Number(answer.body.code || res.status)`，
/// 而 `SPECIAL_STATUS_CODES`（`:131`）里**没有 301** —— 于是任何 `code: 301`
/// 都会变成 HTTP 301，`server.js:436` 再把 msg 改写成「需要登录」。
///
/// 所以这套架构里 HTTP 301 的真实语义是「**这个接口说它没登录**」，
/// 不是「你的会话死了」。而 403 同理（风控拒绝）、401 在这套 helper 里
/// 更是只有 `X-CT-Token` 不匹配一个来源（`server.js:198-210`，
/// 那是辅助进程重启竞态，跟网易云毫无关系）。
///
/// 早先 `NeteaseProvider.request` 把 301/401/403 一律当会话失效，
/// 广播 `.clearToneSessionExpired`，`AppState` 随即清空账号 + 红心缓存
/// + 歌单缓存 + 导航栈。实测后果（`helper.log`）：
///
/// ```
/// /like → 301 → 弹扫码 → 扫码 → /user/account 200 → /likelist 200
///      → 再点红心 → 又 301 → 又弹扫码 ……（会话一直是好的）
/// ```
///
/// ## 规则：只有旁证才能定罪
///
/// 单次 301/403 只记「疑似」，**不碰任何登录态**；
/// 连续达到阈值后再打一次 `/user/account` 探针：
/// 探针成功 → 判定为风控/单接口拒绝，保留登录态；
/// 探针也失败 → 这才广播会话失效。
///
/// 纯值类型、不依赖网络，因此可以在单元测试里穷举。
public struct SessionExpiryGuard: Sendable, Equatable {

    /// 判定结果
    public enum Decision: Equatable, Sendable {
        /// 还没攒够疑似次数，什么都不做
        case ignore
        /// 攒够了，去打 `/user/account` 探针
        case probeSession
        /// 探针通过：单接口被拒而已，**保留登录态**
        case sessionAlive
        /// 探针也失败：真的掉登录了，可以清
        case sessionExpired
    }

    /// 连续几次「疑似」才值得花一次探针。
    ///
    /// 取 2 而不是 1：风控是成片的（辅助进程一次匿名标识注册失败就会连片拒绝），
    /// 单次 301 几乎必然是风控；而探针本身要花一次网络往返，
    /// 不该由每个偶发拒绝都触发。
    public static let suspicionThreshold = 2

    /// 尚未被探针解释掉的疑似次数
    public private(set) var suspicionCount: Int = 0
    /// 探针进行中：防止探针自己再触发一轮（探针也返回 301 时会递归）
    public private(set) var isProbing: Bool = false

    public init() {}

    /// 记录一次 301/403。返回是否需要立刻打探针。
    public mutating func noteRejection() -> Decision {
        suspicionCount += 1
        guard suspicionCount >= Self.suspicionThreshold, !isProbing else { return .ignore }
        isProbing = true
        return .probeSession
    }

    /// 探针回来了。`succeeded` 为 true 表示 `/user/account` 拿到了账号信息。
    ///
    /// 无论哪种结果都清零计数：一次探针就是一次完整裁决，
    /// 不把怀疑累积到下一次请求上。
    public mutating func resolveProbe(succeeded: Bool) -> Decision {
        isProbing = false
        suspicionCount = 0
        return succeeded ? .sessionAlive : .sessionExpired
    }

    /// 登录态确实变了（扫码成功 / 退出登录）时把闸门复位，
    /// 否则新会话要背上旧会话攒下的疑似次数。
    public mutating func reset() {
        suspicionCount = 0
        isProbing = false
    }
}
