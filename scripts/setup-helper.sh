#!/bin/bash
# 下载并打包 Node.js 运行时 + NeteaseCloudMusicApiEnhanced
# 用于开发环境准备辅助进程

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RUNTIME_DIR="$PROJECT_DIR/ClearTone/Resources/HelperRuntime"
NODE_VERSION="22.23.4"
NODE_ARCH="arm64"
# 官方 SHASUMS256.txt 里 node-v22.23.4-darwin-arm64.tar.gz 的哈希。
# 下载后必须校验：只靠 HTTPS 无法防住镜像/上游被投毒，而 node 二进制
# 会以当前用户身份执行网络请求并解析远端数据。
NODE_SHA256="c9e1dbc748b33ed2d14f42445191ecaf14c56259c7a9a26d0042c49ec2b66428"

echo "=== ClearTone 辅助进程安装脚本 ==="
echo "目标目录: $RUNTIME_DIR"

# 创建目录
mkdir -p "$RUNTIME_DIR/bin"
mkdir -p "$RUNTIME_DIR/api"

# 1. 下载 Node.js
NODE_URL="https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-darwin-$NODE_ARCH.tar.gz"
NODE_TARBALL="/tmp/node-v$NODE_VERSION-darwin-$NODE_ARCH.tar.gz"

# 已存在的二进制也要校验版本：否则升级脚本里的 NODE_VERSION 只会影响
# 全新 clone，开发机上永远停留在首次安装的旧版本（包括已知漏洞版本）。
if [ ! -x "$RUNTIME_DIR/bin/node" ] \
    || [ "$("$RUNTIME_DIR/bin/node" --version 2>/dev/null)" != "v$NODE_VERSION" ]; then
    echo "下载 Node.js v$NODE_VERSION ($NODE_ARCH)..."
    curl -fL --retry 3 -o "$NODE_TARBALL" "$NODE_URL"
    echo "校验 SHA256..."
    echo "$NODE_SHA256  $NODE_TARBALL" | shasum -a 256 -c -
    echo "解压 Node.js..."
    tar -xzf "$NODE_TARBALL" -C /tmp/
    cp "/tmp/node-v$NODE_VERSION-darwin-$NODE_ARCH/bin/node" "$RUNTIME_DIR/bin/"
    chmod +x "$RUNTIME_DIR/bin/node"
    rm -rf "/tmp/node-v$NODE_VERSION-darwin-$NODE_ARCH"
    rm "$NODE_TARBALL"
    echo "Node.js 已安装到 $RUNTIME_DIR/bin/node"
else
    echo "Node.js v$NODE_VERSION 已存在，跳过下载"
fi

INSTALLED_NODE_VERSION="$("$RUNTIME_DIR/bin/node" --version 2>/dev/null || echo '未知')"
if [ "$INSTALLED_NODE_VERSION" != "v$NODE_VERSION" ]; then
    echo "错误：Node.js 版本不匹配（期望 v$NODE_VERSION，实际 $INSTALLED_NODE_VERSION）" >&2
    exit 1
fi

# 2. 取得 NeteaseCloudMusicApiEnhanced 的业务代码
API_DIR="/tmp/api-enhanced"
if [ ! -f "$RUNTIME_DIR/api/app.js" ]; then
    echo "克隆 NeteaseCloudMusicApiEnhanced..."
    if [ -d "$API_DIR" ]; then
        rm -rf "$API_DIR"
    fi
    git clone --depth 1 https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced.git "$API_DIR"
    echo "复制到 runtime 目录..."
    cp -r "$API_DIR"/* "$RUNTIME_DIR/api/"
    echo "清理..."
    rm -rf "$API_DIR"
else
    echo "API 已存在，跳过下载"
fi

# 2b. 安装依赖。**必须与上面那步解耦。**
#
# api/ 现在是入库的，所以全新 clone 里 `api/app.js` 一定存在 —— 原来把
# `npm install` 放在「app.js 不存在」的分支里，clone 出来的人永远走 else，
# node_modules 永远装不上。而它是硬依赖：app.js → server → module/* →
# util/request.js 会 require('axios') / ('crypto-js') / ('pac-proxy-agent')。
# 症状是 App 能开、界面正常，但辅助进程一起来就退，日志里是一串
# MODULE_NOT_FOUND。build-app.sh 的前置检查现在会拦下来。
# 每次都要跑：依赖版本由 package-lock 钉死，而安全修复也只会进 lock。
# 原先「node_modules 存在就跳过」会让已经装过依赖的开发机永远停留在旧版本，
# 包括带已知漏洞的传递依赖。
echo "安装 API 依赖（npm ci）..."
cd "$RUNTIME_DIR/api"
npm ci --omit=dev --ignore-scripts

# 3. 添加健康检查端点
cat > "$RUNTIME_DIR/api/ct_health.js" << 'EOF'
// 健康检查中间件，由主应用注入
// 在 app.js 之前加载或作为插件
module.exports = function(req, res, next) {
    if (req.path === '/ct_health') {
        const token = req.headers['x-ct-token'];
        const expectedToken = process.env.CT_AUTH_TOKEN;
        if (token && expectedToken && token === expectedToken) {
            res.status(200).json({ status: 'ok', timestamp: Date.now() });
        } else {
            res.status(401).json({ error: 'unauthorized' });
        }
        return;
    }
    next();
};
EOF

echo ""
echo "=== 安装完成 ==="
echo "辅助进程目录: $RUNTIME_DIR"
echo "Node 版本: $($RUNTIME_DIR/bin/node --version 2>/dev/null || echo '未安装')"
echo ""
echo "注意: 发布版本需要将 $RUNTIME_DIR 打包进 .app/Contents/Resources/"
