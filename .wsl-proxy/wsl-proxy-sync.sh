#!/bin/bash
# wsl-proxy-sync.sh - 同步 Windows 系统代理设置到 WSL
# 用法: wsl-proxy-sync.sh [--port <端口>] [--server <host:port>] <enable|disable|docker-enable|docker-disable|status>

set -euo pipefail

# ─── 配置 ────────────────────────────────────────────────────────────────────
# 内置默认代理服务器（优先级最低）
_BUILTIN_DEFAULT_PROXY_SERVER="127.0.0.1:7993"

# 配置文件路径（优先级次之）
CONFIG_FILE="${HOME}/.wsl-proxy.conf"

# 从配置文件加载 DEFAULT_PROXY_SERVER（若存在且设置了 PROXY_SERVER）
DEFAULT_PROXY_SERVER="${_BUILTIN_DEFAULT_PROXY_SERVER}"
if [ -f "${CONFIG_FILE}" ]; then
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"
    # 配置文件中可用 PROXY_SERVER=host:port 覆盖默认值
    DEFAULT_PROXY_SERVER="${PROXY_SERVER:-${DEFAULT_PROXY_SERVER}}"
fi

# ─── 解析全局参数（--port / --server，优先级最高）────────────────────────────
_parse_global_opts() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --port)
                shift
                # 只替换端口，保留主机部分
                local host
                host=$(echo "${DEFAULT_PROXY_SERVER}" | cut -d: -f1)
                DEFAULT_PROXY_SERVER="${host}:${1}"
                shift
                ;;
            --server)
                shift
                DEFAULT_PROXY_SERVER="${1}"
                shift
                ;;
            *)
                shift
                ;;
        esac
    done
}
_parse_global_opts "$@"

WINDOWS_HOSTS="/mnt/c/Windows/System32/drivers/etc/hosts"

# 固定不走代理的地址段
NO_PROXY_BASE="localhost,127.0.0.1,192.168.*,172.16.0.0/12,10.*,*.local,*360buyimg.com,100ime-iat-api.xfyun.cn,*jd.com,*zhimg.com,*zhihu.com"

# 从 Windows hosts 动态读取本地域名（127.0.0.1 / 0.0.0.0 开头，排除系统默认条目）
build_no_proxy() {
    local hosts_domains=""
    if [ -f "${WINDOWS_HOSTS}" ]; then
        hosts_domains=$(grep -v '^#' "${WINDOWS_HOSTS}" \
            | grep -v '^$' \
            | grep -E '^(127\.0\.0\.1|0\.0\.0\.0)\s' \
            | awk '{print $2}' \
            | grep -vE '^(localhost|ip6-localhost|ip6-loopback|ip6-allnodes|ip6-allrouters|ip6-localnet|ip6-mcastprefix)$' \
            | tr '\n' ',' \
            | sed 's/,$//')
    fi
    if [ -n "${hosts_domains}" ]; then
        echo "${NO_PROXY_BASE},${hosts_domains}"
    else
        echo "${NO_PROXY_BASE}"
    fi
}

ENV_FILE="/etc/environment"
WSL_HOSTS="/etc/hosts"
APT_PROXY_CONF="/etc/apt/apt.conf.d/99proxy"
DOCKER_DROP_IN_DIR="/etc/systemd/system/docker.service.d"
DOCKER_PROXY_CONF="${DOCKER_DROP_IN_DIR}/proxy.conf"
LOG_TAG="wsl-proxy"
# 标记注入块的边界，方便精准清除
HOSTS_MARK_BEGIN="# >>> wsl-proxy: Windows hosts sync begin <<<"
HOSTS_MARK_END="# >>> wsl-proxy: Windows hosts sync end <<<"

