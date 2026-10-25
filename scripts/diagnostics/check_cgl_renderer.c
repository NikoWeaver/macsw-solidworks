#include <ApplicationServices/ApplicationServices.h>
#include <OpenGL/OpenGL.h>
#include <OpenGL/CGLRenderers.h>
#include <OpenGL/gl.h>
#include <stdio.h>
#include <string.h>

/* Diagnostic only: compare native/Rosetta CGL, without Wine, windows or SW.
 * Unavailable renderers are observations, not a passing CAD/rendering gate. */
#if defined(__x86_64__)
#define ARCHITECTURE "x86_64"
#elif defined(__arm64__)
#define ARCHITECTURE "arm64"
#else
#error Unsupported diagnostic architecture
#endif

static void json_string(const char *value)
{
    putchar('"');
    for (const unsigned char *p = (const unsigned char *)(value ? value : ""); *p; ++p)
    {
        if (*p == '"' || *p == '\\') printf("\\%c", *p);
        else if (*p < 0x20) printf("\\u%04x", *p);
        else putchar(*p);
    }
    putchar('"');
}

static int has_extension(const char *extensions, const char *name)
{
    size_t length = strlen(name);
    const char *p = extensions;
    if (!p) return 0;
    while ((p = strstr(p, name)))
    {
        if ((p == extensions || p[-1] == ' ') && (p[length] == ' ' || !p[length])) return 1;
        p += length;
    }
    return 0;
}

static void check_context(const char *mode, const CGLPixelFormatAttribute *attributes)
{
    CGLPixelFormatObj format = NULL;
    CGLContextObj context = NULL, previous = CGLGetCurrentContext();
    GLint screens = 0, accelerated = 0;
    CGLError error;
    const char *stage = "choose-pixel-format", *extensions = NULL;

    error = CGLChoosePixelFormat(attributes, &format, &screens);
    if (error == kCGLNoError && format)
    {
        CGLDescribePixelFormat(format, 0, kCGLPFAAccelerated, &accelerated);
        stage = "create-context";
        error = CGLCreateContext(format, NULL, &context);
        if (error == kCGLNoError && context)
        {
            stage = "make-current";
            error = CGLSetCurrentContext(context);
            if (error == kCGLNoError)
            {
                stage = "complete";
                extensions = (const char *)glGetString(GL_EXTENSIONS);
            }
        }
    }
    printf("{\"kind\":\"context\",\"architecture\":\"%s\",\"mode\":\"%s\","
           "\"stage\":\"%s\",\"cgl_error\":%d,\"virtual_screens\":%d,\"accelerated\":%s,"
           "\"fbo\":%s,\"framebuffer_blit\":%s,\"packed_depth_stencil\":%s,\"renderer\":",
           ARCHITECTURE, mode, stage, error, screens, accelerated ? "true" : "false",
           has_extension(extensions, "GL_EXT_framebuffer_object") ? "true" : "false",
           has_extension(extensions, "GL_EXT_framebuffer_blit") ? "true" : "false",
           has_extension(extensions, "GL_EXT_packed_depth_stencil") ? "true" : "false");
    json_string(extensions ? (const char *)glGetString(GL_RENDERER) : "");
    printf(",\"version\":");
    json_string(extensions ? (const char *)glGetString(GL_VERSION) : "");
    puts("}");
    fflush(stdout);
    CGLSetCurrentContext(previous);
    if (context) CGLReleaseContext(context);
    if (format) CGLReleasePixelFormat(format);
}

int main(void)
{
    CGLRendererInfoObj renderers = NULL;
    GLint count = 0;
    CGLError error = CGLQueryRendererInfo(0xffffffff, &renderers, &count);
    printf("{\"kind\":\"inventory\",\"architecture\":\"%s\",\"cgl_error\":%d,\"count\":%d}\n",
           ARCHITECTURE, error, count);
    if (error == kCGLNoError && renderers)
    {
        for (GLint index = 0; index < count; ++index)
        {
            GLint renderer = 0, accelerated = 0, online = 0;
            CGLDescribeRenderer(renderers, index, kCGLRPRendererID, &renderer);
            CGLDescribeRenderer(renderers, index, kCGLRPAccelerated, &accelerated);
            CGLDescribeRenderer(renderers, index, kCGLRPOnline, &online);
            printf("{\"kind\":\"renderer\",\"architecture\":\"%s\",\"renderer_id\":%d,"
                   "\"accelerated\":%s,\"online\":%s}\n", ARCHITECTURE, renderer,
                   accelerated ? "true" : "false", online ? "true" : "false");
        }
        CGLDestroyRendererInfo(renderers);
    }
    CGLPixelFormatAttribute display_accelerated[] = {
        kCGLPFADisplayMask, (CGLPixelFormatAttribute)CGDisplayIDToOpenGLDisplayMask(CGMainDisplayID()),
        kCGLPFAAccelerated, kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_Legacy, 0};
    const CGLPixelFormatAttribute any_accelerated[] = {
        kCGLPFAAccelerated, kCGLPFAAllowOfflineRenderers, kCGLPFAOpenGLProfile,
        (CGLPixelFormatAttribute)kCGLOGLPVersion_Legacy, 0};
    const CGLPixelFormatAttribute automatic[] = {
        kCGLPFAAllowOfflineRenderers, kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_Legacy, 0};
    const CGLPixelFormatAttribute software[] = {
        kCGLPFARendererID, kCGLRendererGenericFloatID, kCGLPFAOpenGLProfile,
        (CGLPixelFormatAttribute)kCGLOGLPVersion_Legacy, 0};
    check_context("wine-display-accelerated", display_accelerated);
    check_context("any-accelerated", any_accelerated);
    check_context("automatic", automatic);
    check_context("software", software);
    return 0; /* Context failures are recorded; the separate bitmap gate still fails. */
}
