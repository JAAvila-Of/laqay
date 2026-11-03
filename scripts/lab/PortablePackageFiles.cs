using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

// File-only policy. No process, clipboard, registry, desktop, or VM operations.
public static class LaqayPortableFiles {
    public sealed class Entry {
        public string Name;
        public long Length;
        public string Sha256;
        public bool Directory;
    }
    static readonly string[] Names={"laqay.exe","LICENSE","THIRD_PARTY_NOTICES.md","THIRD_PARTY_LICENSES.txt","TRADEMARKS.md","PORTABLE.md"};
    static void Require(bool value,string message) { if(!value) throw new InvalidOperationException(message); }
    public static string Hash(string path) {
        NoReparse(path);
        using(var file=File.OpenRead(path)) using(var hash=SHA256.Create())
            return BitConverter.ToString(hash.ComputeHash(file)).Replace("-","").ToLowerInvariant();
    }
    public static void NoReparse(string path) {
        var full=Path.GetFullPath(path);
        while(!String.IsNullOrEmpty(full)) {
            if(File.Exists(full)||System.IO.Directory.Exists(full))
                Require((File.GetAttributes(full)&FileAttributes.ReparsePoint)==0,"A reparse point is not an owned package path.");
            var parent=Path.GetDirectoryName(full);
            if(parent==full) break;
            full=parent;
        }
    }
    public static void Child(string root,string path) {
        root=Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar)+Path.DirectorySeparatorChar;
        path=Path.GetFullPath(path);
        Require(path.StartsWith(root,StringComparison.OrdinalIgnoreCase)&&path.Length>root.Length,"Path escapes its owned root.");
        NoReparse(root);NoReparse(path);
    }
    static string Json(Entry[] entries) { return new JavaScriptSerializer().Serialize(entries); }
    static Entry[] Parse(string json) { return new JavaScriptSerializer().Deserialize<Entry[]>(json); }
    public static string Archive(string path,string archiveHash,string executableHash) {
        Require(Regex.IsMatch(archiveHash??"","^[a-fA-F0-9]{64}$")&&Regex.IsMatch(executableHash??"","^[a-fA-F0-9]{64}$"),"Expected SHA-256 identities.");
        Require(String.Equals(Hash(path),archiveHash,StringComparison.OrdinalIgnoreCase),"Package archive hash differs.");
        var result=new List<Entry>();
        using(var archive=ZipFile.OpenRead(path)) {
            Require(archive.Entries.Count==Names.Length,"Unexpected archive entry count.");
            var found=new HashSet<string>(StringComparer.Ordinal);
            foreach(var entry in archive.Entries) {
                Require(Names.Contains(entry.FullName,StringComparer.Ordinal)&&found.Add(entry.FullName),"Unexpected, duplicate, or unsafe archive name.");
                Require(((entry.ExternalAttributes>>16)&0xF000)!=0xA000,"A symbolic-link archive entry is not allowed.");
                Require(entry.Length>0&&entry.Length<=16*1024*1024,"Unexpected archive entry size.");
                using(var input=entry.Open()) using(var hash=SHA256.Create()) {
                    var digest=BitConverter.ToString(hash.ComputeHash(input)).Replace("-","").ToLowerInvariant();
                    if(entry.FullName=="laqay.exe") Require(String.Equals(digest,executableHash,StringComparison.OrdinalIgnoreCase),"Archived executable hash differs.");
                    result.Add(new Entry{Name=entry.FullName,Length=entry.Length,Sha256=digest,Directory=false});
                }
            }
        }
        return Json(result.OrderBy(e=>e.Name,StringComparer.Ordinal).ToArray());
    }
    public static string Snapshot(string root) {
        NoReparse(root);Require(System.IO.Directory.Exists(root),"Snapshot root is missing.");
        root=Path.GetFullPath(root).TrimEnd('\\')+"\\";
        var result=new List<Entry>();var pending=new Stack<string>();pending.Push(root);
        while(pending.Count>0) foreach(var path in System.IO.Directory.GetFileSystemEntries(pending.Pop())) {
            Child(root,path);
            var directory=(File.GetAttributes(path)&FileAttributes.Directory)!=0;
            result.Add(new Entry{Name=Path.GetFullPath(path).Substring(root.Length),Directory=directory,
                Length=directory?0:new FileInfo(path).Length,Sha256=directory?"":Hash(path)});
            if(directory) pending.Push(path);
        }
        return Json(result.OrderBy(e=>e.Name,StringComparer.Ordinal).ToArray());
    }
    public static void Verify(string directory,string expected) {
        // Compare canonical inventories, including empty directories and every byte hash.
        var actual=Snapshot(directory);var normalized=Json(Parse(expected).OrderBy(e=>e.Name,StringComparer.Ordinal).ToArray());
        Require(actual==normalized,"Package or baseline tree differs from its recorded inventory.");
    }
    public static void Install(string root,string destination,string archivePath,string archiveHash,string executableHash) {
        Child(root,destination);Require(!System.IO.Directory.Exists(destination)&&!File.Exists(destination),"Refusing to replace an installation directory.");
        var inventory=Archive(archivePath,archiveHash,executableHash);
        System.IO.Directory.CreateDirectory(destination);
        using(var archive=ZipFile.OpenRead(archivePath)) foreach(var entry in archive.Entries) {
            var path=Path.Combine(destination,entry.FullName);Child(destination,path);
            using(var input=entry.Open()) using(var output=new FileStream(path,FileMode.CreateNew,FileAccess.Write)) input.CopyTo(output);
        }
        Verify(destination,inventory);
    }
    public static void Remove(string root,string directory,string inventory) {
        Child(root,directory);Verify(directory,inventory);
        var entries=Parse(inventory);
        Require(entries.Length==Names.Length&&entries.All(e=>!e.Directory&&Names.Contains(e.Name,StringComparer.Ordinal)),"Only a flat verified package can be removed.");
        foreach(var entry in entries) {var path=Path.Combine(directory,entry.Name);Child(directory,path);Require(Hash(path)==entry.Sha256,"Package changed during removal.");File.Delete(path);}
        // Never recursively delete an unexpected file or directory.
        System.IO.Directory.Delete(directory,false);
    }
}
