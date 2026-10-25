/* Native test harness for dlls/glu32/nurbs.c (patch 0037), driven by test_wine_glu_nurbs.py.
 *
 *   nurbs_harness eval < cases     evaluates curves and surfaces with the module's de Boor code
 *   nurbs_harness api <scenario>   runs a scenario through the public gluNurbs* entry points
 *
 * Output is one event per line. GL calls are recorded, not executed. */
#include "nurbs_stubs.h"
#include "nurbs.c"

int harness_trace = 0;
long harness_heap_blocks = 0;

static GLfloat gl_model[16], gl_proj[16];
static GLint gl_viewport[4] = { 0, 0, 400, 400 };
static GLboolean gl_auto_normal;
static int gl_attrib_depth;

static void identity( GLfloat *m )
{
    memset( m, 0, 16 * sizeof(GLfloat) );
    m[0] = m[5] = m[10] = m[15] = 1.0f;
}

static void put( const char *name, const GLfloat *v, int n )
{
    int i;
    printf( "%s", name );
    for (i = 0; i < n; i++) printf( " %.9g", v[i] );
    printf( "\n" );
}

void glBegin( GLenum mode ) { printf( "glBegin %u\n", mode ); }
void glEnd( void ) { printf( "glEnd\n" ); }
void glVertex3fv( const GLfloat *v ) { put( "glVertex3fv", v, 3 ); }
void glVertex4fv( const GLfloat *v ) { put( "glVertex4fv", v, 4 ); }
void glNormal3fv( const GLfloat *v ) { put( "glNormal3fv", v, 3 ); }
void glColor4fv( const GLfloat *v ) { put( "glColor4fv", v, 4 ); }
void glIndexf( GLfloat c ) { put( "glIndexf", &c, 1 ); }
void glTexCoord1fv( const GLfloat *v ) { put( "glTexCoord1fv", v, 1 ); }
void glTexCoord2fv( const GLfloat *v ) { put( "glTexCoord2fv", v, 2 ); }
void glTexCoord3fv( const GLfloat *v ) { put( "glTexCoord3fv", v, 3 ); }
void glTexCoord4fv( const GLfloat *v ) { put( "glTexCoord4fv", v, 4 ); }
void glGetFloatv( GLenum pname, GLfloat *data )
{
    printf( "glGetFloatv %#x\n", pname );
    if (pname == GL_MODELVIEW_MATRIX) memcpy( data, gl_model, sizeof(gl_model) );
    if (pname == GL_PROJECTION_MATRIX) memcpy( data, gl_proj, sizeof(gl_proj) );
}
void glGetIntegerv( GLenum pname, GLint *data )
{
    printf( "glGetIntegerv %#x\n", pname );
    if (pname == GL_VIEWPORT) memcpy( data, gl_viewport, sizeof(gl_viewport) );
}
GLboolean glIsEnabled( GLenum cap ) { return cap == GL_AUTO_NORMAL && gl_auto_normal; }
void glPushAttrib( GLbitfield mask ) { printf( "glPushAttrib %#x\n", mask ); gl_attrib_depth++; }
void glPopAttrib( void ) { printf( "glPopAttrib\n" ); gl_attrib_depth--; }

static void CALLBACK cb_error( GLenum code ) { printf( "error %u\n", code ); }
static void CALLBACK cb_begin( GLenum mode ) { printf( "begin %u\n", mode ); }
static void CALLBACK cb_vertex( GLfloat *v ) { put( "vertex", v, 3 ); }
static void CALLBACK cb_normal( GLfloat *v ) { put( "normal", v, 3 ); }
static void CALLBACK cb_color( GLfloat *v ) { put( "color", v, 4 ); }
static void CALLBACK cb_texcoord( GLfloat *v ) { put( "texcoord", v, 2 ); }
static void CALLBACK cb_end( void ) { printf( "end\n" ); }
static void CALLBACK cb_begin_data( GLenum mode, void *data ) { printf( "begin_data %u %s\n", mode, data ? "ptr" : "null" ); }
static void CALLBACK cb_vertex_data( GLfloat *v, void *data ) { printf( "vertex_data %s ", data ? "ptr" : "null" ); put( "", v, 3 ); }
static void CALLBACK cb_end_data( void *data ) { printf( "end_data %s\n", data ? "ptr" : "null" ); }

typedef void (CALLBACK *fnptr)(void);

