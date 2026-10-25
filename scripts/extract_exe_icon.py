#!/usr/bin/env python3
"""Make a macOS .icns from the main icon of a Windows executable.

    extract_exe_icon.py <program.exe> <output.icns>

Reads the first RT_GROUP_ICON resource (the icon Explorer shows), takes its largest
image and renders the .icns sizes with sips and iconutil. The input is only read.
SOLIDWORKS.app uses this for SLDWORKS.exe's icon on the owner's Mac; the result is
a local build product (build/, ignored by git) and is never committed.
"""
import os
import struct
import subprocess
import sys
import tempfile

RT_ICON = 3
RT_GROUP_ICON = 14
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


class IconError(Exception):
    pass


def _sections(data):
    if data[:2] != b"MZ":
        raise IconError("not a Windows executable (no MZ header)")
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe:pe + 4] != b"PE\0\0":
        raise IconError("not a PE executable")
    count, optional_size = struct.unpack_from("<H12xH", data, pe + 6)
    optional = pe + 24
    magic = struct.unpack_from("<H", data, optional)[0]
    directories = optional + {0x10B: 96, 0x20B: 112}.get(magic, -1)
    if directories < optional:
        raise IconError("unknown PE optional header")
    resource_rva, resource_size = struct.unpack_from("<II", data, directories + 2 * 8)
    table = optional + optional_size
    sections = [struct.unpack_from("<8xIIII", data, table + 40 * i) for i in range(count)]
    return resource_rva, resource_size, sections  # (VirtualSize, VirtualAddress, RawSize, RawPointer)


def _offset(rva, sections):
    for virtual_size, address, raw_size, pointer in sections:
        if address <= rva < address + max(virtual_size, raw_size):
            return pointer + rva - address
    raise IconError("resource RVA 0x%x is outside every section" % rva)


def _entries(data, base, directory):
    named, ids = struct.unpack_from("<12xHH", data, base + directory)
    for i in range(named + ids):
        name, target = struct.unpack_from("<II", data, base + directory + 16 + 8 * i)
        yield (None if name & 0x80000000 else name), target


def _resources(data):
    """{type: [(id, bytes)]} in resource directory order, first language of each entry."""
    resource_rva, resource_size, sections = _sections(data)
    if not resource_rva or not resource_size:
        raise IconError("the executable has no resources")
    base = _offset(resource_rva, sections)
    result = {}
    for kind, types in _entries(data, base, 0):
        if kind not in (RT_ICON, RT_GROUP_ICON) or not types & 0x80000000:
            continue
        for ident, names in _entries(data, base, types & 0x7FFFFFFF):
            if not names & 0x80000000:
                continue
            languages = list(_entries(data, base, names & 0x7FFFFFFF))
            if not languages or languages[0][1] & 0x80000000:
                continue
            rva, size = struct.unpack_from("<II", data, base + languages[0][1])
            start = _offset(rva, sections)
            result.setdefault(kind, []).append((ident, data[start:start + size]))
    return result


def icon_images(data):
    """[(width, height, bit_count, image bytes)] of the executable's first group icon."""
    resources = _resources(data)
    groups = resources.get(RT_GROUP_ICON)
    if not groups:
        raise IconError("the executable has no icon")
    icons = {ident: blob for ident, blob in resources.get(RT_ICON, [])}
    group = groups[0][1]
    reserved, kind, count = struct.unpack_from("<HHH", group, 0)
    if reserved != 0 or kind != 1:
        raise IconError("malformed icon group")
    images = []
    for i in range(count):
        width, height, _, _, _, bit_count, _, ident = struct.unpack_from("<BBBBHHIH", group, 6 + 14 * i)
        if ident in icons:
            images.append((width or 256, height or 256, bit_count, icons[ident]))
    if not images:
        raise IconError("the icon group references no icon images")
    return images


def best_image(images):
    return max(images, key=lambda image: (image[0] * image[1], image[2]))


def single_image_ico(image):
    width, height, bit_count, blob = image
    entry = struct.pack("<BBBBHHII", width % 256, height % 256, 0, 0, 1, bit_count, len(blob), 6 + 16)
    return struct.pack("<HHH", 0, 1, 1) + entry + blob


ICONSET = [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"),
           (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"), (512, "512x512"),
           (1024, "512x512@2x")]


def write_icns(exe, output):
    with open(exe, "rb") as handle:
        image = best_image(icon_images(handle.read()))
    with tempfile.TemporaryDirectory() as work:
        source = os.path.join(work, "source.png")
        if image[3].startswith(PNG_SIGNATURE):
            with open(source, "wb") as handle:
                handle.write(image[3])
        else:
            ico = os.path.join(work, "source.ico")
            with open(ico, "wb") as handle:
                handle.write(single_image_ico(image))
            subprocess.run(["sips", "-s", "format", "png", ico, "--out", source],
                           check=True, stdout=subprocess.DEVNULL)
        iconset = os.path.join(work, "AppIcon.iconset")
        os.mkdir(iconset)
        for size, name in ICONSET:
            subprocess.run(["sips", "-z", str(size), str(size), source, "--out",
                            os.path.join(iconset, "icon_%s.png" % name)], check=True, stdout=subprocess.DEVNULL)
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", output], check=True)
    return image[:3]


def main(argv):
    if len(argv) != 3:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2
    try:
        width, height, bit_count = write_icns(argv[1], argv[2])
    except (IconError, OSError, struct.error, subprocess.CalledProcessError) as error:
        print("extract_exe_icon: %s" % error, file=sys.stderr)
        return 1
    print("%s: %dx%d %d-bit icon -> %s" % (os.path.basename(argv[1]), width, height, bit_count, argv[2]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
