using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Management;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

public static partial class LaqayGuestDesktop {
    [DllImport("user32.dll")] static extern IntPtr GetShellWindow();
    [DllImport("user32.dll")] static extern IntPtr GetClipboardOwner();
    [DllImport("user32.dll")] static extern IntPtr GetOpenClipboardWindow();
    [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern uint RegisterClipboardFormatW(string name);
    [DllImport("shell32.dll")] static extern int Shell_NotifyIconGetRect(ref IconIdentity identity,out RectangleBounds rectangle);
    [StructLayout(LayoutKind.Sequential)] struct IconIdentity {public uint size;public IntPtr window;public uint id;public Guid guid;}
    [StructLayout(LayoutKind.Sequential)] struct RectangleBounds {public int left,top,right,bottom;}
    static DelayedPng delayedPng;
    static void LifecycleGuard() {RequireRole("Primary");if(SessionProtocol()!=0) throw new InvalidOperationException("Lifecycle cases require the owned guest console.");}
    public static bool TrayIconRegistered() {
        LifecycleGuard();IntPtr window=AppWindow();if(window==IntPtr.Zero) return false;
        var identity=new IconIdentity {size=(uint)Marshal.SizeOf(typeof(IconIdentity)),window=window,id=1};RectangleBounds rectangle;
        return Shell_NotifyIconGetRect(ref identity,out rectangle)==0;
    }
    public static int RestartGuestExplorer() {
        LifecycleGuard();if(application==null || application.HasExited) throw new InvalidOperationException("The owned application must remain running.");
        uint pid;GetWindowThreadProcessId(GetShellWindow(),out pid);
        if(pid==0 || pid==(uint)Process.GetCurrentProcess().Id) throw new InvalidOperationException("The guest shell could not be identified.");
        using(var shell=Process.GetProcessById((int)pid)) {
            if(shell.SessionId!=Process.GetCurrentProcess().SessionId || !String.Equals(shell.MainModule.FileName,Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),"explorer.exe"),StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Refusing an unowned guest shell.");
            foreach(var window in windows) {uint owner;GetWindowThreadProcessId(window,out owner);if(owner!=0 && owner!=pid) throw new InvalidOperationException("Refusing separate Explorer processes in the lifecycle fixture.");}
            windows.Clear();shell.Kill();if(!shell.WaitForExit(5000)) throw new InvalidOperationException("The exact guest Explorer did not stop.");
        }
        var until=DateTime.UtcNow.AddSeconds(20);
        while(DateTime.UtcNow<until) {uint current;GetWindowThreadProcessId(GetShellWindow(),out current);if(current!=0 && current!=pid) return (int)pid;Thread.Sleep(100);}
        // Restart only the same Windows shell in this disposable interactive logon.
        using(var restarted=Process.Start(new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),"explorer.exe")) {UseShellExecute=false})) { }
        return (int)pid;
    }
    public static int GuestExplorerPid() {LifecycleGuard();uint pid;GetWindowThreadProcessId(GetShellWindow(),out pid);return (int)pid;}
    public static void BeginDelayedPng() {
        LifecycleGuard();if(application==null || application.HasExited || delayedPng!=null) throw new InvalidOperationException("A fresh owned application and provider are required.");
        delayedPng=new DelayedPng();delayedPng.Start();
    }
    public static object DelayedPngState() {
        LifecycleGuard();if(delayedPng==null) throw new InvalidOperationException("No delayed fixture is active.");
        return new {ProviderPid=Process.GetCurrentProcess().Id,ProviderThreadId=delayedPng.threadId,RequesterPid=delayedPng.requesterPid,RequesterThreadId=delayedPng.requesterThreadId,OwnerMatches=GetClipboardOwner()==delayedPng.Handle,Sequence=GetClipboardSequenceNumber(),PublishedSequence=delayedPng.sequence,Requested=delayedPng.requested.WaitOne(0),Released=delayedPng.release.WaitOne(0),TimedOut=delayedPng.timedOut,Error=delayedPng.error};
    }
    public static void EndDelayedPng() {
        // Always release the exact owned provider, including after the input deadline.
        if(delayedPng==null) return;var current=delayedPng;delayedPng=null;current.Stop();
    }
    sealed class DelayedPng : NativeWindow {
        internal readonly ManualResetEvent requested=new ManualResetEvent(false),release=new ManualResetEvent(false);
        readonly ManualResetEvent ready=new ManualResetEvent(false);Thread thread;uint format;
        internal uint threadId,requesterPid,requesterThreadId,sequence;internal bool timedOut;internal string error;
        public void Start() {
            thread=new Thread(delegate() {
                try {
                    LifecycleGuard();threadId=GetCurrentThreadId();CreateHandle(new CreateParams {Caption="Laqay delayed PNG fixture",Parent=new IntPtr(-3)});
                    format=RegisterClipboardFormatW("PNG");if(format==0) throw new InvalidOperationException("PNG format registration failed.");
                    if(!OpenClipboard(Handle)) throw new InvalidOperationException("The delayed fixture clipboard could not be opened.");
                    try {if(!EmptyClipboard()) throw new InvalidOperationException("The delayed fixture clipboard could not be cleared.");SetClipboardData(format,IntPtr.Zero);if(!IsClipboardFormatAvailable(format)) throw new InvalidOperationException("The delayed PNG was not advertised.");}
                    finally {CloseClipboard();}
                    sequence=GetClipboardSequenceNumber();ready.Set();Application.Run();
                }catch(Exception failure){error=failure.GetBaseException().Message;ready.Set();}
                finally {if(Handle!=IntPtr.Zero) DestroyHandle();}
            });
            thread.IsBackground=true;thread.SetApartmentState(ApartmentState.STA);thread.Start();
            if(!ready.WaitOne(5000) || error!=null) throw new InvalidOperationException("The delayed PNG provider did not initialize: "+error);
        }
        protected override void WndProc(ref Message message) {
            if(message.Msg==0x305 && (uint)message.WParam.ToInt64()==format) {
                requesterThreadId=GetWindowThreadProcessId(GetOpenClipboardWindow(),out requesterPid);
                requested.Set();
                if(!release.WaitOne(60000)) {timedOut=true;return;}
                // This adversarial provider never supplies bytes: release only cancels its blocked render after the application has exited.
                return;
            }
            if(message.Msg==0x10) {
                if(GetClipboardOwner()==Handle) {if(OpenClipboard(Handle)){try{EmptyClipboard();}finally{CloseClipboard();}}else{error="The owned delayed clipboard could not be cleared.";}}
                DestroyHandle();Application.ExitThread();return;
            }
            base.WndProc(ref message);
        }
        public void Stop() {
            release.Set();if(Handle!=IntPtr.Zero) PostMessageW(Handle,0x10,IntPtr.Zero,IntPtr.Zero);
            if(thread!=null && !thread.Join(5000)) throw new InvalidOperationException("The owned delayed PNG thread did not stop.");
            requested.Dispose();release.Dispose();ready.Dispose();
            if(timedOut || error!=null) throw new InvalidOperationException("The delayed PNG provider failed: "+error);
        }
    }
}

