const { redactForLog } = require('./log')

// ANSI 颜色代码
const colors = {
  reset: '\x1b[0m',
  bright: '\x1b[1m',
  dim: '\x1b[2m',
  black: '\x1b[30m',
  red: '\x1b[31m',
  green: '\x1b[32m',
  yellow: '\x1b[33m',
  blue: '\x1b[34m',
  magenta: '\x1b[35m',
  cyan: '\x1b[36m',
  white: '\x1b[37m',
  bgRed: '\x1b[41m',
  bgGreen: '\x1b[42m',
  bgYellow: '\x1b[43m',
}

// 所有参数一律先过脱敏。这里改一次，`server.js` 的 logger.error(…, {body})
// 这类调用点就不可能把 Set-Cookie 原文漏进 helper.log —— 逐个调用点去防是防不住的。
const safe = (args) => args.map((arg) => redactForLog(arg))

const logger = {
  debug: (msg, ...args) =>
    console.info(`${colors.cyan}[DEBUG]${colors.reset}`, redactForLog(msg), ...safe(args)),
  info: (msg, ...args) =>
    console.info(`${colors.green}[INFO]${colors.reset}`, redactForLog(msg), ...safe(args)),
  warn: (msg, ...args) =>
    console.info(`${colors.yellow}[WARN]${colors.reset}`, redactForLog(msg), ...safe(args)),
  error: (msg, ...args) =>
    console.error(`${colors.red}[ERROR]${colors.reset}`, redactForLog(msg), ...safe(args)),
  success: (msg, ...args) =>
    console.log(
      `${colors.bright}${colors.green}[SUCCESS]${colors.reset}`,
      redactForLog(msg),
      ...safe(args),
    ),
  critical: (msg, ...args) =>
    console.error(
      `${colors.bright}${colors.bgRed}[CRITICAL]${colors.reset}`,
      redactForLog(msg),
      ...safe(args),
    ),
}

module.exports = logger
