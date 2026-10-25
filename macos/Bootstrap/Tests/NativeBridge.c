#include <windows.h>

__declspec(dllexport) HANDLE __cdecl bridge_cdecl(void *context)
{
    return CreateActCtxW((PCACTCTXW)context);
}

__declspec(dllexport) HANDLE __stdcall bridge_stdcall(void *context)
{
    return CreateActCtxW((PCACTCTXW)context);
}
