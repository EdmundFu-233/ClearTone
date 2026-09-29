const fs = require('fs')
const path = require('path')
const { register_anonimous } = require('./main')
const { cookieToJson, generateRandomChineseIP } = require('./util/index')
const { getXeapiPublicKey } = require('./util/xeapiKey')
const tmpPath = require('os').tmpdir()

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

/** 读一次就重试一次：这两个注册都是打真实网易云接口，偶发失败很常见 */
async function withRetry(label, fn, attempts = 3) {
  let lastError
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      return await fn()
    } catch (error) {
      lastError = error
      if (attempt < attempts) await sleep(400 * attempt)
    }
  }
  // 重试完还失败：必须打出来。原先这里只有一个 `console.log(error)`，
  // 失败被完全静默掉，症状是「有时候点收藏会掉登录」——
  // 因为 MUSIC_A 拿不到时 weapi 写接口会被风控按 code 301 拒掉。
  console.error(
    `[ClearTone] ${label} 连续 ${attempts} 次失败：${lastError && lastError.message}`,
  )
  return null
}

async function generateConfig() {
  global.cnIp = generateRandomChineseIP()

  // 顺序很重要：**先公钥，再匿名 token**。
  //
  // `register_anonimous` 走 xeapi，而 xeapi 在 `util/request.js:278` 要求
  // `os.tmpdir()/xeapi_public_key` 已经有值，否则直接抛
  // `xeapi public key is missing`。原实现把注册匿名放在取公钥**之前**，
  // 冷启动（临时目录被清空）时第一轮必然失败，anonymous_token 留空 →
  // `processCookieObject` 把 MUSIC_A 置为 '' → weapi 写接口缺客户端标识
  // → 网易云按风控回 code 301。日志里那三次 301 就是这个状态。
  const publicKey = await withRetry('注册 xeapi 公钥', async () => {
    let currentPublicKey = {}
    try {
      currentPublicKey = JSON.parse(
        fs.readFileSync(path.resolve(tmpPath, 'xeapi_public_key'), 'utf-8'),
      )
    } catch (_) {}
    const key = await getXeapiPublicKey(currentPublicKey, global.deviceId)
    fs.writeFileSync(
      path.resolve(tmpPath, 'xeapi_public_key'),
      JSON.stringify(key),
      'utf-8',
    )
    return key
  })

  const anon = await withRetry('注册匿名 token', () => register_anonimous())
  const cookie = anon && anon.body && anon.body.cookie
  if (cookie) {
    const cookieObj = cookieToJson(cookie)
    fs.writeFileSync(
      path.resolve(tmpPath, 'anonymous_token'),
      cookieObj.MUSIC_A || '',
      'utf-8',
    )
  } else if (!publicKey) {
    console.error(
      '[ClearTone] 客户端标识注册全部失败：本次启动的写接口可能被网易云风控拒绝。',
    )
  }
}
module.exports = generateConfig
