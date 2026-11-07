// stdole.cs - a clean-room "stdole" interop assembly for Wine-Mono (MacSW prototype).
//
// Licence: the declarations below follow Wine's stdole2.idl (Copyright (C) 2003 Robert Shearman,
// 2005 Huw Davies), which is under the GNU LGPL 2.1 or later; this file is offered under the
// same licence (LGPL-2.1-or-later). Status: prototype; the owner decides the licence questions.
//
// What it is: managed declarations of the OLE Automation type library (stdole2.tlb,
// library uuid 00020430-0000-0000-C000-000000000046, version 2.0), so that .NET
// assemblies built against "stdole, Version=7.0.3300.0, PublicKeyToken=b03f5f7f11d50a3a"
// can bind and marshal under Wine-Mono.
//
// Where the shapes come from (nothing else was used):
//   - Wine 11.16 dlls/stdole2.tlb/stdole2.idl (LGPL-2.1-or-later): names, GUIDs, member
//     order, parameter types.
//   - Wine 11.16 include/olectl.h: the DISPID values.
//   - The TypeRef/MemberRef rows of the SOLIDWORKS 2026 assemblies that use stdole
//     (DwgDocumentMgrNET4.dll: IPicture, IUnknown, IDispatch, IPicture::get_Handle
//     returning int32; office.dll 15.0: IPictureDisp).
//   - The usual type library to .NET mapping (HRESULT -> exception, [out, retval] ->
//     return value, BSTR -> string, CURRENCY -> decimal, VARIANT_BOOL -> bool,
//     OLE_HANDLE/long -> int, typedef aliases of dispinterfaces -> their own interface).
// No code, IL, metadata or resources were taken from Microsoft's stdole.dll.
//
// COM vtable rule: for a [ComImport] interface the runtime adds the IUnknown (or IDispatch)
// slots itself, and the declared methods follow in declaration order. So members are
// declared exactly in the IDL order, and IPicture's hPal accessors are plain methods
// (the IDL puts get_hPal in slot 2 and put_hPal in slot 7; a C# property would make
// them adjacent).

using System;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

[assembly: AssemblyTitle("stdole")]
[assembly: AssemblyDescription("OLE Automation type declarations for Wine-Mono (MacSW clean-room prototype, from Wine's stdole2.idl)")]
[assembly: AssemblyProduct("MacSW")]
[assembly: AssemblyInformationalVersion("7.0.3300.0-macsw-cleanroom.1")]
[assembly: AssemblyVersion("7.0.3300.0")]
[assembly: AssemblyFileVersion("7.0.3300.0")]
[assembly: ImportedFromTypeLib("stdole")]
[assembly: Guid("00020430-0000-0000-C000-000000000046")]
[assembly: TypeLibVersion(2, 0)]
[assembly: PrimaryInteropAssembly(2, 0)]
[assembly: ComVisible(true)]

