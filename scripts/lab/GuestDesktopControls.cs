using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Management;
using System.Runtime.InteropServices;
using System.Reflection;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Automation;
using System.Windows.Forms;

public static class LaqayGuestDesktop {
    static bool armed;
    static DateTime deadline;
    static readonly HashSet<IntPtr> windows = new HashSet<IntPtr>();
    static Process application;
    static IntPtr job;
    static bool peerConnected;
    const string PeerShare=@"\\10.77.166.11\LaqayLab";
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]
    struct NetResource { public uint scope,type,display,usage; public string local,remote,comment,provider; }
    [DllImport("mpr.dll",CharSet=CharSet.Unicode)] static extern int WNetAddConnection2W(ref NetResource resource,IntPtr password,string user,uint flags);
    [DllImport("mpr.dll",CharSet=CharSet.Unicode)] static extern int WNetCancelConnection2W(string name,uint flags,bool force);
    public static bool WasApplicationForced { get; private set; }
    public static int ApplicationExitCode { get; private set; }
    delegate bool EnumProc(IntPtr window, IntPtr parameter);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr parameter);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr window, StringBuilder name, int count);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] static extern bool ShowWindowAsync(IntPtr window, int command);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll", SetLastError=true)] static extern uint SendInput(uint count, Input[] inputs, int size);
    [DllImport("user32.dll")] static extern bool PostMessageW(IntPtr window,uint message,IntPtr wparam,IntPtr lparam);
    [DllImport("user32.dll")] static extern IntPtr SendMessageTimeoutW(IntPtr window,uint message,IntPtr wparam,IntPtr lparam,uint flags,uint timeout,out UIntPtr result);
    [DllImport("user32.dll",SetLastError=true)] static extern IntPtr OpenInputDesktop(uint flags,bool inherit,uint access);
    [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("user32.dll")] static extern IntPtr GetProcessWindowStation();
    [DllImport("user32.dll")] static extern IntPtr GetThreadDesktop(uint thread);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern bool GetUserObjectInformationW(IntPtr handle,int index,StringBuilder value,uint length,out uint needed);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateJobObjectW(IntPtr attributes,string name);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetInformationJobObject(IntPtr handle,int type,ref JobLimits value,uint size);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr handle,IntPtr process);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr process,uint access,out IntPtr token);
    [DllImport("advapi32.dll",SetLastError=true)] static extern bool GetTokenInformation(IntPtr token,int type,out int value,int size,out int needed);
    [DllImport("wtsapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool WTSQuerySessionInformationW(IntPtr server,int session,int info,out IntPtr value,out int bytes);
    [DllImport("wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr value);
    [StructLayout(LayoutKind.Sequential)] struct Key { public ushort vk,scan; public uint flags,time; public UIntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] struct Mouse { public int x,y; public uint data,flags,time; public UIntPtr extra; }
    [StructLayout(LayoutKind.Explicit)] struct Union { [FieldOffset(0)] public Key key; [FieldOffset(0)] public Mouse mouse; }
    [StructLayout(LayoutKind.Sequential)] struct Input { public uint type; public Union value; }
    [StructLayout(LayoutKind.Sequential)] struct BasicLimits { public long processTime,jobTime; public uint flags; public UIntPtr minimum,maximum; public uint active; public UIntPtr affinity; public uint priority,scheduling; }
    [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong readOps,writeOps,otherOps,readBytes,writeBytes,otherBytes; }
    [StructLayout(LayoutKind.Sequential)] struct JobLimits { public BasicLimits basic; public IoCounters io; public UIntPtr processMemory,jobMemory,peakProcess,peakJob; }

    static string ObjectName(IntPtr handle) {
        var name=new StringBuilder(256); uint needed;
        if(handle==IntPtr.Zero || !GetUserObjectInformationW(handle,2,name,512,out needed)) return "";
        return name.ToString();
    }
    static bool InputDesktopAvailable() {
        IntPtr input=OpenInputDesktop(0,false,1);
        try { return ObjectName(GetProcessWindowStation())=="WinSta0" && ObjectName(GetThreadDesktop(GetCurrentThreadId()))=="Default" && ObjectName(input)=="Default"; }
        finally { if(input!=IntPtr.Zero) CloseDesktop(input); }
    }
    public static void Arm(string labId) {
        armed=false;
        if(!Regex.IsMatch(labId,"^[a-f0-9]{32}$")) throw new InvalidOperationException("Invalid lab identity.");
        var identity=new WindowsPrincipal(WindowsIdentity.GetCurrent());
        if(Process.GetCurrentProcess().SessionId==0 || identity.IsInRole(WindowsBuiltInRole.Administrator))
            throw new InvalidOperationException("A non-elevated interactive guest task is required.");
        var readyPath=@"C:\LaqayLab\ready.json";
        if(!File.Exists(readyPath)) throw new InvalidOperationException("The disposable guest marker is missing.");
        var ready=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(File.ReadAllText(readyPath));
        if(!ready.ContainsKey("LabId") || (string)ready["LabId"]!=labId || !ready.ContainsKey("Ready") || !(bool)ready["Ready"])
            throw new InvalidOperationException("Guest marker identity mismatch.");
        bool guest=false,os=false;
        using(var query=new ManagementObjectSearcher("SELECT Manufacturer,Model FROM Win32_ComputerSystem"))
        using(var results=query.Get()) foreach(ManagementObject item in results) {
            using(item) guest=(string)item["Manufacturer"]=="Microsoft Corporation" && (string)item["Model"]=="Virtual Machine";
        }
        using(var query=new ManagementObjectSearcher("SELECT Caption FROM Win32_OperatingSystem"))
        using(var results=query.Get()) foreach(ManagementObject item in results) {
            using(item) os=((string)item["Caption"]).Contains("Windows 11 Enterprise");
        }
        if(!guest || !os || !InputDesktopAvailable() || Thread.CurrentThread.GetApartmentState()!=ApartmentState.STA)
            throw new InvalidOperationException("An unlocked Windows 11 lab desktop in STA is required.");
        deadline=DateTime.UtcNow.AddMinutes(5); armed=true;
    }
    static void Guard() {
        if(!armed || DateTime.UtcNow>=deadline || !InputDesktopAvailable())
            throw new InvalidOperationException("Guest desktop controls are not armed or have expired.");
    }
    public static void RequireRole(string role) {
        Guard();
        var ready=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(File.ReadAllText(@"C:\LaqayLab\ready.json"));
        if((role!="Primary" && role!="Peer") || !ready.ContainsKey("Role") || (string)ready["Role"]!=role)
            throw new InvalidOperationException("Unexpected guest role.");
    }
    public static int SessionProtocol() {
        Guard(); IntPtr value; int bytes;
        if(!WTSQuerySessionInformationW(IntPtr.Zero,Process.GetCurrentProcess().SessionId,16,out value,out bytes))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        try {if(bytes<2) throw new InvalidOperationException("Missing session protocol."); return Marshal.ReadInt16(value);}
        finally {WTSFreeMemory(value);}
    }
    public static string RdpClientAddress() {
        RequireRole("Peer"); IntPtr value; int bytes;
        if(SessionProtocol()!=2 || !WTSQuerySessionInformationW(IntPtr.Zero,Process.GetCurrentProcess().SessionId,14,out value,out bytes))
            throw new InvalidOperationException("An RDP client address is required.");
        try {
            if(bytes<24 || Marshal.ReadInt32(value)!=2) throw new InvalidOperationException("Expected an IPv4 RDP client.");
            return String.Format("{0}.{1}.{2}.{3}",Marshal.ReadByte(value,6),Marshal.ReadByte(value,7),Marshal.ReadByte(value,8),Marshal.ReadByte(value,9));
        } finally {WTSFreeMemory(value);}
    }
    static Bitmap RedirectedFixture() {
        var bitmap=new Bitmap(3,2);
        Color[] colors={Color.Magenta,Color.Cyan,Color.Yellow,Color.Black,Color.Orange,Color.Purple};
        for(int y=0;y<2;y++) for(int x=0;x<3;x++) bitmap.SetPixel(x,y,colors[y*3+x]);
        return bitmap;
    }
    public static bool ClipboardIsRedirectedFixture() {
        RequireRole("Peer");
        using(var image=Clipboard.GetImage()) {
            if(image==null || image.Width!=3 || image.Height!=2) return false;
            using(var bitmap=new Bitmap(image)) using(var expected=RedirectedFixture())
                for(int y=0;y<2;y++) for(int x=0;x<3;x++) if(bitmap.GetPixel(x,y).ToArgb()!=expected.GetPixel(x,y).ToArgb()) return false;
        }
        return true;
    }
    public static bool ClipboardTextEquals(string expected) {Guard();return Clipboard.ContainsText() && Clipboard.GetText()==expected;}
    public static void RunRdpClient(string labId,string runId,string peer,System.Security.SecureString password) {
        RequireRole("Primary");
        if(SessionProtocol()!=0 || !Regex.IsMatch(labId,"^[a-f0-9]{32}$") || !Regex.IsMatch(runId,"^[a-f0-9]{32}$") ||
            !Regex.IsMatch(peer,"^LQW11-[A-Z0-9]{8}$") || password==null)
            throw new InvalidOperationException("Unexpected isolated RDP client identity.");
        using(var client=new RdpClient(labId,runId,peer,password)) client.Run();
    }
    sealed class RdpHost : AxHost {
        public RdpHost() : base("A0C63C30-F08D-4AB4-907C-34905D770C7D") { }
        public object Client {get {return GetOcx();}}
    }
    sealed class RdpClient : IDisposable {
        readonly string labId,runId,peer,root;
        readonly System.Security.SecureString password;
        readonly JavaScriptSerializer json=new JavaScriptSerializer();
        readonly Dictionary<string,object> report=new Dictionary<string,object>();
        readonly List<string> operations=new List<string>();
        readonly Form form=new Form(); readonly RdpHost host=new RdpHost();
        readonly System.Windows.Forms.Timer timer=new System.Windows.Forms.Timer();
        readonly Guid eventsId=new Guid("336d5562-efa8-482e-8cb3-c5c0fc7a7db6");
        object client,settings;
        Action login; Action<int> disconnected,fatal;
        bool loggedOn,closing,disconnectedClean,connectAttempted,diagnosticCaptured; int sequence;
        readonly DateTime started=DateTime.UtcNow;
        DateTime closeDeadline,lastStatus;
        static object Get(object target,string name) {return target.GetType().InvokeMember(name,BindingFlags.GetProperty,null,target,null);}
        static void Set(object target,string name,object value) {target.GetType().InvokeMember(name,BindingFlags.SetProperty,null,target,new[] {value});}
        static void Call(object target,string name) {target.GetType().InvokeMember(name,BindingFlags.InvokeMethod,null,target,null);}
        public RdpClient(string lab,string run,string server,System.Security.SecureString secret) {
            labId=lab;runId=run;peer=server;password=secret;root=@"C:\LaqayLab\Runs\"+run;
            if(!Directory.Exists(root) || File.Exists(Path.Combine(root,"client-report.json"))) throw new InvalidOperationException("Missing or reused RDP client run.");
            report["LabId"]=labId;report["RunId"]=runId;report["LoggedOn"]=false;report["Passed"]=false;
            report["Error"]=null;report["AckSequence"]=0;report["Operations"]=operations;report["Disconnected"]=false;
            report["AuthenticationLevel"]=1;report["CredSsp"]=true;report["ClipboardRedirection"]=true;
            report["SessionId"]=Process.GetCurrentProcess().SessionId;report["StartedUtc"]=DateTime.UtcNow.ToString("o");report["FinishedUtc"]=null;report["Stage"]="Created";
        }
        void Save() {
            string temporary=Path.Combine(root,"client-report.tmp");
            File.WriteAllText(temporary,json.Serialize(report));
            string destination=Path.Combine(root,"client-report.json");
            if(File.Exists(destination)) File.Replace(temporary,destination,null); else File.Move(temporary,destination);
        }
        void Stage(string stage) {report["Stage"]=stage;Save();}
        void CaptureDiagnostic() {
            if(diagnosticCaptured) return;
            diagnosticCaptured=true;
            try {
                RequireRole("Primary");
                var bounds=Screen.FromControl(form).Bounds;
                using(var bitmap=new Bitmap(bounds.Width,bounds.Height)) using(var graphics=Graphics.FromImage(bitmap)) {
                    graphics.CopyFromScreen(bounds.Location,Point.Empty,bounds.Size);
                    bitmap.Save(Path.Combine(root,"client-desktop.png"),System.Drawing.Imaging.ImageFormat.Png);
                }
                report["DiagnosticImage"]="client-desktop.png";
            } catch(Exception error) {report["DiagnosticError"]=error.GetBaseException().Message;}
        }
        void Fail(Exception error) {
            error=error.GetBaseException();report["Error"]=error.GetType().Name+": "+error.Message;report["ErrorHResult"]=error.HResult;
            CaptureDiagnostic();Stage("Failed");form.Close();
        }
        void FocusClient() {
            RequireRole("Primary");
            ShowWindowAsync(form.Handle,3);
            Send(new[] {new Input {type=1,value=new Union {key=new Key {vk=18}}},new Input {type=1,value=new Union {key=new Key {vk=18,flags=2}}}});
            SetForegroundWindow(form.Handle);host.Focus();
            if(GetForegroundWindow()!=form.Handle || !host.ContainsFocus) throw new InvalidOperationException("The owned RDP client lost focus.");
        }
        void Tick() {
            try {
                RequireRole("Primary");
                if(!connectAttempted) {Connect();return;}
                if(DateTime.UtcNow-lastStatus>=TimeSpan.FromSeconds(1)) {
                    if(client!=null) report["ConnectedState"]=Convert.ToInt32(Get(client,"Connected"));
                    report["HeartbeatUtc"]=DateTime.UtcNow.ToString("o");lastStatus=DateTime.UtcNow;Save();
                }
                if(closing) {if(disconnectedClean) form.Close();else if(DateTime.UtcNow>=closeDeadline) throw new TimeoutException("RDP disconnect did not complete.");return;}
                if(!loggedOn) {
                    if(DateTime.UtcNow-started>=TimeSpan.FromSeconds(30)) {CaptureDiagnostic();Save();}
                    if(DateTime.UtcNow-started>=TimeSpan.FromSeconds(75)) throw new TimeoutException("The native RDP client did not complete logon within seventy-five seconds.");
                    return;
                }
                string path=Path.Combine(root,String.Format("command-{0:0000}.json",sequence+1));
                if(!File.Exists(path)) return;
                var command=json.Deserialize<Dictionary<string,object>>(File.ReadAllText(path));
                if((string)command["LabId"]!=labId || (string)command["RunId"]!=runId || Convert.ToInt32(command["Sequence"])!=sequence+1)
                    throw new InvalidOperationException("Unexpected RDP command identity.");
                string operation=(string)command["Operation"];
                if(operation=="Close") {
                    closing=true;closeDeadline=DateTime.UtcNow.AddSeconds(10);Stage("Disconnecting");Call(client,"Disconnect");
                } else {
                    FocusClient();
                    if(operation=="Image") {using(var bitmap=RedirectedFixture()) Clipboard.SetImage(bitmap);}
                    else if(operation=="Text") Clipboard.SetText("LaqayRdp-"+runId);
                    else if(operation=="Paste") Send(new[] {
                        new Input {type=1,value=new Union {key=new Key {vk=17}}},new Input {type=1,value=new Union {key=new Key {vk=86}}},
                        new Input {type=1,value=new Union {key=new Key {vk=86,flags=2}}},new Input {type=1,value=new Union {key=new Key {vk=17,flags=2}}}});
                    else throw new InvalidOperationException("Unsupported RDP client command.");
                }
                sequence++;operations.Add(operation);report["AckSequence"]=sequence;Save();
            } catch(Exception error) {Fail(error);}
        }
        void Connect() {
            try {
                connectAttempted=true;Stage("InitializingControl");RequireRole("Primary");client=host.Client;
                Stage("ConfiguringConnection");
                Set(client,"Server",peer);Set(client,"UserName","LaqayLab");Set(client,"Domain",peer);
                Set(client,"DesktopWidth",1024);Set(client,"DesktopHeight",768);Set(client,"ColorDepth",32);
                settings=Get(client,"AdvancedSettings8");
                Set(settings,"AuthenticationLevel",1);Set(settings,"EnableCredSspSupport",true);Set(settings,"RedirectClipboard",true);
                Set(settings,"RedirectDrives",false);Set(settings,"RedirectPrinters",false);Set(settings,"RedirectPorts",false);Set(settings,"RedirectSmartCards",false);
                Set(settings,"AudioRedirectionMode",2);Set(settings,"AudioCaptureRedirectionMode",false);Set(settings,"EnableAutoReconnect",false);
                if(Convert.ToInt32(Get(settings,"AuthenticationLevel"))!=1 || !Convert.ToBoolean(Get(settings,"EnableCredSspSupport")) || !Convert.ToBoolean(Get(settings,"RedirectClipboard")))
                    throw new InvalidOperationException("RDP authentication or clipboard settings did not apply.");
                login=delegate {loggedOn=true;report["LoggedOn"]=true;Stage("LoggedOn");};
                disconnected=delegate(int reason) {disconnectedClean=closing;report["Disconnected"]=true;report["DisconnectReason"]=reason;if(!closing) {report["Error"]="Unexpected RDP disconnect: "+reason;CaptureDiagnostic();}Stage("Disconnected");if(!closing) form.Close();};
                fatal=delegate(int code) {Fail(new InvalidOperationException("RDP fatal error: "+code));};
                ComEventsHelper.Combine(client,eventsId,3,login);ComEventsHelper.Combine(client,eventsId,4,disconnected);ComEventsHelper.Combine(client,eventsId,10,fatal);
                IntPtr clear=Marshal.SecureStringToGlobalAllocUnicode(password);
                try {Set(settings,"ClearTextPassword",Marshal.PtrToStringUni(clear));} finally {Marshal.ZeroFreeGlobalAllocUnicode(clear);}
                Stage("PreparingClientFocus");FocusClient();Stage("Connecting");Call(client,"Connect");Stage(loggedOn?"LoggedOn":"WaitingForLogon");
            } catch(Exception error) {Fail(error);}
        }
        public void Run() {
            form.Text="Laqay isolated RDP validation";form.WindowState=FormWindowState.Maximized;
            host.Dock=DockStyle.Fill;
            ((System.ComponentModel.ISupportInitialize)host).BeginInit();form.Controls.Add(host);((System.ComponentModel.ISupportInitialize)host).EndInit();
            // Connect from the UI message loop, independently of the form's Shown event.
            timer.Interval=200;timer.Tick+=delegate {Tick();};timer.Start();Stage("MessageLoopReady");
            try {Application.Run(form);} finally {
                timer.Stop();
                report["Passed"]=loggedOn && closing && disconnectedClean && report["Error"]==null;
                report["Stage"]=(bool)report["Passed"]?"Closed":"Failed";
                report["FinishedUtc"]=DateTime.UtcNow.ToString("o");Save();
            }
            if(!(bool)report["Passed"]) throw new InvalidOperationException("The isolated RDP client failed. See its private report.");
        }
        public void Dispose() {
            timer.Dispose();
            if(client!=null) {
                try {if(Convert.ToInt32(Get(client,"Connected"))!=0) Call(client,"Disconnect");} catch(COMException) { }
                if(login!=null) ComEventsHelper.Remove(client,eventsId,3,login);
                if(disconnected!=null) ComEventsHelper.Remove(client,eventsId,4,disconnected);
                if(fatal!=null) ComEventsHelper.Remove(client,eventsId,10,fatal);
            }
            if(settings!=null) {try {Set(settings,"ClearTextPassword","");} catch(COMException) { }}
            host.Dispose();form.Dispose();
        }
    }
    public static void ConnectPeer(string user,System.Security.SecureString password) {
        Guard();
        if(peerConnected || !Regex.IsMatch(user,@"^LQW11-[A-Z0-9]{8}\\LaqayLab$") || password==null)
            throw new InvalidOperationException("Unexpected peer credential or existing owned connection.");
        var resource=new NetResource {type=1,remote=PeerShare};
        IntPtr secret=Marshal.SecureStringToGlobalAllocUnicode(password);
        try {
            int result=WNetAddConnection2W(ref resource,secret,user,4);
            if(result!=0) throw new System.ComponentModel.Win32Exception(result,"Temporary peer connection failed.");
            peerConnected=true;
        } finally {Marshal.ZeroFreeGlobalAllocUnicode(secret);}
    }
    public static void DisconnectPeer() {
        // Cleanup is available after the input deadline and only for our connection.
        if(!peerConnected) return;
        int result=WNetCancelConnection2W(PeerShare,0,false);
        if(result!=0 && result!=2250) throw new System.ComponentModel.Win32Exception(result,"Temporary peer disconnect failed.");
        peerConnected=false;
    }
    static void Send(Input[] inputs) {
        Guard();
        if(SendInput((uint)inputs.Length,inputs,Marshal.SizeOf(typeof(Input)))!=inputs.Length)
            throw new InvalidOperationException("The guest did not accept all synthesized input.");
    }
    static void ExplorerWindow(IntPtr window) {
        uint pid; GetWindowThreadProcessId(window,out pid);
        using(var process=Process.GetProcessById((int)pid)) {
            if(process.SessionId!=Process.GetCurrentProcess().SessionId || process.ProcessName!="explorer")
                throw new InvalidOperationException("An Explorer window in this guest session is required.");
        }
    }
    public static void Chord(IntPtr window,params ushort[] keys) {
        Guard(); ExplorerWindow(window);
        if(GetForegroundWindow()!=window) throw new InvalidOperationException("The expected guest Explorer window is not foreground.");
        var inputs=new List<Input>();
        foreach(ushort key in keys) inputs.Add(new Input {type=1,value=new Union {key=new Key {vk=key}}});
        for(int i=keys.Length-1;i>=0;i--) inputs.Add(new Input {type=1,value=new Union {key=new Key {vk=keys[i],flags=2}}});
        Send(inputs.ToArray());
    }
    public static void Activate(IntPtr window) {
        Guard(); ExplorerWindow(window); windows.Add(window);
        ShowWindowAsync(window,3);
        // Guest-only Alt press/release allows normal foreground activation.
        Send(new[] {new Input {type=1,value=new Union {key=new Key {vk=18}}},new Input {type=1,value=new Union {key=new Key {vk=18,flags=2}}}});
        SetForegroundWindow(window); Thread.Sleep(200);
        if(GetForegroundWindow()!=window) throw new InvalidOperationException("Guest Explorer activation failed.");
    }
    public static void FocusFolder(IntPtr window) {
        Guard(); ExplorerWindow(window);
        if(GetForegroundWindow()!=window) throw new InvalidOperationException("Guest Explorer lost foreground.");
        var root=AutomationElement.FromHandle(window);
        var controls=root.FindAll(TreeScope.Descendants,new OrCondition(
            new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.List),
            new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.DataGrid),
            new PropertyCondition(AutomationElement.ClassNameProperty,"UIItemsView"),
            new PropertyCondition(AutomationElement.AutomationIdProperty,"ItemsView")));
        foreach(AutomationElement element in controls) {
            var info=element.Current;
            if(info.IsOffscreen || !(info.ClassName=="UIItemsView" || info.AutomationId=="ItemsView" || info.Name=="Items View" || info.Name=="Folder View")) continue;
            var rect=info.BoundingRectangle;
            if(rect.Width<40 || rect.Height<40) continue;
            SetCursorPos((int)(rect.X+rect.Width*0.70),(int)(rect.Y+rect.Height*0.75));
            Send(new[] {new Input {type=0,value=new Union {mouse=new Mouse {flags=2}}},new Input {type=0,value=new Union {mouse=new Mouse {flags=4}}}});
            Thread.Sleep(100); return;
        }
        throw new InvalidOperationException("A visible guest folder Items View was not found.");
    }
    public static string SelectedTabName(IntPtr window) {
        Guard(); ExplorerWindow(window);
        var items=AutomationElement.FromHandle(window).FindAll(TreeScope.Descendants,new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.TabItem));
        foreach(AutomationElement item in items) {
            object pattern;
            if(item.TryGetCurrentPattern(SelectionItemPattern.Pattern,out pattern) && ((SelectionItemPattern)pattern).Current.IsSelected) return item.Current.Name;
        }
        return "";
    }
    public static string FocusedText(IntPtr window) {
        Guard(); ExplorerWindow(window);
        var focused=AutomationElement.FocusedElement;
        if(focused==null) return "";
        uint pid; GetWindowThreadProcessId(window,out pid);
        if(focused.Current.ProcessId!=pid) throw new InvalidOperationException("Focused control belongs to another guest process.");
        object pattern;
        if(focused.TryGetCurrentPattern(ValuePattern.Pattern,out pattern)) return ((ValuePattern)pattern).Current.Value;
        if(focused.TryGetCurrentPattern(TextPattern.Pattern,out pattern)) return ((TextPattern)pattern).DocumentRange.GetText(-1);
        return "";
    }
    static Bitmap Fixture() {
        var bitmap=new Bitmap(2,2);
        bitmap.SetPixel(0,0,Color.Red); bitmap.SetPixel(1,0,Color.Lime);
        bitmap.SetPixel(0,1,Color.Blue); bitmap.SetPixel(1,1,Color.White);
        return bitmap;
    }
    public static void ImageClipboard() { Guard(); using(var bitmap=Fixture()) Clipboard.SetImage(bitmap); }
    public static uint ClipboardSequence() {
        Guard();
        uint sequence=GetClipboardSequenceNumber();
        if(sequence==0) throw new InvalidOperationException("Guest clipboard sequence is unavailable.");
        return sequence;
    }
    public static bool ClipboardImageIsFixture() {
        Guard();
        using(var image=Clipboard.GetImage()) {
            if(image==null || image.Width!=2 || image.Height!=2) return false;
            using(var bitmap=new Bitmap(image)) using(var expected=Fixture()) {
                for(int y=0;y<2;y++) for(int x=0;x<2;x++)
                    if(bitmap.GetPixel(x,y).ToArgb()!=expected.GetPixel(x,y).ToArgb()) return false;
            }
        }
        return true;
    }
    public static void TextAndImageClipboard(string text) {
        Guard(); using(var bitmap=Fixture()) { var data=new DataObject(); data.SetData(DataFormats.UnicodeText,text); data.SetData(DataFormats.Bitmap,bitmap); Clipboard.SetDataObject(data,true); }
    }
    public static void TextClipboard(string text) { Guard(); Clipboard.SetText(text); }
    public static void FilesAndImageClipboard(string[] files) {
        Guard(); using(var bitmap=Fixture()) { var data=new DataObject(); data.SetData(DataFormats.FileDrop,files); data.SetData(DataFormats.Bitmap,bitmap); Clipboard.SetDataObject(data,true); }
    }
    public static int StartApplication(string path) {
        Guard();
        if(application!=null || !Path.GetFullPath(path).StartsWith(@"C:\LaqayLab\App\",StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Unexpected application path or instance.");
        job=CreateJobObjectW(IntPtr.Zero,null);
        if(job==IntPtr.Zero) throw new InvalidOperationException("Cannot create the owned guest process job.");
        var limits=new JobLimits(); limits.basic.flags=0x2000;
        if(!SetInformationJobObject(job,9,ref limits,(uint)Marshal.SizeOf(typeof(JobLimits)))) { CloseHandle(job); job=IntPtr.Zero; throw new InvalidOperationException("Cannot configure the guest process job."); }
        try {
            application=Process.Start(new ProcessStartInfo(path) {UseShellExecute=false,CreateNoWindow=true,WorkingDirectory=Path.GetDirectoryName(path)});
            if(!AssignProcessToJobObject(job,application.Handle)) { application.Kill(); application.WaitForExit(); throw new InvalidOperationException("Cannot contain the owned guest application."); }
            return application.Id;
        } catch { CloseHandle(job); job=IntPtr.Zero; throw; }
    }
    public static int AdoptStartupApplication(string path,DateTime bootUtc) {
        Guard();
        if(application!=null || !Path.GetFullPath(path).StartsWith(@"C:\LaqayLab\App\",StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Unexpected startup application path or instance.");
        var candidates=Process.GetProcessesByName("laqay");
        if(candidates.Length!=1) { foreach(var process in candidates) process.Dispose(); throw new InvalidOperationException("Exactly one startup application is required."); }
        var candidate=candidates[0];
        try {
            if(candidate.SessionId!=Process.GetCurrentProcess().SessionId || candidate.StartTime.ToUniversalTime()<bootUtc.ToUniversalTime() ||
                !String.Equals(Path.GetFullPath(candidate.MainModule.FileName),Path.GetFullPath(path),StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("The startup application does not belong to this guest logon and executable.");
            IntPtr token;
            if(!OpenProcessToken(candidate.Handle,8,out token)) throw new InvalidOperationException("Cannot inspect the startup application token.");
            try {
                int elevated,needed;
                if(!GetTokenInformation(token,20,out elevated,4,out needed) || elevated!=0)
                    throw new InvalidOperationException("The startup application must not be elevated.");
                using(var identity=new WindowsIdentity(token))
                    if(!identity.User.Equals(WindowsIdentity.GetCurrent().User)) throw new InvalidOperationException("Unexpected startup application owner.");
            } finally { CloseHandle(token); }
            job=CreateJobObjectW(IntPtr.Zero,null);
            if(job==IntPtr.Zero) throw new InvalidOperationException("Cannot create the startup application job.");
            var limits=new JobLimits(); limits.basic.flags=0x2000;
            if(!SetInformationJobObject(job,9,ref limits,(uint)Marshal.SizeOf(typeof(JobLimits))) || !AssignProcessToJobObject(job,candidate.Handle))
                throw new InvalidOperationException("Cannot contain the startup application.");
            application=candidate;
            return application.Id;
        } catch { candidate.Dispose(); if(job!=IntPtr.Zero) {CloseHandle(job);job=IntPtr.Zero;} throw; }
    }
    static IntPtr AppWindow() {
        if(application==null || application.HasExited) return IntPtr.Zero;
        IntPtr found=IntPtr.Zero;
        EnumWindows((window,parameter)=> {uint pid; GetWindowThreadProcessId(window,out pid); if(pid!=application.Id) return true; var name=new StringBuilder(128); if(GetClassNameW(window,name,name.Capacity)>0 && name.ToString()=="LaqayTrayWindow") {found=window;return false;} return true;},IntPtr.Zero);
        return found;
    }
    public static bool ApplicationReady() { Guard(); return AppWindow()!=IntPtr.Zero; }
    public static void ToggleEnabled() {
        Guard(); IntPtr window=AppWindow(); UIntPtr result;
        if(window==IntPtr.Zero || SendMessageTimeoutW(window,0x111,new IntPtr(1001),IntPtr.Zero,0x23,3000,out result)==IntPtr.Zero)
            throw new InvalidOperationException("The owned Laqay command failed.");
    }
    public static void ToggleStartup() {
        Guard(); IntPtr window=AppWindow(); UIntPtr result;
        if(window==IntPtr.Zero || SendMessageTimeoutW(window,0x111,new IntPtr(1002),IntPtr.Zero,0x23,3000,out result)==IntPtr.Zero)
            throw new InvalidOperationException("The owned startup command failed.");
    }
    public static bool CloseApplication() {
        // Cleanup remains available after the input deadline, for this process only.
        bool clean=true; WasApplicationForced=false;
        if(application!=null) {
            if(!application.HasExited) {var window=AppWindow(); if(window!=IntPtr.Zero) PostMessageW(window,0x10,IntPtr.Zero,IntPtr.Zero); if(!application.WaitForExit(5000)) {clean=false;WasApplicationForced=true;}}
            if(application.HasExited && application.ExitCode!=0) clean=false;
        }
        if(job!=IntPtr.Zero) {CloseHandle(job);job=IntPtr.Zero;}
        if(application!=null) {if(!application.WaitForExit(5000)) throw new InvalidOperationException("The owned application did not exit after job cleanup.");ApplicationExitCode=application.ExitCode;application.Dispose();application=null;}
        return clean;
    }
    public static void CloseExplorerWindows() {
        foreach(var window in windows) {
            try { ExplorerWindow(window); PostMessageW(window,0x10,IntPtr.Zero,IntPtr.Zero); } catch(ArgumentException) { } catch(InvalidOperationException) { }
        }
        windows.Clear(); armed=false;
    }
}
