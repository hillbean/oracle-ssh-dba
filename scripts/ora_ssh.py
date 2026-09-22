#!/usr/bin/env python3
"""SSH helper for Oracle DBA tasks. Never prints passwords or pass-file contents."""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

def _paramiko():
    try:
        import paramiko
    except ImportError:
        die("paramiko is required: pip install paramiko")
    return paramiko

SKILL_SCRIPTS = Path(__file__).resolve().parent
REMOTE_TEMPLATES = SKILL_SCRIPTS / "remote"
DEFAULT_CONFIG = Path.home() / ".oracle-ssh-dba" / "connections.json"
CONFIRM_TOKEN = "CONFIRM_RESTORE"
CONFIRM_WIPE = "CONFIRM_WIPE"
SOURCE_PROFILES = {"source-database"}
BACKUP_PROFILES = {"backup-database"}


def die(msg: str, rc: int = 2) -> None:
    sys.stderr.write(msg.rstrip() + "\n")
    raise SystemExit(rc)


def lf_bytes(data: bytes | str) -> bytes:
    if isinstance(data, str):
        data = data.encode("utf-8")
    return data.replace(b"\r\n", b"\n").replace(b"\r", b"\n")


def load_config(path: Path | None) -> dict:
    if path is None:
        env = os.environ.get("ORACLE_SSH_CONFIG")
        path = Path(env) if env else DEFAULT_CONFIG
    if not path.exists():
        return {"hosts": {}}
    return json.loads(path.read_text(encoding="utf-8"))


def resolve_target(args: argparse.Namespace) -> dict:
    cfg = load_config(Path(args.config) if args.config else None)
    hosts = cfg.get("hosts") or {}
    target: dict = {}
    if args.profile:
        if args.profile not in hosts:
            known = ", ".join(sorted(hosts)) or "(none)"
            die(f"unknown profile {args.profile!r}. known: {known}")
        target = dict(hosts[args.profile])
        target["profile"] = args.profile
    if args.host:
        target["host"] = args.host
    if args.user:
        target["ssh_user"] = args.user
    if args.pass_file:
        target["ssh_pass_file"] = args.pass_file
    if args.key:
        target["ssh_key"] = args.key
    if args.sid:
        target["oracle_sid"] = args.sid
    if args.oracle_home:
        target["oracle_home"] = args.oracle_home
    if args.oracle_user:
        target["oracle_user"] = args.oracle_user
    if getattr(args, "backup_root", None):
        target["backup_root"] = args.backup_root
    if not target.get("host"):
        die("need --host or --profile")
    target.setdefault("ssh_user", "root")
    target.setdefault("oracle_user", "oracle")
    target.setdefault("ssh_port", 22)
    target.setdefault("backup_root", "/home/oracle/backup/full")
    return target


def read_password(target: dict) -> str | None:
    path = target.get("ssh_pass_file") or os.environ.get("ORACLE_SSH_PASS_FILE")
    if path:
        p = Path(path)
        if not p.exists():
            die(f"pass file not found: {p}")
        return p.read_text(encoding="utf-8").strip()
    env = os.environ.get("ORACLE_SSH_PASS")
    if env:
        return env.strip()
    return None


def connect(target: dict):
    paramiko = _paramiko()
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    password = read_password(target)
    key = target.get("ssh_key")
    kwargs = {
        "hostname": target["host"],
        "port": int(target.get("ssh_port") or 22),
        "username": target["ssh_user"],
        "timeout": 20,
    }
    if password:
        kwargs["password"] = password
        kwargs["allow_agent"] = False
        kwargs["look_for_keys"] = False
    elif key:
        kwargs["key_filename"] = key
        kwargs["allow_agent"] = False
        kwargs["look_for_keys"] = False
    else:
        kwargs["allow_agent"] = True
        kwargs["look_for_keys"] = True
    try:
        client.connect(**kwargs)
    except Exception as e:
        die(f"SSH connect failed: {e}")
    return client


