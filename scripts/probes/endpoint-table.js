#!/usr/bin/env node
/**
 * 用打包的 Node 运行时核对 NeteaseEndpoint 路由登记表。
 *
 * 做法：把 module 的 `request` 换成桩，只记录 (uri, data, options.crypto)，
 * 不发任何网络请求。于是拿到的是**上游 module 真正会发出去的东西**：
 * uri、加密方式、以及 `data` 的字面量键序与 JSON 类型。
 *
 * 这三样恰好是直连层（NeteaseDirectTransport / NeteaseMobileRoute）必须逐字
 * 复现的东西 —— eapi 的签名覆盖整个 JSON.stringify 结果，键序与类型错一个
 * 字节，界面上只表现为「接口报错」。
 *
 * 用法（必须用仓库内打包的 Node，不要用系统 node）：
 *   ./ClearTone/Resources/HelperRuntime/bin/node scripts/probes/endpoint-table.js
 *
 * 有不一致时退出码为 1。
 */
'use strict'

const fs = require('fs')
const path = require('path')

const repoRoot = path.join(__dirname, '..', '..')
const apiDir = path.join(repoRoot, 'ClearTone', 'Resources', 'HelperRuntime', 'api')
const endpointSwift = path.join(repoRoot, 'ClearTone', 'Providers', 'Netease', 'NeteaseEndpoint.swift')

const APP_CONF = JSON.parse(
  fs.readFileSync(path.join(apiDir, 'util', 'config.json'), 'utf8')
).APP_CONF

/** 各路由实际调用时传入的 query（照抄 Swift 调用点的字面量）。 */
const queries = {
  '/login/qr/key': { randomCNIP: 'true' },
  '/login/qr/create': { key: 'fixture-key', qrimg: 'true' },
  '/login/qr/check': { key: 'fixture-key', timestamp: '1700000000000', randomCNIP: 'true' },
  '/cloudsearch': { keywords: '周杰伦', type: '1', limit: '30', offset: '0' },
  '/song/detail': { ids: '123,456' },
  '/playlist/detail': { id: '1' },
  '/playlist/track/all': { id: '1', limit: '100', offset: '0' },
  '/album': { id: '1' },
  '/artist/detail': { id: '1' },
  '/artist/top/song': { id: '1' },
  '/artist/album': { id: '1', limit: '20', offset: '0', total: 'true' },
  '/artist/songs': { id: '1', order: 'hot', offset: '0', limit: '50' },
  '/artist/desc': { id: '1' },
  '/artist/mv': { id: '1', offset: '0', limit: '30', total: 'true' },
  '/song/url/v1': { id: '347230', level: 'exhigh' },
  '/song/url/match': { id: '347230' },
  '/lyric/new': { id: '347230' },
  '/user/playlist': { uid: '1', limit: '30', offset: '0' },
  '/likelist': { uid: '1' },
  '/song/like': { id: '1', uid: '2', like: 'true' },
  '/personalized': { limit: '20' },
  '/dj/recommend': { limit: '6' },
  '/dj/hot': { limit: '6' },
  '/dj/program': { rid: '1', limit: '20', offset: '0' },
  '/dj/detail': { rid: '1' },
  '/dj/sublist': { limit: '30', offset: '0' },
  '/playlist/create': { name: '清单', privacy: '0', type: 'NORMAL' },
  '/playlist/delete': { id: '1,2' },
  '/playlist/name/update': { id: '1', name: '清单' },
  '/playlist/tracks': { op: 'add', pid: '1', tracks: '2,3', imme: 'true' },
  '/playlist/subscribe': { id: '1', t: '1' },
  '/playlist/subscribers': { id: '1', limit: '30', offset: '0' },
  '/album/sublist': { uid: '1', limit: '30', offset: '0' },
  '/artist/sublist': { uid: '1', limit: '30', offset: '0' },
  '/album/sub': { id: '1', t: '1' },
  '/artist/sub': { id: '1', t: '1' },
  '/dj/sub': { rid: '1', t: '1' },
  '/recommend/songs/dislike': { id: '1' },
  '/personalized/newsong': { type: 'recommend', limit: '6', areaId: '0' },
  '/simi/song': { id: '1', limit: '6', offset: '0' },
  '/simi/artist': { id: '1' },
  '/comment/new': { id: '1', type: '0', pageNo: '1', pageSize: '20', sortType: '99', cursor: '0' },
  '/comment/music': { id: '1', limit: '20', offset: '0' },
  '/comment/hot': { id: '1', type: '0', limit: '20', offset: '0' },
  '/comment/like': { id: '1', cid: '2', t: '1', type: '0' },
  '/msg/notices': { limit: '20', lasttime: '-1' },
  '/msg/private': { limit: '20', offset: '0', total: 'true' },
  '/msg/private/history': { uid: '1', limit: '20', before: '0', total: 'true' },
  '/msg/comments': { uid: '1', limit: '20', before: '-1' },
  '/daily_signin': { type: '0' },
  '/user/record': { uid: '1', type: '1' },
  '/top/song': { type: '0', total: 'true' },
  '/top/playlist': { limit: '35', offset: '0', total: 'true', order: 'hot' },
  '/search/suggest': { keywords: '周杰伦' },
  '/search/hot/detail': {},
}

