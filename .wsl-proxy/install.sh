#!/bin/bash
# install.sh - 安装/重装 wsl-proxy-sync 到系统
# 用法: sudo bash ~/.wsl-proxy/install.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then
    echo "错误: 请使用 sudo 运行" >&2
    echo "  sudo bash ${SCRIPT_DIR}/install.sh"
    exit 1
fi

install -m 755 "${SCRIPT_DIR}/wsl-proxy-sync.sh" /usr/local/bin/wsl-proxy-sync.sh
echo "✓ wsl-proxy-sync.sh 已安装到 /usr/local/bin/"
echo ""
echo "立即同步 hosts："
wsl-proxy-sync.sh sync-hosts
