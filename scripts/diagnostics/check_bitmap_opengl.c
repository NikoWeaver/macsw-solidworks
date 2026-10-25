#include <windows.h>
#include <GL/gl.h>
#include <stdio.h>
#include <string.h>

/* Cross-compile with: x86_64-w64-mingw32-gcc -std=c99 -Wall -Wextra -Werror
 * check_bitmap_opengl.c -lopengl32 -lgdi32 -o check_bitmap_opengl.exe
 * No SOLIDWORKS, fixtures, user windows, or private installation is required. */
typedef void (APIENTRY *framebuffer_names)(GLsizei, GLuint *);
typedef void (APIENTRY *bind_framebuffer)(GLenum, GLuint);
typedef BOOL (WINAPI *get_pixel_format_attrib)(HDC, int, int, UINT, const int *, int *);
#define FRAMEBUFFER 0x8d40
#define FRAMEBUFFER_BINDING 0x8ca6
#define WGL_ACCELERATION_ARB 0x2003
#define WGL_NO_ACCELERATION_ARB 0x2025
#define WGL_FULL_ACCELERATION_ARB 0x2027

static void print_json_string(const char *value)
{
    putchar('"');
    for (const unsigned char *p = (const unsigned char *)(value ? value : ""); *p; ++p)
    {
        if (*p == '"' || *p == '\\') putchar('\\');
        if (*p < 32) printf("\\u%04x", *p);
        else putchar(*p);
    }
    putchar('"');
}