def run(
    client,
    command: str,
    timeout: int = 60,
    get_pty: bool = False,
) -> tuple[int, str, str]:
    stdin, stdout, stderr = client.exec_command(
        command, timeout=timeout, get_pty=get_pty
    )
    out = stdout.read().decode("utf-8", "replace")
    err = stderr.read().decode("utf-8", "replace")
    rc = stdout.channel.recv_exit_status()
    return rc, out, err


def emit(rc: int, out: str, err: str) -> int:
    sys.stdout.write(out)
    if err:
        sys.stderr.write(err)
    return rc


def sftp_write(client, remote: str, data: bytes | str) -> None:
    payload = lf_bytes(data)
    sftp = client.open_sftp()
    try:
        remote_dir = remote.rsplit("/", 1)[0]
        mkdir_p(sftp, remote_dir)
        with sftp.file(remote, "wb") as f:
            f.write(payload)
        sftp.chmod(remote, 0o755)
    finally:
        sftp.close()


def mkdir_p(sftp, path: str) -> None:
    parts = [p for p in path.split("/") if p]
    built: list[str] = [""] if path.startswith("/") else []
    for part in parts:
        built.append(part)
        cur = "/".join(built) if built[0] == "" else "/".join(built)
        try:
            sftp.stat(cur)
        except Exception:
            sftp.mkdir(cur)


def remote_job_dir() -> str:
    return f"/tmp/ora_ssh_{time.strftime('%Y%m%d%H%M%S')}_{os.getpid()}"


def wrap_as_oracle(target: dict, inner: str) -> str:
    if target["ssh_user"] == target.get("oracle_user", "oracle"):
        return inner
    user = target.get("oracle_user", "oracle")
    return f"su - {user} -c {sh_quote(inner)}"


def target_role(target: dict) -> str:
    role = (target.get("role") or "").strip().lower()
    if role in ("source", "backup"):
        return role
    profile = (target.get("profile") or "").strip()
    if profile in SOURCE_PROFILES:
        return "source"
    if profile in BACKUP_PROFILES:
        return "backup"
    return "other"


def refuse_wipe_on_source(target: dict) -> None:
    if target_role(target) == "source":
        die("refusing to drop tables on source-database")


def should_wipe_before_restore(args: argparse.Namespace, target: dict) -> bool:
    if args.skip_wipe:
        return False
    if args.wipe_tables:
        return True
    role = target_role(target)
    if role == "source":
        return False
    if role == "backup":
        return True
    return args.type == "datapump"


def upload_template(
    client,
    name: str,
    env: dict[str, str],
    job_dir: str | None = None,
) -> tuple[str, str]:
    src = REMOTE_TEMPLATES / name
    if not src.exists():
        die(f"missing template {src}")
    job_dir = job_dir or remote_job_dir()
    remote_script = f"{job_dir}/{name}"
    sftp_write(client, remote_script, src.read_bytes())
    exports = "\n".join(
        f"export {k}={sh_quote(v)}" for k, v in env.items() if v is not None and str(v) != ""
    )
    wrapper = f"""#!/bin/bash
set -euo pipefail
{exports}
bash {remote_script}
"""
    remote_wrap = f"{job_dir}/run.sh"
    sftp_write(client, remote_wrap, wrapper)
    return job_dir, remote_wrap


def oracle_env(target: dict, extra: dict | None = None) -> dict[str, str]:
    env = {}
    if target.get("oracle_sid"):
        env["ORACLE_SID"] = str(target["oracle_sid"])
    if target.get("oracle_home"):
        env["ORACLE_HOME"] = str(target["oracle_home"])
    if extra:
        env.update({k: str(v) for k, v in extra.items() if v is not None})
    return env


def sh_quote(value: str) -> str:
    return "'" + value.replace("'", "'\\''") + "'"


