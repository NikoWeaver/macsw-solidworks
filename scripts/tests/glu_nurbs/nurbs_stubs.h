/* Stand-ins for the Wine and OpenGL headers, so that dlls/glu32/nurbs.c from patch 0037 compiles
 * as a native arm64 program (test_wine_glu_nurbs.py). The values are the ones of include/wine/wgl.h
 * and include/wine/glu.h. The GL entry points are recorded by nurbs_harness.c. */
#ifndef NURBS_STUBS_H
#define NURBS_STUBS_H

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef int BOOL;
typedef unsigned char BYTE;
typedef void *HANDLE;
#define TRUE 1
#define FALSE 0
#define WINAPI
#define CALLBACK
#define APIENTRY
#define __cdecl
#define HEAP_ZERO_MEMORY 0x00000008
#define ARRAY_SIZE(x) (sizeof(x) / sizeof((x)[0]))
#define max(a,b) (((a) > (b)) ? (a) : (b))
#define min(a,b) (((a) < (b)) ? (a) : (b))

extern long harness_heap_blocks;
static inline HANDLE GetProcessHeap(void) { return NULL; }
static inline void *HeapAlloc( HANDLE heap, unsigned int flags, size_t size )
{
    void *ptr = (flags & HEAP_ZERO_MEMORY) ? calloc( 1, size ) : malloc( size );
    if (ptr) harness_heap_blocks++;
    return ptr;
}
static inline BOOL HeapFree( HANDLE heap, unsigned int flags, void *ptr )
{
    if (ptr) harness_heap_blocks--;
    free( ptr );
    return TRUE;
}

extern int harness_trace;
#define WINE_DEFAULT_DEBUG_CHANNEL(ch)
#define TRACE(...) do { if (harness_trace) fprintf( stderr, __VA_ARGS__ ); } while (0)
#define WARN(...) TRACE(__VA_ARGS__)

typedef unsigned int GLenum;
typedef unsigned int GLbitfield;
typedef unsigned char GLboolean;
typedef unsigned char GLubyte;
typedef int GLint;
typedef float GLfloat;
typedef double GLdouble;
typedef struct GLUnurbs GLUnurbs;

#define GL_FALSE 0
#define GL_TRUE 1
#define GL_LINE_STRIP 0x0003
#define GL_TRIANGLES 0x0004
#define GL_QUAD_STRIP 0x0008
#define GL_CURRENT_BIT 0x00000001
#define GL_AUTO_NORMAL 0x0D80
#define GL_VIEWPORT 0x0BA2
#define GL_MODELVIEW_MATRIX 0x0BA6
#define GL_PROJECTION_MATRIX 0x0BA7
#define GL_MAP1_COLOR_4 0x0D90
#define GL_MAP1_INDEX 0x0D91
#define GL_MAP1_NORMAL 0x0D92
#define GL_MAP1_TEXTURE_COORD_1 0x0D93
#define GL_MAP1_TEXTURE_COORD_2 0x0D94
#define GL_MAP1_TEXTURE_COORD_3 0x0D95
#define GL_MAP1_TEXTURE_COORD_4 0x0D96
#define GL_MAP1_VERTEX_3 0x0D97
#define GL_MAP1_VERTEX_4 0x0D98
#define GL_MAP2_COLOR_4 0x0DB0
#define GL_MAP2_INDEX 0x0DB1
#define GL_MAP2_NORMAL 0x0DB2
#define GL_MAP2_TEXTURE_COORD_1 0x0DB3
#define GL_MAP2_TEXTURE_COORD_2 0x0DB4
#define GL_MAP2_TEXTURE_COORD_3 0x0DB5
#define GL_MAP2_TEXTURE_COORD_4 0x0DB6
#define GL_MAP2_VERTEX_3 0x0DB7
#define GL_MAP2_VERTEX_4 0x0DB8

#define GLU_INVALID_ENUM 100900
#define GLU_INVALID_VALUE 100901
#define GLU_OUT_OF_MEMORY 100902
#define GLU_FILL 100012
#define GLU_AUTO_LOAD_MATRIX 100200
#define GLU_CULLING 100201
#define GLU_PARAMETRIC_TOLERANCE 100202
#define GLU_SAMPLING_TOLERANCE 100203
#define GLU_DISPLAY_MODE 100204
#define GLU_SAMPLING_METHOD 100205
#define GLU_U_STEP 100206
#define GLU_V_STEP 100207
#define GLU_NURBS_MODE 100160
#define GLU_NURBS_TESSELLATOR 100161
#define GLU_NURBS_RENDERER 100162
#define GLU_OBJECT_PARAMETRIC_ERROR 100208
#define GLU_OBJECT_PATH_LENGTH 100209
#define GLU_PATH_LENGTH 100215
#define GLU_PARAMETRIC_ERROR 100216
#define GLU_DOMAIN_DISTANCE 100217
#define GLU_MAP1_TRIM_2 100210
#define GLU_MAP1_TRIM_3 100211
#define GLU_OUTLINE_POLYGON 100240
#define GLU_OUTLINE_PATCH 100241
#define GLU_NURBS_ERROR 100103
#define GLU_NURBS_BEGIN 100164
#define GLU_NURBS_VERTEX 100165
#define GLU_NURBS_NORMAL 100166
#define GLU_NURBS_COLOR 100167
#define GLU_NURBS_TEXTURE_COORD 100168
#define GLU_NURBS_END 100169
#define GLU_NURBS_BEGIN_DATA 100170
#define GLU_NURBS_VERTEX_DATA 100171
#define GLU_NURBS_NORMAL_DATA 100172
#define GLU_NURBS_COLOR_DATA 100173
#define GLU_NURBS_TEXTURE_COORD_DATA 100174
#define GLU_NURBS_END_DATA 100175
#define GLU_NURBS_ERROR1 100251
#define GLU_NURBS_ERROR2 100252
#define GLU_NURBS_ERROR3 100253
#define GLU_NURBS_ERROR4 100254
#define GLU_NURBS_ERROR5 100255
#define GLU_NURBS_ERROR6 100256
#define GLU_NURBS_ERROR7 100257
#define GLU_NURBS_ERROR8 100258
#define GLU_NURBS_ERROR12 100262
#define GLU_NURBS_ERROR13 100263
#define GLU_NURBS_ERROR14 100264
#define GLU_NURBS_ERROR15 100265
#define GLU_NURBS_ERROR16 100266
#define GLU_NURBS_ERROR17 100267
#define GLU_NURBS_ERROR19 100269
#define GLU_NURBS_ERROR22 100272
#define GLU_NURBS_ERROR27 100277
#define GLU_NURBS_ERROR32 100282
#define GLU_NURBS_ERROR33 100283
#define GLU_NURBS_ERROR34 100284
#define GLU_NURBS_ERROR35 100285
#define GLU_NURBS_ERROR36 100286

void glBegin( GLenum mode );
void glEnd( void );
void glVertex3fv( const GLfloat *v );
void glVertex4fv( const GLfloat *v );
void glNormal3fv( const GLfloat *v );
void glColor4fv( const GLfloat *v );
void glIndexf( GLfloat c );
void glTexCoord1fv( const GLfloat *v );
void glTexCoord2fv( const GLfloat *v );
void glTexCoord3fv( const GLfloat *v );
void glTexCoord4fv( const GLfloat *v );
void glGetFloatv( GLenum pname, GLfloat *data );
void glGetIntegerv( GLenum pname, GLint *data );
GLboolean glIsEnabled( GLenum cap );
void glPushAttrib( GLbitfield mask );
void glPopAttrib( void );

#endif
