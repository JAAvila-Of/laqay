using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;
using Com=System.Runtime.InteropServices.ComTypes;

public static partial class LaqayGuestDesktop {
    [DllImport("ole32.dll",EntryPoint="OleInitialize")] static extern int VirtualOleInitialize(IntPtr reserved);
    [DllImport("ole32.dll",EntryPoint="OleUninitialize")] static extern void VirtualOleUninitialize();
    [DllImport("ole32.dll",EntryPoint="OleSetClipboard")] static extern int VirtualOleSetClipboard(Com.IDataObject source);
    [DllImport("ole32.dll",EntryPoint="OleIsCurrentClipboard")] static extern int VirtualOleIsCurrentClipboard(Com.IDataObject source);
    [DllImport("ole32.dll",EntryPoint="ReleaseStgMedium")] static extern void VirtualReleaseMedium(ref Com.STGMEDIUM medium);
    [DllImport("ole32.dll",EntryPoint="CreateStreamOnHGlobal")] static extern int VirtualCreateStream(IntPtr memory,bool deleteOnRelease,out Com.IStream stream);
    static VirtualClipboard virtualClipboard;
    public const string VirtualFileName="virtual-fixture.txt";
    static readonly byte[] VirtualContents=System.Text.Encoding.UTF8.GetBytes("Laqay virtual file fixture.\r\n");

    public static void BeginVirtualFileClipboard() {
        MatrixGuard();if(virtualClipboard!=null) throw new InvalidOperationException("A virtual file provider already exists.");
        virtualClipboard=new VirtualClipboard();virtualClipboard.Start();
    }
    public static object VirtualFileClipboardState() {
        MatrixGuard();if(virtualClipboard==null) throw new InvalidOperationException("No virtual file provider exists.");
        return virtualClipboard.State();
    }
    public static void EndVirtualFileClipboard() {
        var owned=virtualClipboard;if(owned==null) return;
        owned.Dispose();virtualClipboard=null;
    }

