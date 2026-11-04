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
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] static extern int GetPackageFullName(IntPtr process,ref uint length,StringBuilder name);
    [DllImport("kernel32.dll",EntryPoint="OpenProcess",SetLastError=true)] static extern IntPtr RealOpenProcess(uint access,bool inherit,uint pid);
    [DllImport("kernel32.dll")] static extern bool ProcessIdToSessionId(uint process,out uint session);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetWindowTextW(IntPtr window,StringBuilder text,int length);

    public static string RealFixturePath(string kind,string runRoot) {
        if((kind!="Notepad" && kind!="Edge") || runRoot==null || !Regex.IsMatch(runRoot,@"^C:\\LaqayLab\\Runs\\[a-f0-9]{32}$"))
            throw new ArgumentException("An exact owned guest run and supported application are required.");
        return Path.Combine(runRoot,"real-apps",kind);
    }
    public static string RealBrowserFixture(string runId) {
        if(runId==null || !Regex.IsMatch(runId,"^[a-f0-9]{32}$")) throw new ArgumentException("Invalid browser fixture identity.");
        return "<!doctype html><html lang=\"en\"><meta charset=\"utf-8\"><title>Laqay real app "+runId+
            "</title><label for=\"laqay-real-input\">Laqay real application input</label><textarea id=\"laqay-real-input\" aria-label=\"Laqay real application input\" style=\"display:block;width:600px;height:300px\"></textarea></html>";
    }
    public static object RealApplicationAbi() {return new {Startup=Marshal.SizeOf(typeof(RealStartup)),Process=Marshal.SizeOf(typeof(RealProcess)),Accounting=Marshal.SizeOf(typeof(RealAccounting))};}
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
    public static object EndRealApplication() {
        var owned=realApplication;realApplication=null;
        try {return owned==null?null:owned.Stop();}finally {EndNativeUnicodeFixture();}
    }

    sealed class RealApplication {
        internal readonly string kind,document;
        readonly string root,runId,target,launcher,expectedPackage,tag,arguments;
        readonly DateTime started=DateTime.UtcNow;
        Process bootstrap,app;IntPtr ownedJob,launcherJob,window;bool created,assignedBeforeResume,adopted,ready;
        string marker,version,sha,packageIdentity;int appPid;
        readonly System.Collections.Generic.List<object> candidates=new System.Collections.Generic.List<object>();
        readonly System.Collections.Generic.HashSet<uint> candidatePids=new System.Collections.Generic.HashSet<uint>();
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
                document=Path.Combine(root,"Laqay-"+runId+".txt");tag=Path.GetFileName(document);arguments=Quote(document);
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
            version=FileVersionInfo.GetVersionInfo(target).FileVersion;sha=Hash(target);
            Directory.CreateDirectory(root);created=true;marker="LaqayRealApplication:"+runId+":"+kind+":"+Process.GetCurrentProcess().Id;
            File.WriteAllText(Path.Combine(root,"owner.txt"),marker);
            File.WriteAllText(document,kind=="Edge"?RealBrowserFixture(runId):"",new UTF8Encoding(false));
            ownedJob=NewJob();launcherJob=ownedJob;
            var startup=new RealStartup {size=(uint)Marshal.SizeOf(typeof(RealStartup)),flags=1,show=1};RealProcess process;
            if(!CreateProcessW(launcher,new StringBuilder(Quote(launcher)+" "+arguments),IntPtr.Zero,IntPtr.Zero,false,4,IntPtr.Zero,root,ref startup,out process)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(),"Cannot launch the installed application.");
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
            if(kind=="Notepad") {
                uint length=0;GetPackageFullName(app.Handle,ref length,null);
                if(length==0 || length>1024) throw new InvalidOperationException("Notepad has no registered runtime package identity.");
                var name=new StringBuilder((int)length);
                if(GetPackageFullName(app.Handle,ref length,name)!=0 || !String.Equals(name.ToString(),expectedPackage,StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Notepad runtime package identity differs from inventory.");
                packageIdentity=name.ToString();
            }
            if(Hash(target)!=sha) throw new InvalidOperationException("The executable changed during launch.");
            ready=true;string last=null;
            while(DateTime.UtcNow<until) {
                try {Focus();if(kind=="Edge" && !Directory.Exists(Path.Combine(root,"profile","Default"))) throw new InvalidOperationException("The isolated Edge profile was not created.");return;}
                catch(ElementNotAvailableException failure){last=failure.Message;}
                catch(InvalidOperationException failure){last=failure.Message;}
                Thread.Sleep(100);
            }
            ready=false;throw new InvalidOperationException("The real editor did not become ready: "+last);
        }
        void FindWindow() {
            EnumWindows((candidate,parameter)=> {
                var title=new StringBuilder(512);GetWindowTextW(candidate,title,title.Capacity);
                if(title.ToString().IndexOf(tag,StringComparison.OrdinalIgnoreCase)<0) return true;
                uint pid;GetWindowThreadProcessId(candidate,out pid);Process found=null;
                try {
                    found=Process.GetProcessById((int)pid);
                    string image=found.MainModule.FileName;
                    if(candidatePids.Add(pid)) candidates.Add(new {Pid=pid,Image=image,Session=found.SessionId,Started=found.StartTime.ToUniversalTime().ToString("o"),MatchesTarget=String.Equals(image,target,StringComparison.OrdinalIgnoreCase)});
                    if(found.SessionId!=Process.GetCurrentProcess().SessionId || found.StartTime.ToUniversalTime()<started.AddSeconds(-1) || !String.Equals(image,target,StringComparison.OrdinalIgnoreCase)) return true;
                    app=found;found=null;appPid=(int)pid;window=candidate;return false;
                }catch(ArgumentException){return true;}catch(System.ComponentModel.Win32Exception failure){if(candidatePids.Add(pid)) candidates.Add(new {Pid=pid,Error=failure.NativeErrorCode});return true;}
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
            var rootElement=AutomationElement.FromHandle(window);
            if(kind=="Notepad" && rootElement.FindAll(TreeScope.Descendants,new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.TabItem)).Count>1) throw new InvalidOperationException("Notepad restored unrelated tabs.");
            var candidates=rootElement.FindAll(TreeScope.Descendants,kind=="Edge"?(Condition)new AndCondition(new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.Edit),new PropertyCondition(AutomationElement.NameProperty,"Laqay real application input")):
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
            RequireReady();if(GetForegroundWindow()!=window){ShowWindowAsync(window,3);SetForegroundWindow(window);Thread.Sleep(200);}
            Target().SetFocus();RequireFocus();
        }
        public void RequireFocus() {RequireReady();if(GetForegroundWindow()!=window || !FocusMatches(Target())) throw new InvalidOperationException("The real application editor lost native/semantic focus.");}
        public string ReadText() {
            RequireFocus();object pattern;var element=Target();
            if(element.TryGetCurrentPattern(ValuePattern.Pattern,out pattern)) return ((ValuePattern)pattern).Current.Value;
            return ((TextPattern)element.GetCurrentPattern(TextPattern.Pattern)).DocumentRange.GetText(-1).TrimEnd('\r','\n');
        }
        object[] TargetDiagnostics() {
            var results=new System.Collections.Generic.List<object>();
            try {
                if(window==IntPtr.Zero || app==null || app.HasExited) return results.ToArray();
                var elements=AutomationElement.FromHandle(window).FindAll(TreeScope.Descendants,new OrCondition(new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.Document),new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.Edit),new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.TabItem)));
                foreach(AutomationElement element in elements) {if(results.Count>=24) break;var value=element.Current;results.Add(new {Class=value.ClassName,Type=value.ControlType.ProgrammaticName,Id=value.AutomationId,Enabled=value.IsEnabled,Offscreen=value.IsOffscreen,Focusable=value.IsKeyboardFocusable,Pid=value.ProcessId});}
            }catch(Exception failure){results.Add(new {Error=failure.GetType().Name});}
            return results.ToArray();
        }
        public object Info() {return new {Kind=kind,Executable=target,FileVersion=version,ExecutableSha256=sha,PackageIdentity=packageIdentity,ExpectedPackage=expectedPackage,Pid=appPid,BootstrapPid=bootstrap==null?0:bootstrap.Id,Window=window.ToInt64(),LauncherAssignedBeforeResume=assignedBeforeResume,PackageProcessAdopted=adopted,Ready=ready,FixtureRoot=root,ProfileScope=kind=="Edge"?"Owned run directory":"Disposable guest user",Candidates=candidates.ToArray(),Targets=TargetDiagnostics()};}
        public object State() {
            RequireReady();var element=Target();var gui=new FolderGuiInfo {size=(uint)Marshal.SizeOf(typeof(FolderGuiInfo))};
            if(!GetGUIThreadInfo(0,ref gui)) throw new InvalidOperationException("Cannot inspect real application native focus.");
            return new {Pid=appPid,Foreground=GetForegroundWindow()==window,Focused=FocusMatches(element),GuiFlags=gui.flags,MenuOwner=gui.menuOwner.ToInt64(),
                FocusWindow=gui.focus.ToInt64(),FocusWithinWindow=gui.focus==window || IsChild(window,gui.focus),TargetClass=element.Current.ClassName,TargetType=element.Current.ControlType.ProgrammaticName,ClipboardSequence=GetClipboardSequenceNumber()};
        }
        static IntPtr NewJob() {
            IntPtr value=CreateJobObjectW(IntPtr.Zero,null);if(value==IntPtr.Zero) throw new InvalidOperationException("Cannot create a real application Job.");
            var limits=new JobLimits();limits.basic.flags=0x2000;
            if(!SetInformationJobObject(value,9,ref limits,(uint)Marshal.SizeOf(typeof(JobLimits)))) {CloseHandle(value);throw new InvalidOperationException("Cannot configure the real application Job.");}return value;
        }
        static uint Active(IntPtr job) {if(job==IntPtr.Zero) return 0;RealAccounting value;if(!QueryInformationJobObject(job,1,out value,(uint)Marshal.SizeOf(typeof(RealAccounting)),IntPtr.Zero)) throw new InvalidOperationException("Cannot inspect the real application Job.");return value.active;}
        static void SafeTree(string directory) {
            if((File.GetAttributes(directory)&FileAttributes.ReparsePoint)!=0) throw new InvalidOperationException("A fixture directory is a reparse point.");
            foreach(string path in Directory.GetFileSystemEntries(directory)) {var attrs=File.GetAttributes(path);if((attrs&FileAttributes.ReparsePoint)!=0) throw new InvalidOperationException("A fixture entry is a reparse point.");if((attrs&FileAttributes.Directory)!=0) SafeTree(path);}
        }
        public object Stop() {
            bool forced=false;int? exit=null;uint remaining=0;
            try {
                if(app!=null && !app.HasExited) {uint pid;GetWindowThreadProcessId(window,out pid);if(pid==(uint)appPid) PostMessageW(window,0x10,IntPtr.Zero,IntPtr.Zero);}
                var until=DateTime.UtcNow.AddSeconds(6);
                do {
                    remaining=Active(ownedJob)+(launcherJob!=ownedJob?Active(launcherJob):0);
                    if(remaining==0 && (app==null || app.HasExited) && (bootstrap==null || bootstrap.HasExited)) break;
                    Thread.Sleep(100);
                }while(DateTime.UtcNow<until);
                forced=remaining!=0 || (app!=null && !app.HasExited);
            } finally {
                if(ownedJob!=IntPtr.Zero) CloseHandle(ownedJob);
                if(launcherJob!=IntPtr.Zero && launcherJob!=ownedJob) CloseHandle(launcherJob);
                ownedJob=IntPtr.Zero;launcherJob=IntPtr.Zero;
                if(app!=null){if(!app.WaitForExit(5000)){forced=true;app.Kill();if(!app.WaitForExit(5000)) throw new InvalidOperationException("The exact verified real application survived cleanup.");}exit=app.ExitCode;app.Dispose();app=null;}
                if(bootstrap!=null){if(!bootstrap.WaitForExit(5000)) throw new InvalidOperationException("The exact launcher survived Job cleanup.");bootstrap.Dispose();bootstrap=null;}
            }
            if(created) {
                if(root!=RealFixturePath(kind,Path.GetDirectoryName(Path.GetDirectoryName(root))) || File.ReadAllText(Path.Combine(root,"owner.txt"))!=marker) throw new InvalidOperationException("Unexpected fixture cleanup identity.");
                SafeTree(root);Directory.Delete(root,true);
            }
            return new {Kind=kind,Pid=appPid,ExitCode=exit,Forced=forced,ActiveBeforeJobClose=remaining,FixtureRemoved=!Directory.Exists(root),Passed=!forced && exit==0};
        }
    }
}