static GLUnurbs *new_tess( void )
{
    GLUnurbs *nurbs = wine_gluNewNurbsRenderer();
    GLfloat model[16], proj[16];
    GLint viewport[4] = { 0, 0, 400, 400 };

    identity( model );
    identity( proj );
    wine_gluNurbsCallback( nurbs, GLU_NURBS_ERROR, (fnptr)cb_error );
    wine_gluNurbsCallback( nurbs, GLU_NURBS_BEGIN, (fnptr)cb_begin );
    wine_gluNurbsCallback( nurbs, GLU_NURBS_VERTEX, (fnptr)cb_vertex );
    wine_gluNurbsCallback( nurbs, GLU_NURBS_END, (fnptr)cb_end );
    wine_gluNurbsProperty( nurbs, GLU_NURBS_MODE, GLU_NURBS_TESSELLATOR );
    wine_gluNurbsProperty( nurbs, GLU_AUTO_LOAD_MATRIX, GL_FALSE );
    wine_gluLoadSamplingMatrices( nurbs, model, proj, viewport );
    return nurbs;
}

static void done( GLUnurbs *nurbs )
{
    wine_gluDeleteNurbsRenderer( nurbs );
    printf( "heap %ld\n", harness_heap_blocks );
    printf( "attrib %d\n", gl_attrib_depth );
}

/* full circle (or ellipse with radii a, b) as a rational quadratic with 9 points (homogeneous) */
static GLfloat circle_knots[12] = { 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 4 };
static void circle_points( GLfloat a, GLfloat b, GLfloat *pts )
{
    static const GLfloat xy[9][2] = { {1,0}, {1,1}, {0,1}, {-1,1}, {-1,0}, {-1,-1}, {0,-1}, {1,-1}, {1,0} };
    int i;
    for (i = 0; i < 9; i++)
    {
        GLfloat w = (i % 2) ? sqrtf( 0.5f ) : 1.0f;
        pts[4 * i] = xy[i][0] * a * w;
        pts[4 * i + 1] = xy[i][1] * b * w;
        pts[4 * i + 2] = 0;
        pts[4 * i + 3] = w;
    }
}

/* a cubic patch over [0,1]^2 with x = s, y = t and a bump in z */
static GLfloat patch_knots[8] = { 0, 0, 0, 0, 1, 1, 1, 1 };
static void patch_points( GLfloat *pts, GLfloat bump )
{
    int i, j;
    for (i = 0; i < 4; i++)
        for (j = 0; j < 4; j++)
        {
            pts[(i * 4 + j) * 3] = i / 3.0f;
            pts[(i * 4 + j) * 3 + 1] = j / 3.0f;
            pts[(i * 4 + j) * 3 + 2] = (i == 1 || i == 2) && (j == 1 || j == 2) ? bump : 0.0f;
        }
}

static void scenario_props( void )
{
    static const GLenum props[] = { GLU_SAMPLING_METHOD, GLU_SAMPLING_TOLERANCE, GLU_PARAMETRIC_TOLERANCE,
        GLU_U_STEP, GLU_V_STEP, GLU_DISPLAY_MODE, GLU_CULLING, GLU_AUTO_LOAD_MATRIX, GLU_NURBS_MODE };
    static const GLfloat values[] = { GLU_DOMAIN_DISTANCE, 7.5f, 0.25f, 12, 13, GLU_OUTLINE_PATCH, 1, 0,
        GLU_NURBS_TESSELLATOR };
    GLUnurbs *nurbs = wine_gluNewNurbsRenderer();
    GLfloat v;
    unsigned int i;

    wine_gluNurbsCallback( nurbs, GLU_NURBS_ERROR, (fnptr)cb_error );
    for (i = 0; i < ARRAY_SIZE(props); i++)
    {
        v = -1;
        wine_gluGetNurbsProperty( nurbs, props[i], &v );
        printf( "default %u %.9g\n", props[i], v );
    }
    for (i = 0; i < ARRAY_SIZE(props); i++)
    {
        wine_gluNurbsProperty( nurbs, props[i], values[i] );
        wine_gluGetNurbsProperty( nurbs, props[i], &v );
        printf( "set %u %.9g\n", props[i], v );
    }
    printf( "invalid\n" );
    wine_gluNurbsProperty( nurbs, GLU_SAMPLING_TOLERANCE, 0 );
    wine_gluNurbsProperty( nurbs, GLU_SAMPLING_TOLERANCE, NAN );
    wine_gluNurbsProperty( nurbs, GLU_U_STEP, -1 );
    wine_gluNurbsProperty( nurbs, GLU_SAMPLING_METHOD, 12345 );
    wine_gluNurbsProperty( nurbs, GLU_DISPLAY_MODE, GL_TRIANGLES );
    wine_gluNurbsProperty( nurbs, GLU_NURBS_MODE, 0 );
    wine_gluNurbsProperty( nurbs, 4242, 1 );
    wine_gluGetNurbsProperty( nurbs, 4242, &v );
    wine_gluNurbsCallback( nurbs, 4242, NULL );
    wine_gluGetNurbsProperty( nurbs, GLU_SAMPLING_TOLERANCE, &v );
    printf( "kept %.9g\n", v );
    /* NULL objects are ignored, like the NULL that an old gluNewNurbsRenderer returned */
    wine_gluNurbsProperty( NULL, GLU_SAMPLING_TOLERANCE, 1 );
    wine_gluGetNurbsProperty( NULL, GLU_SAMPLING_TOLERANCE, &v );
    wine_gluBeginCurve( NULL );
    wine_gluNurbsCurve( NULL, 12, circle_knots, 4, NULL, 3, GL_MAP1_VERTEX_4 );
    wine_gluEndCurve( NULL );
    wine_gluDeleteNurbsRenderer( NULL );
    done( nurbs );
}

