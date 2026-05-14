#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
CONFIG_PATH="/etc/danted.conf"
DEFAULT_PORT="1080"
DEFAULT_USER="socksuser"

SOCKS_USER="$DEFAULT_USER"
SOCKS_PASSWORD=""
PORT="$DEFAULT_PORT"
EXTERNAL_IFACE=""

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage: sudo bash $SCRIPT_NAME --password <password> [options]

Options:
  --user <username>       SOCKS5 认证用户名，默认: $DEFAULT_USER
  --password <password>   SOCKS5 认证密码，必填
  --port <port>           SOCKS5 监听端口，默认: $DEFAULT_PORT
  --external <iface>      出口网卡；默认自动检测
  -h, --help              显示帮助

示例:
  sudo bash $SCRIPT_NAME --password 'your-password'
  sudo bash $SCRIPT_NAME --user socksuser --password 'your-password' --port 1080
EOF
}

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    die "请使用 root 运行，例如: sudo bash $SCRIPT_NAME --password 'your-password'"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --user)
        [[ $# -ge 2 ]] || die "--user 需要一个参数"
        SOCKS_USER="$2"
        shift 2
        ;;
      --password)
        [[ $# -ge 2 ]] || die "--password 需要一个参数"
        SOCKS_PASSWORD="$2"
        shift 2
        ;;
      --port)
        [[ $# -ge 2 ]] || die "--port 需要一个参数"
        PORT="$2"
        shift 2
        ;;
      --external)
        [[ $# -ge 2 ]] || die "--external 需要一个参数"
        EXTERNAL_IFACE="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "未知参数: $1"
        ;;
    esac
  done
}

validate_args() {
  [[ -n "$SOCKS_PASSWORD" ]] || die "必须指定 --password"
  [[ "$PORT" =~ ^[0-9]+$ ]] || die "端口必须是数字: $PORT"
  (( PORT >= 1 && PORT <= 65535 )) || die "端口范围必须在 1-65535 之间: $PORT"

  if [[ ! "$SOCKS_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
    die "用户名格式不合法: $SOCKS_USER"
  fi
}

check_platform() {
  [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release，当前系统不受支持"
  # shellcheck disable=SC1091
  source /etc/os-release

  if [[ "${ID:-}" != "debian" ]]; then
    warn "检测到系统为 ${ID:-unknown}，目标环境为 Debian，继续执行但请自行确认兼容性。"
  fi
}

install_dante() {
  command -v apt-get >/dev/null 2>&1 || die "未找到 apt-get，当前系统不受支持"

  log "更新 apt 索引"
  apt-get update -y

  log "安装 dante-server"
  DEBIAN_FRONTEND=noninteractive apt-get install -y dante-server curl
}

detect_external_iface() {
  if [[ -n "$EXTERNAL_IFACE" ]]; then
    return 0
  fi

  EXTERNAL_IFACE="$(ip route get 8.8.8.8 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}')"
  [[ -n "$EXTERNAL_IFACE" ]] || die "自动检测出口网卡失败，请使用 --external 指定"
  log "检测到出口网卡: $EXTERNAL_IFACE"
}

ensure_socks_user() {
  if id "$SOCKS_USER" >/dev/null 2>&1; then
    log "用户 $SOCKS_USER 已存在，更新密码"
  else
    log "创建 SOCKS 用户: $SOCKS_USER"
    useradd -r -s /usr/sbin/nologin "$SOCKS_USER"
  fi

  printf '%s:%s\n' "$SOCKS_USER" "$SOCKS_PASSWORD" | chpasswd
}

write_config() {
  if [[ -f "$CONFIG_PATH" ]]; then
    cp "$CONFIG_PATH" "$CONFIG_PATH.bak.$(date +%Y%m%d%H%M%S)"
  fi

  cat > "$CONFIG_PATH" <<EOF
logoutput: syslog

internal: 0.0.0.0 port = $PORT
external: $EXTERNAL_IFACE

socksmethod: username
clientmethod: none
user.privileged: root
user.unprivileged: nobody

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect error
}

socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    command: connect bind udpassociate
    log: connect disconnect error
}
EOF

  log "Dante 配置已写入: $CONFIG_PATH"
}

open_ufw_port_if_active() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    log "检测到 ufw 已启用，放行 TCP 端口 $PORT"
    ufw allow "$PORT/tcp"
  fi
}

restart_service() {
  systemctl enable danted >/dev/null
  systemctl restart danted
  systemctl --no-pager --full status danted || true
}

show_result() {
  local public_ip
  public_ip="$(curl -fsS https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"

  echo
  log "SOCKS5 服务已配置完成"
  printf '地址: %s\n' "$public_ip"
  printf '端口: %s\n' "$PORT"
  printf '用户名: %s\n' "$SOCKS_USER"
  printf '密码: %s\n' "$SOCKS_PASSWORD"
  echo
  printf '测试命令:\n'
  printf 'curl --socks5 %q:%q@%s:%s https://ifconfig.me\n' "$SOCKS_USER" "$SOCKS_PASSWORD" "$public_ip" "$PORT"
}

main() {
  parse_args "$@"
  validate_args
  require_root
  check_platform
  install_dante
  detect_external_iface
  ensure_socks_user
  write_config
  open_ufw_port_if_active
  restart_service
  show_result
}

main "$@"
