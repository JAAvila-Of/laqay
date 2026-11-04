using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Automation;
using Microsoft.Win32;

public static partial class LaqayGuestDesktop {
    static RealApplication realApplication;
    [StructLayout(LayoutKind.Sequential)] struct RealStartup {
        public uint size;public IntPtr reserved,desktop,title;
        public uint x,y,width,height,columns,rows,fill,flags;
        public ushort show,reservedBytes;public IntPtr reservedPointer,input,output,error;
    }
    [StructLayout(LayoutKind.Sequential)] struct RealProcess {public IntPtr process,thread;public uint pid,tid;}
    [StructLayout(LayoutKind.Sequential)] struct RealAccounting {
        public long user,kernel,periodUser,periodKernel;public uint faults,total,active,terminated;
    }
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcessW(string executable,StringBuilder command,IntPtr processSecurity,IntPtr threadSecurity,bool inherit,uint flags,IntPtr environment,string directory,ref RealStartup startup,out RealProcess process);
    [DllImport("kernel32.dll",SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool IsProcessInJob(IntPtr process,IntPtr job,out bool contained);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job,int type,out RealAccounting accounting,uint size,IntPtr needed);
    [DllImport("kernel32.dll",EntryPoint="QueryInformationJobObject",SetLastError=true)] static extern bool RealQueryJobProcesses(IntPtr job,int type,IntPtr data,uint size,out uint needed);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] static extern int GetPackageFullName(IntPtr process,ref uint length,StringBuilder name);
    [DllImport("kernel32.dll",EntryPoint="OpenProcess",SetLastError=true)] static extern IntPtr RealOpenProcess(uint access,bool inherit,uint pid);
    [DllImport("kernel32.dll")] static extern bool ProcessIdToSessionId(uint process,out uint session);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetWindowTextW(IntPtr window,StringBuilder text,int length);
    [DllImport("user32.dll")] [return:MarshalAs(UnmanagedType.Bool)] static extern bool IsWindowVisible(IntPtr window);

