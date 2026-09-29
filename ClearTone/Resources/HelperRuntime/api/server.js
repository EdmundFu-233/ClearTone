require('dotenv').config()
const crypto = require('crypto')
const fs = require('fs')
const path = require('path')
const express = require('express')
const request = require('./util/request')
const packageJSON = require('./package.json')
const exec = require('child_process').exec
const cache = require('./util/apicache').middleware
const { cookieToJson } = require('./util/index')
const fileUpload = require('express-fileupload')
const decode = require('safe-decode-uri-component')
const logger = require('./util/logger.js')
const { APP_CONF } = require('./util/config.json')

/**
 * The version check result.
 * @readonly
 * @enum {number}
 */
const VERSION_CHECK_RESULT = {
  FAILED: -1,
  NOT_LATEST: 0,
  LATEST: 1,
}

/**
 * @typedef {{
 *   identifier?: string,
 *   route: string,
 *   module: any
 * }} ModuleDefinition
 */

/**
 * @typedef {{
 *   port?: number,
 *   host?: string,
 *   checkVersion?: boolean,
 *   moduleDefs?: ModuleDefinition[]
 * }} NcmApiOptions
 */

/**
 * @typedef {{
 *   status: VERSION_CHECK_RESULT,
 *   ourVersion?: string,
 *   npmVersion?: string,
 * }} VersionCheckResult
 */

/**
 * @typedef {{
 *  server?: import('http').Server,
 * }} ExpressExtension
 */

/**
 * Get the module definitions dynamically.
 *
 * @param {string} modulesPath The path to modules (JS).
 * @param {Record<string, string>} [specificRoute] The specific route of specific modules.
 * @param {boolean} [doRequire] If true, require() the module directly.
 * Otherwise, print out the module path. Default to true.
 * @returns {Promise<ModuleDefinition[]>} The module definitions.
 *
 * @example getModuleDefinitions("./module", {"album_new.js": "/album/create"})
 */
async function getModulesDefinitions(
  modulesPath,
  specificRoute,
  doRequire = true,
) {
  const files = await fs.promises.readdir(modulesPath)
  const parseRoute = (/** @type {string} */ fileName) =>
    specificRoute && fileName in specificRoute
      ? specificRoute[fileName]
      : `/${fileName.replace(/\.js$/i, '').replace(/_/g, '/')}`

  const modules = files
    .reverse()
    .filter((file) => file.endsWith('.js'))
    .map((file) => {
      const identifier = file.split('.').shift()
      const route = parseRoute(file)
      const modulePath = path.join(modulesPath, file)
      const module = doRequire ? require(modulePath) : modulePath

      return { identifier, route, module }
    })

  return modules
}

/**
 * Check if the version of this API is latest.
 *
 * @returns {Promise<VersionCheckResult>} If true, this API is up-to-date;
 * otherwise, this API should be upgraded and you would
 * need to notify users to upgrade it manually.
 */
async function checkVersion() {
  return new Promise((resolve) => {
    exec('npm info NeteaseCloudMusicApiEnhanced version', (err, stdout) => {
      if (!err) {
        let version = stdout.trim()

        /**
         * @param {VERSION_CHECK_RESULT} status
         */
        const resolveStatus = (status) =>
          resolve({
            status,
            ourVersion: packageJSON.version,
            npmVersion: version,
          })

        resolveStatus(
          packageJSON.version < version
            ? VERSION_CHECK_RESULT.NOT_LATEST
            : VERSION_CHECK_RESULT.LATEST,
        )
      } else {
        resolve({
          status: VERSION_CHECK_RESULT.FAILED,
        })
      }
    })
  })
}

function parseCorsAllowOrigins(corsAllowOrigin) {
  if (!corsAllowOrigin) {
    return null
  }

  const origins = corsAllowOrigin
    .split(',')
    .map((origin) => origin.trim())
    .filter(Boolean)

  return origins.length > 0 ? origins : null
}

function getCorsAllowOrigin(allowOrigins, requestOrigin) {
  if (!allowOrigins) {
    return requestOrigin || '*'
  }

  if (allowOrigins.includes('*')) {
    return '*'
  }

  if (requestOrigin && allowOrigins.includes(requestOrigin)) {
    return requestOrigin
  }

  return null
}

function createConsoleSpinner(message = '启动中') {
  if (!process.stdout.isTTY) {
    return {
      stop() {},
    }
  }

  const frames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']
  let index = 0
  process.stdout.write(`${frames[index]} ${message}...`)
  const timer = setInterval(() => {
    index = (index + 1) % frames.length
    process.stdout.write(`\r${frames[index]} ${message}...`)
  }, 80)

  return {
    stop() {
      clearInterval(timer)
      process.stdout.write(`\r✔ ${message} 完成。\n`)
    },
  }
}

