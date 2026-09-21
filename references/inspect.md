# 查 Oracle 型号 / 版本

「型号」按下面几项一起报，不要只报 `version=19.0.0.0.0`（19c 的 version 列经常停在 19.0）。

| 含义 | 来源 |
|------|------|
| 产品线 + Edition | `v$version.banner` / `banner_full` |
| 精确版本 | `v$instance.version_full`（12.2+）；否则看 banner 里的 Version |
| 实例状态 | `v$instance.status`、`v$database.open_mode` |
| 身份 | `name`、`dbid`、`db_unique_name` |
| 架构 | `platform_name`、是否 CDB、是否 RAC |

## 默认做法

```bash
python ora_ssh.py inspect --profile source-database
```

`inspect` 会：解析 oratab、看 pmon/监听、跑 sqlplus、`df -h`。11g 没有的列（`version_full`、`cdb`、`edition`）会报 ORA-00904，忽略即可。

## 手工 SQL（sqlplus --sql / --file）

```sql
SET LINES 200 PAGES 100
COL banner FOR A80
SELECT banner FROM v$version;
SELECT banner_full FROM v$version WHERE banner_full IS NOT NULL;

SELECT instance_name, host_name, version, status FROM v$instance;
-- 18c/19c:
-- SELECT version_full, edition FROM v$instance;

SELECT name, dbid, open_mode, log_mode, database_role, platform_name
  FROM v$database;

SELECT product, version, status
  FROM product_component_version
 WHERE product LIKE 'Oracle%';
```

Edition 从 banner 判断：`Enterprise Edition` / `Standard Edition 2` / `Standard Edition` / `Express Edition`。

## 报给用户的格式

- 主机 / IP / SID
- 型号：`Oracle Database 19c Enterprise Edition 19.3.0.0.0`
- 状态：OPEN + READ WRITE / MOUNTED / NOMOUNT
- DBID、归档模式、平台
- 监听 READY 与否、根盘使用率

库没起来时不要假装查到了版本：先报 pmon/oratab，再问是否要 `STARTUP`。
