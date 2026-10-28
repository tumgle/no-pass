#!/usr/bin/env bash
# 针对 disable-password-login.sh 的配置改写测试。不修改本机 /etc/ssh。
# shellcheck disable=SC2034
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/disable-password-login.sh"

FAILURES=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  FAILURES=$((FAILURES + 1))
}

assert_eq() {
  local got="$1" want="$2" label="$3"
  if [[ "$got" != "$want" ]]; then
    fail "${label}: 期望 [${want}] 实际 [${got}]"
  fi
}

assert_contains() {
  local file="$1" text="$2"
  if ! grep -F -q "$text" "$file"; then
    fail "${file} 应包含: ${text}"
  fi
}

assert_not_contains() {
  local file="$1" text="$2"
  if grep -F -q "$text" "$file"; then
    fail "${file} 不应包含: ${text}"
  fi
}

setup_fixture() {
  WORK="$(mktemp -d)"
  SSHD_CONFIG="$WORK/sshd_config"
  SSHD_CONFIG_DIR="$WORK/sshd_config.d"
  INCLUDE_DIR="$SSHD_CONFIG_DIR"
  KEEP_KBD=0
  FORCE=0
  DRY_RUN=0
  mkdir -p "$SSHD_CONFIG_DIR"
  cat > "$SSHD_CONFIG" <<'EOF'
Port 22
PermitRootLogin prohibit-password
PasswordAuthentication yes
KbdInteractiveAuthentication yes
PermitEmptyPasswords yes
PubkeyAuthentication yes
#PasswordAuthentication yes
Match User deploy
    PasswordAuthentication yes
    PubkeyAuthentication no
EOF
  printf '%s\n' "PasswordAuthentication yes" > "$SSHD_CONFIG_DIR/50-cloud-init.conf"
  printf '%s\n' "passwordauthentication YES" > "$SSHD_CONFIG_DIR/60-cloudimg-settings.conf"
}

active_lines() {
  grep -vE '^[[:space:]]*#' "$1" || true
}

test_neutralize_and_managed_file() {
  setup_fixture
  apply_config_files

  assert_contains "$SSHD_CONFIG" "Port 22"
  assert_contains "$SSHD_CONFIG" "PermitRootLogin prohibit-password"
  assert_contains "$SSHD_CONFIG" "PubkeyAuthentication yes"
  assert_contains "$SSHD_CONFIG" "#PasswordAuthentication yes"
  assert_contains "$SSHD_CONFIG" "# disabled-by-disable-password-login.sh: PasswordAuthentication yes"
  assert_contains "$SSHD_CONFIG" "# disabled-by-disable-password-login.sh: KbdInteractiveAuthentication yes"
  assert_contains "$SSHD_CONFIG" "# disabled-by-disable-password-login.sh: PermitEmptyPasswords yes"
  assert_contains "$SSHD_CONFIG" "# disabled-by-disable-password-login.sh:     PasswordAuthentication yes"
  assert_contains "$SSHD_CONFIG" "# disabled-by-disable-password-login.sh:     PubkeyAuthentication no"
  assert_not_contains "$SSHD_CONFIG_DIR/00-disable-password-auth.conf" "# disabled-by-disable-password-login.sh"

  local active
  active="$(active_lines "$SSHD_CONFIG")"
  if grep -Eiq '^[[:space:]]*passwordauthentication[[:space:]]' <<<"$active"; then
    fail "主配置里仍有生效的 PasswordAuthentication"
  fi
  if grep -Eiq '^[[:space:]]*pubkeyauthentication[[:space:]]+no' <<<"$active"; then
    fail "PubkeyAuthentication no 仍生效"
  fi

  assert_contains "$SSHD_CONFIG_DIR/50-cloud-init.conf" "# disabled-by-disable-password-login.sh: PasswordAuthentication yes"
  assert_contains "$SSHD_CONFIG_DIR/60-cloudimg-settings.conf" "# disabled-by-disable-password-login.sh: passwordauthentication YES"

  local managed="$SSHD_CONFIG_DIR/00-disable-password-auth.conf"
  assert_contains "$managed" "PasswordAuthentication no"
  assert_contains "$managed" "PermitEmptyPasswords no"
  assert_contains "$managed" "PubkeyAuthentication yes"
  assert_contains "$managed" "KbdInteractiveAuthentication no"
  assert_contains "$managed" "ChallengeResponseAuthentication no"
  local mode
  mode="$(stat -c '%a' "$managed")"
  assert_eq "$mode" "644" "托管文件权限"
}