# 从 Windows hosts 提取自定义条目并写入 WSL /etc/hosts
sync_hosts() {
    # 先清除上次注入的块
    clear_hosts

    local entries
    entries=$(grep -v '^#' "${WINDOWS_HOSTS}" \
        | grep -v '^$' \
        | grep -E '^(127\.0\.0\.1|0\.0\.0\.0)\s' \
        | grep -vE '\s(localhost|ip6-localhost|ip6-loopback|ip6-allnodes|ip6-allrouters|ip6-localnet|ip6-mcastprefix)$')

    if [ -z "${entries}" ]; then
        echo "[wsl-proxy] Windows hosts 中无自定义条目，跳过同步"
        return
    fi

    {
        echo ""
        echo "${HOSTS_MARK_BEGIN}"
        echo "${entries}"
        echo "${HOSTS_MARK_END}"
    } >> "${WSL_HOSTS}"

    local count
    count=$(echo "${entries}" | wc -l)
    echo "[wsl-proxy] ✓ /etc/hosts 已同步 ${count} 条 Windows hosts 条目"
    echo "${entries}" | awk '{printf "  %s → %s\n", $1, $2}'
}

# 清除 WSL /etc/hosts 中由 wsl-proxy 注入的块
clear_hosts() {
    if grep -q "${HOSTS_MARK_BEGIN}" "${WSL_HOSTS}" 2>/dev/null; then
        sed -i "/${HOSTS_MARK_BEGIN}/,/${HOSTS_MARK_END}/d" "${WSL_HOSTS}"
        # 清除可能残留的空行
        sed -i '/^$/N;/^\n$/d' "${WSL_HOSTS}"
        echo "[wsl-proxy] ✓ /etc/hosts 中的 Windows hosts 条目已清除"
    fi
}
# ─────────────────────────────────────────────────────────────────────────────

# 必须以 root 运行
if [ "$(id -u)" -ne 0 ]; then
    echo "[wsl-proxy] 错误: 请使用 sudo 运行此脚本" >&2
    exit 1
fi

do_enable() {
    local server="${1:-$DEFAULT_PROXY_SERVER}"
    local proxy_url="http://${server}"
    local no_proxy
    no_proxy=$(build_no_proxy)

    echo "[wsl-proxy] 正在启用代理: ${proxy_url}"
    echo "[wsl-proxy] no_proxy: ${no_proxy}"

    # 1. /etc/environment：删除旧代理行，追加新配置
    sed -i '/^http_proxy\|^https_proxy\|^HTTP_PROXY\|^HTTPS_PROXY\|^no_proxy\|^NO_PROXY/d' "${ENV_FILE}"
    cat >> "${ENV_FILE}" <<EOF
http_proxy=${proxy_url}
https_proxy=${proxy_url}
HTTP_PROXY=${proxy_url}
HTTPS_PROXY=${proxy_url}
no_proxy=${no_proxy}
NO_PROXY=${no_proxy}
EOF
    echo "[wsl-proxy] ✓ /etc/environment 已更新"

    # 2. apt 代理
    cat > "${APT_PROXY_CONF}" <<EOF
Acquire::http::Proxy "${proxy_url}";
Acquire::https::Proxy "${proxy_url}";
EOF
    echo "[wsl-proxy] ✓ apt 代理已配置 (${APT_PROXY_CONF})"

    # 3. Docker daemon 代理
    mkdir -p "${DOCKER_DROP_IN_DIR}"
    cat > "${DOCKER_PROXY_CONF}" <<EOF
[Service]
Environment="HTTP_PROXY=${proxy_url}"
Environment="HTTPS_PROXY=${proxy_url}"
Environment="NO_PROXY=${no_proxy}"
EOF
    systemctl daemon-reload
    systemctl restart docker
    echo "[wsl-proxy] ✓ Docker 代理已配置并重启"

    # 4. 同步 Windows hosts → WSL /etc/hosts
    sync_hosts

    logger -t "${LOG_TAG}" "ENABLED: ${proxy_url}"
    echo "[wsl-proxy] 代理启用完成"
}

do_disable() {
    echo "[wsl-proxy] 正在关闭代理..."

    # 1. 清除 /etc/environment 代理行
    sed -i '/^http_proxy\|^https_proxy\|^HTTP_PROXY\|^HTTPS_PROXY\|^no_proxy\|^NO_PROXY/d' "${ENV_FILE}"
    echo "[wsl-proxy] ✓ /etc/environment 代理行已清除"

    # 2. 删除 apt 代理
    if [ -f "${APT_PROXY_CONF}" ]; then
        rm -f "${APT_PROXY_CONF}"
        echo "[wsl-proxy] ✓ apt 代理配置已删除"
    fi

    # 3. 删除 Docker 代理并重启
    if [ -f "${DOCKER_PROXY_CONF}" ]; then
        rm -f "${DOCKER_PROXY_CONF}"
        systemctl daemon-reload
        systemctl restart docker
        echo "[wsl-proxy] ✓ Docker 代理配置已删除并重启"
    fi

    logger -t "${LOG_TAG}" "DISABLED"
    echo "[wsl-proxy] 代理关闭完成"
}

