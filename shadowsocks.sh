#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
CONFIG_DIR="/var/snap/shadowsocks-rust/common/etc/shadowsocks-rust"
CONFIG_PATH="$CONFIG_DIR/config.json"
SYSCTL_FILE="/etc/sysctl.d/99-shadowsocks-bbr.conf"
DEFAULT_METHOD="2022-blake3-chacha20-poly1305"
DEFAULT_PORT="20000"
DEFAULT_SERVER="0.0.0.0"
DEFAULT_MODE="tcp_and_udp"
DEFAULT_CHANNEL="edge"

METHOD="$DEFAULT_METHOD"
PORT="$DEFAULT_PORT"
SERVER_ADDR="$DEFAULT_SERVER"
MODE="$DEFAULT_MODE"
CHANNEL="$DEFAULT_CHANNEL"
PASSWORD=""
ENABLE_BBR=1
FORCE=0
CONFIG_REUSED=0

SUPPORTED_METHODS=(
  "2022-blake3-aes-128-gcm"
  "2022-blake3-aes-256-gcm"
  "2022-blake3-chacha20-poly1305"
  "aes-128-gcm"
  "aes-256-gcm"
  "chacha20-ietf-poly1305"
)

BBR_SYSCTL_CONTENT=$(cat <<'EOF'
fs.file-max = 51200
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 4096
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.ip_local_port_range = 10000 65000
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mem = 25600 51200 102400
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_congestion_control = bbr
EOF
)

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
Usage: sudo bash $SCRIPT_NAME [options]

Options:
  --port <port>            服务端口，默认: $DEFAULT_PORT
  --method <method>        加密方式，默认: $DEFAULT_METHOD
  --password <password>    指定密码；未指定时自动生成
  --server <ip>            监听地址，默认: $DEFAULT_SERVER
  --mode <mode>            传输模式，默认: $DEFAULT_MODE
  --channel <name>         snap 通道，默认: $DEFAULT_CHANNEL
  --enable-bbr             写入并应用 BBR 优化配置
  --force                  即使已有配置，也强制覆盖
  -h, --help               显示帮助

示例:
  sudo bash $SCRIPT_NAME
  sudo bash $SCRIPT_NAME --port 20000 --method 2022-blake3-chacha20-poly1305 --enable-bbr
  sudo bash $SCRIPT_NAME --password 'your-password' --force
