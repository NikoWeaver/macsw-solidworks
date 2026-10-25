#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

CONTENTS_DIR="${TEST_ROOT}/MacSW.app/Contents"
LOG_FILE="${TEST_ROOT}/calls.log"
PREFIX="${TEST_ROOT}/bottle"
mkdir -p \
    "${CONTENTS_DIR}/MacOS" \
    "${CONTENTS_DIR}/Frameworks/wine/bin" \
    "${CONTENTS_DIR}/Resources/SWCLI/bin" \
    "${CONTENTS_DIR}/Resources/SWCLI/runtime/PythonNative/bin" \
    "${CONTENTS_DIR}/Resources/SWCLI/runtime/PythonNative/lib/python3.11/site-packages" \
    "${PREFIX}/drive_c/MacSW/Python311"
mkdir -p "${PREFIX}/dosdevices"
ln -s ../drive_c "${PREFIX}/dosdevices/c:"
ln -s / "${PREFIX}/dosdevices/z:"

cp "${WORKSPACE_ROOT}/scripts/swcli/sw-cli" "${CONTENTS_DIR}/MacOS/sw-cli"
cp "${WORKSPACE_ROOT}/scripts/swcli/swcli-path" \
    "${CONTENTS_DIR}/Resources/SWCLI/bin/swcli-path"
cp "${WORKSPACE_ROOT}/scripts/swcli/swcli_path.py" \
    "${CONTENTS_DIR}/Resources/SWCLI/bin/swcli_path.py"
touch "${CONTENTS_DIR}/Resources/SWCLI/bin/swcli_path.exe"
touch "${PREFIX}/drive_c/MacSW/Python311/python.exe"
touch "${PREFIX}/drive_c/MacSW/Python311/pythonw.exe"

cat > "${CONTENTS_DIR}/Frameworks/wine/bin/wineloader" <<'EOF'
#!/usr/bin/env bash
printf 'windows translator=%s aot=%s overrides=%s lang=%s lc_all=%s loader=%s server=%s surfaces=%s wiccache=%s modreads=%s args=%s\n' \
    "${SWCLI_PATH_TRANSLATE_CMD:-}" "${WINE_MONO_AOT:-}" "${WINEDLLOVERRIDES:-}" \
    "${LANG:-}" "${LC_ALL:-}" "${WINELOADER:-}" "${WINESERVER:-}" "${MACSW_CROSS_PROCESS_SURFACES:-}" \
    "${MACSW_WIC_COMPONENT_CACHE:-}" "${MACSW_LOCAL_MODULE_READS:-}" "$*" >> "${SWCLI_TEST_LOG}"
if [[ "${1:-}" == *pythonw.exe && "${2:-}" == "-c" ]]; then
    output="${4#Z:}"
    output="${output//\\//}"
    printf '{"mock":true}\n' > "${output}"
fi
EOF
cat > "${CONTENTS_DIR}/Frameworks/wine/bin/wineserver" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "${CONTENTS_DIR}/Resources/SWCLI/runtime/PythonNative/bin/python3" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == */swcli_path.py ]]; then
    exec "${SWCLI_TEST_PYTHON}" "$@"
fi
if [[ "${1:-}" == "-I" && "${2:-}" == */swcli_runtime.py ]]; then
    printf 'sync prefix=%s\n' "${WINEPREFIX}" >> "${SWCLI_TEST_LOG}"
    exit "${SWCLI_TEST_SYNC_STATUS:-0}"
fi
if [[ "${1:-}" == "-I" && "${2:-}" == */wine_runtime.py ]]; then
    if [[ "${3:-}" == "check" ]]; then
        exit "${SWCLI_TEST_WINE_STATUS:-0}"
    fi
    while [[ "${1:-}" != "--" ]]; do shift; done
    shift
    exec "$@"
fi
printf 'native translator=%s args=%s\n' "${SWCLI_PATH_TRANSLATE_CMD:-}" "$*" >> "${SWCLI_TEST_LOG}"
EOF
chmod +x \
    "${CONTENTS_DIR}/MacOS/sw-cli" \
    "${CONTENTS_DIR}/Frameworks/wine/bin/wineloader" \
    "${CONTENTS_DIR}/Frameworks/wine/bin/wineserver" \
    "${CONTENTS_DIR}/Resources/SWCLI/bin/swcli-path" \
    "${CONTENTS_DIR}/Resources/SWCLI/runtime/PythonNative/bin/python3"

export MACSW_WINEPREFIX="${PREFIX}"
export SWCLI_TEST_LOG="${LOG_FILE}"
export SWCLI_TEST_PYTHON="$(command -v python3)"
LAUNCHER="${CONTENTS_DIR}/MacOS/sw-cli"

if SWCLI_TEST_WINE_STATUS=1 "${LAUNCHER}" doctor --json; then
    echo 'doctor ignored Wine runtime preflight' >&2
    exit 1
fi
test ! -s "${LOG_FILE}"

"${LAUNCHER}" --help
grep -Fq 'native translator=' "${LOG_FILE}"
! grep -Fq 'windows ' "${LOG_FILE}"

: > "${LOG_FILE}"
if SWCLI_TEST_SYNC_STATUS=1 "${LAUNCHER}" doctor --json; then
    echo 'doctor ignored runtime synchronization failure inside conditional routing' >&2
    exit 1