    static IntPtr VirtualMemory(byte[] bytes) {
        IntPtr memory=GlobalAlloc(0x42,(UIntPtr)bytes.Length);
        if(memory==IntPtr.Zero) throw new OutOfMemoryException();
        IntPtr pointer=GlobalLock(memory);
        if(pointer==IntPtr.Zero){GlobalFree(memory);throw new InvalidOperationException("The fixture HGLOBAL could not be locked.");}
        try{Marshal.Copy(bytes,0,pointer,bytes.Length);}finally{GlobalUnlock(memory);}
        return memory;
    }
    static string VirtualHash(byte[] bytes) {
        using(var sha=System.Security.Cryptography.SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-","");
    }

    [ComVisible(true),ClassInterface(ClassInterfaceType.None)]
    public sealed class VirtualFileData : Com.IDataObject {
        readonly short descriptor,contents,png,effect;readonly byte[] image;
        readonly object sync=new object();readonly Dictionary<string,int> reads=new Dictionary<string,int>();
        int total;
        public VirtualFileData(short descriptor,short contents,short png,short effect,byte[] image) {
            this.descriptor=descriptor;this.contents=contents;this.png=png;this.effect=effect;this.image=(byte[])image.Clone();
        }
        public object Evidence() {lock(sync){return new {Reads=new Dictionary<string,int>(reads),ContentReads=reads.ContainsKey("FileContents")?reads["FileContents"]:0,TotalReads=total};}}
        public int ContentReads {get{lock(sync){return reads.ContainsKey("FileContents")?reads["FileContents"]:0;}}}
        Com.FORMATETC Format(short format,Com.TYMED medium,int index) {
            return new Com.FORMATETC {cfFormat=format,dwAspect=Com.DVASPECT.DVASPECT_CONTENT,lindex=index,tymed=medium,ptd=IntPtr.Zero};
        }
        public int QueryGetData(ref Com.FORMATETC format) {
            if(format.ptd!=IntPtr.Zero) return unchecked((int)0x80040065);
            if(format.dwAspect!=Com.DVASPECT.DVASPECT_CONTENT) return unchecked((int)0x8004006B);
            bool file=format.cfFormat==contents;
            if(format.cfFormat!=descriptor && !file && format.cfFormat!=png && format.cfFormat!=effect) return unchecked((int)0x80040064);
            if(format.lindex!=(file?0:-1)) return unchecked((int)0x80040068);
            var supported=file?Com.TYMED.TYMED_ISTREAM|Com.TYMED.TYMED_HGLOBAL:Com.TYMED.TYMED_HGLOBAL;
            return (format.tymed&supported)!=0?0:unchecked((int)0x80040069);
        }
        public void GetData(ref Com.FORMATETC format,out Com.STGMEDIUM medium) {
            Marshal.ThrowExceptionForHR(QueryGetData(ref format));medium=new Com.STGMEDIUM();
            string name;byte[] bytes;
            if(format.cfFormat==descriptor) {
                name="FileGroupDescriptorW";bytes=new byte[596];
                Buffer.BlockCopy(BitConverter.GetBytes(1),0,bytes,0,4);
                Buffer.BlockCopy(BitConverter.GetBytes(0x80000044u),0,bytes,4,4);
                Buffer.BlockCopy(BitConverter.GetBytes(0x80u),0,bytes,40,4);
                Buffer.BlockCopy(BitConverter.GetBytes(VirtualContents.Length),0,bytes,72,4);
                byte[] filename=System.Text.Encoding.Unicode.GetBytes(VirtualFileName+"\0");Buffer.BlockCopy(filename,0,bytes,76,filename.Length);
            }else if(format.cfFormat==contents){name="FileContents";bytes=VirtualContents;}
            else if(format.cfFormat==png){name="PNG";bytes=image;}
            else{name="Preferred DropEffect";bytes=BitConverter.GetBytes(1);}
            lock(sync){if(total>=128) throw new InvalidOperationException("The bounded virtual provider read budget expired.");total++;reads[name]=reads.ContainsKey(name)?reads[name]+1:1;}
            IntPtr memory=VirtualMemory(bytes);
            if(format.cfFormat==contents && (format.tymed&Com.TYMED.TYMED_ISTREAM)!=0) {
                Com.IStream stream;int result=VirtualCreateStream(memory,true,out stream);
                if(result<0){GlobalFree(memory);Marshal.ThrowExceptionForHR(result);}
                // GlobalSize may round up the allocation; do not expose padding as file bytes.
                try{stream.SetSize(bytes.Length);stream.Seek(0,0,IntPtr.Zero);medium.unionmember=Marshal.GetComInterfaceForObject(stream,typeof(Com.IStream));medium.tymed=Com.TYMED.TYMED_ISTREAM;}
                finally{Marshal.ReleaseComObject(stream);}
            }else{medium.tymed=Com.TYMED.TYMED_HGLOBAL;medium.unionmember=memory;}
        }
        public Com.IEnumFORMATETC EnumFormatEtc(Com.DATADIR direction) {
            if(direction!=Com.DATADIR.DATADIR_GET) throw new COMException("Only fixture reads are supported.",unchecked((int)0x80004001));
            // Advertise the image first: virtual-file precedence must not depend on enumeration order.
            return new VirtualFormats(new[]{Format(png,Com.TYMED.TYMED_HGLOBAL,-1),Format(descriptor,Com.TYMED.TYMED_HGLOBAL,-1),
                Format(contents,Com.TYMED.TYMED_ISTREAM|Com.TYMED.TYMED_HGLOBAL,0),Format(effect,Com.TYMED.TYMED_HGLOBAL,-1)});
        }
        public void SetData(ref Com.FORMATETC format,ref Com.STGMEDIUM medium,bool release) {
            // This immutable copy-only source does not accept target-side mutations.
            throw new COMException("The fixture is read-only.",unchecked((int)0x80004001));
        }
        public void GetDataHere(ref Com.FORMATETC format,ref Com.STGMEDIUM medium){throw new COMException("Use GetData.",unchecked((int)0x80040069));}
        public int GetCanonicalFormatEtc(ref Com.FORMATETC input,out Com.FORMATETC output){output=input;output.ptd=IntPtr.Zero;return 0x40130;}
        public int DAdvise(ref Com.FORMATETC format,Com.ADVF flags,Com.IAdviseSink sink,out int connection){connection=0;return unchecked((int)0x80040003);}
        public void DUnadvise(int connection){throw new COMException("No advisory connection.",unchecked((int)0x80040003));}
        public int EnumDAdvise(out Com.IEnumSTATDATA result){result=null;return unchecked((int)0x80040003);}
    }
    [ComVisible(true),ClassInterface(ClassInterfaceType.None)]
    public sealed class VirtualFormats : Com.IEnumFORMATETC {
        readonly Com.FORMATETC[] formats;int position;
        public VirtualFormats(Com.FORMATETC[] formats){this.formats=(Com.FORMATETC[])formats.Clone();}
        public int Next(int count,Com.FORMATETC[] result,int[] fetched) {
            if(count<0 || result==null || result.Length<count || (fetched==null && count!=1)) return unchecked((int)0x80070057);
            int copied=0;while(copied<count && position<formats.Length) result[copied++]=formats[position++];
            if(fetched!=null && fetched.Length>0) fetched[0]=copied;return copied==count?0:1;
        }
        public int Skip(int count){if(count<0) return unchecked((int)0x80070057);int remaining=formats.Length-position;position+=Math.Min(count,remaining);return count<=remaining?0:1;}
        public int Reset(){position=0;return 0;}
        public void Clone(out Com.IEnumFORMATETC clone){var copy=new VirtualFormats(formats);copy.position=position;clone=copy;}
    }

    sealed class VirtualClipboard : IDisposable {
        readonly ManualResetEvent ready=new ManualResetEvent(false);Thread thread;Control control;ApplicationContext context;
        VirtualFileData source;volatile string error;volatile bool expired;bool cleared;uint sourceThread;uint initialSequence;
        public void Start() {
            thread=new Thread(delegate(){bool initialized=false;System.Windows.Forms.Timer timer=null;
                try {
                    MatrixGuard();Marshal.ThrowExceptionForHR(VirtualOleInitialize(IntPtr.Zero));initialized=true;sourceThread=GetCurrentThreadId();
                    control=new Control();IntPtr unused=control.Handle;context=new ApplicationContext();
                    source=new VirtualFileData(unchecked((short)RegisterClipboardFormatW("FileGroupDescriptorW")),unchecked((short)RegisterClipboardFormatW("FileContents")),
                        unchecked((short)RegisterClipboardFormatW("PNG")),unchecked((short)RegisterClipboardFormatW("Preferred DropEffect")),MatrixPng(2));
                    Marshal.ThrowExceptionForHR(VirtualOleSetClipboard(source));initialSequence=GetClipboardSequenceNumber();
                    timer=new System.Windows.Forms.Timer {Interval=60000};timer.Tick+=delegate{expired=true;context.ExitThread();};timer.Start();ready.Set();Application.Run(context);
                }catch(Exception failure){error=failure.Message;ready.Set();}
                finally {
                    if(timer!=null) timer.Dispose();
                    if(source!=null && initialized && VirtualOleIsCurrentClipboard(source)==0){cleared=VirtualOleSetClipboard(null)==0;}
                    else cleared=source==null || (initialized && VirtualOleIsCurrentClipboard(source)!=0);
                    if(control!=null) control.Dispose();if(context!=null) context.Dispose();if(initialized) VirtualOleUninitialize();
                }
            });thread.IsBackground=true;thread.SetApartmentState(ApartmentState.STA);thread.Start();
            if(!ready.WaitOne(5000) || error!=null) throw new InvalidOperationException("The virtual file provider failed: "+error);
        }
        public object State() {
            if(control==null || control.IsDisposed || !thread.IsAlive) throw new InvalidOperationException("The virtual file provider stopped: "+error);
            return control.Invoke(new Func<object>(delegate {
                uint owner;GetWindowThreadProcessId(GetClipboardOwner(),out owner);
                return new {Current=VirtualOleIsCurrentClipboard(source)==0,OwnerPid=owner,SourcePid=System.Diagnostics.Process.GetCurrentProcess().Id,
                    SourceThread=sourceThread,Sequence=GetClipboardSequenceNumber(),InitialSequence=initialSequence,HasPng=IsClipboardFormatAvailable(RegisterClipboardFormatW("PNG")),
                    HasDescriptor=IsClipboardFormatAvailable(RegisterClipboardFormatW("FileGroupDescriptorW")),HasContents=IsClipboardFormatAvailable(RegisterClipboardFormatW("FileContents")),
                    HasFileDrop=IsClipboardFormatAvailable(15),ContentReads=source.ContentReads,Provider=source.Evidence(),Expired=expired,Error=error,
                    FileName=VirtualFileName,Length=VirtualContents.Length,Sha256=VirtualHash(VirtualContents)};
            }));
        }
        public void Dispose() {
            if(control!=null && !control.IsDisposed && thread.IsAlive) control.BeginInvoke(new Action(delegate {context.ExitThread();}));
            if(thread!=null && !thread.Join(5000)) throw new InvalidOperationException("The owned virtual file provider did not stop.");
            ready.Dispose();if(!cleared || error!=null || expired) throw new InvalidOperationException("The virtual file provider did not close normally: "+error);
        }
    }

    public static object TestVirtualFileProtocol() {
        // Heap-only protocol test: no OLE clipboard publication, registration, windows, or input.
        var data=new VirtualFileData(unchecked((short)0xc101),unchecked((short)0xc102),unchecked((short)0xc103),unchecked((short)0xc104),new byte[]{1,2,3});
        var formats=new Com.FORMATETC[4];var fetched=new int[1];var enumeration=data.EnumFormatEtc(Com.DATADIR.DATADIR_GET);
        if(enumeration.Next(4,formats,fetched)!=0 || fetched[0]!=4 || formats[0].cfFormat!=unchecked((short)0xc103)) throw new InvalidOperationException("The image-first format enumeration changed.");
        var request=formats[1];Com.STGMEDIUM medium;data.GetData(ref request,out medium);
        try{var pointer=GlobalLock(medium.unionmember);if(pointer==IntPtr.Zero) throw new InvalidOperationException("Descriptor lock failed.");
            try{if(Marshal.ReadInt32(pointer)!=1 || Marshal.ReadInt32(pointer,72)!=VirtualContents.Length || Marshal.PtrToStringUni(IntPtr.Add(pointer,76))!=VirtualFileName) throw new InvalidOperationException("The virtual descriptor is malformed.");}finally{GlobalUnlock(medium.unionmember);}
        }finally{VirtualReleaseMedium(ref medium);}
        request=formats[2];request.tymed=Com.TYMED.TYMED_ISTREAM;data.GetData(ref request,out medium);
        try{var stream=(Com.IStream)Marshal.GetObjectForIUnknown(medium.unionmember);
            try{Com.STATSTG stat;stream.Stat(out stat,1);if(stat.cbSize!=VirtualContents.Length) throw new InvalidOperationException("The virtual stream exposes allocation padding.");byte[] bytes=new byte[VirtualContents.Length];IntPtr read=Marshal.AllocHGlobal(4);
                try{stream.Read(bytes,bytes.Length,read);if(Marshal.ReadInt32(read)!=bytes.Length || VirtualHash(bytes)!=VirtualHash(VirtualContents)) throw new InvalidOperationException("The virtual stream differs from the fixture.");}finally{Marshal.FreeHGlobal(read);}
            }finally{Marshal.ReleaseComObject(stream);}
        }finally{VirtualReleaseMedium(ref medium);}
        request=formats[2];request.lindex=1;if(data.QueryGetData(ref request)>=0) throw new InvalidOperationException("An invalid virtual file index was accepted.");
        request=formats[2];request.tymed=Com.TYMED.TYMED_HGLOBAL;data.GetData(ref request,out medium);
        try{IntPtr pointer=GlobalLock(medium.unionmember);if(pointer==IntPtr.Zero) throw new InvalidOperationException("The content HGLOBAL could not be locked.");
            try{byte[] bytes=new byte[VirtualContents.Length];Marshal.Copy(pointer,bytes,0,bytes.Length);if(VirtualHash(bytes)!=VirtualHash(VirtualContents)) throw new InvalidOperationException("HGLOBAL content differs from the stream.");}finally{GlobalUnlock(medium.unionmember);}
        }finally{VirtualReleaseMedium(ref medium);}
        request=formats[0];data.GetData(ref request,out medium);
        try{IntPtr pointer=GlobalLock(medium.unionmember);if(pointer==IntPtr.Zero) throw new InvalidOperationException("The PNG HGLOBAL could not be locked.");
            try{byte[] bytes=new byte[3];Marshal.Copy(pointer,bytes,0,3);if(bytes[0]!=1 || bytes[1]!=2 || bytes[2]!=3) throw new InvalidOperationException("The image representation changed.");}finally{GlobalUnlock(medium.unionmember);}
        }finally{VirtualReleaseMedium(ref medium);}
        request=formats[2];request.tymed=Com.TYMED.TYMED_FILE;if(data.QueryGetData(ref request)>=0) throw new InvalidOperationException("An unsupported virtual medium was accepted.");
        request=formats[0];request.dwAspect=Com.DVASPECT.DVASPECT_ICON;if(data.QueryGetData(ref request)>=0) throw new InvalidOperationException("An unsupported virtual aspect was accepted.");
        Com.IEnumFORMATETC clone;enumeration.Reset();enumeration.Skip(1);enumeration.Clone(out clone);
        var one=new Com.FORMATETC[1];if(clone.Next(1,one,fetched)!=0 || one[0].cfFormat!=formats[1].cfFormat) throw new InvalidOperationException("Virtual format clone lost its cursor.");
        return new {Passed=true,Formats=4,ImageFirst=true,DescriptorBytes=596,FileLength=VirtualContents.Length,StreamExact=true,InvalidIndexRejected=true,InvalidMediumRejected=true,InvalidAspectRejected=true};
    }
}