test_idempotent() {
  setup_fixture
  apply_config_files
  local first second
  first="$(cat "$SSHD_CONFIG" "$SSHD_CONFIG_DIR"/*.conf)"
  apply_config_files
  second="$(cat "$SSHD_CONFIG" "$SSHD_CONFIG_DIR"/*.conf)"
  assert_eq "$second" "$first" "连续执行两次结果应相同"
  if grep -q 'disabled-by-disable-password-login.sh: # disabled-by' "$SSHD_CONFIG"; then
    fail "注释被套了两次"
  fi
}

test_keep_keyboard_interactive() {
  setup_fixture
  KEEP_KBD=1
  apply_config_files
  assert_contains "$SSHD_CONFIG" "KbdInteractiveAuthentication yes"
  assert_not_contains "$SSHD_CONFIG" "disabled-by-disable-password-login.sh: KbdInteractiveAuthentication yes"
  assert_contains "$SSHD_CONFIG" "# disabled-by-disable-password-login.sh: PasswordAuthentication yes"
  local managed="$SSHD_CONFIG_DIR/00-disable-password-auth.conf"
  assert_not_contains "$managed" "KbdInteractiveAuthentication"
  assert_contains "$managed" "PasswordAuthentication no"
}

test_include_once() {
  setup_fixture
  apply_config_files
  local count
  count="$(grep -cF "Include ${SSHD_CONFIG_DIR}/*.conf" "$SSHD_CONFIG")"
  assert_eq "$count" "1" "Include 应只出现一次"
  local first
  first="$(head -n 1 "$SSHD_CONFIG")"
  assert_eq "$first" "Include ${SSHD_CONFIG_DIR}/*.conf" "没有 Include 时应加到文件开头"

  apply_config_files
  count="$(grep -cF "Include ${SSHD_CONFIG_DIR}/*.conf" "$SSHD_CONFIG")"
  assert_eq "$count" "1" "第二次运行不应重复 Include"
}

test_existing_include_untouched() {
  setup_fixture
  local include_line="Include ${SSHD_CONFIG_DIR}/*.conf"
  printf '%s\n%s\n' "$include_line" "Port 22" > "$SSHD_CONFIG"
  printf '%s\n' "PasswordAuthentication yes" >> "$SSHD_CONFIG"
  apply_config_files
  local count
  count="$(grep -cF "$include_line" "$SSHD_CONFIG")"
  assert_eq "$count" "1" "已有 Include 时不应再插入"
  assert_contains "$SSHD_CONFIG" "# disabled-by-disable-password-login.sh: PasswordAuthentication yes"
}

test_authentication_methods_gate() {
  setup_fixture
  printf '%s\n' 'AuthenticationMethods publickey,password' >> "$SSHD_CONFIG"
  if authentication_methods_allow_pubkey 2>/dev/null; then
    fail "publickey,password 应被拒绝"
  fi

  setup_fixture
  printf '%s\n' 'AuthenticationMethods publickey password' >> "$SSHD_CONFIG"
  if ! authentication_methods_allow_pubkey; then
    fail "同时列出单独的 publickey 时应允许"
  fi

  setup_fixture
  printf '%s\n' 'AuthenticationMethods publickey' >> "$SSHD_CONFIG"
  if ! authentication_methods_allow_pubkey; then
    fail "只有 publickey 时应允许"
  fi

  setup_fixture
  printf '%s\n' 'AuthenticationMethods publickey,password' > "$SSHD_CONFIG_DIR/99-match.conf"
  if authentication_methods_allow_pubkey 2>/dev/null; then
    fail "drop-in 里的 publickey,password 应被拒绝"
  fi
}

test_user_in_list() {
  if ! user_in_list ubuntu ubuntu root; then
    fail "应能在账号列表里找到 ubuntu"
  fi
  if user_in_list nobody ubuntu root; then
    fail "nobody 不在账号列表里"
  fi
  if user_in_list ubuntu; then
    fail "只有待查用户、没有账号列表时不应算找到"
  fi
}

test_dry_run_does_not_write() {
  setup_fixture
  local before
  before="$(cat "$SSHD_CONFIG" "$SSHD_CONFIG_DIR"/*.conf)"
  preview >/dev/null
  local after
  after="$(cat "$SSHD_CONFIG" "$SSHD_CONFIG_DIR"/*.conf)"
  assert_eq "$after" "$before" "preview/dry-run 不应改原文件"
}

test_main_with_sshd() {
  [[ -x "${SSHD_BIN_TEST:-/usr/sbin/sshd}" ]] || return 0
  [[ "$(id -u)" -eq 0 ]] || return 0

  setup_fixture
  local checksum_before
  checksum_before="$(cat "$SSHD_CONFIG")"
  set +e
  env \
    SSHD_CONFIG="$SSHD_CONFIG" \
    SSHD_CONFIG_DIR="$SSHD_CONFIG_DIR" \
    SSHD_BIN="${SSHD_BIN_TEST:-/usr/sbin/sshd}" \
    BACKUP_DIR_ROOT="$WORK/backups" \
    CLOUD_CFG_DIR="$WORK/cloud.cfg.d" \
    "$ROOT/disable-password-login.sh" >/tmp/disable-password-login-nokey.out 2>/tmp/disable-password-login-nokey.err
  local rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    fail "没有公钥时脚本应失败"
  fi
  assert_eq "$(cat "$SSHD_CONFIG")" "$checksum_before" "拒绝执行时不应改配置"
  if ! grep -q '没有在任何可登录用户' /tmp/disable-password-login-nokey.err; then
    fail "缺少公钥时的提示不对: $(cat /tmp/disable-password-login-nokey.err)"
  fi

  setup_fixture
  mkdir -p "$WORK/cloud.cfg.d" "$WORK/backups"
  # 使用发行版真实配置做语法校验，避免夹具里的指令在新版本 sshd 上不完整。
  if [[ -f /etc/ssh/sshd_config ]]; then
    cp -a /etc/ssh/sshd_config "$SSHD_CONFIG"
    rm -rf "$SSHD_CONFIG_DIR"
    mkdir -p "$SSHD_CONFIG_DIR"
    if [[ -d /etc/ssh/sshd_config.d ]]; then
      cp -a /etc/ssh/sshd_config.d/. "$SSHD_CONFIG_DIR/"
    fi
    printf '%s\n' "PasswordAuthentication yes" > "$SSHD_CONFIG_DIR/50-cloud-init.conf"
    printf '%s\n' "KbdInteractiveAuthentication yes" > "$SSHD_CONFIG_DIR/60-cloudimg-settings.conf"
  fi

  env \
    SSHD_CONFIG="$SSHD_CONFIG" \
    SSHD_CONFIG_DIR="$SSHD_CONFIG_DIR" \
    SSHD_BIN="${SSHD_BIN_TEST:-/usr/sbin/sshd}" \
    BACKUP_DIR_ROOT="$WORK/backups" \
    CLOUD_CFG_DIR="$WORK/cloud.cfg.d" \
    "$ROOT/disable-password-login.sh" --force
  assert_contains "$WORK/cloud.cfg.d/99-disable-ssh-password.cfg" "ssh_pwauth: false"
  local sshd_bin="${SSHD_BIN_TEST:-/usr/sbin/sshd}"
  "$sshd_bin" -t -f "$SSHD_CONFIG"

  local effective
  effective="$("$sshd_bin" -T -f "$SSHD_CONFIG")"
  assert_eq "$(setting_value passwordauthentication "$effective")" "no" "sshd -T passwordauthentication"
  assert_eq "$(setting_value permitemptypasswords "$effective")" "no" "sshd -T permitemptypasswords"
  assert_eq "$(setting_value pubkeyauthentication "$effective")" "yes" "sshd -T pubkeyauthentication"
  assert_eq "$(setting_value kbdinteractiveauthentication "$effective")" "no" "sshd -T kbdinteractiveauthentication"

  local backup_count
  backup_count="$(find "$WORK/backups" -mindepth 1 -maxdepth 1 -type d | wc -l)"
  if [[ "$backup_count" -lt 1 ]]; then
    fail "应留下备份目录"
  fi
}

test_user_in_list
test_neutralize_and_managed_file
test_idempotent
test_keep_keyboard_interactive
test_include_once
test_existing_include_untouched
test_authentication_methods_gate
test_dry_run_does_not_write
test_main_with_sshd

if [[ "$FAILURES" -ne 0 ]]; then
  printf '%s\n' "${FAILURES} 个测试失败" >&2
  exit 1
fi
printf '%s\n' "全部测试通过"
