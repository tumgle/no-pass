# 关闭 SSH 密码登录

`disable-password-login.sh` 把一台 Linux 服务器的 SSH 密码登录关掉，只留公钥。

密码能从两条认证通路进来：`password`，以及键盘交互（`keyboard-interactive` / `challenge-response`）。只关第一条时，客户端仍可能通过 PAM 弹出密码框。脚本默认两条都关。

## 使用前

当前登录方式必须还能用公钥，否则重载后进不来。把公钥放进对应用户的 `~/.ssh/authorized_keys`，并先开一个已经连上的会话留着，再用另一个终端验证。

需要已安装 OpenSSH 服务器（`sshd`）。

## 一键

在要关闭密码登录的服务器上执行。这条命令会提权、装好脚本，然后打开菜单。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tumgle/no-pass/main/install.sh)
```

菜单里可以先看改动、再关闭密码登录。不进菜单、直接执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tumgle/no-pass/main/install.sh) --dry-run
bash <(curl -fsSL https://raw.githubusercontent.com/tumgle/no-pass/main/install.sh) --force
```

装好之后，在这台机器上执行 `no-pass` 会再次打开菜单。

## 在脚本目录里运行

```bash
sudo ./disable-password-login.sh --dry-run
sudo ./disable-password-login.sh
```

只看会改什么、不写盘：

```bash
sudo ./disable-password-login.sh --dry-run
```

机器上还没有公钥、但控制台一定进得去时：

```bash
sudo ./disable-password-login.sh --force
```

`--keep-keyboard-interactive` 会留下键盘交互认证。常见 PAM 配置里，这条路径仍然接受密码，一般不要加这个参数。

## 脚本改什么

- 写入 `/etc/ssh/sshd_config.d/00-disable-password-auth.conf`
  - `PasswordAuthentication no`
  - `KbdInteractiveAuthentication no`
  - `ChallengeResponseAuthentication no`
  - `PermitEmptyPasswords no`
  - `PubkeyAuthentication yes`
- 注释掉主配置和其他 drop-in（包括 cloud-init 的 `50-cloud-init.conf`）里已经生效的上述选项。OpenSSH 采用先出现的值为准，所以只改主文件、留下 drop-in 里的 `yes`，密码登录还会开着。
- 若主配置没有 `Include /etc/ssh/sshd_config.d/*.conf`，会补到文件开头。
- `sshd -t` 通过、并且 `sshd -T` 确认密码认证已关闭之后，才重载 `ssh` 或 `sshd`。
- 若存在 `/etc/cloud/cloud.cfg.d/`，写入 `ssh_pwauth: false`，避免下次 cloud-init 初始化把密码登录打开。
- 改动前把原配置复制到 `/var/backups/disable-password-login-<时间>/`。

`UsePAM` 保持原样。在 Ubuntu 上关掉它会破坏登录会话，而且在 `PasswordAuthentication no` 之后，PAM 也不会重新打开密码登录。

root 是否允许公钥登录，沿用原来的 `PermitRootLogin`，脚本不改这项。

## 确认

```bash
sudo sshd -T | grep -E '^(passwordauthentication|kbdinteractiveauthentication|permitemptypasswords|pubkeyauthentication) '
```

期望看到：

```text
permitemptypasswords no
pubkeyauthentication yes
passwordauthentication no
kbdinteractiveauthentication no
```

然后新开一个终端，用公钥登录一次，再断开原来的会话。

## 恢复

把脚本结束时打印的备份路径换进去：

```bash
sudo cp -a /var/backups/disable-password-login-时间戳/sshd_config /etc/ssh/sshd_config
sudo rm -rf /etc/ssh/sshd_config.d
sudo cp -a /var/backups/disable-password-login-时间戳/sshd_config.d /etc/ssh/sshd_config.d
sudo sshd -t && sudo systemctl reload ssh
```

校验失败时脚本会自己回滚，不会重载正在运行的 sshd。

## 测试

```bash
bash tests/test-disable-password-login.sh
```

装有 `sshd` 且用 root 运行时，测试还会用真实的 `sshd -t` / `sshd -T` 核对一份配置副本。测试不会改本机的 `/etc/ssh`。
