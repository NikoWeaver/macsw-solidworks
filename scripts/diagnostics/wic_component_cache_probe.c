/* wic_component_cache_probe.c - functional check and micro-benchmark for patch 0032 (WIC component registry cache).
 * Prints a canonical description of the WIC components and of a decoded PNG (with metadata), then times
 * N x (CreateDecoder(PNG) + Initialize + GetFrame + GetMetadataQueryReader + enumerate metadata).
 * The printed text must be identical with MACSW_WIC_COMPONENT_CACHE unset and =1.
 * Build: x86_64-w64-mingw32-gcc -O2 -o wic_component_cache_probe.exe wic_component_cache_probe.c -lole32 -loleaut32 -lwindowscodecs -luuid */
#define COBJMACROS
#include <windows.h>
#include <wincodec.h>
#include <wincodecsdk.h>
#include <stdio.h>
#include <stdlib.h>

static const GUID IID_IWICMetadataHandlerInfo_ = {0xaba958bf,0xc672,0x44d1,{0x8d,0x61,0xce,0x6d,0xf2,0xe6,0x82,0xc2}};

/* 2x1 RGBA PNG with tEXt (Comment=MacSW) and gAMA chunks */
static const unsigned char png[] = {0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a,0x00,0x00,0x00,0x0d,0x49,0x48,0x44,0x52,0x00,0x00,0x00,0x02,0x00,0x00,0x00,0x01,0x08,0x06,0x00,0x00,0x00,0xf4,0x22,0x7f,0x8a,0x00,0x00,0x00,0x0d,0x74,0x45,0x58,0x74,0x43,0x6f,0x6d,0x6d,0x65,0x6e,0x74,0x00,0x4d,0x61,0x63,0x53,0x57,0x1b,0x3c,0x4c,0x98,0x00,0x00,0x00,0x04,0x67,0x41,0x4d,0x41,0x00,0x00,0xb1,0x8f,0x0b,0xfc,0x61,0x05,0x00,0x00,0x00,0x0e,0x49,0x44,0x41,0x54,0x78,0x9c,0x63,0xf8,0xcf,0xc0,0x00,0x42,0x0d,0x00,0x0f,0x7a,0x03,0x7e,0x77,0xe9,0x7f,0x97,0x00,0x00,0x00,0x00,0x49,0x45,0x4e,0x44,0xae,0x42,0x60,0x82};

static void guid_str(const GUID *g, char *out)
{
    sprintf(out, "{%08lX-%04X-%04X-%02X%02X-%02X%02X%02X%02X%02X%02X}", g->Data1, g->Data2, g->Data3,
            g->Data4[0], g->Data4[1], g->Data4[2], g->Data4[3], g->Data4[4], g->Data4[5], g->Data4[6], g->Data4[7]);
}

static void list_components(IWICImagingFactory *factory, DWORD type, const char *label)
{
    IEnumUnknown *e; IUnknown *u; ULONG n; int count = 0;
    if (FAILED(IWICImagingFactory_CreateComponentEnumerator(factory, type, WICComponentEnumerateDefault, &e)))
    { printf("%s: enumerator failed\n", label); return; }
    while (IEnumUnknown_Next(e, 1, &u, &n) == S_OK)
    {
        IWICComponentInfo *info; CLSID clsid; char s[64]; WCHAR name[128]; UINT len = 0;
        if (SUCCEEDED(IUnknown_QueryInterface(u, &IID_IWICComponentInfo, (void **)&info)))
        {
            IWICComponentInfo_GetCLSID(info, &clsid); guid_str(&clsid, s);
            name[0] = 0; IWICComponentInfo_GetFriendlyName(info, 128, name, &len);
            printf("%s %s %ls", label, s, name);
            if (type == WICDecoder || type == WICEncoder)
            {
                IWICBitmapCodecInfo *codec; GUID fmt;
                if (SUCCEEDED(IWICComponentInfo_QueryInterface(info, &IID_IWICBitmapCodecInfo, (void **)&codec)))
                {
                    if (SUCCEEDED(IWICBitmapCodecInfo_GetContainerFormat(codec, &fmt))) { guid_str(&fmt, s); printf(" container %s", s); }
                    IWICBitmapCodecInfo_Release(codec);
                }
            }
            if (type == WICMetadataReader)
            {
                IWICMetadataHandlerInfo *mh; GUID fmt;
                if (SUCCEEDED(IWICComponentInfo_QueryInterface(info, &IID_IWICMetadataHandlerInfo_, (void **)&mh)))
                {
                    if (SUCCEEDED(IWICMetadataHandlerInfo_GetMetadataFormat(mh, &fmt))) { guid_str(&fmt, s); printf(" format %s", s); }
                    IWICMetadataHandlerInfo_Release(mh);
                }
            }
            printf("\n");
            IWICComponentInfo_Release(info);
        }
        IUnknown_Release(u); count++;
    }
    IEnumUnknown_Release(e);
    printf("%s count %d\n", label, count);
}