public static class LaqayGuestWaitChain {
    [StructLayout(LayoutKind.Explicit,Size=280)] public struct Node {
        [FieldOffset(0)] public int Type;[FieldOffset(4)] public int Status;
        [FieldOffset(8)] public uint ProcessId;[FieldOffset(12)] public uint ThreadId;
    }
    [StructLayout(LayoutKind.Sequential)] struct Luid {public uint low;public int high;}
    [StructLayout(LayoutKind.Sequential)] struct Privilege {public uint count;public Luid luid;public uint attributes;}
    [DllImport("advapi32.dll",SetLastError=true)] static extern IntPtr OpenThreadWaitChainSession(uint flags,IntPtr callback);
    [DllImport("advapi32.dll")] static extern void CloseThreadWaitChainSession(IntPtr handle);
    [DllImport("advapi32.dll",SetLastError=true)] static extern bool GetThreadWaitChain(IntPtr handle,UIntPtr context,uint flags,uint threadId,ref uint count,[Out] Node[] nodes,out bool cycle);
    [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr process,uint access,out IntPtr token);
    [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool LookupPrivilegeValueW(string system,string name,out Luid luid);
    [DllImport("advapi32.dll",SetLastError=true)] static extern bool AdjustTokenPrivileges(IntPtr token,bool disable,ref Privilege desired,uint length,out Privilege previous,out uint needed);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr LoadLibraryW(string path);
    [DllImport("kernel32.dll",CharSet=CharSet.Ansi,SetLastError=true)] static extern IntPtr GetProcAddress(IntPtr module,string name);
    [DllImport("kernel32.dll")] static extern bool FreeLibrary(IntPtr module);
    [DllImport("kernel32.dll")] static extern uint PssCaptureSnapshot(IntPtr process,uint flags,uint contextFlags,out IntPtr snapshot);
    [DllImport("kernel32.dll")] static extern uint PssFreeSnapshot(IntPtr process,IntPtr snapshot);
    [DllImport("kernel32.dll")] static extern uint PssWalkMarkerCreate(IntPtr allocator,out IntPtr marker);
    [DllImport("kernel32.dll")] static extern uint PssWalkMarkerFree(IntPtr marker);
    [DllImport("kernel32.dll")] static extern uint PssWalkSnapshot(IntPtr snapshot,int kind,IntPtr marker,out SnapshotThread entry,uint size);
    [StructLayout(LayoutKind.Explicit,Size=120)] public struct SnapshotThread {
        [FieldOffset(0)] public uint ExitStatus;[FieldOffset(16)] public uint ProcessId;[FieldOffset(20)] public uint ThreadId;
        [FieldOffset(104)] public uint Flags;[FieldOffset(110)] public ushort ContextSize;[FieldOffset(112)] public IntPtr Context;
    }
    public static int ClipboardStubLength(byte[] code) {
        if(code==null || code.Length<24 || code[0]!=0x4c || code[1]!=0x8b || code[2]!=0xd1 || code[3]!=0xb8) return 0;
        bool syscall=false;
        for(int i=8;i<Math.Min(code.Length,32);i++) {if(i>0 && code[i-1]==0x0f && code[i]==0x05) syscall=true;if(code[i]==0xc3) return syscall?i+1:0;}
        return 0;
    }
    public static bool InstructionInStub(ulong instruction,ulong start,int length) {return length>0 && instruction>=start && instruction-start<(ulong)length;}
    static HashSet<uint> CaptureClipboardThreads(Process app,ulong start,int length,List<object> observations) {
        IntPtr snapshot=IntPtr.Zero,marker=IntPtr.Zero;
        try {
            uint result=PssCaptureSnapshot(app.Handle,0x180,0x100001,out snapshot);
            if(result!=0) throw new System.ComponentModel.Win32Exception((int)result,"Guest thread-context snapshot failed.");
            result=PssWalkMarkerCreate(IntPtr.Zero,out marker);if(result!=0) throw new System.ComponentModel.Win32Exception((int)result);
            var matches=new HashSet<uint>();int count=0;
            while(true) {
                SnapshotThread entry;result=PssWalkSnapshot(snapshot,3,marker,out entry,(uint)Marshal.SizeOf(typeof(SnapshotThread)));
                if(result==259) break;if(result!=0) throw new System.ComponentModel.Win32Exception((int)result);
                if(++count>128 || entry.ProcessId!=app.Id) throw new InvalidOperationException("Unexpected thread snapshot extent or process.");
                bool valid=entry.ExitStatus==259 && (entry.Flags&1)==0 && entry.Context!=IntPtr.Zero && entry.ContextSize>=256 && (Marshal.ReadInt32(entry.Context,48)&0x100001)==0x100001;
                ulong instruction=valid?unchecked((ulong)Marshal.ReadInt64(entry.Context,248)):0;
                bool inside=valid && InstructionInStub(instruction,start,length);
                observations.Add(new {ThreadId=entry.ThreadId,ValidContext=valid,InstructionPointer=instruction.ToString("X16"),InsideClipboardRead=inside});
                if(inside) matches.Add(entry.ThreadId);
            }
            return matches;
        } finally {
            uint markerResult=marker==IntPtr.Zero?0:PssWalkMarkerFree(marker);
            uint snapshotResult=snapshot==IntPtr.Zero?0:PssFreeSnapshot(new IntPtr(-1),snapshot);
            if(markerResult!=0 || snapshotResult!=0) throw new InvalidOperationException("The guest thread snapshot could not be freed.");
        }
    }
    sealed class ContextProof {public bool Confirmed;public uint ThreadId;public object Details;}
    static ContextProof InspectClipboardContexts(Process app) {
        var result=new ContextProof();var samples=new List<object>();IntPtr library=IntPtr.Zero;
        try {
            if(!Environment.Is64BitProcess) throw new InvalidOperationException("Clipboard context inspection requires x64.");
            string system=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),"win32u.dll");ProcessModule target=null;
            foreach(ProcessModule module in app.Modules) if(String.Equals(module.FileName,system,StringComparison.OrdinalIgnoreCase)) target=module;
            if(target==null) throw new InvalidOperationException("The owned application has no matching Windows clipboard syscall module.");
            library=LoadLibraryW(system);if(library==IntPtr.Zero) throw new InvalidOperationException("The system clipboard module could not be inspected.");
            IntPtr procedure=GetProcAddress(library,"NtUserGetClipboardData");if(procedure==IntPtr.Zero) throw new InvalidOperationException("The clipboard syscall export is unavailable.");
            var code=new byte[32];Marshal.Copy(procedure,code,0,code.Length);int length=ClipboardStubLength(code);
            if(length==0) throw new InvalidOperationException("The clipboard syscall stub is not recognized; declining proof.");
            long offset=procedure.ToInt64()-library.ToInt64();if(offset<0 || offset+length>target.ModuleMemorySize) throw new InvalidOperationException("The clipboard syscall export is outside its system module.");
            ulong start=checked((ulong)(target.BaseAddress.ToInt64()+offset));
            var first=new List<object>();var match=CaptureClipboardThreads(app,start,length,first);samples.Add(new {AtUtc=DateTime.UtcNow.ToString("o"),Threads=first});
            Thread.Sleep(100);
            var second=new List<object>();match.IntersectWith(CaptureClipboardThreads(app,start,length,second));samples.Add(new {AtUtc=DateTime.UtcNow.ToString("o"),Threads=second});
            foreach(uint thread in match){result.Confirmed=true;result.ThreadId=thread;break;}
            result.Details=new {SystemModule=system,Export="NtUserGetClipboardData",TargetStart=start.ToString("X16"),StubLength=length,CaptureFlags=0x180,ContextFlags=0x100001,Samples=samples};
        }catch(Exception failure){result.Details=new {Error=failure.GetBaseException().Message,Samples=samples};}
        finally {if(library!=IntPtr.Zero) FreeLibrary(library);}
        return result;
    }
    static void Guard(string labId,string runId) {
        if(!System.Text.RegularExpressions.Regex.IsMatch(labId??"","^[a-f0-9]{32}$") || !System.Text.RegularExpressions.Regex.IsMatch(runId??"","^[a-f0-9]{32}$")) throw new InvalidOperationException("Invalid wait-chain lab identity.");
        var ready=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(File.ReadAllText(@"C:\LaqayLab\ready.json"));
        if((string)ready["LabId"]!=labId || (string)ready["Role"]!="Primary" || !(bool)ready["Ready"] || !Directory.Exists(@"C:\LaqayLab\Runs\"+runId)) throw new InvalidOperationException("Wait-chain inspection requires the exact owned Primary guest run.");
        bool guest=false;
        using(var query=new ManagementObjectSearcher("SELECT Manufacturer,Model FROM Win32_ComputerSystem")) using(var rows=query.Get())
            foreach(ManagementObject row in rows) guest=(string)row["Manufacturer"]=="Microsoft Corporation" && (string)row["Model"]=="Virtual Machine";
        if(!guest) throw new InvalidOperationException("Wait-chain inspection is limited to the guest.");
        if(!new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator)) throw new InvalidOperationException("The guest diagnostic requires its authorized administrator controller.");
    }
    static void CheckOwner(Process process) {
        IntPtr token;if(!OpenProcessToken(process.Handle,8,out token)) throw new InvalidOperationException("The guest process token could not be inspected.");
        try {using(var identity=new WindowsIdentity(token)) if(!identity.User.Equals(new NTAccount(Environment.MachineName,"LaqayLab").Translate(typeof(SecurityIdentifier)))) throw new InvalidOperationException("Unexpected guest process owner.");}
        finally {CloseHandle(token);}
    }
    public static object Inspect(string labId,string runId,int appPid,int providerPid,uint providerThreadId,int sessionId) {
        Guard(labId,runId);
        using(var app=Process.GetProcessById(appPid)) using(var provider=Process.GetProcessById(providerPid)) {
            if(sessionId<=0 || app.SessionId!=sessionId || provider.SessionId!=sessionId || !app.MainModule.FileName.StartsWith(@"C:\LaqayLab\App\",StringComparison.OrdinalIgnoreCase) || Path.GetFileName(app.MainModule.FileName)!="laqay.exe" ||
                !String.Equals(provider.MainModule.FileName,Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),@"WindowsPowerShell\v1.0\powershell.exe"),StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Unexpected guest diagnostic process identity.");
            CheckOwner(app);CheckOwner(provider);bool threadFound=false;foreach(ProcessThread thread in provider.Threads) {if(thread.Id==providerThreadId) threadFound=true;thread.Dispose();}
            if(!threadFound) throw new InvalidOperationException("The delayed provider thread does not belong to its task.");
            IntPtr token,session=IntPtr.Zero;if(!OpenProcessToken(Process.GetCurrentProcess().Handle,0x28,out token)) throw new InvalidOperationException("The guest diagnostic token could not be opened.");
            Privilege previous=new Privilege();bool changed=false;
            try {
                Luid luid;if(!LookupPrivilegeValueW(null,"SeDebugPrivilege",out luid)) throw new InvalidOperationException("The guest debug privilege is unavailable.");
                var desired=new Privilege {count=1,luid=luid,attributes=2};uint needed;
                if(!AdjustTokenPrivileges(token,false,ref desired,(uint)Marshal.SizeOf(typeof(Privilege)),out previous,out needed) || Marshal.GetLastWin32Error()!=0) throw new InvalidOperationException("The guest diagnostic privilege could not be enabled.");changed=true;
                session=OpenThreadWaitChainSession(0,IntPtr.Zero);if(session==IntPtr.Zero) throw new InvalidOperationException("The guest wait-chain session could not be opened.");
                var observations=new List<object>();bool confirmed=false;
                foreach(ProcessThread thread in app.Threads) {
                    try {
                        uint count=16;bool cycle;var nodes=new Node[16];bool success=GetThreadWaitChain(session,UIntPtr.Zero,1,(uint)thread.Id,ref count,nodes,out cycle);int error=success?0:Marshal.GetLastWin32Error();
                        var observed=new List<object>();bool source=false,owner=false;
                        for(int i=0;i<Math.Min(count,16);i++) {var node=nodes[i];observed.Add(new {Type=node.Type,Status=node.Status,ProcessId=node.Type==8?node.ProcessId:0,ThreadId=node.Type==8?node.ThreadId:0});
                            if(i==0 && node.Type==8 && node.ProcessId==appPid) source=true;
                            if(i>0 && node.Type==8 && node.ProcessId==providerPid && node.ThreadId==providerThreadId) owner=true;
                        }
                        observations.Add(new {ThreadId=thread.Id,Success=success,Error=error,NodeCount=count,Cycle=cycle,Nodes=observed});if(success && source && owner) confirmed=true;
                    } finally {thread.Dispose();}
                }
                var contexts=InspectClipboardContexts(app);
                return new {LabId=labId,RunId=runId,Confirmed=confirmed || contexts.Confirmed,ConfirmedByWaitChain=confirmed,ConfirmedByContexts=contexts.Confirmed,ContextThreadId=contexts.ThreadId,ContextDetails=contexts.Details,ApplicationPid=appPid,ProviderPid=providerPid,ProviderThreadId=providerThreadId,SessionId=sessionId,Threads=observations};
            } finally {
                if(session!=IntPtr.Zero) CloseThreadWaitChainSession(session);
                if(changed) {Privilege ignored;uint needed;if(!AdjustTokenPrivileges(token,false,ref previous,(uint)Marshal.SizeOf(typeof(Privilege)),out ignored,out needed) || Marshal.GetLastWin32Error()!=0) {CloseHandle(token);throw new InvalidOperationException("The temporary guest debug privilege could not be restored.");}}
                CloseHandle(token);
            }
        }
    }
    public static string InspectJson(string labId,string runId,int appPid,int providerPid,uint providerThreadId,int sessionId) {
        try {return new JavaScriptSerializer().Serialize(Inspect(labId,runId,appPid,providerPid,providerThreadId,sessionId));}
        catch(ArgumentException) {return new JavaScriptSerializer().Serialize(new {LabId=labId,RunId=runId,Confirmed=false,ProcessExited=true});}
    }
}