static void scenario_circle( GLfloat a, GLfloat b, GLenum method, GLfloat value )
{
    GLUnurbs *nurbs = new_tess();
    GLfloat pts[36];

    circle_points( a, b, pts );
    wine_gluNurbsProperty( nurbs, GLU_SAMPLING_METHOD, method );
    if (method == GLU_DOMAIN_DISTANCE) wine_gluNurbsProperty( nurbs, GLU_U_STEP, value );
    else if (method == GLU_PATH_LENGTH || method == GLU_OBJECT_PATH_LENGTH)
        wine_gluNurbsProperty( nurbs, GLU_SAMPLING_TOLERANCE, value );
    else wine_gluNurbsProperty( nurbs, GLU_PARAMETRIC_TOLERANCE, value );
    wine_gluBeginCurve( nurbs );
    wine_gluNurbsCurve( nurbs, 12, circle_knots, 4, pts, 3, GL_MAP1_VERTEX_4 );
    wine_gluEndCurve( nurbs );
    done( nurbs );
}

static void scenario_render( void )
{
    GLUnurbs *nurbs = wine_gluNewNurbsRenderer();
    GLfloat pts[36];

    identity( gl_model );
    identity( gl_proj );
    circle_points( 0.5f, 0.5f, pts );
    wine_gluNurbsCallback( nurbs, GLU_NURBS_ERROR, (fnptr)cb_error );
    wine_gluNurbsCallback( nurbs, GLU_NURBS_VERTEX, (fnptr)cb_vertex );  /* not used by the renderer */
    wine_gluNurbsProperty( nurbs, GLU_SAMPLING_TOLERANCE, 25 );
    wine_gluBeginCurve( nurbs );
    wine_gluNurbsCurve( nurbs, 12, circle_knots, 4, pts, 3, GL_MAP1_VERTEX_4 );
    wine_gluEndCurve( nurbs );
    printf( "zoom\n" );  /* 4x zoom: the same curve gets about 4x the segments */
    gl_model[0] = gl_model[5] = 4.0f;
    wine_gluBeginCurve( nurbs );
    wine_gluNurbsCurve( nurbs, 12, circle_knots, 4, pts, 3, GL_MAP1_VERTEX_4 );
    wine_gluEndCurve( nurbs );
    done( nurbs );
}