static HRESULT decode_once(IWICImagingFactory *factory, IWICStream *stream, int verbose)
{
    IWICBitmapDecoder *dec; IWICBitmapFrameDecode *frame; IWICMetadataQueryReader *qr;
    LARGE_INTEGER zero = {{0}}; UINT w, h; GUID fmt; char s[64]; HRESULT hr;
    IWICStream_Seek(stream, zero, STREAM_SEEK_SET, NULL);
    if (FAILED(hr = IWICImagingFactory_CreateDecoder(factory, &GUID_ContainerFormatPng, NULL, &dec))) return hr;
    if (FAILED(hr = IWICBitmapDecoder_Initialize(dec, (IStream *)stream, WICDecodeMetadataCacheOnDemand))) goto out;
    if (FAILED(hr = IWICBitmapDecoder_GetFrame(dec, 0, &frame))) goto out;
    IWICBitmapFrameDecode_GetSize(frame, &w, &h);
    IWICBitmapFrameDecode_GetPixelFormat(frame, &fmt);
    if (verbose) { guid_str(&fmt, s); printf("frame %ux%u format %s\n", w, h, s); }
    if (SUCCEEDED(IWICBitmapFrameDecode_GetMetadataQueryReader(frame, &qr)))
    {
        IEnumString *names; LPOLESTR name; ULONG n;
        if (SUCCEEDED(IWICMetadataQueryReader_GetEnumerator(qr, &names)))
        {
            while (IEnumString_Next(names, 1, &name, &n) == S_OK)
            {
                PROPVARIANT v; PropVariantInit(&v);
                if (verbose) printf("metadata %ls", name);
                if (SUCCEEDED(IWICMetadataQueryReader_GetMetadataByName(qr, name, &v)) && verbose) printf(" vt %u", v.vt);
                if (verbose) printf("\n");
                PropVariantClear(&v); CoTaskMemFree(name);
            }
            IEnumString_Release(names);
        }
        IWICMetadataQueryReader_Release(qr);
    }
    else if (verbose) printf("no metadata query reader\n");
    {
        BYTE pixels[8]; WICRect rc = {0, 0, 2, 1};
        if (SUCCEEDED(IWICBitmapFrameDecode_CopyPixels(frame, &rc, 8, 8, pixels)) && verbose)
            printf("pixels %02x%02x%02x%02x %02x%02x%02x%02x\n", pixels[0], pixels[1], pixels[2], pixels[3],
                   pixels[4], pixels[5], pixels[6], pixels[7]);
    }
    IWICBitmapFrameDecode_Release(frame);
out:
    IWICBitmapDecoder_Release(dec);
    return hr;
}

int main(int argc, char **argv)
{
    IWICImagingFactory *factory; IWICStream *stream; unsigned char buf[sizeof(png)];
    int n = argc > 1 ? atoi(argv[1]) : 1000; LARGE_INTEGER f, t0, t1; HRESULT hr;
    char env[8] = "";
    GetEnvironmentVariableA("MACSW_WIC_COMPONENT_CACHE", env, sizeof(env));
    memcpy(buf, png, sizeof(png));
    CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (FAILED(hr = CoCreateInstance(&CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER, &IID_IWICImagingFactory, (void **)&factory)))
    { printf("factory failed %08lx\n", hr); return 1; }
    list_components(factory, WICDecoder, "decoder");
    list_components(factory, WICEncoder, "encoder");
    list_components(factory, WICPixelFormatConverter, "converter");
    list_components(factory, WICMetadataReader, "metareader");
    IWICImagingFactory_CreateStream(factory, &stream);
    IWICStream_InitializeFromMemory(stream, buf, sizeof(buf));
    hr = decode_once(factory, stream, 1);
    printf("decode %08lx\n", hr);
    QueryPerformanceFrequency(&f); QueryPerformanceCounter(&t0);
    for (int i = 0; i < n; i++) if (FAILED(decode_once(factory, stream, 0))) { printf("loop decode failed at %d\n", i); break; }
    QueryPerformanceCounter(&t1);
    fprintf(stderr, "TIMING cache=%s decodes=%d total_ms=%.1f per_decode_us=%.1f\n", env[0] ? env : "unset", n,
            (t1.QuadPart - t0.QuadPart) * 1000.0 / f.QuadPart, (t1.QuadPart - t0.QuadPart) * 1e6 / f.QuadPart / n);
    IWICStream_Release(stream);
    IWICImagingFactory_Release(factory);
    CoUninitialize();
    return 0;
}
