# 备份

默认：**RMAN 在线 L0**（库保持 OPEN）。用户要「导用户/导表」才用 Data Pump。

不要主动 `DELETE OBSOLETE`。`DELETE OBSOLETE` 可能把过期归档一起删掉；用户没点名就只 `REPORT OBSOLETE`。

## RMAN L0（物理全备）

```bash
python ora_ssh.py backup --profile source-database --type rman-l0
python ora_ssh.py poll --profile source-database --log /home/oracle/scripts/logs/ora_ssh_l0_<TAG>.log
```

模板 `scripts/remote/backup_rman.sh` 会：

1. 记录当前日志序号
2. `BACKUP INCREMENTAL LEVEL 0 DATABASE`
3. 备份 controlfile + spfile 到同一目录（还原要用）
4. `ALTER SYSTEM ARCHIVE LOG CURRENT`
5. 把本次窗口内的归档拷到 `<TAG>_archivelog/`（`--no-arch` 可跳过）

增量用 `--type rman-l1`。L1 不能单独还原，必须有更早的 L0。

备份前看 `df -h`。目录写不下就停，先腾空间或换 `--backup-root`。

长时间任务默认 `nohup`。日志出现 `BACKUP_OK` 才算成功；`RMAN_BACKUP_FAILED` 或没有 `controlfile_*.bkp` 就是失败。

## Data Pump（逻辑导出）

```bash
python ora_ssh.py backup --profile source-database --type datapump --schemas SCOTT
python ora_ssh.py backup --profile source-database --type datapump --full
```

脚本会 `CREATE OR REPLACE DIRECTORY` 指向 `backup_root/datapump/<TAG>/`，再 `expdp "/ as sysdba"`。

适合搬用户、对照环境灌数。不能替代 RMAN 做介质恢复。

## 手工 RMAN（少用）

```bash
python ora_ssh.py rman --profile source-database --cmd "LIST BACKUP SUMMARY;"
python ora_ssh.py rman --profile source-database --cmd "REPORT SCHEMA;"
python ora_ssh.py rman --profile source-database --cmd "REPORT OBSOLETE;"
```

`LIST OBSOLETE` 不是合法语法，要用 `REPORT OBSOLETE`。