static int check_gl_color(int width, BYTE red, BYTE green, BYTE blue)
{
    BYTE pixels[64 * 4] = {0};
    glPushClientAttrib(GL_CLIENT_PIXEL_STORE_BIT);
    glPixelStorei(GL_PACK_ALIGNMENT, 4);
    glPixelStorei(GL_PACK_ROW_LENGTH, 0);
    glPixelStorei(GL_PACK_SKIP_PIXELS, 0);
    glPixelStorei(GL_PACK_SKIP_ROWS, 0);
    glReadPixels(0, 0, width, 8, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
    glPopClientAttrib();
    for (int i = 0; i < width * 8; ++i)
        if (pixels[i * 4] != red || pixels[i * 4 + 1] != green || pixels[i * 4 + 2] != blue) return 0;
    return glGetError() == GL_NO_ERROR;
}

static int run_case(int bpp, int width, int top_down)
{
    BITMAPINFO info = {0};
    PIXELFORMATDESCRIPTOR request = {0}, actual = {0};
    HDC dc = NULL;
    HBITMAP bitmap = NULL, previous = NULL;
    HGLRC context = NULL;
    HGLRC second_context = NULL;
    void *pixels = NULL;
    unsigned int red_pixels = 0;
    int format = 0, success = 0, result = 1;
    const char *stage = "create-dc";
    GLint draw_buffer = 0, binding = 0, depth = 0, stencil = 0;
    GLuint application_fbo = 0;
    int application_fbo_available = 0;
    int acceleration = 0;
    const int acceleration_attribute = WGL_ACCELERATION_ARB;
    const char *renderer = NULL, *version = NULL;
    framebuffer_names gen_fbos, delete_fbos;
    bind_framebuffer bind_fbo;
    get_pixel_format_attrib get_attrib;

    if (!(dc = CreateCompatibleDC(NULL))) goto done;
    info.bmiHeader.biSize = sizeof(info.bmiHeader);
    info.bmiHeader.biWidth = width;
    info.bmiHeader.biHeight = top_down ? -8 : 8;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = bpp;
    info.bmiHeader.biCompression = BI_RGB;
    stage = "create-dib";
    if (!(bitmap = CreateDIBSection(dc, &info, DIB_RGB_COLORS, (void **)&pixels, NULL, 0))) goto done;
    previous = SelectObject(dc, bitmap);
    for (int y = 0; y < 8; ++y)
        for (int x = 0; x < width; ++x) SetPixel(dc, x, y, RGB(0, 0, 255));

    request.nSize = sizeof(request);
    request.nVersion = 1;
    request.dwFlags = PFD_DRAW_TO_BITMAP | PFD_SUPPORT_GDI | PFD_SUPPORT_OPENGL;
    request.iPixelType = PFD_TYPE_RGBA;
    request.cColorBits = 24;
    request.cStencilBits = 8;
    /* SaveBMP prefers 32-bit depth; ChoosePixelFormat may provide 24-bit. */
    request.cDepthBits = 32;
    stage = "choose-pixel-format";
    if (!(format = ChoosePixelFormat(dc, &request))) goto done;
    stage = "describe-pixel-format";
    if (!DescribePixelFormat(dc, format, sizeof(actual), &actual)) goto done;
    if ((actual.dwFlags & request.dwFlags) != request.dwFlags || (actual.dwFlags & PFD_DOUBLEBUFFER)) goto done;
    stage = "set-pixel-format";
    if (!SetPixelFormat(dc, format, &actual)) goto done;
    stage = "create-context";
    if (!(context = wglCreateContext(dc))) goto done;
    stage = "make-current";
    if (!wglMakeCurrent(dc, context)) goto done;
    renderer = (const char *)glGetString(GL_RENDERER);
    version = (const char *)glGetString(GL_VERSION);
    stage = "acceleration-properties";
    if (!renderer || !version) goto done;
    get_attrib = (get_pixel_format_attrib)(void *)wglGetProcAddress("wglGetPixelFormatAttribivARB");
    if (!get_attrib || !get_attrib(dc, format, 0, 1, &acceleration_attribute, &acceleration)) goto done;
    if (acceleration != ((actual.dwFlags & PFD_GENERIC_FORMAT) ?
                        WGL_NO_ACCELERATION_ARB : WGL_FULL_ACCELERATION_ARB)) goto done;
    if (!strcmp(renderer, "Apple Software Renderer") &&
        (!(actual.dwFlags & PFD_GENERIC_FORMAT) || acceleration != WGL_NO_ACCELERATION_ARB)) goto done;
    stage = "initial-dib-upload";
    if (!check_gl_color(width, 0, 0, 255)) goto done;
    stage = "default-buffer-semantics";
    glGetIntegerv(GL_DRAW_BUFFER, &draw_buffer);
    glGetIntegerv(FRAMEBUFFER_BINDING, &binding);
    glGetIntegerv(GL_DEPTH_BITS, &depth);
    glGetIntegerv(GL_STENCIL_BITS, &stencil);
    if (draw_buffer != GL_FRONT || binding != 0 || depth < 24 || stencil < 8) goto done;
    glDrawBuffer(GL_FRONT_AND_BACK);
    glReadBuffer(GL_FRONT);
    stage = "clear-and-flush";
    glViewport(0, 0, width, 8);
    glClearColor(1.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glFinish();
    if (glGetError() != GL_NO_ERROR) goto done;
    stage = "read-dib";
    for (int y = 0; y < 8; ++y)
        for (int x = 0; x < width; ++x)
            if (GetPixel(dc, x, y) == RGB(255, 0, 0)) ++red_pixels;
    if (red_pixels != (unsigned int)width * 8) goto done;
    stage = "application-fbo-binding";
    /* Wine may hide application FBO extensions on a legacy context whose
     * share group differs from its core-profile internal context. Require all
     * semantics if advertised; do not assume an unadvertised API is available. */
    application_fbo_available = strstr((const char *)glGetString(GL_EXTENSIONS), "GL_EXT_framebuffer_object") != NULL;
    if (application_fbo_available)
    {
        gen_fbos = (framebuffer_names)(void *)wglGetProcAddress("glGenFramebuffersEXT");
        delete_fbos = (framebuffer_names)(void *)wglGetProcAddress("glDeleteFramebuffersEXT");
        bind_fbo = (bind_framebuffer)(void *)wglGetProcAddress("glBindFramebufferEXT");
        if (!gen_fbos || !delete_fbos || !bind_fbo) goto done;
        gen_fbos(1, &application_fbo);
        if (!application_fbo) goto done;
        bind_fbo(FRAMEBUFFER, application_fbo);
        stage = "application-fbo-query";
        glGetIntegerv(FRAMEBUFFER_BINDING, &binding);
        if ((GLuint)binding != application_fbo) goto done;
        bind_fbo(FRAMEBUFFER, 0);
        stage = "application-fbo-restore";
        delete_fbos(1, &application_fbo);
        if (!check_gl_color(width, 255, 0, 0)) goto done;
    }
    stage = "second-context";
    if (!(second_context = wglCreateContext(dc)) || !wglMakeCurrent(dc, second_context)) goto done;
    if (!check_gl_color(width, 255, 0, 0)) goto done;
    glClearColor(0, 1, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);
    glFinish();
    if (glGetError() != GL_NO_ERROR || GetPixel(dc, 0, 0) != RGB(0, 255, 0)) goto done;
    stage = "restore-context";
    if (!wglMakeCurrent(dc, context) || !check_gl_color(width, 0, 255, 0)) goto done;
    stage = "row-orientation-and-pack-state";
    glEnable(GL_SCISSOR_TEST);
    glScissor(0, 4, width, 4);
    glClearColor(1, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    glDisable(GL_SCISSOR_TEST);
    glPixelStorei(GL_PACK_ROW_LENGTH, width + 3);
    glPixelStorei(GL_PACK_SKIP_PIXELS, 2);
    glFinish();
    glGetIntegerv(GL_PACK_ROW_LENGTH, &binding);
    if (binding != width + 3 || GetPixel(dc, 0, 0) != RGB(255, 0, 0) ||
        GetPixel(dc, width - 1, 7) != RGB(0, 255, 0)) goto done;
    glGetIntegerv(GL_PACK_SKIP_PIXELS, &binding);
    if (binding != 2) goto done;
    stage = "complete";
    success = 1;
    result = 0;

done:
    printf("{\"success\":%s,\"stage\":\"%s\",\"bpp\":%d,\"width\":%d,\"top_down\":%s,\"format\":%d,\"flags\":%lu,\"red_pixels\":%u,\"expected_pixels\":%d,\"application_fbo_available\":%s,\"depth\":%d,\"stencil\":%d,\"gl_error\":%u,\"wgl_acceleration\":%d,\"renderer\":",
           success ? "true" : "false", stage, bpp, width, top_down ? "true" : "false", format, actual.dwFlags, red_pixels, width * 8,
           application_fbo_available ? "true" : "false", depth, stencil, glGetError(), acceleration);
    print_json_string(renderer);
    printf(",\"version\":");
    print_json_string(version);
    printf("}\n");
    if (context) { wglMakeCurrent(NULL, NULL); wglDeleteContext(context); }
    if (second_context) wglDeleteContext(second_context);
    if (previous) SelectObject(dc, previous);
    if (bitmap) DeleteObject(bitmap);
    if (dc) DeleteDC(dc);
    return result;
}

int main(void)
{
    int failures = 0;
    for (int bpp = 24; bpp <= 32; bpp += 8)
        for (int width = 7; width <= 8; ++width)
            for (int top_down = 0; top_down <= 1; ++top_down)
                failures += run_case(bpp, width, top_down);
    return failures ? 1 : 0;
}