fi
! grep -Fq 'windows ' "${LOG_FILE}"

: > "${LOG_FILE}"
STATUS_OUTPUT="$(MACSW_WINE_LOCALE=en_US.UTF-8 "${LAUNCHER}" daemon status --json)"
test "${STATUS_OUTPUT}" = '{"mock":true}'
grep -Fq 'windows translator=Z:' "${LOG_FILE}"
grep -Fq 'pythonw.exe -c' "${LOG_FILE}"
grep -Fq 'aot=none' "${LOG_FILE}"
grep -Fq 'surfaces=1 wiccache=1 modreads=1 args=' "${LOG_FILE}"
grep -Fq 'overrides=atiadlxx=d;concrt140=n,b;msvcp140=n,b;msvcp140_1=n,b;msvcp140_2=n,b;msvcp140_atomic_wait=n,b;msvcp140_codecvt_ids=n,b;vcruntime140=n,b;vcruntime140_1=n,b;vcomp140=n,b;mfc140u=n,b' "${LOG_FILE}"
grep -Fq 'lang=en_US.UTF-8 lc_all=en_US.UTF-8' "${LOG_FILE}"
# Locale is one setting: zh_CN stays selectable, unknown values fall back to English.
: > "${LOG_FILE}"
MACSW_WINE_LOCALE=zh_CN.UTF-8 "${LAUNCHER}" daemon status --json >/dev/null
grep -Fq 'lang=zh_CN.UTF-8 lc_all=zh_CN.UTF-8' "${LOG_FILE}"
: > "${LOG_FILE}"
MACSW_WINE_LOCALE=bogus "${LAUNCHER}" daemon status --json >/dev/null
grep -Fq 'lang=en_US.UTF-8 lc_all=en_US.UTF-8' "${LOG_FILE}"
grep -Fq "loader=${CONTENTS_DIR}/Frameworks/wine/bin/wineloader server=${CONTENTS_DIR}/Frameworks/wine/bin/wineserver" "${LOG_FILE}"
! grep -Fq 'native ' "${LOG_FILE}"

: > "${LOG_FILE}"
"${LAUNCHER}" daemon serve --port 18496
grep -Fq "sync prefix=${PREFIX}" "${LOG_FILE}"
grep -Fq 'C:\MacSW\Python311\python.exe -m swcli daemon serve --port 18496' "${LOG_FILE}"
! grep -Fq 'pythonw.exe' "${LOG_FILE}"
! grep -Fq 'native ' "${LOG_FILE}"

# Lifecycle inspection/stop must work even while a stale backend is busy.
: > "${LOG_FILE}"
SWCLI_TEST_SYNC_STATUS=1 "${LAUNCHER}" daemon stop --json
! grep -Fq 'sync prefix=' "${LOG_FILE}"
grep -Fq 'pythonw.exe -c' "${LOG_FILE}"

: > "${LOG_FILE}"
if SWCLI_TEST_SYNC_STATUS=1 "${LAUNCHER}" daemon serve --port 18496; then
    echo 'daemon serve ignored runtime synchronization failure' >&2
    exit 1
fi
! grep -Fq 'windows ' "${LOG_FILE}"

: > "${LOG_FILE}"
"${LAUNCHER}" document list --json
! grep -Fq 'windows ' "${LOG_FILE}"
grep -Fq 'native translator=' "${LOG_FILE}"
grep -Fq -- '-m swcli document list --json' "${LOG_FILE}"

: > "${LOG_FILE}"
"${LAUNCHER}" part create-box /tmp/box.SLDPRT --width-mm 1 --height-mm 2 --depth-mm 3 --json
! grep -Fq 'windows ' "${LOG_FILE}"
grep -Fq -- '-m swcli part create-box' "${LOG_FILE}"

TMP_PHYSICAL="$(cd /tmp && pwd -P)"
EXPECTED_TMP="Z:${TMP_PHYSICAL//\//\\}\\model.SLDPRT"
test "$("${CONTENTS_DIR}/Resources/SWCLI/bin/swcli-path" /tmp/model.SLDPRT)" = "${EXPECTED_TMP}"
test "$(cd /tmp && "${CONTENTS_DIR}/Resources/SWCLI/bin/swcli-path" model.SLDPRT)" = "${EXPECTED_TMP}"
test "$("${CONTENTS_DIR}/Resources/SWCLI/bin/swcli-path" 'C:\model.SLDPRT')" = 'C:\model.SLDPRT'
test "$("${CONTENTS_DIR}/Resources/SWCLI/bin/swcli-path" \
    "${PREFIX}/drive_c/models/part with spaces.SLDPRT")" = 'C:\models\part with spaces.SLDPRT'

# Lifecycle paths also use real bottle mappings, rather than hard-coding Z:.
rm "${PREFIX}/dosdevices/z:"
ln -s "${TEST_ROOT}" "${PREFIX}/dosdevices/h:"
mkdir -p "${PREFIX}/drive_c/tmp"
: > "${LOG_FILE}"
(cd "${PREFIX}/drive_c" && TMPDIR="${PREFIX}/drive_c/tmp/" "${LAUNCHER}" daemon serve --port 18496)
grep -Fq 'windows translator=H:\MacSW.app\Contents\Resources\SWCLI\bin\swcli_path.exe' "${LOG_FILE}"
! grep -Fq 'translator=Z:' "${LOG_FILE}"
