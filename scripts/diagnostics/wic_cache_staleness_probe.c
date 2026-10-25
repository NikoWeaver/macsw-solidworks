/* wic_cache_staleness_probe.c - registration and thread checks for patch 0032 (WIC component registry cache).
 *
 *   after    enumerate the decoders, then register a fake decoder (registry only, no DLL), enumerate again and
 *            start a new process ("list") that enumerates; then remove the fake decoder.
 *            Expected: without the cache both enumerations after the registration see it; with the cache the
 *            running process does not (the lists are read once per process), the new process does.
 *   before   register the fake decoder, enumerate (it is listed), read its ContainerFormat, remove it, enumerate,
 *            read ContainerFormat again and decode a PNG. Expected: without the cache the removed decoder is gone
 *            and its ContainerFormat read fails; with the cache it is still listed and returns the cached format;
 *            the PNG decode works in both.
 *   threads  8 threads start at once in a process that has not enumerated yet (so they race the first fill of
 *            the cache) and each does N x (enumerate decoders + metadata readers with their formats, decode a PNG
 *            with metadata). Prints one digest of the component lists; it must be the same in every thread and
 *            iteration, with and without the cache.
 * Registry writes go only to the prefix the probe runs in (HKCR\CLSID\{4D616353-5700-4661-6B65-000000000001}).
 * Build: x86_64-w64-mingw32-gcc -O2 -o wic_cache_staleness_probe.exe wic_cache_staleness_probe.c -lole32 -loleaut32 -luuid -ladvapi32
 *        i686-w64-mingw32-gcc -O2 -o wcs32.exe wic_cache_staleness_probe.c -lole32 -loleaut32 -luuid -ladvapi32 */
#define COBJMACROS
#include <windows.h>
#include <wincodec.h>
#include <wincodecsdk.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const GUID IID_IWICMetadataHandlerInfo_ = {0xaba958bf,0xc672,0x44d1,{0x8d,0x61,0xce,0x6d,0xf2,0xe6,0x82,0xc2}};
static const WCHAR fake_clsid[] = L"{4D616353-5700-4661-6B65-000000000001}";
static const WCHAR fake_format[] = L"{4D616353-5700-4661-6B65-0000000000F1}";
static const WCHAR decoder_instance[] = L"CLSID\\{7ED96837-96F0-4812-B211-F13C24117ED3}\\Instance";

/* 2x1 RGBA PNG with tEXt (Comment=MacSW) and gAMA chunks */
static const unsigned char png[] = {0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a,0x00,0x00,0x00,0x0d,0x49,0x48,0x44,0x52,0x00,0x00,0x00,0x02,0x00,0x00,0x00,0x01,0x08,0x06,0x00,0x00,0x00,0xf4,0x22,0x7f,0x8a,0x00,0x00,0x00,0x0d,0x74,0x45,0x58,0x74,0x43,0x6f,0x6d,0x6d,0x65,0x6e,0x74,0x00,0x4d,0x61,0x63,0x53,0x57,0x1b,0x3c,0x4c,0x98,0x00,0x00,0x00,0x04,0x67,0x41,0x4d,0x41,0x00,0x00,0xb1,0x8f,0x0b,0xfc,0x61,0x05,0x00,0x00,0x00,0x0e,0x49,0x44,0x41,0x54,0x78,0x9c,0x63,0xf8,0xcf,0xc0,0x00,0x42,0x0d,0x00,0x0f,0x7a,0x03,0x7e,0x77,0xe9,0x7f,0x97,0x00,0x00,0x00,0x00,0x49,0x45,0x4e,0x44,0xae,0x42,0x60,0x82};

static IWICImagingFactory *new_factory(void)
{
    IWICImagingFactory *factory = NULL; HRESULT hr;
    if (FAILED(hr = CoCreateInstance(&CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER, &IID_IWICImagingFactory,
                                     (void **)&factory)))
    { printf("factory failed %08lx\n", hr); exit(1); }
    return factory;
}

static LONG set_str(HKEY key, const WCHAR *name, const WCHAR *value)
{
    return RegSetValueExW(key, name, 0, REG_SZ, (const BYTE *)value, (wcslen(value) + 1) * sizeof(WCHAR));
}

