@echo off
setlocal EnableExtensions
title Phone to PC File Server

rem ================= SETTINGS =================
set "SRV_USER=adminlogin"
set "SRV_PASS=adminpassword"
set "SRV_PORT=8080"
set "SRV_ROOT=D:\server"
rem 1 = open the server to the internet (any Wi-Fi / mobile network), 0 = home Wi-Fi only
set "SRV_TUNNEL=1"

rem ---- ONE PERMANENT ADDRESS (pick ONE option, or leave both empty for a temporary link) ----
rem Option A: your own domain through Cloudflare.
rem   SRV_DOMAIN   = the address you set in Cloudflare, for example files.mysite.com
rem   SRV_CF_TOKEN = the long tunnel token from the Cloudflare dashboard
set "SRV_DOMAIN="
set "SRV_CF_TOKEN="
rem Option B: free permanent address like https://my-pc.tailnet-name.ts.net (Tailscale Funnel). 1 = use it
set "SRV_TAILSCALE=0"
rem Option C: plain IP link like http://203.0.113.5:8080 (no domain, only for your own friends). 1 = use it
rem   It tries to open the port on your router automatically (UPnP) and overrides the options above.
set "SRV_DIRECT=0"

rem ---- AUTOSTART WITH WINDOWS ----
rem 0 = off. 1 = start when you sign in to Windows, the console window is visible.
rem 2 = start when the PC boots, hidden, works even before anyone signs in.
set "SRV_AUTOSTART=0"

rem ---- TELEGRAM: post the connection link to a channel or chat ----
rem The bot deletes its old link message and posts the new one, so the current link is always there.
rem SRV_TG_TOKEN = bot token from BotFather. SRV_TG_CHAT = @channelname or a numeric id such as -1001234567890
rem The bot must be an administrator of the channel with the right to post and delete messages.
set "SRV_TG_TOKEN="
set "SRV_TG_CHAT="
rem Do not use these characters in the admin password: % ^ & ! "
rem ============================================

set "BATFILE=%~f0"

rem ---- Auto-elevate to Administrator ----
net session >nul 2>&1
if not "%errorlevel%"=="0" (
    powershell -NoProfile -Command "Start-Process -FilePath $env:BATFILE -Verb RunAs"
    exit /b
)

rem ---- Fallback if drive D: does not exist ----
if not exist "D:\" set "SRV_ROOT=%~dp0server"

if not exist "%SRV_ROOT%" mkdir "%SRV_ROOT%"
if not exist "%SRV_ROOT%\users" mkdir "%SRV_ROOT%\users"

rem ---- Firewall rule (local network) ----
netsh advfirewall firewall delete rule name="PhoneFileServer" >nul 2>&1
netsh advfirewall firewall add rule name="PhoneFileServer" dir=in action=allow protocol=TCP localport=%SRV_PORT% profile=any >nul 2>&1

rem ---- Autostart with Windows ----
if "%SRV_AUTOSTART%"=="1" goto as_logon
if "%SRV_AUTOSTART%"=="2" goto as_boot
schtasks /delete /tn "PhoneFileServer" /f >nul 2>&1
echo Autostart: OFF
goto as_done
:as_logon
schtasks /create /tn "PhoneFileServer" /tr "\"%BATFILE%\"" /sc onlogon /rl highest /delay 0000:20 /f >nul 2>&1
if errorlevel 1 (echo Autostart: could not create the task) else (echo Autostart: ON, the server starts when you sign in to Windows)
goto as_done
:as_boot
schtasks /create /tn "PhoneFileServer" /tr "\"%BATFILE%\"" /sc onstart /ru SYSTEM /rl highest /delay 0000:30 /f >nul 2>&1
if errorlevel 1 (echo Autostart: could not create the task) else (echo Autostart: ON, the server starts when the PC boots, hidden)
:as_done

rem ---- Run embedded PowerShell/C# server ----
powershell -NoProfile -ExecutionPolicy Bypass -Command "$t=[IO.File]::ReadAllText($env:BATFILE,[Text.Encoding]::UTF8); $m='#'+'PS_START'; $i=$t.IndexOf($m,[StringComparison]::Ordinal); Invoke-Expression $t.Substring($i)"
echo.
echo Server stopped.
pause
exit /b

#PS_START
$ErrorActionPreference = 'Stop'

# =====================================================================
#  C# SERVER (ASCII only; all Russian text lives in the web pages below)
# =====================================================================
$src = @'
using System;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Text;
using System.Threading;
using System.Globalization;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Drawing;
using System.Drawing.Imaging;

public class Account
{
    public string Id = "";
    public string Name = "";
    public string Login;
    public string Folder;
    public byte[] Salt;
    public byte[] Hash;
    public double Quota = -1;   // GB: -1 = default, 0 = unlimited
    public int Blocked;         // 0 ok, 1 blocked, 2 pending approval
    public long Created;
    public long Last;
}

public class Session
{
    public Account Acc;
    public DateTime Seen;
    public string Ip = "";
}

public class Msg
{
    public long Id;
    public long Ts;
    public string From = "";
    public string Type = "text";   // text | file | dir
    public string A = "";          // text, or path of the shared item in the sender's storage
    public string B = "";          // item name
    public string C = "";          // item size in bytes
}

public class Conv
{
    public string Key;
    public string P1;
    public string P2;
    public List<Msg> List = new List<Msg>();
}

public class Sub
{
    public string AccId;
    public string Token;
    public string Endpoint;
}

public class Link
{
    public string Full;
    public string Name;
    public bool Zip;
    public DateTime Exp;
}

public class ZipJob
{
    public string Id;
    public string AccId;
    public string Dir;
    public string Name;
    public string Tmp;
    public int State;          // 0 working, 1 ready, 2 failed
    public long Done;
    public long Total;
    public string Url = "";
    public DateTime Exp;
}

public class Notif
{
    public long Id;
    public string Title;
    public string Body;
    public string Url;
    public string Tag;
}

public static class FileServer
{
    public static string PageAuth = "", PageMain = "", PageAdmin = "", PublicUrl = "", SwJs = "";
    public static string DirRecv = "Received", DirChat = "Chat", TxtUser = "User", TxtFile = "File", TxtDir = "Folder";
    public static string TxtNotice = "Message", TxtApp = "Files";
    const string DefBad = "exe,msi,bat,cmd,scr,com,vbs,ps1,jar";
    const string PushSubject = "mailto:push@example.com";

