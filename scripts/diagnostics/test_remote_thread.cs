
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

class TestRemoteThread {
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(int dwDesiredAccess, bool bInheritHandle, int dwProcessId);
    [DllImport("kernel32.dll")] static extern IntPtr VirtualAllocEx(IntPtr hProcess, IntPtr lpAddress, UIntPtr dwSize, uint flAllocationType, uint flProtect);
    [DllImport("kernel32.dll")] static extern bool WriteProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, byte[] lpBuffer, int nSize, out int lpNumberOfBytesWritten);
    [DllImport("kernel32.dll")] static extern IntPtr CreateRemoteThread(IntPtr hProcess, IntPtr lpThreadAttributes, UIntPtr dwStackSize, IntPtr lpStartAddress, IntPtr lpParameter, uint dwCreationFlags, out uint lpThreadId);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr hObject);

    static void Main() {
        Process[] procs = Process.GetProcessesByName("SLDWORKS");
        if (procs.Length == 0) { Console.WriteLine("No SW"); return; }
        IntPtr hProc = OpenProcess(0x1F0FFF, false, procs[0].Id);
        Console.WriteLine("hProc: " + hProc);

        // Simple remote thread: returns 42
        // mov eax, 42 (B8 2A 00 00 00)
        // ret (C3)
        byte[] code = new byte[] { 0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC3 };
        IntPtr pMem = VirtualAllocEx(hProc, IntPtr.Zero, (UIntPtr)0x1000, 0x3000, 0x40);
        Console.WriteLine($"Allocated: 0x{pMem.ToInt64():X}");

        int written;
        WriteProcessMemory(hProc, pMem, code, code.Length, out written);

        uint threadId;
        IntPtr hThread = CreateRemoteThread(hProc, IntPtr.Zero, UIntPtr.Zero, pMem, IntPtr.Zero, 0, out threadId);
        Console.WriteLine($"CreateRemoteThread: hThread=0x{hThread.ToInt64():X}, threadId={threadId}");

        if (hThread != IntPtr.Zero) {
            uint waitRes = WaitForSingleObject(hThread, 5000);
            Console.WriteLine($"WaitForSingleObject: {waitRes} (0 = WAIT_OBJECT_0)");
            CloseHandle(hThread);
        }
        CloseHandle(hProc);
    }
}
