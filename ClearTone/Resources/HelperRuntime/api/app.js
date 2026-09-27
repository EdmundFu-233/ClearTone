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

// ClearTone 鉴权中间件：仅接受携带正确 token 的回环请求
function injectAuth(app) {
  const expectedToken = process.env.CT_AUTH_TOKEN
  if (!expectedToken) return

  app.use((req, res, next) => {
    // 健康检查端点
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

    // 从 X-CT-Cookie 注入网易云 cookie（辅助进程转发到网易云）
    const ctCookie = req.headers['x-ct-cookie']
    if (ctCookie) {
      req.query.cookie = ctCookie
      req.body = req.body || {}
      req.body.cookie = ctCookie
    }
    next()
  })
}

async function start() {
  // 检测是否存在 anonymous_token 文件,没有则生成
  if (!fs.existsSync(path.resolve(tmpPath, 'anonymous_token'))) {
    fs.writeFileSync(path.resolve(tmpPath, 'anonymous_token'), '', 'utf-8')
  }
  // 启动时更新anonymous_token
  const generateConfig = require('./generateConfig')
  await generateConfig()

  // 使用 constructServer 手动构建，以便注入中间件
  const { constructServer } = require('./server')
  const port = Number(process.env.PORT || '3000')
  const host = process.env.HOST || '127.0.0.1'

  constructServer().then((app) => {
    injectAuth(app)
    app.listen(port, host, () => {
      console.log(`ClearTone Helper listening on http://${host}:${port}`)
    })
  }).catch((err) => {
    console.error('Failed to start server:', err)
    process.exit(1)
  })
}
start()
