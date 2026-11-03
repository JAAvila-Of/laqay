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
    static void MatrixGuard() { LifecycleGuard(); }
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
        Send(new[]{new Input {type=1,value=new Union {key=new Key {vk=18}}},new Input {type=1,value=new Union {key=new Key {vk=18,flags=2}}}});
        SetForegroundWindow(handle);Thread.Sleep(200);
        if(GetForegroundWindow()!=handle) throw new InvalidOperationException("The owned guest editor is not foreground.");
        // Select the child after activation, which can otherwise restore a different control.
        matrixEditor.Invoke(delegate(){matrixEditor.Select(rich);});
        Thread.Sleep(100);RequireMatrixEditorFocus();
    }
    static void RequireMatrixEditorFocus() {
        bool focused=false;matrixEditor.Invoke(delegate(){focused=matrixEditor.Focused;});
        if(GetForegroundWindow()!=matrixEditor.Handle || !focused) throw new InvalidOperationException("The selected editor control does not own native keyboard focus.");
    }
    public static object MatrixEditorState() {
        MatrixGuard();if(matrixEditor==null) throw new InvalidOperationException("No editor fixture.");
        object state=null;matrixEditor.Invoke(delegate(){state=matrixEditor.State();});return state;
    }
    public static void PasteMatrixEditor() {
        MatrixGuard();if(matrixEditor==null || GetForegroundWindow()!=matrixEditor.Handle) throw new InvalidOperationException("The editor fixture lost foreground.");
        RequireMatrixEditorFocus();
        Send(new[]{new Input {type=1,value=new Union {key=new Key {vk=17}}},new Input {type=1,value=new Union {key=new Key {vk=86}}},
            new Input {type=1,value=new Union {key=new Key {vk=86,flags=2}}},new Input {type=1,value=new Union {key=new Key {vk=17,flags=2}}}});
    }
    public static string MatrixEditorText() {
        MatrixGuard();if(matrixEditor==null) throw new InvalidOperationException("No editor fixture.");
        string text=null;matrixEditor.Invoke(delegate(){text=matrixEditor.Text;});return text;
    }
    public static void EndMatrixEditor() {var owned=matrixEditor;matrixEditor=null;if(owned!=null) owned.Dispose();}
    sealed class MatrixEditor : IDisposable {
        [DllImport("user32.dll")] static extern IntPtr GetFocus();
        readonly ManualResetEvent ready=new ManualResetEvent(false);Thread thread;Form form;TextBox plain;RichTextBox rich;bool selectedRich;string error;
        public IntPtr Handle {get;private set;}
        public string Text {get{return selectedRich?rich.Text:plain.Text;}}
        public void Invoke(Action action) {if(form==null || form.IsDisposed) throw new InvalidOperationException("The editor fixture closed unexpectedly.");form.Invoke(action);}
        TextBoxBase Target {get{return selectedRich?(TextBoxBase)rich:plain;}}
        public bool Focused {get{return Target.Focused && GetFocus()==Target.Handle && form.ActiveControl==Target;}}
        public object State() {return new {Rich=selectedRich,Foreground=GetForegroundWindow()==Handle,Focused=Focused,
            ControlWindow=Target.Handle.ToInt64(),FocusWindow=GetFocus().ToInt64(),Visible=Target.Visible,
            Enabled=Target.Enabled,ReadOnly=Target.ReadOnly,TextLength=Target.TextLength};}
        public void Select(bool useRich) {
            selectedRich=useRich;plain.Clear();rich.Clear();form.ActiveControl=Target;Target.Select();
            if(!Target.Focus() || !Focused) throw new InvalidOperationException("The owned editor child could not receive keyboard focus.");
        }
        public void Start() {
            thread=new Thread(delegate(){
                try {
                    MatrixGuard();form=new Form {Text="Laqay disposable editor fixture",Width=600,Height=400};
                    plain=new TextBox {Multiline=true,Dock=DockStyle.Top,Height=120};rich=new RichTextBox {Dock=DockStyle.Fill};
                    form.Controls.Add(rich);form.Controls.Add(plain);
                    form.Shown+=delegate {Handle=form.Handle;ready.Set();};Application.Run(form);
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
