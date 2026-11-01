using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;

// Read-only metadata for selecting a task's exact guest session.
public static class LaqayGuestSessionQuery {
    [StructLayout(LayoutKind.Sequential)] struct Session {public int id;public IntPtr station;public int state;}
    [DllImport("wtsapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool WTSEnumerateSessionsW(IntPtr server,int reserved,int version,out IntPtr sessions,out int count);
    [DllImport("wtsapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool WTSQuerySessionInformationW(IntPtr server,int session,int info,out IntPtr value,out int bytes);
    [DllImport("wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr value);
    static object Query(int session,int info) {
        IntPtr value;int bytes;
        if(!WTSQuerySessionInformationW(IntPtr.Zero,session,info,out value,out bytes)) throw new Win32Exception(Marshal.GetLastWin32Error());
        try {if(info==16) {if(bytes<2) throw new InvalidOperationException("Missing protocol.");return (int)Marshal.ReadInt16(value);}return Marshal.PtrToStringUni(value);}
        finally {WTSFreeMemory(value);}
    }
    public static int[] FindActive(int protocol,string user,string domain) {
        if(protocol!=0 && protocol!=2) throw new ArgumentException("Only console or RDP sessions are supported.");
        IntPtr sessions;int count;
        if(!WTSEnumerateSessionsW(IntPtr.Zero,0,1,out sessions,out count)) throw new Win32Exception(Marshal.GetLastWin32Error());
        var result=new List<int>();
        try {
            int size=Marshal.SizeOf(typeof(Session));
            for(int i=0;i<count;i++) {
                var session=(Session)Marshal.PtrToStructure(IntPtr.Add(sessions,i*size),typeof(Session));
                if(session.id>0 && session.state==0 && (int)Query(session.id,16)==protocol &&
                    String.Equals((string)Query(session.id,5),user,StringComparison.OrdinalIgnoreCase) &&
                    String.Equals((string)Query(session.id,7),domain,StringComparison.OrdinalIgnoreCase)) result.Add(session.id);
            }
        } finally {WTSFreeMemory(sessions);}
        return result.ToArray();
    }
}
