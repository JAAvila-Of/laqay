$ErrorActionPreference='Stop'
# Read the installed type library without constructing a control or opening a desktop.
if(-not ('LaqayRdpMetadata' -as [type])){
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using TYPEATTR=System.Runtime.InteropServices.ComTypes.TYPEATTR;
using FUNCDESC=System.Runtime.InteropServices.ComTypes.FUNCDESC;
public static class LaqayRdpMetadata {
    [DllImport("oleaut32.dll",CharSet=CharSet.Unicode)] static extern int LoadTypeLibEx(string file,int registration,out ITypeLib library);
    static void Members(ITypeInfo type,Dictionary<string,int> members,HashSet<Guid> seen) {
        IntPtr pointer;type.GetTypeAttr(out pointer);
        TYPEATTR attr;
        try {attr=(TYPEATTR)Marshal.PtrToStructure(pointer,typeof(TYPEATTR));} finally {type.ReleaseTypeAttr(pointer);}
        if(!seen.Add(attr.guid)) return;
        for(int i=0;i<attr.cFuncs;i++) {
            IntPtr function;type.GetFuncDesc(i,out function);
            try {
                var desc=(FUNCDESC)Marshal.PtrToStructure(function,typeof(FUNCDESC));
                string name,documentation,helpFile;int context;type.GetDocumentation(desc.memid,out name,out documentation,out context,out helpFile);
                members[name]=desc.memid;
            } finally {type.ReleaseFuncDesc(function);}
        }
        for(int i=0;i<attr.cImplTypes;i++) {int reference;type.GetRefTypeOfImplType(i,out reference);ITypeInfo parent;type.GetRefTypeInfo(reference,out parent);try {Members(parent,members,seen);} finally {Marshal.ReleaseComObject(parent);}}
    }
    public static void Check(string file) {
        ITypeLib library;Marshal.ThrowExceptionForHR(LoadTypeLibEx(file,2,out library));
        var required=new Dictionary<string,string[]> {
            {"IMsRdpClient7",new[] {"Server","UserName","Domain","DesktopWidth","DesktopHeight","ColorDepth","AdvancedSettings8","Connected","Connect","Disconnect"}},
            {"IMsRdpClientAdvancedSettings7",new[] {"AuthenticationLevel","EnableCredSspSupport","RedirectClipboard","RedirectDrives","RedirectPrinters","RedirectPorts","RedirectSmartCards","AudioRedirectionMode","AudioCaptureRedirectionMode","EnableAutoReconnect","ClearTextPassword"}},
            {"IMsTscAxEvents",new[] {"OnLoginComplete","OnDisconnected","OnFatalError"}}
        };
        var found=new HashSet<string>();bool coclass=false;
        try {
            for(int i=0;i<library.GetTypeInfoCount();i++) {
                string name,documentation,helpFile;int context;library.GetDocumentation(i,out name,out documentation,out context,out helpFile);
                ITypeInfo type;library.GetTypeInfo(i,out type);
                try {
                    if(name=="MsRdpClient10NotSafeForScripting") {IntPtr pointer;type.GetTypeAttr(out pointer);try {coclass=((TYPEATTR)Marshal.PtrToStructure(pointer,typeof(TYPEATTR))).guid==new Guid("A0C63C30-F08D-4AB4-907C-34905D770C7D");} finally {type.ReleaseTypeAttr(pointer);}}
                    if(!required.ContainsKey(name)) continue;
                    var members=new Dictionary<string,int>();Members(type,members,new HashSet<Guid>());
                    foreach(string member in required[name]) if(!members.ContainsKey(member)) throw new InvalidOperationException("Missing RDP member: "+name+"."+member);
                    if(name=="IMsTscAxEvents" && (members["OnLoginComplete"]!=3 || members["OnDisconnected"]!=4 || members["OnFatalError"]!=10)) throw new InvalidOperationException("Unexpected RDP event DISPIDs.");
                    found.Add(name);
                } finally {Marshal.ReleaseComObject(type);}
            }
            if(found.Count!=required.Count || !coclass) throw new InvalidOperationException("The required native RDP type library is unavailable.");
        } finally {Marshal.ReleaseComObject(library);}
    }
}
'@
}
[LaqayRdpMetadata]::Check((Join-Path $env:SystemRoot 'System32/mstscax.dll'))
Write-Output 'Native RDP metadata and event DISPIDs verified without activating a control.'
