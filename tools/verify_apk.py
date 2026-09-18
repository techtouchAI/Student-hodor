#!/usr/bin/env python3
"""بوابة فحص حزم APK: تتحقق أن الحزمة «قابلة للتثبيت فعلاً» قبل نشرها.

لماذا هذه الأداة؟
-----------------
رسالة أندرويد «لم يتم تثبيت التطبيق لأن الحزمة تبدو غير صالحة» هي الواجهة
التي يعرضها النظام لفئة كاملة من أعطال التثبيت (INSTALL_FAILED_INVALID_APK
وما يرافقها من أعطال تحليل الحزمة/استخراج المكتبات الأصلية). لا يمكن لمستخدم
المدرسة تشخيصها، ولا يكفي «توقيع صحيح» لتنفيها. فحص الملف قبل النشر أوفر
بمراحل من اكتشافه في الميدان.

ماذا تفحص؟
----------
1. سلامة الأرشيف: فتح الحزمة كـ ZIP + تحقق CRC لكل مدخل (يكشف التنزيل
   المبتور/التالف — السبب الميداني الأكثر شيوعاً للرسالة نفسها).
2. بنية الحزمة: وجود AndroidManifest.xml وclasses.dex وresources.arsc،
   وتوقيع META-INF (v1) وحظر توقيع APK (v2/v3) عبر apksigner.
3. محاذاة 16KB (أندرويد 15+): كل مكتبة أصلية 64-بت يجب أن تكون مقاطع
   PT_LOAD فيها بمحاذاة >= 16384، وأن تكون مخزّنة داخل الحزمة (غير مضغوطة)
   عند إزاحة من مضاعفات 16384. خلافه يفشل التثبيت على أجهزة 16KB بخطأ
   «Failed to extract native libraries» = نفس الرسالة أعلاه.
4. وسم الحزمة عبر aapt2: اسم الحزمة، versionCode/Name، minSdk/targetSdk،
   والبنيات الأصلية (ABIs).
5. مقارنة الإصدار الجديد بالمنشور سابقاً (أمر `gate`): استمرار مفتاح
   التوقيع، تزايد versionCode، وعدم تراجع minSdk — أي خرق يعني «تحديث
   لا يُثبَّت فوق المثبت مسبقاً».

الاعتماديات: مكتبة بايثون القياسية فقط. أدوات أندرويد (apksigner/aapt2/
zipalign) تُستخدم إن وُجدت في ANDROID_HOME لت enrich التقرير، وغيابها
يُسجَّل «غير متاح» بدل أن يُفشل الفحص.

الاستخدام
---------
    python3 tools/verify_apk.py inspect app-release.apk [app-arm64.apk ...] \
        [--report ci-diagnostics/apk-report.txt] [--strict]

    python3 tools/verify_apk.py gate --current app-release.apk \
        [--current app-arm64-v8a-release.apk ...] \
        --previous previous/app-release.apk \
        [--report ci-diagnostics/apk-report.txt] [--allow-minsdk-bump]

رموز الخروج: 0 = سليم، 1 = عطل مانع للنشر، 2 = تحذير فقط مع --strict.
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import os
import re
import shutil
import struct
import subprocess
import sys
import zipfile
from pathlib import Path

# ---------------------------------------------------------------- ثوابت

PAGE_16KB = 16384
# البنيات 64-بت فقط ملزمة بمحاذاة 16KB (مكتبات 32-بت تُستثنى رسمياً).
ABIS_64BIT = {"arm64-v8a", "x86_64", "riscv64", "mips64"}

PT_LOAD = 1
# معرّفات سمات aapt التي نقرأها من AndroidManifest الثنائي عند غياب aapt2.
ATTR_VERSION_CODE = 0x0101021B
ATTR_MIN_SDK = 0x0101020C
ATTR_TARGET_SDK = 0x01010270

# صلاحيات يمنعها عقد التطبيق (تُمرَّر من سطر الأوامر عبر --forbid-permission).
FORBIDDEN_PERMISSIONS: list[str] = []

SEVERITY_FATAL = "FATAL"
SEVERITY_WARN = "WARN"
SEVERITY_INFO = "INFO"


# ---------------------------------------------------------------- نماذج


@dataclasses.dataclass
class Problem:
    severity: str
    code: str
    message: str

    def render(self) -> str:
        return f"[{self.severity}] {self.code}: {self.message}"


@dataclasses.dataclass
class ElfInfo:
    is_64bit: bool
    min_align: int


@dataclasses.dataclass
class LibInfo:
    name: str
    abi: str
    size: int
    compressed: bool
    data_offset: int | None
    offset_16kb_aligned: bool | None
    elf: ElfInfo | None
    elf_16kb_aligned: bool | None

    @property
    def subject_to_16kb(self) -> bool:
        return self.abi in ABIS_64BIT


@dataclasses.dataclass
class ApkFacts:
    path: Path
    size: int
    sha256: str
    zip_ok: bool
    zip_bad_entry: str | None
    entry_count: int
    has_manifest: bool
    has_resources: bool
    dex_count: int
    v1_signature_files: list[str]
    libs: list[LibInfo]
    badging: dict[str, str]
    permissions: list[str]
    signer_schemes: dict[str, bool]
    cert_sha256: str | None
    cert_dn: str | None
    zipalign_output: str | None
    tool_notes: list[str]
    problems: list[Problem]


# ---------------------------------------------------------------- أدوات مساعدة


def sha256_file(path: Path, chunk: int = 1 << 20) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(chunk), b""):
            digest.update(block)
    return digest.hexdigest()


def _latest_build_tools_dir() -> Path | None:
    android_home = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
    if not android_home:
        return None
    root = Path(android_home) / "build-tools"
    if not root.is_dir():
        return None
    candidates = sorted((p for p in root.iterdir() if p.is_dir()), key=lambda p: p.name)
    return candidates[-1] if candidates else None


def _build_tool(name: str) -> Path | None:
    direct = shutil.which(name)
    if direct:
        return Path(direct)
    bt = _latest_build_tools_dir()
    if bt and (bt / name).exists():
        return bt / name
    return None


def _run(cmd: list[str]) -> tuple[int, str]:
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    except (OSError, subprocess.SubprocessError) as exc:  # pragma: no cover
        return 1, f"{type(exc).__name__}: {exc}"
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


# ---------------------------------------------------------------- محاذاة 16KB


def parse_elf(data: bytes) -> ElfInfo | None:
    """يقرأ أصغر محاذاة لمقاطع PT_LOAD من ترويسة ELF (بدون أي اعتماد)."""
    if len(data) < 64 or data[:4] != b"\x7fELF":
        return None
    ei_class = data[4]
    ei_data = data[5]
    endian = "<" if ei_data == 1 else ">"
    if ei_class == 2:  # 64-bit
        phoff = struct.unpack_from(endian + "Q", data, 0x20)[0]
        phentsize = struct.unpack_from(endian + "H", data, 0x36)[0]
        phnum = struct.unpack_from(endian + "H", data, 0x38)[0]
        ph_fmt = endian + "IIQQQQQQ"
        align_index = 7
    elif ei_class == 1:  # 32-bit
        phoff = struct.unpack_from(endian + "I", data, 0x1C)[0]
        phentsize = struct.unpack_from(endian + "H", data, 0x2A)[0]
        phnum = struct.unpack_from(endian + "H", data, 0x2C)[0]
        ph_fmt = endian + "IIIIIIII"
        align_index = 7
    else:
        return None

    if phentsize <= 0 or phnum <= 0:
        return ElfInfo(is_64bit=ei_class == 2, min_align=0)
    ph_size = struct.calcsize(ph_fmt)
    min_align: int | None = None
    for i in range(phnum):
        off = phoff + i * phentsize
        if off + ph_size > len(data):
            break
        fields = struct.unpack_from(ph_fmt, data, off)
        if fields[0] != PT_LOAD:
            continue
        align = fields[align_index]
        # p_align بقيمة 0 أو 1 يعني «بلا قيد محاذاة» — مقبول.
        if align > 1 and (min_align is None or align < min_align):
            min_align = align
    return ElfInfo(is_64bit=ei_class == 2, min_align=min_align or 0)


def _stored_data_offset(apk: Path, info: zipfile.ZipInfo) -> int | None:
    """إزاحة بيانات المدخل داخل الحزمة — مقروءة من الترويسة المحلية نفسها.

    الترويسة المحلية (لا المركزية) هي المرجع: طول اسم الملف وطول الحقل الإضافي
    قد يختلفان بين الاثنتين، وأي خطأ هنا يجعل فحص محاذاة 16KB بلا معنى.
    """
    with apk.open("rb") as handle:
        handle.seek(info.header_offset)
        header = handle.read(30)
    if len(header) < 30 or header[:4] != b"PK\x03\x04":
        return None
    name_len = int.from_bytes(header[26:28], "little")
    extra_len = int.from_bytes(header[28:30], "little")
    return info.header_offset + 30 + name_len + extra_len


# ---------------------------------------------------------------- AndroidManifest الثنائي (بديل aapt2)


def parse_manifest_sdk(data: bytes) -> dict[str, int]:
    """يستخرج versionCode/minSdk/targetSdk من AndroidManifest.xml الثنائي.

    يُستخدم فقط حين لا تتوفر أداة aapt2؛ أي فشل يُعيد قاموساً فارغاً
    (معلومة ناقصة لا عطل مانع) — أداة النظام تبقى المصدر المعتمد.
    """
    out: dict[str, int] = {}
    try:
        if len(data) < 8 or struct.unpack_from("<H", data, 0)[0] != 0x0003:
            return out
        pos = struct.unpack_from("<I", data, 4)[0]
        strings: list[str] = []
        # تجمع السلاسل (0x0001) ثم عُقد XML (0x0102 START_ELEMENT).
        while pos + 8 <= len(data):
            chunk_type, header_size, chunk_size = struct.unpack_from("<HHI", data, pos)
            if chunk_size <= 0:
                break
            if chunk_type == 0x0001:
                strings = _read_string_pool(data, pos)
            elif chunk_type == 0x0102:
                _scan_element(data, pos + header_size, strings, out)
            pos += chunk_size
    except (struct.error, IndexError, UnicodeDecodeError):
        return out
    return out


def _read_string_pool(data: bytes, pos: int) -> list[str]:
    _t, _hs, _cs, count, _styles, flags, str_start, _style_start = struct.unpack_from(
        "<HHIIIIII", data, pos
    )
    utf8 = bool(flags & 0x100)
    offsets = struct.unpack_from("<%dI" % count, data, pos + 28) if count else ()
    base = pos + str_start
    out: list[str] = []
    for off in offsets:
        cur = base + off
        if utf8:
            # طول UTF-8 مُرمَّز بطول متغيّر (قد يكون 2 بايت).
            n = data[cur]
            cur += 1
            if n & 0x80:
                n = ((n & 0x7F) << 8) | data[cur]
                cur += 1
            out.append(data[cur : cur + n].decode("utf-8", "replace"))
        else:
            n = struct.unpack_from("<H", data, cur)[0]
            cur += 2
            if n & 0x8000:  # UTF-16 على كلمتين
                n = ((n & 0x7FFF) << 16) | struct.unpack_from("<H", data, cur)[0]
                cur += 2
            out.append(data[cur : cur + n * 2].decode("utf-16-le", "replace"))
        out[-1] = out[-1].rstrip("\x00")
    return out


def _scan_element(data: bytes, pos: int, strings: list[str], out: dict[str, int]) -> None:
    _ns, _name, _attr_start, attr_size, attr_count = struct.unpack_from("<IIHHH", data, pos)
    attr_pos = pos + 20
    for _ in range(attr_count):
        a_ns, a_name, _raw, _size, _res0, data_type, a_data = struct.unpack_from(
            "<IIIHBBI", data, attr_pos
        )
        attr_pos += attr_size
        if a_name in (ATTR_VERSION_CODE, ATTR_MIN_SDK, ATTR_TARGET_SDK):
            key = {
                ATTR_VERSION_CODE: "versionCode",
                ATTR_MIN_SDK: "minSdk",
                ATTR_TARGET_SDK: "targetSdk",
            }[a_name]
            out[key] = a_data
        del a_ns, data_type


# ---------------------------------------------------------------- فحص الحزمة


def inspect_apk(path: Path) -> ApkFacts:
    size = path.stat().st_size
    problems: list[Problem] = []
    tool_notes: list[str] = []

    with path.open("rb") as handle:
        digest = hashlib.sha256()
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    sha256 = digest.hexdigest()

    zip_ok = True
    bad_entry: str | None = None
    names: list[str] = []
    libs: list[LibInfo] = []
    try:
        with zipfile.ZipFile(path) as zf:
            names = zf.namelist()
            bad_entry = zf.testzip()
            if bad_entry is not None:
                zip_ok = False
            manifest_data = zf.read("AndroidManifest.xml") if "AndroidManifest.xml" in names else b""
            for name in names:
                if not name.startswith("lib/") or not name.endswith(".so"):
                    continue
                info = zf.getinfo(name)
                parts = name.split("/")
                abi = parts[1] if len(parts) > 2 else "unknown"
                compressed = info.compress_type != zipfile.ZIP_STORED
                if compressed:
                    data_offset = None
                    offset_aligned = None
                    elf_bytes: bytes | None = None
                else:
                    data_offset = _stored_data_offset(path, info)
                    offset_aligned = data_offset % PAGE_16KB == 0
                    with path.open("rb") as handle:
                        handle.seek(data_offset)
                        elf_bytes = handle.read(min(info.file_size, 1 << 20))
                elf = parse_elf(elf_bytes) if elf_bytes else None
                libs.append(
                    LibInfo(
                        name=name,
                        abi=abi,
                        size=info.file_size,
                        compressed=compressed,
                        data_offset=data_offset,
                        offset_16kb_aligned=offset_aligned,
                        elf=elf,
                        elf_16kb_aligned=(
                            None if elf is None else (elf.min_align == 0 or elf.min_align >= PAGE_16KB)
                        ),
                    )
                )
    except zipfile.BadZipFile as exc:
        zip_ok = False
        manifest_data = b""
        names = []
        problems.append(
            Problem(
                SEVERITY_FATAL,
                "ZIP_INVALID",
                f"الحزمة ليست أرشيف ZIP صالحاً ({exc}) — ملف ناقص/مبتور أو ليس APK.",
            )
        )
    except (OSError, EOFError) as exc:
        zip_ok = False
        manifest_data = b""
        problems.append(Problem(SEVERITY_FATAL, "ZIP_IO", f"تعذّر قراءة الحزمة: {exc}"))

    if zip_ok and size < 1_000_000:
        problems.append(
            Problem(SEVERITY_WARN, "APK_TINY", f"حجم الحزمة {size} بايت — أصغر من المتوقع لتطبيق Flutter.")
        )

    v1_files = [n for n in names if n.startswith("META-INF/") and n.endswith((".RSA", ".DSA", ".EC"))]
    dex_count = sum(1 for n in names if n.startswith("classes") and n.endswith(".dex"))
    has_manifest = "AndroidManifest.xml" in names
    has_resources = "resources.arsc" in names

    if zip_ok:
        if not has_manifest:
            problems.append(Problem(SEVERITY_FATAL, "NO_MANIFEST", "AndroidManifest.xml غائب من الحزمة."))
        if dex_count == 0:
            problems.append(Problem(SEVERITY_FATAL, "NO_DEX", "لا يوجد classes.dex داخل الحزمة."))
        if not v1_files:
            tool_notes.append("لا ملفات META-INF/*.RSA: حزمة بلا توقيع v1 (مقبول مع minSdk>=24).")

    # ---- محاذاة 16KB
    if zip_ok:
        for lib in libs:
            if not lib.subject_to_16kb:
                continue
            if lib.compressed:
                problems.append(
                    Problem(
                        SEVERITY_WARN,
                        "LIB_COMPRESSED",
                        f"{lib.name}: مكتبة 64-بت مضغوطة داخل الحزمة؛ لا يمكن لنظام أندرويد "
                        "تحميلها بصفحة 16KB مباشرةً (المطلوب useLegacyPackaging=false).",
                    )
                )
                continue
            if lib.offset_16kb_aligned is False:
                problems.append(
                    Problem(
                        SEVERITY_FATAL,
                        "ZIP_OFFSET_NOT_16KB",
                        f"{lib.name}: إزاحة البيانات {lib.data_offset} غير محاذاة لـ 16KB داخل الحزمة.",
                    )
                )
            if lib.elf_16kb_aligned is False:
                problems.append(
                    Problem(
                        SEVERITY_FATAL,
                        "ELF_NOT_16KB",
                        f"{lib.name}: مقاطع PT_LOAD بمحاذاة {lib.elf.min_align if lib.elf else '؟'} بايت "
                        "بدل 16384 — التثبيت يفشل على أجهزة 16KB بـ INSTALL_FAILED_INVALID_APK.",
                    )
                )

    # ---- aapt2 (badging)
    badging: dict[str, str] = {}
    permissions: list[str] = []
    aapt2 = _build_tool("aapt2")
    if aapt2 is not None and zip_ok:
        code, out = _run([str(aapt2), "dump", "badging", str(path)])
        if code == 0:
            for line in out.splitlines():
                if line.startswith("uses-permission: name="):
                    permissions.append(line.split("name=", 1)[1].strip().strip("'"))
                if line.startswith("package:"):
                    for key in ("name", "versionCode", "versionName"):
                        token = f"{key}='"
                        if token in line:
                            badging[key] = line.split(token, 1)[1].split("'", 1)[0]
                elif line.startswith("minSdkVersion:") or line.startswith("sdkVersion:"):
                    badging["minSdk"] = line.split(":", 1)[1].strip().strip("'")
                elif line.startswith("targetSdkVersion:"):
                    badging["targetSdk"] = line.split(":", 1)[1].strip().strip("'")
                elif line.startswith("native-code:"):
                    badging["native-code"] = line.split(":", 1)[1].strip()
        else:
            tool_notes.append(f"aapt2 فشل ({code}): {out.strip()[:200]}")
    else:
        tool_notes.append("aapt2 غير متاح — الاعتماد على تحليل Manifest الثنائي (معلومات أقل).")
        if manifest_data:
            for key, value in parse_manifest_sdk(manifest_data).items():
                badging[key] = str(value)

    for forbidden in FORBIDDEN_PERMISSIONS:
        if forbidden in permissions:
            problems.append(
                Problem(
                    SEVERITY_FATAL,
                    "FORBIDDEN_PERMISSION",
                    f"الحزمة تطلب صلاحية {forbidden} المخالفة لعقد التطبيق "
                    "(أوفلاين بالكامل) — أزلها من البيان المدمج.",
                )
            )

    # ---- apksigner
    schemes: dict[str, bool] = {}
    cert_sha256: str | None = None
    cert_dn: str | None = None
    apksigner = _build_tool("apksigner")
    if apksigner is not None and zip_ok:
        min_sdk = badging.get("minSdk", "24")
        code, out, schemes, cert_sha256, cert_dn = _apksigner_verify(apksigner, path, min_sdk)
        if code == 0:
            # توقيع v1 (JAR) يُقاس على نطاق واسع: apksigner قد يبلّغ عنه false
            # حين يضيق نطاق SDK، وبعض مثبّتات الأجهزة (وأنظمة MDM المدرسية)
            # لا تقبل غيره — فنستقصيه من أدنى نسخة أندرويد ممكنة.
            if not schemes.get("v1", False):
                _code2, _out2, schemes21, _c2, _d2 = _apksigner_verify(apksigner, path, "21")
                if schemes21.get("v1"):
                    schemes["v1"] = True
            if not cert_sha256:
                problems.append(
                    Problem(SEVERITY_FATAL, "SIGNER_UNREADABLE", "تعذّر قراءة هوية الموقِّع من apksigner.")
                )
            if not schemes.get("v2", False):
                problems.append(
                    Problem(
                        SEVERITY_FATAL,
                        "NO_V2_SIGNATURE",
                        "الحزمة غير موقّعة بمخطط v2 — أندرويد 7.0+ يرفض تثبيتها.",
                    )
                )
            if not schemes.get("v1", False) and not v1_files:
                tool_notes.append(
                    "لا توقيع v1 (JAR) في الحزمة: مقبول على أندرويد 7.0+، لكن بعض "
                    "مثبّتات الأجهزة وأنظمة إدارة الأجهزة (MDM) لا تقبل غيره."
                )
        else:
            problems.append(
                Problem(SEVERITY_FATAL, "SIGNATURE_INVALID", f"apksigner رفض الحزمة:\n{out.strip()[:800]}")
            )
    elif zip_ok:
        tool_notes.append("apksigner غير متاح — لم يُتحقق من التوقيع.")

    # ---- zipalign (معلومة مساندة)
    zipalign_output: str | None = None
    zipalign = _build_tool("zipalign")
    if zipalign is not None and zip_ok:
        # -P 16: التحقق بمحاذاة صفحة 16KB (مطلب أجهزة أندرويد 15+ بصفحات 16KB).
        checks: list[str] = []
        for label, args in (("16KB", ["-c", "-P", "16", "-v", "4"]), ("4B", ["-c", "4"])):
            code, out = _run([str(zipalign), *args, str(path)])
            checks.append(f"zipalign {label}: {'OK' if code == 0 else 'FAILED'}")
            if code != 0 and label == "16KB":
                checks.append("   " + (out.strip().splitlines() or [""])[-1][:200])
        zipalign_output = " | ".join(checks)

    return ApkFacts(
        path=path,
        size=size,
        sha256=sha256,
        zip_ok=zip_ok,
        zip_bad_entry=bad_entry,
        entry_count=len(names),
        has_manifest=has_manifest,
        has_resources=has_resources,
        dex_count=dex_count,
        v1_signature_files=sorted(v1_files),
        libs=libs,
        badging=badging,
        permissions=sorted(set(permissions)),
        signer_schemes=schemes,
        cert_sha256=cert_sha256,
        cert_dn=cert_dn,
        zipalign_output=zipalign_output,
        tool_notes=tool_notes,
        problems=list(problems),
    )



def _apksigner_verify(
    apksigner: Path, path: Path, min_sdk: str
) -> tuple[int, str, dict[str, bool], str | None, str | None]:
    """يشغّل apksigner على نطاق نسخة محدد ويعيد (الرمز، المخرجات، المخططات، البصمة، الهوية)."""
    code, out = _run(
        [
            str(apksigner),
            "verify",
            "-v",
            "--print-certs",
            "--min-sdk-version",
            min_sdk,
            "--max-sdk-version",
            "36",
            str(path),
        ]
    )
    schemes: dict[str, bool] = {}
    cert_sha256: str | None = None
    cert_dn: str | None = None
    for line in out.splitlines():
        line = line.strip()
        # «Verified using v1 scheme (JAR signing): true»
        match = re.match(r"Verified using (v[0-9.]*) scheme \(.*\):\s*(true|false)", line)
        if match:
            schemes[match.group(1)] = match.group(2) == "true"
            continue
        if "certificate SHA-256 digest:" in line:
            cert_sha256 = cert_sha256 or line.split("digest:", 1)[1].strip()
        if "certificate DN:" in line:
            cert_dn = line.split("certificate DN:", 1)[1].strip()
    return code, out, schemes, cert_sha256, cert_dn


# ---------------------------------------------------------------- المقارنة


def compare(previous: ApkFacts, current: ApkFacts, allow_minsdk_bump: bool) -> list[Problem]:
    """يقارن الحزمة الجديدة بالمنشورة سابقاً: هل تُثبَّت «فوقها» فعلاً؟"""
    problems: list[Problem] = []

    prev_pkg = previous.badging.get("name")
    cur_pkg = current.badging.get("name")
    if prev_pkg and cur_pkg and prev_pkg != cur_pkg:
        problems.append(
            Problem(
                SEVERITY_FATAL,
                "PACKAGE_ID_CHANGED",
                f"معرف الحزمة تغيّر ({prev_pkg} → {cur_pkg}): يُثبَّت كتطبيق جديد لا تحديث.",
            )
        )

    if previous.cert_sha256 and current.cert_sha256 and previous.cert_sha256 != current.cert_sha256:
        problems.append(
            Problem(
                SEVERITY_FATAL,
                "SIGNING_KEY_ROTATED",
                "مفتاح التوقيع مختلف عن الإصدار المنشور: أندرويد يرفض التحديث "
                "(INSTALL_FAILED_UPDATE_INCOMPATIBLE) ويخسر المستخدم بياناته إن اضطر للحذف.\n"
                f"    المنشور: {previous.cert_sha256}\n"
                f"    الجديد : {current.cert_sha256}",
            )
        )
    if previous.cert_sha256 and not current.cert_sha256:
        problems.append(
            Problem(SEVERITY_WARN, "SIGNER_UNKNOWN", "تعذّر تحديد مفتاح توقيع الحزمة الجديدة للمقارنة.")
        )

    try:
        prev_code = int(previous.badging.get("versionCode", "0"))
        cur_code = int(current.badging.get("versionCode", "0"))
    except ValueError:
        prev_code = cur_code = 0
    if prev_code and cur_code and cur_code < prev_code:
        problems.append(
            Problem(
                SEVERITY_FATAL,
                "VERSION_CODE_NOT_INCREASED",
                f"versionCode الجديد ({cur_code}) ليس أكبر من المنشور ({prev_code}): "
                "أندرويد يرفض التحديث التنازلي/المساوي.",
            )
        )

    try:
        prev_min = int(previous.badging.get("minSdk", "0"))
        cur_min = int(current.badging.get("minSdk", "0"))
    except ValueError:
        prev_min = cur_min = 0
    if prev_min and cur_min and cur_min > prev_min:
        severity = SEVERITY_WARN if allow_minsdk_bump else SEVERITY_FATAL
        problems.append(
            Problem(
                severity,
                "MIN_SDK_INCREASED",
                f"minSdk ارتفع {prev_min} → {cur_min}: كل جهاز بأندرويد أقل من "
                f"{_android_name(cur_min)} سيفشل تثبيت التحديث فوق النسخة القديمة.",
            )
        )

    prev_abis = set((previous.badging.get("native-code") or "").replace("'", " ").split())
    cur_abis = set((current.badging.get("native-code") or "").replace("'", " ").split())
    dropped = prev_abis - cur_abis
    if dropped:
        problems.append(
            Problem(
                SEVERITY_WARN,
                "ABI_DROPPED",
                f"بنيات أصلية كانت مدعومة ولم تعد موجودة: {', '.join(sorted(dropped))}",
            )
        )

    return problems


def _android_name(api: int) -> str:
    return {
        21: "أندرويد 5.0",
        22: "أندرويد 5.1",
        23: "أندرويد 6.0",
        24: "أندرويد 7.0",
        26: "أندرويد 8.0",
        28: "أندرويد 9",
        29: "أندرويد 10",
        30: "أندرويد 11",
        31: "أندرويد 12",
        33: "أندرويد 13",
        34: "أندرويد 14",
        35: "أندرويد 15",
        36: "أندرويد 16",
    }.get(api, f"API {api}")


# ---------------------------------------------------------------- التقرير


def render_report(
    facts_list: list[tuple[str, ApkFacts]], extra: list[Problem], header: list[str]
) -> str:
    lines: list[str] = []
    lines.append("=" * 78)
    lines.append("تقرير فحص حزمة APK — بوابة ما قبل النشر")
    lines.extend(header)
    lines.append("=" * 78)

    for label, facts in facts_list:
        lines.append("")
        lines.append(f"── {label}: {facts.path.name}")
        lines.append(f"   الحجم        : {facts.size:,} بايت")
        lines.append(f"   SHA-256      : {facts.sha256}")
        lines.append(f"   سلامة ZIP    : {'سليم' if facts.zip_ok else 'تالف'}"
                     + (f" (أول مدخل تالف: {facts.zip_bad_entry})" if facts.zip_bad_entry else ""))
        lines.append(f"   عدد المداخل  : {facts.entry_count}")
        lines.append(
            f"   البنية       : manifest={facts.has_manifest} resources.arsc={facts.has_resources} "
            f"classes.dex={facts.dex_count}"
        )
        if facts.badging:
            lines.append(
                "   الوسم        : "
                + ", ".join(f"{k}={v}" for k, v in facts.badging.items())
            )
        if facts.permissions:
            lines.append("   الصلاحيات   : " + ", ".join(facts.permissions))
        schemes_text = (
            ", ".join(
                f"{k}={'نعم' if v else 'لا'}" for k, v in sorted(facts.signer_schemes.items())
            )
            or "غير محددة"
        )
        lines.append(
            f"   التوقيع      : {schemes_text} | ملفات v1={len(facts.v1_signature_files)}"
        )
        if facts.cert_dn:
            lines.append(f"   هوية الموقّع : {facts.cert_dn}")
        if facts.cert_sha256:
            lines.append(f"   بصمة الشهادة : {facts.cert_sha256}")
        if facts.zipalign_output:
            lines.append(f"   zipalign     : {facts.zipalign_output.splitlines()[0]}")
        if facts.libs:
            lines.append(f"   مكتبات أصلية : {len(facts.libs)}")
            for lib in facts.libs:
                flag = "16KB✓" if (lib.elf_16kb_aligned and lib.offset_16kb_aligned) else "16KB✗"
                if not lib.subject_to_16kb:
                    flag = "32bit"
                if lib.compressed:
                    flag = "مضغوطة"
                align = lib.elf.min_align if lib.elf else "؟"
                lines.append(f"       - {lib.name} ({lib.abi}) محاذاة ELF={align} {flag}")
        for note in facts.tool_notes:
            lines.append(f"   ملاحظة       : {note}")
        for problem in facts.problems:
            lines.append("   " + problem.render())

    lines.append("")
    lines.append("── بوابة التحديث (مقارنة بالإصدار المنشور)")
    if extra:
        for problem in extra:
            lines.append("   " + problem.render())
    else:
        lines.append("   [INFO] لا خروقات: التحديث متوافق مع النسخة المنشورة.")

    lines.append("")
    return "\n".join(lines)


# ---------------------------------------------------------------- الواجهة


def _collect(paths: list[Path]) -> tuple[list[tuple[str, ApkFacts]], list[Problem]]:
    out: list[tuple[str, ApkFacts]] = []
    problems: list[Problem] = []
    for path in paths:
        if not path.exists():
            problems.append(Problem(SEVERITY_FATAL, "MISSING_APK", f"ملف غير موجود: {path}"))
            continue
        out.append((path.name, inspect_apk(path)))
    return out, problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p_inspect = sub.add_parser("inspect", help="فحص حزمة أو أكثر دون مقارنة")
    p_inspect.add_argument("apks", nargs="+", type=Path)
    p_inspect.add_argument("--report", type=Path)
    p_inspect.add_argument(
        "--forbid-permission", action="append", default=[], metavar="NAME"
    )
    p_inspect.add_argument("--strict", action="store_true", help="اعتبار التحذيرات عطلاً")

    p_gate = sub.add_parser("gate", help="فحص الحزم الجديدة ومقارنتها بالمنشورة")
    p_gate.add_argument("--current", nargs="+", required=True, type=Path)
    p_gate.add_argument("--previous", type=Path)
    p_gate.add_argument("--report", type=Path)
    p_gate.add_argument(
        "--forbid-permission", action="append", default=[], metavar="NAME"
    )
    p_gate.add_argument("--allow-minsdk-bump", action="store_true")
    p_gate.add_argument("--strict", action="store_true")

    args = parser.parse_args(argv)
    FORBIDDEN_PERMISSIONS.extend(args.forbid_permission)

    if args.command == "inspect":
        facts, extra = _collect(args.apks)
        header = ["الوضع: فحص فقط (بلا مقارنة)"]
    else:
        facts, extra = _collect(list(args.current))
        header = ["الوضع: بوابة نشر"]
        if args.previous:
            if not args.previous.exists():
                extra.append(
                    Problem(SEVERITY_WARN, "NO_PREVIOUS", f"لا حزمة سابقة للفحص: {args.previous}")
                )
            else:
                prev_facts = inspect_apk(args.previous)
                facts.append((f"المنشور سابقاً: {prev_facts.path.name}", prev_facts))
                # المقارنة تجري على الحزمة الشاملة وحدها: حزم الـ ABI مقسّمة
                # أصلاً، ومقارنة بنياتها بالشاملة تُنتج تحذيراً كاذباً.
                if facts:
                    extra.extend(compare(prev_facts, facts[0][1], args.allow_minsdk_bump))
                header.append(f"المقارنة مع: {args.previous}")

    report = render_report(facts, extra, header)
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(report, encoding="utf-8")
    print(report)

    severities = {p.severity for _, f in facts for p in f.problems} | {p.severity for p in extra}
    if SEVERITY_FATAL in severities:
        print("النتيجة: فشل — يمنع النشر.", file=sys.stderr)
        return 1
    if args.strict and SEVERITY_WARN in severities:
        print("النتيجة: تحذيرات مع --strict.", file=sys.stderr)
        return 2
    print("النتيجة: سليم.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
