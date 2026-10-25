#define UNICODE
#define _UNICODE
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned checks, failures;
static const COLORREF colors[4]={RGB(210,30,45),RGB(40,180,60),RGB(35,70,220),RGB(245,210,25)};
static LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM wp, LPARAM lp)
{
    if (message == WM_PAINT) {
        PAINTSTRUCT paint;
        RECT rect;
        HDC dc=BeginPaint(window,&paint);
        for (int i=0;i<4;i++) {
            HBRUSH brush=CreateSolidBrush(colors[i]);
            SetRect(&rect,(i%2)*128,(i/2)*128,(i%2+1)*128,(i/2+1)*128);
            FillRect(dc,&rect,brush);
            DeleteObject(brush);
        }
        EndPaint(window,&paint);
        return 0;
    }
    return DefWindowProcW(window,message,wp,lp);
}
static void expect(const char *name, DWORD actual, DWORD expected)
{
    checks++;
    if (actual != expected) { printf("FAIL %s got=%08lx expected=%08lx\n",name,actual,expected); failures++; }
}
static void expect_color(const char *name, COLORREF actual, COLORREF expected)
{
    /* Compositor color management can round channels by a few levels. */
    int red=(int)GetRValue(actual)-(int)GetRValue(expected);
    int green=(int)GetGValue(actual)-(int)GetGValue(expected);
    int blue=(int)GetBValue(actual)-(int)GetBValue(expected);
    expect(name, actual != CLR_INVALID && abs(red)<=3 && abs(green)<=3 && abs(blue)<=3, TRUE);
}
int main(int argc, char **argv)
{
    setvbuf(stdout,NULL,_IONBF,0);
    HWND window;
    HDC dc, screen, memory;
    HBITMAP bitmap, old;
    POINT origin={0,0}, extent={256,256}, samples[4], subrect={145,145};
    int width, height;
    MSG message;
    DWORD end;
    WNDCLASSW cls={0};
    if (argc > 2 || (argc == 2 && strcmp(argv[1], "--unaware"))) return 2;
    if (argc == 1) SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    cls.lpfnWndProc=window_proc;
    cls.hInstance=GetModuleHandleW(NULL);
    cls.lpszClassName=L"ScreenReadbackProbe";
    RegisterClassW(&cls);
    window=CreateWindowExW(WS_EX_TOPMOST,cls.lpszClassName,L"Screen readback regression",WS_POPUP|WS_VISIBLE,
                          560,360,256,256,NULL,NULL,NULL,NULL);
    if (!window) return 2;
    dc=GetDC(window);
    UpdateWindow(window);
    GdiFlush();
    end=GetTickCount()+1200;
    while ((LONG)(end-GetTickCount())>0) {
        while (PeekMessageW(&message,NULL,0,0,PM_REMOVE)) DispatchMessageW(&message);
        Sleep(10);
    }
    ClientToScreen(window,&origin);
    ClientToScreen(window,&extent);
    for (int i=0;i<4;i++) {
        samples[i].x=origin.x+32+(i%2)*128;
        samples[i].y=origin.y+32+(i/2)*128;
        LogicalToPhysicalPointForPerMonitorDPI(window,&samples[i]);
    }
    subrect.x+=origin.x;
    subrect.y+=origin.y;
    LogicalToPhysicalPointForPerMonitorDPI(window,&subrect);
    /* Desktop DC coordinates are physical even for a DPI-unaware process. */
    LogicalToPhysicalPointForPerMonitorDPI(window,&origin);
    LogicalToPhysicalPointForPerMonitorDPI(window,&extent);
    width=extent.x-origin.x;
    height=extent.y-origin.y;
    screen=GetDC(NULL);
    memory=CreateCompatibleDC(screen);
    bitmap=CreateCompatibleBitmap(screen,width+44,height+44);
    old=SelectObject(memory,bitmap);
    printf("dpi=%u origin=%ld,%ld\n",GetDpiForWindow(window),origin.x,origin.y);
    expect("memory/window BitBlt",BitBlt(memory,0,0,256,256,dc,0,0,SRCCOPY),TRUE);
    for (int i=0;i<4;i++) expect("window pixel",GetPixel(memory,32+(i%2)*128,32+(i/2)*128),colors[i]);
    expect("screen BitBlt",BitBlt(memory,0,0,width,height,screen,origin.x,origin.y,SRCCOPY),TRUE);
    for (int i=0;i<4;i++) {
        expect_color("screen capture pixel",GetPixel(memory,samples[i].x-origin.x,samples[i].y-origin.y),colors[i]);
        expect_color("screen GetPixel",GetPixel(screen,samples[i].x,samples[i].y),colors[i]);
    }
    expect("screen subrect BitBlt",BitBlt(memory,7,11,64,64,screen,subrect.x,subrect.y,SRCCOPY),TRUE);
    expect_color("screen subrect pixel",GetPixel(memory,10,15),colors[3]);
    SelectObject(memory,old);
    DeleteObject(bitmap);
    DeleteDC(memory);
    ReleaseDC(NULL,screen);
    ReleaseDC(window,dc);
    DestroyWindow(window);
    printf("screen readback: %u checks, %u failures\n",checks,failures);
    return failures ? 1 : 0;
}
