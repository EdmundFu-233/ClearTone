#!/usr/bin/env node
/**
 * 核对辅助进程的**日志出口脱敏**。
 *
 * 背景：`util/request.js` 在非 200 响应上会打 `answer`，而 `answer.cookie` 是上游
 * 下发的 Set-Cookie 原文（`MUSIC_U` / `__csrf`）。这些 stdout 被
 * `HelperProcessManager` 原样收进 `~/Library/Logs/ClearTone/helper.log`
 * —— 0644 权限、5MB 轮转保留历史，等于把会话凭据明文放到任何能读该用户文件的地方。
 *
 * 本探针两件事：
 *   1. **行为**：`redactForLog` 必须打掉 cookie 值，同时保住 status/code/msg/条数
 *      这些诊断信息（以及 Error 的 message/stack —— 变成 {} 比泄漏更糟）。
 *   2. **接线**：`request.js` 不得再有裸的 `console.log('[ERR]', answer)`，
 *      `logger.js` 的每个入口都必须过脱敏。改回去就会红。
 *
 * 用法（必须用仓库内打包的 Node，不要用系统 node）：
 *   ./ClearTone/Resources/HelperRuntime/bin/node scripts/probes/log-redaction.js
 *
 * 有不一致时退出码为 1。
 */
'use strict'

const fs = require('fs')
const path = require('path')

const repoRoot = path.join(__dirname, '..', '..')
const apiDir = path.join(repoRoot, 'ClearTone', 'Resources', 'HelperRuntime', 'api')

const { redactForLog } = require(path.join(apiDir, 'util', 'log.js'))

let failures = 0
function check(condition, message) {
  if (condition) {
    console.log(`  ok   ${message}`)
  } else {
    failures += 1
    console.log(`  FAIL ${message}`)
  }
}

console.log('行为：')

const SECRET = 'FAKESECRET_u1v2w3x4y5z6a7b8c9d0'
const planted = {
  status: 301,
  cookie: [`${SECRET}; Path=/; HttpOnly`, '__csrf=FAKE_CSRF; Path=/'],
  body: { code: 301, msg: `server said MUSIC_U=${SECRET} expired` },
  nested: [{ header: `Set-Cookie: MUSIC_U=${SECRET}; Path=/` }],
}
const logged = JSON.stringify(redactForLog(planted))
check(!logged.includes(SECRET), 'cookie 数组里的 MUSIC_U 值不落日志')
check(!logged.includes('FAKE_CSRF'), 'cookie 数组里的 __csrf 值不落日志')
check(!logged.includes('Set-Cookie: MUSIC_U=FAKE'), '嵌套字符串里的 Set-Cookie 值不落日志')
check(logged.includes('<redacted:2 set-cookie entries>'), 'cookie 字段保留条数，便于诊断')
check(logged.includes('"status":301') && logged.includes('"code":301'), 'status/code 原样保留')

// 脱敏必须作用于副本，不能就地改 —— answer.cookie 还要拿去续会话
check(planted.cookie[0].includes(SECRET), '原对象未被就地修改（cookie 仍可用于续会话）')

const err = new Error(`expired, MUSIC_U=${SECRET}`)
err.config = { headers: { Cookie: `MUSIC_U=${SECRET}` } }
const loggedError = JSON.stringify(redactForLog(err))
check(loggedError.includes('expired, MUSIC_U=<redacted>'), 'Error 的 message 保留且已脱敏')
check(typeof JSON.parse(loggedError).stack === 'string', 'Error 的 stack 保留（不会退化成 {}）')
check(!loggedError.includes(SECRET), 'Error 附带的 headers.Cookie 被打码')

console.log('接线：')

const requestSrc = fs.readFileSync(path.join(apiDir, 'util', 'request.js'), 'utf8')
check(
  !/console\.log\('\[ERR\]',\s*answer\s*\)/.test(requestSrc),
  "request.js 不得再把 answer 裸打进 console.log",
)
check(requestSrc.includes('redactForLog(answer)'), 'request.js 的 [ERR] 走了 redactForLog')

const loggerSrc = fs.readFileSync(path.join(apiDir, 'util', 'logger.js'), 'utf8')
check(
  (loggerSrc.match(/redactForLog\(msg\)/g) || []).length === 6,
  'logger.js 六个级别的 msg 全部过脱敏',
)
check(/\.\.\.safe\(args\)/.test(loggerSrc), 'logger.js 的可变参数过了脱敏')

// 端到端：真的调一次 logger，抓 console 的输出
const logger = require(path.join(apiDir, 'util', 'logger.js'))
const captured = []
const show = (arg) => (typeof arg === 'string' ? arg : JSON.stringify(arg))
const rawInfo = console.info
const rawError = console.error
console.info = (...args) => captured.push(args.map(show).join(' '))
console.error = (...args) => captured.push(args.map(show).join(' '))
try {
  logger.info(`Request Success: [eapi] /api/song/lyric?id=1&MUSIC_U=${SECRET}`)
  logger.error('boom', { cookie: [`${SECRET}; Path=/`], body: { msg: `MUSIC_U=${SECRET}` } })
} finally {
  console.info = rawInfo
  console.error = rawError
}
const output = captured.join('\n')
check(!output.includes(SECRET), 'logger 端到端输出不含凭据原文')
check(output.includes('Request Success'), 'logger 端到端仍输出可读内容')

if (failures > 0) {
  console.log(`\n日志脱敏检查未通过：${failures} 项。`)
  process.exit(1)
}
console.log('\n日志出口脱敏检查全部通过。')
