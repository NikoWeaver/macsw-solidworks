"""Verify packaged runtime primitives in a disposable Wine prefix, without SW.

This is not Toolbox GUI/CAD acceptance. Always require completion markers:
an unpatched Mono assertion can exit zero.
"""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time

PROJECT = Path(__file__).resolve().parents[2]
BOOTSTRAP_PE_FILES = ('system32/wineboot.exe', 'system32/kernel32.dll',
                      'system32/cmd.exe', 'syswow64/cmd.exe')


def validate_output(output, marker, returncode):
    lines = output.replace('\r\n','\n').splitlines()
    failures = ('Assertion at', 'Unhandled Exception', 'Native Crash Reporting', 'noexec filesystem?')
    if returncode != 0 or marker not in lines or any(failure in output for failure in failures):
        raise RuntimeError('Native runtime probe did not complete: '+marker)


def initialize_prefix(run, prefix, loader):
    """Exercise the installer's exact command, not Shell/start.exe fallback."""
    if prefix.exists():
        raise RuntimeError('Bootstrap probe requires an absent, fresh Wine prefix')
    run('wineboot', [loader, r'C:\windows\system32\wineboot.exe', '-u'], timeout=240)
    for relative in BOOTSTRAP_PE_FILES:
        path = prefix/'drive_c/windows'/relative
        try:
            with path.open('rb') as stream:
                valid = stream.read(2) == b'MZ'
        except OSError:
            valid = False
        if not valid:
            raise RuntimeError('Wine bootstrap did not deploy a PE module: '+relative)
    for arch, directory in (('X64', 'system32'), ('X86', 'syswow64')):
        marker = 'WINE_BOOTSTRAP_'+arch+'_PASS'
        run('bootstrap-'+arch.lower(), [loader, 'C:\\windows\\'+directory+'\\cmd.exe',
                                       '/c', 'echo', marker], marker)


def verify(app, evidence, *, bootstrap_only=False):
    app = app.resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    wine = app/'Contents/Frameworks/wine'
    loader = wine/'lib/wine/x86_64-unix/MacSW'
    server = wine/'bin/wineserver'
    with (app/'Contents/Resources/BuildManifest.plist').open('rb') as stream:
        manifest = plistlib.load(stream)
    mono = wine/'share/wine/mono'/('wine-mono-'+manifest['MonoVersion'])
    with tempfile.TemporaryDirectory(prefix='MacSW toolbox primitives ') as directory:
        root = Path(directory)
        prefix = root/'bottle'
        env = dict(os.environ)
        for key in ('WINEDLLPATH','CX_ROOT','CX_BOTTLE','DYLD_LIBRARY_PATH','DYLD_FALLBACK_LIBRARY_PATH',
                    'WINEDLLOVERRIDES','MONO_ENV_OPTIONS','MONO_TLS_PROVIDER',
                    'MACSW_WINELOADER','MACSW_APP_NAME'):
            env.pop(key,None)
        env.update(WINEPREFIX=str(prefix),WINELOADER=str(loader),WINESERVER=str(server),
                   WINEDEBUG='err+all',WINE_MONO_AOT='interp',LANG='en_US.UTF-8',LC_ALL='en_US.UTF-8')
        def windows(path):
            # A prefix created by Wine has its own Z: mapping; do not assume
            # that the user's main prefix has one.
            return 'Z:'+str(path).replace('/','\\')
        def run(name, arguments, marker=None, *, timeout=120):
            log = evidence/(name+'.log')
            started = time.monotonic()
            with log.open('xb') as output:
                result = subprocess.run(list(map(str,arguments)),env=env,cwd=root,
                                        stdin=subprocess.DEVNULL,stdout=output,stderr=output,timeout=timeout)
            text = log.read_text(errors='replace')
            if marker:
                validate_output(text,marker,result.returncode)
            elif result.returncode != 0:
                raise RuntimeError('Runtime probe command failed: '+name)
            print(name+' passed in '+str(round(time.monotonic()-started,2))+'s',flush=True)
        try:
            initialize_prefix(run, prefix, loader)
            if bootstrap_only:
                return
            env['WINE_MONO_AOT'] = 'none'
            run('mono-path',[loader,'reg','add',r'HKCU\Software\Wine\Mono','/v','RuntimePath',
                             '/t','REG_SZ','/d',windows(mono),'/f'])
            executable = root/'msxml-schema.exe'
            run('msxml-compile',['x86_64-w64-mingw32-gcc','-O2','-Wall',
                                PROJECT/'native/msxml_schema_namespace_probe.c','-o',executable,'-lole32','-loleaut32'])
            run('msxml',[loader,windows(executable)],'XML_NAMESPACE_PROBE_PASS')
            certificate = root/'btls-cert.pem'
            run('certificate',['openssl','req','-x509','-newkey','rsa:2048','-nodes',
                               '-subj','/CN=MacSW-CCW-Probe','-days','1',
                               '-keyout',root/'btls-key.pem','-out',certificate])
            for stem, marker, arguments in (
                ('mono_ccw_release_probe','CCW_RELEASE_PROBE_PASS',[]),
                ('mono_btls_probe','MONO_BTLS_PROBE_PASS',[windows(certificate)]),
            ):
                executable = root/(stem+'.exe')
                run(stem+'-compile',[loader,windows(mono/'lib/mono/4.5/mcs.exe'),'-platform:x64',
                                    '-out:'+windows(executable),windows(PROJECT/'native'/(stem+'.cs'))])
                run(stem,[loader,windows(executable),*arguments],marker)
        finally:
            # Only this fresh prefix is stopped; never use inherited WINEPREFIX.
            failed = sys.exc_info()[0] is not None
            try:
                subprocess.run([str(server),'-k'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=30)
                subprocess.run([str(server),'-w'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=30,check=True)
            except Exception:
                if not failed:
                    raise
                print('Probe cleanup failed; original test failure preserved.',file=sys.stderr)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app',required=True,type=Path)
    parser.add_argument('--evidence',required=True,type=Path)
    parser.add_argument('--bootstrap-only',action='store_true',
                        help='Only verify fresh installer initialization and x64/x86 PE execution')
    arguments = parser.parse_args()
    verify(arguments.app,arguments.evidence,bootstrap_only=arguments.bootstrap_only)
