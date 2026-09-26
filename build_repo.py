#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
越狱源索引生成器 (Cydia / Sileo / Zebra)
把 debs/ 目录下的所有 .deb 扫描成 Packages / Packages.gz / Packages.bz2 / Release。
纯 Python，无需 dpkg。支持 control.tar.{gz,xz,zst}。
用法:  python build_repo.py
"""
import os, io, gzip, bz2, hashlib, tarfile, time, email.utils

REPO_ROOT = os.path.dirname(os.path.abspath(__file__))
DEBS_DIR = os.path.join(REPO_ROOT, "debs")

# ===================== 改成你自己的 =====================
REPO_NAME = "0A`guang"
REPO_ORIGIN = "0A`guang"
REPO_DESCRIPTION = "A`guang 自用的 tweak / 插件源"
REPO_SUITE = "stable"
REPO_CODENAME = "ios"
REPO_COMPONENTS = "main"
REPO_ARCHS = "iphoneos-arm iphoneos-arm64 iphoneos-arm64e"
# 源在 Sileo 里显示的头像（留空字符串则不写 Icon 字段，Sileo 会回退到根目录的 icon.png）
REPO_ICON = "https://g-using.github.io/repo/icon.png"
# 源的根地址，用来拼每个包图标的绝对 URL（必须以 / 结尾）
REPO_BASE_URL = "https://g-using.github.io/repo/"
# 按包图标目录：把 <Package>.png 放进它，就会自动写进那条包的 Icon: 字段。
# 例如 icons/com.huayuarc.snapper3.urlstamp.png -> 该包 stanza 里出现一行 Icon:
# 留空字符串 "" 则不启用这个功能。
REPO_ICONS_DIR = "icons"
# 按包改写分类：索引层面覆盖 Section 字段，不动 deb 本身。
# 用途：把别的源搬来的基础设施包归到自己的分类下，在 Sileo / Zebra 里显示成一个目录。
# 留空字典 {} 则不启用。
SECTION_OVERRIDES = {
    "ellekit":              "越狱必装五个插件",
    "preferenceloader":     "越狱必装五个插件",
    "com.opa334.altlist":   "越狱必装五个插件",
    "com.opa334.libsandy":  "越狱必装五个插件",
    "com.opa334.ccsupport": "越狱必装五个插件",
}
# =======================================================


def parse_ar(data):
    if data[:8] != b"!<arch>\n":
        raise ValueError("不是有效的 .deb (ar 头不对)")
    members = {}
    off = 8
    n = len(data)
    while off + 60 <= n:
        h = data[off:off + 60]
        name = h[0:16].decode("ascii", "replace").rstrip()
        if name.endswith("/"):
            name = name[:-1]
        try:
            size = int((h[48:58].decode("ascii", "replace") or "0").strip() or "0")
        except ValueError:
            size = 0
        off += 60
        body = data[off:off + size]
        off += size
        if size % 2 == 1:
            off += 1
        if name in ("", "/", "//"):
            continue
        members[name] = body
    return members


def open_tar(raw, ext):
    bio = io.BytesIO(raw)
    if ext.endswith(".gz"):
        return tarfile.open(fileobj=bio, mode="r:gz")
    if ext.endswith(".xz"):
        return tarfile.open(fileobj=bio, mode="r:xz")
    if ext.endswith(".zst"):
        try:
            import zstandard
        except ImportError:
            raise RuntimeError("control.tar.zst 需要先在运行环境装 zstandard: pip install zstandard")
        decompressed = zstandard.ZstdDecompressor().decompress(io.BytesIO(raw).read())
        return tarfile.open(fileobj=io.BytesIO(decompressed), mode="r:")
    return tarfile.open(fileobj=bio, mode="r:*")


def read_control(deb_path):
    with open(deb_path, "rb") as f:
        data = f.read()
    members = parse_ar(data)
    ctrl_name = None
    for name in members:
        if name.startswith("control.tar"):
            ctrl_name = name
            break
    if ctrl_name is None:
        raise ValueError("deb 里没有 control.tar*: " + os.path.basename(deb_path))
    raw = members[ctrl_name]
    control_text = None
    with open_tar(raw, ctrl_name) as tar:
        for m in tar.getmembers():
            base = os.path.basename(m.name)
            if base == "control":
                cf = tar.extractfile(m)
                if cf:
                    control_text = cf.read().decode("utf-8", "replace")
                    break
    if control_text is None:
        raise ValueError("control.tar 里找不到 control 文件: " + os.path.basename(deb_path))
    return control_text


def parse_stanza(text):
    fields = {}
    order = []
    cur = None
    for line in text.split("\n"):
        if line == "":
            continue
        if line[0] in (" ", "\t"):
            if cur is not None:
                fields[cur] += "\n" + line.strip()
            continue
        if ":" in line:
            k, v = line.split(":", 1)
            k = k.strip()
            v = v.strip()
            if k not in fields:
                order.append(k)
            fields[k] = v
            cur = k
    return fields, order


def sanitize_deb_name(name):
    # 只保留 ASCII（中文名会拖进 URL 导致装不上），保留 .deb 后缀
    base = "".join(c for c in name if ord(c) < 128)
    if not base.lower().endswith(".deb"):
        base = (base if base.lower().endswith(".deb") else base + ".deb")
    if len(base) <= 4:  # 只剩 ".deb"
        base = "package.deb"
    return base


def rename_nonascii_debs(debs_dir):
    # 把 debs/ 里中文名的 .deb 自动改成英文名，返回 [(旧名, 新名)]
    renamed = []
    existing = set(os.listdir(debs_dir))
    n = 0
    for f in list(existing):
        if not f.lower().endswith(".deb"):
            continue
        try:
            f.encode("ascii")
            continue  # 已经是英文名
        except UnicodeEncodeError:
            pass
        new = sanitize_deb_name(f)
        while new in existing or new == f:
            n += 1
            stem = new[:-4] if new.lower().endswith(".deb") else new
            new = f"{stem}_{n}.deb"
        os.rename(os.path.join(debs_dir, f), os.path.join(debs_dir, new))
        existing.add(new)
        renamed.append((f, new))
    return renamed


def main():
    if not os.path.isdir(DEBS_DIR):
        os.makedirs(DEBS_DIR)
    # 先规范文件名（中文名 -> 英文），否则手机端下载会失败
    renamed = rename_nonascii_debs(DEBS_DIR)
    for old, new in renamed:
        print(f"  [改名] {old} -> {new}")
    debs = sorted(
        os.path.join(DEBS_DIR, f)
        for f in os.listdir(DEBS_DIR)
        if f.endswith(".deb")
    )
    stanzas = []
    for deb in debs:
        fn = os.path.basename(deb)
        rel = "debs/" + fn
        size = os.path.getsize(deb)
        with open(deb, "rb") as f:
            blob = f.read()
        md5 = hashlib.md5(blob).hexdigest()
        sha1 = hashlib.sha1(blob).hexdigest()
        sha256 = hashlib.sha256(blob).hexdigest()
        try:
            ctrl = read_control(deb)
        except Exception as e:
            print("  [跳过] 无法解析 control:", fn, "->", e)
            continue
        fields, order = parse_stanza(ctrl)
        fields["Filename"] = rel
        fields["Size"] = str(size)
        fields["MD5sum"] = md5
        fields["SHA1"] = sha1
        fields["SHA256"] = sha256
        for k in ("Filename", "Size", "MD5sum", "SHA1", "SHA256"):
            if k not in order:
                order.append(k)
        if "Package" not in fields or "Version" not in fields:
            print("  [跳过] 缺 Package/Version:", fn)
            continue
        # 按包图标：icons/<Package>.png 存在就写进这条 stanza 的 Icon: 字段。
        # Sileo / Zebra 会用它在包列表和详情页显示图标。
        pkg_id = fields.get("Package", "").strip()
        if REPO_ICONS_DIR and pkg_id:
            icon_path = os.path.join(REPO_ROOT, REPO_ICONS_DIR, pkg_id + ".png")
            if os.path.isfile(icon_path):
                fields["Icon"] = REPO_BASE_URL + REPO_ICONS_DIR + "/" + pkg_id + ".png"
                if "Icon" not in order:
                    order.append("Icon")
                print("      [图标]", pkg_id, "->", fields["Icon"])
        # 按包改写分类：SECTION_OVERRIDES 里配了的包，Section 换成自定义名字。
        # 这是索引层面覆盖，deb 本身没动（用户装到的仍是官方原包）。
        if pkg_id and pkg_id in SECTION_OVERRIDES:
            new_sec = SECTION_OVERRIDES[pkg_id]
            old_sec = fields.get("Section", "")
            fields["Section"] = new_sec
            if "Section" not in order:
                order.append("Section")
            print("      [分类]", pkg_id, ":", old_sec, "->", new_sec)
        stanzas.append((fields, order))
        print("  [OK]", fn, "->", fields.get("Name", fields.get("Package")), fields.get("Version"))

    # 保护：所有 deb 都解析失败时不要写空索引（会把整个源清空），直接失败以保留旧索引
    if debs and not stanzas:
        print("!! 所有 deb 都解析失败，保留旧索引，不写入")
        raise SystemExit(1)

    out_blocks = []
    for fields, order in stanzas:
        lines = []
        for k in order:
            v = fields[k]
            parts = v.split("\n")
            lines.append(f"{k}: {parts[0]}")
            for extra in parts[1:]:
                lines.append(" " + extra)
        out_blocks.append("\n".join(lines))
    # 注意：APT/Cydia/Sileo 的 Packages 格式要求
    # 每个包之间用「空行」分隔。若只用一个换行，
    # 多个包会被解析成同一条记录，Sileo 里只会显示出一个包。
    packages = "\n\n".join(out_blocks)
    if packages and not packages.endswith("\n"):
        packages += "\n"

    # 头部字段（不含 Date，Date 每次都会变，不能拿它判断）
    header_lines = [
        f"Origin: {REPO_ORIGIN}",
        f"Label: {REPO_NAME}",
        f"Suite: {REPO_SUITE}",
        f"Version: 1.0",
        f"Codename: {REPO_CODENAME}",
        f"Architectures: {REPO_ARCHS}",
        f"Components: {REPO_COMPONENTS}",
    ]
    if REPO_ICON:
        header_lines.append(f"Icon: {REPO_ICON}")
    header_lines.append(f"Description: {REPO_DESCRIPTION}")
    header_key = "\n".join(header_lines)

    # 只有包列表或头部字段（源名/描述/头像）真的变化时才重写索引，
    # 否则连带新 Date 的 Release 也不动，
    # 避免 GitHub Actions 因时间戳变化陷入「提交->触发->再提交」死循环。
    pkg_path = os.path.join(REPO_ROOT, "Packages")
    rel_path = os.path.join(REPO_ROOT, "Release")
    changed = True
    if os.path.exists(pkg_path):
        old = open(pkg_path, "rb").read().decode("utf-8", "replace")
        changed = (old != packages) or bool(renamed)
    if not changed and os.path.exists(rel_path):
        old_rel = open(rel_path, "rb").read().decode("utf-8", "replace")
        old_head = []
        for line in old_rel.split("\n"):
            if line.startswith(("Date:", "MD5Sum:", "SHA1:", "SHA256:")):
                break
            old_head.append(line)
        changed = ("\n".join(old_head) != header_key)
    if not changed:
        print("索引无变化，跳过重写。")
        print(f"\n完成：共 {len(stanzas)} 个包（索引未改动）。")
        return

    # 以字节写入 (强制 LF, 避免 Windows 把 \\n 变 \\r\\n 导致 Release 校验和不一致)
    with open(pkg_path, "wb") as f:
        f.write(packages.encode("utf-8"))
    # mtime=0 → 可复现构建：同样的内容永远产出同样的字节，避免 gzip 头里的
    # 时间戳导致每次生成的 Packages.gz 哈希都不同
    with open(os.path.join(REPO_ROOT, "Packages.gz"), "wb") as f:
        with gzip.GzipFile(fileobj=f, mode="wb", mtime=0) as gz:
            gz.write(packages.encode("utf-8"))
    with bz2.open(os.path.join(REPO_ROOT, "Packages.bz2"), "wb") as f:
        f.write(packages.encode("utf-8"))

    def sums(path):
        b = open(path, "rb").read()
        return (hashlib.md5(b).hexdigest(),
                hashlib.sha1(b).hexdigest(),
                hashlib.sha256(b).hexdigest(),
                len(b))

    md5b, sha1b, sha256b = [], [], []
    for fn in ("Packages", "Packages.gz", "Packages.bz2"):
        p = os.path.join(REPO_ROOT, fn)
        if not os.path.exists(p):
            continue
        m, s1, s2, sz = sums(p)
        md5b.append(f" {m} {sz} {fn}")
        sha1b.append(f" {s1} {sz} {fn}")
        sha256b.append(f" {s2} {sz} {fn}")

    date = email.utils.formatdate(time.time(), usegmt=True)
    nl = "\n"
    release = (
        nl.join(header_lines) + "\n"
        f"Date: {date}\n"
        f"MD5Sum:\n{nl.join(md5b)}\n"
        f"SHA1:\n{nl.join(sha1b)}\n"
        f"SHA256:\n{nl.join(sha256b)}\n"
    )
    with open(os.path.join(REPO_ROOT, "Release"), "wb") as f:
        f.write(release.encode("utf-8"))

    print(f"\n完成：共 {len(stanzas)} 个包。已生成/更新 Packages / Packages.gz / Packages.bz2 / Release。")


if __name__ == "__main__":
    main()

