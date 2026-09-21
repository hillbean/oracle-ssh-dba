# oracle-ssh-dba

Cursor Agent Skill：通过 SSH 登录 Linux 上的 Oracle，查询数据库型号/版本，并用 RMAN 或 Data Pump 做备份与还原。

本机不必安装 Oracle 客户端。默认路径是 **Windows 工作机 → SSH → `su - oracle` → sqlplus / RMAN**。

文档中的主机名和 IP 都是示例（`db-source.example.com` / `192.0.2.10`），请改成你自己的环境。

## 能做什么

| 能力 | 说明 |
|------|------|
| 查型号 | 版本、Edition、DBID、OPEN/归档模式、监听、磁盘 |
| 备份 | 默认在线 RMAN L0；也可用 Data Pump 导出 |
| 还原 | RMAN（含 PITR）或 Data Pump 导入 |
| 清表 | 还原到备份库前，先删除备份库业务表，避免重复行 |

Agent 使用说明见 [SKILL.md](SKILL.md)。细节：

- [references/inspect.md](references/inspect.md) — 查型号
- [references/backup.md](references/backup.md) — 备份
- [references/restore.md](references/restore.md) — 还原与清表
- [references/connections.md](references/connections.md) — 连接配置

## 安装到 Cursor

把本仓库放到 Cursor 的 skills 目录后**新开一个对话**才会加载。

Windows:

```powershell
git clone https://github.com/hillbean/oracle-ssh-dba.git $env:USERPROFILE\.cursor\skills\oracle-ssh-dba
pip install -r $env:USERPROFILE\.cursor\skills\oracle-ssh-dba\scripts\requirements.txt
```

macOS / Linux:

```bash
git clone https://github.com/hillbean/oracle-ssh-dba.git ~/.cursor/skills/oracle-ssh-dba
pip install -r ~/.cursor/skills/oracle-ssh-dba/scripts/requirements.txt
```

依赖：Python 3、`paramiko`。本机可以没有 sqlplus。

## 配置连接

密码只放本机文件或环境变量，**不要提交到 Git**。

```powershell
python $env:USERPROFILE\.cursor\skills\oracle-ssh-dba\scripts\ora_ssh.py init-config
```

然后编辑 `%USERPROFILE%\.oracle-ssh-dba\connections.json`，把示例改成真实主机。模板见 [connections.example.json](connections.example.json)。

```json
{
  "hosts": {
    "source-database": {
      "host": "db-source.example.com",
      "role": "source",
      "ssh_user": "root",
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

| 字段 | 说明 |
|------|------|
| `host` | 主机名或 IP |
| `role` | `source` 禁止清表，备份目录为 oracle 用户下 `backup/full`；`backup` 还原前清表，目录为 `backup/from_source` |
| `ssh_pass_file` | 一行密码的文本文件（UTF-8）。也可改用 `ssh_key` |

不要填写 `oracle_home`、`backup_root`。登录服务器后从 oratab 确认 `ORACLE_HOME`，备份路径按角色自动拼到 oracle 用户家目录。

密码文件示例（只有一行，不要提交）：

```text
your-ssh-password
```

## 常用命令

参数写在子命令后面。入口脚本：`scripts/ora_ssh.py`。

```powershell
$py = "$env:USERPROFILE\.cursor\skills\oracle-ssh-dba\scripts\ora_ssh.py"

python $py inspect --profile source-database
python $py backup --profile source-database --type rman-l0
python $py poll --profile source-database --log /home/oracle/scripts/logs/ora_ssh_l0_<TAG>.log

python $py restore --profile backup-database --type rman --backup-dir <dir> --dbid <dbid> --dry-run
python $py restore --profile backup-database --type rman --backup-dir <dir> --dbid <dbid> --confirm CONFIRM_RESTORE
```

没有 profile 时：

```powershell
python $py inspect --host db-source.example.com --user root --pass-file C:\Users\you\ssh.pass --sid orcl
```

| 子命令 | 用途 |
|--------|------|
| `inspect` | 查型号、状态、监听 |
| `backup` | RMAN L0/L1 或 Data Pump |
| `restore` | 还原（备份库会先清业务表） |
| `wipe-tables` | 只清备份库业务表 |
| `sqlplus` / `rman` / `exec` / `oracle` | 临时 SQL、RMAN、远程命令 |
| `poll` | 看远程备份/还原日志 |

在 Cursor 对话里也可以直接说：「查源库型号」「给源库打 L0」「把备份还原到备份库（先出计划）」。

## 安全

- 只连你明确指定的主机。
- 密码不进聊天、日志、commit、截图。
- **还原会覆盖目标库。** 先 `--dry-run`，用户说「确认还原」后再加 `--confirm CONFIRM_RESTORE`。
- 还原到 `backup-database` 时默认先 DROP 业务表（不动 SYS/SYSTEM）。`source-database` 禁止清表。
- 不要主动执行 `DELETE OBSOLETE`（可能连归档一起删）。只 `REPORT OBSOLETE`，除非用户明确要求删除。
- 长时间任务用远程 `nohup`，用 `poll` 看日志。

## 目录

```text
oracle-ssh-dba/
├── SKILL.md                 # Agent 指令
├── README.md                # 本说明
├── connections.example.json # 连接模板
├── references/              # 查型号 / 备份 / 还原 / 连接
└── scripts/
    ├── ora_ssh.py           # 入口
    ├── requirements.txt
    └── remote/              # 上传到 Linux 执行的脚本
```