/**
 * Construct the server of NCM API.
 *
 * @param {ModuleDefinition[]} [moduleDefs] Customized module definitions [advanced]
 * @returns {Promise<import("express").Express>} The server instance.
 */
async function constructServer(moduleDefs) {
  const app = express()
  const { CORS_ALLOW_ORIGIN } = process.env
  const allowOrigins = parseCorsAllowOrigins(CORS_ALLOW_ORIGIN)
  app.set('trust proxy', true)

  // ClearTone 鉴权中间件：必须在所有路由之前
  //
  // 只做两件事：校验 X-CT-Token、把 X-CT-Cookie 暂存到 `req.ctCookie`。
  //
  // **注入 query/body 的一步被刻意去掉了**（ClearTone 改动）：
  //   - `req.query` 在 Express 5 里是每次访问都重算的 getter，
  //     `req.query.cookie = x` 写的是一个用完即弃的对象，从来没生效过；
  //   - `req.body` 那条当时"能用"纯属侥幸：本中间件跑在 body-parser **之前**，
  //     `req.body` 此刻是 undefined，于是 `req.body = req.body || {}` 新建了一个
  //     带 cookie 的 `{}`；而 body-parser 的 read.js 遇到**空 body** 时直接
  //     `next()` 不覆盖它，cookie 就这样活了下来。
  //     一旦 App 改成带 body 的 POST，read.js 就会用解析结果整个替换 req.body，
  //     cookie 被静默丢弃 → 所有请求变匿名 → 写接口一律回 301。
  // 现在改成把 cookie 放在 request 自己的属性上，由下面的路由处理器统一取，
  // 与 body 有没有内容彻底解耦。
  const expectedToken = process.env.CT_AUTH_TOKEN
  if (expectedToken) {
    app.use((req, res, next) => {
      if (req.path === '/ct_health') {
        const token = req.headers['x-ct-token']
        if (token === expectedToken) {
          return res.status(200).json({ status: 'ok', timestamp: Date.now() })
        }
        return res.status(401).json({ error: 'unauthorized' })
      }

      const token = req.headers['x-ct-token']
      if (token !== expectedToken) {
        return res.status(401).json({ error: 'unauthorized' })
      }

      // 登录相关接口（扫码轮询等）必须实时，禁止缓存
      // 否则 QR 状态（801/802/803）会被 apicache 按 URL 缓存 2 分钟，导致扫码后永远读不到最新状态
      if (req.path === '/login' || req.path.startsWith('/login/')) {
        req.headers['x-apicache-bypass'] = 'true'
      }

      // 从 X-CT-Cookie 取网易云 cookie，交给路由处理器注入 query
      req.ctCookie = req.headers['x-ct-cookie'] || ''
      next()
    })
  }

  /**
   * Serving static files
   */
  app.use(express.static(path.join(__dirname, 'public')))
  /**
   * CORS & Preflight request
   */
  app.use((req, res, next) => {
    if (req.path !== '/' && !req.path.includes('.')) {
      const corsAllowOrigin = getCorsAllowOrigin(
        allowOrigins,
        req.headers.origin,
      )
      const shouldSetVaryHeader = corsAllowOrigin && corsAllowOrigin !== '*'
      res.set({
        'Access-Control-Allow-Credentials': true,
        ...(corsAllowOrigin
          ? { 'Access-Control-Allow-Origin': corsAllowOrigin }
          : {}),
        ...(shouldSetVaryHeader ? { Vary: 'Origin' } : {}),
        'Access-Control-Allow-Headers': 'X-Requested-With,Content-Type',
        'Access-Control-Allow-Methods': 'PUT,POST,GET,DELETE,OPTIONS',
        'Content-Type': 'application/json; charset=utf-8',
      })
    }
    req.method === 'OPTIONS' ? res.status(204).end() : next()
  })

  /**
   * Cookie Parser
   */
  app.use((req, _, next) => {
    req.cookies = {}
    //;(req.headers.cookie || '').split(/\s*;\s*/).forEach((pair) => { //  Polynomial regular expression //
    ;(req.headers.cookie || '').split(/;\s+|(?<!\s)\s+$/g).forEach((pair) => {
      let crack = pair.indexOf('=')
      if (crack < 1 || crack == pair.length - 1) return
      req.cookies[decode(pair.slice(0, crack)).trim()] = decode(
        pair.slice(crack + 1),
      ).trim()
    })
    next()
  })

  /**
   * Body Parser and File Upload
   */
  const MAX_UPLOAD_SIZE_MB = 500
  const MAX_UPLOAD_SIZE_BYTES = MAX_UPLOAD_SIZE_MB * 1024 * 1024

  app.use(express.json({ limit: `${MAX_UPLOAD_SIZE_MB}mb` }))
  app.use(
    express.urlencoded({ extended: false, limit: `${MAX_UPLOAD_SIZE_MB}mb` }),
  )

  app.use(
    fileUpload({
      limits: {
        fileSize: MAX_UPLOAD_SIZE_BYTES,
      },
      useTempFiles: true,
      tempFileDir: require('os').tmpdir(),
      abortOnLimit: true,
      parseNested: true,
    }),
  )

  /**
   * Cache
   *
   * ClearTone 改动（两处，都是必须的）：
   *
   * 1. **只缓存 GET。** 这份 apicache 是 vendored 的老版本，全文没有
   *    `req.method` 过滤，于是 POST 的 200 响应也会被存下来并在 2 分钟内
   *    重放 —— 表现是「点收藏没反应」「刚建的歌单不出现」。
   * 2. **缓存键带上账号。** 默认键是
   *    `hostname + originalUrl + JSON.stringify(req.cookies)`，而
   *    `req.cookies` 解析自 `Cookie:` 请求头，ClearTone 从不发这个头
   *    （凭据走 `X-CT-Cookie`），所以键里恒为 `{}` —— 切账号后
   *    `/user/account`、`/recommend/songs` 会命中**上一个账号**的缓存。
   *    这里用 cookie 的哈希做后缀区分，不把凭据本身写进键
   *    （键会进 debug 日志）。
   */
  app.use(
    cache(
      '2 minutes',
      (req, res) => req.method === 'GET' && res.statusCode === 200,
      // 第三个参数是 localOptions（不是另一个时长）：
      // `appendKey` 可以是函数，用它的返回值给缓存键加后缀。
      { appendKey: (req) => {
          const ctCookie = req.headers['x-ct-cookie'] || ''
          if (!ctCookie) return 'anon'
          return crypto.createHash('sha256').update(ctCookie).digest('hex').slice(0, 16)
        } },
    ),
  )

  /**
   * Special Routers
   */
  const special = {
    'daily_signin.js': '/daily_signin',
    'fm_trash.js': '/fm_trash',
    'personal_fm.js': '/personal_fm',
  }

  /**
   * Load every modules in this directory
   */
  const moduleDefinitions =
    moduleDefs ||
    (await getModulesDefinitions(path.join(__dirname, 'module'), special))

  for (const moduleDef of moduleDefinitions) {
    // Register the route.
    app.all(moduleDef.route, async (req, res) => {
      // X-CT-Cookie 在鉴权中间件里存到了 req.ctCookie（见上面的说明）。
      //
      // 这里**必须先拷一份**再注入：`req.query` 在 Express 5 里是每次访问
      // 都重新解析 URL 的 getter（lib/request.js:217 `defineGetter`），
      // 直接 `req.query.cookie = x` 写的是一个用完即弃的对象，从来没生效过。
      // 旧代码里真正起作用的是 `req.body` 那条，而它依赖「body 恰好是空的」
      // 这个偶然条件：一旦 App 发带 body 的 POST，body-parser 就会整个替换
      // req.body，cookie 被静默丢弃 → 所有请求变匿名 → 写接口一律回 301。
      const rawQuery = Object.assign({}, req.query)
      if (req.ctCookie) {
        rawQuery.cookie = req.ctCookie
      }
      ;[rawQuery, req.body].forEach((item) => {
        // item may be undefined (some environments / middlewares).
        // Guard access to avoid "Cannot read properties of undefined (reading 'cookie')".
        if (item && typeof item.cookie === 'string') {
          item.cookie = cookieToJson(decode(item.cookie))
        }
      })

      let query = Object.assign(
        {},
        { cookie: req.cookies },
        rawQuery,
        req.body,
        req.files,
      )

      try {
        let usedCrypto = ''
        const moduleResponse = await moduleDef.module(query, (...params) => {
          const obj = [...params]
          const options = obj[2] || {}
          usedCrypto = options.crypto || ''
          let ip = ''

          if (options.randomCNIP) {
            ip = global.cnIp
          } else {
            ip = req.ip

            if (ip.substring(0, 7) == '::ffff:') {
              ip = ip.substring(7)
            }
            // 本机回环地址（桌面端经 127.0.0.1 访问辅助进程）不是有效客户端 IP，
            // 透传给网易云会被风控判定为"设备环境异常"（扫码登录即报错、二维码秒失效），
            // 因此与 ::1 一样回退为随机中国 IP
            if (
              ip == '::1' ||
              ip == 'localhost' ||
              ip.startsWith('127.') ||
              ip.startsWith('::ffff:127.')
            ) {
              ip = global.cnIp
            }
          }

          obj[2] = {
            ...options,
            ip,
          }

          return request(...obj)
        })
        const displayCrypto = usedCrypto || (APP_CONF.encrypt ? 'eapi' : 'api')
        logger.info(
          `Request Success: [${displayCrypto}] ${decode(req.originalUrl)}`,
        )

        // 夹带私货部分：如果开启了通用解锁，并且是获取歌曲URL的接口，则尝试解锁（如果需要的话）ヾ(≧▽≦*)o
        if (
          req.baseUrl === '/song/url/v1' &&
          process.env.ENABLE_GENERAL_UNBLOCK === 'true'
        ) {
          const song = moduleResponse.body.data[0]
          if (
            song.freeTrialInfo !== null ||
            !song.url ||
            [1, 4].includes(song.fee)
          ) {
            const {
              matchID,
            } = require('@neteasecloudmusicapienhanced/unblockmusic-utils')
            logger.info('Starting unblock(uses general unblock):', req.query.id)
            const result = await matchID(req.query.id)
            song.url = result.data.url
            song.freeTrialInfo = null
            logger.info('Unblock success! url:', song.url)
          }
          if (song.url && song.url.includes('kuwo')) {
            const proxy = process.env.PROXY_URL
            const useProxy = process.env.ENABLE_PROXY || 'false'
            if (useProxy === 'true' && proxy) {
              song.proxyUrl = proxy + song.url
            }
          }
        }

        const cookies = moduleResponse.cookie
        if (!query.noCookie) {
          if (Array.isArray(cookies) && cookies.length > 0) {
            if (req.protocol === 'https') {
              // Try to fix CORS SameSite Problem
              res.append(
                'Set-Cookie',
                cookies.map((cookie) => {
                  return cookie + '; SameSite=None; Secure'
                }),
              )
            } else {
              res.append('Set-Cookie', cookies)
            }
          }
        }
        if (moduleResponse.redirectUrl) {
          res.redirect(moduleResponse.status || 302, moduleResponse.redirectUrl)
          return
        }

        res.status(moduleResponse.status).send(moduleResponse.body)
      } catch (/** @type {*} */ moduleResponse) {
        logger.error(`${decode(req.originalUrl)}`, {
          status: moduleResponse.status,
          body: moduleResponse.body,
        })
        if (!moduleResponse.body) {
          res.status(404).send({
            code: 404,
            data: null,
            msg: 'Not Found',
          })
          return
        }
        if (moduleResponse.body.code == '301')
          moduleResponse.body.msg = '需要登录'
        if (!query.noCookie) {
          res.append('Set-Cookie', moduleResponse.cookie)
        }

        res.status(moduleResponse.status).send(moduleResponse.body)
      }
    })
  }

  return app
}

