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

public static class LaqayGuestDesktop {
    static bool armed;
    static DateTime deadline;
    static readonly HashSet<IntPtr> windows = new HashSet<IntPtr>();
    static Process application;
    static IntPtr job;
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