static void register_fake(void)
{
    WCHAR path[128]; HKEY key; LONG r1, r2;
    swprintf(path, 128, L"CLSID\\%ls", fake_clsid);
    if (!(r1 = RegCreateKeyExW(HKEY_CLASSES_ROOT, path, 0, NULL, 0, KEY_ALL_ACCESS, NULL, &key, NULL)))
    {
        set_str(key, L"FriendlyName", L"MacSW fake decoder"); set_str(key, L"ContainerFormat", fake_format);
        RegCloseKey(key);
    }
    swprintf(path, 128, L"%ls\\%ls", decoder_instance, fake_clsid);
    if (!(r2 = RegCreateKeyExW(HKEY_CLASSES_ROOT, path, 0, NULL, 0, KEY_ALL_ACCESS, NULL, &key, NULL)))
    {
        set_str(key, L"CLSID", fake_clsid); set_str(key, L"FriendlyName", L"MacSW fake decoder");
        RegCloseKey(key);
    }
    printf("register fake decoder: %ld %ld\n", r1, r2);
}

static void unregister_fake(void)
{
    WCHAR path[128]; LONG r1, r2;
    swprintf(path, 128, L"%ls\\%ls", decoder_instance, fake_clsid);
    r2 = RegDeleteTreeW(HKEY_CLASSES_ROOT, path);
    swprintf(path, 128, L"CLSID\\%ls", fake_clsid);
    r1 = RegDeleteTreeW(HKEY_CLASSES_ROOT, path);
    printf("remove fake decoder: %ld %ld\n", r1, r2);
}

/* number of decoders; *fake = the fake decoder's info (AddRef'd) if listed */
static int count_decoders(IWICImagingFactory *factory, IWICBitmapDecoderInfo **fake)
{
    IEnumUnknown *e; IUnknown *u; ULONG n; int count = 0; HRESULT hr; CLSID want;
    CLSIDFromString(fake_clsid, &want);
    if (fake) *fake = NULL;
    if (FAILED(hr = IWICImagingFactory_CreateComponentEnumerator(factory, WICDecoder, WICComponentEnumerateDefault, &e)))
    { printf("enumerator failed %08lx\n", hr); return -1; }
    while (IEnumUnknown_Next(e, 1, &u, &n) == S_OK)
    {
        IWICBitmapDecoderInfo *info; CLSID clsid;
        if (SUCCEEDED(IUnknown_QueryInterface(u, &IID_IWICBitmapDecoderInfo, (void **)&info)))
        {
            IWICBitmapDecoderInfo_GetCLSID(info, &clsid);
            if (IsEqualCLSID(&clsid, &want) && fake) *fake = info;
            else IWICBitmapDecoderInfo_Release(info);
        }
        IUnknown_Release(u); count++;
    }
    IEnumUnknown_Release(e);
    return count;
}

static void report(IWICImagingFactory *factory, const char *when)
{
    IWICBitmapDecoderInfo *fake; int n = count_decoders(factory, &fake);
    printf("%s: decoders %d, fake decoder %s\n", when, n, fake ? "listed" : "not listed");
    if (fake) IWICBitmapDecoderInfo_Release(fake);
}

static void format_of(IWICBitmapDecoderInfo *info, const char *when)
{
    GUID fmt; WCHAR s[40] = L""; HRESULT hr = IWICBitmapDecoderInfo_GetContainerFormat(info, &fmt);
    if (SUCCEEDED(hr)) StringFromGUID2(&fmt, s, 40);
    printf("%s: fake ContainerFormat %08lx %ls\n", when, hr, s);
}

