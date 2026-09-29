#!/usr/bin/env node
const fs = require('fs')
const path = require('path')
const tmpPath = require('os').tmpdir()

// ClearTone: 监控父进程，父进程退出时自动退出
const parentPid = process.ppid
setInterval(() => {
  try {
    process.kill(parentPid, 0) // 检测父进程是否存活
  } catch (e) {
    console.log('Parent process exited, shutting down helper')
    process.exit(0)
  }
}, 2000)

async function start() {
  // 检测是否存在 anonymous_token 文件,没有则生成
  if (!fs.existsSync(path.resolve(tmpPath, 'anonymous_token'))) {
    fs.writeFileSync(path.resolve(tmpPath, 'anonymous_token'), '', 'utf-8')
  }
  // 启动时刷新匿名 token 与 xeapi 公钥（内部含重试，失败会打日志）
  const generateConfig = require('./generateConfig')
  await generateConfig()

  const { constructServer } = require('./server')
  const port = Number(process.env.PORT || '3000')
  const host = process.env.HOST || '127.0.0.1'

  // ClearTone: 鉴权与 X-CT-Cookie 注入都在 `server.js` 的 `constructServer`
  // 里（必须注册在所有路由之前）。原先这里还有一个 `injectAuth(app)`，
  // 但它在 `constructServer()` **之后**才执行 —— 所有路由早已挂载完毕，
  // 命中的请求根本走不到它，属于彻底的死代码。
  // 留着它只会让人以为「改这里就能修 cookie 注入」，实际改了没有任何效果。
  constructServer().then((app) => {
    app.listen(port, host, () => {
      console.log(`ClearTone Helper listening on http://${host}:${port}`)
    })
  }).catch((err) => {
    console.error('Failed to start server:', err)
    process.exit(1)
  })
}
start()
