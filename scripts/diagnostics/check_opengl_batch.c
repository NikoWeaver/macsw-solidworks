/* check_opengl_batch.exe [frames] [out.bmp]
 * Correctness and timing probe for patch 0030 (opengl32 batches immediate-mode calls).
 * Run it once with MACSW_GL_BATCH=0 and once without: every "query" line must be the same, only the
 * "time" line may differ. No SOLIDWORKS, fixtures or user windows are needed.
 *
 * Cross-compile with: x86_64-w64-mingw32-gcc -std=c99 -O2 -Wall -Wextra check_opengl_batch.c
 *   -lopengl32 -lgdi32 -o check_opengl_batch.exe
 *
 * It draws immediate-mode geometry with every batched call (glBegin/glEnd, glVertex2f/2fv/3f/3fv/3d/3dv,
 * glNormal3f/3fv/3d/3dv, glColor3f/3fv/4f/4fv, glTexCoord2f/2fv/2d) mixed with calls that are not
 * batched, and checks that each of these sees all earlier recorded calls:
 *   - glGetError (an error made by a recorded call, in order), glGetFloatv of the current color,
 *     normal and texture coordinate, glIsEnabled;
 *   - a display list compiled from recorded calls (glNewList/glEndList, glCallList);
 *   - selection (glSelectBuffer/glRenderMode(GL_SELECT)) and feedback (glFeedbackBuffer) results;
 *   - glReadPixels of the frame (FNV-1a hash) and glFinish;
 *   - a second thread that records calls into its own context and only calls wglMakeCurrent(NULL)
 *     before it exits; the main thread then reads that context's frame back;
 *   - a second context on the same thread (wglMakeCurrent switch between two windows).
 * Then it times a SOLIDWORKS-like frame: 10,000 strips of 30 glNormal3fv+glVertex3fv pairs. */
#include <windows.h>
#include <GL/gl.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>

#define W 256
#define H 256

static PIXELFORMATDESCRIPTOR pfd = { sizeof(PIXELFORMATDESCRIPTOR), 1, PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER,
                                     PFD_TYPE_RGBA, 32, 0,0,0,0,0,0, 8, 0, 0,0,0,0,0, 24, 8, 0, PFD_MAIN_PLANE, 0, 0,0,0 };

static double now(void) { LARGE_INTEGER f, c; QueryPerformanceFrequency(&f); QueryPerformanceCounter(&c); return (double)c.QuadPart / f.QuadPart; }

static HWND make_window(int x)
{
    HWND hw = CreateWindowA("check_opengl_batch", "check_opengl_batch", WS_POPUP | WS_VISIBLE, x, 40, W, H, NULL, NULL,
                            GetModuleHandleA(NULL), NULL);
    HDC dc = GetDC(hw);
    if (!SetPixelFormat(dc, ChoosePixelFormat(dc, &pfd), &pfd)) { printf("pixelformat_fail\n"); exit(2); }
    ReleaseDC(hw, dc);
    return hw;
}

static unsigned int frame_hash(void)
{
    static unsigned char px[W * H * 4];
    unsigned int hash = 2166136261u;
    int i;
    glReadBuffer(GL_BACK); glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, px);
    for (i = 0; i < W * H * 4; i++) { hash ^= px[i]; hash *= 16777619u; }
    return hash;
}

static void setup_view(void)
{
    glViewport(0, 0, W, H); glMatrixMode(GL_PROJECTION); glLoadIdentity(); glOrtho(-1, 1, -1, 1, -2, 2);
    glMatrixMode(GL_MODELVIEW); glLoadIdentity();
}

static void triangle(float r, float g, float b)
{
    glBegin(GL_TRIANGLES); glColor3f(r, g, b); glVertex2f(-0.8f, -0.8f); glVertex2f(0.8f, -0.8f); glVertex2f(0, 0.8f); glEnd();
}

