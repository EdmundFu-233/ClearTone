'use strict'

/**
 * 日志脱敏。
 *
 * 存在的理由：`util/request.js` 在非 200 响应上会 `console.log('[ERR]', answer)`，
 * 而 `answer.cookie` 是上游下发的 **Set-Cookie 原文数组**（`MUSIC_U` / `__csrf`）。
 * 这些 stdout 全部被 `HelperProcessManager` 收进
 * `~/Library/Logs/ClearTone/helper.log`（文件权限 0644、5MB 轮转保留历史）——
 * 也就是「任何能读该用户文件的进程」都拿得到明文会话。
 *
 * 所以：**任何**要落日志的对象都必须先过这里。脱敏放在 `util/logger.js` 的
 * 每个入口上，`console.log('[ERR]', …)` 这类绕过 logger 的调用点自己负责传进来。
 *
 * 只脱敏，不改形状：诊断时还需要看到 status / code / msg / cookie 条数。
 */

/// 上游会话 Cookie 的名字。出现在任何字符串里都要打码。
/// （`NMTID` 是设备标识，一并算敏感；`MUSIC_U`/`__csrf` 是真正的会话凭据。）
const SECRET_COOKIE_NAMES = ['MUSIC_U', '__csrf', 'NMTID', 'MUSIC_A']

/// `NAME=value` 里的 value 打码。前缀类覆盖 cookie 串、query、JSON 片段与引号内文本。
const COOKIE_PAIR = new RegExp(
  `(^|[?&;:\\s"'=[{])(${SECRET_COOKIE_NAMES.join('|')})=([^&;"'\\s}\\]]*)`,
  'gi',
)

const MAX_DEPTH = 6

function redactString(value) {
  if (typeof value !== 'string' || value.length === 0) return value
  return value.replace(COOKIE_PAIR, (_match, prefix, name) => `${prefix}${name}=<redacted>`)
}

function redactCookieField(value) {
  if (Array.isArray(value)) return `<redacted:${value.length} set-cookie entries>`
  return redactAny(value, 0)
}

function redactAny(value, depth) {
  if (value === null || value === undefined) return value
  if (typeof value === 'string') return redactString(value)
  if (typeof value !== 'object') return value
  if (depth >= MAX_DEPTH) return '<depth-limit>'
  if (typeof Buffer !== 'undefined' && Buffer.isBuffer(value)) return redactString(value.toString('utf8'))
  if (Array.isArray(value)) return value.map((item) => redactAny(item, depth + 1))

  // Error 的 message/stack 是**不可枚举**的，直接 Object.entries 会得到空对象 ——
  // 那等于把 axios 抛出的错误连同 config.headers.Cookie 一起换成 {}，
  // 日志只剩一个「{}」，比泄漏还糟。所以先显式保住诊断信息，再补可枚举字段。
  if (value instanceof Error) {
    const out = {
      name: value.name,
      message: redactString(String(value.message ?? '')),
      stack: redactString(String(value.stack ?? '')),
    }
    for (const [key, item] of Object.entries(value)) {
      if (key === 'message' || key === 'stack') continue
      out[key] = key === 'cookie' ? redactCookieField(item) : redactAny(item, depth + 1)
    }
    return out
  }

  const out = {}
  for (const [key, item] of Object.entries(value)) {
    out[key] = key === 'cookie' ? redactCookieField(item) : redactAny(item, depth + 1)
  }
  return out
}

/**
 * 把任意对象转成**可以落盘**的副本。
 *
 * 不是原地改：`answer` 本身还要 resolve/reject 给上游，
 * `cookie` 数组是真正用来续会话的，脱敏必须只作用于日志那一份。
 */
function redactForLog(value) {
  try {
    return redactAny(value, 0)
  } catch (_) {
    // 脱敏自己绝不能把日志调用弄崩 —— 拿不到就什么都不打
    return '<unloggable>'
  }
}

module.exports = { redactForLog, redactString, SECRET_COOKIE_NAMES }