    static string adminLogin, root, usersDir, chatDir, accFile, cfgFile, logFile, sessFile, subFile, readFile;
    static Dictionary<string, Account> accs = new Dictionary<string, Account>(StringComparer.OrdinalIgnoreCase);
    static Dictionary<string, Account> byId = new Dictionary<string, Account>();
    static Dictionary<string, Session> sess = new Dictionary<string, Session>();
    static Dictionary<string, string> cfg = new Dictionary<string, string>();
    static Dictionary<string, List<DateTime>> hits = new Dictionary<string, List<DateTime>>();
    static List<string[]> logs = new List<string[]>();
    static Dictionary<string, Conv> convs = new Dictionary<string, Conv>();
    static Dictionary<string, long> reads = new Dictionary<string, long>();
    static List<Sub> subs = new List<Sub>();
    static Dictionary<string, List<Notif>> notifs = new Dictionary<string, List<Notif>>();
    static Dictionary<int, byte[]> icons = new Dictionary<int, byte[]>();
    static Dictionary<string, Link> links = new Dictionary<string, Link>();
    static Dictionary<string, ZipJob> zjobs = new Dictionary<string, ZipJob>();
    static string tmpDir;
    static CngKey vapidKey = null;
    static string vapidPub = "";
    static long lastMsgId = 0;
    static object lk = new object();
    static DateTime started = DateTime.Now;
    static DateTime epoch = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);

    // ------------------------------------------------------------ start
    public static void Run(string au, string ap, int port, string r)
    {
        try { ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072; } catch { }
        root = r; adminLogin = au;
        usersDir = Path.Combine(r, "users");
        chatDir = Path.Combine(r, "chat");
        Directory.CreateDirectory(usersDir);
        Directory.CreateDirectory(chatDir);
        tmpDir = Path.Combine(r, "tmp");
        try
        {
            Directory.CreateDirectory(tmpDir);
            foreach (string tf in Directory.GetFiles(tmpDir)) { try { File.Delete(tf); } catch { } }
        }
        catch { }
        accFile = Path.Combine(r, "accounts.txt");
        cfgFile = Path.Combine(r, "settings.txt");
        logFile = Path.Combine(r, "log.txt");
        sessFile = Path.Combine(r, "sessions.txt");
        subFile = Path.Combine(r, "push.txt");
        readFile = Path.Combine(r, "reads.txt");
        LoadSettings();
        LoadAccounts();
        EnsureAdmin(au, ap);
        LoadSessions();
        LoadSubs();
        LoadReads();
        LoadChats();
        InitVapid();
        CleanParts();

        HttpListener l = new HttpListener();
        l.Prefixes.Add("http://+:" + port + "/");
        l.Start();
        while (true)
        {
            HttpListenerContext c = l.GetContext();
            ThreadPool.QueueUserWorkItem(delegate(object o) { Handle((HttpListenerContext)o); }, c);
        }
    }

    // ------------------------------------------------------------ helpers
    static long NowMs() { return (long)(DateTime.UtcNow - epoch).TotalMilliseconds; }
    static string Dbl(double d) { return d.ToString("0.###", CultureInfo.InvariantCulture); }
    static long ParseL(string s, long d) { long v; return long.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out v) ? v : d; }
    static double ParseD(string s, double d) { double v; return double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out v) ? v : d; }
    static string V(Dictionary<string, string> f, string k) { string v; return f.TryGetValue(k, out v) ? v : ""; }
    static string Trunc(string s, int n) { return s.Length > n ? s.Substring(0, n) : s; }
    // HttpListener decodes the query with the system code page; decode it as UTF-8 ourselves (Cyrillic names!)
    static string QParam(string query, string k)
    {
        if (string.IsNullOrEmpty(query)) return "";
        if (query[0] == '?') query = query.Substring(1);
        foreach (string pair in query.Split('&'))
        {
            int i = pair.IndexOf('=');
            string key = i < 0 ? pair : pair.Substring(0, i);
            string val = i < 0 ? "" : pair.Substring(i + 1);
            try
            {
                if (Uri.UnescapeDataString(key.Replace('+', ' ')) == k) return Uri.UnescapeDataString(val.Replace('+', ' '));
            }
            catch { }
        }
        return "";
    }

    static string QS(HttpListenerContext c, string k)
    {
        string raw = c.Request.RawUrl ?? "";
        int i = raw.IndexOf('?');
        return i < 0 ? "" : QParam(raw.Substring(i + 1), k);
    }

    // Content-Disposition with an ASCII fallback name and the real UTF-8 name
    static string Disp(bool attach, string name)
    {
        StringBuilder a = new StringBuilder();
        foreach (char ch in name)
        {
            if (ch < 32 || ch > 126 || ch == '"' || ch == '\\' || ch == '%' || ch == ';') a.Append('_');
            else a.Append(ch);
        }
        return (attach ? "attachment" : "inline") + "; filename=\"" + a.ToString() + "\"; filename*=UTF-8''" + Uri.EscapeDataString(name);
    }

    static string Q(string s)
    {
        StringBuilder b = new StringBuilder("\"");
        foreach (char ch in s)
        {
            if (ch == '"') b.Append("\\\"");
            else if (ch == '\\') b.Append("\\\\");
            else if (ch < ' ') b.Append("\\u" + ((int)ch).ToString("x4"));
            else b.Append(ch);
        }
        b.Append('"');
        return b.ToString();
    }

    static string Esc(string s) { return s.Replace("\\", "\\\\").Replace("\r", "").Replace("\n", "\\n").Replace("\t", "\\t"); }
    static string Unesc(string s)
    {
        StringBuilder b = new StringBuilder();
        for (int i = 0; i < s.Length; i++)
        {
            char ch = s[i];
            if (ch == '\\' && i + 1 < s.Length)
            {
                i++;
                if (s[i] == 'n') b.Append('\n');
                else if (s[i] == 't') b.Append('\t');
                else b.Append(s[i]);
            }
            else b.Append(ch);
        }
        return b.ToString();
    }

    static string B64u(byte[] b) { return Convert.ToBase64String(b).TrimEnd('=').Replace('+', '-').Replace('/', '_'); }

    static string RandHex(int n)
    {
        byte[] b = new byte[n];
        using (RNGCryptoServiceProvider r = new RNGCryptoServiceProvider()) r.GetBytes(b);
        StringBuilder sb = new StringBuilder();
        foreach (byte x in b) sb.Append(x.ToString("x2"));
        return sb.ToString();
    }

    static bool IsHex(string s)
    {
        if (s == null || s.Length != 32) return false;
        foreach (char ch in s) { if (!((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f'))) return false; }
        return true;
    }

    // public account id: 8 digits, not related to the login
    static string NewId()
    {
        byte[] b = new byte[4];
        while (true)
        {
            using (RNGCryptoServiceProvider r = new RNGCryptoServiceProvider()) r.GetBytes(b);
            uint v = BitConverter.ToUInt32(b, 0);
            string id = (10000000L + (long)(v % 90000000u)).ToString();
            lock (lk) { if (!byId.ContainsKey(id)) return id; }
        }
    }

    static string DisplayName(Account a)
    {
        if (a.Name != null && a.Name.Length > 0) return a.Name;
        return TxtUser + " " + a.Id.Substring(a.Id.Length - 4);
    }

    // ------------------------------------------------------------ settings
    static string Get(string k, string d) { lock (lk) { string v; return cfg.TryGetValue(k, out v) ? v : d; } }
    static double GetD(string k, double d) { return ParseD(Get(k, ""), d); }
    static void Put(string k, string v) { lock (lk) { cfg[k] = v; } }

    static void SaveSettings()
    {
        lock (lk)
        {
            try
            {
                StringBuilder sb = new StringBuilder();
                foreach (KeyValuePair<string, string> kv in cfg) sb.Append(kv.Key).Append('=').Append(Esc(kv.Value)).Append("\r\n");
                File.WriteAllText(cfgFile, sb.ToString(), Encoding.UTF8);
            }
            catch { }
        }
    }

    static void LoadSettings()
    {
        if (!File.Exists(cfgFile)) return;
        foreach (string line in File.ReadAllLines(cfgFile, Encoding.UTF8))
        {
            int i = line.IndexOf('=');
            if (i <= 0) continue;
            cfg[line.Substring(0, i)] = Unesc(line.Substring(i + 1));
        }
    }

    static string CleanExt(string s)
    {
        List<string> l = new List<string>();
        foreach (string p in s.ToLowerInvariant().Split(new char[] { ',', ';', ' ', '\n', '\r', '\t' }, StringSplitOptions.RemoveEmptyEntries))
        {
            string e = p.Trim().TrimStart('.');
            if (e.Length > 0 && e.Length <= 10) l.Add(e);
        }
        return string.Join(",", l.ToArray());
    }

    static bool InList(string list, string ext)
    {
        foreach (string p in list.Split(',')) { if (p == ext) return true; }
        return false;
    }

    // ------------------------------------------------------------ log
    static void Log(string kind, string user, string ip, string info)
    {
        string[] e = new string[] { NowMs().ToString(), kind, user ?? "", ip ?? "", info ?? "" };
        lock (lk)
        {
            logs.Add(e);
            if (logs.Count > 300) logs.RemoveAt(0);
            try
            {
                File.AppendAllText(logFile, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "\t" + kind + "\t" + e[2] + "\t" + e[3] + "\t" + e[4] + "\r\n", Encoding.UTF8);
            }
            catch { }
        }
    }

    // ------------------------------------------------------------ rate limit
    static void Hit(string k)
    {
        lock (lk)
        {
            List<DateTime> l;
            if (!hits.TryGetValue(k, out l)) { l = new List<DateTime>(); hits[k] = l; }
            l.Add(DateTime.UtcNow);
        }
    }

    static int Count(string k, int sec)
    {
        lock (lk)
        {
            List<DateTime> l;
            if (!hits.TryGetValue(k, out l)) return 0;
            DateTime lim = DateTime.UtcNow.AddSeconds(-sec);
            l.RemoveAll(delegate(DateTime d) { return d < lim; });
            return l.Count;
        }
    }

    static string Ip(HttpListenerContext c)
    {
        IPAddress ra = c.Request.RemoteEndPoint.Address;
        if (IPAddress.IsLoopback(ra))
        {
            string h = c.Request.Headers["CF-Connecting-IP"];
            if (!string.IsNullOrEmpty(h)) return h.Trim();
            h = c.Request.Headers["X-Forwarded-For"];
            if (!string.IsNullOrEmpty(h)) return h.Split(',')[0].Trim();
        }
        return ra.ToString();
    }

    // ------------------------------------------------------------ accounts
    static byte[] NewSalt()
    {
        byte[] s = new byte[16];
        using (RNGCryptoServiceProvider r = new RNGCryptoServiceProvider()) r.GetBytes(s);
        return s;
    }

    static byte[] HashPw(string pw, byte[] salt)
    {
        using (Rfc2898DeriveBytes d = new Rfc2898DeriveBytes(pw, salt, 10000)) return d.GetBytes(32);
    }

    static bool CheckPw(Account a, string pw)
    {
        byte[] h = HashPw(pw, a.Salt);
        if (h.Length != a.Hash.Length) return false;
        int diff = 0;
        for (int i = 0; i < h.Length; i++) diff |= h[i] ^ a.Hash[i];
        return diff == 0;
    }

    static bool IsAdmin(Account a) { return string.Equals(a.Login, adminLogin, StringComparison.OrdinalIgnoreCase); }

    static bool ValidLogin(string s)
    {
        if (s == null || s.Length < 3 || s.Length > 20) return false;
        foreach (char ch in s)
        {
            bool ok = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_' || ch == '.' || ch == '-';
            if (!ok) return false;
        }
        return true;
    }

    static bool ValidPass(string s)
    {
        if (s == null || s.Length < 4 || s.Length > 32) return false;
        if (s.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0) return false;
        if (s[0] == ' ' || s[s.Length - 1] == ' ' || s[s.Length - 1] == '.') return false;
        return true;
    }

    static string CleanName(string s)
    {
        StringBuilder b = new StringBuilder();
        foreach (char ch in (s ?? "")) { if (ch >= ' ' && ch != '\u007f') b.Append(ch); }
        return Trunc(b.ToString().Trim(), 30);
    }

    static string FolderName(string login, string pw)
    {
        string n = login + "=" + pw;
        foreach (char ch in Path.GetInvalidFileNameChars()) n = n.Replace(ch.ToString(), "_");
        return n;
    }

    static string FolderPath(Account a) { return Path.Combine(usersDir, a.Folder); }

    static string CurPw(Account a)
    {
        string pre = a.Login + "=";
        return a.Folder.StartsWith(pre) ? a.Folder.Substring(pre.Length) : "";
    }

    static void SaveAccounts()
    {
        lock (lk)
        {
            try
            {
                StringBuilder sb = new StringBuilder();
                foreach (Account a in accs.Values)
                {
                    sb.Append(a.Login).Append('\t').Append(Convert.ToBase64String(a.Salt)).Append('\t')
                      .Append(Convert.ToBase64String(a.Hash)).Append('\t').Append(a.Folder).Append('\t')
                      .Append(Dbl(a.Quota)).Append('\t').Append(a.Blocked).Append('\t')
                      .Append(a.Created).Append('\t').Append(a.Last).Append('\t')
                      .Append(a.Id).Append('\t').Append(Esc(a.Name)).Append("\r\n");
                }
                string tmp = accFile + ".tmp";
                File.WriteAllText(tmp, sb.ToString(), Encoding.UTF8);
                if (File.Exists(accFile)) File.Delete(accFile);
                File.Move(tmp, accFile);
            }
            catch { }
        }
    }

    static void LoadAccounts()
    {
        bool changed = false;
        if (File.Exists(accFile))
        {
            foreach (string line in File.ReadAllLines(accFile, Encoding.UTF8))
            {
                string[] p = line.Split('\t');
                if (p.Length < 8) continue;
                try
                {
                    Account a = new Account();
                    a.Login = p[0];
                    a.Salt = Convert.FromBase64String(p[1]);
                    a.Hash = Convert.FromBase64String(p[2]);
                    a.Folder = p[3];
                    a.Quota = ParseD(p[4], -1);
                    a.Blocked = (int)ParseL(p[5], 0);
                    a.Created = ParseL(p[6], 0);
                    a.Last = ParseL(p[7], 0);
                    if (p.Length >= 10 && p[8].Length > 0 && !byId.ContainsKey(p[8])) { a.Id = p[8]; a.Name = Unesc(p[9]); }
                    else { a.Id = NewId(); changed = true; }
                    accs[a.Login] = a;
                    byId[a.Id] = a;
                }
                catch { }
            }
        }
        if (changed) SaveAccounts();
    }

    static void EnsureAdmin(string au, string ap)
    {
        lock (lk)
        {
            Account a;
            string fn = FolderName(au, ap);
            if (!accs.TryGetValue(au, out a))
            {
                a = new Account();
                a.Login = au; a.Created = NowMs(); a.Folder = fn;
                a.Id = NewId();
                accs[au] = a;
                byId[a.Id] = a;
                // move files from the very first single-user version, if present
                string legacy = Path.Combine(root, "uploads");
                string np = Path.Combine(usersDir, fn);
                try { if (Directory.Exists(legacy) && !Directory.Exists(np)) Directory.Move(legacy, np); } catch { }
            }
            else if (a.Folder != fn)
            {
                try
                {
                    string o = Path.Combine(usersDir, a.Folder), n = Path.Combine(usersDir, fn);
                    if (Directory.Exists(o) && !Directory.Exists(n)) Directory.Move(o, n);
                }
                catch { }
                a.Folder = fn;
            }
            a.Login = au;
            a.Salt = NewSalt();
            a.Hash = HashPw(ap, a.Salt);
            a.Blocked = 0;
            a.Quota = 0;
            try { Directory.CreateDirectory(FolderPath(a)); } catch { }
            SaveAccounts();
        }
    }

    static void CleanParts()
    {
        try
        {
            foreach (string f in Directory.GetFiles(usersDir, "*.part", SearchOption.AllDirectories))
            {
                try { if ((DateTime.Now - File.GetLastWriteTime(f)).TotalHours > 24) File.Delete(f); } catch { }
            }
        }
        catch { }
    }

    static string CreateUser(string login, string pw, string name, double quota, int blocked, bool byAdmin)
    {
        if (!ValidLogin(login)) return "badlogin";
        if (!ValidPass(pw)) return "badpass";
        string lw = login.ToLowerInvariant();
        if (lw == "admin" || lw == "administrator") return "reserved";
        lock (lk)
        {
            if (accs.ContainsKey(login)) return "exists";
            int maxU = (int)GetD("maxUsers", 0);
            if (!byAdmin && maxU > 0 && accs.Count - 1 >= maxU) return "full";
            Account a = new Account();
            a.Login = login; a.Salt = NewSalt(); a.Hash = HashPw(pw, a.Salt);
            a.Folder = FolderName(login, pw);
            a.Name = CleanName(name);
            a.Quota = quota; a.Blocked = blocked; a.Created = NowMs(); a.Last = 0;
            a.Id = NewId();
            try { Directory.CreateDirectory(FolderPath(a)); } catch { return "folder"; }
            accs[login] = a;
            byId[a.Id] = a;
            SaveAccounts();
        }
        return null;
    }

    // Changes login and/or password (the folder name contains both). Must be called inside lock(lk).
    static string ApplyCreds(Account a, string newLogin, string newPw)
    {
        string curPw = CurPw(a);
        bool loginChanged = !string.Equals(newLogin, a.Login, StringComparison.Ordinal);
        bool pwChanged = newPw != curPw;
        if (pwChanged && !ValidPass(newPw)) return "badpass";
        if (loginChanged)
        {
            if (!ValidLogin(newLogin)) return "badlogin";
            string lw = newLogin.ToLowerInvariant();
            if (lw == "admin" || lw == "administrator") return "reserved";
            Account other;
            if (accs.TryGetValue(newLogin, out other) && !object.ReferenceEquals(other, a)) return "exists";
        }
        string newFolder = FolderName(newLogin, newPw);
        if (newFolder != a.Folder)
        {
            string op = FolderPath(a), npth = Path.Combine(usersDir, newFolder);
            try
            {
                if (Directory.Exists(op)) Directory.Move(op, npth);
                else Directory.CreateDirectory(npth);
            }
            catch { return "folder"; }
            a.Folder = newFolder;
        }
        if (loginChanged) { accs.Remove(a.Login); a.Login = newLogin; accs[newLogin] = a; }
        if (pwChanged) { a.Salt = NewSalt(); a.Hash = HashPw(newPw, a.Salt); }
        return null;
    }

    static void KillSessions(Account a, string keepToken)
    {
        lock (lk)
        {
            List<string> del = new List<string>();
            foreach (KeyValuePair<string, Session> kv in sess)
            {
                if (object.ReferenceEquals(kv.Value.Acc, a) && kv.Key != keepToken) del.Add(kv.Key);
            }
            foreach (string k in del) { sess.Remove(k); notifs.Remove(k); }
            subs.RemoveAll(delegate(Sub s) { return s.AccId == a.Id && s.Token != keepToken && !sess.ContainsKey(s.Token); });
            SaveSessions();
            SaveSubs();
        }
    }

    static string UpdateUser(Dictionary<string, string> f)
    {
        string target = V(f, "target"), nl = V(f, "nl").Trim(), np = V(f, "np"), q = V(f, "q"), bl = V(f, "b");
        lock (lk)
        {
            Account a;
            if (!accs.TryGetValue(target, out a)) return "nouser";
            if (IsAdmin(a)) return "adminfixed";
            string newLogin = nl.Length > 0 ? nl : a.Login;
            string newPw = np.Length > 0 ? np : CurPw(a);
            bool pwChanged = np.Length > 0 && np != CurPw(a);
            string err = ApplyCreds(a, newLogin, newPw);
            if (err != null) return err;
            if (pwChanged) KillSessions(a, "");
            if (q == "def") a.Quota = -1;
            else if (q.Length > 0)
            {
                double qv = ParseD(q, double.NaN);
                if (!double.IsNaN(qv)) a.Quota = Math.Max(0.0, qv);
            }
            if (bl == "1") { a.Blocked = 1; KillSessions(a, ""); }
            else if (bl == "0") a.Blocked = 0;
            SaveAccounts();
        }
        return null;
    }

    static string DeleteUser(string target, bool wipe)
    {
        lock (lk)
        {
            Account a;
            if (!accs.TryGetValue(target, out a)) return "nouser";
            if (IsAdmin(a)) return "adminfixed";
            KillSessions(a, "");
            subs.RemoveAll(delegate(Sub s) { return s.AccId == a.Id; });
            SaveSubs();
            accs.Remove(a.Login);
            byId.Remove(a.Id);
            string p = FolderPath(a);
            try
            {
                if (Directory.Exists(p))
                {
                    if (wipe) Directory.Delete(p, true);
                    else
                    {
                        string dd = Path.Combine(root, "deleted");
                        Directory.CreateDirectory(dd);
                        Directory.Move(p, Path.Combine(dd, a.Folder + "_" + DateTime.Now.ToString("yyyyMMdd-HHmmss")));
                    }
                }
            }
            catch { }
            SaveAccounts();
        }
        return null;
    }

    static long QuotaBytes(Account a)
    {
        if (IsAdmin(a)) return 0;
        double g = a.Quota < 0 ? GetD("defQuota", 5) : a.Quota;
        if (g <= 0) return 0;
        return (long)(g * 1073741824.0);
    }

    static long DirSize(string dir)
    {
        long t = 0;
        try { foreach (FileInfo f in new DirectoryInfo(dir).GetFiles("*", SearchOption.AllDirectories)) t += f.Length; } catch { }
        return t;
    }

    static long Used(Account a) { return DirSize(FolderPath(a)); }

    static bool DiskOk(long need)
    {
        try
        {
            long reserve = (long)(GetD("reserve", 2) * 1073741824.0);
            DriveInfo di = new DriveInfo(Path.GetPathRoot(root));
            return di.AvailableFreeSpace - need >= reserve;
        }
        catch { return true; }
    }

    // ------------------------------------------------------------ sessions
    static void SaveSessions()
    {
        lock (lk)
        {
            try
            {
                StringBuilder sb = new StringBuilder();
                foreach (KeyValuePair<string, Session> kv in sess)
                {
                    long ms = (long)(kv.Value.Seen - epoch).TotalMilliseconds;
                    sb.Append(kv.Key).Append('\t').Append(kv.Value.Acc.Id).Append('\t').Append(ms).Append("\r\n");
                }
                File.WriteAllText(sessFile, sb.ToString(), Encoding.UTF8);
            }
            catch { }
        }
    }

    static void LoadSessions()
    {
        if (!File.Exists(sessFile)) return;
        foreach (string line in File.ReadAllLines(sessFile, Encoding.UTF8))
        {
            string[] p = line.Split('\t');
            if (p.Length < 3) continue;
            Account a;
            if (!byId.TryGetValue(p[1], out a)) continue;
            DateTime seen = epoch.AddMilliseconds((double)ParseL(p[2], 0));
            if ((DateTime.UtcNow - seen).TotalDays > 30) continue;
            Session s = new Session();
            s.Acc = a; s.Seen = seen;
            sess[p[0]] = s;
        }
    }

    static Session GetSession(HttpListenerContext c)
    {
        Cookie ck = c.Request.Cookies["sid"];
        if (ck == null) return null;
        lock (lk)
        {
            Session s;
            if (!sess.TryGetValue(ck.Value, out s)) return null;
            if ((DateTime.UtcNow - s.Seen).TotalDays > 30) { sess.Remove(ck.Value); return null; }
            Account cur;
            if (!accs.TryGetValue(s.Acc.Login, out cur) || !object.ReferenceEquals(cur, s.Acc)) { sess.Remove(ck.Value); return null; }
            if (s.Acc.Blocked != 0) return null;
            if (Get("maint", "0") == "1" && !IsAdmin(s.Acc)) return null;
            s.Seen = DateTime.UtcNow;
            s.Acc.Last = NowMs();
            return s;
        }
    }

    static void StartSession(HttpListenerContext c, Account a)
    {
        string t = RandHex(32);
        Session s = new Session();
        s.Acc = a; s.Seen = DateTime.UtcNow; s.Ip = Ip(c);
        lock (lk) { sess[t] = s; a.Last = NowMs(); SaveSessions(); }
        bool https = c.Request.Headers["X-Forwarded-Proto"] == "https" && IPAddress.IsLoopback(c.Request.RemoteEndPoint.Address);
        c.Response.AppendHeader("Set-Cookie", "sid=" + t + "; Path=/; HttpOnly; SameSite=Lax; Max-Age=2592000" + (https ? "; Secure" : ""));
    }

    // ------------------------------------------------------------ routing
    static void Handle(HttpListenerContext c)
    {
        try
        {
            string path = c.Request.Url.AbsolutePath;
            string m = c.Request.HttpMethod;
            // the file name may follow in the path (so every browser names the saved file correctly)
            if (path.StartsWith("/download/")) path = "/download";
            else if (path.StartsWith("/zip/")) path = "/zip";
            else if (path.StartsWith("/api/chat/item/")) path = "/api/chat/item";

            if (path == "/api/info" && m == "GET") { DoInfo(c); return; }
            if (path == "/api/login" && m == "POST") { DoLogin(c); return; }
            if (path == "/api/register" && m == "POST") { DoRegister(c); return; }
            if (path == "/logout") { DoLogout(c); return; }
            if (path.StartsWith("/get/")) { DoGet(c, c.Request.Url.AbsolutePath); return; }
            if (path == "/manifest.webmanifest") { SendBytes(c, 200, "application/manifest+json; charset=utf-8", Encoding.UTF8.GetBytes(Manifest()), "no-cache"); return; }
            if (path == "/sw.js")
            {
                c.Response.AddHeader("Service-Worker-Allowed", "/");
                SendBytes(c, 200, "text/javascript; charset=utf-8", Encoding.UTF8.GetBytes(SwJs), "no-cache");
                return;
            }
            if (path == "/icon-192.png") { SendBytes(c, 200, "image/png", Icon(192), "public, max-age=86400"); return; }
            if (path == "/icon-512.png") { SendBytes(c, 200, "image/png", Icon(512), "public, max-age=86400"); return; }
            if (path == "/apple-touch-icon.png" || path == "/apple-touch-icon-precomposed.png") { SendBytes(c, 200, "image/png", Icon(180), "public, max-age=86400"); return; }

            Session s = GetSession(c);
            if (s == null)
            {
                if (path == "/" && m == "GET") Send(c, 200, "text/html", PageAuth);
                else if (path == "/admin") Redirect(c, "/");
                else Json(c, 401, "{\"err\":\"auth\"}");
                return;
            }
            Account a = s.Acc;
            bool admin = IsAdmin(a);
            string token = c.Request.Cookies["sid"].Value;

            if (m == "POST" && c.Request.Headers["X-Req"] != "1") { Json(c, 403, "{\"err\":\"csrf\"}"); return; }

            if (path == "/" && m == "GET") Send(c, 200, "text/html", PageMain);
            else if (path == "/admin" && m == "GET") { if (admin) Send(c, 200, "text/html", PageAdmin); else Redirect(c, "/"); }
            else if (path == "/api/me") DoMe(c, a);
            else if (path == "/api/ping") DoPing(c, a);
            else if (path == "/list" && m == "GET") DoList(c, a);
            else if (path == "/view" && m == "GET") DoFile(c, a, false);
            else if (path == "/download" && m == "GET") DoFile(c, a, true);
            else if (path == "/zip" && m == "GET") DoZip(c, a);
            else if (path == "/api/link" && m == "POST") DoLink(c, a);
            else if (path == "/api/zip/start" && m == "POST") DoZipStart(c, a);
            else if (path == "/api/zip/status" && m == "GET") DoZipStatus(c, a);
            else if (path == "/upload" && m == "POST") DoUpload(c, a);
            else if (path == "/delete" && m == "POST") DoDelete(c, a);
            else if (path == "/api/fs/folders" && m == "GET") DoFolders(c, a);
            else if (path == "/api/fs/mkdir" && m == "POST") DoMkdir(c, a);
            else if (path == "/api/fs/rename" && m == "POST") DoRename(c, a);
            else if (path == "/api/fs/move" && m == "POST") DoMove(c, a);
            else if (path.StartsWith("/api/profile/") && m == "POST") DoProfile(c, a, path, token);
            else if (path.StartsWith("/api/chat/")) DoChat(c, a, path, m);
            else if (path.StartsWith("/api/push/")) DoPush(c, a, path, token);
            else if (path.StartsWith("/api/admin/"))
            {
                if (!admin) Json(c, 403, "{\"err\":\"forbidden\"}");
                else AdminApi(c, path, m, a);
            }
            else Send(c, 404, "text/plain", "Not found");
        }
        catch
        {
            try { c.Response.Abort(); } catch { }
        }
    }

    static Dictionary<string, string> ReadForm(HttpListenerContext c)
    {
        Dictionary<string, string> d = new Dictionary<string, string>();
        if (c.Request.ContentLength64 > 65536) return d;
        string body;
        using (StreamReader sr = new StreamReader(c.Request.InputStream, Encoding.UTF8)) body = sr.ReadToEnd();
        foreach (string pair in body.Split('&'))
        {
            int i = pair.IndexOf('=');
            if (i < 0) continue;
            try
            {
                string k = Uri.UnescapeDataString(pair.Substring(0, i).Replace('+', ' '));
                string v = Uri.UnescapeDataString(pair.Substring(i + 1).Replace('+', ' '));
                d[k] = v;
            }
            catch { }
        }
        return d;
    }

    // ------------------------------------------------------------ static assets
    static string Manifest()
    {
        string t = Get("title", "");
        if (t.Length == 0) t = TxtApp;
        return "{\"name\":" + Q(t) + ",\"short_name\":" + Q(Trunc(t, 12)) + ",\"start_url\":\"/\",\"scope\":\"/\",\"display\":\"standalone\","
            + "\"background_color\":\"#12151c\",\"theme_color\":\"#12151c\",\"icons\":["
            + "{\"src\":\"/icon-192.png\",\"sizes\":\"192x192\",\"type\":\"image/png\"},"
            + "{\"src\":\"/icon-512.png\",\"sizes\":\"512x512\",\"type\":\"image/png\"}]}";
    }

    static byte[] Icon(int size)
    {
        lock (lk)
        {
            byte[] b;
            if (icons.TryGetValue(size, out b)) return b;
            try
            {
                using (Bitmap bmp = new Bitmap(size, size))
                {
                    using (Graphics g = Graphics.FromImage(bmp))
                    {
                        g.Clear(Color.FromArgb(122, 162, 255));
                        float s = (float)size;
                        using (SolidBrush br = new SolidBrush(Color.FromArgb(12, 18, 32)))
                        {
                            g.FillRectangle(br, s * 0.22f, s * 0.28f, s * 0.27f, s * 0.12f);
                            g.FillRectangle(br, s * 0.22f, s * 0.36f, s * 0.56f, s * 0.36f);
                        }
                    }
                    using (MemoryStream ms = new MemoryStream())
                    {
                        bmp.Save(ms, ImageFormat.Png);
                        b = ms.ToArray();
                    }
                }
            }
            catch { b = new byte[0]; }
            icons[size] = b;
            return b;
        }
    }

    // ------------------------------------------------------------ public api
    static void DoInfo(HttpListenerContext c)
    {
        Json(c, 200, "{\"title\":" + Q(Get("title", "")) + ",\"reg\":" + (Get("reg", "1") == "1" ? "1" : "0")
            + ",\"maint\":" + (Get("maint", "0") == "1" ? "1" : "0") + ",\"approve\":" + (Get("approve", "0") == "1" ? "1" : "0") + "}");
    }

    static void DoLogin(HttpListenerContext c)
    {
        Dictionary<string, string> f = ReadForm(c);
        string ip = Ip(c);
        if (Count("lf:" + ip, 600) >= 8) { Json(c, 200, "{\"err\":\"locked\"}"); return; }
        string u = V(f, "u").Trim(), p = V(f, "p");
        Account a = null;
        bool ok = false;
        lock (lk) { if (u.Length > 0 && accs.TryGetValue(u, out a)) ok = CheckPw(a, p); }
        if (!ok)
        {
            Hit("lf:" + ip);
            Log("loginfail", u, ip, "");
            Thread.Sleep(600);
            Json(c, 200, "{\"err\":\"bad\"}");
            return;
        }
        if (a.Blocked == 1) { Json(c, 200, "{\"err\":\"blocked\"}"); return; }
        if (a.Blocked == 2) { Json(c, 200, "{\"err\":\"pending\"}"); return; }
        if (Get("maint", "0") == "1" && !IsAdmin(a)) { Json(c, 200, "{\"err\":\"maint\"}"); return; }
        StartSession(c, a);
        SaveAccounts();
        Log("login", a.Login, ip, "");
        Json(c, 200, "{\"ok\":1}");
    }

    static void DoRegister(HttpListenerContext c)
    {
        Dictionary<string, string> f = ReadForm(c);
        string ip = Ip(c);
        if (Get("reg", "1") != "1") { Json(c, 200, "{\"err\":\"closed\"}"); return; }
        if (Count("rg:" + ip, 3600) >= 5) { Json(c, 200, "{\"err\":\"locked\"}"); return; }
        string u = V(f, "u").Trim(), p = V(f, "p");
        bool approve = Get("approve", "0") == "1";
        string err = CreateUser(u, p, V(f, "n"), -1, approve ? 2 : 0, false);
        if (err != null) { Json(c, 200, "{\"err\":" + Q(err) + "}"); return; }
        Hit("rg:" + ip);
        Log("register", u, ip, approve ? "pending" : "");
        if (approve) { Json(c, 200, "{\"ok\":1,\"pending\":1}"); return; }
        Account a;
        lock (lk) { accs.TryGetValue(u, out a); }
        StartSession(c, a);
        Json(c, 200, "{\"ok\":1}");
    }

    static void DoLogout(HttpListenerContext c)
    {
        Cookie ck = c.Request.Cookies["sid"];
        if (ck != null)
        {
            lock (lk)
            {
                sess.Remove(ck.Value);
                notifs.Remove(ck.Value);
                subs.RemoveAll(delegate(Sub sb) { return sb.Token == ck.Value; });
                SaveSessions();
                SaveSubs();
            }
        }
        c.Response.AppendHeader("Set-Cookie", "sid=; Path=/; Max-Age=0");
        Redirect(c, "/");
    }

    static void Redirect(HttpListenerContext c, string loc)
    {
        c.Response.StatusCode = 302;
        c.Response.AddHeader("Location", loc);
        c.Response.ContentLength64 = 0;
        c.Response.Close();
    }

    // ------------------------------------------------------------ user api
    static void DoMe(HttpListenerContext c, Account a)
    {
        StringBuilder sb = new StringBuilder("{");
        sb.Append("\"id\":").Append(Q(a.Id));
        sb.Append(",\"name\":").Append(Q(a.Name));
        sb.Append(",\"dn\":").Append(Q(DisplayName(a)));
        sb.Append(",\"login\":").Append(Q(a.Login));
        sb.Append(",\"admin\":").Append(IsAdmin(a) ? "1" : "0");
        sb.Append(",\"used\":").Append(Used(a));
        sb.Append(",\"quota\":").Append(QuotaBytes(a));
        sb.Append(",\"title\":").Append(Q(Get("title", "")));
        sb.Append(",\"chat\":").Append(Get("chat", "1") == "1" ? "1" : "0");
        sb.Append(",\"dc\":").Append(Q(DirChat)).Append(",\"dr\":").Append(Q(DirRecv));
        sb.Append(",\"u\":").Append(UnreadTotal(a));
        sb.Append(",\"nid\":").Append(Q(Get("nid", ""))).Append(",\"nt\":").Append(Q(Get("nt", "")));
        sb.Append("}");
        Json(c, 200, sb.ToString());
    }

    static void DoPing(HttpListenerContext c, Account me)
    {
        int unread = 0;
        Msg newest = null;
        if (Get("chat", "1") == "1")
        {
            lock (lk)
            {
                foreach (Conv cv in convs.Values)
                {
                    if (cv.P1 != me.Id && cv.P2 != me.Id) continue;
                    long mark = ReadMark(me.Id, cv.Key);
                    foreach (Msg m in cv.List)
                    {
                        if (m.Id > mark && m.From != me.Id)
                        {
                            unread++;
                            if (newest == null || m.Id > newest.Id) newest = m;
                        }
                    }
                }
            }
        }
        string mj = "null";
        if (newest != null)
        {
            Account snd;
            lock (lk) { byId.TryGetValue(newest.From, out snd); }
            mj = "{\"i\":" + newest.Id + ",\"p\":" + Q(newest.From) + ",\"n\":" + Q(snd != null ? DisplayName(snd) : "")
                + ",\"k\":" + Q(newest.Type) + ",\"t\":" + Q(newest.Type == "text" ? Trunc(newest.A, 120) : newest.B) + "}";
        }
        Json(c, 200, "{\"nid\":" + Q(Get("nid", "")) + ",\"nt\":" + Q(Get("nt", "")) + ",\"u\":" + unread + ",\"m\":" + mj + "}");
    }

    static void DoProfile(HttpListenerContext c, Account me, string path, string token)
    {
        Dictionary<string, string> f = ReadForm(c);
        string ip = Ip(c);
        if (path == "/api/profile/name")
        {
            lock (lk) { me.Name = CleanName(V(f, "name")); SaveAccounts(); }
            Json(c, 200, "{\"ok\":1,\"dn\":" + Q(DisplayName(me)) + "}");
            return;
        }
        if (path == "/api/profile/logout-all")
        {
            KillSessions(me, token);
            Json(c, 200, "{\"ok\":1}");
            return;
        }
        if (path == "/api/profile/login" || path == "/api/profile/pass")
        {
            if (IsAdmin(me)) { Json(c, 200, "{\"err\":\"adminfixed\"}"); return; }
            if (Count("pf:" + me.Id, 600) >= 8) { Json(c, 200, "{\"err\":\"locked\"}"); return; }
            string cur = V(f, "cur");
            bool ok;
            lock (lk) { ok = CheckPw(me, cur); }
            if (!ok) { Hit("pf:" + me.Id); Thread.Sleep(600); Json(c, 200, "{\"err\":\"wrongpass\"}"); return; }
            string err;
            lock (lk)
            {
                if (path == "/api/profile/login") err = ApplyCreds(me, V(f, "nl").Trim(), CurPw(me));
                else err = ApplyCreds(me, me.Login, V(f, "np"));
                if (err == null) SaveAccounts();
            }
            if (err != null) { Json(c, 200, "{\"err\":" + Q(err) + "}"); return; }
            if (path == "/api/profile/pass") KillSessions(me, token);
            Log(path == "/api/profile/login" ? "selflogin" : "selfpass", me.Id, ip, "");
            Json(c, 200, "{\"ok\":1,\"login\":" + Q(me.Login) + "}");
            return;
        }
        Json(c, 404, "{\"err\":\"nf\"}");
    }

    // ------------------------------------------------------------ files and folders
    static string Safe(string name)
    {
        if (name == null) return "file";
        name = name.Replace('\\', '/');
        name = Path.GetFileName(name);
        foreach (char ch in Path.GetInvalidFileNameChars()) name = name.Replace(ch.ToString(), "_");
        name = name.Trim();
        if (name.Length == 0 || name == "." || name == "..") name = "file";
        return name;
    }

    static string NormRel(string rel)
    {
        if (string.IsNullOrEmpty(rel)) return "";
        return string.Join("/", rel.Split(new char[] { '/', '\\' }, StringSplitOptions.RemoveEmptyEntries));
    }

    static string JoinRel(string a, string b)
    {
        if (string.IsNullOrEmpty(a)) return b ?? "";
        if (string.IsNullOrEmpty(b)) return a;
        return a + "/" + b;
    }

    // Turns a relative path of the account's storage into a full path. Returns null for unsafe paths.
    static string Resolve(Account a, string rel)
    {
        string cur = FolderPath(a);
        if (string.IsNullOrEmpty(rel)) return cur;
        foreach (string seg in rel.Split(new char[] { '/', '\\' }, StringSplitOptions.RemoveEmptyEntries))
        {
            if (seg == "." || seg == "..") return null;
            if (Safe(seg) != seg) return null;
            cur = Path.Combine(cur, seg);
        }
        return cur;
    }

    static string Unique(string dir, string name)
    {
        string full = Path.Combine(dir, name);
        if (!File.Exists(full) && !Directory.Exists(full)) return full;
        string baseName = Path.GetFileNameWithoutExtension(name);
        string ext = Path.GetExtension(name);
        int n = 1;
        while (true)
        {
            full = Path.Combine(dir, baseName + " (" + n + ")" + ext);
            if (!File.Exists(full) && !Directory.Exists(full)) return full;
            n++;
        }
    }

    static string UniqueDir(string dir, string name)
    {
        string full = Path.Combine(dir, name);
        if (!File.Exists(full) && !Directory.Exists(full)) return full;
        int n = 1;
        while (true)
        {
            full = Path.Combine(dir, name + " (" + n + ")");
            if (!File.Exists(full) && !Directory.Exists(full)) return full;
            n++;
        }
    }

    static string Mime(string ext)
    {
        switch ((ext ?? "").ToLowerInvariant())
        {
            case ".jpg": case ".jpeg": return "image/jpeg";
            case ".png": return "image/png";
            case ".gif": return "image/gif";
            case ".webp": return "image/webp";
            case ".bmp": return "image/bmp";
            case ".svg": return "image/svg+xml";
            case ".heic": return "image/heic";
            case ".heif": return "image/heif";
            case ".avif": return "image/avif";
            case ".mp4": case ".m4v": return "video/mp4";
            case ".mov": return "video/quicktime";
            case ".webm": return "video/webm";
            case ".mkv": return "video/x-matroska";
            case ".avi": return "video/x-msvideo";
            case ".3gp": return "video/3gpp";
            case ".mp3": return "audio/mpeg";
            case ".m4a": return "audio/mp4";
            case ".aac": return "audio/aac";
            case ".wav": return "audio/wav";
            case ".ogg": case ".oga": return "audio/ogg";
            case ".flac": return "audio/flac";
            case ".pdf": return "application/pdf";
            case ".txt": case ".log": case ".md": case ".csv": case ".json": case ".xml":
            case ".ini": case ".cfg": case ".bat": case ".cmd": case ".ps1": case ".py":
            case ".js": case ".css": case ".html": case ".htm": case ".cs": case ".java":
            case ".c": case ".cpp": case ".h": case ".sql": case ".yml": case ".yaml":
                return "text/plain; charset=utf-8";
            default: return "application/octet-stream";
        }
    }

    static string Kind(string ext)
    {
        string m = Mime(ext);
        if (m.StartsWith("image/")) return "image";
        if (m.StartsWith("video/")) return "video";
        if (m.StartsWith("audio/")) return "audio";
        if (m == "application/pdf") return "pdf";
        if (m.StartsWith("text/")) return "text";
        return "other";
    }

    static string ListJson(string dir, string rel)
    {
        DirectoryInfo di = new DirectoryInfo(dir);
        DirectoryInfo[] dirs = di.GetDirectories();
        FileInfo[] files = di.GetFiles();
        Array.Sort(dirs, delegate(DirectoryInfo x, DirectoryInfo y) { return string.Compare(x.Name, y.Name, StringComparison.OrdinalIgnoreCase); });
        Array.Sort(files, delegate(FileInfo x, FileInfo y) { return y.LastWriteTimeUtc.CompareTo(x.LastWriteTimeUtc); });
        StringBuilder sb = new StringBuilder("{\"p\":" + Q(rel) + ",\"dirs\":[");
        bool first = true;
        foreach (DirectoryInfo d in dirs)
        {
            if ((d.Attributes & FileAttributes.Hidden) != 0) continue;
            int cnt = 0;
            try { cnt = d.GetFileSystemInfos().Length; } catch { }
            if (!first) sb.Append(',');
            first = false;
            sb.Append("{\"n\":").Append(Q(d.Name)).Append(",\"t\":").Append((long)(d.LastWriteTimeUtc - epoch).TotalMilliseconds).Append(",\"c\":").Append(cnt).Append("}");
        }
        sb.Append("],\"files\":[");
        first = true;
        foreach (FileInfo f in files)
        {
            if ((f.Attributes & FileAttributes.Hidden) != 0) continue;
            if (f.Extension.ToLowerInvariant() == ".part") continue;
            if (!first) sb.Append(',');
            first = false;
            sb.Append("{\"n\":").Append(Q(f.Name));
            sb.Append(",\"s\":").Append(f.Length);
            sb.Append(",\"t\":").Append((long)(f.LastWriteTimeUtc - epoch).TotalMilliseconds);
            sb.Append(",\"k\":\"").Append(Kind(f.Extension)).Append("\"");
            sb.Append(",\"e\":").Append(Q(f.Extension.TrimStart('.').ToLowerInvariant())).Append("}");
        }
        sb.Append("]}");
        return sb.ToString();
    }

    static void DoList(HttpListenerContext c, Account a)
    {
        string rel = NormRel(QS(c, "p"));
        string dir = Resolve(a, rel);
        if (dir == null || !Directory.Exists(dir)) { Json(c, 200, "{\"err\":\"nodir\"}"); return; }
        Json(c, 200, ListJson(dir, rel));
    }

    static void CollectDirs(string baseDir, string rel, List<string> outl, int depth)
    {
        if (outl.Count > 400 || depth > 8) return;
        try
        {
            string[] ds = Directory.GetDirectories(rel.Length == 0 ? baseDir : Path.Combine(baseDir, rel));
            Array.Sort(ds, StringComparer.OrdinalIgnoreCase);
            foreach (string d in ds)
            {
                string r = rel.Length == 0 ? Path.GetFileName(d) : rel + "/" + Path.GetFileName(d);
                outl.Add(r);
                CollectDirs(baseDir, r, outl, depth + 1);
            }
        }
        catch { }
    }

    static void DoFolders(HttpListenerContext c, Account a)
    {
        List<string> l = new List<string>();
        CollectDirs(FolderPath(a), "", l, 0);
        StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < l.Count; i++) { if (i > 0) sb.Append(','); sb.Append(Q(l[i])); }
        sb.Append("]");
        Json(c, 200, sb.ToString());
    }

    static void DoMkdir(HttpListenerContext c, Account a)
    {
        Dictionary<string, string> f = ReadForm(c);
        string dir = Resolve(a, NormRel(V(f, "p")));
        string name = V(f, "name").Trim();
        if (dir == null || !Directory.Exists(dir) || name.Length == 0 || name.Length > 100 || Safe(name) != name) { Json(c, 200, "{\"err\":\"bad\"}"); return; }
        string full = Path.Combine(dir, name);
        if (File.Exists(full) || Directory.Exists(full)) { Json(c, 200, "{\"err\":\"exists\"}"); return; }
        try { Directory.CreateDirectory(full); } catch { Json(c, 200, "{\"err\":\"bad\"}"); return; }
        Json(c, 200, "{\"ok\":1}");
    }

    static void DoRename(HttpListenerContext c, Account a)
    {
        Dictionary<string, string> f = ReadForm(c);
        string p = NormRel(V(f, "p"));
        string name = V(f, "name"), to = V(f, "to").Trim();
        string src = Resolve(a, JoinRel(p, name));
        string dir = Resolve(a, p);
        if (src == null || dir == null || name.Length == 0 || to.Length == 0 || to.Length > 150 || Safe(to) != to) { Json(c, 200, "{\"err\":\"bad\"}"); return; }
        string dst = Path.Combine(dir, to);
        bool isDir = Directory.Exists(src);
        if (!isDir && !File.Exists(src)) { Json(c, 200, "{\"err\":\"nodir\"}"); return; }
        if (string.Equals(src, dst, StringComparison.OrdinalIgnoreCase) && src != dst) { /* only the case of letters changes */ }
        else if (File.Exists(dst) || Directory.Exists(dst)) { Json(c, 200, "{\"err\":\"exists\"}"); return; }
        try { if (isDir) Directory.Move(src, dst); else File.Move(src, dst); }
        catch { Json(c, 200, "{\"err\":\"busy\"}"); return; }
        Json(c, 200, "{\"ok\":1}");
    }

    static void DoMove(HttpListenerContext c, Account a)
    {
        Dictionary<string, string> f = ReadForm(c);
        string p = NormRel(V(f, "p"));
        string name = V(f, "name");
        string src = Resolve(a, JoinRel(p, name));
        string destDir = Resolve(a, NormRel(V(f, "to")));
        if (src == null || destDir == null || name.Length == 0 || !Directory.Exists(destDir)) { Json(c, 200, "{\"err\":\"bad\"}"); return; }
        bool isDir = Directory.Exists(src);
        if (!isDir && !File.Exists(src)) { Json(c, 200, "{\"err\":\"nodir\"}"); return; }
        string dst = Path.Combine(destDir, name);
        if (isDir)
        {
            string s1 = src.TrimEnd('\\') + "\\";
            string d1 = destDir.TrimEnd('\\') + "\\";
            if (d1.StartsWith(s1, StringComparison.OrdinalIgnoreCase)) { Json(c, 200, "{\"err\":\"inside\"}"); return; }
        }
        if (File.Exists(dst) || Directory.Exists(dst)) { Json(c, 200, "{\"err\":\"exists\"}"); return; }
        try { if (isDir) Directory.Move(src, dst); else File.Move(src, dst); }
        catch { Json(c, 200, "{\"err\":\"busy\"}"); return; }
        Json(c, 200, "{\"ok\":1}");
    }

    static void DoDelete(HttpListenerContext c, Account a)
    {
        string rel = JoinRel(NormRel(QS(c, "p")), QS(c, "name"));
        string full = Resolve(a, rel);
        if (full == null || QS(c, "name").Length == 0) { Json(c, 200, "{\"err\":\"bad\"}"); return; }
        try
        {
            if (Directory.Exists(full)) { Directory.Delete(full, true); Log("delete", a.Id, Ip(c), QS(c, "name")); }
            else if (File.Exists(full)) { File.Delete(full); Log("delete", a.Id, Ip(c), QS(c, "name")); }
        }
        catch { Json(c, 200, "{\"err\":\"busy\"}"); return; }
        Json(c, 200, "{\"ok\":1}");
    }

    static void DoUpload(HttpListenerContext c, Account a)
    {
        bool admin = IsAdmin(a);
        string relDir = "";
        try { relDir = NormRel(Uri.UnescapeDataString(c.Request.Headers["X-Path"] ?? "")); } catch { }
        string dir = Resolve(a, relDir);
        if (dir == null) { Json(c, 400, "{\"err\":\"bad\"}"); return; }
        string name = "file";
        try { name = Uri.UnescapeDataString(c.Request.Headers["X-Name"] ?? "file"); } catch { }
        name = Safe(name);
        long total = ParseL(c.Request.Headers["X-Total"], -1);
        long offset = ParseL(c.Request.Headers["X-Offset"], 0);
        bool last = c.Request.Headers["X-Last"] == "1";
        string id = c.Request.Headers["X-Id"] ?? "";
        if (total < 0 || offset < 0) { Json(c, 400, "{\"err\":\"bad\"}"); return; }

        if (id.Length == 0)
        {
            if (offset != 0) { Json(c, 400, "{\"err\":\"bad\"}"); return; }
            if (!admin)
            {
                string ext = Path.GetExtension(name).TrimStart('.').ToLowerInvariant();
                if (ext.Length > 0 && InList(Get("badExt", DefBad), ext)) { Json(c, 415, "{\"err\":\"ext\"}"); return; }
                long maxF = (long)(GetD("maxFile", 0) * 1048576.0);
                if (maxF > 0 && total > maxF) { Json(c, 413, "{\"err\":\"toobig\"}"); return; }
            }
            long qb = QuotaBytes(a);
            if (qb > 0 && Used(a) + total > qb) { Json(c, 413, "{\"err\":\"quota\"}"); return; }
            if (!DiskOk(total)) { Json(c, 507, "{\"err\":\"disk\"}"); return; }
            id = RandHex(16);
        }
        else if (!IsHex(id)) { Json(c, 400, "{\"err\":\"bad\"}"); return; }

        Directory.CreateDirectory(dir);
        string part = Path.Combine(dir, id + ".part");
        bool tooMuch = false;
        using (FileStream fs = new FileStream(part, FileMode.OpenOrCreate, FileAccess.Write, FileShare.None))
        {
            if (offset > fs.Length) { Json(c, 409, "{\"err\":\"offset\"}"); return; }
            fs.SetLength(offset);
            fs.Position = offset;
            byte[] buf = new byte[81920];
            int n;
            long written = offset;
            Stream s = c.Request.InputStream;
            while ((n = s.Read(buf, 0, buf.Length)) > 0)
            {
                written += n;
                if (written > total) { tooMuch = true; break; }
                fs.Write(buf, 0, n);
            }
        }
        if (tooMuch)
        {
            try { File.Delete(part); } catch { }
            Json(c, 400, "{\"err\":\"bad\"}");
            return;
        }
        string finalName = "";
        if (last)
        {
            string final;
            lock (lk)
            {
                final = Unique(dir, name);
                File.Move(part, final);
            }
            finalName = Path.GetFileName(final);
            Log("upload", a.Id, Ip(c), finalName);
        }
        Json(c, 200, "{\"ok\":1,\"id\":" + Q(id) + ",\"name\":" + Q(finalName) + "}");
    }

    static void DoFile(HttpListenerContext c, Account a, bool download)
    {
        string name = QS(c, "name");
        string full = Resolve(a, JoinRel(NormRel(QS(c, "p")), name));
        if (full == null || name.Length == 0 || !File.Exists(full))
        {
            Log("nofile", a.Id, Ip(c), "p=" + QS(c, "p") + " name=" + name);
            Send(c, 404, "text/plain", "Not found: " + name);
            return;
        }
        ServeFile(c, full, name, download);
    }

    static void DoZip(HttpListenerContext c, Account a)
    {
        string name = QS(c, "name");
        string full = Resolve(a, JoinRel(NormRel(QS(c, "p")), name));
        if (full == null || !Directory.Exists(full)) { Send(c, 404, "text/plain", "Not found"); return; }
        ServeZip(c, full, name.Length > 0 ? name : "files");
    }

    // Serves a file inline (preview) or as attachment. Supports Range requests (video seeking).
    static void ServeFile(HttpListenerContext c, string full, string name, bool download)
    {
        string ext = Path.GetExtension(name);
        string mime = download ? "application/octet-stream" : Mime(ext);
        long len = new FileInfo(full).Length;
        long start = 0, end = len - 1;
        bool partial = false;

        string rh = c.Request.Headers["Range"];
        if (len > 0 && !string.IsNullOrEmpty(rh) && rh.StartsWith("bytes="))
        {
            string spec = rh.Substring(6).Split(',')[0].Trim();
            int dash = spec.IndexOf('-');
            if (dash >= 0)
            {
                string sa = spec.Substring(0, dash);
                string sb2 = spec.Substring(dash + 1);
                long vs, ve, suf;
                if (sa.Length == 0)
                {
                    if (long.TryParse(sb2, out suf) && suf > 0)
                    {
                        start = Math.Max(0L, len - suf);
                        end = len - 1;
                        partial = true;
                    }
                }
                else if (long.TryParse(sa, out vs))
                {
                    start = vs;
                    end = len - 1;
                    if (sb2.Length > 0 && long.TryParse(sb2, out ve)) end = Math.Min(ve, len - 1);
                    partial = true;
                }
            }
            if (partial && (start >= len || start > end))
            {
                c.Response.StatusCode = 416;
                c.Response.AddHeader("Content-Range", "bytes */" + len);
                c.Response.ContentLength64 = 0;
                c.Response.Close();
                return;
            }
        }

        long count = len == 0 ? 0 : (end - start + 1);
        c.Response.StatusCode = partial ? 206 : 200;
        c.Response.ContentType = mime;
        c.Response.AddHeader("Accept-Ranges", "bytes");
        c.Response.AddHeader("X-Content-Type-Options", "nosniff");
        if (partial) c.Response.AddHeader("Content-Range", "bytes " + start + "-" + end + "/" + len);
        if (!download)
        {
            c.Response.AddHeader("Cache-Control", "private, max-age=600");
            if (ext.ToLowerInvariant() == ".svg") c.Response.AddHeader("Content-Security-Policy", "sandbox");
        }
        c.Response.AddHeader("Content-Disposition", Disp(download, name));
        c.Response.ContentLength64 = count;

        using (FileStream fs = new FileStream(full, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        {
            fs.Seek(start, SeekOrigin.Begin);
            byte[] buf = new byte[81920];
            long left = count;
            Stream os = c.Response.OutputStream;
            while (left > 0)
            {
                int n = fs.Read(buf, 0, (int)Math.Min((long)buf.Length, left));
                if (n <= 0) break;
                os.Write(buf, 0, n);
                left -= n;
            }
        }
        c.Response.Close();
    }

    static void ServeZip(HttpListenerContext c, string dir, string zipName)
    {
        c.Response.StatusCode = 200;
        c.Response.ContentType = "application/zip";
        c.Response.SendChunked = true;
        c.Response.AddHeader("Content-Disposition", Disp(true, zipName + ".zip"));
        using (ZipArchive za = new ZipArchive(c.Response.OutputStream, ZipArchiveMode.Create, true, Encoding.UTF8))
        {
            AddToZip(za, dir, "");
        }
        c.Response.Close();
    }

    static void AddToZip(ZipArchive za, string dir, string prefix)
    {
        foreach (string f in Directory.GetFiles(dir))
        {
            if (f.EndsWith(".part", StringComparison.OrdinalIgnoreCase)) continue;
            ZipArchiveEntry e = za.CreateEntry(prefix + Path.GetFileName(f), CompressionLevel.Fastest);
            using (Stream es = e.Open())
            using (FileStream fs = new FileStream(f, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                fs.CopyTo(es);
        }
        foreach (string d in Directory.GetDirectories(dir))
            AddToZip(za, d, prefix + Path.GetFileName(d) + "/");
    }

    // Finds what a download address (the same address the browser would use) points to.
    static string LinkTarget(Account me, string u, out string name, out bool zip)
    {
        name = ""; zip = false;
        string full = null;
        int qi = u.IndexOf('?');
        string upath = qi >= 0 ? u.Substring(0, qi) : u;
        string query = qi >= 0 ? u.Substring(qi + 1) : "";
        if (upath.StartsWith("/download"))
        {
            name = QParam(query, "name");
            full = Resolve(me, JoinRel(NormRel(QParam(query, "p")), name));
            if (name.Length == 0 || full == null || !File.Exists(full)) full = null;
        }
        else if (upath.StartsWith("/zip"))
        {
            zip = true;
            string nm = QParam(query, "name");
            full = Resolve(me, JoinRel(NormRel(QParam(query, "p")), nm));
            name = nm.Length > 0 ? nm : "files";
            if (full == null || !Directory.Exists(full)) full = null;
        }
        else if (upath.StartsWith("/api/chat/item"))
        {
            Msg msg; Account sender;
            full = ChatItemPath(me, QParam(query, "peer"), ParseL(QParam(query, "m"), 0), NormRel(QParam(query, "sub")), out msg, out sender);
            if (full != null)
            {
                name = Path.GetFileName(full);
                if (QParam(query, "z") == "1") { zip = true; if (!Directory.Exists(full)) full = null; }
                else if (!File.Exists(full)) full = null;
            }
        }
        return full;
    }

    // One-time download links: /get/<token>/<file name>. They work without cookies and the browser
    // always sees the real file name at the end of the address.
    static string MakeLink(string full, string name, bool zip, int minutes)
    {
        string tok = RandHex(16);
        lock (lk)
        {
            List<string> old = new List<string>();
            foreach (KeyValuePair<string, Link> kv in links) { if (kv.Value.Exp < DateTime.UtcNow) old.Add(kv.Key); }
            foreach (string k in old) links.Remove(k);
            Link ln = new Link();
            ln.Full = full; ln.Name = name; ln.Zip = zip; ln.Exp = DateTime.UtcNow.AddMinutes(minutes);
            links[tok] = ln;
        }
        return "/get/" + tok + "/" + Uri.EscapeDataString(name + (zip ? ".zip" : ""));
    }

    static void DoLink(HttpListenerContext c, Account me)
    {
        Dictionary<string, string> f = ReadForm(c);
        string u = V(f, "u");
        string name; bool zip;
        string full = LinkTarget(me, u, out name, out zip);
        if (full == null)
        {
            Log("nofile", me.Id, Ip(c), u);
            Json(c, 200, "{\"err\":\"gone\"}");
            return;
        }
        Json(c, 200, "{\"url\":" + Q(MakeLink(full, name, zip, 30)) + "}");
    }

    // ---- folders as ZIP: the archive is built in a temporary file first (works with every browser,
    // has a known size and survives interrupted downloads), the page shows the progress
    static void DoZipStart(HttpListenerContext c, Account me)
    {
        Dictionary<string, string> f = ReadForm(c);
        string name; bool zip;
        string full = LinkTarget(me, V(f, "u"), out name, out zip);
        if (full == null || !zip) { Json(c, 200, "{\"err\":\"gone\"}"); return; }
        long total = DirSize(full);
        if (!DiskOk(total)) { Json(c, 200, "{\"err\":\"disk\"}"); return; }
        ZipJob j = new ZipJob();
        j.Id = RandHex(8); j.AccId = me.Id; j.Dir = full; j.Name = name; j.Total = total;
        j.Exp = DateTime.UtcNow.AddHours(2);
        j.Tmp = Path.Combine(tmpDir, j.Id + ".zip");
        lock (lk)
        {
            List<string> old = new List<string>();
            foreach (KeyValuePair<string, ZipJob> kv in zjobs) { if (kv.Value.Exp < DateTime.UtcNow) old.Add(kv.Key); }
            foreach (string k in old)
            {
                try { File.Delete(zjobs[k].Tmp); } catch { }
                zjobs.Remove(k);
            }
            zjobs[j.Id] = j;
        }
        ThreadPool.QueueUserWorkItem(delegate(object o) { BuildZip(j); });
        Json(c, 200, "{\"job\":" + Q(j.Id) + "}");
    }

    static void DoZipStatus(HttpListenerContext c, Account me)
    {
        ZipJob j;
        lock (lk) { zjobs.TryGetValue(QS(c, "job"), out j); }
        if (j == null || j.AccId != me.Id) { Json(c, 200, "{\"st\":2}"); return; }
        Json(c, 200, "{\"st\":" + j.State + ",\"done\":" + j.Done + ",\"total\":" + j.Total + ",\"url\":" + Q(j.Url) + "}");
    }

    static void BuildZip(ZipJob j)
    {
        try
        {
            Directory.CreateDirectory(tmpDir);
            using (FileStream fs = new FileStream(j.Tmp, FileMode.Create, FileAccess.ReadWrite))
            {
                using (ZipArchive za = new ZipArchive(fs, ZipArchiveMode.Create, true, Encoding.UTF8))
                {
                    AddToZipJob(za, j.Dir, "", j);
                }
            }
            j.Url = MakeLink(j.Tmp, j.Name + ".zip", false, 120);
            j.State = 1;
        }
        catch
        {
            j.State = 2;
            try { File.Delete(j.Tmp); } catch { }
        }
    }

    static void AddToZipJob(ZipArchive za, string dir, string prefix, ZipJob j)
    {
        foreach (string f in Directory.GetFiles(dir))
        {
            if (f.EndsWith(".part", StringComparison.OrdinalIgnoreCase)) continue;
            FileStream src = null;
            try { src = new FileStream(f, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete); }
            catch { continue; }
            using (src)
            {
                ZipArchiveEntry e = za.CreateEntry(prefix + Path.GetFileName(f), CompressionLevel.NoCompression);
                using (Stream es = e.Open())
                {
                    byte[] buf = new byte[262144];
                    int n;
                    while ((n = src.Read(buf, 0, buf.Length)) > 0) { es.Write(buf, 0, n); j.Done += n; }
                }
            }
        }
        foreach (string d in Directory.GetDirectories(dir))
            AddToZipJob(za, d, prefix + Path.GetFileName(d) + "/", j);
    }

    static void DoGet(HttpListenerContext c, string rawPath)
    {
        string[] seg = rawPath.Split('/');
        Link ln = null;
        if (seg.Length >= 3)
        {
            lock (lk)
            {
                if (links.TryGetValue(seg[2], out ln) && ln.Exp < DateTime.UtcNow) { links.Remove(seg[2]); ln = null; }
            }
        }
        if (ln == null) { Send(c, 404, "text/plain", "Link expired"); return; }
        if (ln.Zip)
        {
            if (!Directory.Exists(ln.Full)) { Send(c, 404, "text/plain", "Not found"); return; }
            ServeZip(c, ln.Full, ln.Name);
            return;
        }
        if (!File.Exists(ln.Full)) { Send(c, 404, "text/plain", "Not found"); return; }
        ServeFile(c, ln.Full, ln.Name, true);
    }

    static void CopyDir(string src, string dst)
    {
        Directory.CreateDirectory(dst);
        foreach (string f in Directory.GetFiles(src))
        {
            if (f.EndsWith(".part", StringComparison.OrdinalIgnoreCase)) continue;
            File.Copy(f, Path.Combine(dst, Path.GetFileName(f)), false);
        }
        foreach (string d in Directory.GetDirectories(src))
            CopyDir(d, Path.Combine(dst, Path.GetFileName(d)));
    }

    // ------------------------------------------------------------ chat
    static string ConvKey(string a, string b) { return string.CompareOrdinal(a, b) <= 0 ? a + "_" + b : b + "_" + a; }

    static Conv GetConv(string idA, string idB, bool create)
    {
        string key = ConvKey(idA, idB);
        lock (lk)
        {
            Conv cv;
            if (convs.TryGetValue(key, out cv)) return cv;
            if (!create) return null;
            cv = new Conv();
            cv.Key = key;
            string[] ids = key.Split('_');
            cv.P1 = ids[0]; cv.P2 = ids[1];
            convs[key] = cv;
            return cv;
        }
    }

    static void LoadChats()
    {
        if (!Directory.Exists(chatDir)) return;
        foreach (string f in Directory.GetFiles(chatDir, "*.txt"))
        {
            string key = Path.GetFileNameWithoutExtension(f);
            string[] ids = key.Split('_');
            if (ids.Length != 2) continue;
            Conv cv = new Conv();
            cv.Key = key; cv.P1 = ids[0]; cv.P2 = ids[1];
            try
            {
                foreach (string line in File.ReadAllLines(f, Encoding.UTF8))
                {
                    string[] p = line.Split('\t');
                    if (p.Length < 7) continue;
                    Msg m = new Msg();
                    m.Id = ParseL(p[0], 0); m.Ts = ParseL(p[1], 0); m.From = p[2]; m.Type = p[3];
                    m.A = Unesc(p[4]); m.B = Unesc(p[5]); m.C = Unesc(p[6]);
                    cv.List.Add(m);
                    if (m.Id > lastMsgId) lastMsgId = m.Id;
                }
            }
            catch { }
            convs[key] = cv;
        }
    }

    static Msg AddMsg(Account frm, Account to, string type, string a, string b, string c2)
    {
        Msg m = new Msg();
        lock (lk)
        {
            Conv cv = GetConv(frm.Id, to.Id, true);
            lastMsgId = Math.Max(lastMsgId + 1, NowMs());
            m.Id = lastMsgId; m.Ts = NowMs(); m.From = frm.Id; m.Type = type; m.A = a; m.B = b; m.C = c2;
            cv.List.Add(m);
            try
            {
                Directory.CreateDirectory(chatDir);
                File.AppendAllText(Path.Combine(chatDir, cv.Key + ".txt"),
                    m.Id + "\t" + m.Ts + "\t" + m.From + "\t" + m.Type + "\t" + Esc(a) + "\t" + Esc(b) + "\t" + Esc(c2) + "\r\n", Encoding.UTF8);
            }
            catch { }
        }
        return m;
    }

    static void SaveReads()
    {
        lock (lk)
        {
            try
            {
                StringBuilder sb = new StringBuilder();
                foreach (KeyValuePair<string, long> kv in reads) sb.Append(kv.Key).Append('\t').Append(kv.Value).Append("\r\n");
                File.WriteAllText(readFile, sb.ToString(), Encoding.UTF8);
            }
            catch { }
        }
    }

    static void LoadReads()
    {
        if (!File.Exists(readFile)) return;
        foreach (string line in File.ReadAllLines(readFile, Encoding.UTF8))
        {
            string[] p = line.Split('\t');
            if (p.Length < 2) continue;
            reads[p[0]] = ParseL(p[1], 0);
        }
    }

    static long ReadMark(string accId, string key)
    {
        long v;
        return reads.TryGetValue(accId + "|" + key, out v) ? v : 0;
    }

    static void MarkRead(Account me, Conv cv)
    {
        lock (lk)
        {
            long last = cv.List.Count > 0 ? cv.List[cv.List.Count - 1].Id : 0;
            string k = me.Id + "|" + cv.Key;
            long old;
            if (!reads.TryGetValue(k, out old) || old < last) { reads[k] = last; SaveReads(); }
        }
    }

    static int UnreadIn(Account me, Conv cv)
    {
        long mark = ReadMark(me.Id, cv.Key);
        int n = 0;
        foreach (Msg m in cv.List) { if (m.Id > mark && m.From != me.Id) n++; }
        return n;
    }

    static int UnreadTotal(Account me)
    {
        int n = 0;
        if (Get("chat", "1") != "1") return 0;
        lock (lk)
        {
            foreach (Conv cv in convs.Values)
            {
                if (cv.P1 == me.Id || cv.P2 == me.Id) n += UnreadIn(me, cv);
            }
        }
        return n;
    }

    static string MsgJson(Msg m, Account me, Account peer)
    {
        Account sender = m.From == me.Id ? me : peer;
        StringBuilder sb = new StringBuilder("{");
        sb.Append("\"i\":").Append(m.Id).Append(",\"ts\":").Append(m.Ts).Append(",\"f\":").Append(Q(m.From)).Append(",\"k\":").Append(Q(m.Type));
        if (m.Type == "text") sb.Append(",\"t\":").Append(Q(m.A));
        else
        {
            string full = Resolve(sender, m.A);
            bool ok = false;
            if (full != null) ok = m.Type == "file" ? File.Exists(full) : Directory.Exists(full);
            string ext = Path.GetExtension(m.B);
            sb.Append(",\"t\":").Append(Q(m.B)).Append(",\"s\":").Append(ParseL(m.C, 0));
            sb.Append(",\"x\":").Append(ok ? "1" : "0");
            sb.Append(",\"kd\":").Append(Q(m.Type == "file" ? Kind(ext) : "dir"));
            sb.Append(",\"e\":").Append(Q(ext.TrimStart('.').ToLowerInvariant()));
        }
        sb.Append("}");
        return sb.ToString();
    }

    static string Preview(Msg m)
    {
        if (m.Type == "text") return Trunc(m.A, 100);
        return (m.Type == "file" ? TxtFile : TxtDir) + ": " + m.B;
    }

    static void DoChat(HttpListenerContext c, Account me, string path, string m)
    {
        if (Get("chat", "1") != "1") { Json(c, 200, "{\"err\":\"chatoff\"}"); return; }
        if (path == "/api/chat/list" && m == "GET") { DoChatList(c, me); return; }
        if (path == "/api/chat/msgs" && m == "GET") { DoChatMsgs(c, me); return; }
        if (path == "/api/chat/find" && m == "GET") { DoChatFind(c, me); return; }
        if (path == "/api/chat/item" && m == "GET") { DoChatItem(c, me); return; }
        if (path == "/api/chat/dir" && m == "GET") { DoChatDir(c, me); return; }
        if (path == "/api/chat/send" && m == "POST") { DoChatSend(c, me); return; }
        if (path == "/api/chat/save" && m == "POST") { DoChatSave(c, me); return; }
        Json(c, 404, "{\"err\":\"nf\"}");
    }

    static void DoChatFind(HttpListenerContext c, Account me)
    {
        string id = QS(c, "id").Trim();
        Account a;
        lock (lk) { byId.TryGetValue(id, out a); }
        if (a == null || a.Blocked != 0 || object.ReferenceEquals(a, me)) { Json(c, 200, "{\"err\":\"nouser\"}"); return; }
        Json(c, 200, "{\"id\":" + Q(a.Id) + ",\"name\":" + Q(DisplayName(a)) + "}");
    }

    static void DoChatList(HttpListenerContext c, Account me)
    {
        StringBuilder sb = new StringBuilder("[");
        lock (lk)
        {
            List<Conv> mine = new List<Conv>();
            foreach (Conv cv in convs.Values)
            {
                if (cv.List.Count > 0 && (cv.P1 == me.Id || cv.P2 == me.Id)) mine.Add(cv);
            }
            mine.Sort(delegate(Conv x, Conv y) { return y.List[y.List.Count - 1].Id.CompareTo(x.List[x.List.Count - 1].Id); });
            bool first = true;
            foreach (Conv cv in mine)
            {
                string peerId = cv.P1 == me.Id ? cv.P2 : cv.P1;
                Account peer;
                if (!byId.TryGetValue(peerId, out peer)) continue;
                Msg last = cv.List[cv.List.Count - 1];
                if (!first) sb.Append(',');
                first = false;
                sb.Append("{\"id\":").Append(Q(peerId)).Append(",\"name\":").Append(Q(DisplayName(peer)));
                sb.Append(",\"u\":").Append(UnreadIn(me, cv));
                sb.Append(",\"ts\":").Append(last.Ts).Append(",\"mine\":").Append(last.From == me.Id ? "1" : "0");
                sb.Append(",\"k\":").Append(Q(last.Type)).Append(",\"t\":").Append(Q(last.Type == "text" ? Trunc(last.A, 80) : last.B)).Append("}");
            }
        }
        sb.Append("]");
        Json(c, 200, sb.ToString());
    }

    static void DoChatMsgs(HttpListenerContext c, Account me)
    {
        string peerId = QS(c, "peer");
        long after = ParseL(QS(c, "after"), 0);
        Account peer;
        lock (lk) { byId.TryGetValue(peerId, out peer); }
        if (peer == null) { Json(c, 200, "{\"err\":\"nouser\"}"); return; }
        Conv cv = GetConv(me.Id, peer.Id, false);
        StringBuilder sb = new StringBuilder("{\"peer\":{\"id\":" + Q(peer.Id) + ",\"name\":" + Q(DisplayName(peer)) + "},\"msgs\":[");
        if (cv != null)
        {
            lock (lk)
            {
                bool first = true;
                foreach (Msg m in cv.List)
                {
                    if (m.Id <= after) continue;
                    if (!first) sb.Append(',');
                    first = false;
                    sb.Append(MsgJson(m, me, peer));
                }
            }
            if (QS(c, "mark") == "1") MarkRead(me, cv);
        }
        sb.Append("]}");
        Json(c, 200, sb.ToString());
    }

    static void DoChatSend(HttpListenerContext c, Account me)
    {
        Dictionary<string, string> f = ReadForm(c);
        Account peer;
        lock (lk) { byId.TryGetValue(V(f, "peer"), out peer); }
        if (peer == null || object.ReferenceEquals(peer, me) || peer.Blocked != 0) { Json(c, 200, "{\"err\":\"nouser\"}"); return; }
        if (Count("msg:" + me.Id, 60) >= 40) { Json(c, 200, "{\"err\":\"locked\"}"); return; }
        string type = V(f, "type");
        Msg msg;
        if (type == "text")
        {
            string t = V(f, "text").Trim();
            if (t.Length == 0) { Json(c, 200, "{\"err\":\"bad\"}"); return; }
            msg = AddMsg(me, peer, "text", Trunc(t, 2000), "", "");
        }
        else if (type == "file" || type == "dir")
        {
            string name = V(f, "name");
            string rel = JoinRel(NormRel(V(f, "p")), name);
            string full = Resolve(me, rel);
            if (full == null || name.Length == 0) { Json(c, 200, "{\"err\":\"bad\"}"); return; }
            long size = 0;
            if (type == "file")
            {
                if (!File.Exists(full)) { Json(c, 200, "{\"err\":\"gone\"}"); return; }
                size = new FileInfo(full).Length;
            }
            else
            {
                if (!Directory.Exists(full)) { Json(c, 200, "{\"err\":\"gone\"}"); return; }
                size = DirSize(full);
            }
            msg = AddMsg(me, peer, type, rel, name, size.ToString());
        }
        else { Json(c, 200, "{\"err\":\"bad\"}"); return; }
        Hit("msg:" + me.Id);
        Notify(peer, DisplayName(me), Preview(msg), "/#chat/" + me.Id, "chat" + me.Id);
        Json(c, 200, "{\"ok\":1,\"m\":" + MsgJson(msg, me, peer) + "}");
    }

    // Finds the full path of an item shared in a message (or of a file inside a shared folder).
    static string ChatItemPath(Account me, string peerId, long mid, string sub, out Msg msg, out Account sender)
    {
        msg = null; sender = null;
        Conv cv = GetConv(me.Id, peerId, false);
        if (cv == null) return null;
        Msg found = null;
        Account snd = null;
        lock (lk)
        {
            foreach (Msg x in cv.List)
            {
                if (x.Id == mid) { found = x; break; }
            }
            if (found != null) byId.TryGetValue(found.From, out snd);
        }
        if (found == null || found.Type == "text" || snd == null) return null;
        msg = found; sender = snd;
        string rel = found.A;
        if (!string.IsNullOrEmpty(sub))
        {
            if (found.Type != "dir") return null;
            rel = JoinRel(found.A, sub);
        }
        return Resolve(snd, rel);
    }

    static void DoChatItem(HttpListenerContext c, Account me)
    {
        Msg msg; Account sender;
        string full = ChatItemPath(me, QS(c, "peer"), ParseL(QS(c, "m"), 0), NormRel(QS(c, "sub")), out msg, out sender);
        if (full == null) { Send(c, 404, "text/plain", "Not found"); return; }
        if (QS(c, "z") == "1")
        {
            if (!Directory.Exists(full)) { Send(c, 404, "text/plain", "Not found"); return; }
            ServeZip(c, full, Path.GetFileName(full));
            return;
        }
        if (!File.Exists(full)) { Send(c, 404, "text/plain", "Not found"); return; }
        ServeFile(c, full, Path.GetFileName(full), QS(c, "dl") == "1");
    }

    static void DoChatDir(HttpListenerContext c, Account me)
    {
        Msg msg; Account sender;
        string sub = NormRel(QS(c, "sub"));
        string full = ChatItemPath(me, QS(c, "peer"), ParseL(QS(c, "m"), 0), sub, out msg, out sender);
        if (full == null || msg.Type != "dir" || !Directory.Exists(full)) { Json(c, 200, "{\"err\":\"gone\"}"); return; }
        Json(c, 200, ListJson(full, sub));
    }

    static void DoChatSave(HttpListenerContext c, Account me)
    {
        Dictionary<string, string> f = ReadForm(c);
        Msg msg; Account sender;
        string full = ChatItemPath(me, V(f, "peer"), ParseL(V(f, "m"), 0), NormRel(V(f, "sub")), out msg, out sender);
        if (full == null) { Json(c, 200, "{\"err\":\"gone\"}"); return; }
        bool isDir = Directory.Exists(full);
        if (!isDir && !File.Exists(full)) { Json(c, 200, "{\"err\":\"gone\"}"); return; }
        long size = isDir ? DirSize(full) : new FileInfo(full).Length;
        long qb = QuotaBytes(me);
        if (qb > 0 && Used(me) + size > qb) { Json(c, 200, "{\"err\":\"quota\"}"); return; }
        if (!DiskOk(size)) { Json(c, 200, "{\"err\":\"disk\"}"); return; }
        string fromName = Safe(DisplayName(sender));
        string destDir = Path.Combine(Path.Combine(FolderPath(me), DirRecv), fromName);
        try
        {
            Directory.CreateDirectory(destDir);
            string nm = Path.GetFileName(full);
            if (isDir) CopyDir(full, UniqueDir(destDir, nm));
            else File.Copy(full, Unique(destDir, nm), false);
        }
        catch { Json(c, 200, "{\"err\":\"busy\"}"); return; }
        Json(c, 200, "{\"ok\":1}");
    }

    // ------------------------------------------------------------ push notifications (web push, no payload)
    static void SaveSubs()
    {
        lock (lk)
        {
            try
            {
                StringBuilder sb = new StringBuilder();
                foreach (Sub s in subs) sb.Append(s.AccId).Append('\t').Append(s.Token).Append('\t').Append(s.Endpoint).Append("\r\n");
                File.WriteAllText(subFile, sb.ToString(), Encoding.UTF8);
            }
            catch { }
        }
    }

    static void LoadSubs()
    {
        if (!File.Exists(subFile)) return;
        foreach (string line in File.ReadAllLines(subFile, Encoding.UTF8))
        {
            string[] p = line.Split('\t');
            if (p.Length < 3 || !byId.ContainsKey(p[0])) continue;
            Sub s = new Sub();
            s.AccId = p[0]; s.Token = p[1]; s.Endpoint = p[2];
            subs.Add(s);
        }
    }

    static void InitVapid()
    {
        try
        {
            string pv = Get("vapidPriv", "");
            if (pv.Length > 0)
            {
                try { vapidKey = CngKey.Import(Convert.FromBase64String(pv), CngKeyBlobFormat.EccPrivateBlob); }
                catch { vapidKey = null; }
            }
            if (vapidKey == null)
            {
                CngKeyCreationParameters kp = new CngKeyCreationParameters();
                kp.ExportPolicy = CngExportPolicies.AllowPlaintextExport;
                CngKey k = CngKey.Create(CngAlgorithm.ECDsaP256, null, kp);
                Put("vapidPriv", Convert.ToBase64String(k.Export(CngKeyBlobFormat.EccPrivateBlob)));
                SaveSettings();
                vapidKey = k;
            }
            byte[] bl = vapidKey.Export(CngKeyBlobFormat.EccPublicBlob);
            byte[] pub = new byte[65];
            pub[0] = 4;
            Buffer.BlockCopy(bl, 8, pub, 1, 64);
            vapidPub = B64u(pub);
        }
        catch { vapidKey = null; vapidPub = ""; }
    }

    static string VapidJwt(string aud)
    {
        string hdr = B64u(Encoding.UTF8.GetBytes("{\"typ\":\"JWT\",\"alg\":\"ES256\"}"));
        long exp = (long)(DateTime.UtcNow - epoch).TotalSeconds + 12 * 3600;
        string pl = B64u(Encoding.UTF8.GetBytes("{\"aud\":\"" + aud + "\",\"exp\":" + exp + ",\"sub\":\"" + PushSubject + "\"}"));
        byte[] sig;
        using (ECDsaCng ec = new ECDsaCng(vapidKey))
        {
            ec.HashAlgorithm = CngAlgorithm.Sha256;
            sig = ec.SignData(Encoding.ASCII.GetBytes(hdr + "." + pl));
        }
        return hdr + "." + pl + "." + B64u(sig);
    }

    static void SendPush(Sub s)
    {
        if (vapidKey == null) return;
        try
        {
            Uri u = new Uri(s.Endpoint);
            string aud = u.GetLeftPart(UriPartial.Authority);
            HttpWebRequest rq = (HttpWebRequest)WebRequest.Create(s.Endpoint);
            rq.Method = "POST";
            rq.ContentLength = 0;
            rq.Timeout = 15000;
            rq.Headers["Authorization"] = "vapid t=" + VapidJwt(aud) + ", k=" + vapidPub;
            rq.Headers["TTL"] = "86400";
            rq.Headers["Urgency"] = "high";
            using (HttpWebResponse rs = (HttpWebResponse)rq.GetResponse()) { }
        }
        catch (WebException ex)
        {
            HttpWebResponse r = ex.Response as HttpWebResponse;
            if (r != null && (r.StatusCode == HttpStatusCode.NotFound || r.StatusCode == HttpStatusCode.Gone))
            {
                lock (lk) { subs.Remove(s); SaveSubs(); }
            }
        }
        catch { }
    }

    // Queues a notification for every device of the user that is not looking at the site right now and sends a push.
    static void Notify(Account to, string title, string body, string url, string tag)
    {
        List<Sub> targets = new List<Sub>();
        lock (lk)
        {
            foreach (Sub s in subs)
            {
                if (s.AccId != to.Id) continue;
                Session ss;
                if (sess.TryGetValue(s.Token, out ss) && (DateTime.UtcNow - ss.Seen).TotalSeconds < 25) continue;
                targets.Add(s);
            }
            foreach (Sub s in targets)
            {
                List<Notif> q;
                if (!notifs.TryGetValue(s.Token, out q)) { q = new List<Notif>(); notifs[s.Token] = q; }
                Notif n = new Notif();
                n.Id = NowMs(); n.Title = title; n.Body = body; n.Url = url; n.Tag = tag;
                q.Add(n);
                if (q.Count > 20) q.RemoveAt(0);
            }
        }
        foreach (Sub s in targets)
        {
            Sub sc = s;
            ThreadPool.QueueUserWorkItem(delegate(object o) { SendPush(sc); });
        }
    }

    static void DoPush(HttpListenerContext c, Account me, string path, string token)
    {
        if (path == "/api/push/key")
        {
            Json(c, 200, vapidPub.Length > 0 ? "{\"key\":" + Q(vapidPub) + "}" : "{\"err\":\"nopush\"}");
            return;
        }
        if (path == "/api/push/pending")
        {
            List<Notif> items = null;
            lock (lk)
            {
                List<Notif> q;
                if (notifs.TryGetValue(token, out q)) { items = new List<Notif>(q); q.Clear(); }
            }
            int unread = UnreadTotal(me);
            StringBuilder sb = new StringBuilder("[");
            if (items != null)
            {
                for (int i = 0; i < items.Count; i++)
                {
                    if (i > 0) sb.Append(',');
                    Notif n = items[i];
                    sb.Append("{\"i\":").Append(n.Id).Append(",\"t\":").Append(Q(n.Title)).Append(",\"b\":").Append(Q(n.Body));
                    sb.Append(",\"u\":").Append(Q(n.Url)).Append(",\"g\":").Append(Q(n.Tag)).Append(",\"n\":").Append(unread).Append("}");
                }
            }
            sb.Append("]");
            Json(c, 200, sb.ToString());
            return;
        }
        if (c.Request.HttpMethod != "POST") { Json(c, 404, "{\"err\":\"nf\"}"); return; }
        if (path == "/api/push/sub")
        {
            Dictionary<string, string> f = ReadForm(c);
            string ep = V(f, "endpoint");
            if (!ep.StartsWith("https://") || ep.Length > 1000) { Json(c, 200, "{\"err\":\"bad\"}"); return; }
            lock (lk)
            {
                subs.RemoveAll(delegate(Sub x) { return x.Endpoint == ep || x.Token == token; });
                Sub s = new Sub();
                s.AccId = me.Id; s.Token = token; s.Endpoint = ep;
                subs.Add(s);
                SaveSubs();
            }
            Json(c, 200, "{\"ok\":1}");
            return;
        }
        if (path == "/api/push/unsub")
        {
            lock (lk) { subs.RemoveAll(delegate(Sub x) { return x.Token == token; }); notifs.Remove(token); SaveSubs(); }
            Json(c, 200, "{\"ok\":1}");
            return;
        }
        Json(c, 404, "{\"err\":\"nf\"}");
    }

    // ------------------------------------------------------------ admin api
    static void AdminApi(HttpListenerContext c, string path, string m, Account me)
    {
        if (path == "/api/admin/state" && m == "GET") { DoState(c); return; }
        if (m != "POST") { Json(c, 404, "{\"err\":\"nf\"}"); return; }
        Dictionary<string, string> f = ReadForm(c);
        string ip = Ip(c);

        if (path == "/api/admin/settings")
        {
            lock (lk)
            {
                Put("title", Trunc(V(f, "title").Trim(), 40));
                Put("reg", V(f, "reg") == "1" ? "1" : "0");
                Put("approve", V(f, "approve") == "1" ? "1" : "0");
                Put("maint", V(f, "maint") == "1" ? "1" : "0");
                Put("chat", V(f, "chat") == "0" ? "0" : "1");
                Put("maxUsers", Dbl(Math.Max(0.0, ParseD(V(f, "maxUsers"), 0))));
                Put("defQuota", Dbl(Math.Max(0.0, ParseD(V(f, "defQuota"), 5))));
                Put("maxFile", Dbl(Math.Max(0.0, ParseD(V(f, "maxFile"), 0))));
                Put("reserve", Dbl(Math.Max(0.0, ParseD(V(f, "reserve"), 2))));
                Put("badExt", CleanExt(V(f, "badExt")));
                SaveSettings();
            }
            Log("settings", me.Id, ip, "");
            Json(c, 200, "{\"ok\":1}");
            return;
        }

        if (path == "/api/admin/notice")
        {
            string act = V(f, "act");
            string text = "";
            lock (lk)
            {
                if (act == "send")
                {
                    text = Trunc(V(f, "text").Trim(), 500);
                    if (text.Length == 0) { Json(c, 200, "{\"err\":\"empty\"}"); return; }
                    Put("nid", NowMs().ToString());
                    Put("nt", text);
                    Put("ntime", NowMs().ToString());
                }
                else { Put("nid", ""); Put("nt", ""); Put("ntime", "0"); }
                SaveSettings();
            }
            Log("notice", me.Id, ip, act == "send" ? "send" : "clear");
            if (act == "send")
            {
                List<Account> all;
                lock (lk) { all = new List<Account>(accs.Values); }
                foreach (Account x in all) Notify(x, TxtNotice, Trunc(text, 120), "/", "notice");
            }
            Json(c, 200, "{\"ok\":1}");
            return;
        }

        if (path == "/api/admin/user")
        {
            string act = V(f, "act");
            string target = V(f, "target");
            string err = null;
            string kind = "useredit";
            if (act == "update") err = UpdateUser(f);
            else if (act == "delete") { err = DeleteUser(target, V(f, "wipe") == "1"); kind = "userdel"; }
            else if (act == "kick")
            {
                kind = "kick";
                lock (lk) { Account a; if (accs.TryGetValue(target, out a) && !IsAdmin(a)) KillSessions(a, ""); }
            }
            else if (act == "create")
            {
                kind = "usernew";
                string q = V(f, "q");
                double qv = ParseD(q, double.NaN);
                double quota = (q == "def" || double.IsNaN(qv)) ? -1 : Math.Max(0.0, qv);
                err = CreateUser(V(f, "nl").Trim(), V(f, "np"), V(f, "nm"), quota, 0, true);
                target = V(f, "nl").Trim();
            }
            else err = "bad";
            if (err == null) Log(kind, me.Id, ip, target);
            Json(c, 200, err == null ? "{\"ok\":1}" : "{\"err\":" + Q(err) + "}");
            return;
        }

        Json(c, 404, "{\"err\":\"nf\"}");
    }

    static void DoState(HttpListenerContext c)
    {
        StringBuilder sb = new StringBuilder();
        lock (lk)
        {
            sb.Append("{\"now\":").Append(NowMs());
            sb.Append(",\"pub\":").Append(Q(PublicUrl ?? ""));
            sb.Append(",\"up\":").Append((long)(DateTime.Now - started).TotalSeconds);
            long disk = -1, diskTotal = -1;
            try { DriveInfo di = new DriveInfo(Path.GetPathRoot(root)); disk = di.AvailableFreeSpace; diskTotal = di.TotalSize; } catch { }
            sb.Append(",\"disk\":").Append(disk).Append(",\"diskTotal\":").Append(diskTotal);
            sb.Append(",\"subs\":").Append(subs.Count);

            sb.Append(",\"set\":{\"title\":").Append(Q(Get("title", "")));
            sb.Append(",\"reg\":").Append(Get("reg", "1") == "1" ? "1" : "0");
            sb.Append(",\"approve\":").Append(Get("approve", "0") == "1" ? "1" : "0");
            sb.Append(",\"maint\":").Append(Get("maint", "0") == "1" ? "1" : "0");
            sb.Append(",\"chat\":").Append(Get("chat", "1") == "1" ? "1" : "0");
            sb.Append(",\"maxUsers\":").Append(Dbl(GetD("maxUsers", 0)));
            sb.Append(",\"defQuota\":").Append(Dbl(GetD("defQuota", 5)));
            sb.Append(",\"maxFile\":").Append(Dbl(GetD("maxFile", 0)));
            sb.Append(",\"reserve\":").Append(Dbl(GetD("reserve", 2)));
            sb.Append(",\"badExt\":").Append(Q(Get("badExt", DefBad)));
            sb.Append(",\"nid\":").Append(Q(Get("nid", ""))).Append(",\"nt\":").Append(Q(Get("nt", "")));
            sb.Append(",\"ntime\":").Append(ParseL(Get("ntime", "0"), 0));
            sb.Append("}");

            Dictionary<string, DateTime> seen = new Dictionary<string, DateTime>(StringComparer.OrdinalIgnoreCase);
            Dictionary<string, string> ips = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (Session s in sess.Values)
            {
                DateTime d;
                if (!seen.TryGetValue(s.Acc.Login, out d) || s.Seen > d) { seen[s.Acc.Login] = s.Seen; ips[s.Acc.Login] = s.Ip; }
            }

            long total = 0;
            int online = 0;
            StringBuilder us = new StringBuilder();
            bool first = true;
            foreach (Account a in accs.Values)
            {
                long used = Used(a);
                total += used;
                DateTime sd;
                bool on = seen.TryGetValue(a.Login, out sd) && (DateTime.UtcNow - sd).TotalSeconds < 90;
                if (on) online++;
                string ipv;
                if (!ips.TryGetValue(a.Login, out ipv)) ipv = "";
                if (!first) us.Append(',');
                first = false;
                us.Append("{\"login\":").Append(Q(a.Login));
                us.Append(",\"id\":").Append(Q(a.Id));
                us.Append(",\"name\":").Append(Q(a.Name));
                us.Append(",\"folder\":").Append(Q(a.Folder));
                us.Append(",\"quota\":").Append(Dbl(a.Quota));
                us.Append(",\"used\":").Append(used);
                us.Append(",\"blocked\":").Append(a.Blocked);
                us.Append(",\"created\":").Append(a.Created);
                us.Append(",\"last\":").Append(a.Last);
                us.Append(",\"online\":").Append(on ? "1" : "0");
                us.Append(",\"admin\":").Append(IsAdmin(a) ? "1" : "0");
                us.Append(",\"ip\":").Append(Q(ipv)).Append("}");
            }
            sb.Append(",\"users\":[").Append(us.ToString()).Append("]");
            sb.Append(",\"total\":").Append(total).Append(",\"online\":").Append(online);

            sb.Append(",\"log\":[");
            for (int i = logs.Count - 1; i >= 0; i--)
            {
                string[] e = logs[i];
                if (i != logs.Count - 1) sb.Append(',');
                sb.Append("[").Append(e[0]).Append(",").Append(Q(e[1])).Append(",").Append(Q(ShowWho(e[2]))).Append(",").Append(Q(e[3])).Append(",").Append(Q(e[4])).Append("]");
            }
            sb.Append("]}");
        }
        Json(c, 200, sb.ToString());
    }

    // log entries store the account id (or a typed login for failed sign-ins); show the login for ids
    static string ShowWho(string w)
    {
        Account a;
        if (w.Length == 8 && byId.TryGetValue(w, out a)) return a.Login;
        return w;
    }

    // ------------------------------------------------------------ output
    static void Send(HttpListenerContext c, int code, string type, string text)
    {
        byte[] b = Encoding.UTF8.GetBytes(text);
        c.Response.StatusCode = code;
        c.Response.ContentType = type + "; charset=utf-8";
        c.Response.AddHeader("Cache-Control", "no-store");
        c.Response.ContentLength64 = b.Length;
        c.Response.OutputStream.Write(b, 0, b.Length);
        c.Response.Close();
    }

    static void SendBytes(HttpListenerContext c, int code, string type, byte[] b, string cache)
    {
        c.Response.StatusCode = code;
        c.Response.ContentType = type;
        c.Response.AddHeader("Cache-Control", cache);
        c.Response.ContentLength64 = b.Length;
        c.Response.OutputStream.Write(b, 0, b.Length);
        c.Response.Close();
    }

    static void Json(HttpListenerContext c, int code, string json) { Send(c, code, "application/json", json); }
}
'@

# =====================================================================
#  WEB PAGES (Russian UI)
# =====================================================================

$head = @'
<meta charset='utf-8'>
<meta name='viewport' content='width=device-width,initial-scale=1,viewport-fit=cover'>
<meta name='color-scheme' content='dark'>
<meta name='theme-color' content='#12151c'>
<link rel='manifest' href='/manifest.webmanifest'>
<link rel='apple-touch-icon' href='/apple-touch-icon.png'>
<meta name='apple-mobile-web-app-capable' content='yes'>
<meta name='mobile-web-app-capable' content='yes'>
<meta name='apple-mobile-web-app-title' content='Файлы'>
<meta name='apple-mobile-web-app-status-bar-style' content='black'>
<style>
:root{--bg:#12151c;--sf:#1a1f2a;--sf2:#232a38;--ln:#2c3444;--tx:#e8ebf2;--mu:#8b94a7;--ac:#7aa2ff;--rd:#ff6b6b;--gn:#4ade80;--am:#fbbf24}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html,body{margin:0;min-height:100%}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,'Helvetica Neue',Arial,sans-serif;color:var(--tx);background:var(--bg);-webkit-font-smoothing:antialiased}
button{font:inherit;color:inherit;cursor:pointer;border:0;background:none}
a{color:inherit}
@keyframes fade{from{opacity:0}to{opacity:1}}
@keyframes rise{from{opacity:0;transform:translateY(10px)}to{opacity:1;transform:none}}
@keyframes pop{from{opacity:0;transform:scale(.95)}to{opacity:1;transform:none}}
@keyframes shake{25%{transform:translateX(-6px)}75%{transform:translateX(6px)}}
.btn{display:inline-block;flex:none;padding:12px 18px;border-radius:12px;background:var(--sf2);color:var(--tx);font-size:15px;text-align:center;text-decoration:none;transition:background .2s,transform .1s,opacity .2s}
.btn:active{transform:scale(.97)}
.btn:disabled{opacity:.5;pointer-events:none}
.btn.pri{background:var(--ac);color:#0c1220;font-weight:600}
.btn.red{background:var(--rd);color:#1a0b0b;font-weight:600}
.in{width:100%;padding:12px 14px;border-radius:12px;border:1px solid var(--ln);background:var(--bg);color:var(--tx);font:inherit;font-size:16px;outline:0;transition:border-color .2s,box-shadow .2s}
.in:focus{border-color:var(--ac);box-shadow:0 0 0 4px rgba(122,162,255,.16)}
textarea.in{resize:vertical;min-height:90px}
.mut{color:var(--mu)}
.msg{border-radius:12px;padding:11px 14px;margin-bottom:12px;font-size:14px;line-height:1.4}
.msg.bad{background:rgba(255,107,107,.12);color:#ffa0a0;animation:shake .4s}
.msg.ok{background:rgba(74,222,128,.12);color:#86efac}
.sw{position:relative;display:inline-block;width:46px;height:28px;flex:none}
.sw input{opacity:0;width:0;height:0;position:absolute}
.sw i{position:absolute;top:0;left:0;right:0;bottom:0;border-radius:28px;background:var(--sf2);border:1px solid var(--ln);transition:background .2s;cursor:pointer}
.sw i:before{content:'';position:absolute;width:20px;height:20px;left:3px;top:3px;border-radius:50%;background:#aab3c5;transition:transform .2s,background .2s}
.sw input:checked+i{background:var(--ac)}
.sw input:checked+i:before{transform:translateX(18px);background:#0c1220}
.rng{width:100%;-webkit-appearance:none;appearance:none;height:6px;border-radius:6px;background:var(--sf2);outline:0;margin:14px 0}
.rng::-webkit-slider-thumb{-webkit-appearance:none;width:26px;height:26px;border-radius:50%;background:var(--ac);border:4px solid var(--bg);box-shadow:0 0 0 1px var(--ac);cursor:pointer}
.rng::-moz-range-thumb{width:20px;height:20px;border-radius:50%;background:var(--ac);border:4px solid var(--bg);cursor:pointer}
.dlg{position:fixed;top:0;left:0;right:0;bottom:0;z-index:60;display:grid;place-items:center;padding:20px;background:rgba(0,0,0,.55);opacity:0;visibility:hidden;transition:opacity .2s,visibility .2s}
.dlg.on{opacity:1;visibility:visible}
.dbox{width:100%;max-width:340px;max-height:92vh;overflow:auto;background:var(--sf);border:1px solid var(--ln);border-radius:18px;padding:20px;transform:scale(.94);transition:transform .2s}
.dbox.wide{max-width:440px}
.dlg.on .dbox{transform:none}
.dbox h3{margin:0 0 14px;font-size:18px}
.dbox p{margin:0 0 18px;word-break:break-all;line-height:1.45}
.drow{display:flex;gap:10px;margin-top:14px}
.drow .btn{flex:1}
.toast{position:fixed;left:50%;bottom:24px;transform:translate(-50%,16px);background:var(--sf2);border:1px solid var(--ln);padding:10px 18px;border-radius:999px;font-size:14px;opacity:0;pointer-events:none;transition:opacity .3s,transform .3s;z-index:70;max-width:90%;text-align:center}
.toast.on{opacity:1;transform:translate(-50%,0)}
@media (prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}}
</style>
'@

$snd = @'
function $(id){return document.getElementById(id);}
function h(tag,cls,txt){var e=document.createElement(tag);if(cls)e.className=cls;if(txt!=null)e.textContent=txt;return e;}
function enc(d){var a=[];for(var k in d){a.push(encodeURIComponent(k)+'='+encodeURIComponent(d[k]));}return a.join('&');}
function api(url,data){
 var o={method:data?'POST':'GET',credentials:'same-origin',headers:{'X-Req':'1'}};
 if(data){o.headers['Content-Type']='application/x-www-form-urlencoded;charset=UTF-8';o.body=enc(data);}
 return fetch(url,o).then(function(r){
  if(r.status===401){location.href='/';throw 0;}
  if(r.status===503){if(window.toast)toast('Сервер выключен. Попробуйте позже');throw 0;}
  return r.json();
 });
}
function sz(n){
 if(n<1024)return n+' Б';
 if(n<1048576)return (n/1024).toFixed(1)+' КБ';
 if(n<1073741824)return (n/1048576).toFixed(1)+' МБ';
 if(n<1099511627776)return (n/1073741824).toFixed(2)+' ГБ';
 return (n/1099511627776).toFixed(2)+' ТБ';
}
function fillRng(r){var p=(r.value-r.min)/(r.max-r.min)*100;r.style.background='linear-gradient(to right,var(--ac) '+p+'%,var(--sf2) '+p+'%)';}
var Snd=(function(){
 var ctx=null,on=true,last=0;
 try{on=localStorage.getItem('snd')!=='0';}catch(e){}
 function ac(){
  if(!ctx){
   var C=window.AudioContext||window.webkitAudioContext;
   if(!C)return null;
   try{ctx=new C();}catch(e){return null;}
  }
  if(ctx.state==='suspended'){try{ctx.resume();}catch(e){}}
  return ctx;
 }
 function tone(f,t0,d,v,ty){
  var c=ac();if(!c)return;
  var o=c.createOscillator(),g=c.createGain(),t=c.currentTime+t0;
  o.type=ty||'sine';o.frequency.setValueAtTime(f,t);
  g.gain.setValueAtTime(0.0001,t);
  g.gain.exponentialRampToValueAtTime(v,t+0.012);
  g.gain.exponentialRampToValueAtTime(0.0001,t+d);
  o.connect(g);g.connect(c.destination);o.start(t);o.stop(t+d+0.05);
 }
 function p(fn){return function(){if(!on)return;try{fn();}catch(e){}};}
 return {
  isOn:function(){return on;},
  setOn:function(v){on=v;try{localStorage.setItem('snd',v?'1':'0');}catch(e){}},
  unlock:function(){ac();},
  click:p(function(){var n=Date.now();if(n-last<40)return;last=n;tone(1200,0,0.05,0.03,'triangle');}),
  open:p(function(){tone(520,0,0.12,0.045);tone(780,0.06,0.16,0.035);}),
  ok:p(function(){tone(660,0,0.14,0.055);tone(880,0.09,0.2,0.045);}),
  err:p(function(){tone(300,0,0.16,0.055,'triangle');tone(240,0.1,0.22,0.045,'triangle');}),
  del:p(function(){tone(520,0,0.1,0.045);tone(390,0.07,0.16,0.04);}),
  msg:p(function(){tone(880,0,0.18,0.05);tone(1174.7,0.12,0.3,0.04);}),
  send:p(function(){tone(700,0,0.07,0.035);tone(950,0.05,0.09,0.03);}),
  chime:p(function(){tone(523.25,0,1.6,0.07);tone(659.25,0.2,1.6,0.06);tone(783.99,0.4,2.0,0.055);tone(1046.5,0.4,1.4,0.02);})
 };
})();
document.addEventListener('pointerdown',function(e){
 Snd.unlock();
 var t=e.target;
 if(t&&t.closest&&t.closest('button,a,label,.th,.meta,.urow,.tabs button'))Snd.click();
},true);
'@

$sw = @'
self.addEventListener('install',function(e){self.skipWaiting();});
self.addEventListener('activate',function(e){e.waitUntil(self.clients.claim());});
self.addEventListener('push',function(e){
 e.waitUntil(
  fetch('/api/push/pending',{credentials:'include',cache:'no-store'})
  .then(function(r){return r.ok?r.json():[];})
  .catch(function(){return [];})
  .then(function(items){
   if(!items||!items.length){
    return self.registration.showNotification('Мои файлы',{body:'Есть новые уведомления',tag:'generic',data:{url:'/'},icon:'/icon-192.png'});
   }
   var p=[];
   items.forEach(function(it){
    p.push(self.registration.showNotification(it.t,{body:it.b,tag:it.g||('n'+it.i),renotify:true,data:{url:it.u||'/'},icon:'/icon-192.png'}));
   });
   try{if(self.navigator&&self.navigator.setAppBadge)p.push(self.navigator.setAppBadge(items[0].n||1));}catch(x){}
   return Promise.all(p);
  })
 );
});
self.addEventListener('notificationclick',function(e){
 e.notification.close();
 var url=(e.notification.data&&e.notification.data.url)||'/';
 e.waitUntil(
  self.clients.matchAll({type:'window',includeUncontrolled:true}).then(function(list){
   for(var i=0;i<list.length;i++){
    var c=list[i];
    if('focus' in c){c.postMessage({go:url});return c.focus();}
   }
   return self.clients.openWindow(url);
  })
 );
});
'@

$pAuth = @'
<!DOCTYPE html><html lang='ru'><head><title>Вход</title>@@HEAD@@
<style>
body{min-height:100vh;display:grid;place-items:center;padding:20px}
.login{width:100%;max-width:380px;padding:28px 24px 24px;background:var(--sf);border:1px solid var(--ln);border-radius:22px;box-shadow:0 24px 60px rgba(0,0,0,.45);animation:pop .45s both}
.mark{width:56px;height:56px;border-radius:16px;display:grid;place-items:center;background:var(--ac);color:#0c1220;margin-bottom:16px}
h1{margin:0 0 4px;font-size:24px;font-weight:650;letter-spacing:-.01em}
.hint{margin:0 0 18px;color:var(--mu);font-size:15px}
.seg{display:flex;background:var(--bg);border:1px solid var(--ln);border-radius:12px;padding:4px;margin-bottom:16px}
.seg button{flex:1;padding:9px;border-radius:9px;color:var(--mu);transition:background .2s,color .2s}
.seg button.on{background:var(--sf2);color:var(--tx)}
.fld{position:relative;display:block;margin-bottom:12px}
.eye{position:absolute;right:6px;top:50%;transform:translateY(-50%);color:var(--mu);font-size:14px;padding:10px}
.note{font-size:13px;line-height:1.45;color:var(--mu);margin:0 0 14px;padding:10px 12px;border-radius:10px;background:rgba(251,191,36,.08);border:1px solid rgba(251,191,36,.25)}
.go{width:100%;margin-top:4px}
form{animation:fade .3s both}
</style></head><body>
<div class='login'>
<div class='mark'><svg viewBox='0 0 24 24' width='28' height='28' fill='none' stroke='currentColor' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><path d='M3 7a2 2 0 012-2h4l2 2h8a2 2 0 012 2v9a2 2 0 01-2 2H5a2 2 0 01-2-2z'/></svg></div>
<h1 id='h'>Мои файлы</h1>
<p class='hint'>Личное файловое хранилище</p>
<div class='seg'><button id='tl' class='on'>Вход</button><button id='tr'>Регистрация</button></div>
<div id='msg' class='msg' style='display:none'></div>

<form id='fl'>
<label class='fld'><input class='in' id='lu' type='text' placeholder='Логин' autocomplete='username' autocapitalize='none' autocorrect='off' required></label>
<label class='fld'><input class='in' id='lp' type='password' placeholder='Пароль' autocomplete='current-password' required><button type='button' class='eye' data-e='lp'>Показать</button></label>
<button class='btn pri go' id='bl' type='submit'>Войти</button>
</form>

<form id='fr' style='display:none'>
<label class='fld'><input class='in' id='rn' type='text' maxlength='30' placeholder='Имя для других (необязательно)' autocomplete='nickname'></label>
<label class='fld'><input class='in' id='ru' type='text' placeholder='Придумайте логин' autocomplete='username' autocapitalize='none' autocorrect='off' required></label>
<label class='fld'><input class='in' id='rp' type='password' placeholder='Пароль' autocomplete='new-password' required><button type='button' class='eye' data-e='rp'>Показать</button></label>
<label class='fld'><input class='in' id='rp2' type='password' placeholder='Повторите пароль' autocomplete='new-password' required></label>
<p class='note'>Другие пользователи видят только ваше имя и ID, но не логин. Администратор хранит логин и пароль в названии вашей папки, чтобы помочь восстановить доступ. Не используйте пароль от почты, соцсетей и банков.</p>
<button class='btn pri go' id='br' type='submit'>Создать аккаунт</button>
</form>
</div>
<script>
@@SND@@
var E={
 bad:'Неверный логин или пароль',
 blocked:'Аккаунт заблокирован администратором',
 pending:'Аккаунт ещё не подтверждён администратором',
 locked:'Слишком много попыток. Попробуйте позже',
 maint:'Идут технические работы. Вход доступен только администратору',
 closed:'Регистрация сейчас закрыта',
 exists:'Такой логин уже занят',
 badlogin:'Логин: от 3 до 20 символов, только латинские буквы, цифры, точка, дефис и подчёркивание',
 badpass:'Пароль: от 4 до 32 символов, без символов \\ / : * ? " < > |, без пробела или точки в конце',
 reserved:'Этот логин зарезервирован',
 full:'Достигнут лимит пользователей',
 folder:'Не удалось создать папку на сервере'
};
var regOpen=true;
function say(t,ok){var m=$('msg');m.textContent=t;m.className='msg '+(ok?'ok':'bad');m.style.display='block';}
function hide(){$('msg').style.display='none';}
function tab(r){
 $('tl').classList.toggle('on',!r);$('tr').classList.toggle('on',r);
 $('fl').style.display=r?'none':'block';$('fr').style.display=r?'block':'none';
 hide();
 if(r&&!regOpen)say(E.closed,false);
}
$('tl').onclick=function(){tab(false);};
$('tr').onclick=function(){tab(true);};
Array.prototype.forEach.call(document.querySelectorAll('.eye'),function(b){
 b.onclick=function(){
  var i=$(b.getAttribute('data-e'));var s=i.type==='password';
  i.type=s?'text':'password';b.textContent=s?'Скрыть':'Показать';
 };
});
$('fl').onsubmit=function(e){
 e.preventDefault();hide();
 var b=$('bl');b.disabled=true;
 api('/api/login',{u:$('lu').value.trim(),p:$('lp').value}).then(function(j){
  if(j.ok){Snd.ok();location.href='/';}
  else{Snd.err();say(E[j.err]||'Ошибка входа',false);b.disabled=false;}
 }).catch(function(){say('Нет связи с сервером',false);b.disabled=false;});
};
$('fr').onsubmit=function(e){
 e.preventDefault();hide();
 if($('rp').value!==$('rp2').value){Snd.err();say('Пароли не совпадают',false);return;}
 var b=$('br');b.disabled=true;
 api('/api/register',{u:$('ru').value.trim(),p:$('rp').value,n:$('rn').value}).then(function(j){
  if(j.ok&&j.pending){Snd.ok();say('Аккаунт создан. Дождитесь подтверждения администратора.',true);b.disabled=false;}
  else if(j.ok){Snd.ok();location.href='/';}
  else{Snd.err();say(E[j.err]||'Ошибка регистрации',false);b.disabled=false;}
 }).catch(function(){say('Нет связи с сервером',false);b.disabled=false;});
};
api('/api/info').then(function(j){
 if(j.title){$('h').textContent=j.title;document.title=j.title;}
 regOpen=!!j.reg;
 if(j.maint)say(E.maint,false);
}).catch(function(){});
</script>
</body></html>
'@

$pMain = @'
<!DOCTYPE html><html lang='ru'><head><title>Мои файлы</title>@@HEAD@@
<style>
.bar{position:sticky;top:0;z-index:20;background:rgba(18,21,28,.88);backdrop-filter:blur(14px);-webkit-backdrop-filter:blur(14px);border-bottom:1px solid var(--ln)}
.bar-in{max-width:1000px;margin:0 auto;padding:10px 16px;display:flex;align-items:center;justify-content:space-between;gap:12px}
.brand{display:flex;align-items:center;gap:12px;min-width:0}
.mark{width:38px;height:38px;border-radius:12px;display:grid;place-items:center;background:var(--ac);color:#0c1220;flex:none}
.brand b{display:block;font-size:17px;font-weight:650;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.brand small{color:var(--mu);font-size:13px}
.hact{display:flex;align-items:center;gap:8px;flex:none}
.wrap{max-width:1000px;margin:0 auto;padding:16px 16px 96px}
.view{display:none}
.view.on{display:block;animation:fade .25s both}
.nav{position:fixed;left:0;right:0;bottom:0;z-index:30;display:flex;background:rgba(18,21,28,.94);backdrop-filter:blur(14px);-webkit-backdrop-filter:blur(14px);border-top:1px solid var(--ln);padding-bottom:env(safe-area-inset-bottom)}
.nav button{flex:1;display:flex;flex-direction:column;align-items:center;gap:3px;padding:9px 0 8px;color:var(--mu);font-size:12px;position:relative;transition:color .2s}
.nav button.on{color:var(--ac)}
.nb{position:absolute;top:3px;left:calc(50% + 6px);min-width:18px;height:18px;border-radius:9px;background:var(--rd);color:#fff;font-size:11px;font-weight:600;display:none;place-items:center;padding:0 5px}
.nb.on{display:grid;animation:pop .25s both}
.meter{background:var(--sf);border:1px solid var(--ln);border-radius:14px;padding:12px 14px;margin-bottom:12px}
.mt{display:flex;justify-content:space-between;gap:10px;font-size:14px;margin-bottom:8px}
.mb{height:6px;border-radius:6px;background:var(--sf2);overflow:hidden}
.mb i{display:block;height:100%;width:0;background:var(--ac);border-radius:6px;transition:width .5s}
.mb i.hi{background:var(--rd)}
.crumbs{display:flex;flex-wrap:wrap;align-items:center;gap:4px;margin-bottom:12px;font-size:15px}
.cr{padding:6px 10px;border-radius:999px;color:var(--mu);transition:background .2s,color .2s}
.cr:hover{background:var(--sf)}
.cr.on{color:var(--tx);font-weight:600}
.sep{color:var(--mu)}
.acts{display:flex;flex-wrap:wrap;gap:8px;margin-bottom:6px}
.acts .btn{padding:10px 14px;font-size:14px}
.tools{display:flex;flex-wrap:wrap;gap:10px;align-items:center;justify-content:space-between;margin:16px 0 14px}
.tabs{display:flex;gap:6px;overflow-x:auto;max-width:100%;scrollbar-width:none}
.tabs::-webkit-scrollbar{display:none}
.tabs button{padding:8px 15px;border-radius:999px;background:var(--sf);color:var(--mu);font-size:14px;white-space:nowrap;border:1px solid var(--ln);transition:background .2s,color .2s,border-color .2s}
.tabs button.on{background:var(--ac);color:#0c1220;border-color:var(--ac);font-weight:600}
#q{flex:1;min-width:150px;max-width:280px;width:auto;border-radius:999px;padding:9px 16px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:12px}
.card{background:var(--sf);border:1px solid var(--ln);border-radius:14px;overflow:hidden;transition:transform .2s,opacity .28s,border-color .2s}
.card.in{animation:rise .4s both}
.card:hover{transform:translateY(-2px);border-color:#3a4458}
.th{position:relative;width:100%;padding-top:100%;background:#151a24;cursor:pointer;overflow:hidden}
.th>img,.th>video,.th>.ico{position:absolute;top:0;left:0;width:100%;height:100%;object-fit:cover;transition:transform .35s}
.card:hover .th>img,.card:hover .th>video{transform:scale(1.04)}
.ico{display:flex;flex-direction:column;align-items:center;justify-content:center;gap:8px;color:#9db6f5}
.card.dir .ico{color:var(--ac)}
.ico.k-pdf{color:#f2a0a0}.ico.k-text{color:#9ee0b4}.ico.k-audio{color:#cfb0f5}
.ico i{font-style:normal;font-size:13px;color:var(--mu)}
.pl{position:absolute;left:8px;bottom:8px;width:28px;height:28px;border-radius:50%;display:grid;place-items:center;background:rgba(0,0,0,.6);color:#fff;pointer-events:none}
.ac{position:absolute;top:8px;right:8px;z-index:2}
.meta{padding:10px 12px 11px;cursor:pointer}
.nm{font-size:14px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.sub{color:var(--mu);font-size:12.5px;margin-top:2px}
.ib{width:38px;height:38px;border-radius:50%;display:grid;place-items:center;background:rgba(18,21,28,.72);color:var(--tx);transition:background .2s,color .2s,transform .1s;text-decoration:none;flex:none}
.ib:hover{background:var(--sf2)}
.ib:active{transform:scale(.92)}
.ib.sm{width:32px;height:32px}
.ib.off{opacity:.3;pointer-events:none}
.hact .ib{background:var(--sf);border:1px solid var(--ln)}
.empty{display:none;text-align:center;color:var(--mu);padding:56px 0}
.empty.on{display:block;animation:fade .4s}
.sechead{display:flex;align-items:center;justify-content:space-between;margin-bottom:14px}
.sechead h2{margin:0;font-size:22px}
.btn.sm{padding:9px 14px;font-size:14px}
.crow{display:flex;gap:12px;align-items:center;padding:12px;background:var(--sf);border:1px solid var(--ln);border-radius:14px;margin-bottom:8px;cursor:pointer;transition:background .2s,transform .1s;animation:rise .3s both}
.crow:active{transform:scale(.99)}
.crow:hover{background:var(--sf2)}
.av{width:46px;height:46px;border-radius:50%;background:var(--sf2);display:grid;place-items:center;font-weight:650;font-size:18px;flex:none}
.cinf{flex:1;min-width:0}
.cnm{font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.cpv{color:var(--mu);font-size:14px;margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.cmeta{display:flex;flex-direction:column;align-items:flex-end;gap:6px;flex:none;font-size:12px;color:var(--mu)}
.cu{min-width:20px;height:20px;border-radius:10px;background:var(--ac);color:#0c1220;font-weight:700;display:grid;place-items:center;padding:0 6px;font-size:12px}
.cv{position:fixed;left:0;right:0;top:0;height:100%;z-index:40;background:var(--bg);display:flex;flex-direction:column;transform:translateX(100%);visibility:hidden;transition:transform .3s cubic-bezier(.2,.8,.2,1),visibility .3s}
.cv.on{transform:none;visibility:visible}
.cvh{display:flex;align-items:center;gap:10px;padding:10px 12px;border-bottom:1px solid var(--ln);background:var(--sf)}
.cvh .ib{background:var(--sf2)}
.cvt{min-width:0;flex:1}
.cvt b{display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.cvt small{color:var(--mu);font-size:12.5px}
.cvm{flex:1;overflow-y:auto;padding:14px 12px;display:flex;flex-direction:column;gap:6px;-webkit-overflow-scrolling:touch}
.cve{margin:auto;color:var(--mu);text-align:center;font-size:14px}
.bb{max-width:84%;padding:9px 12px 6px;border-radius:16px;font-size:15px;line-height:1.4;animation:pop .2s both;word-break:break-word}
.bb.me{align-self:flex-end;background:var(--ac);color:#0c1220;border-bottom-right-radius:5px}
.bb.th{align-self:flex-start;background:var(--sf2);border-bottom-left-radius:5px}
.bb .tx{white-space:pre-wrap}
.bb .tm{font-size:11px;opacity:.65;text-align:right;margin-top:3px}
.att{display:flex;gap:10px;align-items:center}
.ai{width:40px;height:40px;border-radius:10px;background:rgba(0,0,0,.18);display:grid;place-items:center;flex:none}
.an{font-weight:600;word-break:break-all}
.as{font-size:12.5px;opacity:.75}
.ab{display:flex;flex-wrap:wrap;gap:6px;margin-top:8px}
.ab button{padding:6px 11px;border-radius:999px;background:rgba(0,0,0,.2);font-size:13px;color:inherit}
.bb.th .ab button{background:var(--sf)}
.ab .gone{font-size:13px;opacity:.7}
.cmp{display:flex;gap:8px;align-items:flex-end;padding:10px 12px calc(10px + env(safe-area-inset-bottom));border-top:1px solid var(--ln);background:var(--sf)}
.cmp textarea{flex:1;min-height:42px;max-height:120px;resize:none;border-radius:20px;padding:10px 14px;line-height:1.35}
.cmp .ib{background:var(--sf2);width:42px;height:42px}
.cmp .ib.go{background:var(--ac);color:#0c1220}
.panel{background:var(--sf);border:1px solid var(--ln);border-radius:16px;padding:16px;margin-bottom:14px}
.panel h3{margin:0 0 6px;font-size:16px}
.panel p{margin:0 0 12px;font-size:14px;line-height:1.45}
.pid{display:flex;gap:14px;align-items:center}
.pid .av{width:64px;height:64px;font-size:26px}
.pn{font-size:19px;font-weight:650}
.idv{display:flex;align-items:center;gap:10px;margin-top:4px}
.idv code{font-size:20px;letter-spacing:.06em;color:var(--ac)}
.row2{display:flex;gap:10px;flex-wrap:wrap}
.row2 .in{flex:1;min-width:140px}
.line{display:flex;align-items:center;justify-content:space-between;gap:14px}
.shi{display:block;width:100%;text-align:left;padding:13px 12px;border-radius:10px;font-size:16px;transition:background .15s}
.shi:hover{background:var(--sf2)}
.shi.red{color:var(--rd)}
.pkl{max-height:48vh;overflow:auto;margin:10px 0}
.prow{display:flex;align-items:center;gap:10px;padding:11px 10px;border-radius:10px;cursor:pointer;transition:background .15s}
.prow:hover{background:var(--sf2)}
.prow .pn2{flex:1;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.prow .pr{color:var(--mu);font-size:12.5px;flex:none}
.prow svg{color:var(--ac);flex:none}
#upq{position:fixed;left:12px;right:12px;bottom:calc(70px + env(safe-area-inset-bottom));max-width:520px;margin:0 auto;z-index:55}
.up{margin-top:8px;padding:11px 14px;background:var(--sf2);border:1px solid var(--ln);border-radius:12px;font-size:14px;animation:rise .3s both;transition:opacity .35s,transform .35s;box-shadow:0 8px 24px rgba(0,0,0,.35)}
.up.gone{opacity:0;transform:translateY(8px)}
.ut{display:flex;justify-content:space-between;gap:10px}
.un{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0}
.pc{color:var(--mu);font-size:13px;text-align:right;flex:none;max-width:60%}
.pb{margin-top:8px;height:5px;border-radius:6px;background:var(--bg);overflow:hidden}
.pb i{display:block;height:100%;width:0;background:var(--ac);border-radius:6px;transition:width .2s}
.up.ok .pc{color:var(--gn)}.up.ok .pb i{background:var(--gn)}
.up.bad .pc{color:var(--rd)}.up.bad .pb i{background:var(--rd)}
.ntc{position:fixed;top:12px;left:12px;right:12px;max-width:520px;margin:0 auto;z-index:95;display:flex;gap:12px;align-items:flex-start;background:var(--sf2);border:1px solid var(--ac);border-radius:16px;padding:14px;box-shadow:0 12px 40px rgba(0,0,0,.5);transform:translateY(-150%);opacity:0;transition:transform .5s cubic-bezier(.2,.9,.3,1),opacity .35s}
.ntc.on{transform:none;opacity:1}
.ni{color:var(--ac);flex:none;margin-top:2px}
.nx{min-width:0;flex:1}
.nx b{font-size:15px}
.nx p{margin:4px 0 12px;line-height:1.45;word-break:break-word;white-space:pre-wrap}
.nx .btn{padding:9px 18px}
.vw{position:fixed;top:0;left:0;right:0;bottom:0;z-index:90;background:rgba(8,10,15,.97);opacity:0;visibility:hidden;transition:opacity .25s,visibility .25s}
.vw.on{opacity:1;visibility:visible}
.vtop{position:absolute;top:0;left:0;right:0;height:60px;display:flex;align-items:center;justify-content:space-between;gap:10px;padding:0 12px 0 16px;z-index:3}
.vt{min-width:0}
.vt div{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-size:15px;font-weight:600}
.vt small{color:var(--mu);font-size:13px}
.vact{display:flex;gap:8px;flex:none}
.vact .ib{background:var(--sf2)}
.vact .ib:hover{background:#2f394c}
.vbody{position:absolute;top:60px;left:0;right:0;bottom:0}
.vc{width:100%;height:100%;display:flex;flex-direction:column;align-items:center;justify-content:center;padding:6px 12px 14px;animation:pop .28s both}
.vc img{max-width:100%;max-height:100%;object-fit:contain;border-radius:10px;cursor:zoom-in}
.vc.zm{display:block;overflow:auto;-webkit-overflow-scrolling:touch}
.vc.zm img{max-width:none;max-height:none;width:220%;height:auto;display:block;cursor:zoom-out}
.vc video{max-width:100%;max-height:100%;border-radius:12px;background:#000}
.vc audio{width:min(440px,100%)}
.vc iframe{width:100%;flex:1;min-height:0;border:0;border-radius:10px;background:#fff}
.vc pre{width:100%;flex:1;min-height:0;overflow:auto;margin:0;padding:14px;background:var(--sf);border:1px solid var(--ln);border-radius:12px;font:13px/1.55 ui-monospace,Menlo,Consolas,monospace;white-space:pre-wrap;word-break:break-word;text-align:left}
.big{display:flex;flex-direction:column;align-items:center;gap:10px;color:#9db6f5;margin-bottom:18px}
.big i{font-style:normal;color:var(--mu);font-size:15px}
.fb{text-align:center;margin-top:14px}
.toast{bottom:calc(78px + env(safe-area-inset-bottom));z-index:100;pointer-events:auto;cursor:pointer}
.dlg{z-index:70}
body.lock{overflow:hidden}
</style></head><body>
<header class='bar'><div class='bar-in'>
<div class='brand'><div class='mark' data-i='folder' data-s='22'></div><div style='min-width:0'><b id='ttl'>Мои файлы</b><small id='who'></small></div></div>
<div class='hact'>
<button class='ib' id='snd' title='Звуки интерфейса'></button>
<a class='ib' id='adm' href='/admin' title='Админ-панель' style='display:none' data-i='sliders' data-s='20'></a>
</div>
</div></header>

<div class='ntc' id='ntc'>
<div class='ni' data-i='bell' data-s='22'></div>
<div class='nx'><b>Сообщение от администратора</b><p id='ntx'></p><button class='btn pri' id='nok'>Понятно</button></div>
</div>

<main class='wrap'>

<section class='view on' id='v-files'>
<div class='meter'><div class='mt'><span id='mtx'>Загрузка...</span><span id='mpc'></span></div><div class='mb'><i id='mbar'></i></div></div>
<div class='crumbs' id='crumbs'></div>
<div class='acts'>
<label class='btn pri' for='f'>Загрузить сюда</label>
<input type='file' id='f' multiple hidden>
<button class='btn' id='newdir'>Новая папка</button>
<button class='btn' id='zipcur'>Скачать всё (ZIP)</button>
</div>
<div class='tools'>
<div class='tabs' id='tabs'>
<button class='on' data-k='all'>Все</button>
<button data-k='image'>Фото</button>
<button data-k='video'>Видео</button>
<button data-k='audio'>Аудио</button>
<button data-k='doc'>Документы</button>
</div>
<input class='in' id='q' type='search' placeholder='Поиск по имени'>
</div>
<div class='grid' id='grid'></div>
<div class='empty' id='empty'>Здесь пока пусто. Загрузите файл или создайте папку.</div>
</section>

<section class='view' id='v-chat'>
<div class='sechead'><h2>Чаты</h2><button class='btn pri sm' id='newchat'>Новый чат</button></div>
<div id='cl'></div>
<div class='empty' id='cempty'>Чатов пока нет. Нажмите «Новый чат» и введите ID друга. Свой ID можно посмотреть в разделе «Профиль».</div>
</section>

<section class='view' id='v-prof'>
<div class='panel pid'>
<div class='av' id='pav'></div>
<div><div class='pn' id='pname'></div><div class='mut' style='font-size:13px;margin-top:2px'>Ваш ID для чатов</div>
<div class='idv'><code id='pid'></code><button class='btn sm' id='pidcopy'>Копировать</button></div></div>
</div>
<div class='panel'><h3>Имя</h3><p class='mut'>Это имя видят другие пользователи. Ваш логин нигде не показывается.</p>
<div class='row2'><input class='in' id='pn' maxlength='30' placeholder='Как вас называть'><button class='btn pri' id='pnsave'>Сохранить</button></div></div>
<div class='panel'><h3>Вход в аккаунт</h3>
<p class='mut'>Логин: <b id='plogin' style='color:var(--tx)'></b></p>
<p class='mut' id='padm' style='display:none'>Логин и пароль администратора меняются в начале файла server.bat.</p>
<div class='row2' id='pcred'><button class='btn' id='chlogin'>Сменить логин</button><button class='btn' id='chpass'>Сменить пароль</button></div></div>
<div class='panel'><h3>Уведомления</h3><p class='mut' id='pushinfo'></p><button class='btn pri' id='pushbtn' style='display:none'>Включить уведомления</button></div>
<div class='panel'><div class='line'><div><h3 style='margin:0'>Звуки интерфейса</h3><p class='mut' style='margin:4px 0 0'>Тихие звуки нажатий и сообщений</p></div><label class='sw'><input type='checkbox' id='psnd'><i></i></label></div></div>
<div class='panel'><div class='row2'><button class='btn' id='outall'>Выйти на всех устройствах</button><a class='btn' href='/logout'>Выйти</a></div></div>
</section>

</main>

<nav class='nav' id='nav'>
<button class='on' data-v='files'><span data-i='folder' data-s='22'></span>Файлы</button>
<button data-v='chat'><span data-i='chat' data-s='22'></span>Чаты<span class='nb' id='nbadge'></span></button>
<button data-v='prof'><span data-i='user' data-s='22'></span>Профиль</button>
</nav>

<div class='cv' id='cv'>
<div class='cvh'>
<button class='ib' id='cvback' data-i='l' data-s='20' title='Назад'></button>
<div class='av' id='cvav' style='width:38px;height:38px;font-size:16px'></div>
<div class='cvt'><b id='cvn'></b><small id='cvi'></small></div>
</div>
<div class='cvm' id='cvm'></div>
<div class='cmp'>
<button class='ib' id='cvatt' data-i='clip' data-s='20' title='Прикрепить'></button>
<textarea class='in' id='ct' rows='1' placeholder='Сообщение'></textarea>
<button class='ib go' id='cvsend' data-i='send' data-s='20' title='Отправить'></button>
</div>
<input type='file' id='cf' multiple hidden>
</div>

<div class='vw' id='vw'>
<div class='vtop'>
<div class='vt'><div id='vname'></div><small id='vcount'></small></div>
<div class='vact'>
<button class='ib' id='vprev' data-i='l' data-s='20' title='Назад'></button>
<button class='ib' id='vnext' data-i='r' data-s='20' title='Вперёд'></button>
<a class='ib' id='vdl' data-i='dl' data-s='20' title='Скачать'></a>
<button class='ib' id='vx' data-i='x' data-s='20' title='Закрыть'></button>
</div>
</div>
<div class='vbody' id='vbody'></div>
</div>

<div id='upq'></div>
<div class='toast' id='toast'></div>
<script>
@@SND@@
function q(s){return encodeURIComponent(s);}
function jn(a,b){return a?(b?a+'/'+b:a):b;}
var me={id:'',name:'',dn:'',login:'',admin:0,used:0,quota:0,chat:1,dc:'',dr:'',u:0};
var cp='',dirs=[],files=[],view=[],filt='all',qs='';
var vl=[],cur=-1,seq=0,isOpen=false,hs=true,ct=null,tt=null;
var seenN='',curN='',lastNote=-1,unread=0,curView='files';
var peer=null,convOpen=false,lastMid=0,cvTimer=null,convs=[];
var pending=[],busy=false;
try{seenN=localStorage.getItem('nseen')||'';}catch(e){}
var P={
 dl:'M12 4v11m0 0l-4-4m4 4l4-4M5 20h14',
 x:'M6 6l12 12M18 6L6 18',
 l:'M15 5l-7 7 7 7',
 r:'M9 5l7 7-7 7',
 up:'M12 16V4m0 0L8 8m4-4l4 4M4 15v4a1 1 0 001 1h14a1 1 0 001-1v-4',
 file:'M7 3h7l5 5v12a1 1 0 01-1 1H7a1 1 0 01-1-1V4a1 1 0 011-1zM14 3v5h5',
 play:'M8 5v14l11-7z',
 music:'M9 18V6l10-2v12M9 18a3 3 0 11-6 0 3 3 0 016 0zM19 16a3 3 0 11-6 0 3 3 0 016 0z',
 folder:'M3 7a2 2 0 012-2h4l2 2h8a2 2 0 012 2v9a2 2 0 01-2 2H5a2 2 0 01-2-2z',
 vol:'M11 5L6 9H2v6h4l5 4V5zM15.5 8.5a5 5 0 010 7M18.5 5.5a9 9 0 010 13',
 mute:'M11 5L6 9H2v6h4l5 4V5zM22 9l-6 6M16 9l6 6',
 sliders:'M4 7h9M17 7h3M4 17h3M11 17h9M15 4v6M9 14v6',
 bell:'M6 9a6 6 0 1112 0c0 5 2 6 2 6H4s2-1 2-6zM10 19a2 2 0 004 0',
 more:'M5 12h.01M12 12h.01M19 12h.01',
 chat:'M21 12a8 8 0 01-11.6 7.1L4 20l1-4.4A8 8 0 1121 12z',
 user:'M12 12a4 4 0 100-8 4 4 0 000 8zM4 21a8 8 0 0116 0',
 send:'M22 2L11 13M22 2l-7 20-4-9-9-4 20-7z',
 clip:'M21 12.5l-8.5 8.5a5.5 5.5 0 01-7.8-7.8l9-9a3.7 3.7 0 015.2 5.2l-9 9a1.8 1.8 0 01-2.6-2.6l8.4-8.4'
};
function ic(n,s){s=s||20;return `<svg viewBox='0 0 24 24' width='${s}' height='${s}' fill='none' stroke='currentColor' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><path d='${P[n]}'/></svg>`;}
function dt(t){return new Date(t).toLocaleDateString('ru-RU',{day:'numeric',month:'short',year:'numeric'});}
function tmf(t){var d=new Date(t),n=new Date();if(d.toDateString()===n.toDateString())return d.toLocaleTimeString('ru-RU',{hour:'2-digit',minute:'2-digit'});return d.toLocaleDateString('ru-RU',{day:'numeric',month:'short'});}
function toast(t,fn){var e=$('toast');e.textContent=t;e.onclick=fn||null;e.classList.add('on');clearTimeout(tt);tt=setTimeout(function(){e.classList.remove('on');},3200);}
function dlGo(u){var a=document.createElement('a');a.href=u;a.setAttribute('download','');document.body.appendChild(a);a.click();document.body.removeChild(a);}
// ask the server for a one-time link that ends with the real file name, then download it
function zipGo(u){
 var row=h('div','up'),top=h('div','ut');
 var un=h('div','un','Готовлю архив...'),pc=h('div','pc','0%');
 top.appendChild(un);top.appendChild(pc);
 var pb=h('div','pb'),bi=document.createElement('i');pb.appendChild(bi);
 row.appendChild(top);row.appendChild(pb);$('upq').appendChild(row);
 function end(ms){setTimeout(function(){row.classList.add('gone');setTimeout(function(){if(row.parentNode)row.parentNode.removeChild(row);},380);},ms);}
 function bad(t){row.classList.add('bad');pc.textContent=t;Snd.err();end(5000);}
 api('/api/zip/start',{u:u}).then(function(j){
  if(!j.job){bad(FE[j.err]||'Папка не найдена');return;}
  function poll(){
   api('/api/zip/status?job='+j.job).then(function(s){
    if(s.st===1){bi.style.width='100%';row.classList.add('ok');pc.textContent='Готово';un.textContent='Архив готов';Snd.ok();dlGo(s.url);end(2500);}
    else if(s.st===2){bad('Не удалось собрать архив');}
    else{var p=s.total>0?Math.min(99,Math.round(s.done*100/s.total)):0;bi.style.width=p+'%';pc.textContent=p+'%';setTimeout(poll,1000);}
   }).catch(function(){bad('Нет связи');});
  }
  poll();
 }).catch(function(){bad('Нет связи');});
}
function dlUrl(u){
 if(u.indexOf('/zip')===0||u.indexOf('&z=1')>=0){zipGo(u);return;}
 api('/api/link',{u:u}).then(function(j){
  if(j.url)dlGo(j.url);else toast('Файл не найден или уже удалён');
 }).catch(function(){dlGo(u);});
}
var FE={exists:'Такое имя уже есть',bad:'Недопустимое имя',inside:'Нельзя переместить папку внутрь самой себя',busy:'Не получилось: файл сейчас занят',nodir:'Не найдено',gone:'Файл уже удалён отправителем',quota:'Не хватает места в вашем хранилище',disk:'На сервере закончилось место',nouser:'Пользователь с таким ID не найден',locked:'Слишком много сообщений. Подождите минуту',chatoff:'Чат отключён администратором'};

/* ---------- dialogs ---------- */
function mkDlg(wide){
 var o=h('div','dlg'),b=h('div','dbox'+(wide?' wide':''));
 o.appendChild(b);document.body.appendChild(o);
 requestAnimationFrame(function(){requestAnimationFrame(function(){o.classList.add('on');});});
 var d={box:b,close:function(){o.classList.remove('on');setTimeout(function(){if(o.parentNode)o.parentNode.removeChild(o);},230);}};
 o.onclick=function(e){if(e.target===o)d.close();};
 return d;
}
function ask(msg,label,ok){
 var d=mkDlg();d.box.appendChild(h('p','',msg));
 var r=h('div','drow'),c=h('button','btn','Отмена'),o=h('button','btn red',label);
 c.onclick=d.close;o.onclick=function(){d.close();ok();};
 r.appendChild(c);r.appendChild(o);d.box.appendChild(r);
}
function sheet(title,items){
 var d=mkDlg();var t=h('h3','',title);t.style.wordBreak='break-all';d.box.appendChild(t);
 items.forEach(function(it){
  var b=h('button','shi'+(it.red?' red':''),it.t);
  b.onclick=function(){d.close();setTimeout(it.fn,60);};
  d.box.appendChild(b);
 });
}
function inputBox(title,val,label,cb){
 var d=mkDlg();d.box.appendChild(h('h3','',title));
 var i=h('input','in');i.value=val||'';i.maxLength=100;d.box.appendChild(i);
 var r=h('div','drow'),c=h('button','btn','Отмена'),o=h('button','btn pri',label);
 c.onclick=d.close;
 o.onclick=function(){var v=i.value.trim();if(!v)return;d.close();cb(v);};
 i.onkeydown=function(e){if(e.key==='Enter')o.onclick();};
 r.appendChild(c);r.appendChild(o);d.box.appendChild(r);
 setTimeout(function(){i.focus();i.select();},260);
}
function row(parent,iconName,name,right,fn){
 var r=h('div','prow');
 var ico=h('span','');ico.innerHTML=ic(iconName,20);r.appendChild(ico);
 r.appendChild(h('div','pn2',name));
 if(right)r.appendChild(h('div','pr',right));
 r.onclick=fn;parent.appendChild(r);return r;
}
// choose a destination folder (mode 'dir') or a file/folder (mode 'any') from my storage
function picker(mode,cb){
 var d=mkDlg(true),path='';
 d.box.appendChild(h('h3','',mode==='dir'?'Выберите папку':'Выберите файл или папку'));
 var loc=h('div','mut');loc.style.fontSize='13px';d.box.appendChild(loc);
 var list=h('div','pkl');d.box.appendChild(list);
 var foot=h('div','drow'),c=h('button','btn','Отмена');c.onclick=d.close;foot.appendChild(c);
 if(mode==='dir'){var ok=h('button','btn pri','Выбрать эту папку');ok.onclick=function(){d.close();cb(path);};foot.appendChild(ok);}
 d.box.appendChild(foot);
 function load(){
  api('/list?p='+q(path)).then(function(j){
   if(j.err)return;
   path=j.p;loc.textContent='Все файлы'+(path?' / '+path.split('/').join(' / '):'');
   list.innerHTML='';
   if(path){row(list,'l','Наверх','',function(){var a=path.split('/');a.pop();path=a.join('/');load();});}
   j.dirs.forEach(function(x){
    var r=row(list,'folder',x.n,mode==='any'?'выбрать':'',function(){path=jn(path,x.n);load();});
    if(mode==='any'){
     var pr=r.querySelector('.pr');
     pr.style.color='var(--ac)';
     pr.onclick=function(e){e.stopPropagation();d.close();cb({p:path,name:x.n,dir:1});};
    }
   });
   if(mode==='any'){j.files.forEach(function(f){row(list,'file',f.n,sz(f.s),function(){d.close();cb({p:path,name:f.n,dir:0});});});}
   if(!list.firstChild)list.appendChild(h('p','mut','Пусто'));
  });
 }
 load();
}

/* ---------- account, meter, notices ---------- */
function meter(){
 var u=me.used,qq=me.quota;
 $('mtx').textContent=qq>0?('Занято '+sz(u)+' из '+sz(qq)):('Занято '+sz(u)+', без ограничений');
 var p=qq>0?Math.min(100,u*100/qq):0;
 $('mbar').style.width=p+'%';$('mbar').className=p>90?'hi':'';
 $('mpc').textContent=qq>0?Math.round(p)+'%':'\u221e';
}
function loadMe(){
 return api('/api/me').then(function(j){
  me=j;
  $('who').textContent=j.dn;
  if(j.title){$('ttl').textContent=j.title;document.title=j.title;}
  $('adm').style.display=j.admin?'grid':'none';
  document.querySelector('#nav [data-v=chat]').style.display=j.chat?'flex':'none';
  unread=j.u;badge();meter();notice(j.nid,j.nt);
  if(curView==='prof')fillProf();
 }).catch(function(){});
}
function hideN(){$('ntc').classList.remove('on');}
function notice(id,t){
 if(!id){if(curN){curN='';hideN();}return;}
 if(id===seenN||id===curN)return;
 curN=id;$('ntx').textContent=t;$('ntc').classList.add('on');Snd.chime();
}
$('nok').onclick=function(){seenN=curN;try{localStorage.setItem('nseen',curN);}catch(e){}hideN();};
function setBadge(n){try{if(n>0){if(navigator.setAppBadge)navigator.setAppBadge(n);}else if(navigator.clearAppBadge)navigator.clearAppBadge();}catch(e){}}
function badge(){var b=$('nbadge');b.textContent=unread>99?'99+':String(unread);b.classList.toggle('on',unread>0);setBadge(unread);}
function pv(k,t){return k==='text'?t:(k==='file'?'Файл: ':'Папка: ')+t;}
function ping(){
 api('/api/ping').then(function(j){
  notice(j.nid,j.nt);
  unread=j.u;badge();
  if(j.m){
   if(lastNote<0)lastNote=j.m.i;
   else if(j.m.i>lastNote){
    lastNote=j.m.i;
    if(!(convOpen&&peer===j.m.p)){
     Snd.msg();
     toast(j.m.n+': '+pv(j.m.k,j.m.t),function(){goConv(j.m.p);});
    }
   }
  }else if(lastNote<0)lastNote=0;
  if(curView==='chat'&&!convOpen)loadChats();
 }).catch(function(){});
}
setInterval(ping,10000);

/* ---------- views ---------- */
function showView(v){
 curView=v;
 Array.prototype.forEach.call(document.querySelectorAll('.view'),function(x){x.classList.remove('on');});
 $('v-'+v).classList.add('on');
 Array.prototype.forEach.call(document.querySelectorAll('#nav button'),function(b){b.classList.toggle('on',b.getAttribute('data-v')===v);});
 if(v==='chat')loadChats();
 if(v==='prof')fillProf();
 window.scrollTo(0,0);
}
Array.prototype.forEach.call(document.querySelectorAll('#nav button'),function(b){
 b.onclick=function(){
  if(convOpen&&location.hash.indexOf('#chat/')===0){history.back();}
  showView(b.getAttribute('data-v'));
 };
});

/* ---------- files and folders ---------- */
function crumbs(){
 var b=$('crumbs');b.innerHTML='';
 var parts=cp?cp.split('/'):[];
 var r=h('button','cr'+(parts.length?'':' on'),'Все файлы');r.onclick=function(){loadFs('',true);};b.appendChild(r);
 var acc='';
 parts.forEach(function(p,i){
  acc=jn(acc,p);var path=acc;
  b.appendChild(h('span','sep','/'));
  var x=h('button','cr'+(i===parts.length-1?' on':''),p);x.onclick=function(){loadFs(path,true);};b.appendChild(x);
 });
}
function loadFs(path,anim){
 return api('/list?p='+q(path||'')).then(function(j){
  if(j.err){if(path)return loadFs('',anim);return;}
  cp=j.p;dirs=j.dirs;files=j.files;
  files.forEach(function(f){f.u='/view?p='+q(cp)+'&name='+q(f.n);f.d='/download/'+q(f.n)+'?p='+q(cp)+'&name='+q(f.n);});
  renderFs(anim);
 }).catch(function(){});
}
function iconBox(f){
 var d=h('div','ico k-'+f.k);
 d.innerHTML=ic(f.k==='audio'?'music':'file',38)+'<i></i>';
 d.lastChild.textContent=f.e?'.'+f.e:'файл';
 return d;
}
function renderFs(anim){
 crumbs();
 view=files.filter(function(f){
  if(filt==='doc'){if(f.k==='image'||f.k==='video'||f.k==='audio')return false;}
  else if(filt!=='all'&&f.k!==filt)return false;
  if(qs&&f.n.toLowerCase().indexOf(qs)<0)return false;
  return true;
 });
 var dv=dirs.filter(function(d){return filt==='all'&&(!qs||d.n.toLowerCase().indexOf(qs)>=0);});
 var g=$('grid');g.innerHTML='';
 var i=0;
 dv.forEach(function(d){g.appendChild(dirCard(d,i++,anim));});
 view.forEach(function(f,k){g.appendChild(fileCard(f,k,i++,anim));});
 $('empty').classList.toggle('on',!dv.length&&!view.length);
}
function moreBtn(fn){
 var b=h('button','ib sm');b.innerHTML=ic('more',18);b.title='Действия';
 b.onclick=function(e){e.stopPropagation();fn();};
 var w=h('div','ac');w.appendChild(b);return w;
}
function dirCard(d,i,anim){
 var c=h('div','card dir'+(anim?' in':''));
 if(anim)c.style.animationDelay=Math.min(i,14)*28+'ms';
 var th=h('div','th');
 var ib=h('div','ico');ib.innerHTML=ic('folder',46)+'<i></i>';ib.lastChild.textContent=d.c+' эл.';
 th.appendChild(ib);
 th.onclick=function(){loadFs(jn(cp,d.n),true);};
 th.appendChild(moreBtn(function(){dirMenu(d);}));
 var m=h('div','meta');m.appendChild(h('div','nm',d.n));m.appendChild(h('div','sub',dt(d.t)));
 m.onclick=th.onclick;
 c.appendChild(th);c.appendChild(m);return c;
}
function fileCard(f,k,i,anim){
 var c=h('div','card'+(anim?' in':''));
 if(anim)c.style.animationDelay=Math.min(i,14)*28+'ms';
 var th=h('div','th');
 if(f.k==='image'){
  var im=document.createElement('img');im.loading='lazy';im.decoding='async';im.alt='';im.src=f.u;
  im.onerror=function(){th.replaceChild(iconBox(f),im);};
  th.appendChild(im);
 }else if(f.k==='video'){
  var v=document.createElement('video');v.preload='metadata';v.muted=true;v.setAttribute('playsinline','');v.src=f.u+'#t=0.1';
  th.appendChild(v);
  th.insertAdjacentHTML('beforeend',`<span class='pl'>${ic('play',14)}</span>`);
 }else th.appendChild(iconBox(f));
 th.onclick=function(){openV(view,k);};
 th.appendChild(moreBtn(function(){fileMenu(f,k);}));
 var m=h('div','meta');m.appendChild(h('div','nm',f.n));m.appendChild(h('div','sub',sz(f.s)+', '+dt(f.t)));
 m.onclick=th.onclick;
 c.appendChild(th);c.appendChild(m);return c;
}
function dirMenu(d){
 sheet(d.n,[
  {t:'Открыть',fn:function(){loadFs(jn(cp,d.n),true);}},
  {t:'Скачать папкой (ZIP)',fn:function(){dlUrl('/zip/'+q(d.n)+'.zip?p='+q(cp)+'&name='+q(d.n));}},
  {t:'Отправить в чат',fn:function(){sendToChat({p:cp,name:d.n,dir:1});}},
  {t:'Переименовать',fn:function(){renameItem(d.n);}},
  {t:'Переместить',fn:function(){moveItem(d.n);}},
  {t:'Удалить',red:1,fn:function(){delItem(d.n,true);}}
 ]);
}
function fileMenu(f,k){
 sheet(f.n,[
  {t:'Открыть',fn:function(){openV(view,k);}},
  {t:'Скачать',fn:function(){dlUrl(f.d);}},
  {t:'Отправить в чат',fn:function(){sendToChat({p:cp,name:f.n,dir:0});}},
  {t:'Переименовать',fn:function(){renameItem(f.n);}},
  {t:'Переместить',fn:function(){moveItem(f.n);}},
  {t:'Удалить',red:1,fn:function(){delItem(f.n,false);}}
 ]);
}
function fsDone(j,okMsg){
 if(j.ok){Snd.ok();toast(okMsg);loadFs(cp,false);loadMe();}
 else{Snd.err();toast(FE[j.err]||'Ошибка');}
}
function renameItem(name){
 inputBox('Новое имя',name,'Сохранить',function(v){api('/api/fs/rename',{p:cp,name:name,to:v}).then(function(j){fsDone(j,'Переименовано');});});
}
function moveItem(name){
 picker('dir',function(dest){api('/api/fs/move',{p:cp,name:name,to:dest}).then(function(j){fsDone(j,'Перемещено');});});
}
function delItem(name,isDir){
 ask(isDir?'Удалить папку «'+name+'» со всем содержимым?':'Удалить файл «'+name+'»?','Удалить',function(){
  api('/delete?p='+q(cp)+'&name='+q(name),{x:1}).then(function(j){if(j.ok)Snd.del();fsDone(j,'Удалено');});
 });
}
$('newdir').onclick=function(){
 inputBox('Новая папка','','Создать',function(v){api('/api/fs/mkdir',{p:cp,name:v}).then(function(j){fsDone(j,'Папка создана');});});
};
$('zipcur').onclick=function(){dlUrl('/zip/files.zip?p='+q(cp)+'&name=');};
Array.prototype.forEach.call(document.querySelectorAll('#tabs button'),function(b){
 b.onclick=function(){
  Array.prototype.forEach.call(document.querySelectorAll('#tabs button'),function(x){x.classList.remove('on');});
  b.classList.add('on');filt=b.getAttribute('data-k');renderFs(true);
 };
});
$('q').oninput=function(){qs=this.value.trim().toLowerCase();renderFs(false);};

/* ---------- chunked upload (floating progress panel) ---------- */
var CH=8*1024*1024;
var UE={offline:'Сервер выключен',quota:'Не хватает места в хранилище',toobig:'Файл больше разрешённого размера',ext:'Этот тип файлов запрещён',disk:'На сервере закончилось место',bad:'Ошибка запроса',offset:'Сбой передачи, попробуйте ещё раз'};
function upload(list,dest,cb){
 for(var i=0;i<list.length;i++)pending.push({file:list[i],dest:dest,cb:cb});
 if(!busy)nextUp();
}
function nextUp(){
 if(!pending.length){busy=false;return;}
 busy=true;
 var job=pending.shift(),file=job.file;
 var row=h('div','up'),top=h('div','ut');
 var un=h('div','un',file.name),pc=h('div','pc','0%');
 top.appendChild(un);top.appendChild(pc);
 var pb=h('div','pb'),bi=document.createElement('i');pb.appendChild(bi);
 row.appendChild(top);row.appendChild(pb);$('upq').appendChild(row);
 var total=file.size,off=0,id='';
 function fin(ok,label,name){
  row.classList.add(ok?'ok':'bad');pc.textContent=label;
  if(ok){bi.style.width='100%';Snd.ok();if(job.cb)job.cb(name);if(job.dest===cp)loadFs(cp,false);loadMe();}else Snd.err();
  setTimeout(function(){row.classList.add('gone');setTimeout(function(){if(row.parentNode)row.parentNode.removeChild(row);},380);},ok?1600:6000);
  nextUp();
 }
 function step(tries){
  var end=Math.min(off+CH,total),last=end>=total;
  var x=new XMLHttpRequest();
  x.open('POST','/upload');
  x.setRequestHeader('X-Req','1');
  x.setRequestHeader('X-Name',q(file.name));
  x.setRequestHeader('X-Path',q(job.dest||''));
  x.setRequestHeader('X-Total',String(total));
  x.setRequestHeader('X-Offset',String(off));
  if(id)x.setRequestHeader('X-Id',id);
  if(last)x.setRequestHeader('X-Last','1');
  x.upload.onprogress=function(e){
   if(e.lengthComputable){var p=Math.round((off+e.loaded)*100/Math.max(total,1));bi.style.width=p+'%';pc.textContent=p+'%';}
  };
  x.onload=function(){
   var j={};try{j=JSON.parse(x.responseText);}catch(e){}
   if(x.status===200&&j.ok){
    id=j.id;off=end;
    if(last)fin(true,'Готово',j.name);else step(3);
   }else if(x.status===401){location.href='/';}
   else fin(false,UE[j.err]||('Ошибка '+x.status));
  };
  x.onerror=function(){if(tries>0)setTimeout(function(){step(tries-1);},1500);else fin(false,'Нет связи');};
  x.send(file.slice(off,end));
 }
 step(3);
}
$('f').onchange=function(){var arr=Array.prototype.slice.call(this.files);this.value='';upload(arr,cp,null);};
var fv=$('v-files');
['dragenter','dragover'].forEach(function(n){fv.addEventListener(n,function(e){e.preventDefault();});});
fv.addEventListener('drop',function(e){e.preventDefault();upload(Array.prototype.slice.call(e.dataTransfer.files),cp,null);});

/* ---------- viewer ---------- */
function stopMedia(){
 var m=$('vbody').querySelectorAll('video,audio');
 for(var i=0;i<m.length;i++){try{m[i].pause();m[i].removeAttribute('src');m[i].load();}catch(e){}}
}
function dlBtn(f){var a=h('a','btn pri','Скачать');a.href=f.d;a.onclick=function(e){e.preventDefault();dlUrl(f.d);};return a;}
function big(f,icon){
 var d=h('div','big');d.innerHTML=ic(icon,64)+'<i></i>';
 d.lastChild.textContent=f.e?'.'+f.e:'файл';return d;
}
function zoom(w,im,e){
 if(w.classList.contains('zm')){w.classList.remove('zm');return;}
 var r=im.getBoundingClientRect();
 var fx=(e.clientX-r.left)/r.width,fy=(e.clientY-r.top)/r.height;
 w.classList.add('zm');
 w.scrollLeft=fx*im.offsetWidth-w.clientWidth/2;
 w.scrollTop=fy*im.offsetHeight-w.clientHeight/2;
}
function show(){
 var f=vl[cur];if(!f)return;
 var tok=++seq;
 stopMedia();
 var b=$('vbody');b.innerHTML='';
 $('vname').textContent=f.n;
 $('vcount').textContent=(cur+1)+' из '+vl.length+', '+sz(f.s);
 $('vdl').href=f.d;
 $('vprev').classList.toggle('off',cur<=0);
 $('vnext').classList.toggle('off',cur>=vl.length-1);
 var w=h('div','vc');b.appendChild(w);
 if(f.k==='image'){
  var im=document.createElement('img');im.alt='';im.src=f.u;
  im.onclick=function(e){zoom(w,im,e);};
  im.onerror=function(){w.innerHTML='';w.appendChild(big(f,'file'));w.appendChild(h('p','mut','Этот формат изображения нельзя показать в браузере.'));w.appendChild(dlBtn(f));};
  w.appendChild(im);
 }else if(f.k==='video'){
  var v=document.createElement('video');
  v.controls=true;v.setAttribute('playsinline','');v.preload='auto';v.src=f.u;
  v.onerror=function(){
   if(w.querySelector('.fb'))return;
   var p=h('div','fb');p.appendChild(h('p','mut','Этот формат видео не воспроизводится в браузере.'));
   p.appendChild(dlBtn(f));w.appendChild(p);
  };
  w.appendChild(v);
  var pr=v.play();if(pr&&pr.catch)pr.catch(function(){});
 }else if(f.k==='audio'){
  w.appendChild(big(f,'music'));
  var au=document.createElement('audio');au.controls=true;au.src=f.u;
  w.appendChild(au);
  var pa=au.play();if(pa&&pa.catch)pa.catch(function(){});
 }else if(f.k==='pdf'){
  var fr=document.createElement('iframe');fr.src=f.u;
  w.appendChild(fr);
  var o=h('a','btn','Открыть в новой вкладке');o.target='_blank';o.href=f.u;o.style.marginTop='10px';
  w.appendChild(o);
 }else if(f.k==='text'){
  var pre=h('pre','','Загрузка...');w.appendChild(pre);
  fetch(f.u,{headers:{'Range':'bytes=0-200000'},credentials:'same-origin'}).then(function(r){return r.text();}).then(function(t){
   if(tok!==seq)return;
   pre.textContent=t+(f.s>200001?'\n\n(Показано начало файла. Скачайте файл, чтобы прочитать его полностью.)':'');
  }).catch(function(){if(tok===seq)pre.textContent='Не удалось загрузить файл.';});
 }else{
  w.appendChild(big(f,'file'));
  w.appendChild(h('p','mut','Для этого типа файлов нет предпросмотра.'));w.appendChild(dlBtn(f));
 }
}
function openV(list,i){
 vl=list;cur=i;clearTimeout(ct);
 $('vw').classList.add('on');document.body.classList.add('lock');
 if(!isOpen){isOpen=true;hs=true;Snd.open();try{history.pushState({v:1},'');}catch(e){hs=false;}}
 show();
}
function doClose(){
 isOpen=false;seq++;stopMedia();
 $('vw').classList.remove('on');document.body.classList.remove('lock');
 cur=-1;ct=setTimeout(function(){$('vbody').innerHTML='';},280);
}
function closeV(){if(!isOpen)return;if(hs){try{history.back();}catch(e){doClose();}}else doClose();}
function go(d){var n=cur+d;if(n<0||n>=vl.length)return;cur=n;show();}
window.addEventListener('popstate',function(){if(isOpen)doClose();});
$('vx').onclick=closeV;
$('vdl').onclick=function(e){e.preventDefault();var f=vl[cur];if(f)dlUrl(f.d);};
$('vprev').onclick=function(){go(-1);};
$('vnext').onclick=function(){go(1);};
document.addEventListener('keydown',function(e){
 if(!isOpen)return;
 if(e.key==='Escape')closeV();else if(e.key==='ArrowLeft')go(-1);else if(e.key==='ArrowRight')go(1);
});
var tx=0,ty=0,sw=false;
$('vbody').addEventListener('touchstart',function(e){
 var t=e.changedTouches[0];tx=t.clientX;ty=t.clientY;
 sw=(e.target.tagName==='IMG'||e.target.classList.contains('vc'));
},{passive:true});
$('vbody').addEventListener('touchend',function(e){
 if(!sw)return;
 var w=$('vbody').firstChild;if(w&&w.classList.contains('zm'))return;
 var t=e.changedTouches[0],dx=t.clientX-tx,dy=t.clientY-ty;
 if(Math.abs(dx)>60&&Math.abs(dx)>Math.abs(dy)*1.5)go(dx<0?1:-1);
},{passive:true});

/* ---------- chat ---------- */
function loadChats(){
 return api('/api/chat/list').then(function(j){
  if(j.err){convs=[];}else convs=j;
  var box=$('cl');box.innerHTML='';
  convs.forEach(function(c,i){
   var r=h('div','crow');r.style.animationDelay=Math.min(i,10)*30+'ms';
   r.appendChild(h('div','av',c.name.charAt(0).toUpperCase()));
   var inf=h('div','cinf');inf.appendChild(h('div','cnm',c.name));
   inf.appendChild(h('div','cpv',(c.mine?'Вы: ':'')+pv(c.k,c.t)));r.appendChild(inf);
   var m=h('div','cmeta');m.appendChild(h('span','',tmf(c.ts)));
   if(c.u>0)m.appendChild(h('span','cu',String(c.u)));
   r.appendChild(m);
   r.onclick=function(){goConv(c.id);};
   box.appendChild(r);
  });
  $('cempty').classList.toggle('on',!convs.length);
 }).catch(function(){});
}
function goConv(id){
 showView('chat');
 if(location.hash==='#chat/'+id)route();else location.hash='#chat/'+id;
}
function route(){
 var m=/^#chat\/(\d+)/.exec(location.hash||'');
 if(m&&me.chat){showView('chat');openConv(m[1]);}
 else if(convOpen)closeConv();
}
window.addEventListener('hashchange',route);
function fitTa(){var t=$('ct');t.style.height='auto';t.style.height=Math.min(t.scrollHeight,120)+'px';}
function openConv(id){
 if(convOpen&&peer===id)return;
 peer=id;convOpen=true;lastMid=0;
 $('cvm').innerHTML='';$('cvn').textContent='...';$('cvi').textContent='ID '+id;$('cvav').textContent='';
 $('cv').classList.add('on');fitCv();
 pollConv(true);
 clearInterval(cvTimer);cvTimer=setInterval(function(){pollConv(false);},3000);
}
function closeConv(){
 convOpen=false;peer=null;clearInterval(cvTimer);
 $('cv').classList.remove('on');
 loadChats();loadMe();
}
$('cvback').onclick=function(){if(location.hash.indexOf('#chat/')===0)history.back();else closeConv();};
function fitCv(){
 var v=window.visualViewport,el=$('cv');
 if(v){el.style.height=v.height+'px';el.style.top=v.offsetTop+'px';}
}
if(window.visualViewport){visualViewport.addEventListener('resize',fitCv);visualViewport.addEventListener('scroll',fitCv);}
function pollConv(first){
 if(!peer)return;
 var pid=peer;
 api('/api/chat/msgs?peer='+q(pid)+'&after='+lastMid+'&mark=1').then(function(j){
  if(pid!==peer)return;
  if(j.err){toast(FE[j.err]||'Чат недоступен');if(location.hash.indexOf('#chat/')===0)history.back();else closeConv();return;}
  $('cvn').textContent=j.peer.name;$('cvi').textContent='ID '+j.peer.id;$('cvav').textContent=j.peer.name.charAt(0).toUpperCase();
  if(j.msgs.length)addMsgs(j.msgs,first);
  else if(first&&!$('cvm').firstChild)$('cvm').appendChild(h('div','cve','Сообщений пока нет. Напишите первым.'));
 }).catch(function(){});
}
function addMsgs(list,first){
 var box=$('cvm');
 var near=first||(box.scrollHeight-box.scrollTop-box.clientHeight<140);
 var other=false;
 var e0=box.querySelector('.cve');if(e0)box.removeChild(e0);
 list.forEach(function(m){
  if(m.i<=lastMid)return;
  lastMid=m.i;box.appendChild(msgEl(m));
  if(m.f!==me.id)other=true;
 });
 if(other&&!first)Snd.msg();
 if(near)box.scrollTop=box.scrollHeight;
}
function msgEl(m){
 var mine=m.f===me.id;
 var b=h('div','bb '+(mine?'me':'th'));
 if(m.k==='text')b.appendChild(h('div','tx',m.t));
 else b.appendChild(attEl(m));
 b.appendChild(h('div','tm',new Date(m.ts).toLocaleTimeString('ru-RU',{hour:'2-digit',minute:'2-digit'})));
 return b;
}
function mk(parent,label,fn){var x=h('button','',label);x.onclick=fn;parent.appendChild(x);}
function attEl(m){
 var isDir=m.k==='dir',pid=peer;
 var w=h('div','');
 var a=h('div','att'),i=h('div','ai');i.innerHTML=ic(isDir?'folder':'file',22);a.appendChild(i);
 var inf=h('div','');inf.appendChild(h('div','an',m.t));inf.appendChild(h('div','as',sz(m.s)+(isDir?', папка':'')));a.appendChild(inf);
 w.appendChild(a);
 var bt=h('div','ab');
 if(!m.x)bt.appendChild(h('span','gone','Удалено отправителем'));
 else{
  var base='/api/chat/item?peer='+q(pid)+'&m='+m.i;
  if(isDir){
   mk(bt,'Открыть папку',function(){openShared(m);});
   mk(bt,'Скачать ZIP',function(){dlUrl(base+'&z=1&dl=1');});
  }else{
   mk(bt,'Открыть',function(){openV([{n:m.t,s:m.s,k:m.kd,e:m.e,t:m.ts,u:base,d:base+'&dl=1'}],0);});
   mk(bt,'Скачать',function(){dlUrl(base+'&dl=1');});
  }
  if(m.f!==me.id)mk(bt,'Сохранить себе',function(){saveShared(pid,m.i,'');});
 }
 w.appendChild(bt);
 return w;
}
function saveShared(pid,mid,sub){
 api('/api/chat/save',{peer:pid,m:mid,sub:sub}).then(function(j){
  if(j.ok){Snd.ok();toast('Сохранено в папку «'+me.dr+'»');loadMe();if(cp===''||cp===me.dr)loadFs(cp,false);}
  else{Snd.err();toast(FE[j.err]||'Не удалось сохранить');}
 });
}
function openShared(m){
 var pid=peer,sub='';
 var d=mkDlg(true);
 var t=h('h3','',m.t);t.style.wordBreak='break-all';d.box.appendChild(t);
 var loc=h('div','mut');loc.style.fontSize='13px';d.box.appendChild(loc);
 var list=h('div','pkl');d.box.appendChild(list);
 var r1=h('div','drow'),zb=h('button','btn','Скачать ZIP'),sv=h('button','btn pri','Сохранить себе');
 zb.onclick=function(){dlUrl('/api/chat/item?peer='+q(pid)+'&m='+m.i+'&sub='+q(sub)+'&z=1&dl=1');};
 sv.onclick=function(){saveShared(pid,m.i,sub);};
 r1.appendChild(zb);if(m.f!==me.id)r1.appendChild(sv);d.box.appendChild(r1);
 var r2=h('div','drow'),cl=h('button','btn','Закрыть');cl.onclick=d.close;r2.appendChild(cl);d.box.appendChild(r2);
 function ci(name){return '/api/chat/item?peer='+q(pid)+'&m='+m.i+'&sub='+q(jn(sub,name));}
 function load(){
  api('/api/chat/dir?peer='+q(pid)+'&m='+m.i+'&sub='+q(sub)).then(function(j){
   if(j.err){toast('Папка недоступна');return;}
   loc.textContent=m.t+(sub?' / '+sub.split('/').join(' / '):'');
   list.innerHTML='';
   if(sub){row(list,'l','Наверх','',function(){var a=sub.split('/');a.pop();sub=a.join('/');load();});}
   j.dirs.forEach(function(x){row(list,'folder',x.n,x.c+' эл.',function(){sub=jn(sub,x.n);load();});});
   var fl=j.files.map(function(f){return {n:f.n,s:f.s,k:f.k,e:f.e,t:f.t,u:ci(f.n),d:ci(f.n)+'&dl=1'};});
   fl.forEach(function(f,k){row(list,'file',f.n,sz(f.s),function(){openV(fl,k);});});
   if(!list.firstChild)list.appendChild(h('p','mut','Папка пуста'));
  });
 }
 load();
}
function sendItem(pid,it){
 api('/api/chat/send',{peer:pid,type:it.dir?'dir':'file',p:it.p,name:it.name}).then(function(j){
  if(j.ok){Snd.send();toast('Отправлено');if(convOpen&&peer===pid)addMsgs([j.m],false);}
  else{Snd.err();toast(FE[j.err]||'Не отправлено');}
 });
}
function chooseChat(cb){
 var d=mkDlg();d.box.appendChild(h('h3','','Кому отправить'));
 var list=h('div','pkl');d.box.appendChild(list);
 api('/api/chat/list').then(function(j){
  if(j.err){list.appendChild(h('p','mut','Чат отключён'));return;}
  j.forEach(function(c){row(list,'user',c.name,'ID '+c.id,function(){d.close();cb(c.id);});});
  if(!j.length)list.appendChild(h('p','mut','Пока нет чатов. Введите ID ниже.'));
 });
 var i=h('input','in');i.placeholder='Или введите ID человека';i.inputMode='numeric';d.box.appendChild(i);
 var r=h('div','drow'),c=h('button','btn','Отмена'),o=h('button','btn pri','Найти по ID');
 c.onclick=d.close;
 o.onclick=function(){
  api('/api/chat/find?id='+q(i.value.trim())).then(function(j){
   if(j.err){Snd.err();toast(FE[j.err]||'Не найден');}else{d.close();cb(j.id);}
  });
 };
 r.appendChild(c);r.appendChild(o);d.box.appendChild(r);
}
function sendToChat(it){chooseChat(function(pid){sendItem(pid,it);});}
$('newchat').onclick=function(){
 var d=mkDlg();d.box.appendChild(h('h3','','Новый чат'));
 d.box.appendChild(h('p','mut','Введите ID человека. Свой ID вы найдёте в разделе «Профиль».'));
 var i=h('input','in');i.placeholder='Например, 48291037';i.inputMode='numeric';d.box.appendChild(i);
 var r=h('div','drow'),c=h('button','btn','Отмена'),o=h('button','btn pri','Открыть чат');
 c.onclick=d.close;
 o.onclick=function(){
  api('/api/chat/find?id='+q(i.value.trim())).then(function(j){
   if(j.err){Snd.err();toast(FE[j.err]||'Не найден');}else{d.close();goConv(j.id);}
  });
 };
 i.onkeydown=function(e){if(e.key==='Enter')o.onclick();};
 r.appendChild(c);r.appendChild(o);d.box.appendChild(r);
 setTimeout(function(){i.focus();},260);
};
function sendText(){
 var t=$('ct').value.trim();if(!t||!peer)return;
 $('ct').value='';fitTa();
 api('/api/chat/send',{peer:peer,type:'text',text:t}).then(function(j){
  if(j.ok){Snd.send();addMsgs([j.m],false);$('cvm').scrollTop=$('cvm').scrollHeight;}
  else{Snd.err();toast(FE[j.err]||'Не отправлено');$('ct').value=t;fitTa();}
 });
}
$('cvsend').onclick=sendText;
$('ct').oninput=fitTa;
$('ct').onkeydown=function(e){
 if(e.key==='Enter'&&!e.shiftKey&&window.matchMedia&&matchMedia('(pointer:fine)').matches){e.preventDefault();sendText();}
};
$('cvatt').onclick=function(){
 sheet('Прикрепить',[
  {t:'Загрузить с устройства',fn:function(){$('cf').click();}},
  {t:'Выбрать из моих файлов',fn:function(){var pid=peer;picker('any',function(sel){sendItem(pid,sel);});}}
 ]);
};
$('cf').onchange=function(){
 var arr=Array.prototype.slice.call(this.files);this.value='';
 var pid=peer;
 upload(arr,me.dc,function(name){sendItem(pid,{p:me.dc,name:name,dir:0});});
};

/* ---------- profile ---------- */
var PE={wrongpass:'Неверный текущий пароль',locked:'Слишком много попыток. Попробуйте позже',exists:'Такой логин уже занят',badlogin:'Логин: от 3 до 20 символов, только латиница, цифры, точка, дефис и подчёркивание',badpass:'Пароль: от 4 до 32 символов, без символов \\ / : * ? " < > |, без пробела или точки в конце',reserved:'Этот логин зарезервирован',folder:'Не удалось переименовать папку. Закройте открытые файлы и повторите',adminfixed:'Логин и пароль администратора меняются в server.bat'};
function fillProf(){
 $('pav').textContent=(me.dn||'?').charAt(0).toUpperCase();
 $('pname').textContent=me.dn;$('pid').textContent=me.id;$('pn').value=me.name;$('plogin').textContent=me.login;
 $('pcred').style.display=me.admin?'none':'flex';
 $('padm').style.display=me.admin?'block':'none';
 $('psnd').checked=Snd.isOn();
 pushInfo();
}
$('pidcopy').onclick=function(){
 if(navigator.clipboard&&navigator.clipboard.writeText){navigator.clipboard.writeText(me.id).then(function(){Snd.ok();toast('ID скопирован');},function(){prompt('Ваш ID',me.id);});}
 else prompt('Ваш ID',me.id);
};
$('pnsave').onclick=function(){
 api('/api/profile/name',{name:$('pn').value}).then(function(j){
  if(j.ok){me.name=$('pn').value.trim();me.dn=j.dn;$('who').textContent=j.dn;Snd.ok();toast('Имя сохранено');fillProf();}
 });
};
$('psnd').onchange=function(){Snd.setOn(this.checked);sndIcon();if(this.checked)Snd.ok();};
function credDlg(kind){
 var d=mkDlg();d.box.appendChild(h('h3','',kind==='login'?'Сменить логин':'Сменить пароль'));
 function fld(ph,type){var i=h('input','in');i.type=type||'password';i.placeholder=ph;i.autocapitalize='none';i.style.marginBottom='10px';d.box.appendChild(i);return i;}
 var nl=null,np=null,np2=null;
 if(kind==='login')nl=fld('Новый логин','text');else{np=fld('Новый пароль');np2=fld('Повторите новый пароль');}
 var cur=fld('Текущий пароль');
 var er=h('div','msg bad');er.style.display='none';d.box.appendChild(er);
 var r=h('div','drow'),c=h('button','btn','Отмена'),o=h('button','btn pri','Сохранить');
 c.onclick=d.close;
 o.onclick=function(){
  er.style.display='none';
  var data={cur:cur.value};
  if(kind==='login')data.nl=nl.value.trim();
  else{if(np.value!==np2.value){er.textContent='Пароли не совпадают';er.style.display='block';Snd.err();return;}data.np=np.value;}
  api('/api/profile/'+kind,data).then(function(j){
   if(j.ok){Snd.ok();d.close();toast(kind==='login'?'Логин изменён':'Пароль изменён');if(j.login){me.login=j.login;}fillProf();loadMe();}
   else{Snd.err();er.textContent=PE[j.err]||'Ошибка';er.style.display='block';}
  });
 };
 r.appendChild(c);r.appendChild(o);d.box.appendChild(r);
}
$('chlogin').onclick=function(){credDlg('login');};
$('chpass').onclick=function(){credDlg('pass');};
$('outall').onclick=function(){
 ask('Выйти на всех остальных устройствах? Здесь вы останетесь в аккаунте.','Выйти',function(){
  api('/api/profile/logout-all',{x:1}).then(function(){Snd.ok();toast('Готово');});
 });
};

/* ---------- push notifications ---------- */
function b64u(s){
 var p='='.repeat((4-s.length%4)%4);
 var r=atob((s+p).replace(/-/g,'+').replace(/_/g,'/')),o=new Uint8Array(r.length);
 for(var i=0;i<r.length;i++)o[i]=r.charCodeAt(i);
 return o;
}
function pushSupported(){return ('serviceWorker' in navigator)&&('PushManager' in window)&&('Notification' in window);}
function isStandalone(){return window.navigator.standalone===true||(window.matchMedia&&matchMedia('(display-mode: standalone)').matches);}
function pushInfo(){
 var i=$('pushinfo'),b=$('pushbtn');
 var ios=/iPhone|iPad|iPod/.test(navigator.userAgent);
 b.style.display='none';
 if(location.protocol!=='https:'&&location.hostname!=='localhost'){
  i.textContent='Для уведомлений нужен защищённый адрес https. Откройте сайт по постоянной ссылке с https (Cloudflare или Tailscale).';return;
 }
 if(ios&&!isStandalone()){
  i.textContent='На iPhone: нажмите «Поделиться» в Safari и выберите «На экран Домой». Откройте сайт с иконки на экране и включите уведомления здесь.';return;
 }
 if(!pushSupported()){i.textContent='Этот браузер не поддерживает уведомления.';return;}
 b.style.display='inline-block';
 navigator.serviceWorker.getRegistration().then(function(reg){return reg?reg.pushManager.getSubscription():null;}).then(function(sub){
  if(sub&&Notification.permission==='granted'){
   i.textContent='Уведомления включены на этом устройстве. Сообщения придут, даже когда сайт закрыт.';
   b.textContent='Отключить уведомления';b.onclick=disablePush;
  }else{
   i.textContent=Notification.permission==='denied'?'Уведомления запрещены в настройках браузера или телефона. Разрешите их и обновите страницу.':'Включите, чтобы получать сообщения и объявления, даже когда сайт закрыт.';
   b.textContent='Включить уведомления';b.onclick=enablePush;
  }
 }).catch(function(){});
}
function enablePush(){
 Notification.requestPermission().then(function(p){
  if(p!=='granted'){toast('Уведомления не разрешены');pushInfo();return;}
  return navigator.serviceWorker.register('/sw.js').then(function(){return navigator.serviceWorker.ready;}).then(function(reg){
   return api('/api/push/key').then(function(k){
    if(!k.key){toast('Сервер не поддерживает уведомления');return;}
    return reg.pushManager.getSubscription().then(function(s){
     return s||reg.pushManager.subscribe({userVisibleOnly:true,applicationServerKey:b64u(k.key)});
    }).then(function(sub){
     return api('/api/push/sub',{endpoint:sub.endpoint}).then(function(){Snd.ok();toast('Уведомления включены');pushInfo();});
    });
   });
  });
 }).catch(function(){toast('Не удалось включить уведомления');pushInfo();});
}
function disablePush(){
 navigator.serviceWorker.getRegistration().then(function(reg){return reg?reg.pushManager.getSubscription():null;}).then(function(s){return s?s.unsubscribe():null;}).then(function(){
  return api('/api/push/unsub',{x:1});
 }).then(function(){toast('Уведомления отключены');pushInfo();}).catch(function(){});
}
function initSW(){
 if(!('serviceWorker' in navigator))return;
 navigator.serviceWorker.register('/sw.js').then(function(){return navigator.serviceWorker.ready;}).then(function(reg){
  // keep the server in sync with this device's subscription (the login session may have changed)
  return reg.pushManager.getSubscription().then(function(s){
   if(s&&Notification.permission==='granted')return api('/api/push/sub',{endpoint:s.endpoint});
  });
 }).catch(function(){});
 navigator.serviceWorker.addEventListener('message',function(e){
  if(e.data&&e.data.go){var hsh=String(e.data.go).split('#')[1]||'';location.hash=hsh?'#'+hsh:'';route();}
 });
}

/* ---------- start ---------- */
function sndIcon(){$('snd').innerHTML=ic(Snd.isOn()?'vol':'mute',20);}
$('snd').onclick=function(){Snd.setOn(!Snd.isOn());sndIcon();if(Snd.isOn())Snd.ok();};
Array.prototype.forEach.call(document.querySelectorAll('[data-i]'),function(el){
 el.innerHTML=ic(el.getAttribute('data-i'),parseInt(el.getAttribute('data-s'),10)||20);
});
sndIcon();
loadMe().then(function(){route();});
loadFs('',true);
ping();
initSW();
document.addEventListener('visibilitychange',function(){
 if(!document.hidden){ping();loadMe();if(curView==='files')loadFs(cp,false);}
});
</script>
</body></html>
'@

$pAdmin = @'
<!DOCTYPE html><html lang='ru'><head><title>Админ-панель</title>@@HEAD@@
<style>
.bar{position:sticky;top:0;z-index:20;background:rgba(18,21,28,.82);backdrop-filter:blur(14px);-webkit-backdrop-filter:blur(14px);border-bottom:1px solid var(--ln)}
.bar-in{max-width:1000px;margin:0 auto;padding:12px 16px;display:flex;align-items:center;justify-content:space-between;gap:12px}
.brand{display:flex;align-items:center;gap:12px;min-width:0}
.mark{width:40px;height:40px;border-radius:12px;display:grid;place-items:center;background:var(--ac);color:#0c1220;flex:none}
.brand b{display:block;font-size:17px;font-weight:650}
.brand small{color:var(--mu);font-size:13px}
.hact{display:flex;align-items:center;gap:8px;flex:none}
.out{color:var(--mu);text-decoration:none;padding:8px 14px;border:1px solid var(--ln);border-radius:999px;font-size:14px;transition:background .2s,color .2s}
.out:hover{color:var(--tx);background:var(--sf)}
.ib{width:38px;height:38px;border-radius:50%;display:grid;place-items:center;background:var(--sf);border:1px solid var(--ln);color:var(--tx);transition:background .2s;flex:none}
.ib:hover{background:var(--sf2)}
.wrap{max-width:1000px;margin:0 auto;padding:16px 16px 70px}
.tabs{display:flex;gap:6px;overflow-x:auto;margin-bottom:16px;scrollbar-width:none}
.tabs::-webkit-scrollbar{display:none}
.tabs button{padding:9px 16px;border-radius:999px;background:var(--sf);color:var(--mu);font-size:14px;white-space:nowrap;border:1px solid var(--ln);transition:background .2s,color .2s,border-color .2s}
.tabs button.on{background:var(--ac);color:#0c1220;border-color:var(--ac);font-weight:600}
.sec{display:none}
.sec.on{display:block;animation:fade .3s both}
.panel{background:var(--sf);border:1px solid var(--ln);border-radius:16px;padding:16px;margin-bottom:14px}
.panel h3{margin:0 0 6px;font-size:16px}
.panel p{margin:0 0 12px;font-size:14px;line-height:1.45}
.stats{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:10px;margin-bottom:14px}
.st{background:var(--sf);border:1px solid var(--ln);border-radius:14px;padding:14px}
.st small{display:block;color:var(--mu);font-size:13px;margin-bottom:6px}
.st b{font-size:19px;font-weight:650}
.copy{display:flex;gap:10px;align-items:center}
.copy code{flex:1;min-width:0;padding:11px 12px;border-radius:10px;background:var(--bg);border:1px solid var(--ln);font-size:14px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.orow{display:flex;justify-content:space-between;gap:10px;padding:9px 0;border-bottom:1px solid var(--ln);font-size:14px}
.orow:last-child{border-bottom:0}
.tools{display:flex;gap:10px;margin-bottom:12px}
.tools .in{flex:1}
.urow{display:flex;align-items:center;gap:12px;padding:12px;background:var(--sf);border:1px solid var(--ln);border-radius:14px;margin-bottom:10px;animation:rise .35s both}
.ua{width:42px;height:42px;border-radius:50%;display:grid;place-items:center;background:var(--sf2);font-weight:650;flex:none}
.ui{flex:1;min-width:0}
.unm{font-weight:600;display:flex;flex-wrap:wrap;gap:6px;align-items:center}
.bd{font-size:11.5px;font-weight:500;padding:2px 8px;border-radius:999px}
.bd.ac{background:rgba(122,162,255,.18);color:var(--ac)}
.bd.gn{background:rgba(74,222,128,.15);color:var(--gn)}
.bd.rd{background:rgba(255,107,107,.15);color:var(--rd)}
.bd.am{background:rgba(251,191,36,.15);color:var(--am)}
.uf{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12.5px;color:var(--mu);margin-top:3px;word-break:break-all}
.umeta{font-size:13px;color:var(--mu);margin-top:6px}
.mb{height:5px;border-radius:6px;background:var(--sf2);overflow:hidden;margin-top:8px}
.mb i{display:block;height:100%;width:0;background:var(--ac);border-radius:6px;transition:width .5s}
.mb i.hi{background:var(--rd)}
.ubtn{display:flex;flex-direction:column;gap:6px;flex:none}
.ubtn .btn{padding:8px 14px;font-size:14px}
.field{margin-bottom:16px}
.lb{display:block;font-size:14px;margin-bottom:6px}
.sub{font-size:13px;color:var(--mu);margin:4px 0 0;line-height:1.4}
.line{display:flex;align-items:center;justify-content:space-between;gap:14px;padding:12px 0;border-bottom:1px solid var(--ln)}
.line:last-child{border-bottom:0}
.line span{font-size:15px}
.line small{display:block;color:var(--mu);font-size:13px;margin-top:2px}
.qv{font-weight:650;color:var(--ac)}
.lrow{display:grid;grid-template-columns:130px 1fr;gap:10px;padding:9px 0;border-bottom:1px solid var(--ln);font-size:13.5px}
.lrow:last-child{border-bottom:0}
.lrow time{color:var(--mu)}
.chk{display:flex;align-items:center;gap:10px;font-size:15px;margin:8px 0}
.chk input{width:18px;height:18px;accent-color:var(--ac)}
.cur{background:var(--sf2);border-radius:10px;padding:8px 12px;font-size:13.5px;margin:8px 0 14px;word-break:break-all}
@media (max-width:520px){.lrow{grid-template-columns:1fr;gap:2px}}
</style></head><body>
<header class='bar'><div class='bar-in'>
<div class='brand'><div class='mark' data-i='sliders' data-s='22'></div><div><b>Админ-панель</b><small id='sub'>Загрузка...</small></div></div>
<div class='hact'><button class='ib' id='snd' title='Звуки интерфейса'></button><a class='out' href='/'>К файлам</a></div>
</div></header>

<main class='wrap'>
<nav class='tabs' id='tabs'>
<button class='on' data-t='ov'>Обзор</button>
<button data-t='us'>Пользователи</button>
<button data-t='st'>Настройки</button>
<button data-t='nt'>Оповещение</button>
<button data-t='lg'>Журнал</button>
</nav>

<section class='sec on' id='ov'>
<div class='stats' id='stats'></div>
<div class='panel'>
<h3>Ссылка для друзей</h3>
<p class='mut' id='pubh'>Загрузка...</p>
<div class='copy'><code id='pub'>...</code><button class='btn pri' id='cpy'>Копировать</button></div>
</div>
<div class='panel'><h3>Сейчас онлайн</h3><div id='onl'></div></div>
</section>

<section class='sec' id='us'>
<div class='tools'><input class='in' id='uq' type='search' placeholder='Поиск по логину'><button class='btn pri' id='uadd'>Добавить</button></div>
<div id='ulist'></div>
</section>

<section class='sec' id='st'>
<div class='panel'>
<div class='field'><label class='lb'>Название сайта</label><input class='in' id='s_title' maxlength='40' placeholder='Мои файлы'></div>
<div class='line'><span>Регистрация открыта<small>Если выключить, новые аккаунты создать нельзя</small></span><label class='sw'><input type='checkbox' id='s_reg'><i></i></label></div>
<div class='line'><span>Подтверждать новые аккаунты<small>Новый пользователь сможет войти после вашего подтверждения</small></span><label class='sw'><input type='checkbox' id='s_app'><i></i></label></div>
<div class='line'><span>Чат включён<small>Переписка и передача файлов между пользователями</small></span><label class='sw'><input type='checkbox' id='s_chat'><i></i></label></div>
<div class='line'><span>Технические работы<small>Войти смогут только администраторы, остальные будут отключены</small></span><label class='sw'><input type='checkbox' id='s_mnt'><i></i></label></div>
</div>
<div class='panel'>
<h3>Место для новых пользователей</h3>
<p class='mut'>Выделяется каждому обычному пользователю по умолчанию. Для отдельного человека можно задать своё значение в списке пользователей.</p>
<div class='lb'>Сейчас: <span class='qv' id='s_ql'></span></div>
<input class='rng' type='range' id='s_q' min='0' max='12' step='1'>
</div>
<div class='panel'>
<div class='field'><label class='lb'>Максимальный размер одного файла, МБ</label><input class='in' id='s_mf' type='number' min='0' inputmode='numeric'><p class='sub'>0 означает без ограничений. Не относится к администратору.</p></div>
<div class='field'><label class='lb'>Максимум пользователей</label><input class='in' id='s_mu' type='number' min='0' inputmode='numeric'><p class='sub'>0 означает без ограничений.</p></div>
<div class='field'><label class='lb'>Запасное место на диске, ГБ</label><input class='in' id='s_rs' type='number' min='0' step='0.5' inputmode='decimal'><p class='sub'>Загрузки остановятся, если на диске останется меньше этого объёма.</p></div>
<div class='field'><label class='lb'>Запрещённые типы файлов</label><input class='in' id='s_be' placeholder='exe, bat, msi'><p class='sub'>Расширения через запятую. Защищает компьютер от вредоносных файлов. Не относится к администратору.</p></div>
</div>
<button class='btn pri' id='s_save' style='width:100%'>Сохранить настройки</button>
</section>

<section class='sec' id='nt'>
<div class='panel'>
<h3>Оповещение для всех</h3>
<p class='mut'>Сообщение увидят все, кто сейчас онлайн, и все, кто зайдёт позже. Появится тихий звук.</p>
<textarea class='in' id='n_text' maxlength='500' placeholder='Например: сегодня в 22:00 сервер будет перезагружен'></textarea>
<div class='drow'><button class='btn' id='n_clear'>Убрать текущее</button><button class='btn pri' id='n_send'>Отправить всем</button></div>
</div>
<div class='panel'><h3>Сейчас показывается</h3><p id='n_cur' class='mut' style='margin:0;white-space:pre-wrap'></p></div>
</section>

<section class='sec' id='lg'>
<div class='panel'><div id='logs'></div></div>
</section>
</main>

<div class='dlg' id='ed'><div class='dbox wide'>
<h3 id='et'>Аккаунт</h3>
<div class='field'><label class='lb'>Логин</label><input class='in' id='el' autocapitalize='none' autocorrect='off'></div>
<div class='field' style='margin-bottom:0'><label class='lb'>Пароль</label><input class='in' id='ep' autocapitalize='none' autocorrect='off' placeholder='Новый пароль'></div>
<div class='cur' id='ecur'></div>
<div class='lb'>Выделенное место: <span class='qv' id='eql'></span></div>
<label class='chk'><input type='checkbox' id='edef'> Как по умолчанию</label>
<input class='rng' type='range' id='eq' min='0' max='12' step='1'>
<div class='line' id='ebr'><span>Заблокирован</span><label class='sw'><input type='checkbox' id='eb'><i></i></label></div>
<div class='msg bad' id='eerr' style='display:none'></div>
<div class='drow'><button class='btn' id='ecan'>Отмена</button><button class='btn pri' id='esav'>Сохранить</button></div>
<div class='drow' id='eextra'><button class='btn' id='ekick'>Отключить от сайта</button><button class='btn red' id='edel'>Удалить</button></div>
</div></div>

<div class='dlg' id='cf'><div class='dbox'>
<p id='cfm'></p>
<label class='chk' id='cfw'><input type='checkbox' id='cfwipe'> Удалить также файлы пользователя</label>
<div class='drow'><button class='btn' id='cfn'>Отмена</button><button class='btn red' id='cfy'>Удалить</button></div>
</div></div>
<div class='toast' id='toast'></div>

<script>
@@SND@@
var P={
 sliders:'M4 7h9M17 7h3M4 17h3M11 17h9M15 4v6M9 14v6',
 vol:'M11 5L6 9H2v6h4l5 4V5zM15.5 8.5a5 5 0 010 7M18.5 5.5a9 9 0 010 13',
 mute:'M11 5L6 9H2v6h4l5 4V5zM22 9l-6 6M16 9l6 6'
};
function ic(n,s){s=s||20;return `<svg viewBox='0 0 24 24' width='${s}' height='${s}' fill='none' stroke='currentColor' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><path d='${P[n]}'/></svg>`;}
var QS=[1,2,3,5,10,20,30,50,100,200,500,1000,0];
function ql(g){return g===0?'Безлимит':(g>=1000?(g/1000)+' ТБ':g+' ГБ');}
function qi(g){
 var i=QS.indexOf(g);if(i>=0)return i;
 if(g===0)return QS.length-1;
 for(var k=0;k<QS.length-1;k++){if(QS[k]>=g)return k;}
 return QS.length-2;
}
var AE={nouser:'Пользователь не найден',badlogin:'Логин: от 3 до 20 символов, только латиница, цифры, точка, дефис и подчёркивание',badpass:'Пароль: от 4 до 32 символов, без символов \\ / : * ? " < > |, без пробела или точки в конце',exists:'Такой логин уже занят',reserved:'Этот логин зарезервирован',folder:'Не удалось переименовать папку (возможно, файл сейчас открыт)',adminfixed:'Администратора нельзя изменить здесь. Логин и пароль задаются в начале файла server.bat',full:'Лимит пользователей',bad:'Ошибка запроса'};
var S=null,loaded=false,uf='',edT=null,cfT=null;
function toast(t){var e=$('toast');e.textContent=t;e.classList.add('on');clearTimeout(toast.t);toast.t=setTimeout(function(){e.classList.remove('on');},2400);}
function dur(sec){var d=Math.floor(sec/86400),hh=Math.floor(sec%86400/3600),m=Math.floor(sec%3600/60);return (d?d+' д ':'')+(hh?hh+' ч ':'')+m+' мин';}
function when(ms){return ms?new Date(ms).toLocaleString('ru-RU',{day:'numeric',month:'short',hour:'2-digit',minute:'2-digit'}):'никогда';}

/* ---------- tabs ---------- */
Array.prototype.forEach.call(document.querySelectorAll('#tabs button'),function(b){
 b.onclick=function(){
  Array.prototype.forEach.call(document.querySelectorAll('#tabs button'),function(x){x.classList.remove('on');});
  Array.prototype.forEach.call(document.querySelectorAll('.sec'),function(x){x.classList.remove('on');});
  b.classList.add('on');$(b.getAttribute('data-t')).classList.add('on');
 };
});

/* ---------- load / render ---------- */
function load(){
 return api('/api/admin/state').then(function(j){
  if(!j.users){location.href='/';return;}
  S=j;render();
  if(!loaded){fillSet(j.set);loaded=true;}
 }).catch(function(){});
}
function render(){
 $('sub').textContent='Онлайн: '+S.online+', пользователей: '+S.users.length;
 stats();pubBox();online();users();noticeBox();logBox();
}
function stats(){
 var items=[['Пользователей',S.users.length],['Сейчас онлайн',S.online],['Занято файлами',sz(S.total)],['Свободно на диске',S.disk>=0?sz(S.disk):'неизвестно'],['Устройств с уведомлениями',S.subs],['Сервер работает',dur(S.up)]];
 var box=$('stats');box.innerHTML='';
 items.forEach(function(it){var d=h('div','st');d.appendChild(h('small','',it[0]));d.appendChild(h('b','',String(it[1])));box.appendChild(d);});
}
function pubBox(){
 $('pub').textContent=S.pub||'недоступна';
 var tmp=S.pub.indexOf('trycloudflare.com')>=0;
 $('pubh').textContent=!S.pub?'Выход в интернет не запущен. Проверьте SRV_TUNNEL=1 в начале server.bat и подключение к интернету.':(S.pub.indexOf('http://')===0?'Прямая ссылка по IP-адресу: работает из любой сети, но без шифрования. IP может смениться после перезагрузки роутера, тогда отправьте друзьям новую ссылку. Если ссылка не открывается с мобильного интернета, провайдер не выдаёт вам публичный IP.':tmp?'Временная ссылка: работает из любой сети, но меняется при каждом перезапуске. Чтобы получить постоянный адрес, заполните SRV_DOMAIN и SRV_CF_TOKEN (свой домен) или включите SRV_TAILSCALE=1 в начале server.bat.':'Постоянная ссылка: работает из любой сети и не меняется после перезапуска. Отправьте её друзьям.');
}
$('cpy').onclick=function(){
 var t=S&&S.pub?S.pub:'';if(!t)return;
 if(navigator.clipboard&&navigator.clipboard.writeText){navigator.clipboard.writeText(t).then(function(){toast('Ссылка скопирована');Snd.ok();},function(){prompt('Скопируйте ссылку',t);});}
 else prompt('Скопируйте ссылку',t);
};
function online(){
 var box=$('onl');box.innerHTML='';
 var L=S.users.filter(function(u){return u.online;});
 if(!L.length){box.appendChild(h('p','mut','Сейчас никого нет.'));return;}
 L.forEach(function(u){var r=h('div','orow');r.appendChild(h('b','',u.login));r.appendChild(h('span','mut',u.ip||''));box.appendChild(r);});
}
function badge(t,c){return h('span','bd '+c,t);}
function users(){
 var box=$('ulist');box.innerHTML='';
 var L=S.users.filter(function(u){return !uf||u.login.toLowerCase().indexOf(uf)>=0;});
 L.sort(function(a,b){return (b.admin-a.admin)||(b.online-a.online)||a.login.localeCompare(b.login);});
 L.forEach(function(u){
  var r=h('div','urow');
  r.appendChild(h('div','ua',u.login.charAt(0).toUpperCase()));
  var inf=h('div','ui');
  var nm=h('div','unm',u.login);
  if(u.admin)nm.appendChild(badge('админ','ac'));
  if(u.online)nm.appendChild(badge('онлайн','gn'));
  if(u.blocked===1)nm.appendChild(badge('заблокирован','rd'));
  if(u.blocked===2)nm.appendChild(badge('ждёт подтверждения','am'));
  inf.appendChild(nm);
  inf.appendChild(h('div','uf','ID: '+u.id+(u.name?', имя: '+u.name:'')));
  inf.appendChild(h('div','uf','Папка: '+u.folder));
  var g=u.admin?0:(u.quota<0?S.set.defQuota:u.quota);
  var qb=g*1073741824;
  inf.appendChild(h('div','umeta',sz(u.used)+(qb>0?' из '+sz(qb):', без ограничений')+'. Заходил(а): '+(u.online?'сейчас':when(u.last))));
  var bar=h('div','mb'),fill=h('i');bar.appendChild(fill);
  var p=qb>0?Math.min(100,u.used*100/qb):0;fill.style.width=p+'%';if(p>90)fill.className='hi';
  inf.appendChild(bar);
  r.appendChild(inf);
  if(!u.admin){
   var bt=h('div','ubtn');
   if(u.blocked===2){
    var ok=h('button','btn pri','Подтвердить');
    ok.onclick=function(){api('/api/admin/user',{act:'update',target:u.login,b:0}).then(function(){Snd.ok();toast('Аккаунт подтверждён');load();});};
    bt.appendChild(ok);
   }
   var ed=h('button','btn','Изменить');ed.onclick=function(){openEd(u);};
   bt.appendChild(ed);r.appendChild(bt);
  }
  box.appendChild(r);
 });
}
$('uq').oninput=function(){uf=this.value.trim().toLowerCase();if(S)users();};

/* ---------- edit dialog ---------- */
function eqUpd(){fillRng($('eq'));$('eql').textContent=$('edef').checked?('как по умолчанию ('+ql(S.set.defQuota)+')'):ql(QS[+$('eq').value]);}
$('eq').oninput=function(){$('edef').checked=false;eqUpd();};
$('edef').onchange=eqUpd;
function eerr(t){var e=$('eerr');if(t){e.textContent=t;e.style.display='block';e.style.animation='none';void e.offsetWidth;e.style.animation='';}else e.style.display='none';}
function openEd(u){
 edT=u?u.login:null;eerr('');
 $('et').textContent=u?('Аккаунт: '+u.login):'Новый аккаунт';
 $('el').value=u?u.login:'';$('ep').value='';
 $('ep').placeholder=u?'Новый пароль (пусто, чтобы не менять)':'Пароль';
 if(u){
  var pre=u.login+'=';
  var pw=u.folder.indexOf(pre)===0?u.folder.substring(pre.length):'';
  $('ecur').textContent='Текущий пароль: '+pw;$('ecur').style.display='block';
 }else $('ecur').style.display='none';
 var def=!u||u.quota<0;
 $('edef').checked=def;
 $('eq').value=qi(def?S.set.defQuota:u.quota);
 $('eb').checked=!!(u&&u.blocked===1);
 $('ebr').style.display=u?'flex':'none';
 $('eextra').style.display=u?'flex':'none';
 eqUpd();
 $('ed').classList.add('on');
}
function closeEd(){$('ed').classList.remove('on');}
$('ecan').onclick=closeEd;
$('ed').onclick=function(e){if(e.target===this)closeEd();};
$('esav').onclick=function(){
 var d={act:edT?'update':'create',target:edT||'',nl:$('el').value.trim(),np:$('ep').value,q:$('edef').checked?'def':QS[+$('eq').value],b:$('eb').checked?1:0};
 api('/api/admin/user',d).then(function(j){
  if(j.ok){Snd.ok();closeEd();toast(edT?'Изменения сохранены':'Аккаунт создан');load();}
  else{Snd.err();eerr(AE[j.err]||'Ошибка');}
 });
};
$('ekick').onclick=function(){
 api('/api/admin/user',{act:'kick',target:edT}).then(function(){Snd.ok();closeEd();toast('Пользователь отключён');load();});
};
$('edel').onclick=function(){
 cfT=edT;$('cfm').textContent='Удалить аккаунт «'+edT+'»? Если не отмечать галочку, файлы сохранятся в папке deleted на компьютере.';
 $('cfwipe').checked=false;closeEd();$('cf').classList.add('on');
};
$('cfn').onclick=function(){$('cf').classList.remove('on');};
$('cfy').onclick=function(){
 api('/api/admin/user',{act:'delete',target:cfT,wipe:$('cfwipe').checked?1:0}).then(function(j){
  $('cf').classList.remove('on');
  if(j.ok){Snd.del();toast('Аккаунт удалён');load();}else{Snd.err();toast(AE[j.err]||'Ошибка');}
 });
};
$('uadd').onclick=function(){openEd(null);};

/* ---------- settings ---------- */
function sqUpd(){fillRng($('s_q'));$('s_ql').textContent=ql(QS[+$('s_q').value]);}
$('s_q').oninput=sqUpd;
function fillSet(s){
 $('s_title').value=s.title;$('s_reg').checked=!!s.reg;$('s_app').checked=!!s.approve;$('s_mnt').checked=!!s.maint;$('s_chat').checked=!!s.chat;
 $('s_q').value=qi(s.defQuota);$('s_mf').value=s.maxFile;$('s_mu').value=s.maxUsers;$('s_rs').value=s.reserve;$('s_be').value=s.badExt;
 sqUpd();
}
$('s_save').onclick=function(){
 api('/api/admin/settings',{
  title:$('s_title').value,reg:$('s_reg').checked?1:0,approve:$('s_app').checked?1:0,maint:$('s_mnt').checked?1:0,chat:$('s_chat').checked?1:0,
  defQuota:QS[+$('s_q').value],maxFile:$('s_mf').value||0,maxUsers:$('s_mu').value||0,reserve:$('s_rs').value||0,badExt:$('s_be').value
 }).then(function(j){if(j.ok){Snd.ok();toast('Настройки сохранены');load();}});
};

/* ---------- notice ---------- */
function noticeBox(){
 var s=S.set;
 $('n_cur').textContent=s.nid?(s.nt+'\n\nОтправлено: '+when(s.ntime)):'Сейчас нет активного оповещения.';
}
$('n_send').onclick=function(){
 var t=$('n_text').value.trim();
 if(!t){Snd.err();toast('Введите текст оповещения');return;}
 api('/api/admin/notice',{act:'send',text:t}).then(function(j){
  if(j.ok){Snd.chime();toast('Оповещение отправлено');$('n_text').value='';load();}
 });
};
$('n_clear').onclick=function(){
 api('/api/admin/notice',{act:'clear'}).then(function(){Snd.ok();toast('Оповещение убрано');load();});
};

/* ---------- log ---------- */
function lt(e){
 var i=e[4];
 var m={login:'вошёл(а) в аккаунт',loginfail:'неудачная попытка входа',register:i==='pending'?'зарегистрировался(ась), ждёт подтверждения':'зарегистрировался(ась)',
  upload:'загрузил(а) файл '+i,'delete':'удалил(а) файл '+i,useredit:'аккаунт «'+i+'» изменён',userdel:'аккаунт «'+i+'» удалён',
  usernew:'создан аккаунт «'+i+'»',kick:'пользователь «'+i+'» отключён',notice:i==='send'?'отправлено оповещение':'оповещение убрано',settings:'настройки изменены',selflogin:'сам(а) сменил(а) логин',nofile:'файл не найден ('+i+')',selfpass:'сам(а) сменил(а) пароль'};
 return m[e[1]]||e[1];
}
function logBox(){
 var box=$('logs');box.innerHTML='';
 if(!S.log.length){box.appendChild(h('p','mut','Событий пока нет.'));return;}
 S.log.forEach(function(e){
  var r=h('div','lrow');
  r.appendChild(h('time','',new Date(e[0]).toLocaleString('ru-RU',{day:'numeric',month:'short',hour:'2-digit',minute:'2-digit',second:'2-digit'})));
  r.appendChild(h('div','',(e[2]?e[2]+': ':'')+lt(e)+(e[3]?' ('+e[3]+')':'')));
  box.appendChild(r);
 });
}

/* ---------- start ---------- */
function sndIcon(){$('snd').innerHTML=ic(Snd.isOn()?'vol':'mute',20);}
$('snd').onclick=function(){Snd.setOn(!Snd.isOn());sndIcon();if(Snd.isOn())Snd.ok();};
Array.prototype.forEach.call(document.querySelectorAll('[data-i]'),function(el){
 el.innerHTML=ic(el.getAttribute('data-i'),parseInt(el.getAttribute('data-s'),10)||20);
});
sndIcon();
load();
setInterval(load,12000);
</script>
</body></html>
'@

# =====================================================================
#  START
# =====================================================================
try {
    Add-Type -TypeDefinition $src -Language CSharp -ReferencedAssemblies @('System.Core', 'System.Drawing', 'System.IO.Compression')

    [FileServer]::PageAuth  = $pAuth.Replace('@@HEAD@@', $head).Replace('@@SND@@', $snd)
    [FileServer]::PageMain  = $pMain.Replace('@@HEAD@@', $head).Replace('@@SND@@', $snd)
    [FileServer]::PageAdmin = $pAdmin.Replace('@@HEAD@@', $head).Replace('@@SND@@', $snd)
    [FileServer]::SwJs      = $sw
    [FileServer]::DirRecv   = 'Полученное'
    [FileServer]::DirChat   = 'Чат'
    [FileServer]::TxtUser   = 'Пользователь'
    [FileServer]::TxtFile   = 'Файл'
    [FileServer]::TxtDir    = 'Папка'
    [FileServer]::TxtNotice = 'Сообщение от администратора'
    [FileServer]::TxtApp    = 'Мои файлы'

    $port = [int]$env:SRV_PORT
    $tunnelUrl = ''
    $cfProc = $null

    # ---- Internet access ----
    # Priority: Cloudflare named tunnel (own domain) -> Tailscale Funnel -> temporary Cloudflare link
    $stable = $false
    $direct = $false
    $natMaps = $null
    if ($env:SRV_TUNNEL -eq '1' -and $env:SRV_DIRECT -ne '1') {
        try {
            $cf = Join-Path $env:SRV_ROOT 'cloudflared.exe'
            $tok = ("" + $env:SRV_CF_TOKEN).Trim()
            $dom = ("" + $env:SRV_DOMAIN).Trim()
            $dom = ($dom -replace '^https?://', '') -replace '/.*$', ''
            $useCf = ($tok.Length -gt 20)
            $tsExe = $null

            if (-not $useCf -and $env:SRV_TAILSCALE -eq '1') {
                foreach ($tp in @(($env:ProgramFiles + '\Tailscale\tailscale.exe'), (${env:ProgramFiles(x86)} + '\Tailscale\tailscale.exe'))) {
                    if (Test-Path $tp) { $tsExe = $tp; break }
                }
                if (-not $tsExe) {
                    $tc = Get-Command tailscale -ErrorAction SilentlyContinue
                    if ($tc) { $tsExe = $tc.Source }
                }
                if (-not $tsExe) {
                    Write-Host 'Tailscale is not installed. Install it from https://tailscale.com/download, log in, and start this file again.' -ForegroundColor Red
                }
            }

            if ($tsExe) {
                # ---------- Tailscale Funnel: free permanent *.ts.net address ----------
                Write-Host 'Starting Tailscale Funnel...' -ForegroundColor Yellow
                $tsLog = Join-Path $env:SRV_ROOT 'tailscale.log'
                $tsErr = Join-Path $env:SRV_ROOT 'tailscale.err.log'
                $tsp = Start-Process -FilePath $tsExe -ArgumentList @('funnel', '--bg', [string]$port) -RedirectStandardOutput $tsLog -RedirectStandardError $tsErr -WindowStyle Hidden -PassThru
                [void]$tsp.WaitForExit(25000)
                if (-not $tsp.HasExited) { try { $tsp.Kill() } catch { } }
                $txt = ('' + (Get-Content $tsLog -Raw -ErrorAction SilentlyContinue)) + ('' + (Get-Content $tsErr -Raw -ErrorAction SilentlyContinue))
                if ($txt -notmatch 'https://[A-Za-z0-9.-]+\.ts\.net') {
                    $old = $ErrorActionPreference
                    $ErrorActionPreference = 'Continue'
                    $txt = $txt + (& $tsExe funnel status 2>&1 | Out-String)
                    $ErrorActionPreference = $old
                }
                if ($txt -match 'https://[A-Za-z0-9.-]+\.ts\.net') {
                    $tunnelUrl = $Matches[0].TrimEnd('/')
                    $stable = $true
                }
                else {
                    Write-Host 'Tailscale Funnel is not ready. In the Tailscale admin console turn on HTTPS Certificates and allow Funnel for this device.' -ForegroundColor Red
                    if ($txt -match 'https://login\.tailscale\.com[^\s]*') { Write-Host ('Open this link to enable it: ' + $Matches[0]) -ForegroundColor Yellow }
                }
            }
            else {
                # ---------- cloudflared: named tunnel (own domain) or temporary link ----------
                if (-not (Test-Path $cf)) {
                    Write-Host 'Downloading cloudflared (one time, about 60 MB)...' -ForegroundColor Yellow
                    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                    $ProgressPreference = 'SilentlyContinue'
                    Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe' -OutFile $cf
                }
                Get-Process cloudflared -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $cf } | Stop-Process -Force -ErrorAction SilentlyContinue
                $log = Join-Path $env:SRV_ROOT 'tunnel.log'
                if (Test-Path $log) { Remove-Item $log -Force -ErrorAction SilentlyContinue }

                if ($useCf) {
                    Write-Host 'Starting your Cloudflare tunnel...' -ForegroundColor Yellow
                    $cfProc = Start-Process -FilePath $cf -ArgumentList @('tunnel', '--no-autoupdate', 'run', '--token', $tok) -RedirectStandardError $log -WindowStyle Hidden -PassThru
                    $connected = $false
                    for ($k = 0; $k -lt 30; $k++) {
                        Start-Sleep -Seconds 1
                        if ($cfProc.HasExited) { break }
                        if (Test-Path $log) {
                            $txt = Get-Content $log -Raw -ErrorAction SilentlyContinue
                            if ($txt -and ($txt -match 'Registered tunnel connection')) { $connected = $true; break }
                        }
                    }
                    if ($connected -or (-not $cfProc.HasExited)) {
                        if ($dom.Length -gt 0) { $tunnelUrl = 'https://' + $dom; $stable = $true }
                        else { Write-Host 'Tunnel is running, but SRV_DOMAIN is empty. Write your domain (for example files.mysite.com) at the top of server.bat.' -ForegroundColor Red }
                        if (-not $connected) { Write-Host 'Tunnel has not confirmed the connection yet. If the site does not open, check the token.' -ForegroundColor Yellow }
                    }
                    else {
                        Write-Host 'Cloudflare tunnel stopped. The token is probably wrong. See tunnel.log in the server folder.' -ForegroundColor Red
                    }
                }
                else {
                    Write-Host 'Starting temporary internet link...' -ForegroundColor Yellow
                    $cfProc = Start-Process -FilePath $cf -ArgumentList @('tunnel', '--url', ('http://127.0.0.1:' + $port), '--no-autoupdate') -RedirectStandardError $log -WindowStyle Hidden -PassThru
                    for ($k = 0; $k -lt 45; $k++) {
                        Start-Sleep -Seconds 1
                        if (Test-Path $log) {
                            $txt = Get-Content $log -Raw -ErrorAction SilentlyContinue
                            if ($txt -and ($txt -match 'https://[a-z0-9-]+\.trycloudflare\.com')) { $tunnelUrl = $Matches[0]; break }
                        }
                    }
                }
            }
        }
        catch {
            Write-Host ('Tunnel error: ' + $_.Exception.Message) -ForegroundColor Red
        }
    }
    # ---- Direct IP link (no domain): public IP + automatic router port opening (UPnP) ----
    if ($env:SRV_DIRECT -eq '1') {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $pubIp = ('' + (Invoke-RestMethod -UseBasicParsing -Uri 'https://api.ipify.org' -TimeoutSec 15)).Trim()
            $cfg = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -ne $null -and $_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1
            $lip = ''
            if ($cfg) { $lip = '' + @($cfg.IPv4Address.IPAddress)[0] }
            $mapped = $false
            try {
                $nat = New-Object -ComObject HNetCfg.NATUpnp
                $natMaps = $nat.StaticPortMappingCollection
                if ($natMaps -ne $null -and $lip -ne '') {
                    try { $natMaps.Remove($port, 'TCP') } catch { }
                    [void]$natMaps.Add($port, 'TCP', $port, $lip, $true, 'PhoneFileServer')
                    $mapped = $true
                }
            }
            catch { $mapped = $false }
            if ($pubIp -match '^\d{1,3}(\.\d{1,3}){3}$') {
                $tunnelUrl = 'http://' + $pubIp + ':' + $port
                $direct = $true
            }
            if ($mapped) { Write-Host 'Router port was opened automatically (UPnP).' -ForegroundColor Green }
            else {
                Write-Host ('Could not open the port automatically. In your router settings forward TCP port ' + $port + ' to this PC (' + $lip + ').') -ForegroundColor Yellow
            }
        }
        catch {
            Write-Host ('Direct IP error: ' + $_.Exception.Message) -ForegroundColor Red
        }
    }
    [FileServer]::PublicUrl = $tunnelUrl

    # ---- Telegram: post the link to a channel; the old message is deleted ----
    $tgToken = ("" + $env:SRV_TG_TOKEN).Trim()
    $tgChat = ("" + $env:SRV_TG_CHAT).Trim()
    $tgState = Join-Path $env:SRV_ROOT 'telegram.txt'
    $tgMsg = ''
    $rsMon = $null
    $tgOn = ($tgToken.Length -gt 10 -and $tgChat.Length -gt 0)
    $tgFn = @'
function Sync-Tg {
    param([string]$token, [string]$chat, [string]$url, [string]$stateFile)
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $api = 'https://api.telegram.org/bot' + $token
        $old = $null
        if (Test-Path $stateFile) {
            $raw = '' + (Get-Content $stateFile -Raw -ErrorAction SilentlyContinue)
            if ($raw.Trim().Length -gt 0) { $old = $raw.Trim().Split('|') }
        }
        if ($old -and $old.Length -ge 3 -and $old[0] -eq $chat -and $old[2] -eq $url) { return 'same' }
        if ($old -and $old.Length -ge 2 -and $old[0] -eq $chat) {
            try {
                $d = ConvertTo-Json -Compress @{ chat_id = $chat; message_id = [int64]$old[1] }
                [void](Invoke-RestMethod -Uri ($api + '/deleteMessage') -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($d)) -TimeoutSec 20)
            }
            catch { }
        }
        $icon = [char]::ConvertFromUtf32(0x1F517)
        $text = $icon + ' Ссылка для подключения:' + "`n" + $url + "`n`n" + 'Обновлено: ' + (Get-Date -Format 'dd.MM.yyyy HH:mm')
        $d = ConvertTo-Json -Compress @{ chat_id = $chat; text = $text; disable_web_page_preview = $true }
        $r = Invoke-RestMethod -Uri ($api + '/sendMessage') -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($d)) -TimeoutSec 20
        if ($r.ok) {
            Set-Content -Path $stateFile -Value ($chat + '|' + $r.result.message_id + '|' + $url) -Encoding ASCII
            return 'sent'
        }
        return 'error: Telegram did not accept the message'
    }
    catch {
        $m = $_.Exception.Message
        try {
            $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())
            $m = $m + ' ' + $sr.ReadToEnd()
        }
        catch { }
        return 'error: ' + $m
    }
}
'@
    if ($tgOn) {
        Invoke-Expression $tgFn
        if ($tunnelUrl -ne '') {
            $res = Sync-Tg $tgToken $tgChat $tunnelUrl $tgState
            if ($res -eq 'sent') { $tgMsg = 'Telegram: the new link was posted and the old message was deleted.' }
            elseif ($res -eq 'same') { $tgMsg = 'Telegram: the link has not changed, nothing to update.' }
            else { $tgMsg = 'Telegram ' + $res + ' (check SRV_TG_TOKEN and SRV_TG_CHAT, and that the bot is an admin of the channel)' }
        }
        else { $tgMsg = 'Telegram: there is no internet link to post yet.' }

        # while the server runs, watch for a changed public IP (direct IP mode) and keep the router port open
        if ($direct) {
            $mon = @'
param($token, $chat, $stateFile, $port, $lip, $fnText)
Invoke-Expression $fnText
$cur = [FileServer]::PublicUrl
while ($true) {
    Start-Sleep -Seconds 300
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $ip = ('' + (Invoke-RestMethod -UseBasicParsing -Uri 'https://api.ipify.org' -TimeoutSec 15)).Trim()
        if ($ip -match '^\d{1,3}(\.\d{1,3}){3}$') {
            try {
                $nat = New-Object -ComObject HNetCfg.NATUpnp
                $maps = $nat.StaticPortMappingCollection
                if ($maps -ne $null -and $lip -ne '') {
                    try { $maps.Remove([int]$port, 'TCP') } catch { }
                    [void]$maps.Add([int]$port, 'TCP', [int]$port, $lip, $true, 'PhoneFileServer')
                }
            }
            catch { }
            $new = 'http://' + $ip + ':' + $port
            if ($new -ne $cur) {
                $cur = $new
                [FileServer]::PublicUrl = $new
                [void](Sync-Tg $token $chat $new $stateFile)
            }
        }
    }
    catch { }
}
'@
            $rsMon = [powershell]::Create()
            [void]$rsMon.AddScript($mon).AddArgument($tgToken).AddArgument($tgChat).AddArgument($tgState).AddArgument([string]$port).AddArgument(("" + $lip)).AddArgument($tgFn)
            [void]$rsMon.BeginInvoke()
        }
    }

    Write-Host '=============================================' -ForegroundColor Cyan
    Write-Host '   FILE SERVER IS RUNNING' -ForegroundColor Cyan
    Write-Host '=============================================' -ForegroundColor Cyan
    Write-Host ''
    if ($tunnelUrl -ne '') {
        Write-Host 'LINK FOR ANY NETWORK (Wi-Fi / mobile internet):' -ForegroundColor Yellow
        Write-Host ('   ' + $tunnelUrl) -ForegroundColor Green
        if ($stable) { Write-Host '   (permanent link, it stays the same after restarts)' }
        elseif ($direct) { Write-Host '   (IP link over plain HTTP. Test it from mobile internet, not from home Wi-Fi. The IP can change; the new one is shown here and in the admin panel.)' }
        else { Write-Host '   (temporary link: it changes every time the server restarts; see SRV_DOMAIN in server.bat for a permanent one)' }
    }
    elseif ($env:SRV_TUNNEL -eq '1') {
        Write-Host 'Internet tunnel did not start. Only the local network link works.' -ForegroundColor Red
    }
    if ($tgMsg -ne '') { Write-Host ''; Write-Host $tgMsg -ForegroundColor Cyan }
    Write-Host ''
    Write-Host 'Home Wi-Fi links:'
    foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($ni.OperationalStatus -ne 'Up') { continue }
        if ($ni.NetworkInterfaceType -eq 'Loopback') { continue }
        foreach ($a in $ni.GetIPProperties().UnicastAddresses) {
            if ($a.Address.AddressFamily -eq 'InterNetwork' -and -not $a.Address.ToString().StartsWith('169.254')) {
                Write-Host ('   http://{0}:{1}    ({2})' -f $a.Address, $port, $ni.Name) -ForegroundColor Green
            }
        }
    }
    Write-Host ''
    Write-Host ('Admin login:    ' + $env:SRV_USER)
    Write-Host ('Admin password: ' + $env:SRV_PASS)
    Write-Host ('User files:     ' + $env:SRV_ROOT + '\users')
    Write-Host ''
    Write-Host 'Close this window to stop the server.' -ForegroundColor Yellow

    try {
        [FileServer]::Run($env:SRV_USER, $env:SRV_PASS, $port, $env:SRV_ROOT)
    }
    finally {
        if ($cfProc -ne $null) { try { if (-not $cfProc.HasExited) { $cfProc.Kill() } } catch { } }
        if ($natMaps -ne $null) { try { $natMaps.Remove($port, 'TCP') } catch { } }
        if ($rsMon -ne $null) { try { $rsMon.Stop() } catch { } }
    }
}
catch {
    Write-Host ''
    Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host 'Maybe the port is busy. Change SRV_PORT at the top of the .bat file.' -ForegroundColor Yellow
}