#define COBJMACROS
#include <windows.h>
#include <msxml6.h>
#include <oleauto.h>
#include <stdio.h>

static const GUID doc_iid = {0x2933bf95,0x7b36,0x11d2,{0xb2,0x0e,0x00,0xc0,0x4f,0x98,0x3e,0x60}};
static const GUID cache_iid = {0x50ea08b0,0xdd1b,0x4664,{0x9a,0x50,0xc2,0xf4,0x0f,0x4b,0xd7,0x9a}};
static int failures;
static int check(HRESULT hr, const char *step)
{
    if (FAILED(hr)) { printf("FAIL %s hr=0x%08lx\n",step,hr); ++failures; return 0; }
    return 1;
}
static void test(const char *label, const wchar_t *xsd, const wchar_t *xml, const wchar_t *uri, int valid)
{
    IXMLDOMDocument2 *schema = NULL, *doc = NULL;
    IXMLDOMSchemaCollection2 *cache = NULL;
    IXMLDOMParseError *error = NULL;
    BSTR before = NULL, after = NULL, string = NULL, ns = NULL;
    VARIANT value;
    VARIANT_BOOL loaded;
    CLSID clsid;
    LONG code = -1;
    HRESULT hr;
    printf("case=%s\n",label);
    if (!check(CLSIDFromProgID(L"Msxml2.DOMDocument.6.0", &clsid), "doc-clsid")) goto done;
    if (!check(CoCreateInstance(&clsid,NULL,CLSCTX_INPROC_SERVER,&doc_iid,(void **)&schema), "schema-create")) goto done;
    if (!check(CoCreateInstance(&clsid,NULL,CLSCTX_INPROC_SERVER,&doc_iid,(void **)&doc), "doc-create")) goto done;
    IXMLDOMDocument2_put_async(schema, VARIANT_FALSE);
    IXMLDOMDocument2_put_validateOnParse(schema, VARIANT_FALSE);
    IXMLDOMDocument2_put_async(doc, VARIANT_FALSE);
    IXMLDOMDocument2_put_validateOnParse(doc, VARIANT_FALSE);
    string=SysAllocString(xsd);
    hr=IXMLDOMDocument2_loadXML(schema,string,&loaded);
    SysFreeString(string); string=NULL;
    if (!check(hr,"schema-load") || !loaded) { ++failures; goto done; }
    IXMLDOMDocument2_get_xml(schema,&before);
    if (!check(CLSIDFromProgID(L"Msxml2.XMLSchemaCache.6.0", &clsid), "cache-clsid")) goto done;
    if (!check(CoCreateInstance(&clsid,NULL,CLSCTX_INPROC_SERVER,&cache_iid,(void **)&cache), "cache-create")) goto done;
    VariantInit(&value); V_VT(&value)=VT_DISPATCH; V_DISPATCH(&value)=(IDispatch *)schema;
    ns=SysAllocString(uri);
    if (!check(IXMLDOMSchemaCollection2_add(cache,ns,value),"cache-add")) goto done;
    IXMLDOMDocument2_get_xml(schema,&after);
    if (!before || !after || wcscmp(before,after)) { puts("FAIL caller DOM changed"); ++failures; }
    string=SysAllocString(xml);
    hr=IXMLDOMDocument2_loadXML(doc,string,&loaded);
    SysFreeString(string); string=NULL;
    if (!check(hr,"doc-load") || !loaded) { ++failures; goto done; }
    V_DISPATCH(&value)=(IDispatch *)cache;
    if (!check(IXMLDOMDocument2_putref_schemas(doc,value),"schemas-set")) goto done;
    hr=IXMLDOMDocument2_validate(doc,&error);
    if (error) IXMLDOMParseError_get_errorCode(error,&code);
    printf("validate=0x%08lx error=%ld expected_valid=%d\n",hr,code,valid);
    if ((valid && (hr!=S_OK || code!=0)) || (!valid && (hr!=S_FALSE || code==0))) ++failures;
done:
    SysFreeString(string); SysFreeString(before); SysFreeString(after); SysFreeString(ns);
    if(error) IXMLDOMParseError_Release(error);
    if(cache) IXMLDOMSchemaCollection2_Release(cache);
    if(doc) IXMLDOMDocument2_Release(doc);
    if(schema) IXMLDOMDocument2_Release(schema);
}
int main(void)
{
    if (FAILED(CoInitialize(NULL))) return 2;
    const wchar_t *simple=L"<xs:schema xmlns:xs='http://www.w3.org/2001/XMLSchema' elementFormDefault='qualified'><xs:element name='root' type='xs:int'/></xs:schema>";
    test("adopt-valid",simple,L"<root xmlns='urn:macsw:probe'>42</root>",L"urn:macsw:probe",1);
    test("reject-invalid",simple,L"<root xmlns='urn:macsw:probe'>not-an-int</root>",L"urn:macsw:probe",0);
    test("empty-namespace",simple,L"<root>42</root>",L"",1);
    test("named-type-and-ref",L"<xs:schema xmlns:xs='http://www.w3.org/2001/XMLSchema' elementFormDefault='qualified'><xs:simpleType name='Value'><xs:restriction base='xs:int'/></xs:simpleType><xs:element name='child' type='Value'/><xs:element name='root'><xs:complexType><xs:sequence><xs:element ref='child'/><xs:element name='local' type='Value' form='unqualified'/></xs:sequence></xs:complexType></xs:element></xs:schema>",L"<root xmlns='urn:macsw:probe'><child>1</child><local xmlns=''>2</local></root>",L"urn:macsw:probe",1);
    test("explicit-target",L"<xs:schema xmlns:xs='http://www.w3.org/2001/XMLSchema' targetNamespace='urn:macsw:probe'><xs:element name='root' type='xs:int'/></xs:schema>",L"<root xmlns='urn:macsw:probe'>42</root>",L"urn:macsw:probe",1);
    test("default-xsd-namespace",L"<schema xmlns='http://www.w3.org/2001/XMLSchema'><element name='root' type='int'/></schema>",L"<root xmlns='urn:macsw:probe'>42</root>",L"urn:macsw:probe",1);
    test("local-empty-namespace",L"<xs:schema xmlns:xs='http://www.w3.org/2001/XMLSchema'><xs:simpleType name='Value'><xs:restriction base='xs:int'/></xs:simpleType><xs:element name='root' type='Value' xmlns=''/></xs:schema>",L"<root xmlns='urn:macsw:probe'>42</root>",L"urn:macsw:probe",1);
    CoUninitialize();
    wchar_t module_path[1024];
    HMODULE module=GetModuleHandleW(L"msxml3.dll");
    if (!module) module=GetModuleHandleW(L"msxml6.dll");
    if (module && GetModuleFileNameW(module,module_path,1024))
        printf("msxml-module=%ls\n",module_path);
    printf("failures=%d\n",failures);
    if (!failures) puts("XML_NAMESPACE_PROBE_PASS");
    return failures ? 1 : 0;
}