static void scene(GLuint list, GLuint tex)
{
    float v[3], n[3], c[4];
    int i;

    glClearColor(0.2f, 0.2f, 0.25f, 1); glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    glEnable(GL_DEPTH_TEST);
    glEnable(GL_LIGHTING); glEnable(GL_LIGHT0); glEnable(GL_COLOR_MATERIAL);
    glBegin(GL_TRIANGLE_FAN);
    glNormal3f(0, 0, 1); glColor3f(1, 0.5f, 0); glVertex3f(-0.5f, -0.5f, 0);
    for (i = 0; i <= 24; i++)
    {
        double a = i * 3.14159265 / 48;
        n[0] = (float)cos(a) * 0.3f; n[1] = (float)sin(a) * 0.3f; n[2] = 0.9f;
        c[0] = (float)i / 24; c[1] = 1 - c[0]; c[2] = 0.5f;
        v[0] = -0.5f + (float)cos(a) * 0.9f; v[1] = -0.5f + (float)sin(a) * 0.9f; v[2] = 0;
        glNormal3fv(n); glColor3fv(c); glVertex3fv(v);
    }
    glEnd();
    { static const float spec[4] = { 1, 1, 1, 1 }; glMaterialfv(GL_FRONT, GL_SPECULAR, spec); glMaterialf(GL_FRONT, GL_SHININESS, 20); }
    glBegin(GL_QUADS);
    { static const double nd[3] = { 0, 0.2, 0.98 }, vd[3] = { 0.9, 0.1, -0.1 };
      glNormal3d(0.1, 0, 0.99); glVertex3d(0.1, 0.1, -0.1); glVertex3d(0.5, 0.1, -0.1);
      glNormal3dv(nd); glVertex3dv(vd); glVertex3d(0.1, 0.6, -0.1); }
    glEnd();
    glDisable(GL_LIGHTING);
    glBegin(GL_LINES);
    for (i = 0; i < 40; i++)
    {
        c[0] = 1; c[1] = (float)i / 40; c[2] = 0; c[3] = 1;
        if (i & 1) glColor4fv(c); else glColor4f(0, 1, (float)i / 40, 1);
        glVertex2f(-0.95f + i * 0.045f, 0.7f); glVertex2f(-0.9f + i * 0.045f, 0.95f);
    }
    glEnd();
    glEnable(GL_TEXTURE_2D); glBindTexture(GL_TEXTURE_2D, tex); glColor3f(1, 1, 1);
    glBegin(GL_QUADS);
    { static const float t2[2] = { 1, 1 }, v2[2] = { -0.1f, -0.1f };
      glTexCoord2f(0, 0); glVertex2f(-0.6f, -0.95f); glTexCoord2d(1, 0); glVertex2f(-0.1f, -0.95f);
      glTexCoord2fv(t2); glVertex2fv(v2); glTexCoord2f(0, 1); glVertex2f(-0.6f, -0.1f); }
    glEnd();
    glDisable(GL_TEXTURE_2D);
    glPushMatrix(); glTranslatef(0.3f, -0.6f, 0); glCallList(list); glPopMatrix();
    glFinish();
}

struct thread_args { HWND hw; HGLRC rc; };

static DWORD WINAPI thread_draw(void *param)
{
    struct thread_args *args = param;
    HDC dc = GetDC(args->hw);
    if (!wglMakeCurrent(dc, args->rc)) { printf("query thread_make_current=fail\n"); return 1; }
    setup_view();
    glClearColor(0, 0, 0, 1); glClear(GL_COLOR_BUFFER_BIT);
    triangle(0.1f, 0.9f, 0.3f);      /* recorded; no glFlush/glFinish */
    wglMakeCurrent(NULL, NULL);      /* the context switch must replay it */
    ReleaseDC(args->hw, dc);
    return 0;
}

