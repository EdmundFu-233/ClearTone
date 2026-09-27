#!/bin/bash
# 下载并打包 Node.js 运行时 + NeteaseCloudMusicApiEnhanced
# 用于开发环境准备辅助进程

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RUNTIME_DIR="$PROJECT_DIR/ClearTone/Resources/HelperRuntime"
NODE_VERSION="22.14.0"
NODE_ARCH="arm64"

echo "=== ClearTone 辅助进程安装脚本 ==="
echo "目标目录: $RUNTIME_DIR"

# 创建目录
mkdir -p "$RUNTIME_DIR/bin"
mkdir -p "$RUNTIME_DIR/api"

# 1. 下载 Node.js
NODE_URL="https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-darwin-$NODE_ARCH.tar.gz"
NODE_TARBALL="/tmp/node-v$NODE_VERSION-darwin-$NODE_ARCH.tar.gz"

if [ ! -f "$RUNTIME_DIR/bin/node" ]; then
    echo "下载 Node.js v$NODE_VERSION ($NODE_ARCH)..."
    curl -L -o "$NODE_TARBALL" "$NODE_URL"
    echo "解压 Node.js..."
    tar -xzf "$NODE_TARBALL" -C /tmp/
    cp "/tmp/node-v$NODE_VERSION-darwin-$NODE_ARCH/bin/node" "$RUNTIME_DIR/bin/"
    chmod +x "$RUNTIME_DIR/bin/node"
    rm -rf "/tmp/node-v$NODE_VERSION-darwin-$NODE_ARCH"
    rm "$NODE_TARBALL"
    echo "Node.js 已安装到 $RUNTIME_DIR/bin/node"
else
    echo "Node.js 已存在，跳过下载"
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
# util/request.js 会 require('axios') / ('crypto-js') / ('node-forge')。
# 症状是 App 能开、界面正常，但辅助进程一起来就退，日志里是一串
# MODULE_NOT_FOUND。build-app.sh 的前置检查现在会拦下来。
if [ ! -d "$RUNTIME_DIR/api/node_modules" ]; then
    echo "安装 API 依赖（npm ci）..."
    cd "$RUNTIME_DIR/api"
    npm ci --omit=dev --ignore-scripts
else
    echo "API 依赖已存在，跳过安装"
fi

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