do_docker_enable() {
    local server="${1:-$DEFAULT_PROXY_SERVER}"
    local proxy_url="http://${server}"
    local no_proxy
    no_proxy=$(build_no_proxy)

    echo "[wsl-proxy] 正在为 Docker 启用代理: ${proxy_url}"
    echo "[wsl-proxy] no_proxy: ${no_proxy}"

    # 1. 仅写入 no_proxy 到 /etc/environment（不写 http_proxy/https_proxy，不影响 shell 代理）
    sed -i '/^no_proxy\|^NO_PROXY/d' "${ENV_FILE}"
    cat >> "${ENV_FILE}" <<EOF
no_proxy=${no_proxy}
NO_PROXY=${no_proxy}
EOF
    echo "[wsl-proxy] ✓ /etc/environment no_proxy 已更新（重开终端生效）"

    # 2. Docker daemon 代理
    mkdir -p "${DOCKER_DROP_IN_DIR}"
    cat > "${DOCKER_PROXY_CONF}" <<EOF
[Service]
Environment="HTTP_PROXY=${proxy_url}"
Environment="HTTPS_PROXY=${proxy_url}"
Environment="NO_PROXY=${no_proxy}"
EOF
    systemctl daemon-reload
    systemctl restart docker
    echo "[wsl-proxy] ✓ Docker 代理已配置并重启"

    # 3. 同步 Windows hosts → WSL /etc/hosts
    sync_hosts

    logger -t "${LOG_TAG}" "DOCKER ENABLED: ${proxy_url}"
    echo "[wsl-proxy] ✓ docker-enable 完成"
}

do_docker_disable() {
    echo "[wsl-proxy] 正在为 Docker 关闭代理..."

    # 1. 若 /etc/environment 中没有 http_proxy（即非 enable 模式），清除 no_proxy
    if ! grep -q '^http_proxy' "${ENV_FILE}" 2>/dev/null; then
        sed -i '/^no_proxy\|^NO_PROXY/d' "${ENV_FILE}"
        echo "[wsl-proxy] ✓ /etc/environment no_proxy 已清除"
    fi

    # 2. 删除 Docker 代理并重启
    if [ -f "${DOCKER_PROXY_CONF}" ]; then
        rm -f "${DOCKER_PROXY_CONF}"
        systemctl daemon-reload
        systemctl restart docker
        logger -t "${LOG_TAG}" "DOCKER DISABLED"
        echo "[wsl-proxy] ✓ Docker 代理配置已删除并重启"
    else
        echo "[wsl-proxy] Docker 代理本身未配置，无需操作"
    fi
}

do_status() {
    echo "========================================"
    echo "        WSL Proxy 状态总览"
    echo "========================================"

    # 显示动态 no_proxy 预览
    echo "── no_proxy 预览（下次 enable 时生效）──"
    build_no_proxy | tr ',' '\n' | sed 's/^/  /'
    echo ""

    # Windows 注册表状态
    local reg_enable reg_server
    reg_enable=$(reg.exe query \
        "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings" \
        /v ProxyEnable 2>/dev/null | awk '/ProxyEnable/{print $NF}') || reg_enable="(读取失败)"
    reg_server=$(reg.exe query \
        "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings" \
        /v ProxyServer 2>/dev/null | awk '/ProxyServer/{print $NF}') || reg_server="(读取失败)"

    if [ "${reg_enable}" = "0x1" ]; then
        echo "  Windows 系统代理 : ✓ 开启  (${reg_server})"
    else
        echo "  Windows 系统代理 : ✗ 关闭"
    fi
    echo ""

    # /etc/environment
    echo "── /etc/environment ─────────────────────"
    if grep -qE 'http_proxy|HTTP_PROXY' "${ENV_FILE}" 2>/dev/null; then
        grep -E 'http_proxy|https_proxy|HTTP_PROXY|HTTPS_PROXY|no_proxy|NO_PROXY' "${ENV_FILE}"
    else
        echo "  (未配置)"
    fi
    echo ""

    # apt 代理
    echo "── apt 代理 ─────────────────────────────"
    if [ -f "${APT_PROXY_CONF}" ]; then
        cat "${APT_PROXY_CONF}"
    else
        echo "  (未配置)"
    fi
    echo ""

    # Docker 代理
    echo "── Docker daemon 代理 ───────────────────"
    if [ -f "${DOCKER_PROXY_CONF}" ]; then
        cat "${DOCKER_PROXY_CONF}"
    else
        echo "  (未配置)"
    fi
    echo ""

    # /etc/hosts 同步状态
    echo "── /etc/hosts Windows hosts 同步 ───────"
    if grep -q "${HOSTS_MARK_BEGIN}" "${WSL_HOSTS}" 2>/dev/null; then
        sed -n "/${HOSTS_MARK_BEGIN}/,/${HOSTS_MARK_END}/p" "${WSL_HOSTS}" \
            | grep -v '^#' | grep -v '^$' | awk '{printf "  %s → %s\n", $1, $2}'
    else
        echo "  (未同步)"
    fi
    echo "========================================"
}

