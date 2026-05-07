#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
SYSCTL_FILE="/etc/sysctl.d/99-bbr.conf"
FORCE=0
DRY_RUN=0

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
  --file <path>    sysctl 配置文件路径，默认: $SYSCTL_FILE
  --force          如果配置文件已存在，强制覆盖
  --dry-run        只打印将要写入的配置，不实际修改系统
  -h, --help       显示帮助

示例:
  sudo bash $SCRIPT_NAME
  sudo bash $SCRIPT_NAME --force
  sudo bash $SCRIPT_NAME --file /etc/sysctl.d/99-custom-bbr.conf --force
  bash $SCRIPT_NAME --dry-run
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
      --file)
        [[ $# -ge 2 ]] || die "--file 需要一个参数"
        SYSCTL_FILE="$2"
        shift 2
        ;;
      --force)
        FORCE=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
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

check_platform() {
  [[ "$(uname -s)" == "Linux" ]] || die "当前脚本仅支持 Linux"
  command_exists sysctl || die "未找到 sysctl 命令"
}

check_bbr_available() {
  local available_control
  local available_qdisc

  available_control="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  if [[ -n "$available_control" && "$available_control" != *bbr* ]]; then
    warn "当前内核可用拥塞控制算法中未看到 bbr: $available_control"
    warn "如果后续应用失败，请确认内核版本是否支持 BBR。"
  fi

  available_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
  if [[ -n "$available_qdisc" ]]; then
    log "当前默认队列算法: $available_qdisc"
  fi
}

show_dry_run() {
  log "dry-run 模式，不会修改系统。将写入的目标文件: $SYSCTL_FILE"
  echo
  printf '%s\n' "$BBR_SYSCTL_CONTENT"
}

write_bbr_config() {
  local sysctl_dir
  sysctl_dir="$(dirname "$SYSCTL_FILE")"

  if [[ -e "$SYSCTL_FILE" && $FORCE -ne 1 ]]; then
    die "配置文件已存在: $SYSCTL_FILE。如需覆盖，请追加 --force"
  fi

  mkdir -p "$sysctl_dir"
  printf '%s\n' "$BBR_SYSCTL_CONTENT" > "$SYSCTL_FILE"
  log "BBR 优化配置已写入: $SYSCTL_FILE"
}

apply_sysctl_config() {
  log "应用 sysctl 配置"
  sysctl --system >/dev/null
}

show_status() {
  echo
  log "当前 BBR 相关状态:"
  sysctl net.ipv4.tcp_congestion_control || true
  sysctl net.ipv4.tcp_available_congestion_control || true
  sysctl net.core.default_qdisc || true

  echo
  if sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -qx 'bbr'; then
    log "BBR 已启用"
  else
    warn "当前拥塞控制算法不是 bbr，请检查系统是否支持或查看 sysctl --system 输出。"
  fi
}

main() {
  parse_args "$@"
  check_platform

  if [[ $DRY_RUN -eq 1 ]]; then
    show_dry_run
    return 0
  fi

  require_root
  check_bbr_available
  write_bbr_config
  apply_sysctl_config
  show_status
}

main "$@"