    public static string RealFixturePath(string kind,string runRoot) {
        if((kind!="Notepad" && kind!="Edge" && kind!="Terminal") || runRoot==null || !Regex.IsMatch(runRoot,@"^C:\\LaqayLab\\Runs\\[a-f0-9]{32}$"))
            throw new ArgumentException("An exact owned guest run and supported application are required.");
        return Path.Combine(runRoot,"real-apps",kind);
    }
    public static string RealBrowserFixture(string runId) {
        if(runId==null || !Regex.IsMatch(runId,"^[a-f0-9]{32}$")) throw new ArgumentException("Invalid browser fixture identity.");
        return "<!doctype html><html lang=\"en\"><meta charset=\"utf-8\"><title>Laqay real app "+runId+
            "</title><label for=\"laqay-real-input\">Laqay real application input</label><textarea id=\"laqay-real-input\" aria-label=\"Laqay real application input\" style=\"display:block;width:600px;height:300px\"></textarea></html>";
    }
    public static object RealApplicationAbi() {return new {Startup=Marshal.SizeOf(typeof(RealStartup)),Process=Marshal.SizeOf(typeof(RealProcess)),Accounting=Marshal.SizeOf(typeof(RealAccounting))};}
    public static string RealNotepadStatePath(string localAppData) {
        if(!String.Equals(localAppData,@"C:\Users\LaqayLab\AppData\Local",StringComparison.OrdinalIgnoreCase)) throw new ArgumentException("Packaged application state isolation requires the exact disposable guest profile.");
        return Path.Combine(localAppData,@"Packages\Microsoft.WindowsNotepad_8wekyb3d8bbwe\LocalState");
    }
    public static string RealTerminalStatePath(string localAppData) {
        RealNotepadStatePath(localAppData);
        return Path.Combine(localAppData,@"Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState");
    }
    public static string RealTerminalSettings() {return "{\"actions\":[{\"command\":\"paste\",\"keys\":\"ctrl+v\"}]}";}
    public static string RealTerminalReceiverJobName(string labId,string runId,int ownerPid) {
        if(labId==null || runId==null || !Regex.IsMatch(labId,"^[a-f0-9]{32}$") || !Regex.IsMatch(runId,"^[a-f0-9]{32}$") || ownerPid<=0) throw new ArgumentException("Unexpected Terminal receiver Job identity.");
        return @"Local\LaqayTerminalReceiver-"+labId+"-"+runId+"-"+ownerPid;
    }
    // Prefix declarations follow UIAutomationClient.idl in the Windows SDK.
    // Unused cache/walker pointers preserve their native vtable positions.
    [StructLayout(LayoutKind.Sequential)] struct RealUiaPoint {public int x,y;}
    [ComImport,Guid("352ffba8-0973-437c-a61f-f64cafd81df9"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] interface RealUiaCondition {}
    [ComImport,Guid("d22108aa-8ac5-49a5-837b-37bbb3d7591e"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] interface RealUiaElement {
        void SetFocus();
        [return:MarshalAs(UnmanagedType.SafeArray,SafeArraySubType=VarEnum.VT_I4)] int[] GetRuntimeId();
        RealUiaElement FindFirst(int scope,RealUiaCondition condition);
        RealUiaElements FindAll(int scope,RealUiaCondition condition);
        RealUiaElement FindFirstBuildCache(int scope,RealUiaCondition condition,IntPtr cache);
        RealUiaElements FindAllBuildCache(int scope,RealUiaCondition condition,IntPtr cache);
        RealUiaElement BuildUpdatedCache(IntPtr cache);
        [return:MarshalAs(UnmanagedType.Struct)] object GetCurrentPropertyValue(int property);
    }
    [ComImport,Guid("14314595-b4bc-4055-95f2-58f2e42c9855"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] interface RealUiaElements {
        int GetLength();RealUiaElement GetElement(int index);
    }
    [ComImport,Guid("30cbe57d-d9d0-452a-ab13-7ac5ac4825ee"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] interface RealUiaClient {
        [return:MarshalAs(UnmanagedType.Bool)] bool CompareElements(RealUiaElement first,RealUiaElement second);
        [return:MarshalAs(UnmanagedType.Bool)] bool CompareRuntimeIds([MarshalAs(UnmanagedType.SafeArray,SafeArraySubType=VarEnum.VT_I4)] int[] first,[MarshalAs(UnmanagedType.SafeArray,SafeArraySubType=VarEnum.VT_I4)] int[] second);
        RealUiaElement GetRootElement();RealUiaElement ElementFromHandle(IntPtr handle);
        RealUiaElement ElementFromPoint(RealUiaPoint point);RealUiaElement GetFocusedElement();
        RealUiaElement GetRootElementBuildCache(IntPtr cache);
        RealUiaElement ElementFromHandleBuildCache(IntPtr handle,IntPtr cache);
        RealUiaElement ElementFromPointBuildCache(RealUiaPoint point,IntPtr cache);
        RealUiaElement GetFocusedElementBuildCache(IntPtr cache);
        IntPtr CreateTreeWalker(RealUiaCondition condition);
        IntPtr GetControlViewWalker();IntPtr GetContentViewWalker();IntPtr GetRawViewWalker();
        RealUiaCondition GetRawViewCondition();RealUiaCondition GetControlViewCondition();RealUiaCondition GetContentViewCondition();
        IntPtr CreateCacheRequest();RealUiaCondition CreateTrueCondition();
    }
    public static object RealNativeProbeContract() {
        return new {Client=typeof(RealUiaClient).GUID.ToString(),Element=typeof(RealUiaElement).GUID.ToString(),
            ClientPrefix=typeof(RealUiaClient).GetMethods().Length,ElementPrefix=typeof(RealUiaElement).GetMethods().Length,Point=Marshal.SizeOf(typeof(RealUiaPoint))};
    }
    static void ReleaseRealCom(object value) {if(value!=null && Marshal.IsComObject(value)) Marshal.ReleaseComObject(value);}
    static object ProbeRealNativeWindow(IntPtr window,int expectedPid) {
        if(Thread.CurrentThread.GetApartmentState()!=ApartmentState.MTA) throw new InvalidOperationException("Native automation probing requires the owned MTA worker.");
        RealUiaClient client=null;RealUiaElement root=null;RealUiaCondition condition=null;RealUiaElements elements=null;
        string stage="Activate",error=null;bool completed=false;int count=0,rootPid=0;var controls=new System.Collections.Generic.List<object>();
        try {
            client=(RealUiaClient)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("ff48dba4-60ef-4201-aa87-54103eef594e"),true));
            stage="ElementFromHandle";root=client.ElementFromHandle(window);
            stage="RootProcessId";rootPid=Convert.ToInt32(root.GetCurrentPropertyValue(30002));
            if(rootPid!=expectedPid) throw new InvalidOperationException("Native automation root differs from the verified application process.");
            stage="CreateTrueCondition";condition=client.CreateTrueCondition();
            stage="FindAll";elements=root.FindAll(4,condition);
            stage="ElementCount";count=elements.GetLength();
            if(count<0 || count>1024) throw new InvalidOperationException("The native automation subtree exceeds the diagnostic bound.");
            for(int index=0;index<count;index++) {
                RealUiaElement element=null;
                try {
                    stage="ElementProperties";element=elements.GetElement(index);
                    int type=Convert.ToInt32(element.GetCurrentPropertyValue(30003));
                    if(controls.Count<24 && (type==50004 || type==50030 || type==50019)) controls.Add(new {
                        Type=type,Pid=Convert.ToInt32(element.GetCurrentPropertyValue(30002)),
                        Class=Convert.ToString(element.GetCurrentPropertyValue(30012)),
                        Enabled=Convert.ToBoolean(element.GetCurrentPropertyValue(30010)),
                        Offscreen=Convert.ToBoolean(element.GetCurrentPropertyValue(30022)),
                        Focusable=Convert.ToBoolean(element.GetCurrentPropertyValue(30009))});
                }finally{ReleaseRealCom(element);}
            }
            stage="Completed";completed=true;
        }catch(Exception failure){error=failure.ToString();}
        finally{ReleaseRealCom(elements);ReleaseRealCom(condition);ReleaseRealCom(root);ReleaseRealCom(client);}
        return new {Completed=completed,Stage=stage,Error=error,RootPid=rootPid,Count=count,Controls=controls.ToArray()};
    }
    public static object RealAutomationContract() {
        var worker=new RealAutomation();int caller=Thread.CurrentThread.ManagedThreadId;
        int first=worker.Call("First",()=>Thread.CurrentThread.ManagedThreadId);
        bool mta=worker.Call("Apartment",()=>Thread.CurrentThread.GetApartmentState()==ApartmentState.MTA);
        bool same=worker.Call("Second",()=>Thread.CurrentThread.ManagedThreadId==first);
        bool propagated=false;try{worker.Call<int>("Failure",()=>{throw new InvalidOperationException("Expected worker rejection.");});}catch(InvalidOperationException){propagated=true;}
        bool stopped=worker.Stop();bool rejected=false;try{worker.Call("Stopped",()=>0);}catch(InvalidOperationException){rejected=true;}
        return new {Separate=first!=caller,Mta=mta,Stable=same,ExceptionPropagated=propagated,Stopped=stopped,RejectedAfterStop=rejected};
    }
    sealed class RealAutomation {
        readonly System.Collections.Concurrent.BlockingCollection<Action> queue=new System.Collections.Concurrent.BlockingCollection<Action>();
        readonly Thread thread;internal string Stage,Failure;
        public RealAutomation() {thread=new Thread(()=>{foreach(var action in queue.GetConsumingEnumerable()) action();});thread.IsBackground=true;thread.Name="Laqay guest real app automation";thread.SetApartmentState(ApartmentState.MTA);thread.Start();}
        public T Call<T>(string stage,Func<T> action) {
            if(queue.IsAddingCompleted) throw new InvalidOperationException("Real application automation has stopped.");
            var result=new System.Threading.Tasks.TaskCompletionSource<T>();
            queue.Add(()=>{Stage=stage;try{result.SetResult(action());}catch(Exception failure){Failure=Stage+": "+failure;result.SetException(failure);}});
            bool completed;try{completed=result.Task.Wait(10000);}catch(AggregateException){return result.Task.GetAwaiter().GetResult();}
            if(!completed) throw new TimeoutException("Real application automation timed out at "+Stage+".");
            return result.Task.GetAwaiter().GetResult();
        }
        public object Info() {return new {ThreadId=thread.ManagedThreadId,Apartment=thread.GetApartmentState().ToString(),Stage=Stage,Failure=Failure};}
        public bool Stop() {queue.CompleteAdding();return thread.Join(5000);}
    }
    static RealApplication OwnedRealApplication() {
        MatrixGuard();if(realApplication==null) throw new InvalidOperationException("No real application is owned.");
        realApplication.RequireReady();return realApplication;
    }
    public static object BeginRealApplication(string kind,string runRoot,string notepadExecutable,string packageName) {
        MatrixGuard();if(realApplication!=null) throw new InvalidOperationException("A real application is already owned.");
        realApplication=new RealApplication(kind,runRoot,notepadExecutable,packageName);realApplication.Start();return realApplication.Info();
    }
    public static void FocusRealApplication() {OwnedRealApplication().Focus();}
    public static object RealApplicationState() {return OwnedRealApplication().State();}
    public static object RealApplicationDiagnostics() {MatrixGuard();return realApplication==null?null:realApplication.Info();}
    public static string RealApplicationText() {return OwnedRealApplication().ReadText();}
    public static object RealApplicationTextClipboard(string text) {OwnedRealApplication();return PublishNativeUnicodeFixture(text);}
    public static void RealApplicationChord(params ushort[] keys) {
        var owned=OwnedRealApplication();owned.RequireFocus();
        var inputs=new System.Collections.Generic.List<Input>();
        foreach(ushort key in keys) inputs.Add(new Input {type=1,value=new Union {key=new Key {vk=key}}});
        for(int i=keys.Length-1;i>=0;i--) inputs.Add(new Input {type=1,value=new Union {key=new Key {vk=keys[i],flags=2}}});
        Send(inputs.ToArray());
    }
    public static bool RealNotepadSaved(string expected) {
        var owned=OwnedRealApplication();if(owned.kind!="Notepad") throw new InvalidOperationException("No owned Notepad document.");
        try {return File.ReadAllText(owned.document)==expected;} catch(IOException) {return false;}
    }
    public static object BindRealTerminalReceiver(int pid) {return OwnedRealApplication().BindReceiver(pid);}
    public static object EndRealApplication() {
        var owned=realApplication;realApplication=null;
        try {return owned==null?null:owned.Stop();}finally {EndNativeUnicodeFixture();}
    }

    sealed class RealApplication {
        internal readonly string kind,document;
        readonly string root,runId,target,launcher,expectedPackage,tag,arguments;
        readonly DateTime started=DateTime.UtcNow;
        Process bootstrap,app,receiver;IntPtr ownedJob,launcherJob,receiverJob,window;string receiverJobName;bool created,assignedBeforeResume,adopted,ready;
        string receiverScriptHash,terminalSettingsHash;
        RealAutomation automation;object nativeProbe;
        string packageState,stateBackup,stateOriginal,stateFinal;bool stateExisted,stateIsolated,stateRestored;
        const string edgePolicyPath=@"SOFTWARE\Policies\Microsoft\Edge";
        bool edgePoliciesConfigured;
        readonly System.Collections.Generic.HashSet<uint> priorEdgePids=new System.Collections.Generic.HashSet<uint>();
        readonly System.Collections.Generic.List<object> priorTerminalProcesses=new System.Collections.Generic.List<object>();
        readonly System.Collections.Generic.List<object> priorEdgeProcesses=new System.Collections.Generic.List<object>();
        string marker,version,sha,packageIdentity;int appPid;
        readonly System.Collections.Generic.List<object> candidates=new System.Collections.Generic.List<object>();
        readonly System.Collections.Generic.HashSet<string> candidateStates=new System.Collections.Generic.HashSet<string>();
        static string Quote(string value) {if(value.IndexOfAny(new[]{'"','\0','\r','\n'})>=0) throw new ArgumentException("Unsafe fixture argument.");return "\""+value+"\"";}
        static string Hash(string path) {using(var input=File.OpenRead(path)) using(var hash=System.Security.Cryptography.SHA256.Create()) return BitConverter.ToString(hash.ComputeHash(input)).Replace("-","");}
        public RealApplication(string name,string runRoot,string notepad,string package) {
            kind=name;root=RealFixturePath(name,runRoot);runId=Path.GetFileName(runRoot);
            if(kind=="Notepad") {
                if(package==null || !Regex.IsMatch(package,@"^Microsoft\.WindowsNotepad_[A-Za-z0-9._-]+$")) throw new ArgumentException("The registered Notepad package is required.");
                string packageRoot=Path.Combine(@"C:\Program Files\WindowsApps",package);
                target=Path.GetFullPath(notepad);
                if(!target.StartsWith(packageRoot+"\\",StringComparison.OrdinalIgnoreCase) || !String.Equals(Path.GetFileName(target),"Notepad.exe",StringComparison.OrdinalIgnoreCase)) throw new ArgumentException("Unexpected registered Notepad executable.");
                expectedPackage=package;launcher=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),"System32","notepad.exe");
                document=Path.Combine(root,"Laqay-"+runId+".txt");tag=Path.GetFileNameWithoutExtension(document);arguments=Quote(document);
            } else if(kind=="Terminal") {
                if(package==null || !Regex.IsMatch(package,@"^Microsoft\.WindowsTerminal_[A-Za-z0-9._-]+$")) throw new ArgumentException("The registered Terminal package is required.");
                string packageRoot=Path.Combine(@"C:\Program Files\WindowsApps",package);
                target=Path.GetFullPath(notepad);
                if(!target.StartsWith(packageRoot+"\\",StringComparison.OrdinalIgnoreCase) || !String.Equals(Path.GetFileName(target),"WindowsTerminal.exe",StringComparison.OrdinalIgnoreCase)) throw new ArgumentException("Unexpected registered Terminal executable.");
                expectedPackage=package;launcher=target;document=Path.Combine(root,"GuestTerminalReceiver.ps1");tag="Laqay Terminal "+runId;
                var markerData=new System.Web.Script.Serialization.JavaScriptSerializer().Deserialize<System.Collections.Generic.Dictionary<string,object>>(File.ReadAllText(@"C:\LaqayLab\ready.json"));
                string lab=(string)markerData["LabId"];if(!Regex.IsMatch(lab,"^[a-f0-9]{32}$")) throw new InvalidOperationException("Unexpected Terminal lab marker.");
                receiverJobName=RealTerminalReceiverJobName(lab,runId,Process.GetCurrentProcess().Id);
                string powershell=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),@"System32\WindowsPowerShell\v1.0\powershell.exe");
                arguments="--window new new-tab --title "+Quote(tag)+" --suppressApplicationTitle --startingDirectory "+Quote(root)+" "+Quote(powershell)+" -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "+Quote(document)+" -LabId "+lab+" -RunId "+runId+" -OwnerPid "+Process.GetCurrentProcess().Id;
            } else {
                foreach(var hive in new[]{Registry.LocalMachine,Registry.CurrentUser}) foreach(string suffix in new[]{"",@"\Recommended"})
                    using(var key=hive.OpenSubKey(@"SOFTWARE\Policies\Microsoft\Edge"+suffix))
                        if(key!=null && key.GetValue("UserDataDir")!=null) throw new InvalidOperationException("An Edge user-data policy prevents isolated profile testing.");
                foreach(string candidate in new[]{@"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",@"C:\Program Files\Microsoft\Edge\Application\msedge.exe"}) if(File.Exists(candidate)){target=candidate;break;}
                if(target==null) throw new InvalidOperationException("The installed Edge executable was not found.");
                launcher=target;document=Path.Combine(root,"input.html");tag="Laqay real app "+runId;
                arguments="--no-first-run --disable-background-mode --force-renderer-accessibility --new-window --user-data-dir="+Quote(Path.Combine(root,"profile"))+" "+Quote(new Uri(document).AbsoluteUri);
            }
        }
        public void Start() {
            if(!Directory.Exists(Path.GetDirectoryName(Path.GetDirectoryName(root))) || Directory.Exists(root)) throw new InvalidOperationException("Unexpected or reused real application fixture.");
            if((File.GetAttributes(target)&FileAttributes.ReparsePoint)!=0 || (File.GetAttributes(launcher)&FileAttributes.ReparsePoint)!=0) throw new InvalidOperationException("A real application executable is a reparse point.");
            if(kind=="Notepad") foreach(var existing in Process.GetProcessesByName("Notepad")) using(existing) if(existing.SessionId==Process.GetCurrentProcess().SessionId) throw new InvalidOperationException("Refusing an existing Notepad session.");
            if(kind=="Terminal") {
                foreach(var existing in Process.GetProcessesByName("WindowsTerminal")) using(existing) {
                    if(existing.SessionId!=Process.GetCurrentProcess().SessionId) continue;
                    try {priorTerminalProcesses.Add(new {Pid=existing.Id,SessionId=existing.SessionId,Executable=existing.MainModule.FileName,StartedUtc=existing.StartTime.ToUniversalTime().ToString("o"),Window=existing.MainWindowHandle.ToInt64()});}
                    catch(System.ComponentModel.Win32Exception failure){priorTerminalProcesses.Add(new {Pid=existing.Id,Error=failure.NativeErrorCode});}
                }
                if(priorTerminalProcesses.Count!=0) throw new InvalidOperationException("Refusing an existing Terminal session before state isolation.");
            }
            version=FileVersionInfo.GetVersionInfo(target).FileVersion;sha=Hash(target);
            Directory.CreateDirectory(root);created=true;marker="LaqayRealApplication:"+runId+":"+kind+":"+Process.GetCurrentProcess().Id;
            File.WriteAllText(Path.Combine(root,"owner.txt"),marker);
            if(kind=="Terminal") {File.Copy(Path.Combine(Path.GetDirectoryName(Path.GetDirectoryName(root)),"GuestTerminalReceiver.ps1"),document);receiverScriptHash=Hash(document);}
            else File.WriteAllText(document,kind=="Edge"?RealBrowserFixture(runId):"",new UTF8Encoding(false));
            if(kind=="Notepad" || kind=="Terminal") IsolatePackagedState();
            if(kind=="Terminal"){Directory.CreateDirectory(packageState);string settings=Path.Combine(packageState,"settings.json");File.WriteAllText(settings,RealTerminalSettings(),new UTF8Encoding(false));terminalSettingsHash=Hash(settings);}
            if(kind=="Edge") VerifyEdgePolicies();
            ownedJob=NewJob();launcherJob=ownedJob;
            if(kind=="Terminal") receiverJob=NewJob(receiverJobName);
            var startup=new RealStartup {size=(uint)Marshal.SizeOf(typeof(RealStartup)),flags=1,show=1};RealProcess process;
            string workingDirectory=Path.GetDirectoryName(Path.GetDirectoryName(root));
            if(!CreateProcessW(launcher,new StringBuilder(Quote(launcher)+" "+arguments),IntPtr.Zero,IntPtr.Zero,false,4,IntPtr.Zero,workingDirectory,ref startup,out process)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(),"Cannot launch the installed application.");
            try {
                bootstrap=Process.GetProcessById((int)process.pid);var keepHandle=bootstrap.Handle;
                bool contained;
                if(!AssignProcessToJobObject(ownedJob,process.process) || !IsProcessInJob(process.process,ownedJob,out contained) || !contained) throw new InvalidOperationException("Cannot contain the launcher before resume.");
                assignedBeforeResume=true;if(ResumeThread(process.thread)==UInt32.MaxValue) throw new InvalidOperationException("Cannot resume the owned launcher.");
            } finally {CloseHandle(process.thread);CloseHandle(process.process);}
            var until=DateTime.UtcNow.AddSeconds(30);
            while(window==IntPtr.Zero && DateTime.UtcNow<until) {FindWindow();if(window==IntPtr.Zero) Thread.Sleep(100);}
            if(window==IntPtr.Zero) throw new InvalidOperationException("The installed application did not expose its uniquely tagged window.");
            bool inJob;
            if(!IsProcessInJob(app.Handle,ownedJob,out inJob)) throw new InvalidOperationException("Cannot verify the actual application Job.");
            if(!inJob) {
                if(kind!="Notepad") throw new InvalidOperationException("The actual application escaped its owned Job.");
                // Package activation may use a different OS Job hierarchy than
                // the launcher. Adopt only the newly tagged, verified process.
                ownedJob=NewJob();
                if(!AssignProcessToJobObject(ownedJob,app.Handle)) throw new InvalidOperationException("Cannot contain the activated Notepad process.");adopted=true;
            }
            if(!IsProcessInJob(app.Handle,ownedJob,out inJob) || !inJob) throw new InvalidOperationException("The actual application is not contained.");
            if(kind=="Notepad" || kind=="Terminal") {
                uint length=0;GetPackageFullName(app.Handle,ref length,null);
                if(length==0 || length>1024) throw new InvalidOperationException("Notepad has no registered runtime package identity.");
                var name=new StringBuilder((int)length);
                if(GetPackageFullName(app.Handle,ref length,name)!=0 || !String.Equals(name.ToString(),expectedPackage,StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Notepad runtime package identity differs from inventory.");
                packageIdentity=name.ToString();
            }
            if(Hash(target)!=sha) throw new InvalidOperationException("The executable changed during launch.");
            if(kind=="Terminal" && Hash(document)!=receiverScriptHash) throw new InvalidOperationException("The Terminal receiver changed during launch.");
            automation=new RealAutomation();
            nativeProbe=automation.Call("NativeProbe",()=>ProbeRealNativeWindow(window,appPid));
            ready=true;string last=null;
            while(DateTime.UtcNow<until) {
                try {Focus();if(kind=="Edge" && !Directory.Exists(Path.Combine(root,"profile","Default"))) throw new InvalidOperationException("The isolated Edge profile was not created.");return;}
                catch(ElementNotAvailableException failure){last=failure.Message;}
                catch(InvalidOperationException failure){last=failure.Message;}
                catch{ready=false;throw;}
                Thread.Sleep(100);
            }
            ready=false;throw new InvalidOperationException("The real editor did not become ready: "+last);
        }
        void FindWindow() {
            EnumWindows((candidate,parameter)=> {
                var title=new StringBuilder(512);GetWindowTextW(candidate,title,title.Capacity);
                bool tagged=title.ToString().IndexOf(tag,StringComparison.OrdinalIgnoreCase)>=0;
                uint pid;GetWindowThreadProcessId(candidate,out pid);Process found=null;
                try {
                    found=Process.GetProcessById((int)pid);
                    string image=found.MainModule.FileName;
                    bool matchesTarget=String.Equals(image,target,StringComparison.OrdinalIgnoreCase);
                    if((tagged || matchesTarget) && candidates.Count<32 && candidateStates.Add(pid+":"+title)) candidates.Add(new {Pid=pid,Image=image,Title=title.ToString(),TagMatched=tagged,Session=found.SessionId,Started=found.StartTime.ToUniversalTime().ToString("o"),MatchesTarget=matchesTarget});
                    if(!tagged || found.SessionId!=Process.GetCurrentProcess().SessionId || found.StartTime.ToUniversalTime()<started.AddSeconds(-1) || !matchesTarget || (kind=="Edge" && priorEdgePids.Contains(pid))) return true;
                    app=found;found=null;appPid=(int)pid;window=candidate;return false;
                }catch(ArgumentException){return true;}catch(System.ComponentModel.Win32Exception failure){if(tagged && candidates.Count<32 && candidateStates.Add(pid+":error")) candidates.Add(new {Pid=pid,Error=failure.NativeErrorCode});return true;}
                finally {if(found!=null) found.Dispose();}
            },IntPtr.Zero);
        }
        public void RequireReady() {
            if(!ready || app==null || app.HasExited) throw new InvalidOperationException("The owned real application is not ready.");
            uint pid;GetWindowThreadProcessId(window,out pid);bool contained;
            if(pid!=(uint)appPid || !IsProcessInJob(app.Handle,ownedJob,out contained) || !contained) throw new InvalidOperationException("The real application window or Job changed.");
        }
        bool OwnElement(AutomationElement element) {
            uint session;uint pid=(uint)element.Current.ProcessId;
            if(!ProcessIdToSessionId(pid,out session) || session!=(uint)Process.GetCurrentProcess().SessionId) return false;
            IntPtr process=RealOpenProcess(0x1000,false,pid);
            if(process==IntPtr.Zero) return false;
            try {bool contained;return IsProcessInJob(process,ownedJob,out contained) && contained;} finally {CloseHandle(process);}
        }
        AutomationElement Target() {
            automation.Stage="Target.FromHandle";
            var rootElement=AutomationElement.FromHandle(window);
            automation.Stage="Target.FindTabs";
            if(kind=="Notepad" && rootElement.FindAll(TreeScope.Descendants,new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.TabItem)).Count>1) throw new InvalidOperationException("Notepad restored unrelated tabs.");
            automation.Stage="Target.FindEditors";
            var candidates=rootElement.FindAll(TreeScope.Descendants,kind=="Terminal"?(Condition)new PropertyCondition(AutomationElement.ClassNameProperty,"TermControl"):kind=="Edge"?(Condition)new AndCondition(new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.Edit),new PropertyCondition(AutomationElement.NameProperty,"Laqay real application input")):
                new OrCondition(new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.Document),new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.Edit)));
            AutomationElement targetElement=null;
            foreach(AutomationElement element in candidates) {
                if(element.Current.IsOffscreen || !element.Current.IsEnabled || !element.Current.IsKeyboardFocusable || !OwnElement(element)) continue;
                object pattern;if(!element.TryGetCurrentPattern(ValuePattern.Pattern,out pattern) && !element.TryGetCurrentPattern(TextPattern.Pattern,out pattern)) continue;
                if(targetElement!=null) throw new InvalidOperationException("The real application editor target is ambiguous.");targetElement=element;
            }
            if(targetElement==null) throw new InvalidOperationException("The real application editor target is unavailable.");return targetElement;
        }
        bool FocusMatches(AutomationElement targetElement) {
            var focused=AutomationElement.FocusedElement;
            for(int depth=0;focused!=null && depth<16;depth++) {if(Automation.Compare(focused,targetElement)) return true;focused=TreeWalker.ControlViewWalker.GetParent(focused);}return false;
        }
        public void Focus() {
            automation.Call("Focus",()=>{FocusCore();return 0;});
        }
        void FocusCore() {
            RequireReady();if(GetForegroundWindow()!=window){ShowWindowAsync(window,3);SetForegroundWindow(window);Thread.Sleep(200);}
            var targetElement=Target();automation.Stage="Focus.SetFocus";targetElement.SetFocus();RequireFocusCore();
        }
        public void RequireFocus() {automation.Call("RequireFocus",()=>{RequireFocusCore();return 0;});}
        void RequireFocusCore() {RequireReady();if(GetForegroundWindow()!=window || !FocusMatches(Target())) throw new InvalidOperationException("The real application editor lost native/semantic focus.");}
        public string ReadText() {
            return automation.Call("ReadText",()=>ReadTextCore());
        }
        string ReadTextCore() {
            RequireFocusCore();object pattern;var element=Target();
            if(element.TryGetCurrentPattern(ValuePattern.Pattern,out pattern)) return ((ValuePattern)pattern).Current.Value;
            return ((TextPattern)element.GetCurrentPattern(TextPattern.Pattern)).DocumentRange.GetText(-1).TrimEnd('\r','\n');
        }
        object[] TargetDiagnostics() {
            if(automation==null) return new object[0];
            try{return automation.Call("Diagnostics",()=>TargetDiagnosticsCore());}catch(Exception failure){return new object[]{new {Error=failure.ToString()}};}
        }
        object[] TargetDiagnosticsCore() {
            var results=new System.Collections.Generic.List<object>();
            try {
                if(window==IntPtr.Zero || app==null || app.HasExited) return results.ToArray();
                var elements=AutomationElement.FromHandle(window).FindAll(TreeScope.Descendants,new OrCondition(new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.Document),new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.Edit),new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.TabItem),new PropertyCondition(AutomationElement.ClassNameProperty,"TermControl")));
                foreach(AutomationElement element in elements) {if(results.Count>=24) break;var value=element.Current;results.Add(new {Class=value.ClassName,Type=value.ControlType.ProgrammaticName,Id=value.AutomationId,Enabled=value.IsEnabled,Offscreen=value.IsOffscreen,Focusable=value.IsKeyboardFocusable,Pid=value.ProcessId});}
            }catch(Exception failure){results.Add(new {Error=failure.ToString()});}
            return results.ToArray();
        }
        public object Info() {var targets=TargetDiagnostics();return new {Kind=kind,Executable=target,FileVersion=version,ExecutableSha256=sha,PackageIdentity=packageIdentity,ExpectedPackage=expectedPackage,Pid=appPid,BootstrapPid=bootstrap==null?0:bootstrap.Id,Window=window.ToInt64(),LauncherAssignedBeforeResume=assignedBeforeResume,PackageProcessAdopted=adopted,Ready=ready,FixtureRoot=root,ProfileScope=kind=="Edge"?"Owned run directory":"Disposable guest user",Candidates=candidates.ToArray(),Targets=targets,Automation=automation==null?null:automation.Info(),NativeProbe=nativeProbe,NotepadState=new {Isolated=stateIsolated,Existed=stateExisted,OriginalFingerprint=stateOriginal},TerminalSettingsSha256=terminalSettingsHash,TerminalReceiverScriptSha256=receiverScriptHash,TerminalReceiverJobName=receiverJobName,TerminalState=new {Isolated=stateIsolated,Existed=stateExisted,OriginalFingerprint=stateOriginal},EdgePoliciesConfigured=edgePoliciesConfigured,PriorEdgeProcesses=priorEdgeProcesses.ToArray(),PriorTerminalProcesses=priorTerminalProcesses.ToArray()};}
        public object State() {
            return automation.Call("State",()=>StateCore());
        }
        public object BindReceiver(int pid) {
            RequireReady();if(kind!="Terminal" || pid<=0 || (receiver!=null && receiver.Id!=pid)) throw new InvalidOperationException("Unexpected Terminal receiver process.");
            if(receiver==null) {
                var candidate=Process.GetProcessById(pid);bool contained=false;
                try {
                    string expected=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),@"System32\WindowsPowerShell\v1.0\powershell.exe");
                    int actualSession=candidate.SessionId,expectedSession=Process.GetCurrentProcess().SessionId;
                    DateTime actualStart=candidate.StartTime.ToUniversalTime(),earliestStart=started.AddSeconds(-1);
                    string actualImage=candidate.MainModule.FileName;
                    bool queried=IsProcessInJob(candidate.Handle,receiverJob,out contained);
                    int queryError=queried?0:Marshal.GetLastWin32Error();
                    if(actualSession!=expectedSession || actualStart<earliestStart || !String.Equals(actualImage,expected,StringComparison.OrdinalIgnoreCase) || !queried || !contained) {
                        string proof=new System.Web.Script.Serialization.JavaScriptSerializer().Serialize(new {
                            Pid=pid,SessionId=actualSession,ExpectedSessionId=expectedSession,StartedUtc=actualStart.ToString("o"),
                            EarliestStartUtc=earliestStart.ToString("o"),Executable=actualImage,ExpectedExecutable=expected,
                            JobName=receiverJobName,JobQuerySucceeded=queried,JobQueryError=queryError,Contained=contained});
                        throw new InvalidOperationException("The Terminal receiver is not a new owned PowerShell process: "+proof);
                    }
                    receiver=candidate;candidate=null;
                }finally{if(candidate!=null) candidate.Dispose();}
            }
            return new {Pid=receiver.Id,SessionId=receiver.SessionId,Executable=receiver.MainModule.FileName,OwnedJob=true,JobName=receiverJobName,ScriptSha256=receiverScriptHash};
        }
        object StateCore() {
            RequireReady();var element=Target();var gui=new FolderGuiInfo {size=(uint)Marshal.SizeOf(typeof(FolderGuiInfo))};
            if(!GetGUIThreadInfo(0,ref gui)) throw new InvalidOperationException("Cannot inspect real application native focus.");
            return new {Pid=appPid,Foreground=GetForegroundWindow()==window,Focused=FocusMatches(element),GuiFlags=gui.flags,MenuOwner=gui.menuOwner.ToInt64(),
                FocusWindow=gui.focus.ToInt64(),FocusWithinWindow=gui.focus==window || IsChild(window,gui.focus),TargetClass=element.Current.ClassName,TargetType=element.Current.ControlType.ProgrammaticName,ClipboardSequence=GetClipboardSequenceNumber()};
        }
        static IntPtr NewJob(string name=null) {
            IntPtr value=CreateJobObjectW(IntPtr.Zero,name);int error=Marshal.GetLastWin32Error();
            if(value==IntPtr.Zero) throw new InvalidOperationException("Cannot create a real application Job.");
            if(name!=null && error==183){CloseHandle(value);throw new InvalidOperationException("Refusing an existing receiver Job.");}
            var limits=new JobLimits();limits.basic.flags=0x2000;
            if(!SetInformationJobObject(value,9,ref limits,(uint)Marshal.SizeOf(typeof(JobLimits)))) {CloseHandle(value);throw new InvalidOperationException("Cannot configure the real application Job.");}return value;
        }
        static uint Active(IntPtr job) {if(job==IntPtr.Zero) return 0;RealAccounting value;if(!QueryInformationJobObject(job,1,out value,(uint)Marshal.SizeOf(typeof(RealAccounting)),IntPtr.Zero)) throw new InvalidOperationException("Cannot inspect the real application Job.");return value.active;}
        static void SafeTree(string directory) {
            if((File.GetAttributes(directory)&FileAttributes.ReparsePoint)!=0) throw new InvalidOperationException("A fixture directory is a reparse point.");
            foreach(string path in Directory.GetFileSystemEntries(directory)) {var attrs=File.GetAttributes(path);if((attrs&FileAttributes.ReparsePoint)!=0) throw new InvalidOperationException("A fixture entry is a reparse point.");if((attrs&FileAttributes.Directory)!=0) SafeTree(path);}
        }
        static void NoReparseAncestors(string directory) {
            for(var item=new DirectoryInfo(directory);item!=null;item=item.Parent) if(item.Exists && (item.Attributes&FileAttributes.ReparsePoint)!=0) throw new InvalidOperationException("A Packaged application state ancestor is a reparse point.");
        }
        static string StateFingerprint(string directory) {
            if(!Directory.Exists(directory)) {if(File.Exists(directory)) throw new InvalidOperationException("The Packaged application state path is not a directory.");return "absent";}
            SafeTree(directory);
            var entries=new System.Collections.Generic.List<string>();long bytes=0;
            foreach(string path in Directory.GetDirectories(directory,"*",SearchOption.AllDirectories)) entries.Add("D:"+path.Substring(directory.Length));
            foreach(string path in Directory.GetFiles(directory,"*",SearchOption.AllDirectories)) {
                bytes+=new FileInfo(path).Length;if(bytes>128*1024*1024 || entries.Count>=1024) throw new InvalidOperationException("The Packaged application state exceeds the fixture budget.");
                entries.Add("F:"+path.Substring(directory.Length)+":"+Hash(path));
            }
            entries.Sort(StringComparer.Ordinal);
            using(var digest=System.Security.Cryptography.SHA256.Create()) return BitConverter.ToString(digest.ComputeHash(Encoding.UTF8.GetBytes(String.Join("\n",entries.ToArray())))).Replace("-","");
        }
        void CheckStatePaths() {
            string expected=kind=="Terminal"?RealTerminalStatePath(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)):RealNotepadStatePath(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData));
            if(packageState!=expected || stateBackup!=Path.Combine(root,"packaged-state-backup")) throw new InvalidOperationException("Unexpected packaged application state backup identity.");
            NoReparseAncestors(packageState);NoReparseAncestors(root);
        }
        void IsolatePackagedState() {
            packageState=kind=="Terminal"?RealTerminalStatePath(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)):RealNotepadStatePath(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData));stateBackup=Path.Combine(root,"packaged-state-backup");
            CheckStatePaths();
            if(kind=="Terminal" && !Directory.Exists(Path.GetDirectoryName(packageState))) Directory.CreateDirectory(Path.GetDirectoryName(packageState));
            if(!Directory.Exists(Path.GetDirectoryName(packageState)) || Directory.Exists(stateBackup) || File.Exists(stateBackup)) throw new InvalidOperationException("Unexpected packaged application state package or reused backup.");
            stateOriginal=StateFingerprint(packageState);stateExisted=Directory.Exists(packageState);
            File.WriteAllText(Path.Combine(root,"packaged-state-journal.txt"),"LocalState="+packageState+"\nBackup="+stateBackup+"\nOriginalFingerprint="+stateOriginal+"\nExisted="+stateExisted);
            if(stateExisted) Directory.Move(packageState,stateBackup);
            stateIsolated=true;
        }
        void RestorePackagedState() {
            if(!stateIsolated) return;
            CheckStatePaths();
            if(File.ReadAllText(Path.Combine(root,"owner.txt"))!=marker) throw new InvalidOperationException("The Packaged application state backup lost its fixture owner.");
            foreach(var process in Process.GetProcessesByName(kind=="Terminal"?"WindowsTerminal":"Notepad")) using(process) if(process.SessionId==Process.GetCurrentProcess().SessionId) throw new InvalidOperationException("Cannot restore packaged state while an application process remains.");
            if(stateExisted && StateFingerprint(stateBackup)!=stateOriginal) throw new InvalidOperationException("The original Packaged application state backup changed.");
            if(Directory.Exists(packageState)){SafeTree(packageState);Directory.Delete(packageState,true);}
            if(stateExisted) Directory.Move(stateBackup,packageState);
            stateFinal=StateFingerprint(packageState);stateRestored=stateFinal==stateOriginal;
            if(!stateRestored) throw new InvalidOperationException("Packaged application state restoration did not preserve its fingerprint.");
        }
        void VerifyEdgePolicies() {
            RealNotepadStatePath(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData));
            foreach(var process in Process.GetProcessesByName("msedge")) using(process) {
                try {
                    if(process.SessionId!=Process.GetCurrentProcess().SessionId) continue;
                    uint pid=(uint)process.Id;priorEdgePids.Add(pid);
                    var windows=new System.Collections.Generic.List<long>();
                    EnumWindows((handle,parameter)=>{uint owner;GetWindowThreadProcessId(handle,out owner);if(owner==pid && IsWindowVisible(handle)) windows.Add(handle.ToInt64());return true;},IntPtr.Zero);
                    priorEdgeProcesses.Add(new {Pid=pid,Image=process.MainModule.FileName,VisibleWindows=windows.ToArray()});
                }catch(InvalidOperationException){}catch(System.ComponentModel.Win32Exception failure){priorEdgeProcesses.Add(new {Pid=process.Id,Error=failure.NativeErrorCode});}
            }
            if(!File.Exists(Path.Combine(Path.GetDirectoryName(Path.GetDirectoryName(root)),"edge-policy-scope.json"))) throw new InvalidOperationException("Missing administrative guest policy scope.");
            using(var user=Registry.CurrentUser.OpenSubKey(edgePolicyPath)) {
                foreach(string name in new[]{"StartupBoostEnabled","BackgroundModeEnabled"})
                    if(user==null || user.GetValue(name)==null || user.GetValueKind(name)!=RegistryValueKind.DWord || Convert.ToInt32(user.GetValue(name))!=0) throw new InvalidOperationException("The administrative controller did not establish temporary Edge background policies.");
            }
            edgePoliciesConfigured=true;
        }
        static object[] PendingJobProcesses(IntPtr job) {
            if(job==IntPtr.Zero) return new object[0];
            IntPtr buffer=Marshal.AllocHGlobal(8+256*IntPtr.Size);var results=new System.Collections.Generic.List<object>();
            try {
                uint needed;if(!RealQueryJobProcesses(job,3,buffer,(uint)(8+256*IntPtr.Size),out needed)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                int count=Marshal.ReadInt32(buffer,4);if(count<0 || count>256) throw new InvalidOperationException("The owned application Job exceeds its diagnostic bound.");
                for(int index=0;index<count;index++) {
                    int pid=checked((int)Marshal.ReadIntPtr(buffer,8+index*IntPtr.Size).ToInt64());
                    try{using(var process=Process.GetProcessById(pid)){bool contained;if(IsProcessInJob(process.Handle,job,out contained) && contained) results.Add(new {Pid=pid,Name=process.ProcessName,Image=process.MainModule.FileName});}}
                    catch(Exception failure){results.Add(new {Pid=pid,Error=failure.GetType().Name});}
                }
            }catch(Exception failure){results.Add(new {Error=failure.ToString()});}finally{Marshal.FreeHGlobal(buffer);}
            return results.ToArray();
        }
        public object Stop() {
            bool terminalStop=kind=="Terminal" && created && receiver!=null;
            if(terminalStop) File.WriteAllText(Path.Combine(root,"stop.txt"),runId);
            string releaseError=null;
            try{if(automation!=null) automation.Call("ReleaseReferences",()=>{GC.Collect();GC.WaitForPendingFinalizers();GC.Collect();return 0;});}catch(Exception failure){releaseError=failure.ToString();}
            bool automationStopped=automation==null || automation.Stop();
            bool forced=false,receiverJobClosed=receiverJob==IntPtr.Zero;int? exit=null;uint remaining=0;object[] pending=new object[0];
            try {
                if(!terminalStop && app!=null && !app.HasExited) {uint pid;GetWindowThreadProcessId(window,out pid);if(pid==(uint)appPid) PostMessageW(window,0x10,IntPtr.Zero,IntPtr.Zero);}
                var until=DateTime.UtcNow.AddSeconds(6);
                do {
                    remaining=Active(ownedJob)+(launcherJob!=ownedJob?Active(launcherJob):0)+Active(receiverJob);
                    if(remaining==0 && (app==null || app.HasExited) && (bootstrap==null || bootstrap.HasExited)) break;
                    Thread.Sleep(100);
                }while(DateTime.UtcNow<until);
                forced=remaining!=0 || (app!=null && !app.HasExited);
                if(remaining!=0){var processes=new System.Collections.Generic.List<object>(PendingJobProcesses(ownedJob));if(launcherJob!=ownedJob) processes.AddRange(PendingJobProcesses(launcherJob));processes.AddRange(PendingJobProcesses(receiverJob));pending=processes.ToArray();}
            } finally {
                if(ownedJob!=IntPtr.Zero) CloseHandle(ownedJob);
                if(launcherJob!=IntPtr.Zero && launcherJob!=ownedJob) CloseHandle(launcherJob);
                if(receiverJob!=IntPtr.Zero) receiverJobClosed=CloseHandle(receiverJob);
                ownedJob=IntPtr.Zero;launcherJob=IntPtr.Zero;receiverJob=IntPtr.Zero;
                if(app!=null){if(!app.WaitForExit(5000)){forced=true;app.Kill();if(!app.WaitForExit(5000)) throw new InvalidOperationException("The exact verified real application survived cleanup.");}exit=app.ExitCode;app.Dispose();app=null;}
                if(bootstrap!=null){if(!bootstrap.WaitForExit(5000)) throw new InvalidOperationException("The exact launcher survived Job cleanup.");bootstrap.Dispose();bootstrap=null;}
            }
            int? receiverExit=null;string receiverReceipt=null;
            if(receiver!=null){try{if(!receiver.WaitForExit(5000)) throw new InvalidOperationException("The owned Terminal receiver survived cleanup.");receiverExit=receiver.ExitCode;receiverReceipt=File.ReadAllText(Path.Combine(root,"receiver.json"));}finally{receiver.Dispose();receiver=null;}}
            if(kind=="Terminal" && created && File.Exists(Path.Combine(root,"receiver.json"))) receiverReceipt=File.ReadAllText(Path.Combine(root,"receiver.json"));
            string cleanupError=releaseError;
            try{RestorePackagedState();}catch(Exception failure){cleanupError=failure.ToString();}
            try {if(created && cleanupError==null) {
                if(root!=RealFixturePath(kind,Path.GetDirectoryName(Path.GetDirectoryName(root))) || File.ReadAllText(Path.Combine(root,"owner.txt"))!=marker) throw new InvalidOperationException("Unexpected fixture cleanup identity.");
                SafeTree(root);Directory.Delete(root,true);
            }}catch(Exception failure){cleanupError=failure.Message;}
            return new {Kind=kind,Pid=appPid,ExitCode=exit,Forced=forced,ActiveBeforeJobClose=remaining,PendingProcesses=pending,FixtureRemoved=!Directory.Exists(root),CleanupError=cleanupError,AutomationStopped=automationStopped,NotepadStateRestored=kind!="Notepad" || stateRestored,NotepadStateFingerprint=stateFinal,TerminalStateRestored=kind!="Terminal" || stateRestored,TerminalReceiverExitCode=receiverExit,TerminalReceiverJobClosed=receiverJobClosed,TerminalReceiverReceiptJson=receiverReceipt,EdgePolicyRestoreDelegated=kind=="Edge" && edgePoliciesConfigured,Passed=!forced && exit==0 && cleanupError==null && automationStopped && (kind!="Notepad" || stateRestored) && (kind!="Terminal" || (stateRestored && receiverExit==0 && receiverJobClosed)) && (kind!="Edge" || edgePoliciesConfigured)};
        }
    }
}
