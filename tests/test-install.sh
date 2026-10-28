#!/usr/bin/env bash
# 检查一键入口会用旁边的脚本，而不是去下载。不改本机 /usr/local。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  FAILURES=$((FAILURES + 1))
}

tmp="$(mktemp -d)"
sudo env NO_PASS_DEST="$tmp/lib" bash "$ROOT/install.sh" --help >"$tmp/help.out"
if ! grep -q 'bash <(curl -fsSL https://raw.githubusercontent.com/tumgle/no-pass/main/install.sh)' "$tmp/help.out"; then
  fail "帮助信息里没有一键命令"
fi
if [[ -e "$tmp/lib" ]]; then
  fail "--help 不应安装脚本"
fi

sudo env NO_PASS_DEST="$tmp/lib" bash "$ROOT/install.sh" <<'EOF'
0
EOF

if ! cmp -s "$ROOT/disable-password-login.sh" "$tmp/lib/disable-password-login.sh"; then
  fail "没有装上旁边的 disable-password-login.sh"
fi
if ! cmp -s "$ROOT/no-pass.sh" "$tmp/lib/no-pass.sh"; then
  fail "没有装上旁边的 no-pass.sh"
fi
if [[ ! -x "$tmp/lib/no-pass.sh" ]]; then
  fail "菜单脚本不可执行"
fi

if [[ "$FAILURES" -ne 0 ]]; then
  printf '%s\n' "${FAILURES} 个测试失败" >&2
  exit 1
fi
printf '%s\n' "install.sh 测试通过"
