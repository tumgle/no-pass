#!/usr/bin/env bash
# 关闭 SSH 密码登录，只保留公钥认证。
# 用法: sudo ./disable-password-login.sh [--dry-run] [--force] [--keep-keyboard-interactive]
set -euo pipefail

SSHD_CONFIG="${SSHD_CONFIG:-/etc/ssh/sshd_config}"
SSHD_CONFIG_DIR="${SSHD_CONFIG_DIR:-/etc/ssh/sshd_config.d}"
BACKUP_DIR_ROOT="${BACKUP_DIR_ROOT:-/var/backups}"
CLOUD_CFG_DIR="${CLOUD_CFG_DIR:-/etc/cloud/cloud.cfg.d}"
MANAGED_BASENAME="${MANAGED_BASENAME:-00-disable-password-auth.conf}"
INCLUDE_DIR="${INCLUDE_DIR:-$SSHD_CONFIG_DIR}"

FORCE="${FORCE:-0}"
DRY_RUN="${DRY_RUN:-0}"
KEEP_KBD="${KEEP_KBD:-0}"

BACKUP_DIR=""
CONFIG_DIR_WAS_PRESENT=0
APPLY_STARTED=0
APPLY_VALIDATED=0
IN_ROLLBACK=0
SSHD_BIN="${SSHD_BIN:-}"

usage() {
  cat <<'EOF'
用法: sudo ./disable-password-login.sh [选项]

关闭 SSH 密码登录，只保留公钥认证。

会写入 /etc/ssh/sshd_config.d/00-disable-password-auth.conf，并注释掉
其他配置里已经生效的密码认证选项。UsePAM 保持打开（Ubuntu 要用它做会话，
不会因此重新允许密码登录）。

选项:
  --dry-run                     只打印将要修改的内容，不写入、不重载
  --force                       没有公钥，或 AuthenticationMethods 可能把公钥挡在外面时，仍继续
  --keep-keyboard-interactive   不关闭键盘交互认证。密码有时会从这条路径进来，一般不要用
  -h, --help                    显示本说明
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

is_system_target() {
  [[ "$SSHD_CONFIG" == /etc/ssh/sshd_config && "$SSHD_CONFIG_DIR" == /etc/ssh/sshd_config.d ]]
}

parse_args() {
  FORCE=0
  DRY_RUN=0
  KEEP_KBD=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --force) FORCE=1 ;;
      --keep-keyboard-interactive) KEEP_KBD=1 ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        usage >&2
        die "未知参数: $1"
        ;;
    esac
    shift
  done
}

find_sshd() {
  if [[ -n "$SSHD_BIN" && -x "$SSHD_BIN" ]]; then
    return 0
  fi
  if command -v sshd >/dev/null 2>&1; then
    SSHD_BIN="$(command -v sshd)"
    return 0
  fi
  if [[ -x /usr/sbin/sshd ]]; then
    SSHD_BIN=/usr/sbin/sshd
    return 0
  fi
  return 1
}

each_config_file() {
  local f nullglob=0
  printf '%s\n' "$SSHD_CONFIG"
  [[ -d "$SSHD_CONFIG_DIR" ]] || return 0
  shopt -q nullglob && nullglob=1
  shopt -s nullglob
  local files=("$SSHD_CONFIG_DIR"/*.conf)
  [[ "$nullglob" -eq 0 ]] && shopt -u nullglob
  for f in "${files[@]}"; do
    [[ "$(basename "$f")" == "$MANAGED_BASENAME" ]] && continue
    printf '%s\n' "$f"
  done
}

key_file_has_key() {
  local keyfile="$1"
  [[ -f "$keyfile" && -r "$keyfile" ]] || return 1
  grep -Eiq 'ssh-ed25519|ssh-rsa|ssh-dss|ecdsa-sha2-|sk-ssh-ed25519|sk-ecdsa-sha2-' "$keyfile"
}

accounts_with_keys() {
  local user home shell keyfile
  while IFS=: read -r user _ _ _ _ home shell; do
    [[ -n "$home" && "$home" != / && "$home" != /nonexistent ]] || continue
    [[ "$shell" == *nologin || "$shell" == */false ]] && continue
    for keyfile in "$home/.ssh/authorized_keys" "$home/.ssh/authorized_keys2"; do
      if key_file_has_key "$keyfile"; then
        printf '%s\n' "$user"
        break
      fi
    done
  done < <(getent passwd)
}