static HRESULT decode(IWICImagingFactory *factory, IWICStream *stream, DWORD *pixel)
{
    IWICBitmapDecoder *dec; IWICBitmapFrameDecode *frame; IWICMetadataQueryReader *qr; LARGE_INTEGER zero = {{0}};
    BYTE pixels[8]; WICRect rc = {0, 0, 2, 1}; HRESULT hr;
    IWICStream_Seek(stream, zero, STREAM_SEEK_SET, NULL);
    if (FAILED(hr = IWICImagingFactory_CreateDecoderFromStream(factory, (IStream *)stream, NULL,
                                                               WICDecodeMetadataCacheOnDemand, &dec))) return hr;
    if (SUCCEEDED(hr = IWICBitmapDecoder_GetFrame(dec, 0, &frame)))
    {
        if (SUCCEEDED(IWICBitmapFrameDecode_GetMetadataQueryReader(frame, &qr)))
        {
            PROPVARIANT v; PropVariantInit(&v);
            hr = IWICMetadataQueryReader_GetMetadataByName(qr, L"/tEXt/{str=Comment}", &v);
            PropVariantClear(&v); IWICMetadataQueryReader_Release(qr);
        }
        else hr = E_FAIL;
        if (SUCCEEDED(hr)) hr = IWICBitmapFrameDecode_CopyPixels(frame, &rc, 8, 8, pixels);
        if (SUCCEEDED(hr) && pixel) memcpy(pixel, pixels, 4);
        IWICBitmapFrameDecode_Release(frame);
    }
    IWICBitmapDecoder_Release(dec);
    return hr;
}

static IWICStream *png_stream(IWICImagingFactory *factory, BYTE *buf)
{
    IWICStream *stream;
    memcpy(buf, png, sizeof(png));
    IWICImagingFactory_CreateStream(factory, &stream);
    IWICStream_InitializeFromMemory(stream, buf, sizeof(png));
    return stream;
}