# ─── 入口 ────────────────────────────────────────────────────────────────────
# 跳过已由 _parse_global_opts 处理的 --port / --server 参数，定位实际命令
_cmd=""
_cmd_extra=""
_skip_next=false
for _arg in "$@"; do
    if ${_skip_next}; then
        _skip_next=false
        continue
    fi
    case "${_arg}" in
        --port|--server)
            _skip_next=true
            ;;
        --*)
            # 忽略其他全局选项
            ;;
        *)
            if [ -z "${_cmd}" ]; then
                _cmd="${_arg}"
            else
                _cmd_extra="${_arg}"
            fi
            ;;
    esac
done

case "${_cmd}" in
    enable)
        do_enable "${_cmd_extra}"
        ;;
    disable)
        do_disable
        ;;
    docker-enable)
        do_docker_enable "${_cmd_extra}"
        ;;
    docker-disable)
        do_docker_disable
        ;;
    sync-hosts)
        sync_hosts
        ;;
    clear-hosts)
        clear_hosts
        ;;
    status)
        do_status
        ;;
    *)
        echo "用法: $(basename "$0") [--port <端口>] [--server <host:port>] <命令> [host:port]"
        echo ""
        echo "全局选项（优先级高于配置文件和内置默认值）:"
        echo "  --port <端口>       仅覆盖端口号，主机保持默认（当前默认: ${DEFAULT_PROXY_SERVER}）"
        echo "  --server <host:port> 完整覆盖代理服务器地址"
        echo ""
        echo "命令:"
        echo "  enable              启用全部代理（shell/apt/docker）+ 同步 hosts"
        echo "  disable             关闭全部代理（shell/apt/docker），hosts 保持不动"
        echo "  docker-enable       仅为 Docker 启用代理 + 同步 hosts，不影响 shell/apt"
        echo "  docker-disable      仅为 Docker 关闭代理，不影响 shell/apt 和 hosts"
        echo "  sync-hosts          仅同步 Windows hosts → WSL /etc/hosts（hosts 有新增时使用）"
        echo "  clear-hosts         仅清除 /etc/hosts 中由本脚本同步的条目"
        echo "  status              查看当前代理状态"
        echo ""
        echo "配置文件 (~/.wsl-proxy.conf，优先级高于内置默认值):"
        echo "  PROXY_SERVER=127.0.0.1:7890   # 设置默认代理服务器"
        echo ""
        echo "优先级（高 → 低）: --port/--server 参数 > 配置文件 > 内置默认 (${_BUILTIN_DEFAULT_PROXY_SERVER})"
        echo ""
        echo "示例:"
        echo "  sudo $(basename "$0") enable                          # 使用当前默认 ${DEFAULT_PROXY_SERVER}"
        echo "  sudo $(basename "$0") --port 7890 enable              # 使用端口 7890"
        echo "  sudo $(basename "$0") --server 192.168.1.1:8080 enable"
        echo "  sudo $(basename "$0") enable 127.0.0.1:7890           # 旧语法，仍然支持"
        echo "  sudo $(basename "$0") docker-enable"
        echo "  sudo $(basename "$0") disable"
        exit 1
        ;;
esac