static void scenario_errors( void )
{
    GLUnurbs *nurbs = new_tess();
    GLfloat knots[8] = { 0, 0, 0, 0, 1, 1, 1, 1 }, bad[8] = { 0, 0, 0, 1, 0.5f, 1, 1, 1 };
    GLfloat mult[8] = { 0, 0, 0, 0, 0, 1, 1, 1 }, flat[4] = { 0, 1, 1, 2 };
    GLfloat pts[12] = { 0, 0, 0, 1, 1, 0, 2, -1, 0, 3, 0, 0 }, pwl[4] = { 0, 0, 1, 1 };

    wine_gluNurbsProperty( nurbs, GLU_SAMPLING_METHOD, GLU_DOMAIN_DISTANCE );
    wine_gluNurbsProperty( nurbs, GLU_U_STEP, 2 );
    printf( "case order\n" );      wine_gluNurbsCurve( nurbs, 8, knots, 3, pts, 0, GL_MAP1_VERTEX_3 );
    printf( "case order25\n" );    wine_gluNurbsCurve( nurbs, 8, knots, 3, pts, 25, GL_MAP1_VERTEX_3 );
    printf( "case fewknots\n" );   wine_gluNurbsCurve( nurbs, 7, knots, 3, pts, 4, GL_MAP1_VERTEX_3 );
    printf( "case decreasing\n" ); wine_gluNurbsCurve( nurbs, 8, bad, 3, pts, 4, GL_MAP1_VERTEX_3 );
    printf( "case multiplicity\n" ); wine_gluNurbsCurve( nurbs, 8, mult, 3, pts, 4, GL_MAP1_VERTEX_3 );
    printf( "case emptyrange\n" ); wine_gluNurbsCurve( nurbs, 4, flat, 3, pts, 2, GL_MAP1_VERTEX_3 );
    printf( "case nullknots\n" );  wine_gluNurbsCurve( nurbs, 8, NULL, 3, pts, 4, GL_MAP1_VERTEX_3 );
    printf( "case nullctl\n" );    wine_gluNurbsCurve( nurbs, 8, knots, 3, NULL, 4, GL_MAP1_VERTEX_3 );
    printf( "case stride\n" );     wine_gluNurbsCurve( nurbs, 8, knots, -3, pts, 4, GL_MAP1_VERTEX_3 );
    printf( "case type\n" );       wine_gluNurbsCurve( nurbs, 8, knots, 3, pts, 4, GL_TRIANGLES );
    printf( "case endcurve\n" );   wine_gluEndCurve( nurbs );
    printf( "case endsurface\n" ); wine_gluEndSurface( nurbs );
    printf( "case begintrim\n" );  wine_gluBeginTrim( nurbs );
    printf( "case endtrim\n" );    wine_gluEndTrim( nurbs );
    printf( "case pwl\n" );        wine_gluPwlCurve( nurbs, 2, pwl, 2, GLU_MAP1_TRIM_2 );
    printf( "case trimtype\n" );   wine_gluNurbsCurve( nurbs, 8, knots, 2, pwl, 4, GLU_MAP1_TRIM_2 );
    printf( "case twice\n" );      wine_gluBeginCurve( nurbs ); wine_gluBeginCurve( nurbs );
    printf( "case nosurface\n" );  wine_gluBeginSurface( nurbs );
    printf( "case novertex\n" );   wine_gluEndCurve( nurbs );
    printf( "case surface\n" );
    wine_gluBeginSurface( nurbs );
    wine_gluBeginTrim( nurbs );
    printf( "case trimtwice\n" );  wine_gluBeginTrim( nurbs );
    printf( "case pwltype\n" );    wine_gluPwlCurve( nurbs, 2, pwl, 2, GL_MAP1_VERTEX_3 );
    printf( "case pwlcount\n" );   wine_gluPwlCurve( nurbs, -1, pwl, 2, GLU_MAP1_TRIM_2 );
    printf( "case curveintrim\n" ); wine_gluNurbsCurve( nurbs, 8, knots, 3, pts, 4, GL_MAP1_VERTEX_3 );
    printf( "case endsurfaceintrim\n" ); wine_gluEndSurface( nurbs );  /* ends the trim too; no vertex surface */
    printf( "case recovered\n" );
    wine_gluBeginCurve( nurbs );
    wine_gluNurbsCurve( nurbs, 8, knots, 3, pts, 4, GL_MAP1_VERTEX_3 );
    wine_gluEndCurve( nurbs );
    done( nurbs );
}

