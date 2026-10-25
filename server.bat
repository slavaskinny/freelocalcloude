@echo off
setlocal EnableExtensions
title Phone to PC File Server

rem ================= SETTINGS =================
set "SRV_USER=iphone"
set "SRV_PASS=2009AZC"
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
using System.Net;
using System.Text;
using System.Threading;
using System.Globalization;
using System.Collections.Generic;
using System.Security.Cryptography;

public class Account
{
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
    public string Ip;
}

public static class FileServer
{
    public static string PageAuth = "", PageMain = "", PageAdmin = "", PublicUrl = "";
    const string DefBad = "exe,msi,bat,cmd,scr,com,vbs,ps1,jar";

    static string adminLogin, root, usersDir, accFile, cfgFile, logFile;
    static Dictionary<string, Account> accs = new Dictionary<string, Account>(StringComparer.OrdinalIgnoreCase);
    static Dictionary<string, Session> sess = new Dictionary<string, Session>();
    static Dictionary<string, string> cfg = new Dictionary<string, string>();
    static Dictionary<string, List<DateTime>> hits = new Dictionary<string, List<DateTime>>();
    static List<string[]> logs = new List<string[]>();
    static object lk = new object();
    static DateTime started = DateTime.Now;
    static DateTime epoch = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);

    // ------------------------------------------------------------ start
    public static void Run(string au, string ap, int port, string r)
    {
        root = r; adminLogin = au;
        usersDir = Path.Combine(r, "users");
        Directory.CreateDirectory(usersDir);
        accFile = Path.Combine(r, "accounts.txt");
        cfgFile = Path.Combine(r, "settings.txt");
        logFile = Path.Combine(r, "log.txt");
        LoadSettings();
        LoadAccounts();
        EnsureAdmin(au, ap);
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

    static string Esc(string s) { return s.Replace("\\", "\\\\").Replace("\r", "").Replace("\n", "\\n"); }
    static string Unesc(string s)
    {
        StringBuilder b = new StringBuilder();
        for (int i = 0; i < s.Length; i++)
        {
            char ch = s[i];
            if (ch == '\\' && i + 1 < s.Length) { i++; b.Append(s[i] == 'n' ? '\n' : s[i]); }
            else b.Append(ch);
        }
        return b.ToString();
    }

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
                      .Append(a.Created).Append('\t').Append(a.Last).Append("\r\n");
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
        if (!File.Exists(accFile)) return;
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
                accs[a.Login] = a;
            }
            catch { }
        }
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
                accs[au] = a;
                // move files from the old single-user version, if present
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
            foreach (string d in Directory.GetDirectories(usersDir))
            {
                foreach (string f in Directory.GetFiles(d, "*.part"))
                {
                    try { if ((DateTime.Now - File.GetLastWriteTime(f)).TotalHours > 24) File.Delete(f); } catch { }
                }
            }
        }
        catch { }
    }

    static string CreateUser(string login, string pw, double quota, int blocked, bool byAdmin)
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
            a.Quota = quota; a.Blocked = blocked; a.Created = NowMs(); a.Last = 0;
            try { Directory.CreateDirectory(FolderPath(a)); } catch { return "folder"; }
            accs[login] = a;
            SaveAccounts();
        }
        return null;
    }

    static void KillSessions(Account a)
    {
        lock (lk)
        {
            List<string> del = new List<string>();
            foreach (KeyValuePair<string, Session> kv in sess) { if (object.ReferenceEquals(kv.Value.Acc, a)) del.Add(kv.Key); }
            foreach (string k in del) sess.Remove(k);
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
            string curPw = CurPw(a);
            string newLogin = nl.Length > 0 ? nl : a.Login;
            string newPw = np.Length > 0 ? np : curPw;
            if (np.Length > 0 && !ValidPass(np)) return "badpass";
            bool loginChanged = !string.Equals(newLogin, a.Login, StringComparison.Ordinal);
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
            if (np.Length > 0) { a.Salt = NewSalt(); a.Hash = HashPw(np, a.Salt); KillSessions(a); }
            if (q == "def") a.Quota = -1;
            else if (q.Length > 0)
            {
                double qv = ParseD(q, double.NaN);
                if (!double.IsNaN(qv)) a.Quota = Math.Max(0.0, qv);
            }
            if (bl == "1") { a.Blocked = 1; KillSessions(a); }
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
            KillSessions(a);
            accs.Remove(a.Login);
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

    static long Used(Account a)
    {
        long t = 0;
        try { foreach (FileInfo f in new DirectoryInfo(FolderPath(a)).GetFiles()) t += f.Length; } catch { }
        return t;
    }

    // ------------------------------------------------------------ sessions
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
        lock (lk) { sess[t] = s; a.Last = NowMs(); }
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

            if (path == "/api/info" && m == "GET") { DoInfo(c); return; }
            if (path == "/api/login" && m == "POST") { DoLogin(c); return; }
            if (path == "/api/register" && m == "POST") { DoRegister(c); return; }
            if (path == "/logout") { DoLogout(c); return; }

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

            if (m == "POST" && c.Request.Headers["X-Req"] != "1") { Json(c, 403, "{\"err\":\"csrf\"}"); return; }

            if (path == "/" && m == "GET") Send(c, 200, "text/html", PageMain);
            else if (path == "/admin" && m == "GET") { if (admin) Send(c, 200, "text/html", PageAdmin); else Redirect(c, "/"); }
            else if (path == "/api/me") DoMe(c, a);
            else if (path == "/api/ping") DoPing(c);
            else if (path == "/list" && m == "GET") DoList(c, a);
            else if (path == "/view" && m == "GET") DoFile(c, a, false);
            else if (path == "/download" && m == "GET") DoFile(c, a, true);
            else if (path == "/upload" && m == "POST") DoUpload(c, a);
            else if (path == "/delete" && m == "POST") DoDelete(c, a);
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
        string err = CreateUser(u, p, -1, approve ? 2 : 0, false);
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
        if (ck != null) { lock (lk) { sess.Remove(ck.Value); } }
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
        sb.Append("\"login\":").Append(Q(a.Login));
        sb.Append(",\"admin\":").Append(IsAdmin(a) ? "1" : "0");
        sb.Append(",\"used\":").Append(Used(a));
        sb.Append(",\"quota\":").Append(QuotaBytes(a));
        sb.Append(",\"title\":").Append(Q(Get("title", "")));
        sb.Append(",\"nid\":").Append(Q(Get("nid", ""))).Append(",\"nt\":").Append(Q(Get("nt", "")));
        sb.Append("}");
        Json(c, 200, sb.ToString());
    }

    static void DoPing(HttpListenerContext c)
    {
        Json(c, 200, "{\"nid\":" + Q(Get("nid", "")) + ",\"nt\":" + Q(Get("nt", "")) + "}");
    }

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

    static string Unique(string dir, string name)
    {
        string full = Path.Combine(dir, name);
        if (!File.Exists(full)) return full;
        string baseName = Path.GetFileNameWithoutExtension(name);
        string ext = Path.GetExtension(name);
        int n = 1;
        while (true)
        {
            full = Path.Combine(dir, baseName + " (" + n + ")" + ext);
            if (!File.Exists(full)) return full;
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

    static void DoList(HttpListenerContext c, Account a)
    {
        DirectoryInfo di = new DirectoryInfo(FolderPath(a));
        FileInfo[] files = di.Exists ? di.GetFiles() : new FileInfo[0];
        Array.Sort(files, delegate(FileInfo x, FileInfo y) { return y.LastWriteTimeUtc.CompareTo(x.LastWriteTimeUtc); });
        StringBuilder sb = new StringBuilder("[");
        bool first = true;
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
        sb.Append(']');
        Json(c, 200, sb.ToString());
    }

    // Chunked upload: each request carries one part of the file (works through the tunnel's body limit).
    static void DoUpload(HttpListenerContext c, Account a)
    {
        bool admin = IsAdmin(a);
        string dir = FolderPath(a);
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
            long reserve = (long)(GetD("reserve", 2) * 1073741824.0);
            try
            {
                DriveInfo di = new DriveInfo(Path.GetPathRoot(root));
                if (di.AvailableFreeSpace - total < reserve) { Json(c, 507, "{\"err\":\"disk\"}"); return; }
            }
            catch { }
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
        if (last)
        {
            string final;
            lock (lk)
            {
                final = Unique(dir, name);
                File.Move(part, final);
            }
            Log("upload", a.Login, Ip(c), Path.GetFileName(final));
        }
        Json(c, 200, "{\"ok\":1,\"id\":" + Q(id) + "}");
    }

    // Serves a file inline (preview) or as attachment. Supports Range requests (video seeking).
    static void DoFile(HttpListenerContext c, Account a, bool download)
    {
        string name = Safe(c.Request.QueryString["name"]);
        string full = Path.Combine(FolderPath(a), name);
        if (!File.Exists(full)) { Send(c, 404, "text/plain", "Not found"); return; }

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
        c.Response.AddHeader("Content-Disposition", (download ? "attachment" : "inline") + "; filename*=UTF-8''" + Uri.EscapeDataString(name));
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

    static void DoDelete(HttpListenerContext c, Account a)
    {
        string name = Safe(c.Request.QueryString["name"]);
        string full = Path.Combine(FolderPath(a), name);
        try { if (File.Exists(full)) { File.Delete(full); Log("delete", a.Login, Ip(c), name); } } catch { }
        Json(c, 200, "{\"ok\":1}");
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
                Put("maxUsers", Dbl(Math.Max(0.0, ParseD(V(f, "maxUsers"), 0))));
                Put("defQuota", Dbl(Math.Max(0.0, ParseD(V(f, "defQuota"), 5))));
                Put("maxFile", Dbl(Math.Max(0.0, ParseD(V(f, "maxFile"), 0))));
                Put("reserve", Dbl(Math.Max(0.0, ParseD(V(f, "reserve"), 2))));
                Put("badExt", CleanExt(V(f, "badExt")));
                SaveSettings();
            }
            Log("settings", me.Login, ip, "");
            Json(c, 200, "{\"ok\":1}");
            return;
        }

        if (path == "/api/admin/notice")
        {
            string act = V(f, "act");
            lock (lk)
            {
                if (act == "send")
                {
                    string t = Trunc(V(f, "text").Trim(), 500);
                    if (t.Length == 0) { Json(c, 200, "{\"err\":\"empty\"}"); return; }
                    Put("nid", NowMs().ToString());
                    Put("nt", t);
                    Put("ntime", NowMs().ToString());
                }
                else { Put("nid", ""); Put("nt", ""); Put("ntime", "0"); }
                SaveSettings();
            }
            Log("notice", me.Login, ip, act == "send" ? "send" : "clear");
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
                lock (lk) { Account a; if (accs.TryGetValue(target, out a) && !IsAdmin(a)) KillSessions(a); }
            }
            else if (act == "create")
            {
                kind = "usernew";
                string q = V(f, "q");
                double qv = ParseD(q, double.NaN);
                double quota = (q == "def" || double.IsNaN(qv)) ? -1 : Math.Max(0.0, qv);
                err = CreateUser(V(f, "nl").Trim(), V(f, "np"), quota, 0, true);
                target = V(f, "nl").Trim();
            }
            else err = "bad";
            if (err == null) Log(kind, me.Login, ip, target);
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

            sb.Append(",\"set\":{\"title\":").Append(Q(Get("title", "")));
            sb.Append(",\"reg\":").Append(Get("reg", "1") == "1" ? "1" : "0");
            sb.Append(",\"approve\":").Append(Get("approve", "0") == "1" ? "1" : "0");
            sb.Append(",\"maint\":").Append(Get("maint", "0") == "1" ? "1" : "0");
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
                sb.Append("[").Append(e[0]).Append(",").Append(Q(e[1])).Append(",").Append(Q(e[2])).Append(",").Append(Q(e[3])).Append(",").Append(Q(e[4])).Append("]");
            }
            sb.Append("]}");
        }
        Json(c, 200, sb.ToString());
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

    static void Json(HttpListenerContext c, int code, string json) { Send(c, code, "application/json", json); }
}
'@