/**
 * Serve the NCM API.
 * @param {NcmApiOptions} options
 * @returns {Promise<import('express').Express & ExpressExtension>}
 */
async function serveNcmApi(options) {
  const port = Number(options.port || process.env.PORT || '3000')
  const host = options.host || process.env.HOST || ''

  const spinner = createConsoleSpinner('服务启动中')

  const checkVersionSubmission =
    options.checkVersion &&
    checkVersion().then(({ npmVersion, ourVersion, status }) => {
      if (status == VERSION_CHECK_RESULT.NOT_LATEST) {
        logger.warn(
          `最新版本: ${npmVersion}, 当前版本: ${ourVersion}, 请及时更新`,
        )
      }
    })
  const constructServerSubmission = constructServer(options.moduleDefs)

  const [_, app] = await Promise.all([
    checkVersionSubmission,
    constructServerSubmission,
  ])

  spinner.stop()

  /** @type {import('express').Express & ExpressExtension} */
  const appExt = app
  appExt.server = app.listen(port, host, () => {
    console.log(`
  ╔═╗╔═╗╦    ╔═╗╔╗╔╦ ╦╔═╗╔╗╔╔═╗╔═╗╔╦╗
  ╠═╣╠═╝║    ║╣ ║║║╠═╣╠═╣║║║║  ║╣  ║║
  ╩ ╩╩  ╩    ╚═╝╝╚╝╩ ╩╩ ╩╝╚╝╚═╝╚═╝═╩╝
    `)
    logger.info(
      `Server started successfully @ http://${host ? host : 'localhost'}:${port}`,
    )
  })

  return appExt
}

module.exports = {
  serveNcmApi,
  getModulesDefinitions,
  constructServer,
}