static void run_child(const char *mode)
{
    STARTUPINFOA si = {sizeof(si)}; PROCESS_INFORMATION pi; char exe[MAX_PATH], cmd[MAX_PATH + 16];
    GetModuleFileNameA(NULL, exe, MAX_PATH);
    snprintf(cmd, sizeof(cmd), "\"%s\" %s", exe, mode);
    fflush(stdout);
    if (!CreateProcessA(NULL, cmd, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) { printf("child failed\n"); return; }
    WaitForSingleObject(pi.hProcess, 60000); CloseHandle(pi.hProcess); CloseHandle(pi.hThread);
}

/* ---- threads ---- */
static HANDLE go;
static int iterations = 300;
static volatile LONG mismatches, decode_failures;
static DWORD digests[8];

static void hash(DWORD *h, const void *p, size_t n)
{
    const BYTE *b = p;
    while (n--) { *h ^= *b++; *h *= 16777619u; }
}

static DWORD digest_components(IWICImagingFactory *factory)
{
    static const DWORD types[] = {WICDecoder, WICMetadataReader, WICPixelFormatConverter};
    DWORD h = 2166136261u; unsigned int t;
    for (t = 0; t < 3; t++)
    {
        IEnumUnknown *e; IUnknown *u; ULONG n;
        if (FAILED(IWICImagingFactory_CreateComponentEnumerator(factory, types[t], WICComponentEnumerateDefault, &e)))
        { hash(&h, "fail", 4); continue; }
        while (IEnumUnknown_Next(e, 1, &u, &n) == S_OK)
        {
            IWICComponentInfo *info; IWICBitmapDecoderInfo *dec; IWICMetadataHandlerInfo *mh; CLSID clsid; GUID fmt;
            if (SUCCEEDED(IUnknown_QueryInterface(u, &IID_IWICComponentInfo, (void **)&info)))
            {
                IWICComponentInfo_GetCLSID(info, &clsid); hash(&h, &clsid, sizeof(clsid));
                if (SUCCEEDED(IWICComponentInfo_QueryInterface(info, &IID_IWICBitmapDecoderInfo, (void **)&dec)))
                {
                    memset(&fmt, 0, sizeof(fmt)); IWICBitmapDecoderInfo_GetContainerFormat(dec, &fmt);
                    hash(&h, &fmt, sizeof(fmt));
                    memset(&fmt, 0, sizeof(fmt)); IWICBitmapDecoderInfo_GetVendorGUID(dec, &fmt);
                    hash(&h, &fmt, sizeof(fmt));
                    IWICBitmapDecoderInfo_Release(dec);
                }
                if (SUCCEEDED(IWICComponentInfo_QueryInterface(info, &IID_IWICMetadataHandlerInfo_, (void **)&mh)))
                {
                    memset(&fmt, 0, sizeof(fmt)); IWICMetadataHandlerInfo_GetMetadataFormat(mh, &fmt);
                    hash(&h, &fmt, sizeof(fmt));
                    IWICMetadataHandlerInfo_Release(mh);
                }
                IWICComponentInfo_Release(info);
            }
            IUnknown_Release(u);
        }
        IEnumUnknown_Release(e);
    }
    return h;
}

static DWORD WINAPI worker(void *arg)
{
    int id = (int)(INT_PTR)arg, i; IWICImagingFactory *factory; IWICStream *stream; BYTE buf[sizeof(png)];
    DWORD d, pixel;
    CoInitializeEx(NULL, COINIT_MULTITHREADED);
    factory = new_factory(); stream = png_stream(factory, buf);
    WaitForSingleObject(go, INFINITE);
    for (i = 0; i < iterations; i++)
    {
        d = digest_components(factory);
        if (!i) digests[id] = d; else if (d != digests[id]) InterlockedIncrement(&mismatches);
        pixel = 0;
        if (FAILED(decode(factory, stream, &pixel)) || pixel == 0) InterlockedIncrement(&decode_failures);
    }
    IWICStream_Release(stream); IWICImagingFactory_Release(factory);
    CoUninitialize();
    return 0;
}

int main(int argc, char **argv)
{
    const char *mode = argc > 1 ? argv[1] : "threads"; char env[8] = "";
    IWICImagingFactory *factory; IWICStream *stream; IWICBitmapDecoderInfo *fake; BYTE buf[sizeof(png)];
    GetEnvironmentVariableA("MACSW_WIC_COMPONENT_CACHE", env, sizeof(env));
    CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (!strcmp(mode, "list"))
    {
        report(new_factory(), "  new process");
        return 0;
    }
    printf("probe %s mode %s\n", sizeof(void *) == 8 ? "x86_64" : "i386", mode);
    if (!strcmp(mode, "after"))
    {
        factory = new_factory();
        report(factory, "before registration");
        register_fake();
        report(factory, "after registration, same process");
        run_child("list");
        unregister_fake();
        report(factory, "after removal, same process");
    }
    else if (!strcmp(mode, "before"))
    {
        DWORD pixel = 0; HRESULT hr;
        register_fake();
        factory = new_factory();
        count_decoders(factory, &fake);
        printf("first enumeration: fake decoder %s\n", fake ? "listed" : "not listed");
        if (fake) { format_of(fake, "registered"); IWICBitmapDecoderInfo_Release(fake); }
        unregister_fake();
        count_decoders(factory, &fake);
        printf("after removal: fake decoder %s\n", fake ? "listed" : "not listed");
        if (fake) { format_of(fake, "removed"); IWICBitmapDecoderInfo_Release(fake); }
        stream = png_stream(factory, buf);
        hr = decode(factory, stream, &pixel);
        printf("after removal: PNG decode %08lx pixel %08lx\n", hr, pixel);
    }
    else
    {
        HANDLE threads[8]; int i, consistent = 1; LARGE_INTEGER f, t0, t1;
        if (argc > 2) iterations = atoi(argv[2]);
        go = CreateEventA(NULL, TRUE, FALSE, NULL);
        for (i = 0; i < 8; i++) threads[i] = CreateThread(NULL, 0, worker, (void *)(INT_PTR)i, 0, NULL);
        Sleep(300);
        QueryPerformanceFrequency(&f); QueryPerformanceCounter(&t0);
        SetEvent(go);
        WaitForMultipleObjects(8, threads, TRUE, INFINITE);
        QueryPerformanceCounter(&t1);
        for (i = 1; i < 8; i++) if (digests[i] != digests[0]) consistent = 0;
        printf("threads 8 x %d: digest %08lx, same in all threads %d, changed between iterations %ld, decode failures %ld\n",
               iterations, digests[0], consistent, mismatches, decode_failures);
        fprintf(stderr, "TIMING cache=%s threads=8 iterations=%d total_ms=%.1f\n", env[0] ? env : "unset", iterations,
                (t1.QuadPart - t0.QuadPart) * 1000.0 / f.QuadPart);
    }
    return 0;
}
