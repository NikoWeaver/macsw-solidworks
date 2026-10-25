#!/usr/bin/env bash
# Strip the PE modules MacSW rebuilds (package_app.sh sources this file).
#
# build_winemac.sh keeps the cross-compiled modules as the linker wrote them: Wine's configure adds
# -g to the MinGW flags, so each module carries DWARF sections and a COFF symbol table (kernelbase.dll
# is 6.0 MB, the stock one 2.7 MB; the first 15 rebuilt modules are 72 MB, 12 MB stripped; glu32.dll
# of patch 0037 is the 16th). The stock
# modules of the pinned runtime are stripped, so are the ones `make install` produces, and Wine
# loads builtin modules by their exports (.edata) and unwind data (.pdata/.xdata), not by symbols.
#
# Functions (all fail with a message on stderr; none needs anything but od, dd and the MinGW strip):
#   macsw_strip_pe FILE...         strip in place, then check the result with macsw_pe_stripped
#   macsw_pe_stripped FILE         0 when FILE has no COFF symbols and a "Wine builtin DLL" mark
#   macsw_pe_arch FILE             prints x86_64 or i386
#   macsw_pe_timestamp FILE        the module's link time stamp (kept by macsw_strip_pe)
# Environment:
#   MACSW_STRIP_X86_64, MACSW_STRIP_I386   strip programs (default: the MinGW-w64 binutils, found in
#                                          PATH, /opt/homebrew/bin or /usr/local/bin)

macsw_pe_u32() { # FILE OFFSET -> unsigned little-endian 32-bit value at OFFSET
    od -An -tu4 -j "$2" -N4 "$1" | tr -d ' \n'
}

macsw_pe_arch() {
    local file="$1" pe machine
    [ "$(dd if="${file}" bs=1 count=2 2>/dev/null)" = "MZ" ] || { echo "macsw_pe_arch: ${file}: not a PE file" >&2; return 1; }
    pe="$(macsw_pe_u32 "${file}" 60)"
    [ "$(dd if="${file}" bs=1 skip="${pe}" count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "50450000" ] \
        || { echo "macsw_pe_arch: ${file}: no PE signature" >&2; return 1; }
    machine="$(od -An -tx2 -j "$((pe + 4))" -N2 "${file}" | tr -d ' \n')"
    case "${machine}" in
        8664) echo x86_64 ;;
        014c) echo i386 ;;
        *) echo "macsw_pe_arch: ${file}: unexpected machine type ${machine}" >&2; return 1 ;;
    esac
}

macsw_pe_timestamp() { # IMAGE_FILE_HEADER.TimeDateStamp (PE offset +8 after the signature)
    macsw_pe_u32 "$1" "$(($(macsw_pe_u32 "$1" 60) + 4 + 4))"
}

macsw_pe_stripped() {
    local file="$1" pe
    # Wine marks its own modules: "Wine builtin DLL" at offset 0x40, inside the DOS header gap.
    [ "$(dd if="${file}" bs=1 skip=64 count=16 2>/dev/null)" = "Wine builtin DLL" ] || return 1
    pe="$(macsw_pe_u32 "${file}" 60)"
    # IMAGE_FILE_HEADER.NumberOfSymbols is at PE offset +12 after the 4-byte signature. binutils leaves
    # PointerToSymbolTable pointing at the end of the file, so only the count says "no symbols".
    [ "$(macsw_pe_u32 "${file}" "$((pe + 4 + 12))")" = 0 ]
}

macsw_pe_strip_tool() { # x86_64 | i386 -> path of the strip program
    local arch="$1" override triplet tool dir
    case "${arch}" in
        x86_64) override="${MACSW_STRIP_X86_64:-}"; triplet=x86_64-w64-mingw32 ;;
        i386) override="${MACSW_STRIP_I386:-}"; triplet=i686-w64-mingw32 ;;
        *) echo "macsw_pe_strip_tool: unknown architecture ${arch}" >&2; return 1 ;;
    esac
    if [ -n "${override}" ]; then echo "${override}"; return 0; fi
    tool="${triplet}-strip"
    if command -v "${tool}" >/dev/null 2>&1; then command -v "${tool}"; return 0; fi
    for dir in /opt/homebrew/bin /usr/local/bin; do
        if [ -x "${dir}/${tool}" ]; then echo "${dir}/${tool}"; return 0; fi
    done
    echo "${tool} not found. Install MinGW-w64 (brew install mingw-w64). package_app.sh alone can skip stripping with MACSW_STRIP_PE=0; verify_app.sh needs the tool to compare a stripped build with dist/." >&2
    return 1
}

macsw_strip_pe() {
    local file arch tool before
    for file in "$@"; do
        arch="$(macsw_pe_arch "${file}")" || return 1
        tool="$(macsw_pe_strip_tool "${arch}")" || return 1
        before="$(wc -c < "${file}" | tr -d ' ')"
        # binutils writes the current time into TimeDateStamp (and so into the checksum) unless
        # SOURCE_DATE_EPOCH is set: keep the module's own stamp, so the output depends on the input only
        # and the SHA-256 in BuildManifest.plist (the runtime identity) does not change per packaging run.
        SOURCE_DATE_EPOCH="$(macsw_pe_timestamp "${file}")" "${tool}" "${file}" \
            || { echo "macsw_strip_pe: ${tool} failed on ${file}" >&2; return 1; }
        macsw_pe_stripped "${file}" || {
            echo "macsw_strip_pe: ${file} still has symbols or lost the Wine builtin mark after strip" >&2; return 1; }
        echo "    stripped $(basename "${file}") (${arch}): ${before} -> $(wc -c < "${file}" | tr -d ' ') bytes"
    done
}