def cmd_init_config(args: argparse.Namespace) -> int:
    dest = Path(args.config) if args.config else DEFAULT_CONFIG
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists() and not args.force:
        print(f"already exists: {dest}")
        return 0
    example = {
        "hosts": {
            "source-database": {
                "host": "db-source.example.com",
                "role": "source",
                "ssh_user": "root",
                "ssh_pass_file": str(Path.home() / "ssh.pass"),
                "oracle_sid": "orcl",
                "oracle_home": "/u01/app/oracle/product/19.0.0/dbhome_1",
                "backup_root": "/home/oracle/backup/full",
            },
            "backup-database": {
                "host": "db-backup.example.com",
                "role": "backup",
                "ssh_user": "root",
                "ssh_pass_file": str(Path.home() / "ssh.pass"),
                "oracle_sid": "orcl",
                "oracle_home": "/u01/app/oracle/product/19.0.0/dbhome_1",
                "backup_root": "/home/oracle/backup/from_source",
            },
        }
    }
    dest.write_text(json.dumps(example, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {dest}")
    print("edit ssh_pass_file / ssh_key, then: ora_ssh.py inspect --profile source-database")
    return 0


def cmd_list_profiles(args: argparse.Namespace) -> int:
    cfg = load_config(Path(args.config) if args.config else None)
    hosts = cfg.get("hosts") or {}
    if not hosts:
        print(f"no profiles in {args.config or DEFAULT_CONFIG}")
        return 1
    for name, h in hosts.items():
        print(f"{name}\t{h.get('ssh_user', 'root')}@{h.get('host')} sid={h.get('oracle_sid', '')}")
    return 0


def cmd_exec(args: argparse.Namespace, as_oracle: bool) -> int:
    target = resolve_target(args)
    client = connect(target)
    try:
        command = args.command
        if as_oracle:
            command = wrap_as_oracle(target, f"bash -lc {sh_quote(args.command)}")
        rc, out, err = run(client, command, timeout=args.timeout, get_pty=args.pty)
        return emit(rc, out, err)
    finally:
        client.close()


def cmd_sql_or_rman(args: argparse.Namespace, kind: str) -> int:
    target = resolve_target(args)
    if args.file:
        body = Path(args.file).read_text(encoding="utf-8")
    else:
        body = args.sql if kind == "sqlplus" else args.cmd
    if not body:
        die(f"need --file or {'--sql' if kind == 'sqlplus' else '--cmd'}")
    job_dir = remote_job_dir()
    if kind == "sqlplus":
        remote_in = f"{job_dir}/stmt.sql"
        script = f"""#!/bin/bash
set -euo pipefail
{"export ORACLE_SID=" + target["oracle_sid"] if target.get("oracle_sid") else ""}
{"export ORACLE_HOME=" + target["oracle_home"] if target.get("oracle_home") else ""}
{"export PATH=$ORACLE_HOME/bin:$PATH" if target.get("oracle_home") else ""}
sqlplus -s / as sysdba @{remote_in}
"""
        if not body.upper().rstrip().endswith("EXIT") and "EXIT;" not in body.upper():
            body = body.rstrip() + "\nEXIT;\n"
    else:
        remote_in = f"{job_dir}/stmt.rman"
        script = f"""#!/bin/bash
set -euo pipefail
{"export ORACLE_SID=" + target["oracle_sid"] if target.get("oracle_sid") else ""}
{"export ORACLE_HOME=" + target["oracle_home"] if target.get("oracle_home") else ""}
{"export PATH=$ORACLE_HOME/bin:$PATH" if target.get("oracle_home") else ""}
rman target / @{remote_in}
"""
        if "EXIT" not in body.upper():
            body = body.rstrip() + "\nEXIT;\n"
    client = connect(target)
    try:
        sftp_write(client, remote_in, body)
        wrap = f"{job_dir}/run.sh"
        sftp_write(client, wrap, script)
        rc, out, err = run(
            client,
            wrap_as_oracle(target, f"bash {wrap}"),
            timeout=args.timeout,
            get_pty=args.pty,
        )
        return emit(rc, out, err)
    finally:
        client.close()


def cmd_inspect(args: argparse.Namespace) -> int:
    target = resolve_target(args)
    client = connect(target)
    try:
        _job, wrap = upload_template(client, "inspect.sh", oracle_env(target))
        rc, out, err = run(
            client,
            wrap_as_oracle(target, f"bash {wrap}"),
            timeout=args.timeout,
            get_pty=args.pty,
        )
        return emit(rc, out, err)
    finally:
        client.close()


def start_job(
    client,
    target: dict,
    job_dir: str,
    wrap: str,
    timeout: int,
    foreground: bool,
    pty: bool,
) -> tuple[int, str, str]:
    if foreground:
        return run(client, wrap_as_oracle(target, f"bash {wrap}"), timeout=timeout, get_pty=pty)
    launcher = f"{job_dir}/launch.sh"
    sftp_write(
        client,
        launcher,
        f"#!/bin/bash\nnohup bash {wrap} >{job_dir}/nohup.out 2>&1 &\necho PID=$!\n",
    )
    return run(client, wrap_as_oracle(target, f"bash {launcher}"), timeout=30, get_pty=pty)


def run_wipe(client, target: dict, args: argparse.Namespace, allow_not_open: bool) -> int:
    refuse_wipe_on_source(target)
    date_tag = time.strftime("%Y%m%d_%H%M%S")
    owners = getattr(args, "owners", None) or ""
    extra = {
        "LOG_DIR": getattr(args, "log_dir", None) or "/home/oracle/scripts/logs",
        "DATE_TAG": date_tag,
        "OWNERS": owners,
        "ALLOW_NOT_OPEN": "1" if allow_not_open else "0",
    }
    _job, wrap = upload_template(client, "wipe_user_tables.sh", oracle_env(target, extra))
    timeout = int(getattr(args, "wipe_timeout", 0) or 0) or max(int(args.timeout), 1800)
    print(f"WIPE_HOST={target['host']}")
    print(f"WIPE_SID={target.get('oracle_sid', '')}")
    print(f"WIPE_OWNERS={owners or 'ALL_USER'}")
    print(f"WIPE_LOG={extra['LOG_DIR']}/ora_ssh_wipe_{date_tag}.log")
    rc, out, err = run(
        client,
        wrap_as_oracle(target, f"bash {wrap}"),
        timeout=timeout,
        get_pty=args.pty,
    )
    emit(rc, out, err)
    if rc != 0:
        print("STATUS=WIPE_FAILED")
    return rc


def cmd_backup(args: argparse.Namespace) -> int:
    target = resolve_target(args)
    date_tag = time.strftime("%Y%m%d_%H%M%S")
    backup_root = target.get("backup_root") or "/home/oracle/backup/full"
    if args.type in ("rman-l0", "rman-l1"):
        extra = {
            "BACKUP_ROOT": backup_root,
            "LEVEL": "0" if args.type == "rman-l0" else "1",
            "DATE_TAG": date_tag,
            "COPY_ARCH": "0" if args.no_arch else "1",
            "LOG_DIR": args.log_dir or "/home/oracle/scripts/logs",
        }
        template = "backup_rman.sh"
        log = f"{extra['LOG_DIR']}/ora_ssh_l{extra['LEVEL']}_{date_tag}.log"
        backup_dir = f"{backup_root}/{date_tag}"
    else:
        extra = {
            "BACKUP_ROOT": backup_root,
            "DATE_TAG": date_tag,
            "SCHEMAS": args.schemas or "",
            "FULL": "1" if args.full else "0",
            "LOG_DIR": args.log_dir or "/home/oracle/scripts/logs",
        }
        template = "backup_dp.sh"
        log = f"{extra['LOG_DIR']}/ora_ssh_dp_{date_tag}.log"
        backup_dir = f"{backup_root}/datapump/{date_tag}"
        if not args.full and not args.schemas:
            die("datapump needs --schemas SCOTT,HR or --full")
    client = connect(target)
    try:
        job_dir, wrap = upload_template(client, template, oracle_env(target, extra))
        rc, out, err = start_job(
            client, target, job_dir, wrap, args.timeout, args.foreground, args.pty
        )
        print(f"JOB={args.type}")
        print(f"HOST={target['host']}")
        print(f"SID={target.get('oracle_sid', '')}")
        print(f"DATE_TAG={date_tag}")
        print(f"DIR={backup_dir}")
        print(f"LOG={log}")
        print(f"JOB_DIR={job_dir}")
        if not args.foreground:
            print(f"POLL=python {Path(__file__).name} poll --host {target['host']} --log {log}")
        return emit(rc, out, err)
    finally:
        client.close()


def cmd_restore(args: argparse.Namespace) -> int:
    target = resolve_target(args)
    want_wipe = should_wipe_before_restore(args, target)
    if want_wipe:
        refuse_wipe_on_source(target)
    if (
        args.type == "datapump"
        and args.skip_wipe
        and (args.table_exists or "SKIP").upper() == "SKIP"
    ):
        die("datapump with --skip-wipe and TABLE_EXISTS=SKIP would keep old rows; use --wipe-tables or --table-exists REPLACE")
    if args.dry_run:
        pass
    elif args.confirm != CONFIRM_TOKEN:
        die(
            "restore refused. after the user confirms, rerun with "
            f"--confirm {CONFIRM_TOKEN} (or --dry-run first)"
        )
    date_tag = time.strftime("%Y%m%d_%H%M%S")
    extra: dict[str, str] = {
        "LOG_DIR": args.log_dir or "/home/oracle/scripts/logs",
        "DATE_TAG": date_tag,
    }
    if args.type == "rman":
        if not args.backup_dir:
            die("rman restore needs --backup-dir")
        if not args.dbid:
            die("rman restore needs --dbid (from inspect)")
        extra.update(
            {
                "BACKUP_SET_DIR": args.backup_dir,
                "DBID": str(args.dbid),
                "ARCH_DIR": args.arch_dir or "",
                "UNTIL_SEQUENCE": str(args.until_sequence) if args.until_sequence else "",
                "OPEN_RESETLOGS": "0" if args.no_resetlogs else "1",
                "LISTENER_HOST": args.listener_host or target["host"],
            }
        )
        template = "restore_rman.sh"
        summary = (
            f"RMAN restore host={target['host']} sid={target.get('oracle_sid')} "
            f"dbid={args.dbid} backup={args.backup_dir} arch={args.arch_dir or '-'} "
            f"until={args.until_sequence or '-'} resetlogs={'no' if args.no_resetlogs else 'yes'}"
        )
    else:
        if not args.dump:
            die("datapump restore needs --dump /path/file.dmp")
        extra.update(
            {
                "DUMP_PATH": args.dump,
                "SCHEMAS": args.schemas or "",
                "FULL": "1" if args.full else "0",
                "TABLE_EXISTS": args.table_exists,
                "REMAP_SCHEMA": args.remap_schema or "",
            }
        )
        template = "restore_dp.sh"
        summary = (
            f"impdp host={target['host']} sid={target.get('oracle_sid')} "
            f"dump={args.dump} schemas={args.schemas or '-'} full={args.full}"
        )
    print(f"PLAN={summary}")
    print(f"WIPE_BEFORE_RESTORE={'yes' if want_wipe else 'no'}")
    if args.dry_run:
        if want_wipe:
            print("WIPE_PLAN=drop all non-Oracle user tables on backup-database, then restore")
        src = REMOTE_TEMPLATES / template
        print("---- remote template (will substitute env) ----")
        print(src.read_text(encoding="utf-8"))
        print("---- env ----")
        for k, v in oracle_env(target, extra).items():
            print(f"{k}={v}")
        print("DRY_RUN_OK")
        return 0
    client = connect(target)
    try:
        if want_wipe:
            # RMAN can wipe only if the instance is still OPEN; closed library is replaced by datafiles.
            wrc = run_wipe(client, target, args, allow_not_open=(args.type == "rman"))
            if wrc != 0:
                die("wipe failed; restore not started")
        job_dir, wrap = upload_template(client, template, oracle_env(target, extra))
        rc, out, err = start_job(
            client, target, job_dir, wrap, args.timeout, args.foreground, args.pty
        )
        log = f"{extra['LOG_DIR']}/ora_ssh_{'restore' if args.type == 'rman' else 'impdp'}_{date_tag}.log"
        print(f"HOST={target['host']}")
        print(f"JOB_DIR={job_dir}")
        print(f"LOG={log}")
        if not args.foreground:
            print(f"POLL=python {Path(__file__).name} poll --host {target['host']} --log {log}")
        return emit(rc, out, err)
    finally:
        client.close()


def cmd_wipe_tables(args: argparse.Namespace) -> int:
    target = resolve_target(args)
    refuse_wipe_on_source(target)
    if args.dry_run:
        print(
            f"WIPE_PLAN=drop non-Oracle user tables host={target['host']} "
            f"sid={target.get('oracle_sid')} owners={args.owners or 'ALL_USER'}"
        )
        print("DRY_RUN_OK")
        return 0
    if args.confirm != CONFIRM_WIPE:
        die(f"wipe refused. after the user confirms, rerun with --confirm {CONFIRM_WIPE}")
    client = connect(target)
    try:
        return run_wipe(client, target, args, allow_not_open=False)
    finally:
        client.close()


def cmd_poll(args: argparse.Namespace) -> int:
    target = resolve_target(args)
    n = args.lines
    command = f"tail -n {n} {sh_quote(args.log)}; echo '----'; wc -l {sh_quote(args.log)}"
    client = connect(target)
    try:
        rc, out, err = run(client, command, timeout=args.timeout)
        emit(rc, out, err)
        text = out + err
        if "BACKUP_OK" in text or "RESTORE_OK" in text or "WIPE_OK" in text:
            print("STATUS=OK")
        elif "RMAN_BACKUP_FAILED" in text or "WIPE_FAILED" in text or "ERROR=" in text:
            print("STATUS=FAILED")
        else:
            print("STATUS=RUNNING")
        return rc
    finally:
        client.close()


def cmd_put(args: argparse.Namespace) -> int:
    target = resolve_target(args)
    client = connect(target)
    try:
        data = Path(args.local).read_bytes()
        sftp_write(client, args.remote, data)
        print(f"PUT_OK {args.remote}")
        return 0
    finally:
        client.close()


def cmd_get(args: argparse.Namespace) -> int:
    target = resolve_target(args)
    client = connect(target)
    try:
        sftp = client.open_sftp()
        try:
            sftp.get(args.remote, args.local)
        finally:
            sftp.close()
        print(f"GET_OK {args.local}")
        return 0
    finally:
        client.close()


def add_target_flags(p: argparse.ArgumentParser) -> None:
    p.add_argument("--config", help="connections.json path")
    p.add_argument("--profile")
    p.add_argument("--host")
    p.add_argument("--user")
    p.add_argument("--pass-file")
    p.add_argument("--key")
    p.add_argument("--sid")
    p.add_argument("--oracle-home")
    p.add_argument("--oracle-user", default=None)
    p.add_argument("--timeout", type=int, default=90)
    p.add_argument("--pty", action="store_true")


def main() -> int:
    p = argparse.ArgumentParser(description="SSH + Oracle DBA helper. Never prints passwords.")
    sub = p.add_subparsers(dest="cmd", required=True)

    p_init = sub.add_parser("init-config")
    p_init.add_argument("--config")
    p_init.add_argument("--force", action="store_true")
    p_init.set_defaults(func=lambda a: cmd_init_config(a))

    p_ls = sub.add_parser("list-profiles")
    p_ls.add_argument("--config")
    p_ls.set_defaults(func=lambda a: cmd_list_profiles(a))

    p_exec = sub.add_parser("exec")
    add_target_flags(p_exec)
    p_exec.add_argument("command")
    p_exec.set_defaults(func=lambda a: cmd_exec(a, False))

    p_ora = sub.add_parser("oracle")
    add_target_flags(p_ora)
    p_ora.add_argument("command")
    p_ora.set_defaults(func=lambda a: cmd_exec(a, True))

    p_sql = sub.add_parser("sqlplus")
    add_target_flags(p_sql)
    p_sql.add_argument("--sql")
    p_sql.add_argument("--file")
    p_sql.set_defaults(func=lambda a: cmd_sql_or_rman(a, "sqlplus"))

    p_rman = sub.add_parser("rman")
    add_target_flags(p_rman)
    p_rman.add_argument("--cmd")
    p_rman.add_argument("--file")
    p_rman.set_defaults(func=lambda a: cmd_sql_or_rman(a, "rman"))

    p_ins = sub.add_parser("inspect")
    add_target_flags(p_ins)
    p_ins.set_defaults(func=cmd_inspect)

    p_put = sub.add_parser("put")
    add_target_flags(p_put)
    p_put.add_argument("local")
    p_put.add_argument("remote")
    p_put.set_defaults(func=cmd_put)

    p_get = sub.add_parser("get")
    add_target_flags(p_get)
    p_get.add_argument("remote")
    p_get.add_argument("local")
    p_get.set_defaults(func=cmd_get)

    p_bak = sub.add_parser("backup")
    add_target_flags(p_bak)
    p_bak.add_argument("--type", choices=["rman-l0", "rman-l1", "datapump"], default="rman-l0")
    p_bak.add_argument("--backup-root")
    p_bak.add_argument("--schemas")
    p_bak.add_argument("--full", action="store_true")
    p_bak.add_argument("--no-arch", action="store_true")
    p_bak.add_argument("--log-dir")
    p_bak.add_argument("--foreground", action="store_true")
    p_bak.set_defaults(func=cmd_backup)

    p_res = sub.add_parser("restore")
    add_target_flags(p_res)
    p_res.add_argument("--type", choices=["rman", "datapump"], default="rman")
    p_res.add_argument("--backup-dir")
    p_res.add_argument("--arch-dir")
    p_res.add_argument("--dbid")
    p_res.add_argument("--until-sequence", type=int)
    p_res.add_argument("--dump")
    p_res.add_argument("--schemas")
    p_res.add_argument("--full", action="store_true")
    p_res.add_argument("--table-exists", default="SKIP")
    p_res.add_argument("--remap-schema")
    p_res.add_argument("--listener-host")
    p_res.add_argument("--no-resetlogs", action="store_true")
    p_res.add_argument("--log-dir")
    p_res.add_argument("--foreground", action="store_true")
    p_res.add_argument("--dry-run", action="store_true")
    p_res.add_argument("--confirm")
    p_res.add_argument("--wipe-tables", action="store_true", help="drop user tables before restore")
    p_res.add_argument("--skip-wipe", action="store_true")
    p_res.add_argument("--owners", help="comma-separated schemas to wipe (default: all user schemas)")
    p_res.add_argument("--wipe-timeout", type=int, default=1800)
    p_res.set_defaults(func=cmd_restore)

    p_wipe = sub.add_parser("wipe-tables")
    add_target_flags(p_wipe)
    p_wipe.add_argument("--owners", help="comma-separated schemas (default: all user schemas)")
    p_wipe.add_argument("--log-dir")
    p_wipe.add_argument("--wipe-timeout", type=int, default=1800)
    p_wipe.add_argument("--dry-run", action="store_true")
    p_wipe.add_argument("--confirm")
    p_wipe.set_defaults(func=cmd_wipe_tables)

    p_poll = sub.add_parser("poll")
    add_target_flags(p_poll)
    p_poll.add_argument("--log", required=True)
    p_poll.add_argument("--lines", type=int, default=40)
    p_poll.set_defaults(func=cmd_poll)

    args = p.parse_args()
    return int(args.func(args) or 0)


if __name__ == "__main__":
    sys.exit(main())