EOF
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
	die "请使用 root 运行，例如: sudo bash $SCRIPT_NAME"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
	case "$1" in
	  --port)
		[[ $# -ge 2 ]] || die "--port 需要一个参数"
		PORT="$2"
		shift 2
		;;
	  --method)
		[[ $# -ge 2 ]] || die "--method 需要一个参数"
		METHOD="$2"
		shift 2
		;;
	  --password)
		[[ $# -ge 2 ]] || die "--password 需要一个参数"
		PASSWORD="$2"
		shift 2
		;;
	  --server)
		[[ $# -ge 2 ]] || die "--server 需要一个参数"
		SERVER_ADDR="$2"
		shift 2
		;;
	  --mode)
		[[ $# -ge 2 ]] || die "--mode 需要一个参数"
		MODE="$2"
		shift 2
		;;
	  --channel)
		[[ $# -ge 2 ]] || die "--channel 需要一个参数"
		CHANNEL="$2"
		shift 2
		;;
	  --enable-bbr)
		ENABLE_BBR=1
		shift
		;;
	  --force)
		FORCE=1
		shift
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

validate_port() {
  [[ "$PORT" =~ ^[0-9]+$ ]] || die "端口必须是数字: $PORT"
  (( PORT >= 1 && PORT <= 65535 )) || die "端口范围必须在 1-65535 之间: $PORT"
}

validate_method() {
  local item
  for item in "${SUPPORTED_METHODS[@]}"; do
	if [[ "$METHOD" == "$item" ]]; then
	  return 0
	fi
  done
  die "不支持的加密方式: $METHOD"
}

check_platform() {
  [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release，当前系统不受支持"
  # shellcheck disable=SC1091
  source /etc/os-release

  if [[ "${ID:-}" != "ubuntu" ]]; then
	warn "检测到系统为 ${ID:-unknown}，文档目标环境为 Ubuntu 24，继续执行但请自行确认兼容性。"
  fi

  if [[ "${VERSION_ID:-}" != "24.04" && "${VERSION_ID:-}" != "24" ]]; then
	warn "检测到版本为 ${VERSION_ID:-unknown}，文档目标环境为 Ubuntu 24，继续执行但请自行确认兼容性。"
  fi
}

apt_install_if_missing() {
  local pkg="$1"
  if dpkg -s "$pkg" >/dev/null 2>&1; then
	log "$pkg 已安装，跳过"
  else
	log "安装 $pkg"
	apt-get install -y "$pkg"
  fi
}

ensure_dependencies() {
  command_exists apt-get || die "未找到 apt-get，当前系统不受支持"

  log "更新 apt 索引"
  apt-get update -y

  apt_install_if_missing snapd
  apt_install_if_missing curl

  if ! systemctl is-enabled snapd.service >/dev/null 2>&1; then
	systemctl enable snapd.service >/dev/null 2>&1 || true
  fi
  if ! systemctl is-active snapd.service >/dev/null 2>&1; then
	systemctl start snapd.service
  fi

  local waited=0
  until command_exists snap; do
	(( waited < 30 )) || die "snap 命令未就绪，请稍后重试"
	sleep 1
	((waited += 1))
  done
}

ensure_snap_package() {
  if snap list shadowsocks-rust >/dev/null 2>&1; then
	log "shadowsocks-rust 已安装，执行 refresh 保持最新"
  snap refresh shadowsocks-rust --channel="$CHANNEL" || warn "refresh 失败，可稍后手动执行 snap refresh shadowsocks-rust --channel=$CHANNEL"
  else
	log "通过 snap 安装 shadowsocks-rust (channel: $CHANNEL)"
  snap install shadowsocks-rust --channel="$CHANNEL"
  fi
}

find_ssservice() {
  local candidate

  if candidate="$(command -v ssservice 2>/dev/null)" && [[ -n "$candidate" ]]; then
	printf '%s\n' "$candidate"
	return 0
  fi

  candidate="/snap/bin/shadowsocks-rust.ssservice"
  if [[ -x "$candidate" ]]; then
	printf '%s\n' "$candidate"
	return 0
  fi

  candidate="$(find /snap /var/snap -type f -name 'ssservice' 2>/dev/null | head -n 1 || true)"
  if [[ -n "$candidate" && -x "$candidate" ]]; then
	printf '%s\n' "$candidate"
	return 0
  fi

  return 1
}

generate_password_if_needed() {
  if [[ -n "$PASSWORD" ]]; then
	log "使用命令行提供的密码"
	return 0
  fi

  local ssservice_bin
  ssservice_bin="$(find_ssservice)" || die "未找到 ssservice，可先检查 snap 安装是否成功"

  log "未提供密码，使用 ssservice 自动生成密钥"
  PASSWORD="$($ssservice_bin genkey -m "$METHOD")"
  [[ -n "$PASSWORD" ]] || die "自动生成密码失败"
}

write_config() {
  mkdir -p "$CONFIG_DIR"

  if [[ -f "$CONFIG_PATH" && $FORCE -ne 1 ]]; then
  CONFIG_REUSED=1
	warn "检测到现有配置: $CONFIG_PATH"
	warn "如需覆盖，请追加 --force"
	log "保留现有配置并跳过写入"
	return 0
  fi

  umask 077
  cat > "$CONFIG_PATH" <<EOF
{
  "server": "$SERVER_ADDR",
  "server_port": $PORT,
  "password": "$PASSWORD",
  "method": "$METHOD",
  "mode": "$MODE"
}
EOF

  log "配置已写入: $CONFIG_PATH"
}

enable_and_restart_service() {
  log "启用并启动 shadowsocks-rust 服务"
  snap start --enable shadowsocks-rust.ssserver-daemon >/dev/null 2>&1 || true
  snap restart shadowsocks-rust.ssserver-daemon
}

configure_bbr() {
  [[ $ENABLE_BBR -eq 1 ]] || return 0

  log "写入 BBR 优化配置: $SYSCTL_FILE"
  printf '%s\n' "$BBR_SYSCTL_CONTENT" > "$SYSCTL_FILE"
  sysctl --system >/dev/null
}

show_summary() {
  if [[ $CONFIG_REUSED -eq 1 ]]; then
	log "当前使用的是已有配置文件，下面的端口/加密方式摘要可能与命令行参数不同，请以配置文件内容为准。"
	echo
	cat "$CONFIG_PATH"
	echo
  fi

  echo
  log "安装完成，当前配置摘要如下:"
  printf '  server : %s\n' "$SERVER_ADDR"
  printf '  port   : %s\n' "$PORT"
  printf '  method : %s\n' "$METHOD"
  printf '  mode   : %s\n' "$MODE"
  printf '  config : %s\n' "$CONFIG_PATH"
  printf '  bbr    : %s\n' "$([[ $ENABLE_BBR -eq 1 ]] && echo enabled || echo skipped)"

  echo
  log "snap 服务状态:"
  snap services shadowsocks-rust || true

  echo
  log "端口监听情况:"
  if command_exists ss; then
	ss -lntup | grep -F ":$PORT" || warn "未在 ss 输出中看到端口 $PORT，可能服务仍在启动中"
  else
	warn "未找到 ss 命令，跳过端口检查"
  fi

  if [[ $ENABLE_BBR -eq 1 ]]; then
	echo
	log "当前拥塞控制算法:"
	sysctl net.ipv4.tcp_congestion_control || true
  fi

  echo
  log "如需查看完整配置，可执行: cat $CONFIG_PATH"
  cat $CONFIG_PATH
}

main() {
  parse_args "$@"
  require_root
  validate_port
  validate_method
  check_platform
  ensure_dependencies
  ensure_snap_package
  generate_password_if_needed
  write_config
  enable_and_restart_service
  configure_bbr
  show_summary
}

main "$@"
