import ctypes
from ctypes import wintypes

user32 = ctypes.windll.user32

ENUM_CHILD_PROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)

def enum_child(hwnd, lparam):
    length = user32.GetWindowTextLengthW(hwnd)
    buff = ctypes.create_unicode_buffer(length + 1)
    user32.GetWindowTextW(hwnd, buff, length + 1)
    
    cls_buff = ctypes.create_unicode_buffer(256)
    user32.GetClassNameW(hwnd, cls_buff, 256)
    
    rect = wintypes.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(rect))
    
    style = user32.GetWindowLongW(hwnd, -16)
    exstyle = user32.GetWindowLongW(hwnd, -20)
    visible = user32.IsWindowVisible(hwnd)
    
    w = rect.right - rect.left
    h = rect.bottom - rect.top
    if visible and w > 20 and h > 20:
        print(f"HWND: 0x{hwnd:08x} | Rect: ({rect.left},{rect.top}, {w}x{h}) | Class: {cls_buff.value:<30} | Style: 0x{style:08x} | Ex: 0x{exstyle:08x} | Text: '{buff.value}'")
    return True

ENUM_PROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)

def enum_top(hwnd, lparam):
    length = user32.GetWindowTextLengthW(hwnd)
    buff = ctypes.create_unicode_buffer(length + 1)
    user32.GetWindowTextW(hwnd, buff, length + 1)
    
    cls_buff = ctypes.create_unicode_buffer(256)
    user32.GetClassNameW(hwnd, cls_buff, 256)
    
    if "SOLIDWORKS" in buff.value or "SLDWORKS" in cls_buff.value:
        print(f"\n=== Found SolidWorks Main Window: 0x{hwnd:08x} '{buff.value}' ===")
        user32.EnumChildWindows(hwnd, ENUM_CHILD_PROC(enum_child), 0)
    return True

user32.EnumWindows(ENUM_PROC(enum_top), 0)
