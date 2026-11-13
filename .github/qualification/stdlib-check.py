"""Compile rules_go's stdlib using the syscall-number header from Linux v3.16."""
import hashlib
import json
import os
import re
import subprocess
from pathlib import Path

base = "f9689452ce5999237c187346ea2ad62207015d99"
change = "10f9a0f0d126d5fae773c18275bdaa8bc0ec3ae3"
target = "//tests/core/stdlib:stdlib_files"
package = "crypto/internal/sysrand/internal/seccomp"
temp = Path(os.environ["RUNNER_TEMP"])
evidence = temp / "old-header-evidence"
evidence.mkdir(exist_ok=True)


def objects(path):
    decoder = json.JSONDecoder()
    data = path.read_text()
    offset = 0
    while offset < len(data):
        if data[offset].isspace():
            offset += 1
            continue
        value, offset = decoder.raw_decode(data, offset)
        yield value


def read(*args):
    return subprocess.check_output(args, text=True).strip()


results = []
for source in (change,):
    subprocess.run(["git", "checkout", "--detach", source], check=True)
    assert read("git", "rev-parse", "HEAD") == source
    subprocess.run(["git", "diff", "--quiet", "HEAD", "--"], check=True)
    for strategy in ("linux-sandbox", "local"):
        name = f"{source[:9]}-{strategy}"
        row = dict(source=source, strategy=strategy)
        results.append(row)
        log = evidence / (name + ".build.txt")
        spawns = temp / (name + ".spawns.json")
        flags = [f"--strategy=GoStdlib={strategy}", f"--strategy=GoStdlibList={strategy}",
                 "--copt=-I/opt/linux-3.16-headers", "--noremote_accept_cached", "--noremote_upload_local_results",
                 f"--modify_execution_info=^GoStdlib(List)?$=+no-cache,^GoStdlib(List)?$=+{name}"]
        try:
            with log.open("w") as output:
                proc = subprocess.run(["bazel", "build", "--keep_going", *flags, f"--execution_log_json_file={spawns}", target],
                                      stdout=output, stderr=subprocess.STDOUT, timeout=720)
            row["buildExit"] = proc.returncode
            row["actions"] = [
                {key: x.get(key, default) for key, default in (("mnemonic", ""), ("runner", ""), ("cacheHit", False), ("exitCode", 0), ("status", ""))}
                for x in objects(spawns) if x.get("mnemonic") in ("GoStdlib", "GoStdlibList")
            ]
            assert any(x["mnemonic"] == "GoStdlib" for x in row["actions"]), row
            assert all(x["runner"] == strategy and not x["cacheHit"] for x in row["actions"]), row
            execroot = Path(read("bazel", "info", "execution_root"))
            sources = read("bazel", "cquery", *flags, "--output=files", f'kind("^go_sdk rule$",deps({target}))').splitlines()
            sdk, = {s.removesuffix("/src/fmt/print.go") for s in sources if s.endswith("/src/fmt/print.go")}
            row["goversion"] = (execroot / sdk / "VERSION").read_text().splitlines()[0]
            sdkfiles = [s.removeprefix(sdk + "/src/") for s in sources if s.startswith(sdk + "/src/")]
            row["declaredSrcCount"] = len(sdkfiles)
            row["declaredSrcHash"] = hashlib.sha256("\n".join(sorted(sdkfiles)).encode()).hexdigest()
            assert sdkfiles and not any(s.startswith(package + "/") for s in sdkfiles)
            physical = execroot / sdk / "src" / package / "seccomp_linux.go"
            row["physicalGoSourceSha256"] = hashlib.sha256(physical.read_bytes()).hexdigest()
            if proc.returncode:
                text = log.read_text()
                row["diagnostics"] = [s for s in text.splitlines() if re.search(r"error:.*SYS_(getrandom|seccomp)", s)]
                assert source == base and strategy == "local" and package in text and all(
                    any("SYS_" + m in line for line in row["diagnostics"]) for m in ("getrandom", "seccomp")
                ), row
            else:
                assert source != base or strategy != "local", "expected exact old-header compile error on stock local"
                assert {x["mnemonic"] for x in row["actions"]} == {"GoStdlib", "GoStdlibList"}, row
                assert all(x["exitCode"] == 0 for x in row["actions"]), row
                outputs = [execroot / name for name in read("bazel", "cquery", *flags, "--output=files", target).splitlines()]
                tree, = [p for p in outputs if p.is_dir() and p.name == "pkg"]
                listing, = [p for p in outputs if p.name.endswith("stdlib.pkg.json")]
                archives = {p.relative_to(tree).as_posix().split("/", 1)[1][:-2] for p in tree.rglob("*.a") if p.relative_to(tree).parts[0].startswith("linux_amd64")}
                packages = {p["PkgPath"] for p in objects(listing)}
                for kind, entries in (("archives", archives), ("packages", packages)):
                    assert {"fmt", "runtime", "syscall"} <= entries and package not in entries, kind
                    row[kind] = len(entries)
                    row[kind + "Hash"] = hashlib.sha256("\n".join(sorted(entries)).encode()).hexdigest()
            row["ok"] = True
        except Exception as exc:
            row["error"] = str(exc)[:4000]
        (evidence / (name + ".json")).write_text(json.dumps(row, indent=2) + "\n")
        if spawns.exists():
            spawns.unlink()
assert all(r.get("ok") for r in results), results
for field in ("declaredSrcHash", "physicalGoSourceSha256", "goversion"):
    assert len({r[field] for r in results}) == 1, field
for field in ("archivesHash", "packagesHash"):
    assert len({r[field] for r in results if field in r}) == 1, field
assert all(r["declaredSrcHash"] == "d0bbb609450c29bbe0600eb1424ce67f61ecd6df2739bd2ecfdea38ba08feb28" and r["archivesHash"] == "0d073ba4892f00d5dda1111496c52ed1ccb7c36318aa6e9f823685c6961ba185" and r["packagesHash"] == "c014b8db61bee15b8cf6a9fe32a8f1eff0096138ed348eae37fcd40217b4a56e" for r in results)