static void scenario_limits( void )
{
    GLUnurbs *nurbs = new_tess();
    GLfloat pts[36], nan_knots[12], huge[16];
    GLint viewport[4] = { 0, 0, 1 << 20, 1 << 20 };
    int i;

    circle_points( 1000.0f, 1000.0f, pts );
    memcpy( nan_knots, circle_knots, sizeof(nan_knots) );
    nan_knots[5] = NAN;
    identity( huge );
    huge[0] = huge[5] = 1e6f;
    printf( "case tiny\n" );  /* tiny tolerance on a huge view: capped at MAX_SPAN_STEPS per span */
    wine_gluLoadSamplingMatrices( nurbs, huge, NULL, viewport );
    wine_gluNurbsProperty( nurbs, GLU_SAMPLING_TOLERANCE, 1e-30f );
    wine_gluNurbsCurve( nurbs, 12, circle_knots, 4, pts, 3, GL_MAP1_VERTEX_4 );
    printf( "case parametric\n" );
    wine_gluNurbsProperty( nurbs, GLU_SAMPLING_METHOD, GLU_PARAMETRIC_ERROR );
    wine_gluNurbsProperty( nurbs, GLU_PARAMETRIC_TOLERANCE, 1e-30f );
    wine_gluNurbsCurve( nurbs, 12, circle_knots, 4, pts, 3, GL_MAP1_VERTEX_4 );
    printf( "case domain\n" );
    wine_gluNurbsProperty( nurbs, GLU_SAMPLING_METHOD, GLU_DOMAIN_DISTANCE );
    wine_gluNurbsProperty( nurbs, GLU_U_STEP, 1e30f );
    wine_gluNurbsCurve( nurbs, 12, circle_knots, 4, pts, 3, GL_MAP1_VERTEX_4 );
    printf( "case nanknot\n" );
    wine_gluNurbsCurve( nurbs, 12, nan_knots, 4, pts, 3, GL_MAP1_VERTEX_4 );
    printf( "case nanpoint\n" );
    wine_gluNurbsProperty( nurbs, GLU_SAMPLING_METHOD, GLU_PATH_LENGTH );
    for (i = 0; i < 36; i++) pts[i] = NAN;
    wine_gluNurbsCurve( nurbs, 12, circle_knots, 4, pts, 3, GL_MAP1_VERTEX_4 );
    printf( "case surface\n" );  /* tiny tolerance on a surface: capped at MAX_GRID_STEPS per direction */
    {
        GLfloat patch[48];
        patch_points( patch, 1e6f );
        wine_gluNurbsProperty( nurbs, GLU_SAMPLING_TOLERANCE, 1e-30f );
        wine_gluNurbsSurface( nurbs, 8, patch_knots, 8, patch_knots, 12, 3, patch, 4, 4, GL_MAP2_VERTEX_3 );
    }
    printf( "case manyspans\n" );  /* 200 spans with a tiny tolerance: capped at MAX_CURVE_STEPS in all */
    {
        static GLfloat knots[203], line[201 * 3];
        for (i = 0; i < 203; i++) knots[i] = i < 1 ? 0 : i > 201 ? 200 : i - 1;
        for (i = 0; i < 201; i++)
        {
            line[3 * i] = i / 200.0f;
            line[3 * i + 1] = (i % 2) / 200.0f;
            line[3 * i + 2] = 0;
        }
        wine_gluNurbsCurve( nurbs, 203, knots, 3, line, 2, GL_MAP1_VERTEX_3 );
    }
    done( nurbs );
}

static void scenario_surface( GLenum display, BOOL trim, BOOL normals )
{
    GLUnurbs *nurbs = new_tess();
    GLfloat patch[48], circle[27], hole[10] = { 0.4f, 0.4f, 0.4f, 0.6f, 0.6f, 0.6f, 0.6f, 0.4f, 0.4f, 0.4f };
    static const GLfloat xy[9][2] = { {1,0}, {1,1}, {0,1}, {-1,1}, {-1,0}, {-1,-1}, {0,-1}, {1,-1}, {1,0} };
    int i;

    patch_points( patch, normals ? 0.5f : 0.0f );
    if (normals) wine_gluNurbsCallback( nurbs, GLU_NURBS_NORMAL, (fnptr)cb_normal );
    wine_gluNurbsProperty( nurbs, GLU_SAMPLING_METHOD, GLU_DOMAIN_DISTANCE );
    wine_gluNurbsProperty( nurbs, GLU_U_STEP, trim ? 40 : 4 );
    wine_gluNurbsProperty( nurbs, GLU_V_STEP, trim ? 40 : 3 );
    wine_gluNurbsProperty( nurbs, GLU_DISPLAY_MODE, display );
    for (i = 0; i < 9; i++)  /* counterclockwise circle, centre (0.5, 0.5), radius 0.4, homogeneous */
    {
        GLfloat w = (i % 2) ? sqrtf( 0.5f ) : 1.0f;
        circle[3 * i] = (0.5f + 0.4f * xy[i][0]) * w;
        circle[3 * i + 1] = (0.5f + 0.4f * xy[i][1]) * w;
        circle[3 * i + 2] = w;
    }
    wine_gluBeginSurface( nurbs );
    wine_gluNurbsSurface( nurbs, 8, patch_knots, 8, patch_knots, 12, 3, patch, 4, 4, GL_MAP2_VERTEX_3 );
    if (trim)
    {
        wine_gluBeginTrim( nurbs );
        wine_gluNurbsCurve( nurbs, 12, circle_knots, 3, circle, 3, GLU_MAP1_TRIM_3 );
        wine_gluEndTrim( nurbs );
        wine_gluBeginTrim( nurbs );  /* clockwise square hole in two pieces */
        wine_gluPwlCurve( nurbs, 3, hole, 2, GLU_MAP1_TRIM_2 );
        wine_gluPwlCurve( nurbs, 3, hole + 4, 2, GLU_MAP1_TRIM_2 );
        wine_gluEndTrim( nurbs );
    }
    wine_gluEndSurface( nurbs );
    done( nurbs );
}

