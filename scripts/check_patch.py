"""校验 OpenWrt 内核补丁里每个 hunk 的 @@ 行数声明是否与实际内容一致。

背景
----
手工在补丁中间插入/删除行却忘记更新 `@@ -a,b +c,d @@` 声明时，
patch 工具只会严格读取声明的行数，多出来的内容被静默丢弃，
结果生成的文件在末尾被截断 —— 典型症状是 DTS 报
"syntax error" 且位置恰好落在文件最后一行。

用法
----
    python check_patch.py <补丁文件> [更多补丁...]
    python check_patch.py --dir <patches 目录>

退出码 0 = 全部一致；1 = 发现不匹配。
"""
import io
import os
import re
import sys

HDR = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")


def is_end_of_patch(line):
    """git format-patch 的签名分隔符, 之后不再是 hunk 内容。"""
    return line == "-- " or line == "--"


def count_hunk(lines, start):
    """从 start 的下一行开始数 hunk body, 返回 (old_c, new_c, next_index)。"""
    old_c = new_c = 0
    j = start + 1
    while j < len(lines):
        l = lines[j]
        if HDR.match(l) or l.startswith("diff --git") or is_end_of_patch(l):
            break
        if l.startswith("\\"):          # \ No newline at end of file
            j += 1
            continue
        # 注意: 这里【不能】把 "---"/"+++" 当作 hunk 结束标志。
        # 当补丁内容本身是另一个补丁文件时（例如新增一个 *.patch），
        # 内层的 "+++ b/..." 行在外层补丁里被写成 "++++ b/..."，
        # 仍然以 "+++" 开头 —— 若据此 break，会把整个 hunk 截断成前几行，
        # 但判定必须带尾随空格：有些补丁没有 "diff --git" 行，段与段之间
        # 只有 "--- a/x" / "+++ b/x"，不识别就会把它们算成 hunk 内容
        # （表现为 old/new 各多 1）。带空格的条件同时正确放过了嵌套情形 ——
        # 内层文件头在外层写作 "++++ b/x" / "+--- a/x"，第 4 字符不是空格。
        if l.startswith("--- ") or l.startswith("+++ "):
            break
        if l.startswith("+"):
            new_c += 1
        elif l.startswith("-"):
            old_c += 1
        else:
            # 上下文行: 标准格式是前导空格; 但部分补丁前导空格被 trim 掉,
            # 于是行首直接是原文件的缩进(空格或 TAB); 完全空行也属上下文。
            if l.startswith(" ") or l.startswith("\t") or l == "":
                old_c += 1
                new_c += 1
            else:
                break
        j += 1
    # 尾部空行是 hunk 之间的分隔（或补丁末尾的填充），不是 hunk 内容。
    # 不回退它们会让「最后一个 hunk」系统性多算 1 行，产生看似真问题的误报。
    while j > start + 1 and lines[j - 1] == "":
        old_c -= 1
        new_c -= 1
        j -= 1
    return old_c, new_c, j


def check_file(path):
    raw = io.open(path, "rb").read()
    lines = raw.decode("utf-8", errors="replace").split("\n")
    while lines and lines[-1] == "":
        lines.pop()

    bad = 0
    total = 0
    i = 0
    while i < len(lines):
        m = HDR.match(lines[i])
        if not m:
            i += 1
            continue
        total += 1
        old_n = int(m.group(2) or 1)
        new_n = int(m.group(4) or 1)
        old_c, new_c, j = count_hunk(lines, i)
        if old_c != old_n or new_c != new_n:
            bad += 1
            print("  MISMATCH @ %s:%d" % (os.path.basename(path), i + 1))
            print("      %s" % lines[i])
            print(
                "      declared old=%-4d new=%-4d | actual old=%-4d new=%-4d"
                % (old_n, new_n, old_c, new_c)
            )
        i = j if j > i else i + 1
    return total, bad


def load_series(path):
    """从 series 清单读取生效的补丁路径。

    行格式: <文件名> [  # 说明 ]；# 开头的整行为注释。
    只扫描清单里列出的补丁 —— 目录里可能存在历史遗留、已不再生效的补丁文件，
    把它们一起扫进来会污染结论。
    """
    d = os.path.dirname(os.path.abspath(path))
    out = []
    for line in io.open(path, encoding="utf-8"):
        name = line.split("#", 1)[0].strip()
        if name:
            out.append(os.path.join(d, name))
    return out


def main(argv):
    args = argv[1:]
    if args and args[0] == "--dir":
        d = args[1]
        files = sorted(
            os.path.join(d, f) for f in os.listdir(d) if f.endswith((".patch", ".diff"))
        )
    elif args and args[0] == "--series":
        files = load_series(args[1])
    else:
        files = args

    if not files:
        print(__doc__)
        return 2

    grand_bad = 0
    grand_hunk = 0
    for f in files:
        if not os.path.exists(f):
            print("[MISSING] %s" % f)
            grand_bad += 1
            continue
        total, bad = check_file(f)
        grand_hunk += total
        grand_bad += bad
        flag = "OK " if bad == 0 else "BAD"
        print("[%s] %-58s hunks=%d" % (flag, os.path.basename(f), total))

    print()
    print("扫描补丁数: %d, hunk 总数: %d, 不匹配: %d" % (len(files), grand_hunk, grand_bad))
    print("RESULT:", "ALL OK" if grand_bad == 0 else "NEEDS FIX")
    return 0 if grand_bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
