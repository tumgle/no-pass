#!/bin/bash
# 一键关闭 SSH 密码登录。
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/tumgle/no-pass/main/install.sh)

set -euo pipefail

RAW_BASE=https://raw.githubusercontent.com/tumgle/no-pass/main
DEST="${NO_PASS_DEST:-/usr/local/lib/no-pass}"

die() {
  echo "错误: $*" >&2
  exit 1
}

usage() {
  cat <<EOF
关闭 SSH 密码登录，只保留公钥。

  bash <(curl -fsSL ${RAW_BASE}/install.sh)

不带参数会打开菜单。也可以直接把参数传给脚本：

  bash <(curl -fsSL ${RAW_BASE}/install.sh) --dry-run
  bash <(curl -fsSL ${RAW_BASE}/install.sh) --force

脚本安装到 ${DEST}。之后在这台机器上执行 no-pass 会再次打开菜单。
用进程替换运行，菜单才能从当前终端读输入。
EOF
}

# bash <(curl) 的脚本在 /dev/fd 上，sudo 读不到。先复制成普通文件再提权。
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  [[ -z "${NO_PASS_REEXEC:-}" ]] || die "需要 root"
  command -v sudo >/dev/null 2>&1 || die "需要 root。请用 root 打开终端后再执行"
  tmp=$(mktemp)
  src=${BASH_SOURCE[0]}
  origin=""
  # /dev/fd 只能读一次，bash 已经把它当脚本读完，再复制会得到空文件。
  if [[ "$src" != /dev/fd/* && "$src" != /proc/self/fd/* && -f "$src" ]]; then
    cp -f "$src" "$tmp"
    origin=$(cd "$(dirname "$src")" && pwd)
  else
    command -v curl >/dev/null 2>&1 || die "需要 curl"
    curl -fsSL "${RAW_BASE}/install.sh" -o "$tmp"
  fi
  chmod 755 "$tmp"
  exec sudo env NO_PASS_REEXEC=1 NO_PASS_ORIGIN="$origin" NO_PASS_DEST="$DEST" bash "$tmp" "$@"
fi

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

mkdir -p "$DEST"
src=${NO_PASS_ORIGIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
if [[ -f "$src/disable-password-login.sh" && -f "$src/no-pass.sh" ]]; then
  cp -f "$src/disable-password-login.sh" "$src/no-pass.sh" "$DEST/"
else
  command -v curl >/dev/null 2>&1 || die "需要 curl 才能下载脚本"
  for name in disable-password-login.sh no-pass.sh; do
    echo "下载 ${name}"
    curl -fsSL "${RAW_BASE}/${name}" -o "$DEST/$name"
  done
fi
chmod 755 "$DEST/disable-password-login.sh" "$DEST/no-pass.sh"
[[ -s "$DEST/disable-password-login.sh" && -s "$DEST/no-pass.sh" ]] || die "缺少 disable-password-login.sh 或 no-pass.sh"

if [[ "$DEST" == /usr/local/lib/no-pass ]]; then
  ln -sfn "$DEST/no-pass.sh" /usr/local/bin/no-pass
fi

if [[ $# -gt 0 ]]; then
  exec bash "$DEST/disable-password-login.sh" "$@"
fi

echo "打开菜单。脚本目录: $DEST"
exec bash "$DEST/no-pass.sh"
