---
name: oracle-ssh-dba
description: >-
  通过 SSH 登录 Linux 上的 Oracle 服务器，查询数据库型号/版本/版本号/Edition，并用 RMAN 或 Data Pump 做备份与还原。
  当用户要连 SSH、连 Oracle、查数据库型号、查版本、sqlplus、RMAN、expdp/impdp、备份、还原、恢复、PITR、
  打开/关闭实例、看监听，或提到 11g/12c/19c/21c、ORACLE_SID、ORACLE_HOME 时使用本 skill。
---

# Oracle SSH DBA

本机通常没有 sqlplus。默认路径是：**Windows 工作机 → SSH 到 Linux → `su - oracle` → sqlplus/RMAN**。
不要在本机装 Oracle 客户端，也不要把密码打进聊天或命令行。安装与命令说明见 [README.md](README.md)。

执行前先读本文件。查型号读 [references/inspect.md](references/inspect.md)；备份读 [references/backup.md](references/backup.md)；还原读 [references/restore.md](references/restore.md)；连接配置读 [references/connections.md](references/connections.md)。

## 工具

入口脚本（执行它，不要现场重写 SSH/RMAN）：

```bash
python "%USERPROFILE%\.cursor\skills\oracle-ssh-dba\scripts\ora_ssh.py" --help
```

依赖：Python 3、`pip install paramiko`。密码只从 `ssh_pass_file` 或环境变量读取，脚本永不打印密码。

首次使用：

```bash
python "%USERPROFILE%\.cursor\skills\oracle-ssh-dba\scripts\ora_ssh.py" init-config
```

然后编辑 `%USERPROFILE%\.oracle-ssh-dba\connections.json`，填主机、SID、密码文件路径。

## 安全

- 只连用户点名的主机。未授权的地址不要扫、不要试密码。
- 密码、口令文件内容、连接串里的口令：**不写进对话、日志、commit、截图**。
- **还原会覆盖目标库。** 必须用户明确说「确认还原」或 `CONFIRM_RESTORE` 之后，才加 `--confirm CONFIRM_RESTORE`。
- **还原到 `backup-database`（示例 `db-backup.example.com` / `192.0.2.20`）前，先删掉备份库上所有业务表**，避免还原/导入后出现重复行。SYS/SYSTEM 等 Oracle 维护用户不动。源库 `source-database`（示例 `db-source.example.com` / `192.0.2.10`）禁止清表。
- 生产库还原前先陈述：目标主机、SID、备份集路径、是否 `OPEN RESETLOGS`、会丢掉还原点之后的数据。
- 不要主动跑 `DELETE OBSOLETE`：它可能连归档一起删。用户没要求就只 `REPORT OBSOLETE`。
- 长时间备份/还原用远程 `nohup`，用 `poll` 看日志，不要把 SSH timeout 拉到几小时还傻等。

## 工作流

按用户意图选一条，不要一次做完所有事。

### 1. 连通并查型号

```bash
python "%USERPROFILE%\.cursor\skills\oracle-ssh-dba\scripts\ora_ssh.py" inspect --profile <name>
```

没有 profile 时把连接参数放在子命令后面：`inspect --host db-source.example.com --user root --pass-file <file> --sid orcl`。

向用户汇报：主机名、SID、版本/Edition（型号）、DBID、OPEN 模式、归档模式、平台、监听、根盘使用率。完整 SQL 见 [references/inspect.md](references/inspect.md)。

### 2. 备份

默认 **RMAN 在线 L0**（库保持 OPEN）。逻辑导出才用 Data Pump。

```bash
python ...\ora_ssh.py backup --profile <name> --type rman-l0
python ...\ora_ssh.py backup --profile <name> --type datapump --schemas SCOTT
python ...\ora_ssh.py poll --profile <name> --log /home/oracle/scripts/logs/<log>
```

备份前看磁盘：`df -h`，备份目录要写得下。细节见 [references/backup.md](references/backup.md)。

### 3. 还原

还原到 `backup-database` 时，**先清业务表再还原**（默认开启）。先 `--dry-run`，得到确认后再执行。

```bash
python ...\ora_ssh.py restore --profile backup-database --type rman --backup-dir <dir> --dbid <dbid> --dry-run
python ...\ora_ssh.py restore --profile backup-database --type rman --backup-dir <dir> --dbid <dbid> --confirm CONFIRM_RESTORE
python ...\ora_ssh.py wipe-tables --profile backup-database --dry-run
```

RMAN 还原默认 `OPEN RESETLOGS`，会开新 incarnation。PITR、Data Pump、清表细节见 [references/restore.md](references/restore.md)。不要对源库清表。

### 4. 临时 SQL / RMAN / Shell

```bash
python ...\ora_ssh.py sqlplus --profile <name> --sql "SELECT name, open_mode FROM v\$database;"
python ...\ora_ssh.py rman --profile <name> --cmd "REPORT SCHEMA;"
python ...\ora_ssh.py exec --profile <name> "hostname; df -h /"
python ...\ora_ssh.py oracle --profile <name> "echo SID=\$ORACLE_SID"
```

多行 SQL 写成本地 `.sql` 再 `--file`。远程脚本必须是 LF 换行；`ora_ssh.py` 上传时会自动去掉 CR。

## 输出

给用户看短结果，不要贴密码或超长 RMAN 日志。

**查型号示例：**

- 主机：`db-source.example.com`（192.0.2.10）
- 实例：`orcl` OPEN / READ WRITE
- 型号：Oracle Database 19c Enterprise Edition 19.3.0.0.0
- DBID：`1234567890`，归档：ARCHIVELOG
- 监听：READY，根盘：72%

**备份/还原：** 返回 TAG、远程目录、日志路径、当前状态（RUNNING / OK / FAILED）。失败时摘最后 30 行日志。

## 示例连接（请改成实际环境）

| 角色 | profile | 主机名 | 示例 IP | SID |
|------|---------|--------|---------|-----|
| 源库 / 生产库 | `source-database` | `db-source.example.com` | 192.0.2.10 | orcl |
| 备份库 / 对照库 | `backup-database` | `db-backup.example.com` | 192.0.2.20 | orcl |

`ORACLE_HOME` 登录后从 oratab/pmon 探测。备份目录在 oracle 用户家目录下自动拼：源库 `backup/full`，备份库 `backup/from_source`。不要让用户填这两项。

SSH 账号一般是 `root`，再 `su - oracle`。本机无 sqlplus、有 OpenSSH；用 paramiko 走密码文件。
