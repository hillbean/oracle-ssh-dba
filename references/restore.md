# 还原

还原会覆盖目标实例上的数据。先说清楚再动手。

## 确认清单（必须跟用户对齐）

- 目标主机、SID（尤其是 `source-database` 源库 vs `backup-database` 备份库）
- 备份目录、是否带归档
- DBID（`inspect` 或备份日志里的 `DBID=`）
- 完全恢复还是 PITR（`SET UNTIL SEQUENCE`）
- 是否 `OPEN RESETLOGS`（默认会开，新 incarnation，还原点之后的数据没了）

用户明确说「确认还原」或 `CONFIRM_RESTORE` 之后，才加 `--confirm CONFIRM_RESTORE`。先 `--dry-run` 把计划打出来。

## 还原到备份库前先清表

往 `backup-database`（示例 `db-backup.example.com` / `192.0.2.20`）还原时，**默认先 DROP 所有非 Oracle 维护用户下的表**（`CASCADE CONSTRAINTS PURGE`），再做 RMAN 或 Data Pump。目的是清掉备份库里已有行，避免导入后主键/唯一约束冲突或出现重复条目。

- 不动 `SYS` / `SYSTEM` / `XDB` 等维护用户。
- **禁止**对 `source-database`（示例 `db-source.example.com` / `192.0.2.10`）清表。
- 库必须是 `OPEN READ WRITE`。RMAN 若目标库已经关掉，会跳过清表（随后数据文件会被整库覆盖）。Data Pump 必须先清成功再导入。
- `--skip-wipe` 可跳过。Data Pump 若跳过清表且 `TABLE_EXISTS=SKIP`，脚本会拒绝执行。
- 只清某些用户：`--owners SCOTT,HR`。

单独清表（仍只要备份库）：

```bash
python ora_ssh.py wipe-tables --profile backup-database --dry-run
python ora_ssh.py wipe-tables --profile backup-database --confirm CONFIRM_WIPE
```

## RMAN 还原

```bash
python ora_ssh.py restore --profile backup-database --type rman \
  --backup-dir /home/oracle/backup/from_source/20260101_020001 \
  --arch-dir /home/oracle/backup/from_source/archivelog/20260101_020001 \
  --dbid 1234567890 --dry-run

python ora_ssh.py restore --profile backup-database --type rman \
  --backup-dir /home/oracle/backup/from_source/20260101_020001 \
  --arch-dir /home/oracle/backup/from_source/archivelog/20260101_020001 \
  --dbid 1234567890 --confirm CONFIRM_RESTORE
```

`--confirm CONFIRM_RESTORE` 会先清表再还原。模板步骤（单次 RMAN 会话，不要拆成多次 RMAN 以免丢掉 MOUNT/catalog）：

1. （备份库 OPEN 时）DROP 所有业务表
2. `SHUTDOWN IMMEDIATE`，不行再 `ABORT`
3. `SET DBID` → `STARTUP NOMOUNT` → restore spfile → `STARTUP FORCE NOMOUNT`
4. restore controlfile → `ALTER DATABASE MOUNT`
5. `CATALOG START WITH '<backup>/' NOPROMPT`（有归档再 catalog 归档目录）
6. `RESTORE DATABASE` + `RECOVER DATABASE`（PITR 则 `SET UNTIL SEQUENCE n THREAD 1`）
7. 默认 `ALTER DATABASE OPEN RESETLOGS`
8. `lsnrctl start`，必要时改 `local_listener` 指向目标 IP

PITR：`--until-sequence` 用**下一**个序号（要应用到 seq 24010，则 UNTIL SEQUENCE 24011）。

`--no-resetlogs` 只恢复到 MOUNT，留给用户自己 OPEN。

目录里要有 `controlfile_*.bkp` 和 `spfile_*.bkp`。没有就先 `ls` 备份集，不要瞎猜文件名。

## Data Pump 导入

```bash
python ora_ssh.py restore --profile backup-database --type datapump \
  --dump /home/oracle/backup/datapump/20260101_120000/exp_20260101_120000.dmp \
  --schemas SCOTT --dry-run
```

`--table-exists SKIP|REPLACE|TRUNCATE|APPEND`。`--remap-schema OLD:NEW` 换用户。导入前会按上面规则清表；导入时目标库必须 OPEN。

## 失败时

`poll --log` 看最后 40 行。常见原因：DBID 不对、备份集不在目标机、路径磁盘不够、controlfile 找不到、PITR 序号超出归档。
不要在半还原状态再开一次 `OPEN RESETLOGS` 碰运气；先看 `v$database.open_mode` 和 RMAN 日志。