user_in_list() {
  local want="$1" name
  shift
  for name in "$@"; do
    [[ "$name" == "$want" ]] && return 0
  done
  return 1
}

check_authorized_keys() {
  local accounts=()
  local current="${USER:-${LOGNAME:-}}"
  mapfile -t accounts < <(accounts_with_keys || true)

  if [[ ${#accounts[@]} -eq 0 ]]; then
    if [[ "$FORCE" -eq 1 ]]; then
      printf '%s\n' "警告: 没有发现可用公钥。已指定 --force，密码登录关闭后可能只能从控制台进入。" >&2
    else
      die "已中止: 没有在任何可登录用户的 ~/.ssh/authorized_keys 里发现公钥。先放入公钥，或确认控制台还能登录后使用 --force。"
    fi
  else
    printf '已发现这些账号有公钥: %s\n' "${accounts[*]}"
  fi

  if [[ -n "${SSH_CONNECTION:-}" && "$FORCE" -ne 1 ]]; then
    if [[ -z "$current" ]] || ! user_in_list "$current" "${accounts[@]+"${accounts[@]}"}"; then
      die "已中止: 当前是 SSH 会话，但 ${current:-当前用户} 没有公钥。关闭密码登录后，这个会话断开就无法再进来。"
    fi
  fi
}

# 有 AuthenticationMethods 时，必须仍有一条「只有公钥」的路径，否则关掉密码后谁都进不来。
authentication_methods_allow_pubkey() {
  local file line rest seq ok found=0
  local nocase=0 noglob=0 rc=0
  local -a risky=() config_files=()
  shopt -q nocasematch && nocase=1
  shopt -s nocasematch
  mapfile -t config_files < <(each_config_file)
  [[ $- == *f* ]] && noglob=1
  set -f
  for file in "${config_files[@]}"; do
    [[ -f "$file" ]] || continue
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ "$line" =~ ^[[:space:]]*AuthenticationMethods[[:space:]]+(.*)$ ]] || continue
      found=1
      rest="${BASH_REMATCH[1]}"
      rest="${rest%%#*}"
      ok=0
      for seq in $rest; do
        [[ "$seq" == "publickey" ]] && ok=1
      done
      if [[ "$ok" -ne 1 ]]; then
        risky+=("$file: $line")
      fi
    done < "$file"
  done
  [[ "$noglob" -eq 0 ]] && set +f
  [[ "$nocase" -eq 0 ]] && shopt -u nocasematch

  if [[ "$found" -eq 0 || ${#risky[@]} -eq 0 ]]; then
    return 0
  fi
  printf '%s\n' "这些 AuthenticationMethods 没有单独的 publickey 路径，关掉密码后可能无法登录:" >&2
  printf '  %s\n' "${risky[@]}" >&2
  if [[ "$FORCE" -eq 1 ]]; then
    printf '%s\n' "警告: 已指定 --force，继续修改。" >&2
    return 0
  fi
  rc=1
  return "$rc"
}

line_should_disable() {
  local line="$1"
  [[ "$line" =~ ^[[:space:]]*# ]] && return 1
  if [[ "$line" =~ ^[[:space:]]*(PasswordAuthentication|PermitEmptyPasswords)[[:space:]]+ ]]; then
    return 0
  fi
  if [[ "$KEEP_KBD" -eq 0 && "$line" =~ ^[[:space:]]*(KbdInteractiveAuthentication|ChallengeResponseAuthentication)[[:space:]]+ ]]; then
    return 0
  fi
  if [[ "$line" =~ ^[[:space:]]*PubkeyAuthentication[[:space:]]+no[[:space:]]*(#.*)?$ ]]; then
    return 0
  fi
  return 1
}

neutralize_file() {
  local file="$1"
  local tmp
  tmp="$(mktemp)"
  (
    shopt -s nocasematch
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
      if line_should_disable "$line"; then
        printf '# disabled-by-disable-password-login.sh: %s\n' "$line"
      else
        printf '%s\n' "$line"
      fi
    done < "$file"
  ) > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

write_managed_file() {
  local file="$SSHD_CONFIG_DIR/$MANAGED_BASENAME"
  local tmp
  install -d -m 0755 "$SSHD_CONFIG_DIR"
  tmp="$(mktemp)"
  {
    printf '%s\n' "# Generated by disable-password-login.sh"
    printf '%s\n' "# 关闭 SSH 密码登录。再次运行脚本会覆盖本文件。"
    printf '%s\n' "PasswordAuthentication no"
    printf '%s\n' "PermitEmptyPasswords no"
    printf '%s\n' "PubkeyAuthentication yes"
    if [[ "$KEEP_KBD" -eq 0 ]]; then
      printf '%s\n' "KbdInteractiveAuthentication no"
      printf '%s\n' "ChallengeResponseAuthentication no"
      printf '%s\n' "# 若要禁止公钥以外的所有方式，取消下一行注释。"
      printf '%s\n' "# AuthenticationMethods publickey"
    fi
  } > "$tmp"
  install -m 0644 "$tmp" "$file"
  rm -f "$tmp"
}

include_present() {
  local line trimmed
  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%%#*}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    if [[ "$trimmed" == "Include ${INCLUDE_DIR}/*.conf" ]]; then
      return 0
    fi
  done < "$SSHD_CONFIG"
  return 1
}

ensure_include() {
  local tmp
  include_present && return 0
  tmp="$(mktemp)"
  {
    printf '%s\n' "Include ${INCLUDE_DIR}/*.conf"
    cat "$SSHD_CONFIG"
  } > "$tmp"
  cat "$tmp" > "$SSHD_CONFIG"
  rm -f "$tmp"
}

apply_config_files() {
  local file
  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    neutralize_file "$file"
  done < <(each_config_file)
  write_managed_file
  ensure_include
}

create_backup() {
  local stamp
  stamp="$(date +%Y%m%d%H%M%S)"
  BACKUP_DIR="${BACKUP_DIR_ROOT}/disable-password-login-${stamp}"
  mkdir -p "$BACKUP_DIR"
  cp -a "$SSHD_CONFIG" "$BACKUP_DIR/sshd_config"
  if [[ -d "$SSHD_CONFIG_DIR" ]]; then
    cp -a "$SSHD_CONFIG_DIR" "$BACKUP_DIR/sshd_config.d"
    CONFIG_DIR_WAS_PRESENT=1
  else
    CONFIG_DIR_WAS_PRESENT=0
  fi
}

rollback() {
  [[ "$IN_ROLLBACK" -eq 0 ]] || return 0
  [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]] || return 0
  IN_ROLLBACK=1
  if [[ -f "$BACKUP_DIR/sshd_config" ]]; then
    cp -a "$BACKUP_DIR/sshd_config" "$SSHD_CONFIG"
  fi
  if [[ "$CONFIG_DIR_WAS_PRESENT" -eq 1 && -d "$BACKUP_DIR/sshd_config.d" ]]; then
    rm -rf "$SSHD_CONFIG_DIR"
    cp -a "$BACKUP_DIR/sshd_config.d" "$SSHD_CONFIG_DIR"
  elif [[ "$CONFIG_DIR_WAS_PRESENT" -eq 0 ]]; then
    rm -rf "$SSHD_CONFIG_DIR"
  fi
  printf '已回滚 SSH 配置。备份仍在 %s\n' "$BACKUP_DIR" >&2
}

write_cloud_init() {
  local file="$CLOUD_CFG_DIR/99-disable-ssh-password.cfg"
  [[ -d "$CLOUD_CFG_DIR" ]] || return 0
  if [[ -f "$file" ]]; then
    if grep -Eq '^ssh_pwauth:[[:space:]]*(false|0)[[:space:]]*$' "$file"; then
      return 0
    fi
    printf '注意: %s 已存在。请确认 ssh_pwauth 为 false，否则 cloud-init 可能把密码登录重新打开。\n' "$file" >&2
    return 0
  fi
  cat > "$file" <<'EOF'
# Written by disable-password-login.sh
# 阻止 cloud-init 在下次初始化时重新打开 SSH 密码登录。
ssh_pwauth: false
EOF
  chmod 0644 "$file"
}

strip_unknown_options() {
  local err_file="$1"
  local managed="$SSHD_CONFIG_DIR/$MANAGED_BASENAME"
  local opt tmp changed=0
  for opt in ChallengeResponseAuthentication KbdInteractiveAuthentication; do
    if grep -F -q "Bad configuration option: ${opt}" "$err_file" || grep -F -q "Unsupported option: ${opt}" "$err_file"; then
      tmp="$(mktemp)"
      grep -viE "^[[:space:]]*${opt}[[:space:]]+" "$managed" > "$tmp" || true
      cat "$tmp" > "$managed"
      rm -f "$tmp"
      changed=1
    fi
  done
  [[ "$changed" -eq 1 ]]
}

ensure_privsep_dir() {
  # sshd -t 会检查这个目录。systemd 正常开机时由 tmpfiles 创建；容器里可能还没有。
  [[ -d /run/sshd ]] && return 0
  mkdir -p /run/sshd 2>/dev/null || return 0
  chmod 0755 /run/sshd 2>/dev/null || true
}

validate_syntax() {
  local err_file attempt
  ensure_privsep_dir
  err_file="$(mktemp)"
  for attempt in 1 2 3; do
    if "$SSHD_BIN" -t -f "$SSHD_CONFIG" 2>"$err_file"; then
      rm -f "$err_file"
      return 0
    fi
    if [[ "$attempt" -lt 3 ]] && strip_unknown_options "$err_file"; then
      continue
    fi
    printf '%s\n' "sshd 配置校验失败:" >&2
    cat "$err_file" >&2
    rm -f "$err_file"
    return 1
  done
}

setting_value() {
  local key="$1"
  local text="$2"
  local key_lower="${key,,}"
  local line lower
  while IFS= read -r line; do
    lower="${line,,}"
    if [[ "$lower" == "${key_lower} "* ]]; then
      printf '%s\n' "${lower#"${key_lower} "}"
      return 0
    fi
  done <<<"$text"
  return 1
}

require_setting() {
  local key="$1"
  local want="$2"
  local text="$3"
  local got=""
  got="$(setting_value "$key" "$text" || true)"
  if [[ "$got" != "$want" ]]; then
    printf '校验失败: 期望 %s %s，实际 %s\n' "$key" "$want" "${got:-<未设置>}" >&2
    return 1
  fi
}

validate_effective() {
  local effective err_file
  err_file="$(mktemp)"
  if ! effective="$("$SSHD_BIN" -T -f "$SSHD_CONFIG" 2>"$err_file")"; then
    printf '%s\n' "无法读取 sshd 生效配置:" >&2
    cat "$err_file" >&2
    rm -f "$err_file"
    return 1
  fi
  rm -f "$err_file"
  require_setting passwordauthentication no "$effective"
  require_setting permitemptypasswords no "$effective"
  require_setting pubkeyauthentication yes "$effective"
  if [[ "$KEEP_KBD" -eq 0 ]]; then
    if setting_value kbdinteractiveauthentication "$effective" >/dev/null; then
      require_setting kbdinteractiveauthentication no "$effective"
    elif setting_value challengeresponseauthentication "$effective" >/dev/null; then
      require_setting challengeresponseauthentication no "$effective"
    else
      printf '%s\n' "校验失败: 无法确认键盘交互认证已关闭。" >&2
      return 1
    fi
  fi
  printf '%s\n' "生效配置:"
  printf '%s\n' "$effective" | grep -Ei '^(passwordauthentication|kbdinteractiveauthentication|challengeresponseauthentication|permitemptypasswords|pubkeyauthentication|authenticationmethods) ' || true
}

reload_sshd() {
  is_system_target || return 0
  if ! command -v systemctl >/dev/null 2>&1; then
    if [[ -f /run/sshd.pid ]]; then
      kill -HUP "$(cat /run/sshd.pid)"
      return 0
    fi
    printf '%s\n' "未找到 systemctl。配置已写入，请手动重载 sshd。"
    return 0
  fi
  if systemctl is-active --quiet ssh 2>/dev/null; then
    systemctl reload ssh
    return 0
  fi
  if systemctl is-active --quiet sshd 2>/dev/null; then
    systemctl reload sshd
    return 0
  fi
  printf '%s\n' "SSH 服务当前没有在运行。配置已写入，下次启动时生效。"
}

run_against() {
  SSHD_CONFIG="$1"
  SSHD_CONFIG_DIR="$2"
  INCLUDE_DIR="$3"
  shift 3
  "$@"
}

preview() {
  local real_config="$SSHD_CONFIG"
  local real_dir="$SSHD_CONFIG_DIR"
  local real_include="$INCLUDE_DIR"
  local tmp rc
  tmp="$(mktemp -d)"
  # 在子 shell 里改副本。run_against 改的是子 shell 里的路径变量，不会碰到原配置。
  if (
    cp -a "$real_config" "$tmp/sshd_config"
    if [[ -d "$real_dir" ]]; then
      cp -a "$real_dir" "$tmp/sshd_config.d"
    else
      mkdir -p "$tmp/sshd_config.d"
    fi
    run_against "$tmp/sshd_config" "$tmp/sshd_config.d" "$real_include" apply_config_files
    printf '\n%s\n' "----- 将写入 ${real_dir}/${MANAGED_BASENAME} -----"
    cat "$tmp/sshd_config.d/$MANAGED_BASENAME"
    printf '\n%s\n' "----- ${real_config} 差异 -----"
    if diff -u "$real_config" "$tmp/sshd_config"; then
      printf '%s\n' "(无变化)"
    fi
    if [[ -d "$real_dir" ]]; then
      printf '\n%s\n' "----- ${real_dir} 差异 -----"
      if diff -ru "$real_dir" "$tmp/sshd_config.d"; then
        printf '%s\n' "(无变化)"
      fi
    fi
  ); then
    rc=0
  else
    rc=$?
  fi
  rm -rf "$tmp"
  return "$rc"
}

on_error() {
  local rc=$?
  if [[ "$APPLY_STARTED" -eq 1 && "$APPLY_VALIDATED" -ne 1 ]]; then
    printf '%s\n' "修改过程中出错，正在回滚 SSH 配置。" >&2
    rollback || true
  fi
  exit "$rc"
}

main() {
  parse_args "$@"
  INCLUDE_DIR="$SSHD_CONFIG_DIR"

  if ! find_sshd; then
    die "未找到 sshd。请先安装 OpenSSH 服务器，例如: sudo apt-get install -y openssh-server"
  fi
  if [[ ! -f "$SSHD_CONFIG" ]]; then
    die "未找到 ${SSHD_CONFIG}。"
  fi

  check_authorized_keys
  if ! authentication_methods_allow_pubkey; then
    die "已中止。请先把 AuthenticationMethods 改成包含单独的 publickey，或使用 --force。"
  fi

  if [[ "$KEEP_KBD" -eq 1 ]]; then
    printf '%s\n' "警告: 保留了键盘交互认证。在常见 PAM 配置里，这条路径仍然可以输入密码。" >&2
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '%s\n' "dry-run: 不会写入，也不会重载 sshd。"
    preview
    return 0
  fi

  if is_system_target && [[ "$(id -u)" -ne 0 ]]; then
    die "请用 root 运行，例如: sudo ./disable-password-login.sh"
  fi

  trap on_error ERR
  create_backup
  APPLY_STARTED=1
  apply_config_files
  if ! validate_syntax || ! validate_effective; then
    rollback
    APPLY_VALIDATED=1
    die "未重载 sshd。当前配置已恢复。"
  fi
  APPLY_VALIDATED=1
  trap - ERR
  write_cloud_init
  reload_sshd
  printf '密码登录已关闭。备份: %s\n' "$BACKUP_DIR"
  printf '%s\n' "请新开一个终端，用公钥登录确认成功后，再断开当前会话。"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
