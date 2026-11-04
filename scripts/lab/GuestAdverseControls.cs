using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

public static partial class LaqayGuestDesktop {
    static ClipboardLease matrixClipboardLease;
    static MatrixEditor matrixEditor;
    static MatrixReferenceHook matrixReferenceHook;
    static NativeWindow matrixTextSource;
    static uint matrixTextThread;
    static void MatrixGuard() { LifecycleGuard(); }
    public static byte[] MatrixUnicodeFixture(string text) {
        if(text==null || text.Length>256 || text.IndexOf('\0')>=0) throw new ArgumentException("A bounded Unicode fixture without embedded nulls is required.");
        return System.Text.Encoding.Unicode.GetBytes(text+"\0");
    }
    public static object MatrixEditorTextClipboard(string text) {
        MatrixGuard();if(matrixEditor==null) throw new InvalidOperationException("No owned editor fixture.");
        return PublishNativeUnicodeFixture(text);
    }
    static object PublishNativeUnicodeFixture(string text) {
        MatrixGuard();
        var bytes=MatrixUnicodeFixture(text);
        if(matrixTextSource==null) {
            matrixTextThread=GetCurrentThreadId();matrixTextSource=new NativeWindow();
            matrixTextSource.CreateHandle(new CreateParams {Caption="Laqay native Unicode source",Parent=new IntPtr(-3)});
        }
        if(matrixTextThread!=GetCurrentThreadId()) throw new InvalidOperationException("The native Unicode source changed publisher thread.");
        IntPtr memory=GlobalAlloc(2,new UIntPtr((uint)bytes.Length));bool transferred=false,opened=false;
        if(memory==IntPtr.Zero) throw new InvalidOperationException("The Unicode buffer could not be allocated.");
        try {
            IntPtr pointer=GlobalLock(memory);
            if(pointer==IntPtr.Zero) throw new InvalidOperationException("The Unicode buffer could not be locked.");
            try {Marshal.Copy(bytes,0,pointer,bytes.Length);} finally {GlobalUnlock(memory);}
            for(int attempt=0;attempt<10 && !opened;attempt++){opened=OpenClipboard(matrixTextSource.Handle);if(!opened) Thread.Sleep(20);}
            if(!opened || !EmptyClipboard() || SetClipboardData(13,memory)==IntPtr.Zero) throw new InvalidOperationException("The native Unicode source could not publish.");
            transferred=true;
            IntPtr actual=GetClipboardData(13);
            if(actual==IntPtr.Zero || GlobalSize(actual).ToUInt64()<(ulong)bytes.Length) throw new InvalidOperationException("The published Unicode buffer is incomplete.");
            pointer=GlobalLock(actual);
            if(pointer==IntPtr.Zero) throw new InvalidOperationException("The Unicode readback could not be locked.");
            try {
                var readback=new byte[bytes.Length];Marshal.Copy(pointer,readback,0,readback.Length);
                for(int i=0;i<bytes.Length;i++) if(readback[i]!=bytes[i]) throw new InvalidOperationException("The native Unicode readback differs from its fixture.");
            } finally {GlobalUnlock(actual);}
        } finally {if(opened) CloseClipboard();if(!transferred) GlobalFree(memory);}
        uint pid;uint thread=GetWindowThreadProcessId(GetClipboardOwner(),out pid);
        if(GetClipboardOwner()!=matrixTextSource.Handle || thread!=matrixTextThread || pid!=(uint)Process.GetCurrentProcess().Id)
            throw new InvalidOperationException("The native Unicode source owner changed before input.");
        string hash;using(var sha=System.Security.Cryptography.SHA256.Create()) hash=BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-","");
        return new {Format=13,ByteLength=bytes.Length,Characters=text.Length,ReadbackMatched=true,PayloadSha256=hash,
            Window=matrixTextSource.Handle.ToInt64(),OwnerPid=pid,OwnerThread=thread,Sequence=GetClipboardSequenceNumber()};
    }
    public static int MatrixPixel(int index) {
        var colors=new[]{Color.FromArgb(0,0,0,0),Color.FromArgb(64,255,0,0),Color.FromArgb(128,0,255,0),Color.FromArgb(255,0,0,255)};
        if(index<0 || index>=colors.Length) throw new ArgumentOutOfRangeException("index");
        return colors[index].ToArgb();
    }
    // Pure fixture generation is also checked without arming or opening a desktop.
    public static byte[] MatrixPng(int size) {
        if(size!=2 && size!=2048) throw new ArgumentOutOfRangeException("size");
        using(var bitmap=new Bitmap(size,size,PixelFormat.Format32bppArgb)) using(var output=new MemoryStream()) {
            using(var graphics=Graphics.FromImage(bitmap)) graphics.Clear(Color.White);
            bitmap.SetPixel(0,0,Color.FromArgb(MatrixPixel(0)));bitmap.SetPixel(size-1,0,Color.FromArgb(MatrixPixel(1)));
            bitmap.SetPixel(0,size-1,Color.FromArgb(MatrixPixel(2)));bitmap.SetPixel(size-1,size-1,Color.FromArgb(MatrixPixel(3)));
            bitmap.Save(output,ImageFormat.Png);return output.ToArray();
        }
    }
    public static void MatrixPngClipboard(int size) {
        MatrixGuard();using(var stream=new MemoryStream(MatrixPng(size),false)) {
            var data=new DataObject();data.SetData("PNG",false,stream);Clipboard.SetDataObject(data,true);
        }
    }
    public static void EmptyImageClipboard() {MatrixGuard();Clipboard.Clear();}
    public static void BeginClipboardLease() {
        MatrixGuard();if(matrixClipboardLease!=null) throw new InvalidOperationException("A clipboard lease already exists.");
        matrixClipboardLease=new ClipboardLease();matrixClipboardLease.Start();
    }
    public static void EndClipboardLease() {
        var owned=matrixClipboardLease;matrixClipboardLease=null;if(owned!=null) owned.Dispose();
    }
    public static object ClipboardLeaseState() {
        MatrixGuard();if(matrixClipboardLease==null) throw new InvalidOperationException("No owned clipboard lease exists.");
        return matrixClipboardLease.State();
    }
    sealed class ClipboardLease : NativeWindow,IDisposable {
        readonly ManualResetEvent ready=new ManualResetEvent(false),release=new ManualResetEvent(false);
        readonly Stopwatch elapsed=new Stopwatch();Thread thread;volatile string error;volatile bool expired;uint ownerThread;
        public void Start() {
            thread=new Thread(delegate() {
                bool opened=false;
                try {
                    MatrixGuard();ownerThread=GetCurrentThreadId();
                    CreateHandle(new CreateParams {Caption="Laqay owned clipboard lease",Parent=new IntPtr(-3)});
                    opened=OpenClipboard(Handle);
                    if(!opened) throw new InvalidOperationException("The fixture did not obtain the clipboard lock.");
                    elapsed.Start();ready.Set();if(!release.WaitOne(10000)) {expired=true;error="The owned clipboard lock exceeded ten seconds.";}
                }catch(Exception failure){error=failure.Message;ready.Set();}
                finally {if(opened && !CloseClipboard()) error="The owned clipboard lease did not close normally.";if(Handle!=IntPtr.Zero) DestroyHandle();}
            });
            thread.IsBackground=true;thread.SetApartmentState(ApartmentState.STA);thread.Start();
            if(!ready.WaitOne(3000) || error!=null) {Dispose();throw new InvalidOperationException("Clipboard lock setup failed: "+error);}
        }
        public object State() {
            var window=GetOpenClipboardWindow();uint pid=0;
            uint observedThread=window==IntPtr.Zero?0:GetWindowThreadProcessId(window,out pid);
            bool rejected=!OpenClipboard(IntPtr.Zero);
            if(!rejected) CloseClipboard();
            uint expectedPid=(uint)Process.GetCurrentProcess().Id;
            bool held=window!=IntPtr.Zero && window==Handle && observedThread==ownerThread && pid==expectedPid
                && thread.IsAlive && !release.WaitOne(0) && !expired && error==null && rejected;
            return new {Held=held,ProbeRejected=rejected,Window=window.ToInt64(),ExpectedWindow=Handle.ToInt64(),
                OwnerPid=pid,ExpectedPid=expectedPid,OwnerThread=observedThread,ExpectedThread=ownerThread,
                ElapsedMilliseconds=elapsed.ElapsedMilliseconds,Expired=expired,Error=error};
        }
        public void Dispose() {
            release.Set();if(thread!=null && !thread.Join(3000)) throw new InvalidOperationException("The owned clipboard lock did not stop.");
            ready.Dispose();release.Dispose();if(error!=null) throw new InvalidOperationException(error);
        }
    }
    public static void HeldPaste(IntPtr window) {
        MatrixGuard();ExplorerWindow(window);
        if(GetForegroundWindow()!=window) throw new InvalidOperationException("The repeat fixture lost foreground.");
        var events=new List<Input>();events.Add(new Input {type=1,value=new Union {key=new Key {vk=17}}});
        for(int i=0;i<8;i++) events.Add(new Input {type=1,value=new Union {key=new Key {vk=86}}});
        events.Add(new Input {type=1,value=new Union {key=new Key {vk=86,flags=2}}});
        events.Add(new Input {type=1,value=new Union {key=new Key {vk=17,flags=2}}});Send(events.ToArray());
    }
    public static object SecondApplication() {
        MatrixGuard();if(application==null || application.HasExited) throw new InvalidOperationException("The original application must be running.");
        IntPtr ownedJob=CreateJobObjectW(IntPtr.Zero,null);Process candidate=null;bool forced=false;
        if(ownedJob==IntPtr.Zero) throw new InvalidOperationException("Cannot create the second-instance job.");
        try {
            var limits=new JobLimits();limits.basic.flags=0x2000;
            if(!SetInformationJobObject(ownedJob,9,ref limits,(uint)Marshal.SizeOf(typeof(JobLimits)))) throw new InvalidOperationException("Cannot bound the second instance.");
            candidate=Process.Start(new ProcessStartInfo(application.MainModule.FileName) {UseShellExecute=false,CreateNoWindow=true});
            if(candidate==null) throw new InvalidOperationException("The second instance did not start.");
            if(!candidate.HasExited && !AssignProcessToJobObject(ownedJob,candidate.Handle) && !candidate.HasExited) throw new InvalidOperationException("Cannot contain the second instance.");
            forced=!candidate.WaitForExit(5000);
            if(forced) throw new InvalidOperationException("The second instance did not exit normally.");
            if(candidate.ExitCode!=0 || !ApplicationReady()) throw new InvalidOperationException("Single-instance behavior failed.");
            return new {ExitCode=candidate.ExitCode,Forced=false,OriginalPid=application.Id,SecondPid=candidate.Id};
        } finally {
            CloseHandle(ownedJob);
            if(candidate!=null) {
                if(!candidate.WaitForExit(3000)) {candidate.Kill();candidate.WaitForExit(3000);candidate.Dispose();throw new InvalidOperationException("The exact owned second instance required forced cleanup.");}
                candidate.Dispose();
            }
        }
    }
    public static object MatrixResources() {
        MatrixGuard();if(application==null || application.HasExited) throw new InvalidOperationException("The application is missing.");application.Refresh();
        return new {Pid=application.Id,CpuMilliseconds=application.TotalProcessorTime.TotalMilliseconds,
            WorkingSetBytes=application.WorkingSet64,PrivateBytes=application.PrivateMemorySize64,
            PeakWorkingSetBytes=application.PeakWorkingSet64,Handles=application.HandleCount,Threads=application.Threads.Count};
    }
    public static bool MatrixApplicationResponsive() {
        MatrixGuard();var window=AppWindow();UIntPtr result;
        return window!=IntPtr.Zero && SendMessageTimeoutW(window,0,IntPtr.Zero,IntPtr.Zero,0x23,500,out result)!=IntPtr.Zero;
    }
    public static void BeginMatrixEditor() {
        MatrixGuard();if(matrixEditor!=null) throw new InvalidOperationException("An editor fixture already exists.");
        matrixEditor=new MatrixEditor();matrixEditor.Start();
    }
    public static void FocusMatrixEditor(bool rich) {
        MatrixGuard();if(matrixEditor==null) throw new InvalidOperationException("No owned editor fixture.");
        var handle=matrixEditor.Handle;
        // This form belongs to our process. Repeated Alt input on an already
        // active editor can enter menu preprocessing instead of preparing text input.
        if(GetForegroundWindow()!=handle) {SetForegroundWindow(handle);Thread.Sleep(200);}
        if(GetForegroundWindow()!=handle) throw new InvalidOperationException("The owned guest editor is not foreground.");
        // Select the child after activation, which can otherwise restore a different control.
        matrixEditor.Invoke(delegate(){matrixEditor.Select(rich);});
        Thread.Sleep(100);RequireMatrixEditorFocus();
    }
    static void RequireMatrixEditorFocus() {
        bool focused=false;matrixEditor.Invoke(delegate(){focused=matrixEditor.InputReady;});
        if(GetForegroundWindow()!=matrixEditor.Handle || !focused) throw new InvalidOperationException("The selected editor control does not own native keyboard focus.");
    }
    public static object MatrixEditorState() {
        MatrixGuard();if(matrixEditor==null) throw new InvalidOperationException("No editor fixture.");
        object state=null;matrixEditor.Invoke(delegate(){state=matrixEditor.State();});return state;
    }
    public static void PasteMatrixEditor() {
        MatrixGuard();if(matrixEditor==null || GetForegroundWindow()!=matrixEditor.Handle) throw new InvalidOperationException("The editor fixture lost foreground.");
        RequireMatrixEditorFocus();
        SendMatrixEditorPaste();
    }
    static void SendMatrixEditorPaste() {
        Send(new[]{new Input {type=1,value=new Union {key=new Key {vk=17}}},new Input {type=1,value=new Union {key=new Key {vk=86}}},
            new Input {type=1,value=new Union {key=new Key {vk=86,flags=2}}},new Input {type=1,value=new Union {key=new Key {vk=17,flags=2}}}});
    }
    public static void PasteMatrixEditorFromUiThread() {
        MatrixGuard();if(matrixEditor==null) throw new InvalidOperationException("No editor fixture.");
        matrixEditor.Invoke(delegate(){
            if(GetForegroundWindow()!=matrixEditor.Handle || !matrixEditor.InputReady) throw new InvalidOperationException("The editor-thread reference lost native focus.");
            SendMatrixEditorPaste();
        });
    }
    public static string MatrixEditorText() {
        MatrixGuard();if(matrixEditor==null) throw new InvalidOperationException("No editor fixture.");
        string text=null;matrixEditor.Invoke(delegate(){text=matrixEditor.Text;});return text;
    }
    public static void EndMatrixEditor() {
        var owned=matrixEditor;matrixEditor=null;
        try {if(owned!=null) owned.Dispose();}
        finally {EndNativeUnicodeFixture();}
    }
    static void EndNativeUnicodeFixture() {if(matrixTextSource!=null){matrixTextSource.DestroyHandle();matrixTextSource=null;matrixTextThread=0;}}
    public static void BeginMatrixReferenceHook() {
        MatrixGuard();if(matrixEditor==null || matrixReferenceHook!=null) throw new InvalidOperationException("Unexpected reference-hook context.");
        matrixReferenceHook=new MatrixReferenceHook(matrixEditor.Handle);matrixReferenceHook.Start();
    }
    public static object EndMatrixReferenceHook() {
        var owned=matrixReferenceHook;matrixReferenceHook=null;if(owned==null) return null;
        owned.Dispose();return owned.State();
    }
    sealed class MatrixReferenceHook : IDisposable {
        delegate IntPtr HookCallback(int code,IntPtr wparam,IntPtr lparam);
        [StructLayout(LayoutKind.Sequential)] struct HookMessage {
            public IntPtr window;public uint message;public UIntPtr wparam;public IntPtr lparam;public uint time;public int x,y;public uint unused;
        }
        [DllImport("user32.dll",SetLastError=true)] static extern IntPtr SetWindowsHookExW(int kind,HookCallback callback,IntPtr module,uint threadId);
        [DllImport("user32.dll",SetLastError=true)] static extern bool UnhookWindowsHookEx(IntPtr hook);
        [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook,int code,IntPtr wparam,IntPtr lparam);
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] static extern IntPtr GetModuleHandleW(string name);
        [DllImport("user32.dll")] static extern bool PeekMessageW(out HookMessage message,IntPtr window,uint first,uint last,uint remove);
        [DllImport("user32.dll")] static extern int GetMessageW(out HookMessage message,IntPtr window,uint first,uint last);
        [DllImport("user32.dll",SetLastError=true)] static extern bool PostThreadMessageW(uint thread,uint message,UIntPtr wparam,IntPtr lparam);
        [DllImport("user32.dll")] static extern UIntPtr SetTimer(IntPtr window,UIntPtr id,uint milliseconds,IntPtr callback);
        [DllImport("user32.dll")] static extern bool KillTimer(IntPtr window,UIntPtr id);
        readonly IntPtr target;readonly ManualResetEvent ready=new ManualResetEvent(false);
        Thread thread;HookCallback callback;uint ownerThread;string error;bool expired,removed;
        int down,up,blocked;
        public MatrixReferenceHook(IntPtr targetWindow) {target=targetWindow;}
        IntPtr Forward(int code,IntPtr wparam,IntPtr lparam) {
            // Chain immediately. Count only Ctrl/V directed at the owned fixture;
            // no foreground snapshots, clipboard calls, or paste work are queued.
            var result=CallNextHookEx(IntPtr.Zero,code,wparam,lparam);
            if(code==0 && GetForegroundWindow()==target) {
                int key=Marshal.ReadInt32(lparam);
                if(key==17 || key==86 || key==162 || key==163) {
                    long message=wparam.ToInt64();
                    if(message==0x100 || message==0x104) down++;
                    if(message==0x101 || message==0x105) up++;
                    if(result!=IntPtr.Zero) blocked++;
                }
            }
            return result;
        }
        public void Start() {
            thread=new Thread(delegate(){
                IntPtr hook=IntPtr.Zero;UIntPtr timer=UIntPtr.Zero;
                try {
                    MatrixGuard();ownerThread=GetCurrentThreadId();HookMessage message;
                    PeekMessageW(out message,IntPtr.Zero,0,0,0);
                    callback=Forward;hook=SetWindowsHookExW(13,callback,GetModuleHandleW(null),0);
                    if(hook==IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                    timer=SetTimer(IntPtr.Zero,UIntPtr.Zero,10000,IntPtr.Zero);
                    if(timer==UIntPtr.Zero) throw new InvalidOperationException("Cannot bound the reference hook.");
                    ready.Set();int status;
                    while((status=GetMessageW(out message,IntPtr.Zero,0,0))>0) {
                        if(message.message==0x113 && message.wparam==timer) {expired=true;break;}
                    }
                    if(status<0) throw new InvalidOperationException("The reference message pump failed.");
                }catch(Exception failure){error=failure.Message;ready.Set();}
                finally {
                    if(timer!=UIntPtr.Zero) KillTimer(IntPtr.Zero,timer);
                    if(hook!=IntPtr.Zero) {removed=UnhookWindowsHookEx(hook);if(!removed) error="The reference hook did not unregister.";}
                    GC.KeepAlive(callback);
                }
            });thread.IsBackground=true;thread.SetApartmentState(ApartmentState.STA);thread.Start();
            if(!ready.WaitOne(3000) || error!=null) {Dispose();throw new InvalidOperationException("Reference hook setup failed: "+error);}
        }
        public object State() {return new {Down=down,Up=up,NextHookBlocked=blocked,Expired=expired,Removed=removed,Error=error};}
        public void Dispose() {
            if(thread!=null && thread.IsAlive) {
                if(!PostThreadMessageW(ownerThread,0x12,UIntPtr.Zero,IntPtr.Zero)) throw new InvalidOperationException("Cannot stop the owned reference hook.");
                if(!thread.Join(3000)) throw new InvalidOperationException("The owned reference hook did not stop.");
            }
            ready.Dispose();if(error!=null) throw new InvalidOperationException(error);
        }
    }
    sealed class MatrixEditor : IDisposable,IMessageFilter {
        [StructLayout(LayoutKind.Sequential)] struct GuiInfo {
            public uint size,flags;public IntPtr active,focus,capture,menuOwner,moveSize,caret;public int left,top,right,bottom;
        }
        [DllImport("user32.dll",SetLastError=true)] static extern bool GetGUIThreadInfo(uint thread,ref GuiInfo info);
        GuiInfo ThreadInfo() {
            var info=new GuiInfo {size=(uint)Marshal.SizeOf(typeof(GuiInfo))};
            if(!GetGUIThreadInfo(GetCurrentThreadId(),ref info)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            return info;
        }
        [DllImport("user32.dll")] static extern IntPtr GetFocus();
        [DllImport("user32.dll")] static extern short GetKeyState(int key);
        readonly List<object> receivedKeys=new List<object>();
        public bool PreFilterMessage(ref Message message) {
            // Observe only Ctrl/V queue messages for our disposable form/controls.
            // Always continue normal dispatch; never register a desktop hook.
            long key=message.WParam.ToInt64();
            if(receivedKeys.Count<16 && (message.HWnd==form.Handle || message.HWnd==plain.Handle || message.HWnd==rich.Handle)
                && message.Msg>=0x100 && message.Msg<=0x105 && (key==17 || key==86 || key==162 || key==163)) {
                receivedKeys.Add(new {Message=message.Msg,Key=key,ControlWindow=message.HWnd.ToInt64(),
                    FocusWindow=GetFocus().ToInt64(),Foreground=GetForegroundWindow()==Handle,
                    ControlDown=(GetKeyState(17)&0x8000)!=0,AltDown=(GetKeyState(18)&0x8000)!=0,
                    ShiftDown=(GetKeyState(16)&0x8000)!=0,Milliseconds=Environment.TickCount});
            }
            return false;
        }
        readonly ManualResetEvent ready=new ManualResetEvent(false);Thread thread;Form form;TextBox plain;RichTextBox rich;bool selectedRich;string error;
        public IntPtr Handle {get;private set;}
        public string Text {get{return selectedRich?rich.Text:plain.Text;}}
        public void Invoke(Action action) {if(form==null || form.IsDisposed) throw new InvalidOperationException("The editor fixture closed unexpectedly.");form.Invoke(action);}
        TextBoxBase Target {get{return selectedRich?(TextBoxBase)rich:plain;}}
        public bool Focused {get{return Target.Focused && GetFocus()==Target.Handle && form.ActiveControl==Target;}}
        public bool InputReady {get{return Focused && (ThreadInfo().flags&0x1e)==0;}}
        public object State() {var gui=ThreadInfo();return new {Rich=selectedRich,Foreground=GetForegroundWindow()==Handle,Focused=Focused,
            InputReady=Focused && (gui.flags&0x1e)==0,GuiFlags=gui.flags,MenuOwner=gui.menuOwner.ToInt64(),
            ControlWindow=Target.Handle.ToInt64(),FocusWindow=GetFocus().ToInt64(),Visible=Target.Visible,
            Enabled=Target.Enabled,ReadOnly=Target.ReadOnly,TextLength=Target.TextLength,
            ClipboardSequence=GetClipboardSequenceNumber(),ClipboardUnicode=IsClipboardFormatAvailable(13),ReceivedKeys=receivedKeys.ToArray()};}
        public void Select(bool useRich) {
            selectedRich=useRich;plain.Clear();rich.Clear();receivedKeys.Clear();form.ActiveControl=Target;Target.Select();
            if(!Target.Focus() || !Focused) throw new InvalidOperationException("The owned editor child could not receive keyboard focus.");
        }
        public void Start() {
            thread=new Thread(delegate(){
                try {
                    MatrixGuard();form=new Form {Text="Laqay disposable editor fixture",Width=600,Height=400};
                    plain=new TextBox {Multiline=true,Dock=DockStyle.Top,Height=120};rich=new RichTextBox {Dock=DockStyle.Fill};
                    form.Controls.Add(rich);form.Controls.Add(plain);
                    form.Shown+=delegate {Handle=form.Handle;ready.Set();};
                    Application.AddMessageFilter(this);try{Application.Run(form);}finally{Application.RemoveMessageFilter(this);}
                }catch(Exception failure){error=failure.Message;ready.Set();}
                finally {if(form!=null) form.Dispose();}
            });thread.IsBackground=true;thread.SetApartmentState(ApartmentState.STA);thread.Start();
            if(!ready.WaitOne(5000) || error!=null) throw new InvalidOperationException("The guest editor fixture failed: "+error);
        }
        public void Dispose() {
            if(form!=null && !form.IsDisposed) form.BeginInvoke(new Action(delegate(){form.Close();}));
            if(thread!=null && !thread.Join(5000)) throw new InvalidOperationException("The owned editor fixture did not close.");ready.Dispose();
        }
    }
}
