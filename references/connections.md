# 连接配置

密码只放本机文件或环境变量，不进 git、不进对话。

## 配置文件

默认：`%USERPROFILE%\.oracle-ssh-dba\connections.json`

```bash
python ora_ssh.py init-config
```

已存在则不覆盖。`--force` 才重写。把示例主机名改成你的实际环境。

**不要填 `oracle_home`、`backup_root`。** 登录后自动确认：

- `ORACLE_HOME`：oratab / pmon / sqlplus
- 备份目录：oracle 用户家目录下
  - 源库 `role=source` → `$HOME/backup/full`
  - 备份库 `role=backup` → `$HOME/backup/from_source`

```json
{
  "hosts": {
    "source-database": {
      "host": "db-source.example.com",
      "role": "source",
      "ssh_user": "root",
      "ssh_port": 22,
      "ssh_pass_file": "C:/Users/you/ssh.pass",
      "oracle_sid": "orcl"
    },
    "backup-database": {
      "host": "db-backup.example.com",
      "role": "backup",
      "ssh_user": "root",
      "ssh_pass_file": "C:/Users/you/ssh.pass",
      "oracle_sid": "orcl"
    }
  }
}
```

`host` 可以是主机名或 IP（文档示例网段 `192.0.2.0/24`）。

| 字段 | 说明 |
|------|------|
| `role` | `source` 禁止清表、备份写到 `backup/full`；`backup` 还原前清表、目录为 `backup/from_source` |
| `ssh_pass_file` | 一行密码，UTF-8。与 `ssh_key` 二选一 |
| `ssh_key` | 私钥路径 |
| `oracle_user` | 默认 `oracle`。SSH 若已是 oracle，不再 `su` |
| `oracle_sid` | 多实例时填写；单实例可省略，登录后从 pmon 探测 |

命令行 `--host/--user/--pass-file/--sid` 会覆盖 profile。

密码环境变量：`ORACLE_SSH_PASS_FILE` 或 `ORACLE_SSH_PASS`。不要用 `--password`。

## 依赖

```bash
pip install -r %USERPROFILE%\.cursor\skills\oracle-ssh-dba\scripts\requirements.txt
```

需要能访问目标网段。本机可以没有 Oracle 客户端。

## 鉴权顺序

1. `ssh_pass_file` / `ORACLE_SSH_PASS_FILE` / `ORACLE_SSH_PASS`
2. `ssh_key`
3. SSH agent + 默认密钥

密码登录会关掉 agent/默认密钥，避免混用。未知主机密钥当前是自动接受；只连用户指定的主机。
