# Third-party notices

MacSW.app 0.2.0-rc.2 (build 6) contains the software listed below. Each part keeps
its own licence and copyright notices. This list comes from `config/third-party-notices.tsv`.
The full notices, with every licence text, are in `THIRD_PARTY_NOTICES.txt`: in each built app
(`Contents/Resources`) and in the `Licenses` folder of the DMG. `scripts/third_party_notices.py`
writes that file at package time and stops the build when a part of the bundle is not in the
table. `SOURCE.txt`, next to it, says where to get the source code of the parts under the GNU LGPL
and of MacSW itself.

SOLIDWORKS is a registered trademark of Dassault Systemes SolidWorks Corporation. This app is not made, endorsed or supported by Dassault Systemes. It contains no SOLIDWORKS program files; you install SOLIDWORKS from your own licensed media.

This source tree also holds the Wine patches in `patches/wine-crossover` (LGPL-2.1-or-later, see
`patches/wine-crossover/LICENSE`) and the libinotify-kqueue headers in `third_party/libinotify-kqueue`
(MIT, see its `LICENSE`).

| # | Component | Version | Licence | In MacSW.app |
|---|---|---|---|---|
| 1 | MacSW (fork of YJBeetle/MacSW) | 0.2.0 (build 6) | Apache-2.0 | `Contents/MacOS/MacSW`<br>`Contents/Resources/SOLIDWORKS.app.zip`<br>`Contents/Resources/SOLIDWORKS.app.plist`<br>`Contents/Resources/helpers/msi_spatialiop.exe` |
| 2 | Wine | 11.16 | LGPL-2.1-or-later | `Contents/Resources/Wine/bin/*`<br>`Contents/Resources/Wine/lib/wine`<br>`Contents/Resources/Wine/share/wine/fonts`<br>`Contents/Resources/Wine/share/wine/nls`<br>`Contents/Resources/Wine/share/wine/wine.inf`<br>`Contents/Resources/Wine/share/wine/winmd` |
| 3 | GnuTLS | 3.8.7 (libgnutls.30) | LGPL-2.1-or-later | `Contents/Resources/Wine/lib/libgnutls*` |
| 4 | Nettle | 3.10 (libnettle.8.9, libhogweed.6.9) | LGPL-3.0-or-later OR GPL-2.0-or-later (used under LGPL-3.0-or-later) | `Contents/Resources/Wine/lib/libnettle*`<br>`Contents/Resources/Wine/lib/libhogweed*` |
| 5 | GMP | 6.3.0 | LGPL-3.0-or-later OR GPL-2.0-or-later (used under LGPL-3.0-or-later) | `Contents/Resources/Wine/lib/libgmp*` |
| 6 | libtasn1 | 4.20.0 | LGPL-2.1-or-later | `Contents/Resources/Wine/lib/libtasn1*` |
| 7 | libunistring | 1.3 (libunistring.5) | LGPL-3.0-or-later OR GPL-2.0-or-later (used under LGPL-3.0-or-later) | `Contents/Resources/Wine/lib/libunistring*` |
| 8 | libidn2 | 2.3.7 | LGPL-3.0-or-later OR GPL-2.0-or-later (used under LGPL-3.0-or-later); Unicode data under the Unicode licence | `Contents/Resources/Wine/lib/libidn2*` |
| 9 | GNU libiconv | 1.17 (libiconv.2, libcharset.1) | LGPL-2.1-or-later | `Contents/Resources/Wine/lib/libiconv*`<br>`Contents/Resources/Wine/lib/libcharset*` |
| 10 | GNU gettext (libintl) | 0.22.5 (libintl.8) | LGPL-2.1-or-later | `Contents/Resources/Wine/lib/libintl*` |
| 11 | p11-kit | libp11-kit.0 | BSD-3-Clause | `Contents/Resources/Wine/lib/libp11-kit*`<br>`Contents/Resources/Wine/lib/p11-kit-proxy.dylib` |
| 12 | FreeType | libfreetype.6 | FTL OR GPL-2.0-or-later (used under the FreeType License) | `Contents/Resources/Wine/lib/libfreetype*` |
| 13 | ICU | 76.1 | Unicode-3.0 | `Contents/Resources/Wine/lib/libicu*` |
| 14 | MoltenVK | libMoltenVK | Apache-2.0 | `Contents/Resources/Wine/lib/libMoltenVK.dylib` |
| 15 | Vulkan Loader | 1.4.350 | Apache-2.0 | `Contents/Resources/Wine/lib/libvulkan*` |
| 16 | SDL2 | 2.32.8 | Zlib | `Contents/Resources/Wine/lib/libSDL2*` |
| 17 | libxml2 | libxml2.2 | MIT | `Contents/Resources/Wine/lib/libxml2*` |
| 18 | libxslt and libexslt | libxslt.1, libexslt.0 | MIT | `Contents/Resources/Wine/lib/libxslt*`<br>`Contents/Resources/Wine/lib/libexslt*` |
| 19 | libffi | libffi.8 | MIT | `Contents/Resources/Wine/lib/libffi*` |
| 20 | Brotli | 1.1.0 | MIT | `Contents/Resources/Wine/lib/libbrotli*` |
| 21 | bzip2 | 1.0.8 | bzip2-1.0.6 | `Contents/Resources/Wine/lib/libbz2*` |
| 22 | LZ4 | 1.10.0 | BSD-2-Clause | `Contents/Resources/Wine/lib/liblz4*` |
| 23 | XZ Utils (liblzma) | 5.6.4 | 0BSD | `Contents/Resources/Wine/lib/liblzma*` |
| 24 | Zstandard | 1.5.6 | BSD-3-Clause | `Contents/Resources/Wine/lib/libzstd*` |
| 25 | libpcap | 1.10.5 | BSD-3-Clause | `Contents/Resources/Wine/lib/libpcap*` |
| 26 | libpng | 1.6.45 | libpng-2.0 | `Contents/Resources/Wine/lib/libpng*` |
| 27 | zlib | 1.3.1 | Zlib | `Contents/Resources/Wine/lib/libz.*` |
| 28 | libinotify-kqueue | libinotify.0 | MIT | `Contents/Resources/Wine/lib/libinotify*` |
| 29 | MacPorts legacy-support | 1.4.0 | See upstream (MIT, BSD and APSL-2.0 parts) | `Contents/Resources/Wine/lib/libMacportsLegacy*` |
| 30 | Wine Gecko | 2.47.4 | MPL-2.0 and others | `Contents/Resources/Wine/share/wine/gecko` |
| 31 | Wine Mono | 11.3.0, with wine-mono-11.3.0-X86StdcallFix-ComRegistration-CCWFix | MIT, LGPL-2.0 and others (see the files below) | `Contents/Resources/Wine/share/wine/mono` |
| 32 | 7-Zip | 23.01 | LGPL-2.1-or-later, BSD-3-Clause, and LGPL-2.1-or-later with the unRAR restriction | `Contents/MacOS/7zz`<br>`Contents/MacOS/7z` |
| 33 | stdole | 7.0.3300 | Microsoft licence (http://go.microsoft.com/fwlink/?LinkID=746386) | `Contents/Resources/managed/stdole.dll` |
| 34 | Python (native, python-build-standalone) | 3.11.16, release 20260901 | PSF-2.0, and the licences of the libraries it includes | `Contents/Resources/SWCLI/runtime/PythonNative` |

## Sources and notes

1. **MacSW (fork of YJBeetle/MacSW).** Source: https://github.com/NikoWeaver/macsw-solidworks (this fork; this build: see SOURCE.txt), based on https://github.com/YJBeetle/MacSW 69c5509. A modified version of MacSW, not an official MacSW release. The MacSW launcher, the SOLIDWORKS.app launcher and the SpatialIOP MSI edit helper (native/msi_spatialiop.c, built with MinGW-w64).
2. **Wine.** Source: https://dl.winehq.org/wine/source/11.x/wine-11.16.tar.xz (SHA-256 c66e2090343dcd727f7f7fd2f87ee0bfb0b118790c1d745ab7b8a4c3a4197f2f), plus MacSW's patches 0001-0037 (see SOURCE.txt). The runtime is the Gcenx macOS Wine build https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.16/wine-devel-11.16-osx64.tar.xz (SHA-256 6f9af818b7af6001aeed7818cb32bf0155598c5ea4e3b33380a03cf814e033cd). MacSW replaces some of its modules with modules built from the Wine source above and patches 0001-0037. Wine contains code from other projects (libpng, zlib, libxml2, libxslt, LibJPEG, LibTIFF, Little CMS, FluidSynth, mpg123, vkd3d, ICU, OpenLDAP, musl, LLVM and more); their notices are in Wine's NOTICES.md below.
3. **GnuTLS.** Source: https://www.gnutls.org; source archive https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-3.8.7.tar.xz. From the Gcenx Wine runtime, unchanged (as all libraries in Resources/Wine/lib).
4. **Nettle.** Source: https://www.lysator.liu.se/~nisse/nettle/; source archive https://ftp.gnu.org/gnu/nettle/nettle-3.10.tar.gz. The LGPL 3.0 adds terms to the GPL 3.0, so both texts apply.
5. **GMP.** Source: https://gmplib.org; source archive https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.bz2.
6. **libtasn1.** Source: https://www.gnu.org/software/libtasn1/; source archive https://ftp.gnu.org/gnu/libtasn1/libtasn1-4.20.0.tar.gz.
7. **libunistring.** Source: https://www.gnu.org/software/libunistring/; source archive https://ftp.gnu.org/gnu/libunistring/libunistring-1.3.tar.gz.
8. **libidn2.** Source: https://www.gnu.org/software/libidn/#libidn2; source archive https://ftp.gnu.org/gnu/libidn/libidn2-2.3.7.tar.gz.
9. **GNU libiconv.** Source: https://www.gnu.org/software/libiconv/; source archive https://ftp.gnu.org/gnu/libiconv/libiconv-1.17.tar.gz.
10. **GNU gettext (libintl).** Source: https://www.gnu.org/software/gettext/; source archive https://ftp.gnu.org/gnu/gettext/gettext-0.22.5.tar.gz.
11. **p11-kit.** Source: https://p11-glue.github.io/p11-glue/p11-kit.html.
12. **FreeType.** Source: https://freetype.org. Portions of this software are copyright © The FreeType Project (www.freetype.org). All rights reserved.
13. **ICU.** Source: https://icu.unicode.org.
14. **MoltenVK.** Source: https://github.com/KhronosGroup/MoltenVK. Copyright The Brenwill Workshop Ltd. Licensed under the Apache License, Version 2.0.
15. **Vulkan Loader.** Source: https://github.com/KhronosGroup/Vulkan-Loader. Copyright The Khronos Group Inc., Valve Corporation and LunarG, Inc. Licensed under the Apache License, Version 2.0.
16. **SDL2.** Source: https://www.libsdl.org.
17. **libxml2.** Source: https://gitlab.gnome.org/GNOME/libxml2.
18. **libxslt and libexslt.** Source: https://gitlab.gnome.org/GNOME/libxslt.
19. **libffi.** Source: https://sourceware.org/libffi/.
20. **Brotli.** Source: https://github.com/google/brotli.
21. **bzip2.** Source: https://sourceware.org/bzip2/.
22. **LZ4.** Source: https://github.com/lz4/lz4.
23. **XZ Utils (liblzma).** Source: https://tukaani.org/xz/.
24. **Zstandard.** Source: https://github.com/facebook/zstd.
25. **libpcap.** Source: https://www.tcpdump.org.
26. **libpng.** Source: http://www.libpng.org/pub/png/libpng.html.
27. **zlib.** Source: https://zlib.net.
28. **libinotify-kqueue.** Source: https://github.com/libinotify-kqueue/libinotify-kqueue.
29. **MacPorts legacy-support.** Source: https://github.com/macports/macports-legacy-support. The licence text is not in this file yet. It is in the upstream source at the address above.
30. **Wine Gecko.** Source: https://dl.winehq.org/wine/wine-gecko/2.47.4/. Text of about:license from Gecko's omni.ja: the MPL 2.0 and the notices of the code Gecko includes.
31. **Wine Mono.** Source: https://github.com/wine-mono/wine-mono; see licenses/Mono/SOURCE.txt. MacSW replaces five files with patched builds (libmono-2.0-x86.dll, libmono-2.0-x86_64.dll, mscorlib.dll and the two regasm.exe in Resources/Wine/lib/wine).
32. **7-Zip.** Source: https://www.7-zip.org (source: https://www.7-zip.org/a/7z2301-src.tar.xz). 7zz is the unchanged macOS console build from 7-zip.org; 7z is a link to it.
33. **stdole.** Source: https://www.nuget.org/packages/stdole/7.0.3300. © Microsoft Corporation. All rights reserved. Taken unchanged from the NuGet package (SHA-256 4650fd3efc38255954558bd22f2e28f241ff1c27f068687b45fc95b72c9c9de4); the licence address is from the package's stdole.nuspec. That address now leads to Microsoft's pre-release licence terms for Visual Studio 2017, which allow evaluation use only and no distribution.
34. **Python (native, python-build-standalone).** Source: https://github.com/astral-sh/python-build-standalone. Runs MacSW's bottle tools (wine_runtime.py). pip's own licence files stay in the runtime (lib/python3.11/site-packages/pip-*.dist-info/licenses).