int main(int argc, char **argv)
{
    int frames = argc > 1 ? atoi(argv[1]) : 20, i, j, f;
    WNDCLASSA wc = {0}; HWND hw, hw2; HDC dc, dc2; HGLRC rc, rc2; GLuint list, tex; GLenum err;
    static unsigned char texels[8 * 8 * 4];
    float cur[4];
    double t0, t;
    const char *batch = getenv("MACSW_GL_BATCH");

    wc.style = CS_OWNDC; wc.lpfnWndProc = DefWindowProcA; wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "check_opengl_batch"; RegisterClassA(&wc);
    hw = make_window(40); hw2 = make_window(40 + W + 20);
    dc = GetDC(hw); dc2 = GetDC(hw2);
    if (!(rc = wglCreateContext(dc)) || !(rc2 = wglCreateContext(dc2)) || !wglMakeCurrent(dc, rc)) { printf("context_fail\n"); return 3; }
    printf("MACSW_GL_BATCH=%s renderer=\"%s\"\n", batch ? batch : "(unset)", (const char *)glGetString(GL_RENDERER));
    setup_view();
    for (i = 0; i < 64; i++) { texels[i * 4] = (i & 1) ? 255 : 0; texels[i * 4 + 1] = (i & 8) ? 255 : 40; texels[i * 4 + 2] = 128; texels[i * 4 + 3] = 255; }
    glGenTextures(1, &tex); glBindTexture(GL_TEXTURE_2D, tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 8, 8, 0, GL_RGBA, GL_UNSIGNED_BYTE, texels);

    /* display list compiled from recorded calls */
    list = glGenLists(1);
    glNewList(list, GL_COMPILE);
    glBegin(GL_TRIANGLES); glColor3f(0, 0.8f, 1); glVertex3f(0, 0, 0.5f); glVertex3f(0.4f, 0, 0.5f); glColor3f(1, 0, 1); glVertex3f(0.2f, 0.35f, 0.5f); glEnd();
    glEndList();
    printf("query list_compiled=%d\n", glIsList(list));

    /* errors made by recorded calls are reported by the next glGetError, in order */
    while (glGetError()) ;
    glBegin(GL_POINTS); glVertex2f(0, 0); glBegin(GL_POINTS); glEnd();
    err = glGetError(); printf("query nested_begin_error=0x%04x\n", err);
    err = glGetError(); printf("query second_error=0x%04x\n", err);
    glEnd();                                     /* glEnd without glBegin */
    err = glGetError(); printf("query end_without_begin_error=0x%04x\n", err);
    glBegin(0x1234);                             /* invalid primitive mode */
    err = glGetError(); printf("query invalid_mode_error=0x%04x\n", err);
    glBegin(GL_LINES); err = glGetError(); glEnd();  /* glGetError between glBegin and glEnd is itself an error */
    printf("query geterror_inside_begin=0x%04x after_end=0x%04x\n", err, glGetError());

    /* current state after recorded calls */
    glColor4f(0.25f, 0.5f, 0.75f, 1.0f); glGetFloatv(GL_CURRENT_COLOR, cur);
    printf("query current_color=%.3f,%.3f,%.3f,%.3f\n", cur[0], cur[1], cur[2], cur[3]);
    glNormal3f(0.0f, 0.6f, 0.8f); glGetFloatv(GL_CURRENT_NORMAL, cur);
    printf("query current_normal=%.3f,%.3f,%.3f\n", cur[0], cur[1], cur[2]);
    glTexCoord2f(0.125f, 0.875f); glGetFloatv(GL_CURRENT_TEXTURE_COORDS, cur);
    printf("query current_texcoord=%.3f,%.3f\n", cur[0], cur[1]);
    glEnable(GL_CULL_FACE); printf("query is_enabled_cull=%d\n", glIsEnabled(GL_CULL_FACE)); glDisable(GL_CULL_FACE);

    /* selection: hits are counted from recorded geometry when glRenderMode returns */
    {
        GLuint sel[64]; GLint hits;
        glSelectBuffer(64, sel); glRenderMode(GL_SELECT); glInitNames(); glPushName(7);
        triangle(1, 1, 1);
        glLoadName(8);
        glBegin(GL_QUADS); glVertex2f(3, 3); glVertex2f(4, 3); glVertex2f(4, 4); glVertex2f(3, 4); glEnd();  /* outside the view */
        glLoadName(9);
        glBegin(GL_POINTS); glVertex3d(0.1, 0.1, 0.0); glEnd();
        hits = glRenderMode(GL_RENDER);
        printf("query select_hits=%d", hits);
        for (i = 0, j = 0; i < hits && j < 60; i++) { printf(" [n=%u name=%u]", sel[j], sel[j + 3]); j += 3 + sel[j]; }
        printf("\n");
    }
    /* feedback: the transformed vertices of recorded calls */
    {
        GLfloat fb[64]; GLint n;
        glFeedbackBuffer(64, GL_2D, fb); glRenderMode(GL_FEEDBACK);
        glBegin(GL_POINTS); glVertex2f(0.5f, -0.5f); glVertex2fv((const GLfloat[]){ -0.25f, 0.75f }); glEnd();
        n = glRenderMode(GL_RENDER);
        printf("query feedback_values=%d", n);
        for (i = 0; i < n && i < 64; i++) printf(" %.1f", fb[i]);
        printf("\n");
    }

    scene(list, tex);
    printf("query image_fnv1a=%08x error_after_scene=0x%04x\n", frame_hash(), glGetError());
    if (argc > 2)  /* optional 32-bit BMP of the read-back frame */
    {
        static unsigned char px[W * H * 4];
        BITMAPFILEHEADER bf = { 0x4d42, sizeof(bf) + sizeof(BITMAPINFOHEADER) + W * H * 4, 0, 0, sizeof(bf) + sizeof(BITMAPINFOHEADER) };
        BITMAPINFOHEADER bi = { sizeof(bi), W, H, 1, 32, BI_RGB, 0, 0, 0, 0, 0 };
        FILE *out = fopen(argv[2], "wb");
        glReadPixels(0, 0, W, H, GL_BGRA_EXT, GL_UNSIGNED_BYTE, px);
        if (out) { fwrite(&bf, sizeof(bf), 1, out); fwrite(&bi, sizeof(bi), 1, out); fwrite(px, 1, W * H * 4, out); fclose(out); }
    }
    SwapBuffers(dc);

    /* a second context on the same thread: recorded calls stay with the context they were made in */
    glClearColor(0, 0, 0, 1); glClear(GL_COLOR_BUFFER_BIT);
    triangle(1, 0, 0);                           /* recorded for rc */
    wglMakeCurrent(dc2, rc2); setup_view();
    glClearColor(0, 0, 0, 1); glClear(GL_COLOR_BUFFER_BIT);
    triangle(0, 0, 1);                           /* recorded for rc2 */
    printf("query context2_fnv1a=%08x\n", frame_hash());
    wglMakeCurrent(dc, rc);
    printf("query context1_fnv1a=%08x\n", frame_hash());

    /* a second thread records into rc2 and only switches the context away before it exits */
    {
        struct thread_args args = { hw2, rc2 };
        HANDLE th = CreateThread(NULL, 0, thread_draw, &args, 0, NULL);
        WaitForSingleObject(th, INFINITE); CloseHandle(th);
        wglMakeCurrent(dc2, rc2);
        printf("query thread_fnv1a=%08x\n", frame_hash());
        wglMakeCurrent(dc, rc);
    }

    /* timing: SOLIDWORKS-like immediate-mode frame */
    {
        static float vn[31 * 6];
        for (j = 0; j < 31; j++) { vn[j * 6] = 0; vn[j * 6 + 1] = 0.6f; vn[j * 6 + 2] = 0.8f; vn[j * 6 + 3] = (j & 1) * 0.01f; vn[j * 6 + 4] = j * 0.002f; vn[j * 6 + 5] = 0; }
        glEnable(GL_LIGHTING);
        t0 = now();
        for (f = 0; f < frames; f++)
        {
            glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
            for (i = 0; i < 10000; i++)
            {
                glBegin(GL_TRIANGLE_STRIP);
                for (j = 0; j < 30; j++) { glNormal3fv(vn + j * 6); glVertex3fv(vn + j * 6 + 3); }
                glEnd();
                if (!(i % 16)) { glDisable(GL_POLYGON_OFFSET_FILL); glEnable(GL_POLYGON_OFFSET_FILL); }
            }
            glFlush();
        }
        glFinish();
        t = now() - t0;
        printf("time frame_600k_calls_ms=%.1f ns_per_call=%.1f\n", t * 1e3 / frames, t * 1e9 / frames / 600000.0);
    }
    wglMakeCurrent(NULL, NULL); wglDeleteContext(rc); wglDeleteContext(rc2);
    ReleaseDC(hw, dc); ReleaseDC(hw2, dc2); DestroyWindow(hw); DestroyWindow(hw2);
    return 0;
}