/** 上游 module 不发请求（本地拼 URL / 调第三方解锁），crypto 字段无意义。 */
const localModules = new Set(['/login/qr/create', '/song/url/match'])

function parseTable() {
  const text = fs.readFileSync(endpointSwift, 'utf8')
  const rows = []
  const re = /"(\/[^"]*)"\s*:\s*Endpoint\(\s*apiPath:\s*"([^"]*)"\s*,\s*crypto:\s*\.(\w+)/g
  let m
  while ((m = re.exec(text))) rows.push({ route: m[1], apiPath: m[2], crypto: m[3] })
  if (rows.length === 0) throw new Error('没能从 NeteaseEndpoint.swift 解析出任何路由')
  return rows
}

function moduleFileFor(route) {
  const base = route.replace(/^\//, '').replace(/\//g, '_')
  const candidate = path.join(apiDir, 'module', base + '.js')
  return fs.existsSync(candidate) ? candidate : null
}

function resolveCrypto(options) {
  const raw = (options && options.crypto) || ''
  if (raw === '') return APP_CONF.encrypt ? 'eapi' : 'api'
  return raw
}

async function probe(route) {
  const file = moduleFileFor(route)
  if (!file) {
    return {
      route,
      error: `helper 没有这条路由（api/module/${route.replace(/^\//, '').replace(/\//g, '_')}.js 不存在，server.js:78 是拿文件名推路由的）—— 调用它在 macOS 上是 404`,
    }
  }
  let mod
  try {
    delete require.cache[require.resolve(file)]
    mod = require(file)
  } catch (error) {
    return { route, error: `require 失败：${error.message}` }
  }
  const calls = []
  const stub = async (uri, data, options) => {
    calls.push({ uri, crypto: resolveCrypto(options), data })
    return { status: 200, body: {}, cookie: [] }
  }
  try {
    await mod(queries[route] || {}, stub)
  } catch (error) {
    if (calls.length === 0) return { route, error: `module 抛错：${error.message}` }
  }
  if (calls.length === 0) return { route, local: true }
  return { route, calls }
}

function main() {
  const rows = parseTable()
  const problems = []
  const lines = []

  Promise.all(rows.map((row) => probe(row.route).then((r) => ({ ...row, ...r }))))
    .then((results) => {
      for (const r of results.sort((a, b) => a.route.localeCompare(b.route))) {
        if (r.error) {
          problems.push(`${r.route}: ${r.error}`)
          continue
        }
        if (r.local) {
          const mark = localModules.has(r.route) ? 'OK ' : '?? '
          if (!localModules.has(r.route)) problems.push(`${r.route}: 上游不发请求，但登记表当成网络路由`)
          lines.push(`${mark}${r.route}\n     LOCAL（module 不调用 request）`)
          continue
        }
        for (const call of r.calls) {
          // apiPath 里的 `{id}` 之类是占位符，由调用方替换 —— 只校验模板前缀
          const templated = r.apiPath.includes('{')
          const uriOk = templated
            ? call.uri.startsWith(r.apiPath.slice(0, r.apiPath.indexOf('{')))
            : call.uri === r.apiPath
          const cryptoOk = call.crypto === r.crypto
          if (!uriOk) problems.push(`${r.route}: apiPath 登记 ${r.apiPath}，上游实际 ${call.uri}`)
          if (!cryptoOk) problems.push(`${r.route}: crypto 登记 .${r.crypto}，上游实际 .${call.crypto}`)
          const flag = uriOk && cryptoOk ? 'OK ' : 'BAD'
          lines.push(
            `${flag}${r.route}\n     uri=${call.uri} crypto=${call.crypto}\n     data=${JSON.stringify(call.data)}`
          )
        }
      }

      console.log(lines.join('\n'))
      console.log('')
      if (problems.length) {
        console.error(`不一致 ${problems.length} 处：`)
        for (const p of problems) console.error('  - ' + p)
        process.exit(1)
      }
      console.log(`全部 ${rows.length} 条路由与上游 module 一致。`)
    })
    .catch((error) => {
      console.error(error)
      process.exit(1)
    })
}

main()