# =====================================================================
#  WEB PAGES (Russian UI)
# =====================================================================

$head = @'
<meta charset='utf-8'>
<meta name='viewport' content='width=device-width,initial-scale=1'>
<meta name='color-scheme' content='dark'>
<meta name='theme-color' content='#12151c'>
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
  chime:p(function(){tone(523.25,0,1.6,0.07);tone(659.25,0.2,1.6,0.06);tone(783.99,0.4,2.0,0.055);tone(1046.5,0.4,1.4,0.02);})
 };
})();
document.addEventListener('pointerdown',function(e){
 Snd.unlock();
 var t=e.target;
 if(t&&t.closest&&t.closest('button,a,label,.th,.meta,.urow,.tabs button'))Snd.click();
},true);
'@

# ------------------------------------------------------------ AUTH PAGE
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
<label class='fld'><input class='in' id='ru' type='text' placeholder='Придумайте логин' autocomplete='username' autocapitalize='none' autocorrect='off' required></label>
<label class='fld'><input class='in' id='rp' type='password' placeholder='Пароль' autocomplete='new-password' required><button type='button' class='eye' data-e='rp'>Показать</button></label>
<label class='fld'><input class='in' id='rp2' type='password' placeholder='Повторите пароль' autocomplete='new-password' required></label>
<p class='note'>Администратор хранит логин и пароль в названии вашей папки, чтобы помочь восстановить доступ. Не используйте пароль от почты, соцсетей и банков.</p>
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
 api('/api/register',{u:$('ru').value.trim(),p:$('rp').value}).then(function(j){
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

# ------------------------------------------------------------ MAIN PAGE
$pMain = @'
<!DOCTYPE html><html lang='ru'><head><title>Мои файлы</title>@@HEAD@@
<style>
.bar{position:sticky;top:0;z-index:20;background:rgba(18,21,28,.82);backdrop-filter:blur(14px);-webkit-backdrop-filter:blur(14px);border-bottom:1px solid var(--ln)}
.bar-in{max-width:1000px;margin:0 auto;padding:12px 16px;display:flex;align-items:center;justify-content:space-between;gap:12px}
.brand{display:flex;align-items:center;gap:12px;min-width:0}
.mark{width:40px;height:40px;border-radius:12px;display:grid;place-items:center;background:var(--ac);color:#0c1220;flex:none}
.brand b{display:block;font-size:17px;font-weight:650;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.brand small{color:var(--mu);font-size:13px}
.hact{display:flex;align-items:center;gap:8px;flex:none}
.out{color:var(--mu);text-decoration:none;padding:8px 14px;border:1px solid var(--ln);border-radius:999px;font-size:14px;transition:background .2s,color .2s}
.out:hover{color:var(--tx);background:var(--sf)}
.wrap{max-width:1000px;margin:0 auto;padding:16px 16px 60px}
.meter{background:var(--sf);border:1px solid var(--ln);border-radius:14px;padding:12px 14px;margin-bottom:12px}
.mt{display:flex;justify-content:space-between;gap:10px;font-size:14px;margin-bottom:8px}
.mb{height:6px;border-radius:6px;background:var(--sf2);overflow:hidden}
.mb i{display:block;height:100%;width:0;background:var(--ac);border-radius:6px;transition:width .5s}
.mb i.hi{background:var(--rd)}
.drop{display:flex;flex-direction:column;align-items:center;gap:4px;padding:24px 16px;border:1.5px dashed var(--ln);border-radius:18px;background:var(--sf);cursor:pointer;text-align:center;transition:border-color .25s,background .25s}
.drop:hover,.drop.hot{border-color:var(--ac);background:#1b2336}
.drop svg{color:var(--ac);transition:transform .25s}
.drop:hover svg,.drop.hot svg{transform:translateY(-3px)}
.drop b{font-weight:600;margin-top:4px}
.drop span{color:var(--mu);font-size:14px}
.drop input{display:none}
.up{margin-top:10px;padding:11px 14px;background:var(--sf);border:1px solid var(--ln);border-radius:12px;font-size:14px;animation:rise .3s both;transition:opacity .35s,transform .35s}
.up.gone{opacity:0;transform:translateY(-6px)}
.ut{display:flex;justify-content:space-between;gap:10px}
.un{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0}
.pc{color:var(--mu);font-size:13px;text-align:right;flex:none;max-width:60%}
.pb{margin-top:8px;height:5px;border-radius:6px;background:var(--sf2);overflow:hidden}
.pb i{display:block;height:100%;width:0;background:var(--ac);border-radius:6px;transition:width .2s}
.up.ok .pc{color:var(--gn)}.up.ok .pb i{background:var(--gn)}
.up.bad .pc{color:var(--rd)}.up.bad .pb i{background:var(--rd)}
.tools{display:flex;flex-wrap:wrap;gap:10px;align-items:center;justify-content:space-between;margin:22px 0 14px}
.tabs{display:flex;gap:6px;overflow-x:auto;max-width:100%;scrollbar-width:none}
.tabs::-webkit-scrollbar{display:none}
.tabs button{padding:8px 15px;border-radius:999px;background:var(--sf);color:var(--mu);font-size:14px;white-space:nowrap;border:1px solid var(--ln);transition:background .2s,color .2s,border-color .2s}
.tabs button.on{background:var(--ac);color:#0c1220;border-color:var(--ac);font-weight:600}
#q{flex:1;min-width:150px;max-width:280px;width:auto;border-radius:999px;padding:9px 16px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:12px}
.card{background:var(--sf);border:1px solid var(--ln);border-radius:14px;overflow:hidden;transition:transform .2s,opacity .28s,border-color .2s}
.card.in{animation:rise .4s both}
.card:hover{transform:translateY(-2px);border-color:#3a4458}
.card.gone{opacity:0;transform:scale(.92)}
.th{position:relative;width:100%;padding-top:100%;background:#151a24;cursor:pointer;overflow:hidden}
.th>img,.th>video,.th>.ico{position:absolute;top:0;left:0;width:100%;height:100%;object-fit:cover;transition:transform .35s}
.card:hover .th>img,.card:hover .th>video{transform:scale(1.04)}
.ico{display:flex;flex-direction:column;align-items:center;justify-content:center;gap:8px;color:#9db6f5}
.ico.k-pdf{color:#f2a0a0}.ico.k-text{color:#9ee0b4}.ico.k-audio{color:#cfb0f5}
.ico i{font-style:normal;font-size:13px;color:var(--mu)}
.pl{position:absolute;left:8px;bottom:8px;width:28px;height:28px;border-radius:50%;display:grid;place-items:center;background:rgba(0,0,0,.6);color:#fff;pointer-events:none}
.ac{position:absolute;top:8px;right:8px;display:flex;gap:6px;z-index:2}
.meta{padding:10px 12px 11px;cursor:pointer}
.nm{font-size:14px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.sub{color:var(--mu);font-size:12.5px;margin-top:2px}
.ib{width:38px;height:38px;border-radius:50%;display:grid;place-items:center;background:rgba(18,21,28,.72);color:var(--tx);transition:background .2s,color .2s,transform .1s;text-decoration:none;flex:none}
.ib:hover{background:var(--sf2)}
.ib:active{transform:scale(.92)}
.ib.sm{width:30px;height:30px}
.ib.red:hover{background:var(--rd);color:#1a0b0b}
.ib.off{opacity:.3;pointer-events:none}
.hact .ib{background:var(--sf);border:1px solid var(--ln)}
.empty{display:none;text-align:center;color:var(--mu);padding:56px 0}
.empty.on{display:block;animation:fade .4s}
.ntc{position:fixed;top:12px;left:12px;right:12px;max-width:520px;margin:0 auto;z-index:45;display:flex;gap:12px;align-items:flex-start;background:var(--sf2);border:1px solid var(--ac);border-radius:16px;padding:14px;box-shadow:0 12px 40px rgba(0,0,0,.5);transform:translateY(-150%);opacity:0;transition:transform .5s cubic-bezier(.2,.9,.3,1),opacity .35s}
.ntc.on{transform:none;opacity:1}
.ni{color:var(--ac);flex:none;margin-top:2px}
.nx{min-width:0;flex:1}
.nx b{font-size:15px}
.nx p{margin:4px 0 12px;line-height:1.45;word-break:break-word;white-space:pre-wrap}
.nx .btn{padding:9px 18px}
.vw{position:fixed;top:0;left:0;right:0;bottom:0;z-index:50;background:rgba(8,10,15,.96);opacity:0;visibility:hidden;transition:opacity .25s,visibility .25s}
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
body.lock{overflow:hidden}
</style></head><body>
<header class='bar'><div class='bar-in'>
<div class='brand'><div class='mark' data-i='folder' data-s='22'></div><div style='min-width:0'><b id='ttl'>Мои файлы</b><small id='who'></small></div></div>
<div class='hact'>
<button class='ib' id='snd' title='Звуки интерфейса'></button>
<a class='ib' id='adm' href='/admin' title='Админ-панель' style='display:none' data-i='sliders' data-s='20'></a>
<a class='out' href='/logout'>Выйти</a>
</div>
</div></header>

<div class='ntc' id='ntc'>
<div class='ni' data-i='bell' data-s='22'></div>
<div class='nx'><b>Сообщение от администратора</b><p id='ntx'></p><button class='btn pri' id='nok'>Понятно</button></div>
</div>

<main class='wrap'>
<div class='meter'><div class='mt'><span id='mtx'>Загрузка...</span><span id='mpc'></span></div><div class='mb'><i id='mbar'></i></div></div>
<label class='drop' id='drop'>
<input type='file' id='f' multiple>
<div data-i='up' data-s='30'></div>
<b>Выбрать файлы для отправки</b>
<span>Фото, видео и документы. Загрузка начнётся сразу.</span>
</label>
<div id='queue'></div>
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
<div class='empty' id='empty'>Здесь пока пусто. Отправьте файл с телефона, и он появится здесь.</div>
</main>

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

<div class='dlg' id='dlg'><div class='dbox'>
<p id='dmsg'></p>
<div class='drow'><button class='btn' id='dno'>Отмена</button><button class='btn red' id='dok'>Удалить</button></div>
</div></div>
<div class='toast' id='toast'></div>

<script>
@@SND@@
var me={login:'',admin:0,used:0,quota:0},files=[],view=[],cur=-1,filt='all',qs='',seq=0,isOpen=false,hs=true,ct=null,tt=null,busy=false,pending=[],seenN='',curN='';
try{seenN=localStorage.getItem('nseen')||'';}catch(e){}
var P={
 dl:'M12 4v11m0 0l-4-4m4 4l4-4M5 20h14',
 tr:'M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13M10 11v6M14 11v6',
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
 bell:'M6 9a6 6 0 1112 0c0 5 2 6 2 6H4s2-1 2-6zM10 19a2 2 0 004 0'
};
function ic(n,s){s=s||20;return `<svg viewBox='0 0 24 24' width='${s}' height='${s}' fill='none' stroke='currentColor' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><path d='${P[n]}'/></svg>`;}
function dt(t){return new Date(t).toLocaleDateString('ru-RU',{day:'numeric',month:'short',year:'numeric'});}
function U(n){return '/view?name='+encodeURIComponent(n);}
function D(n){return '/download?name='+encodeURIComponent(n);}
function toast(t){var e=$('toast');e.textContent=t;e.classList.add('on');clearTimeout(tt);tt=setTimeout(function(){e.classList.remove('on');},2600);}
function ask(msg,ok){
 $('dmsg').textContent=msg;$('dlg').classList.add('on');
 $('dok').onclick=function(){$('dlg').classList.remove('on');ok();};
}
$('dno').onclick=function(){$('dlg').classList.remove('on');};
$('dlg').onclick=function(e){if(e.target===this)this.classList.remove('on');};

/* ---------- account, storage meter, notices ---------- */
function meter(){
 var u=me.used,q=me.quota;
 $('mtx').textContent=q>0?('Занято '+sz(u)+' из '+sz(q)):('Занято '+sz(u)+', без ограничений');
 var p=q>0?Math.min(100,u*100/q):0;
 $('mbar').style.width=p+'%';
 $('mbar').className=p>90?'hi':'';
 $('mpc').textContent=q>0?Math.round(p)+'%':'\u221e';
}
function loadMe(){
 return api('/api/me').then(function(j){
  me=j;
  $('who').textContent=j.login;
  if(j.title){$('ttl').textContent=j.title;document.title=j.title;}
  $('adm').style.display=j.admin?'grid':'none';
  meter();notice(j.nid,j.nt);
 }).catch(function(){});
}
function hideN(){$('ntc').classList.remove('on');}
function notice(id,t){
 if(!id){if(curN){curN='';hideN();}return;}
 if(id===seenN||id===curN)return;
 curN=id;$('ntx').textContent=t;$('ntc').classList.add('on');Snd.chime();
}
$('nok').onclick=function(){
 seenN=curN;try{localStorage.setItem('nseen',curN);}catch(e){}
 hideN();
};
function ping(){api('/api/ping').then(function(j){notice(j.nid,j.nt);}).catch(function(){});}
setInterval(ping,10000);

/* ---------- list ---------- */
function load(anim){
 return api('/list').then(function(j){files=j;render(anim);}).catch(function(){});
}
function iconBox(f){
 var d=document.createElement('div');d.className='ico k-'+f.k;
 d.innerHTML=ic(f.k==='audio'?'music':'file',38)+'<i></i>';
 d.lastChild.textContent=f.e?'.'+f.e:'файл';
 return d;
}
function render(anim){
 var cn=(isOpen&&view[cur])?view[cur].n:null;
 view=files.filter(function(f){
  if(filt==='doc'){if(f.k==='image'||f.k==='video'||f.k==='audio')return false;}
  else if(filt!=='all'&&f.k!==filt)return false;
  if(qs&&f.n.toLowerCase().indexOf(qs)<0)return false;
  return true;
 });
 if(cn){for(var k=0;k<view.length;k++){if(view[k].n===cn){cur=k;break;}}}
 var g=$('grid');g.innerHTML='';
 view.forEach(function(f,i){g.appendChild(card(f,i,anim));});
 $('empty').classList.toggle('on',view.length===0);
}
function card(f,i,anim){
 var c=document.createElement('div');c.className='card'+(anim?' in':'');
 if(anim)c.style.animationDelay=Math.min(i,14)*28+'ms';
 var th=document.createElement('div');th.className='th';
 if(f.k==='image'){
  var im=document.createElement('img');im.loading='lazy';im.decoding='async';im.alt='';im.src=U(f.n);
  im.onerror=function(){th.replaceChild(iconBox(f),im);};
  th.appendChild(im);
 }else if(f.k==='video'){
  var v=document.createElement('video');v.preload='metadata';v.muted=true;v.setAttribute('playsinline','');v.src=U(f.n)+'#t=0.1';
  th.appendChild(v);
  th.insertAdjacentHTML('beforeend',`<span class='pl'>${ic('play',14)}</span>`);
 }else{
  th.appendChild(iconBox(f));
 }
 th.onclick=function(){openV(i);};
 var ac=document.createElement('div');ac.className='ac';
 var a=document.createElement('a');a.className='ib sm';a.href=D(f.n);a.title='Скачать';a.innerHTML=ic('dl',15);
 a.onclick=function(e){e.stopPropagation();};
 var b=document.createElement('button');b.className='ib sm red';b.title='Удалить';b.innerHTML=ic('tr',15);
 b.onclick=function(e){e.stopPropagation();del(f,c);};
 ac.appendChild(a);ac.appendChild(b);th.appendChild(ac);
 var m=document.createElement('div');m.className='meta';
 var nm=document.createElement('div');nm.className='nm';nm.textContent=f.n;nm.title=f.n;
 var sb=document.createElement('div');sb.className='sub';sb.textContent=sz(f.s)+', '+dt(f.t);
 m.appendChild(nm);m.appendChild(sb);
 m.onclick=th.onclick;
 c.appendChild(th);c.appendChild(m);
 return c;
}
function del(f,c){
 ask('Удалить файл «'+f.n+'»?',function(){
  var x=new XMLHttpRequest();
  x.open('POST','/delete?name='+encodeURIComponent(f.n));
  x.setRequestHeader('X-Req','1');
  x.onload=function(){Snd.del();c.classList.add('gone');setTimeout(function(){load(false);loadMe();toast('Файл удалён');},280);};
  x.send();
 });
}

/* ---------- chunked upload ---------- */
var CH=8*1024*1024;
var UE={offline:'Сервер выключен',quota:'Не хватает места в вашем хранилище',toobig:'Файл больше разрешённого размера',ext:'Этот тип файлов запрещён',disk:'На сервере закончилось место',bad:'Ошибка запроса',offset:'Сбой передачи, попробуйте ещё раз'};
function upload(list){
 for(var i=0;i<list.length;i++)pending.push(list[i]);
 if(!busy)nextUp();
}
function nextUp(){
 if(!pending.length){busy=false;return;}
 busy=true;
 var file=pending.shift();
 var row=document.createElement('div');row.className='up';
 var top=document.createElement('div');top.className='ut';
 var un=document.createElement('div');un.className='un';un.textContent=file.name;
 var pc=document.createElement('div');pc.className='pc';pc.textContent='0%';
 top.appendChild(un);top.appendChild(pc);
 var pb=document.createElement('div');pb.className='pb';
 var bi=document.createElement('i');pb.appendChild(bi);
 row.appendChild(top);row.appendChild(pb);
 $('queue').appendChild(row);
 var total=file.size,off=0,id='';
 function fin(ok,label){
  row.classList.add(ok?'ok':'bad');pc.textContent=label;
  if(ok){bi.style.width='100%';Snd.ok();load(false);loadMe();}else Snd.err();
  setTimeout(function(){row.classList.add('gone');setTimeout(function(){if(row.parentNode)row.parentNode.removeChild(row);},380);},ok?1600:6000);
  nextUp();
 }
 function step(tries){
  var end=Math.min(off+CH,total),last=end>=total;
  var x=new XMLHttpRequest();
  x.open('POST','/upload');
  x.setRequestHeader('X-Req','1');
  x.setRequestHeader('X-Name',encodeURIComponent(file.name));
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
    if(last)fin(true,'Готово');else step(3);
   }else if(x.status===401){location.href='/';}
   else fin(false,UE[j.err]||('Ошибка '+x.status));
  };
  x.onerror=function(){
   if(tries>0)setTimeout(function(){step(tries-1);},1500);
   else fin(false,'Нет связи');
  };
  x.send(file.slice(off,end));
 }
 step(3);
}
$('f').onchange=function(){
 var arr=Array.prototype.slice.call(this.files);
 this.value='';
 upload(arr);
};
var dr=$('drop');
['dragenter','dragover'].forEach(function(n){dr.addEventListener(n,function(e){e.preventDefault();dr.classList.add('hot');});});
['dragleave','drop'].forEach(function(n){dr.addEventListener(n,function(e){e.preventDefault();dr.classList.remove('hot');});});
dr.addEventListener('drop',function(e){upload(Array.prototype.slice.call(e.dataTransfer.files));});

/* ---------- filters ---------- */
Array.prototype.forEach.call(document.querySelectorAll('#tabs button'),function(b){
 b.onclick=function(){
  Array.prototype.forEach.call(document.querySelectorAll('#tabs button'),function(x){x.classList.remove('on');});
  b.classList.add('on');filt=b.getAttribute('data-k');render(true);
 };
});
$('q').oninput=function(){qs=this.value.trim().toLowerCase();render(false);};

/* ---------- viewer ---------- */
function stopMedia(){
 var m=$('vbody').querySelectorAll('video,audio');
 for(var i=0;i<m.length;i++){try{m[i].pause();m[i].removeAttribute('src');m[i].load();}catch(e){}}
}
function dlBtn(f){var a=document.createElement('a');a.className='btn pri';a.href=D(f.n);a.textContent='Скачать';return a;}
function big(f,icon){
 var d=document.createElement('div');d.className='big';
 d.innerHTML=ic(icon,64)+'<i></i>';
 d.lastChild.textContent=f.e?'.'+f.e:'файл';
 return d;
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
 var f=view[cur];if(!f)return;
 var tok=++seq;
 stopMedia();
 var b=$('vbody');b.innerHTML='';
 $('vname').textContent=f.n;
 $('vcount').textContent=(cur+1)+' из '+view.length+', '+sz(f.s);
 $('vdl').href=D(f.n);
 $('vprev').classList.toggle('off',cur<=0);
 $('vnext').classList.toggle('off',cur>=view.length-1);
 var w=document.createElement('div');w.className='vc';b.appendChild(w);
 if(f.k==='image'){
  var im=document.createElement('img');im.alt='';im.src=U(f.n);
  im.onclick=function(e){zoom(w,im,e);};
  im.onerror=function(){w.innerHTML='';w.appendChild(big(f,'file'));var p=document.createElement('p');p.className='mut';p.textContent='Этот формат изображения нельзя показать в браузере.';w.appendChild(p);w.appendChild(dlBtn(f));};
  w.appendChild(im);
 }else if(f.k==='video'){
  var v=document.createElement('video');
  v.controls=true;v.setAttribute('playsinline','');v.preload='auto';v.src=U(f.n);
  v.onerror=function(){
   if(w.querySelector('.fb'))return;
   var p=document.createElement('div');p.className='fb';
   p.innerHTML=`<p class='mut'>Этот формат видео не воспроизводится в браузере.</p>`;
   p.appendChild(dlBtn(f));w.appendChild(p);
  };
  w.appendChild(v);
  var pr=v.play();if(pr&&pr.catch)pr.catch(function(){});
 }else if(f.k==='audio'){
  w.appendChild(big(f,'music'));
  var au=document.createElement('audio');au.controls=true;au.src=U(f.n);
  w.appendChild(au);
  var pa=au.play();if(pa&&pa.catch)pa.catch(function(){});
 }else if(f.k==='pdf'){
  var fr=document.createElement('iframe');fr.src=U(f.n);
  w.appendChild(fr);
  var o=document.createElement('a');o.className='btn';o.target='_blank';o.href=U(f.n);o.textContent='Открыть в новой вкладке';o.style.marginTop='10px';
  w.appendChild(o);
 }else if(f.k==='text'){
  var pre=document.createElement('pre');pre.textContent='Загрузка...';w.appendChild(pre);
  fetch(U(f.n),{headers:{'Range':'bytes=0-200000'},credentials:'same-origin'}).then(function(r){return r.text();}).then(function(t){
   if(tok!==seq)return;
   pre.textContent=t+(f.s>200001?'\n\n(Показано начало файла. Скачайте файл, чтобы прочитать его полностью.)':'');
  }).catch(function(){if(tok===seq)pre.textContent='Не удалось загрузить файл.';});
 }else{
  w.appendChild(big(f,'file'));
  var p2=document.createElement('p');p2.className='mut';p2.textContent='Для этого типа файлов нет предпросмотра.';
  w.appendChild(p2);w.appendChild(dlBtn(f));
 }
}
function openV(i){
 cur=i;clearTimeout(ct);
 $('vw').classList.add('on');document.body.classList.add('lock');
 if(!isOpen){isOpen=true;hs=true;Snd.open();try{history.pushState({v:1},'');}catch(e){hs=false;}}
 show();
}
function doClose(){
 isOpen=false;seq++;stopMedia();
 $('vw').classList.remove('on');document.body.classList.remove('lock');
 cur=-1;
 ct=setTimeout(function(){$('vbody').innerHTML='';},280);
}
function closeV(){
 if(!isOpen)return;
 if(hs){try{history.back();}catch(e){doClose();}}else doClose();
}
function go(d){var n=cur+d;if(n<0||n>=view.length)return;cur=n;show();}
window.addEventListener('popstate',function(){if(isOpen)doClose();});
$('vx').onclick=closeV;
$('vprev').onclick=function(){go(-1);};
$('vnext').onclick=function(){go(1);};
document.addEventListener('keydown',function(e){
 if(!isOpen)return;
 if(e.key==='Escape')closeV();
 else if(e.key==='ArrowLeft')go(-1);
 else if(e.key==='ArrowRight')go(1);
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

/* ---------- sound button + start ---------- */
function sndIcon(){$('snd').innerHTML=ic(Snd.isOn()?'vol':'mute',20);}
$('snd').onclick=function(){Snd.setOn(!Snd.isOn());sndIcon();if(Snd.isOn())Snd.ok();};
Array.prototype.forEach.call(document.querySelectorAll('[data-i]'),function(el){
 el.innerHTML=ic(el.getAttribute('data-i'),parseInt(el.getAttribute('data-s'),10)||20);
});
sndIcon();
loadMe();
load(true);
</script>
</body></html>
'@

# ------------------------------------------------------------ ADMIN PAGE
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
 var items=[['Пользователей',S.users.length],['Сейчас онлайн',S.online],['Занято файлами',sz(S.total)],['Свободно на диске',S.disk>=0?sz(S.disk):'неизвестно'],['Сервер работает',dur(S.up)]];
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
 $('s_title').value=s.title;$('s_reg').checked=!!s.reg;$('s_app').checked=!!s.approve;$('s_mnt').checked=!!s.maint;
 $('s_q').value=qi(s.defQuota);$('s_mf').value=s.maxFile;$('s_mu').value=s.maxUsers;$('s_rs').value=s.reserve;$('s_be').value=s.badExt;
 sqUpd();
}
$('s_save').onclick=function(){
 api('/api/admin/settings',{
  title:$('s_title').value,reg:$('s_reg').checked?1:0,approve:$('s_app').checked?1:0,maint:$('s_mnt').checked?1:0,
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
  usernew:'создан аккаунт «'+i+'»',kick:'пользователь «'+i+'» отключён',notice:i==='send'?'отправлено оповещение':'оповещение убрано',settings:'настройки изменены'};
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
    Add-Type -TypeDefinition $src -Language CSharp

    [FileServer]::PageAuth  = $pAuth.Replace('@@HEAD@@', $head).Replace('@@SND@@', $snd)
    [FileServer]::PageMain  = $pMain.Replace('@@HEAD@@', $head).Replace('@@SND@@', $snd)
    [FileServer]::PageAdmin = $pAdmin.Replace('@@HEAD@@', $head).Replace('@@SND@@', $snd)

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
    }
}
catch {
    Write-Host ''
    Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host 'Maybe the port is busy. Change SRV_PORT at the top of the .bat file.' -ForegroundColor Yellow
}