static void scenario_attributes( void )
{
    GLUnurbs *nurbs = new_tess();
    GLfloat knots[4] = { 0, 0, 1, 1 }, line[6] = { 0, 0, 0, 2, 0, 0 };
    GLfloat colors[8] = { 1, 0, 0, 1, 0, 0, 1, 1 }, tex[4] = { 0, 0, 1, 1 };
    GLfloat knots2[6] = { 0, 0, 0.5f, 1, 2, 2 }, line2[12] = { 0, 0, 0, 1, 1, 0, 2, 0, 0, 3, 1, 0 };

    wine_gluNurbsCallback( nurbs, GLU_NURBS_COLOR, (fnptr)cb_color );
    wine_gluNurbsCallback( nurbs, GLU_NURBS_TEXTURE_COORD, (fnptr)cb_texcoord );
    wine_gluNurbsProperty( nurbs, GLU_SAMPLING_METHOD, GLU_DOMAIN_DISTANCE );
    wine_gluNurbsProperty( nurbs, GLU_U_STEP, 4 );
    wine_gluBeginCurve( nurbs );
    wine_gluNurbsCurve( nurbs, 4, knots, 4, colors, 2, GL_MAP1_COLOR_4 );
    wine_gluNurbsCurve( nurbs, 4, knots, 2, tex, 2, GL_MAP1_TEXTURE_COORD_2 );
    wine_gluNurbsCurve( nurbs, 4, knots, 3, line, 2, GL_MAP1_VERTEX_3 );
    wine_gluEndCurve( nurbs );
    printf( "case data\n" );
    wine_gluNurbsCallback( nurbs, GLU_NURBS_BEGIN_DATA, (fnptr)cb_begin_data );
    wine_gluNurbsCallback( nurbs, GLU_NURBS_VERTEX_DATA, (fnptr)cb_vertex_data );
    wine_gluNurbsCallback( nurbs, GLU_NURBS_END_DATA, (fnptr)cb_end_data );
    wine_gluNurbsCurve( nurbs, 4, knots, 3, line, 2, GL_MAP1_VERTEX_3 );  /* implicit gluBeginCurve */
    printf( "case discontinuous\n" );  /* order 2, knot 1 twice: two pieces, two strips */
    wine_gluNurbsCallback( nurbs, GLU_NURBS_BEGIN_DATA, NULL );
    wine_gluNurbsCallback( nurbs, GLU_NURBS_VERTEX_DATA, NULL );
    wine_gluNurbsCallback( nurbs, GLU_NURBS_END_DATA, NULL );
    wine_gluNurbsProperty( nurbs, GLU_U_STEP, 1 );
    knots2[2] = 1;
    knots2[3] = 1;
    wine_gluNurbsCurve( nurbs, 6, knots2, 3, line2, 2, GL_MAP1_VERTEX_3 );
    printf( "case culling\n" );
    wine_gluNurbsProperty( nurbs, GLU_CULLING, GL_TRUE );
    line[0] = 5;
    line[3] = 7;
    wine_gluNurbsCurve( nurbs, 4, knots, 3, line, 2, GL_MAP1_VERTEX_3 );
    line[0] = -0.5f;
    line[3] = 0.5f;
    wine_gluNurbsCurve( nurbs, 4, knots, 3, line, 2, GL_MAP1_VERTEX_3 );
    done( nurbs );
}

static void scenario_render_surface( void )
{
    GLUnurbs *nurbs = wine_gluNewNurbsRenderer();
    GLfloat patch[48];

    identity( gl_model );
    identity( gl_proj );
    gl_auto_normal = GL_TRUE;
    patch_points( patch, 0.5f );
    wine_gluNurbsProperty( nurbs, GLU_SAMPLING_METHOD, GLU_PARAMETRIC_ERROR );
    wine_gluNurbsProperty( nurbs, GLU_PARAMETRIC_TOLERANCE, 2 );
    wine_gluBeginSurface( nurbs );
    wine_gluNurbsSurface( nurbs, 8, patch_knots, 8, patch_knots, 12, 3, patch, 4, 4, GL_MAP2_VERTEX_3 );
    wine_gluEndSurface( nurbs );
    done( nurbs );
}

