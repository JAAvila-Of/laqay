using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Management;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Automation;
using System.Windows.Forms;

public static partial class LaqayGuestDesktop {
    static bool armed;
    static Dictionary<string,object> observedDesktopProfile;
    static DateTime deadline;
    static readonly HashSet<IntPtr> windows = new HashSet<IntPtr>();
    static Process application;
    static readonly object trialLogLock=new object();
    static StringBuilder trialLog;
    static bool trialLogTruncated,trialLogDrained;
    static ManualResetEvent trialOutputDone,trialErrorDone;
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
    [StructLayout(LayoutKind.Sequential)]
    struct FolderGuiInfo {
        public uint size, flags;
        public IntPtr active, focus, capture, menuOwner, moveSize, caret;
        public int left, top, right, bottom;
    }
    [DllImport("user32.dll",SetLastError=true)] static extern bool GetGUIThreadInfo(uint thread,ref FolderGuiInfo info);
    [DllImport("user32.dll")] static extern bool IsChild(IntPtr parent,IntPtr child);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll",SetLastError=true)] static extern bool OpenClipboard(IntPtr owner);
    [DllImport("user32.dll")] static extern bool CloseClipboard();
    [DllImport("user32.dll")] static extern bool IsClipboardFormatAvailable(uint format);
    [DllImport("user32.dll",SetLastError=true)] static extern IntPtr GetClipboardData(uint format);
    [DllImport("user32.dll",SetLastError=true)] static extern bool EmptyClipboard();
    [DllImport("user32.dll",SetLastError=true)] static extern IntPtr SetClipboardData(uint format,IntPtr data);
    [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr GlobalAlloc(uint flags,UIntPtr bytes);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalFree(IntPtr handle);
    [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr GlobalLock(IntPtr handle);
    [DllImport("kernel32.dll")] static extern bool GlobalUnlock(IntPtr handle);
    [DllImport("kernel32.dll")] static extern UIntPtr GlobalSize(IntPtr handle);
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
    public static void ValidateDesktopProfile(string profile,Dictionary<string,object> ready,string caption,string build,string edition,string language) {
        int number;
        if(profile=="Windows11EnterpriseEvaluation") {
            if(!caption.Contains("Windows 11 Enterprise") || !Int32.TryParse(build,out number) || number<22000 ||
                (ready.ContainsKey("GuestProfile") && Convert.ToString(ready["GuestProfile"])!=profile))
                throw new InvalidOperationException("The declared Windows 11 desktop profile does not match the system.");
        } else if(profile=="Windows10ProEsMx") {
            if(caption!="Microsoft Windows 10 Pro" || build!="19045" || edition!="Professional" || !String.Equals(language,"es-MX",StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("The Pro desktop system does not match the requested profile.");
            foreach(var field in new[] {"GuestProfile","Caption","Build","Edition","Language"})
                if(!ready.ContainsKey(field)) throw new InvalidOperationException("The Pro ready profile is incomplete.");
            if(Convert.ToString(ready["GuestProfile"])!=profile || Convert.ToString(ready["Caption"])!=caption ||
                Convert.ToString(ready["Build"])!=build || Convert.ToString(ready["Edition"])!=edition ||
                !String.Equals(Convert.ToString(ready["Language"]),language,StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("The Pro marker differs from the live desktop system.");
        } else throw new InvalidOperationException("Unsupported explicit desktop profile.");
    }
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,ExactSpelling=true)] static extern int GetSystemDefaultLocaleName(StringBuilder name,int count);
    public static Dictionary<string,object> GuestProfileEvidence() {
        Guard(); return new Dictionary<string,object>(observedDesktopProfile);
    }
    public static void Arm(string labId) { Arm(labId,"Windows11EnterpriseEvaluation"); }
    public static void Arm(string labId,string profile) {
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
        if(profile=="Windows10ProEsMx" && (!ready.ContainsKey("Role") || Convert.ToString(ready["Role"])!="Primary" || !ready.ContainsKey("ComputerName") || !String.Equals(Convert.ToString(ready["ComputerName"]),Environment.MachineName,StringComparison.OrdinalIgnoreCase)))
            throw new InvalidOperationException("The Pro marker does not identify this primary guest computer.");
        bool guest=false; string caption="",build="",edition="";
        using(var query=new ManagementObjectSearcher("SELECT Manufacturer,Model FROM Win32_ComputerSystem"))
        using(var results=query.Get()) foreach(ManagementObject item in results) {
            using(item) guest=(string)item["Manufacturer"]=="Microsoft Corporation" && (string)item["Model"]=="Virtual Machine";
        }
        using(var query=new ManagementObjectSearcher("SELECT Caption,BuildNumber FROM Win32_OperatingSystem"))
        using(var results=query.Get()) foreach(ManagementObject item in results) {
            using(item) {caption=(string)item["Caption"];build=(string)item["BuildNumber"];}
        }
        using(var key=Microsoft.Win32.Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion")) {
            if(key!=null) edition=Convert.ToString(key.GetValue("EditionID",""));
        }
        var locale=new StringBuilder(85);
        if(GetSystemDefaultLocaleName(locale,locale.Capacity)==0) throw new InvalidOperationException("The live system locale is unavailable.");
        ValidateDesktopProfile(profile,ready,caption,build,edition,locale.ToString());
        if(!guest || !InputDesktopAvailable() || Thread.CurrentThread.GetApartmentState()!=ApartmentState.STA)
            throw new InvalidOperationException("An unlocked owned lab desktop in STA is required.");
        observedDesktopProfile=new Dictionary<string,object> {{"Profile",profile},{"Caption",caption},{"Build",build},{"Edition",edition},{"Language",locale.ToString()}};
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
    public static bool ClipboardIsRedirectedFixture() {
        RequireRole("Peer");
        var bytes=ClipboardDib();return bytes!=null && RedirectedDibMatches(bytes);
    }
    static byte[] ClipboardDib() {
        Guard();if(!OpenClipboard(IntPtr.Zero)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        try {
            uint format=IsClipboardFormatAvailable(17)?17u:IsClipboardFormatAvailable(8)?8u:0u;
            if(format==0) return null;
            IntPtr handle=GetClipboardData(format);if(handle==IntPtr.Zero) throw new InvalidOperationException("Native clipboard DIB is unavailable.");
            ulong size=GlobalSize(handle).ToUInt64();if(size<40 || size>1048576) throw new InvalidOperationException("Native fixture DIB size is outside its bounds.");
            IntPtr pointer=GlobalLock(handle);if(pointer==IntPtr.Zero) throw new InvalidOperationException("Native clipboard DIB could not be locked.");
            try {var bytes=new byte[(int)size];Marshal.Copy(pointer,bytes,0,bytes.Length);return bytes;} finally {GlobalUnlock(handle);}
        } finally {CloseClipboard();}
    }
    static string[] RedirectedDibPixels(byte[] bytes) {
        if(bytes==null || bytes.Length<40) return null;
        uint header=BitConverter.ToUInt32(bytes,0);int width=BitConverter.ToInt32(bytes,4),height=BitConverter.ToInt32(bytes,8);
        uint compression=BitConverter.ToUInt32(bytes,16);
        if((header!=40 && header!=108 && header!=124) || header>bytes.Length || width!=3 || (height!=2 && height!=-2) ||
            BitConverter.ToUInt16(bytes,12)!=1 || BitConverter.ToUInt16(bytes,14)!=32 || (compression!=0 && compression!=3) || BitConverter.ToUInt32(bytes,32)!=0) return null;
        if(header==124 && (BitConverter.ToUInt32(bytes,112)!=0 || BitConverter.ToUInt32(bytes,116)!=0)) return null;
        int offset=(int)header;uint alpha=0;
        if(compression==3) {
            if(header==40) offset+=12;
            if(bytes.Length<offset || BitConverter.ToUInt32(bytes,40)!=0x00ff0000 || BitConverter.ToUInt32(bytes,44)!=0x0000ff00 || BitConverter.ToUInt32(bytes,48)!=0x000000ff) return null;
            if(header>=108) alpha=BitConverter.ToUInt32(bytes,52);
            if(alpha!=0 && alpha!=0xff000000) return null;
        }
        if(bytes.Length-offset<24) return null;
        var pixels=new string[6];
        for(int y=0;y<2;y++) for(int x=0;x<3;x++) {
            int p=offset+(height>0?1-y:y)*12+x*4;
            uint value=BitConverter.ToUInt32(bytes,p);if(alpha==0) value|=0xff000000;
            pixels[y*3+x]=value.ToString("X8");
        }
        return pixels;
    }
    public static bool RedirectedDibMatches(byte[] bytes) {
        var pixels=RedirectedDibPixels(bytes);if(pixels==null) return false;
        string[] expected={"FFFF00FF","FF00FFFF","FFFFFF00","FF000000","FFFFA500","FF800080"};
        for(int i=0;i<expected.Length;i++) if(pixels[i]!=expected[i]) return false;
        return true;
    }
    public static byte[] RedirectedDibFixture() {
        var bytes=new byte[148];
        Array.Copy(BitConverter.GetBytes(124u),0,bytes,0,4);Array.Copy(BitConverter.GetBytes(3),0,bytes,4,4);
        Array.Copy(BitConverter.GetBytes(-2),0,bytes,8,4);Array.Copy(BitConverter.GetBytes((ushort)1),0,bytes,12,2);
        Array.Copy(BitConverter.GetBytes((ushort)32),0,bytes,14,2);Array.Copy(BitConverter.GetBytes(3u),0,bytes,16,4);
        Array.Copy(BitConverter.GetBytes(24u),0,bytes,20,4);
        uint[] masks={0x00ff0000,0x0000ff00,0x000000ff,0xff000000};
        for(int i=0;i<masks.Length;i++) Array.Copy(BitConverter.GetBytes(masks[i]),0,bytes,40+i*4,4);
        Array.Copy(BitConverter.GetBytes(0x73524742u),0,bytes,56,4);Array.Copy(BitConverter.GetBytes(4u),0,bytes,108,4);
        uint[] pixels={0xffff00ff,0xff00ffff,0xffffff00,0xff000000,0xffffa500,0xff800080};
        for(int i=0;i<pixels.Length;i++) Array.Copy(BitConverter.GetBytes(pixels[i]),0,bytes,124+i*4,4);
        return bytes;
    }
    static void PublishRedirectedDib(IntPtr owner) {
        RequireRole("Primary");uint pid;GetWindowThreadProcessId(owner,out pid);
        if(owner==IntPtr.Zero || pid!=(uint)Process.GetCurrentProcess().Id) throw new InvalidOperationException("The fixture clipboard owner must belong to this guest task.");
        var bytes=RedirectedDibFixture();IntPtr memory=GlobalAlloc(2,new UIntPtr((uint)bytes.Length));bool transferred=false;
        if(memory==IntPtr.Zero) throw new InvalidOperationException("The native fixture buffer could not be allocated.");
        try {
            IntPtr pointer=GlobalLock(memory);if(pointer==IntPtr.Zero) throw new InvalidOperationException("The native fixture buffer could not be locked.");
            try {Marshal.Copy(bytes,0,pointer,bytes.Length);} finally {GlobalUnlock(memory);}
            bool opened=false;for(int attempt=0;attempt<10 && !opened;attempt++) {opened=OpenClipboard(owner);if(!opened) Thread.Sleep(20);}
            if(!opened) throw new InvalidOperationException("The guest clipboard could not be opened for the native fixture.");
            try {
                if(!EmptyClipboard() || SetClipboardData(17,memory)==IntPtr.Zero) throw new InvalidOperationException("The native fixture could not be published.");
                transferred=true;
            } finally {CloseClipboard();}
        } finally {if(!transferred) GlobalFree(memory);}
        if(!RedirectedDibMatches(ClipboardDib())) throw new InvalidOperationException("The source native DIB fixture failed its exact readback before RDP transfer.");
    }
    public static bool ClipboardTextEquals(string expected) {Guard();return Clipboard.ContainsText() && Clipboard.GetText()==expected;}
    public static object ClipboardDiagnostic() {
        Guard();var result=new Dictionary<string,object>();
        try {
            var native=ClipboardDib();
            if(native!=null) result["NativeDib"]=new {HeaderSize=BitConverter.ToUInt32(native,0),Compression=BitConverter.ToUInt32(native,16),Pixels=RedirectedDibPixels(native),Matches=RedirectedDibMatches(native)};
            var data=Clipboard.GetDataObject();result["Formats"]=data==null?new string[0]:data.GetFormats(false);
            using(var image=Clipboard.GetImage()) {
                result["HasImage"]=image!=null;
                if(image!=null) {
                    result["Width"]=image.Width;result["Height"]=image.Height;result["PixelFormat"]=image.PixelFormat.ToString();
                    if(image.Width<=256 && image.Height<=256) {
                        var actual=image as Bitmap;bool owned=actual==null;if(owned) actual=new Bitmap(image);
                        try {
                            var argb=new List<byte>();var rgb=new List<byte>();var pixels=new List<string>();int nonOpaque=0;
                            for(int y=0;y<actual.Height;y++) for(int x=0;x<actual.Width;x++) {
                                var color=actual.GetPixel(x,y);argb.Add(color.A);argb.Add(color.R);argb.Add(color.G);argb.Add(color.B);
                                rgb.Add(color.R);rgb.Add(color.G);rgb.Add(color.B);if(color.A!=255) nonOpaque++;
                                if(actual.Width<=8 && actual.Height<=8) pixels.Add(color.ToArgb().ToString("X8"));
                            }
                            using(var hash=System.Security.Cryptography.SHA256.Create()) {
                                result["ArgbSha256"]=BitConverter.ToString(hash.ComputeHash(argb.ToArray())).Replace("-","");
                                result["RgbSha256"]=BitConverter.ToString(hash.ComputeHash(rgb.ToArray())).Replace("-","");
                            }
                            result["NonOpaquePixels"]=nonOpaque;
                            if(pixels.Count>0) result["DiagnosticArgbPixels"]=pixels;
                        } finally {if(owned) actual.Dispose();}
                    }
                }
            }
        } catch(Exception error) {result["Error"]=error.GetType().Name+": "+error.Message;}
        return result;
    }
    public static void RunRdpClient(string labId,string runId,string peer,System.Security.SecureString password) {
        RunRdpClient(labId,runId,peer,password,false);
    }
    public static void RunRdpClient(string labId,string runId,string peer,System.Security.SecureString password,bool allowFileConsent) {
        RequireRole("Primary");
        if(SessionProtocol()!=0 || !Regex.IsMatch(labId,"^[a-f0-9]{32}$") || !Regex.IsMatch(runId,"^[a-f0-9]{32}$") ||
            !Regex.IsMatch(peer,"^LQW11-[A-Z0-9]{8}$") || password==null)
            throw new InvalidOperationException("Unexpected isolated RDP client identity.");
        using(var client=new RdpClient(labId,runId,peer,password,allowFileConsent)) client.Run();
    }
    sealed class RdpClient : IDisposable {
        [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]
        struct Credential {
            public uint flags,type; public string target,comment; public long written;
            public uint blobSize; public IntPtr blob; public uint persist,attributeCount;
            public IntPtr attributes; public string alias,user;
        }
        [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CredReadW(string target,uint type,uint flags,out IntPtr credential);
        [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CredWriteW(ref Credential credential,uint flags);
        [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CredDeleteW(string target,uint type,uint flags);
        [DllImport("advapi32.dll")] static extern void CredFree(IntPtr value);
        readonly string labId,runId,peer,root,target;
        readonly System.Security.SecureString password;
        readonly bool allowFileConsent;
        readonly JavaScriptSerializer json=new JavaScriptSerializer();
        readonly Dictionary<string,object> report=new Dictionary<string,object>();
        readonly List<string> operations=new List<string>();
        readonly ApplicationContext context=new ApplicationContext();
        readonly System.Windows.Forms.Timer timer=new System.Windows.Forms.Timer();
        readonly DateTime started=DateTime.UtcNow;
        Process process; IntPtr clientJob;NativeWindow clipboardOwner;
        bool loggedOn,closing,disconnected,credentialWritten,diagnosticCaptured,forced;
        int sequence,serverSession;DateTime closeDeadline,lastStatus,lastClose;
        string configuration;
        public RdpClient(string lab,string run,string server,System.Security.SecureString secret,bool consent) {
            labId=lab;runId=run;peer=server;password=secret;allowFileConsent=consent;root=@"C:\LaqayLab\Runs\"+run;target="TERMSRV/"+peer;
            if(!Directory.Exists(root) || File.Exists(Path.Combine(root,"client-report.json"))) throw new InvalidOperationException("Missing or reused RDP client run.");
            report["LabId"]=labId;report["RunId"]=runId;report["LoggedOn"]=false;report["Passed"]=false;
            report["Error"]=null;report["AckSequence"]=0;report["Operations"]=operations;report["Disconnected"]=false;
            report["AuthenticationLevel"]=1;report["CredSsp"]=true;report["ClipboardRedirection"]=true;
            report["SessionId"]=Process.GetCurrentProcess().SessionId;report["StartedUtc"]=DateTime.UtcNow.ToString("o");report["FinishedUtc"]=null;
            report["Stage"]="Created";report["CredentialRemoved"]=false;report["ForcedTermination"]=false;report["ClientExitCode"]=null;
            report["FileConsentAllowed"]=allowFileConsent;report["FirstUseConsentAccepted"]=false;report["ClipboardConsentAccepted"]=false;
            report["EndedSessionDialogAccepted"]=false;
        }
        void Save() {
            string temporary=Path.Combine(root,"client-report.tmp");File.WriteAllText(temporary,json.Serialize(report));
            string destination=Path.Combine(root,"client-report.json");
            if(File.Exists(destination)) File.Replace(temporary,destination,null); else File.Move(temporary,destination);
        }
        void Stage(string value) {report["Stage"]=value;Save();}
        bool ReadCredential(uint type,out Credential value) {
            IntPtr pointer;value=new Credential();
            if(!CredReadW(target,type,0,out pointer)) {int error=Marshal.GetLastWin32Error();if(error==1168) return false;throw new System.ComponentModel.Win32Exception(error);}
            try {value=(Credential)Marshal.PtrToStructure(pointer,typeof(Credential));return true;} finally {CredFree(pointer);}
        }
        void WriteCredential() {
            RequireRole("Primary");Credential previous;
            if(ReadCredential(1,out previous) || ReadCredential(2,out previous)) throw new InvalidOperationException("Refusing an existing peer credential.");
            IntPtr secret=Marshal.SecureStringToGlobalAllocUnicode(password);
            try {
                var value=new Credential {type=2,target=target,comment="Laqay disposable RDP "+runId,blobSize=checked((uint)password.Length*2),blob=secret,persist=1,user=peer+@"\LaqayLab"};
                if(!CredWriteW(ref value,0)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                credentialWritten=true;
            } finally {Marshal.ZeroFreeGlobalAllocUnicode(secret);}
        }
        void RemoveCredential() {
            if(credentialWritten) {
                Credential value;
                if(ReadCredential(2,out value)) {
                    if(!String.Equals(value.user,peer+@"\LaqayLab",StringComparison.OrdinalIgnoreCase) || value.comment!="Laqay disposable RDP "+runId || value.persist!=1)
                        throw new InvalidOperationException("The owned session credential changed unexpectedly.");
                    if(!CredDeleteW(target,2,0)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                }
                if(ReadCredential(2,out value)) throw new InvalidOperationException("The owned RDP credential remains.");
            }
            report["CredentialRemoved"]=true;
        }
        IntPtr ClientWindow() {
            if(process==null || process.HasExited) return IntPtr.Zero;
            IntPtr result=IntPtr.Zero;
            EnumWindows(delegate(IntPtr window,IntPtr parameter) {
                uint pid;GetWindowThreadProcessId(window,out pid);
                var name=new StringBuilder(128);GetClassNameW(window,name,name.Capacity);
                if(pid==(uint)process.Id && name.ToString()=="TscShellContainerClass") {result=window;return false;}return true;
            },IntPtr.Zero);
            return result;
        }
        void FocusClient() {
            RequireRole("Primary");IntPtr window=ClientWindow();
            if(window==IntPtr.Zero) throw new InvalidOperationException("The owned native RDP window is missing.");
            if(GetForegroundWindow()!=window) {
                // Do not send an activation Alt into the already focused remote desktop.
                Send(new[] {new Input {type=1,value=new Union {key=new Key {vk=18}}},new Input {type=1,value=new Union {key=new Key {vk=18,flags=2}}}});
                ShowWindowAsync(window,3);SetForegroundWindow(window);
            }
            if(GetForegroundWindow()!=window) throw new InvalidOperationException("The owned RDP client lost foreground.");
        }
        void CaptureDiagnostic() {
            if(diagnosticCaptured) return;diagnosticCaptured=true;
            try {
                RequireRole("Primary");var bounds=Screen.PrimaryScreen.Bounds;
                using(var bitmap=new Bitmap(bounds.Width,bounds.Height)) using(var graphics=Graphics.FromImage(bitmap)) {
                    graphics.CopyFromScreen(bounds.Location,Point.Empty,bounds.Size);bitmap.Save(Path.Combine(root,"client-desktop.png"),System.Drawing.Imaging.ImageFormat.Png);
                }
                report["DiagnosticImage"]="client-desktop.png";
            } catch(Exception error) {report["DiagnosticError"]=error.GetBaseException().Message;}
        }
        void Fail(Exception error) {
            error=error.GetBaseException();report["Error"]=error.GetType().Name+": "+error.Message;report["ErrorHResult"]=error.HResult;
            CaptureDiagnostic();Stage("Failed");context.ExitThread();
        }
        static string Label(AutomationElement element) {return Regex.Replace((element.Current.Name??"").Replace("&",""),@"\s+"," ").Trim();}
        List<AutomationElement> ConsentWindows() {
            var handles=new HashSet<IntPtr>();var result=new List<AutomationElement>();
            // Owned modal dialogs need not be direct children of the UI Automation desktop.
            EnumWindows(delegate(IntPtr window,IntPtr parameter) {
                uint pid;GetWindowThreadProcessId(window,out pid);
                var name=new StringBuilder(128);GetClassNameW(window,name,name.Capacity);
                if(pid==(uint)process.Id && name.ToString()!="TscShellContainerClass") handles.Add(window);
                return true;
            },IntPtr.Zero);
            foreach(var handle in handles) result.Add(AutomationElement.FromHandle(handle));
            var roots=AutomationElement.RootElement.FindAll(TreeScope.Children,new PropertyCondition(AutomationElement.ProcessIdProperty,process.Id));
            foreach(AutomationElement window in roots) {
                if(window.Current.ClassName=="TscShellContainerClass") continue;
                var handle=new IntPtr(window.Current.NativeWindowHandle);
                if(handle==IntPtr.Zero || handles.Add(handle)) result.Add(window);
            }
            return result;
        }
        void InvokeConsentButton(AutomationElement element) {
            int handle=element.Current.NativeWindowHandle;
            if(handle!=0) {
                uint pid;GetWindowThreadProcessId(new IntPtr(handle),out pid);
                if(pid!=(uint)process.Id) throw new InvalidOperationException("The consent button belongs to another process.");
                var name=new StringBuilder(128);GetClassNameW(new IntPtr(handle),name,name.Capacity);
                if(name.ToString()=="Button") {if(!PostMessageW(new IntPtr(handle),0xF5,IntPtr.Zero,IntPtr.Zero)) throw new InvalidOperationException("The owned consent button could not be invoked.");return;}
            }
            ((InvokePattern)element.GetCurrentPattern(InvokePattern.Pattern)).Invoke();
        }
        void AcceptOwnedFileConsent() {
            if(!allowFileConsent) return;
            RequireRole("Primary");
            if(File.ReadAllText(Path.Combine(root,"connection.rdp"),Encoding.Unicode)!=configuration) throw new InvalidOperationException("The owned RDP file changed before consent.");
            var observations=new List<object>();report["ConsentWindows"]=observations;
            foreach(AutomationElement window in ConsentWindows()) {
                if(window.Current.ProcessId!=process.Id) throw new InvalidOperationException("The consent window belongs to another process.");
                var controls=window.FindAll(TreeScope.Descendants,Condition.TrueCondition);
                if(controls.Count>500) continue;
                AutomationElement first=null,ok=null,connect=null;bool peerShown=false;var boxes=new List<AutomationElement>();var labels=new StringBuilder();
                var observedControls=new List<object>();
                observations.Add(new {Name=Label(window),ClassName=window.Current.ClassName,Controls=observedControls});
                labels.AppendLine(Label(window));
                for(int i=0;i<controls.Count;i++) {
                    var element=controls[i];var info=element.Current;
                    if(info.ProcessId!=process.Id || info.IsPassword) continue;
                    string label=Label(element);labels.AppendLine(label);
                    observedControls.Add(new {Name=label,ClassName=info.ClassName,Type=info.ControlType.ProgrammaticName,Enabled=info.IsEnabled});
                    if(info.ControlType==ControlType.Text && String.Equals(label,peer,StringComparison.OrdinalIgnoreCase)) peerShown=true;
                    if(info.ControlType==ControlType.CheckBox) {
                        boxes.Add(element);
                        if(label=="I understand and allow RDP files to open on this device for my account") first=element;
                    }
                    if(info.ControlType==ControlType.Button && label=="OK") ok=element;
                    if(info.ControlType==ControlType.Button && label=="Connect") connect=element;
                    object value;
                    if(!info.IsPassword && element.TryGetCurrentPattern(ValuePattern.Pattern,out value)) labels.AppendLine(((ValuePattern)value).Current.Value);
                }
                string text=labels.ToString();
                if(first!=null && boxes.Count==1 && ok!=null && text.Contains("Opening Remote Desktop Connection") && !(bool)report["FirstUseConsentAccepted"]) {
                    var toggle=(TogglePattern)first.GetCurrentPattern(TogglePattern.Pattern);
                    if(toggle.Current.ToggleState!=ToggleState.On) {toggle.Toggle();return;}
                    if(ok.Current.IsEnabled) {InvokeConsentButton(ok);report["FirstUseConsentAccepted"]=true;Stage("GuestFirstUseAcknowledged");return;}
                }
                // The visual banner is exposed only as BannerAccessibilityWrapperWindow on current Windows.
                bool security=window.Current.ClassName=="#32770" && Label(window)=="Remote Desktop Connection security warning" &&
                    text.Contains("Allow the remote computer to access the following resources on my computer:") &&
                    text.Contains("Unknown publisher") && text.Contains("Remote computer:");
                if(security && peerShown && connect!=null && !(bool)report["ClipboardConsentAccepted"]) {
                    int clipboard=0;
                    foreach(var box in boxes) {
                        bool wanted=String.Equals(Label(box),"Clipboard",StringComparison.OrdinalIgnoreCase);
                        if(wanted) clipboard++;
                        var toggle=(TogglePattern)box.GetCurrentPattern(TogglePattern.Pattern);
                        var expected=wanted?ToggleState.On:ToggleState.Off;
                        if(toggle.Current.ToggleState!=expected) {toggle.Toggle();return;}
                    }
                    if(clipboard!=1) throw new InvalidOperationException("The owned connection warning did not expose exactly one Clipboard resource.");
                    if(connect.Current.IsEnabled) {InvokeConsentButton(connect);report["ClipboardConsentAccepted"]=true;Stage("GuestClipboardSharingAuthorized");return;}
                }
            }
        }
        void DismissEndedSession() {
            if((bool)report["EndedSessionDialogAccepted"]) return;
            var observations=new List<object>();report["DisconnectWindows"]=observations;
            foreach(var window in ConsentWindows()) {
                if(window.Current.ProcessId!=process.Id) continue;
                var controls=window.FindAll(TreeScope.Descendants,Condition.TrueCondition);
                if(controls.Count>100) continue;
                var labels=new StringBuilder();var observed=new List<object>();AutomationElement ok=null;
                observations.Add(new {Name=Label(window),ClassName=window.Current.ClassName,Controls=observed});
                foreach(AutomationElement control in controls) {
                    var info=control.Current;if(info.ProcessId!=process.Id || info.IsPassword) continue;
                    labels.AppendLine(Label(control));observed.Add(new {Name=Label(control),Type=info.ControlType.ProgrammaticName});
                    if(info.ControlType==ControlType.Button && Label(control)=="OK") ok=control;
                }
                string text=labels.ToString();
                bool ended=window.Current.ClassName=="#32770" && Label(window)=="Remote Desktop Connection" &&
                    text.Contains("Your Remote Desktop Services session has ended.") && text.Contains("Your network administrator might have ended the connection.");
                if(ended && ok!=null && ok.Current.IsEnabled) {InvokeConsentButton(ok);report["EndedSessionDialogAccepted"]=true;Save();return;}
            }
        }
        Dictionary<string,object> ReadProof(string name) {
            string path=Path.Combine(root,name);if(!File.Exists(path)) return null;
            var proof=json.Deserialize<Dictionary<string,object>>(File.ReadAllText(path));
            if((string)proof["LabId"]!=labId || (string)proof["RunId"]!=runId || Convert.ToInt32(proof["ClientProcessId"])!=process.Id ||
                (string)proof["PeerName"]!=peer || Convert.ToInt32(proof["Protocol"])!=2 || (string)proof["ClientAddress"]!="10.77.166.10")
                throw new InvalidOperationException("Unexpected server session proof.");
            return proof;
        }
        void CloseOwnedWindows() {
            EnumWindows(delegate(IntPtr window,IntPtr parameter) {uint pid;GetWindowThreadProcessId(window,out pid);if(pid==(uint)process.Id) PostMessageW(window,0x10,IntPtr.Zero,IntPtr.Zero);return true;},IntPtr.Zero);
        }
        void Tick() {
            try {
                RequireRole("Primary");
                if(DateTime.UtcNow-lastStatus>=TimeSpan.FromSeconds(1)) {
                    report["ClientAlive"]=!process.HasExited;report["ClientWindowSeen"]=ClientWindow()!=IntPtr.Zero;
                    report["HeartbeatUtc"]=DateTime.UtcNow.ToString("o");lastStatus=DateTime.UtcNow;Save();
                }
                if(closing) {
                    var proof=ReadProof("server-disconnected.json");
                    if(proof!=null) {
                        if(Convert.ToInt32(proof["PeerSessionId"])!=serverSession || Convert.ToInt32(proof["State"])!=4) throw new InvalidOperationException("Unexpected disconnect proof.");
                        disconnected=true;report["Disconnected"]=true;
                        if(process.HasExited) {context.ExitThread();return;}
                        DismissEndedSession();
                        if(DateTime.UtcNow-lastClose>=TimeSpan.FromSeconds(1)) {CloseOwnedWindows();lastClose=DateTime.UtcNow;}
                    }
                    if(DateTime.UtcNow>=closeDeadline) throw new TimeoutException("The native RDP client did not exit after the verified server disconnect.");
                    return;
                }
                if(process.HasExited) throw new InvalidOperationException("The owned RDP client exited before controlled disconnect.");
                if(!loggedOn) {
                    try {AcceptOwnedFileConsent();} catch(ElementNotAvailableException) { }
                    var proof=ReadProof("server-session.json");
                    if(proof!=null) {
                        serverSession=Convert.ToInt32(proof["PeerSessionId"]);if(serverSession<=0 || ClientWindow()==IntPtr.Zero) throw new InvalidOperationException("Missing verified RDP session or native window.");
                        loggedOn=true;report["LoggedOn"]=true;report["ServerSessionId"]=serverSession;Stage("ServerVerifiedLogon");
                    } else {
                        if(DateTime.UtcNow-started>=TimeSpan.FromSeconds(30)) {CaptureDiagnostic();Save();}
                        if(DateTime.UtcNow-started>=TimeSpan.FromSeconds(75)) throw new TimeoutException("The server did not confirm an authenticated RDP session.");
                        return;
                    }
                }
                string path=Path.Combine(root,String.Format("command-{0:0000}.json",sequence+1));if(!File.Exists(path)) return;
                var command=json.Deserialize<Dictionary<string,object>>(File.ReadAllText(path));
                if((string)command["LabId"]!=labId || (string)command["RunId"]!=runId || Convert.ToInt32(command["Sequence"])!=sequence+1) throw new InvalidOperationException("Unexpected RDP command identity.");
                string operation=(string)command["Operation"];
                if(operation=="Close") {closing=true;closeDeadline=DateTime.UtcNow.AddSeconds(20);Stage("AwaitingServerDisconnect");}
                else {
                    FocusClient();
                    if(operation=="Image") {
                        if(clipboardOwner==null) {clipboardOwner=new NativeWindow();clipboardOwner.CreateHandle(new CreateParams {Caption="Laqay test clipboard",Parent=new IntPtr(-3)});}
                        PublishRedirectedDib(clipboardOwner.Handle);report["ImageClipboard"]=ClipboardDiagnostic();
                    }
                    else if(operation=="Text") Clipboard.SetText("LaqayRdp-"+runId);
                    else if(operation=="Paste") Send(new[] {
                        new Input {type=1,value=new Union {key=new Key {vk=17}}},new Input {type=1,value=new Union {key=new Key {vk=86}}},
                        new Input {type=1,value=new Union {key=new Key {vk=86,flags=2}}},new Input {type=1,value=new Union {key=new Key {vk=17,flags=2}}}});
                    else throw new InvalidOperationException("Unsupported RDP client command.");
                }
                sequence++;operations.Add(operation);report["AckSequence"]=sequence;Save();
            } catch(Exception error) {Fail(error);}
        }
        public void Run() {
            try {
                if(Process.GetProcessesByName("mstsc").Length!=0) throw new InvalidOperationException("An unrelated native RDP client is already running.");
                Stage("PreparingSessionCredential");WriteCredential();
                string file=Path.Combine(root,"connection.rdp");
                if(File.Exists(file)) throw new InvalidOperationException("Refusing an existing RDP file.");
                configuration="full address:s:"+peer+"\r\nusername:s:"+peer+"\\LaqayLab\r\n"+
                    "authentication level:i:1\r\nenablecredsspsupport:i:1\r\nprompt for credentials:i:0\r\n"+
                    "screen mode id:i:1\r\ndesktopwidth:i:1024\r\ndesktopheight:i:768\r\nsession bpp:i:32\r\n"+
                    "redirectclipboard:i:1\r\naudiomode:i:2\r\naudiocapturemode:i:0\r\nredirectdrives:i:0\r\ndrivestoredirect:s:\r\n"+
                    "redirectprinters:i:0\r\nredirectsmartcards:i:0\r\nredirectcomports:i:0\r\nredirectposdevices:i:0\r\ndevicestoredirect:s:\r\nredirectwebauthn:i:0\r\nredirectlocation:i:0\r\ncamerastoredirect:s:\r\n"+
                    "autoreconnection enabled:i:0\r\nuse multimon:i:0\r\nadministrative session:i:0\r\n";
                File.WriteAllText(file,configuration,Encoding.Unicode);
                clientJob=CreateJobObjectW(IntPtr.Zero,null);if(clientJob==IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                var limits=new JobLimits {basic=new BasicLimits {flags=0x2000}};
                if(!SetInformationJobObject(clientJob,9,ref limits,(uint)Marshal.SizeOf(typeof(JobLimits)))) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                string executable=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),"mstsc.exe");
                process=Process.Start(new ProcessStartInfo(executable,"\""+file+"\"") {UseShellExecute=false,WorkingDirectory=root});
                if(process==null) throw new InvalidOperationException("The native RDP client did not start.");
                if(!AssignProcessToJobObject(clientJob,process.Handle)) {
                    if(!process.HasExited) {process.Kill();process.WaitForExit(5000);forced=true;}
                    throw new InvalidOperationException("The owned native RDP client could not enter its job.");
                }
                report["ClientProcessId"]=process.Id;Stage("Connecting");
                timer.Interval=200;timer.Tick+=delegate {Tick();};timer.Start();Application.Run(context);
            } catch(Exception error) {Fail(error);} finally {
                timer.Stop();
                if(process!=null && !process.HasExited) {CloseOwnedWindows();if(!process.WaitForExit(2000)) forced=true;}
                if(clientJob!=IntPtr.Zero) {CloseHandle(clientJob);clientJob=IntPtr.Zero;}
                if(process!=null && process.WaitForExit(5000)) report["ClientExitCode"]=process.ExitCode;
                try {RemoveCredential();} catch(Exception error) {report["Error"]="Credential cleanup: "+error.GetBaseException().Message;}
                report["ForcedTermination"]=forced;
                report["Passed"]=loggedOn && closing && disconnected && !forced && report["ClientExitCode"]!=null && (int)report["ClientExitCode"]==0 && (bool)report["CredentialRemoved"] && report["Error"]==null;
                report["Stage"]=(bool)report["Passed"]?"Closed":"Failed";report["FinishedUtc"]=DateTime.UtcNow.ToString("o");Save();
            }
            if(!(bool)report["Passed"]) throw new InvalidOperationException("The isolated native RDP client failed. See its private report.");
        }
        public void Dispose() {timer.Dispose();context.Dispose();if(clipboardOwner!=null) clipboardOwner.DestroyHandle();if(clientJob!=IntPtr.Zero) {CloseHandle(clientJob);clientJob=IntPtr.Zero;}if(process!=null) process.Dispose();}
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
    public static object FolderInputState(IntPtr window) {
        Guard(); ExplorerWindow(window);
        uint pid; uint thread=GetWindowThreadProcessId(window,out pid);
        var info=new FolderGuiInfo {size=(uint)Marshal.SizeOf(typeof(FolderGuiInfo))};
        if(!GetGUIThreadInfo(thread,ref info)) throw new InvalidOperationException("The guest Explorer input state could not be inspected.");
        bool within=info.focus==window || IsChild(window,info.focus);
        var name=new StringBuilder(128);
        if(within) GetClassNameW(info.focus,name,name.Capacity);
        bool itemsFocus=false;string semanticClass="",semanticType="",semanticError=null;
        try {
            var focused=AutomationElement.FocusedElement;
            if(focused!=null && focused.Current.ProcessId==(int)pid) {
                semanticClass=focused.Current.ClassName;semanticType=focused.Current.ControlType.ProgrammaticName;
                for(int depth=0;focused!=null && depth<16;depth++) {
                    if(focused.Current.ProcessId!=(int)pid) break;
                    if(focused.Current.ClassName=="UIItemsView" || focused.Current.AutomationId=="ItemsView") {itemsFocus=true;break;}
                    focused=TreeWalker.ControlViewWalker.GetParent(focused);
                }
            }
        } catch(Exception error) {semanticError=error.GetType().Name;}
        return new {Foreground=GetForegroundWindow()==window,FocusWithinWindow=within,
            FocusWindow=info.focus.ToInt64(),FocusedClass=name.ToString(),GuiFlags=info.flags,
            MenuOwner=info.menuOwner.ToInt64(),ClipboardSequence=GetClipboardSequenceNumber(),
            ItemsViewFocused=itemsFocus,SemanticClass=semanticClass,SemanticType=semanticType,SemanticError=semanticError,
            ControlDown=(GetAsyncKeyState(17)&0x8000)!=0,AltDown=(GetAsyncKeyState(18)&0x8000)!=0,
            ShiftDown=(GetAsyncKeyState(16)&0x8000)!=0,WindowsDown=((GetAsyncKeyState(91)|GetAsyncKeyState(92))&0x8000)!=0,
            HasBitmap=IsClipboardFormatAvailable(2),HasDib=IsClipboardFormatAvailable(8),
            HasDibV5=IsClipboardFormatAvailable(17),HasFileDrop=IsClipboardFormatAvailable(15),HasPng=IsClipboardFormatAvailable(RegisterClipboardFormatW("PNG"))};
    }
    // A read-only MTA comparison for failed guest input. No COM element leaves
    // the worker and this observation never substitutes for a passing paste.
    public static object FolderSemanticProbe(IntPtr window) {
        Guard(); ExplorerWindow(window);
        uint pid;uint thread=GetWindowThreadProcessId(window,out pid);
        var info=new FolderGuiInfo {size=(uint)Marshal.SizeOf(typeof(FolderGuiInfo))};
        if(!GetGUIThreadInfo(thread,ref info)) throw new InvalidOperationException("Guest input state was unavailable for semantic diagnostics.");
        IntPtr focus=info.focus;
        object result=null;
        var worker=new Thread(delegate() {
            var values=new Dictionary<string,object>();
            values["Apartment"]="MTA";values["Completed"]=true;
            values["NativeCom"]=ProbeNativeFolderFocus(focus);
            try {
                var element=AutomationElement.FocusedElement;
                if(element==null) throw new InvalidOperationException("UI Automation returned no focused element.");
                var current=element.Current;
                values["Class"]=current.ClassName;values["AutomationId"]=current.AutomationId;
                values["ControlType"]=current.ControlType.ProgrammaticName;values["ProcessId"]=current.ProcessId;
                values["NativeWindow"]=current.NativeWindowHandle;values["HasKeyboardFocus"]=current.HasKeyboardFocus;values["Enabled"]=current.IsEnabled;
                var ancestors=new List<object>();
                for(int depth=0;element!=null && depth<8;depth++) {
                    current=element.Current;
                    if(current.ProcessId!=(int)pid) break;
                    ancestors.Add(new {Class=current.ClassName,AutomationId=current.AutomationId,ControlType=current.ControlType.ProgrammaticName,NativeWindow=current.NativeWindowHandle});
                    element=TreeWalker.ControlViewWalker.GetParent(element);
                }
                values["Ancestors"]=ancestors.ToArray();
            }catch(Exception error){values["FocusedError"]=error.GetType().Name;values["FocusedHResult"]=error.HResult;}
            try {
                var element=AutomationElement.FromHandle(focus);
                var current=element.Current;
                values["NativeControl"]=new {Class=current.ClassName,AutomationId=current.AutomationId,ControlType=current.ControlType.ProgrammaticName,HasKeyboardFocus=current.HasKeyboardFocus,Enabled=current.IsEnabled,ProcessId=current.ProcessId};
            }catch(Exception error){values["NativeError"]=error.GetType().Name;values["NativeHResult"]=error.HResult;}
            result=values;
        });
        worker.IsBackground=true;worker.SetApartmentState(ApartmentState.MTA);worker.Start();
        if(!worker.Join(2000)) return new {Apartment="MTA",Completed=false,Error="Semantic diagnostic exceeded two seconds."};
        return result;
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
    public static int ExplorerTabCount(IntPtr window) {
        Guard(); ExplorerWindow(window);
        return AutomationElement.FromHandle(window).FindAll(TreeScope.Descendants,new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.TabItem)).Count;
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
    public static string CoreTrialArguments(string directory) {
        string full=Path.GetFullPath(directory);
        if(!Regex.IsMatch(full,@"^C:\\LaqayLab\\Runs\\[a-f0-9]{32}\\data\\core-trial$",RegexOptions.IgnoreCase)) throw new ArgumentException("Unexpected core trial directory.");
        return "--trial 20 \""+full+"\"";
    }
    public static int StartTrialApplication(string path,string directory) {
        Guard();RequireRole("Primary");
        if(observedDesktopProfile==null || Convert.ToString(observedDesktopProfile["Profile"])!="Windows10ProEsMx") throw new InvalidOperationException("Core trials require the explicit Pro guest profile.");
        string arguments=CoreTrialArguments(directory);
        if(!Directory.Exists(directory)) throw new ArgumentException("The owned core trial directory is missing.");
        for(string current=Path.GetFullPath(directory);!String.IsNullOrEmpty(current);current=Path.GetDirectoryName(current))
            if((File.GetAttributes(current)&FileAttributes.ReparsePoint)!=0) throw new ArgumentException("A core trial ancestor is a reparse point.");
        return StartApplicationCore(path,arguments,true);
    }
    static void CaptureTrialLine(string channel,string line,ManualResetEvent completed) {
        if(line==null) {completed.Set();return;}
        lock(trialLogLock) {
            string text=channel+": "+line+Environment.NewLine;
            int remaining=65536-trialLog.Length;
            if(text.Length>remaining) trialLogTruncated=true;
            if(remaining>0) trialLog.Append(text,0,Math.Min(text.Length,remaining));
        }
    }
    public static object CoreTrialLog() {
        lock(trialLogLock) return new {Output=trialLog==null?"":trialLog.ToString(),Truncated=trialLogTruncated,Drained=trialLogDrained,MaximumCharacters=65536};
    }
    public static int StartApplication(string path) {return StartApplicationCore(path,"",false);}
    static int StartApplicationCore(string path,string arguments,bool capture) {
        Guard();
        if(application!=null || !Path.GetFullPath(path).StartsWith(@"C:\LaqayLab\App\",StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Unexpected application path or instance.");
        job=CreateJobObjectW(IntPtr.Zero,null);
        if(job==IntPtr.Zero) throw new InvalidOperationException("Cannot create the owned guest process job.");
        var limits=new JobLimits(); limits.basic.flags=0x2000;
        if(!SetInformationJobObject(job,9,ref limits,(uint)Marshal.SizeOf(typeof(JobLimits)))) { CloseHandle(job); job=IntPtr.Zero; throw new InvalidOperationException("Cannot configure the guest process job."); }
        try {
            var start=new ProcessStartInfo(path,arguments) {UseShellExecute=false,CreateNoWindow=true,WorkingDirectory=Path.GetDirectoryName(path),RedirectStandardOutput=capture,RedirectStandardError=capture};
            if(capture) {start.StandardOutputEncoding=Encoding.UTF8;start.StandardErrorEncoding=Encoding.UTF8;}
            application=Process.Start(start);
            if(!AssignProcessToJobObject(job,application.Handle)) { application.Kill(); application.WaitForExit(); throw new InvalidOperationException("Cannot contain the owned guest application."); }
            if(capture) {
                trialLog=new StringBuilder();trialLogTruncated=false;trialLogDrained=false;
                trialOutputDone=new ManualResetEvent(false);trialErrorDone=new ManualResetEvent(false);
                application.OutputDataReceived+=(sender,eventArgs)=>CaptureTrialLine("stdout",eventArgs.Data,trialOutputDone);
                application.ErrorDataReceived+=(sender,eventArgs)=>CaptureTrialLine("stderr",eventArgs.Data,trialErrorDone);
                application.BeginOutputReadLine();application.BeginErrorReadLine();
            }
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
        if(application!=null) {
            if(!application.WaitForExit(5000)) throw new InvalidOperationException("The owned application did not exit after job cleanup.");
            if(application.StartInfo.RedirectStandardOutput) {
                trialLogDrained=trialOutputDone.WaitOne(1000) && trialErrorDone.WaitOne(1000);
                if(!trialLogDrained) {try{application.CancelOutputRead();application.CancelErrorRead();}catch(InvalidOperationException){}}
            }
            ApplicationExitCode=application.ExitCode;application.Dispose();application=null;
        }
        return clean;
    }
    public static void CloseExplorerWindows() {
        foreach(var window in windows) {
            try { ExplorerWindow(window); PostMessageW(window,0x10,IntPtr.Zero,IntPtr.Zero); } catch(ArgumentException) { } catch(InvalidOperationException) { }
        }
        windows.Clear(); armed=false;
    }
}
