#!/bin/bash
# UniClaudeProxy 一键启动脚本
# 自动检查并启动 CodeBuddy 代理和 UniClaudeProxy

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEBUDDY_PROXY_URL="http://127.0.0.1:8789"
UNICLAUDE_PORT=9223

echo "🚀 启动 UniClaudeProxy..."

# 1. 检查 CodeBuddy 代理是否运行
echo "📡 检查 CodeBuddy 代理 ($CODEBUDDY_PROXY_URL)..."
if curl -s "$CODEBUDDY_PROXY_URL/v1/models" > /dev/null 2>&1; then
    echo "   ✅ CodeBuddy 代理已运行"
else
    echo "   ⚠️ CodeBuddy 代理未运行，尝试启动..."
    cd ~/code/wesee/ai-scripts
    if [ -f "./cproxy.sh" ]; then
        ./cproxy.sh &
        sleep 2
        if curl -s "$CODEBUDDY_PROXY_URL/v1/models" > /dev/null 2>&1; then
            echo "   ✅ CodeBuddy 代理启动成功"
        else
            echo "   ❌ CodeBuddy 代理启动失败，请手动检查"
            exit 1
        fi
    else
        echo "   ❌ 找不到 cproxy.sh，请手动启动 CodeBuddy 代理"
        exit 1
    fi
fi

# 2. 检查虚拟环境
echo "🐍 检查 Python 环境..."
cd "$SCRIPT_DIR"
if [ ! -d ".venv" ]; then
    echo "   📦 创建虚拟环境..."
    python3 -m venv .venv
fi

# 3. 激活环境并启动
echo "🎯 启动 UniClaudeProxy (端口 $UNICLAUDE_PORT)..."
source .venv/bin/activate

# 检查依赖
if ! python3 -c "import fastapi" 2>/dev/null; then
    echo "   📦 安装依赖..."
    pip install -r requirements.txt
fi

echo ""
echo "✨ UniClaudeProxy 已启动！"
echo "   地址: http://127.0.0.1:$UNICLAUDE_PORT"
echo ""
echo "使用方式:"
echo "   ANTHROPIC_BASE_URL=http://127.0.0.1:$UNICLAUDE_PORT claude"
echo ""

python3 -m uvicorn app.main:app --host 127.0.0.1 --port $UNICLAUDE_PORT
