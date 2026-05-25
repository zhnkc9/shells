#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
SERVICE_NAME="microsocks"
ENV_FILE="/etc/default/microsocks"
SERVICE_FILE="/etc/systemd/system/microsocks.service"
DEFAULT_PORT="1080"
DEFAULT_USER="socksuser"
DEFAULT_LISTEN="0.0.0.0"

SOCKS_USER="$DEFAULT_USER"
SOCKS_PASSWORD=""
PORT="$DEFAULT_PORT"
LISTEN_ADDR="$DEFAULT_LISTEN"
MICROSOCKS_BIN=""

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
  --listen <ip>           监听地址，默认: $DEFAULT_LISTEN
  -h, --help              显示帮助

示例:
  sudo bash $SCRIPT_NAME --password 'your-password'
  sudo bash $SCRIPT_NAME --user socksuser --password 'your-password' --port 2080
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
      --listen)
        [[ $# -ge 2 ]] || die "--listen 需要一个参数"
        LISTEN_ADDR="$2"
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

  if [[ ! "$SOCKS_USER" =~ ^[A-Za-z0-9._-]+$ ]]; then
    die "用户名只允许字母、数字、点、下划线和短横线: $SOCKS_USER"
  fi

  if [[ ! "$SOCKS_PASSWORD" =~ ^[A-Za-z0-9._@+=-]+$ ]]; then
    die "密码只允许字母、数字、点、下划线、@、+、= 和短横线"
  fi

  if [[ ! "$LISTEN_ADDR" =~ ^[0-9A-Fa-f:.]+$ ]]; then
    die "监听地址格式不合法: $LISTEN_ADDR"
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

install_microsocks() {
  command -v apt-get >/dev/null 2>&1 || die "未找到 apt-get，当前系统不受支持"
  command -v systemctl >/dev/null 2>&1 || die "未找到 systemctl，当前系统不受支持"

  log "更新 apt 索引"
  apt-get update -y

  log "安装 microsocks"
  DEBIAN_FRONTEND=noninteractive apt-get install -y microsocks curl

  MICROSOCKS_BIN="$(command -v microsocks || true)"
  [[ -n "$MICROSOCKS_BIN" ]] || die "microsocks 安装后仍未找到可执行文件"
}

write_environment() {
  cat > "$ENV_FILE" <<EOF
MICROSOCKS_LISTEN=$LISTEN_ADDR
MICROSOCKS_PORT=$PORT
MICROSOCKS_USER=$SOCKS_USER
MICROSOCKS_PASSWORD=$SOCKS_PASSWORD
EOF
  chmod 600 "$ENV_FILE"
  log "microsocks 参数已写入: $ENV_FILE"
}

write_service() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=MicroSocks SOCKS5 proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=$ENV_FILE
ExecStart=$MICROSOCKS_BIN -i \${MICROSOCKS_LISTEN} -p \${MICROSOCKS_PORT} -u \${MICROSOCKS_USER} -P \${MICROSOCKS_PASSWORD}
Restart=always
RestartSec=3
DynamicUser=true
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF

  log "systemd 服务已写入: $SERVICE_FILE"
}

open_ufw_port_if_active() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    log "检测到 ufw 已启用，放行 TCP 端口 $PORT"
    ufw allow "$PORT/tcp"
  fi
}

restart_service() {
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null
  systemctl restart "$SERVICE_NAME"
  systemctl --no-pager --full status "$SERVICE_NAME" || true
}

show_result() {
  local public_ip
  public_ip="$(curl -fsS https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"

  echo
  log "SOCKS5 服务已配置完成"
  printf '服务: microsocks\n'
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
  install_microsocks
  write_environment
  write_service
  open_ufw_port_if_active
  restart_service
  show_result
}

main "$@"