/* knots of an order 2 curve with count points: count - 1 spans of length 1 (malloc, not counted) */
static GLfloat *span_knots( int count )
{
    GLfloat *knots = malloc( (size_t)(count + 2) * sizeof(GLfloat) );
    int i;

    for (i = 0; i < count + 2; i++) knots[i] = i == 0 ? 0 : i == count + 1 ? count - 1 : i - 1;
    return knots;
}

/* a surface of order 2 along s with many spans, order 1 along t */
static void overflow_grid( GLUnurbs *nurbs, int spans )
{
    GLfloat *knots = span_knots( spans + 1 ), *pts = calloc( (size_t)(spans + 1) * 3, sizeof(GLfloat) );
    GLfloat tknots[2] = { 0, 1 };
    int i;

    for (i = 0; i <= spans; i++) pts[3 * i] = i;
    wine_gluNurbsSurface( nurbs, spans + 3, knots, 2, tknots, 3, 3, pts, 2, 1, GL_MAP2_VERTEX_3 );
    free( knots );
    free( pts );
}

/* the cubic patch, trimmed by an order 2 curve with many spans about 42 long, then pwl more points */
static void overflow_trim( GLUnurbs *nurbs, int spans, int pwl )
{
    GLfloat patch[48], point[2] = { 0.5f, 0.5f }, *knots = span_knots( spans + 1 );
    GLfloat *pts = malloc( (size_t)(spans + 1) * 2 * sizeof(GLfloat) );
    int i;

    patch_points( patch, 0.0f );
    for (i = 0; i <= spans; i++) pts[2 * i] = pts[2 * i + 1] = (i % 2) * 30;
    wine_gluBeginSurface( nurbs );
    wine_gluNurbsSurface( nurbs, 8, patch_knots, 8, patch_knots, 12, 3, patch, 4, 4, GL_MAP2_VERTEX_3 );
    wine_gluBeginTrim( nurbs );
    wine_gluNurbsCurve( nurbs, spans + 3, knots, 2, pts, 2, GLU_MAP1_TRIM_2 );
    if (pwl) wine_gluPwlCurve( nurbs, pwl, point, 0, GLU_MAP1_TRIM_2 );
    wine_gluEndTrim( nurbs );
    wine_gluEndSurface( nurbs );
    free( knots );
    free( pts );
}

/* sample counts that would pass INT_MAX or the 256 MB limits: GLU_OUT_OF_MEMORY, nothing drawn */
static void scenario_overflow( void )
{
    GLUnurbs *nurbs = new_tess();

    wine_gluNurbsProperty( nurbs, GLU_SAMPLING_METHOD, GLU_DOMAIN_DISTANCE );
    wine_gluNurbsProperty( nurbs, GLU_U_STEP, 1024 );
    wine_gluNurbsProperty( nurbs, GLU_V_STEP, 1 );
    printf( "case grid\n" );  /* 2^22 spans * 1024 steps = 2^32 grid steps along s */
    overflow_grid( nurbs, 1 << 22 );
    printf( "case gridcap\n" );  /* 4,500,000 spans: more grid values along s than fit in the largest grid */
    overflow_grid( nurbs, 4500000 );
    wine_gluNurbsProperty( nurbs, GLU_U_STEP, 4 );  /* grid cell 1/4, trim step 1/8: 256 steps per span */
    wine_gluNurbsProperty( nurbs, GLU_V_STEP, 4 );
    printf( "case trim\n" );  /* 8,400,000 spans * 257 points > INT_MAX */
    overflow_trim( nurbs, 8400000, 0 );
    printf( "case pwl\n" );  /* 130,000 spans * 257 points + 200,000 pwl points > MAX_FLOATS / 2 */
    overflow_trim( nurbs, 130000, 200000 );
    done( nurbs );
}

static int read_floats( GLfloat *out, int n )
{
    int i;
    for (i = 0; i < n; i++) if (scanf( "%f", &out[i] ) != 1) return 0;
    return 1;
}

/* "curve order dim nknots knots... points... nu u..." and
 * "surface sorder torder dim ns nt sknots... tknots... points... np (s t)..." */
