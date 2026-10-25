#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <GL/gl.h>
#include <stdio.h>

#define PANEL_WIDTH 220
#define HEADER_HEIGHT 64

static HWND main_window, gl_window, left_panel, right_panel, header;
static HDC gl_dc;
static HGLRC gl_context;
static int show_right_panel = 1;
static int show_header = 1;

static void print_gl_region(void)
{
    HRGN region = CreateRectRgn(0, 0, 0, 0);
    RECT box;
    int result = GetRandomRgn(gl_dc, region, SYSRGN);
    int kind = GetRgnBox(region, &box);

    printf("SYSRGN result=%d kind=%d box=(%ld,%ld)-(%ld,%ld)\n",
           result, kind, box.left, box.top, box.right, box.bottom);
    fflush(stdout);
    DeleteObject(region);
}

static void layout(void)
{
    RECT rect;
    int width, height;

    GetClientRect(main_window, &rect);
    width = rect.right - rect.left;
    height = rect.bottom - rect.top;

    /* The GL HWND covers the whole client area. Higher siblings must obscure it. */
    SetWindowPos(gl_window, HWND_BOTTOM, 0, 0, width, height, SWP_NOACTIVATE);
    SetWindowPos(left_panel, HWND_TOP, 0, HEADER_HEIGHT, PANEL_WIDTH,
                 height - HEADER_HEIGHT, SWP_NOACTIVATE);
    SetWindowPos(right_panel, HWND_TOP, width - PANEL_WIDTH, HEADER_HEIGHT,
                 PANEL_WIDTH, height - HEADER_HEIGHT, SWP_NOACTIVATE);
    SetWindowPos(header, HWND_TOP, 0, 0, width, HEADER_HEIGHT, SWP_NOACTIVATE);
    ShowWindow(right_panel, show_right_panel ? SW_SHOW : SW_HIDE);
    ShowWindow(header, show_header ? SW_SHOW : SW_HIDE);
    if (gl_dc) print_gl_region();
}

static void draw(void)
{
    RECT rect;
    float width, height;

    if (!gl_context) return;
    GetClientRect(gl_window, &rect);
    width = (float)(rect.right - rect.left);
    height = (float)(rect.bottom - rect.top);
    if (width < 1 || height < 1) return;

    wglMakeCurrent(gl_dc, gl_context);
    glViewport(0, 0, (GLsizei)width, (GLsizei)height);
    glClearColor(0.12f, 0.38f, 0.75f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glBegin(GL_TRIANGLES);
    glColor3f(1.0f, 0.9f, 0.1f);
    glVertex2f(-0.8f, -0.6f);
    glColor3f(0.9f, 0.1f, 0.1f);
    glVertex2f(0.8f, -0.6f);
    glColor3f(0.1f, 0.9f, 0.2f);
    glVertex2f(0.0f, 0.8f);
    glEnd();
    SwapBuffers(gl_dc);
}

static LRESULT CALLBACK gl_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    if (msg == WM_ERASEBKGND) return 1;
    return DefWindowProcA(hwnd, msg, wp, lp);
}

static LRESULT CALLBACK panel_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    if (msg == WM_PAINT)
    {
        PAINTSTRUCT ps;
        RECT rect;
        HDC dc = BeginPaint(hwnd, &ps);
        HBRUSH brush = CreateSolidBrush(hwnd == left_panel ? RGB(235, 170, 65) :
                                      hwnd == right_panel ? RGB(80, 180, 110) :
                                      RGB(210, 210, 220));
        GetClientRect(hwnd, &rect);
        FillRect(dc, &rect, brush);
        SetBkMode(dc, TRANSPARENT);
        DrawTextA(dc, hwnd == left_panel ? "Left sibling" :
                  hwnd == right_panel ? "Right sibling" : "Header sibling",
                  -1, &rect, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        DeleteObject(brush);
        EndPaint(hwnd, &ps);
        return 0;
    }
    return DefWindowProcA(hwnd, msg, wp, lp);
}

static LRESULT CALLBACK main_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    switch (msg)
    {
    case WM_SIZE:
        if (gl_window) layout();
        return 0;
    case WM_KEYDOWN:
        if (wp == 'R') show_right_panel = !show_right_panel;
        else if (wp == 'H') show_header = !show_header;
        else if (wp == 'P') print_gl_region();
        else break;
        layout();
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcA(hwnd, msg, wp, lp);
}

int main(void)
{
    HINSTANCE instance = GetModuleHandleA(NULL);
    WNDCLASSA cls = {0};
    PIXELFORMATDESCRIPTOR pfd = {0};
    MSG msg;
    int pixel_format;

    cls.hInstance = instance;
    cls.hCursor = LoadCursor(NULL, IDC_ARROW);
    cls.lpfnWndProc = main_proc;
    cls.lpszClassName = "ClipReproMain";
    RegisterClassA(&cls);
    cls.lpfnWndProc = gl_proc;
    cls.lpszClassName = "ClipReproGL";
    cls.style = CS_OWNDC;
    RegisterClassA(&cls);
    cls.lpfnWndProc = panel_proc;
    cls.lpszClassName = "ClipReproPanel";
    cls.style = 0;
    RegisterClassA(&cls);

    main_window = CreateWindowA("ClipReproMain", "Wine macOS OpenGL child clipping",
                                WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN,
                                CW_USEDEFAULT, CW_USEDEFAULT, 960, 680,
                                NULL, NULL, instance, NULL);
    gl_window = CreateWindowA("ClipReproGL", "", WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS,
                              0, 0, 960, 680, main_window, NULL, instance, NULL);
    left_panel = CreateWindowA("ClipReproPanel", "", WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS,
                               0, 0, 1, 1, main_window, NULL, instance, NULL);
    right_panel = CreateWindowA("ClipReproPanel", "", WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS,
                                0, 0, 1, 1, main_window, NULL, instance, NULL);
    header = CreateWindowA("ClipReproPanel", "", WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS,
                           0, 0, 1, 1, main_window, NULL, instance, NULL);
    if (!main_window || !gl_window || !left_panel || !right_panel || !header) return 1;

    gl_dc = GetDC(gl_window);
    pfd.nSize = sizeof(pfd);
    pfd.nVersion = 1;
    pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
    pfd.iPixelType = PFD_TYPE_RGBA;
    pfd.cColorBits = 24;
    pfd.cDepthBits = 16;
    pfd.iLayerType = PFD_MAIN_PLANE;
    pixel_format = ChoosePixelFormat(gl_dc, &pfd);
    if (!pixel_format || !SetPixelFormat(gl_dc, pixel_format, &pfd)) return 2;
    gl_context = wglCreateContext(gl_dc);
    if (!gl_context) return 3;
    layout();
    ShowWindow(main_window, SW_SHOW);
    UpdateWindow(main_window);
    SetTimer(main_window, 1, 33, NULL);
    printf("R: right panel; H: header; P: print SYSRGN\n");
    fflush(stdout);

    while (GetMessageA(&msg, NULL, 0, 0) > 0)
    {
        TranslateMessage(&msg);
        DispatchMessageA(&msg);
        if (msg.message == WM_TIMER) draw();
    }
    wglMakeCurrent(NULL, NULL);
    wglDeleteContext(gl_context);
    ReleaseDC(gl_window, gl_dc);
    return 0;
}