namespace stdole
{
    // ---------------------------------------------------------------- structures

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct GUID
    {
        public uint Data1;
        public ushort Data2;
        public ushort Data3;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 8)]
        public byte[] Data4;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct DISPPARAMS
    {
        public IntPtr rgvarg;             // VARIANT *
        public IntPtr rgdispidNamedArgs;  // long *
        public uint cArgs;
        public uint cNamedArgs;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct EXCEPINFO
    {
        public ushort wCode;
        public ushort wReserved;
        [MarshalAs(UnmanagedType.BStr)] public string bstrSource;
        [MarshalAs(UnmanagedType.BStr)] public string bstrDescription;
        [MarshalAs(UnmanagedType.BStr)] public string bstrHelpFile;
        public uint dwHelpContext;
        public IntPtr pvReserved;
        public IntPtr pfnDeferredFillIn;
        public int scode;
    }

    // ---------------------------------------------------------------- enums

    [Guid("6650430A-BE0F-101A-8BBB-00AA00300CAB")]
    public enum OLE_TRISTATE
    {
        Unchecked = 0,
        Checked = 1,
        Gray = 2
    }

    [Guid("E6C8FA08-BD9F-11D0-985E-00C04FC29993")]
    public enum LoadPictureConstants
    {
        Default = 0,
        Monochrome = 1,
        VgaColor = 2,
        Color = 4
    }

    // ---------------------------------------------------------------- base interfaces

    // IDL: interface IUnknown { QueryInterface; AddRef; Release } - the three slots that
    // every COM interface starts with. The runtime supplies them, so nothing is declared.
    [ComImport, Guid("00000000-0000-0000-C000-000000000046")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IUnknown
    {
    }

    // IDL: interface IDispatch : IUnknown (all four methods [restricted]).
    [ComImport, Guid("00020400-0000-0000-C000-000000000046")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IDispatch
    {
        void GetTypeInfoCount(out uint pctinfo);
        void GetTypeInfo(uint itinfo, uint lcid, out IntPtr pptinfo);
        void GetIDsOfNames(ref GUID riid, IntPtr rgszNames, uint cNames, uint lcid, out int rgdispid);
        void Invoke(int dispidMember, ref GUID riid, uint lcid, ushort wFlags, ref DISPPARAMS pdispparams,
                    out object pvarResult, out EXCEPINFO pexcepinfo, out uint puArgErr);
    }

    // IDL: interface IEnumVARIANT : IUnknown
    [ComImport, Guid("00020404-0000-0000-C000-000000000046")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IEnumVARIANT
    {
        void Next(uint celt, ref object rgvar, out uint pceltFetched);
        void Skip(uint celt);
        void Reset();
        void Clone(out IEnumVARIANT ppenum);
    }

    // ---------------------------------------------------------------- font

    // IDL: interface IFont : IUnknown (odl, hidden)
    [ComImport, Guid("BEF6E002-A874-101A-8BBA-00AA00300CAB")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IFont
    {
        string Name
        {
            [return: MarshalAs(UnmanagedType.BStr)] get;
            [param: MarshalAs(UnmanagedType.BStr)] set;
        }
        decimal Size
        {
            [return: MarshalAs(UnmanagedType.Currency)] get;
            [param: MarshalAs(UnmanagedType.Currency)] set;
        }
        bool Bold
        {
            [return: MarshalAs(UnmanagedType.VariantBool)] get;
            [param: MarshalAs(UnmanagedType.VariantBool)] set;
        }
        bool Italic
        {
            [return: MarshalAs(UnmanagedType.VariantBool)] get;
            [param: MarshalAs(UnmanagedType.VariantBool)] set;
        }
        bool Underline
        {
            [return: MarshalAs(UnmanagedType.VariantBool)] get;
            [param: MarshalAs(UnmanagedType.VariantBool)] set;
        }
        bool Strikethrough
        {
            [return: MarshalAs(UnmanagedType.VariantBool)] get;
            [param: MarshalAs(UnmanagedType.VariantBool)] set;
        }
        short Weight { get; set; }
        short Charset { get; set; }
        int hFont { get; }                      // OLE_HANDLE
        void Clone(out IFont ppfont);
        void IsEqual(IFont pfontOther);
        void SetRatio(int cyLogical, int cyHimetric);
        void AddRefHfont(int hFont);            // OLE_HANDLE
        void ReleaseHfont(int hFont);           // OLE_HANDLE
    }

    // IDL: dispinterface Font, and "typedef [public] Font IFontDisp".
    [ComImport, Guid("BEF6E003-A874-101A-8BBA-00AA00300CAB")]
    [InterfaceType(ComInterfaceType.InterfaceIsIDispatch)]
    public interface IFontDisp
    {
        [DispId(0)] string Name { get; set; }   // DISPID_FONT_NAME
        [DispId(2)] decimal Size { [return: MarshalAs(UnmanagedType.Currency)] get; [param: MarshalAs(UnmanagedType.Currency)] set; }
        [DispId(3)] bool Bold { get; set; }
        [DispId(4)] bool Italic { get; set; }
        [DispId(5)] bool Underline { get; set; }
        [DispId(6)] bool Strikethrough { get; set; }
        [DispId(7)] short Weight { get; set; }
        [DispId(8)] short Charset { get; set; }
    }

    [ComImport, Guid("BEF6E003-A874-101A-8BBA-00AA00300CAB")]
    [InterfaceType(ComInterfaceType.InterfaceIsIDispatch)]
    public interface Font : IFontDisp
    {
    }

    // IDL: coclass StdFont { [default] dispinterface Font; interface IFont; }
    [ComImport, Guid("BEF6E003-A874-101A-8BBA-00AA00300CAB")]
    [CoClass(typeof(StdFontClass))]
    public interface StdFont : Font
    {
    }

    [ComImport, Guid("0BE35203-8F91-11CE-9DE3-00AA004BB851")]
    [ClassInterface(ClassInterfaceType.None)]
    public class StdFontClass
    {
    }

    // IDL: dispinterface FontEvents, and "typedef [public] FontEvents IFontEventsDisp".
    [ComImport, Guid("4EF6100A-AF88-11D0-9846-00C04FC29993")]
    [InterfaceType(ComInterfaceType.InterfaceIsIDispatch)]
    public interface IFontEventsDisp
    {
        [DispId(9)] void FontChanged([In, MarshalAs(UnmanagedType.BStr)] string PropertyName);  // DISPID_FONT_CHANGED
    }

    [ComImport, Guid("4EF6100A-AF88-11D0-9846-00C04FC29993")]
    [InterfaceType(ComInterfaceType.InterfaceIsIDispatch)]
    public interface FontEvents : IFontEventsDisp
    {
    }

    // ---------------------------------------------------------------- picture

    // IDL: interface IPicture : IUnknown (odl, hidden). Slot order = IDL order.
    [ComImport, Guid("7BF80980-BF32-101A-8BBB-00AA00300CAB")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPicture
    {
        int Handle { get; }                     // slot 1: [propget] Handle (OLE_HANDLE)
        int get_hPal();                         // slot 2: [propget] hPal
        short Type { get; }                     // slot 3
        int Width { get; }                      // slot 4: OLE_XSIZE_HIMETRIC
        int Height { get; }                     // slot 5: OLE_YSIZE_HIMETRIC
        void Render(int hdc, int x, int y, int cx, int cy,
                    int xSrc, int ySrc, int cxSrc, int cySrc, IntPtr prcWBounds);  // slot 6
        void set_hPal(int phpal);               // slot 7: [propput] hPal
        int CurDC { get; }                      // slot 8
        void SelectPicture(int hdcIn, out int phdcOut, out int phbmpOut);         // slot 9
        bool KeepOriginalFormat                 // slots 10, 11
        {
            [return: MarshalAs(UnmanagedType.VariantBool)] get;
            [param: MarshalAs(UnmanagedType.VariantBool)] set;
        }
        void PictureChanged();                  // slot 12
        void SaveAsFile(IntPtr pstm, [MarshalAs(UnmanagedType.VariantBool)] bool fSaveMemCopy, out int pcbSize);  // slot 13
        int Attributes { get; }                 // slot 14
        void SetHdc(int hdc);                   // slot 15 (OLE_HANDLE)
    }

    // IDL: dispinterface Picture, and "typedef [public] Picture IPictureDisp".
    [ComImport, Guid("7BF80981-BF32-101A-8BBB-00AA00300CAB")]
    [InterfaceType(ComInterfaceType.InterfaceIsIDispatch)]
    public interface IPictureDisp
    {
        [DispId(0)] int Handle { get; }         // DISPID_PICT_HANDLE
        [DispId(2)] int hPal { get; set; }      // DISPID_PICT_HPAL
        [DispId(3)] short Type { get; }         // DISPID_PICT_TYPE
        [DispId(4)] int Width { get; }          // DISPID_PICT_WIDTH
        [DispId(5)] int Height { get; }         // DISPID_PICT_HEIGHT
        [DispId(6)] void Render(int hdc, int x, int y, int cx, int cy,
                                int xSrc, int ySrc, int cxSrc, int cySrc, IntPtr prcWBounds);  // DISPID_PICT_RENDER
    }

    [ComImport, Guid("7BF80981-BF32-101A-8BBB-00AA00300CAB")]
    [InterfaceType(ComInterfaceType.InterfaceIsIDispatch)]
    public interface Picture : IPictureDisp
    {
    }

    // IDL: coclass StdPicture { [default] dispinterface Picture; interface IPicture; }
    [ComImport, Guid("7BF80981-BF32-101A-8BBB-00AA00300CAB")]
    [CoClass(typeof(StdPictureClass))]
    public interface StdPicture : Picture
    {
    }

    [ComImport, Guid("0BE35204-8F91-11CE-9DE3-00AA004BB851")]
    [ClassInterface(ClassInterfaceType.None)]
    public class StdPictureClass
    {
    }

    // IDL "module StdFunctions" (LoadPicture/SavePicture in oleaut32.dll) has no .NET
    // form in an interop assembly, so it is not declared.
}
