#!/bin/bash
# 关闭 SSH 密码登录的菜单。

set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
TOOL="$DIR/disable-password-login.sh"

die() {
  echo "错误: $*" >&2
  exit 1
}

[[ -f "$TOOL" ]] || die "缺少 $TOOL"

pause() {
  read -r -p "按回车继续..." _
}

while true; do
  echo
  echo "======== 关闭 SSH 密码登录 ========"
  echo "1) 先看会改什么（不写入）"
  echo "2) 关闭密码登录"
  echo "3) 没有公钥也继续"
  echo "0) 退出"
  read -r -p "请选择: " choice
  case "$choice" in
    1)
      bash "$TOOL" --dry-run || echo "没有执行写入。"
      pause
      ;;
    2)
      bash "$TOOL" || echo "没有关闭密码登录。"
      pause
      ;;
    3)
      echo "只有确认控制台还能登录时才选这项。"
      bash "$TOOL" --force || echo "没有关闭密码登录。"
      pause
      ;;
    0)
      exit 0
      ;;
    *)
      echo "无效选项"
      ;;
  esac
done