static int run_eval( void )
{
    static GLfloat buf[1 << 16];
    struct nurbs_map map;
    GLfloat out[4], ds[4], dt[4], s, t;
    char kind[16];
    int n, i, d;

    while (scanf( "%15s", kind ) == 1)
    {
        memset( &map, 0, sizeof(map) );
        map.order[1] = map.count[1] = 1;
        if (!strcmp( kind, "curve" ))
        {
            if (scanf( "%d %d %d", &map.order[0], &map.dim, &n ) != 3) return 1;
            map.count[0] = n - map.order[0];
            map.knots[0] = buf;
            map.ctl = buf + n;
            if (!read_floats( buf, n + map.count[0] * map.dim )) return 1;
            printf( "check %u\n", check_knots( n, map.knots[0], map.order[0] ) );
        }
        else if (!strcmp( kind, "surface" ))
        {
            int ns, nt;
            if (scanf( "%d %d %d %d %d", &map.order[0], &map.order[1], &map.dim, &ns, &nt ) != 5) return 1;
            map.count[0] = ns - map.order[0];
            map.count[1] = nt - map.order[1];
            map.knots[0] = buf;
            map.knots[1] = buf + ns;
            map.ctl = buf + ns + nt;
            if (!read_floats( buf, ns + nt + map.count[0] * map.count[1] * map.dim )) return 1;
        }
        else return 1;
        if (scanf( "%d", &n ) != 1) return 1;
        for (i = 0; i < n; i++)
        {
            if (scanf( "%f", &s ) != 1 || (map.knots[1] && scanf( "%f", &t ) != 1)) return 1;
            eval_map( &map, s, map.knots[1] ? t : 0.0f, out, ds, map.knots[1] ? dt : NULL );
            printf( "p" );
            for (d = 0; d < map.dim; d++) printf( " %.9g", out[d] );
            for (d = 0; d < map.dim; d++) printf( " %.9g", ds[d] );
            if (map.knots[1]) for (d = 0; d < map.dim; d++) printf( " %.9g", dt[d] );
            printf( "\n" );
        }
    }
    return 0;
}

int main( int argc, char **argv )
{
    const char *name = argc > 2 ? argv[2] : "";

    identity( gl_model );
    identity( gl_proj );
    harness_trace = getenv( "NURBS_TRACE" ) != NULL;
    if (argc > 1 && !strcmp( argv[1], "eval" )) return run_eval();
    if (argc < 3 || strcmp( argv[1], "api" )) return 2;
    if (!strcmp( name, "props" )) scenario_props();
    else if (!strcmp( name, "circle_path" )) scenario_circle( 1, 1, GLU_PATH_LENGTH, 10 );
    else if (!strcmp( name, "circle_object" )) scenario_circle( 1, 1, GLU_OBJECT_PATH_LENGTH, 0.05f );
    else if (!strcmp( name, "circle_parametric" )) scenario_circle( 1, 1, GLU_PARAMETRIC_ERROR, 0.5f );
    else if (!strcmp( name, "circle_object_parametric" )) scenario_circle( 1, 1, GLU_OBJECT_PARAMETRIC_ERROR, 0.001f );
    else if (!strcmp( name, "ellipse_domain" )) scenario_circle( 3, 1.5f, GLU_DOMAIN_DISTANCE, 8 );
    else if (!strcmp( name, "render" )) scenario_render();
    else if (!strcmp( name, "errors" )) scenario_errors();
    else if (!strcmp( name, "limits" )) scenario_limits();
    else if (!strcmp( name, "surface_fill" )) scenario_surface( GLU_FILL, FALSE, TRUE );
    else if (!strcmp( name, "surface_outline_polygon" )) scenario_surface( GLU_OUTLINE_POLYGON, FALSE, FALSE );
    else if (!strcmp( name, "surface_outline_patch" )) scenario_surface( GLU_OUTLINE_PATCH, FALSE, FALSE );
    else if (!strcmp( name, "surface_trim" )) scenario_surface( GLU_FILL, TRUE, FALSE );
    else if (!strcmp( name, "surface_trim_outline" )) scenario_surface( GLU_OUTLINE_PATCH, TRUE, FALSE );
    else if (!strcmp( name, "attributes" )) scenario_attributes();
    else if (!strcmp( name, "render_surface" )) scenario_render_surface();
    else if (!strcmp( name, "overflow" )) scenario_overflow();
    else return 2;
    return 0;
}
