# stdole (clean-room build for Wine-Mono)

MacSW copies `stdole.dll` to `C:\Program Files\Common Files\SOLIDWORKS Shared` before the
SOLIDWORKS installer runs. The installer registers `DwgDocumentMgrNET4.dll` there with RegAsm, and
that assembly references `stdole, Version=7.0.3300.0`. Without a stdole assembly the RegAsm call
fails and registers nothing. Wine-Mono has no stdole assembly.

This folder replaces Microsoft's `stdole.dll` from the NuGet package `stdole` 7.0.3300 (its
licence terms allow evaluation use only and no distribution).

## Files

| File | SHA-256 |
|---|---|
| `stdole.cs` | `1ca59b7fff84d5e1a31147b0d0a55011004fe8bdbae86d5939d2f702a5cf3e5b` |
| `stdole.dll` | `e5d0ce39bfc7620ace151778527ebefeb92a255678c83ff6cc3cb8f550f1bac9` (`STDOLE_DLL_SHA256` in `config/versions.env`) |

`stdole.dll`: 9216 bytes, identity `stdole, Version=7.0.3300.0, Culture=neutral,
PublicKeyToken=null` (no strong name). It holds declarations only (71 methods, no IL, no
resources other than a version block). It has no code, IL, metadata, resources or key from
Microsoft's file.

## Source and licence

`stdole.cs` declares the OLE Automation type library (`stdole2.tlb`, library
`00020430-0000-0000-C000-000000000046`, version 2.0) in C#. The names, GUIDs, member order and
types come from Wine 11.16 `dlls/stdole2.tlb/stdole2.idl` (Copyright (C) 2003 Robert Shearman,
2005 Huw Davies) and the DISPID values from Wine 11.16 `include/olectl.h`. The list of types to
declare comes from the type and member references of the SOLIDWORKS 2026 assemblies that use
stdole. The header of `stdole.cs` gives the details.

Licence: GNU Lesser General Public License 2.1 or later (LGPL-2.1-or-later), the licence of the
Wine files it follows. The licence text is Wine's `COPYING.LIB`; MacSW.app has it in
`THIRD_PARTY_NOTICES.txt`.

## How it was built

Built on 2026-10-25 with the Roslyn C# compiler of Wine-Mono 11.3.0, under MacSW's Wine 11.16, in
a test bottle:

    csc.exe /nologo /target:library /platform:anycpu /optimize+ /deterministic+ /out:stdole.dll stdole.cs

(`csc.exe` is `C:\windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe` of the bottle.) The
build uses no key file and no signing options.

`stdole.cs` was saved 3 minutes after this build. A review compared its declarations with the
binary and found them the same (71 methods, the same GUIDs and strings). A rebuild from this copy
of `stdole.cs` has not been done yet, so it is not proved that it gives the same bytes. The assembly description in the binary still says "prototype"; a rebuild to change it
would change the SHA-256.

## Tests

In a clone of a bottle with SOLIDWORKS 2026 SP4.1, with this file in `SOLIDWORKS Shared`:

- x64 RegAsm `/codebase` of `DwgDocumentMgrNET4.dll` gave the same registry keys and values as
  with Microsoft's file (7 CLSIDs, 11 records, 7 ProgIDs, 25 CodeBase values). Without a stdole
  file RegAsm exits 100 and registers nothing.
- Loading `DwgDocumentMgrNET4.dll` and resolving all its signatures by reflection gave 0 errors,
  as with Microsoft's file.

## Limits

- The file binds because Wine-Mono's default loader does not compare the public key token when it
  probes a folder. If Wine-Mono turns on the strict check, the file no longer binds for
  assemblies that reference the Microsoft token.
- It is only for Wine-Mono. .NET Framework on Windows does not bind it in place of the
  strong-named Microsoft assembly.
- `scripts/ci/publication_scan.py` allows a `stdole.dll` only with the SHA-256 above. Any other
  `stdole.dll` is a proprietary-file hit.
