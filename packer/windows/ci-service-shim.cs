// The generic service host baked at C:\ci\bin\ci-service-shim.exe.
//
// WHY THIS EXISTS AT ALL
//
// A PowerShell script cannot be a Windows service. The service control manager
// expects SERVICE_RUNNING to be reported inside its start timeout, and
// `powershell.exe -File` never reports it, so the SCM kills the process and
// reports a start failure that looks nothing like its cause. Something has to
// answer the SCM and supervise the real process; on Linux that thing is systemd
// and it is already installed.
//
// It is a CONVENIENCE, NOT A SAFETY BOUNDARY. Section 3A of
// docs/adr-windows-pool.md retired the reason this shim was originally
// justified by -- the metadata fence exempted processes by service SID, and a
// scheduled task has no SID to exempt. That fence does not exist. What is left
// is lifecycle: SCM start/stop, a restart policy the SCM applies, and a
// per-service environment block. Review it as such; nothing here contains a
// security property.
//
// WHY IT IS COMPILED AT IMAGE BUILD FROM THE IN-BOX COMPILER
//
// The alternative is a third-party binary fetched at boot or vendored into this
// repository, and an executable that every CI host on the fleet runs as
// LocalSystem is the last thing that should arrive through a channel nobody in
// this repository reviews. csc.exe ships with the .NET Framework that is part of
// Windows Server, so the artifact is built from the source in this file, in the
// image, once, and the source is what review sees.
//
// THE CONFIG FORMAT IS NOT NEGOTIABLE HERE
//
// modules/ci-runner-host-pool/scripts/windows-host-startup.ps1 WRITES these
// documents (Get-BeaconServiceConfig, Get-BrokerServiceConfig) and this file
// READS them. The element names below are that contract, and this side does not
// get to rename one: an image and a boot script disagreeing about an element
// name is a service that installs and never starts.
//
//   <service>
//     <id>            service name (SCM key)                        required
//     <name>          display name                                  required
//     <description>   SCM description                               optional
//     <executable>    the child process to run                      required
//     <arguments>     its command line, verbatim                    optional
//     <env name= value= />  per-service environment, repeatable     optional
//     <startmode>     Automatic | Manual | Disabled                 optional
//     <onfailure action="restart" delay="10 sec"/>  repeatable, x3   optional
//     <resetfailure>  "1 hour" | "3600 sec"                         optional
//     <log mode="roll-by-size"><sizeThreshold>KB</sizeThreshold>
//          <keepFiles>N</keepFiles></log>                           optional
//
// USAGE
//   ci-service-shim.exe install <config.xml>   -- register or reconfigure
//   ci-service-shim.exe run     <config.xml>   -- what the SCM invokes
//
// `install` IS IDEMPOTENT AND THAT IS A REQUIREMENT, NOT A COURTESY. Windows
// hosts reboot for updates, the boot script runs again on every boot, and it
// calls `install` unconditionally. A shim that failed on "service already
// exists" would turn every patch reboot into a host that never registers.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.ServiceProcess;
using System.Text;
using System.Xml;

internal sealed class ServiceDefinition
{
    public string Id = "";
    public string DisplayName = "";
    public string Description = "";
    public string Executable = "";
    public string Arguments = "";
    public string StartMode = "Automatic";
    public int RestartDelaySeconds = 10;
    public int RestartActions;
    public int ResetFailureSeconds = 3600;
    public int LogSizeThresholdKb = 10240;
    public int LogKeepFiles = 2;
    public readonly List<KeyValuePair<string, string>> Environment =
        new List<KeyValuePair<string, string>>();

    public static ServiceDefinition Load(string path)
    {
        XmlDocument doc = new XmlDocument();
        // No DTD, no entity resolution. This document is written by a process
        // running as SYSTEM, but it is parsed by one too, and an XXE in a
        // service host is a file read as LocalSystem for free.
        doc.XmlResolver = null;
        using (XmlReader reader = XmlReader.Create(path, new XmlReaderSettings
        {
            DtdProcessing = DtdProcessing.Prohibit,
            XmlResolver = null
        }))
        {
            doc.Load(reader);
        }

        XmlElement root = doc.DocumentElement;
        if (root == null || root.Name != "service")
        {
            throw new InvalidDataException("the root element is not <service>");
        }

        ServiceDefinition d = new ServiceDefinition();
        d.Id = Text(root, "id");
        d.DisplayName = Text(root, "name");
        d.Description = Text(root, "description");
        d.Executable = Text(root, "executable");
        d.Arguments = Text(root, "arguments");

        string startMode = Text(root, "startmode");
        if (startMode.Length > 0) { d.StartMode = startMode; }

        foreach (XmlElement e in root.GetElementsByTagName("env"))
        {
            string name = e.GetAttribute("name");
            if (name.Length == 0) { continue; }
            d.Environment.Add(new KeyValuePair<string, string>(name, e.GetAttribute("value")));
        }

        foreach (XmlElement e in root.GetElementsByTagName("onfailure"))
        {
            if (e.GetAttribute("action") != "restart") { continue; }
            d.RestartActions++;
            int seconds = ParseDuration(e.GetAttribute("delay"), -1);
            if (seconds >= 0) { d.RestartDelaySeconds = seconds; }
        }

        d.ResetFailureSeconds = ParseDuration(Text(root, "resetfailure"), d.ResetFailureSeconds);

        XmlElement log = First(root, "log");
        if (log != null)
        {
            d.LogSizeThresholdKb = ParseInt(Text(log, "sizeThreshold"), d.LogSizeThresholdKb);
            d.LogKeepFiles = ParseInt(Text(log, "keepFiles"), d.LogKeepFiles);
        }

        if (d.Id.Length == 0) { throw new InvalidDataException("<id> is empty"); }
        if (d.DisplayName.Length == 0) { d.DisplayName = d.Id; }
        if (d.Executable.Length == 0) { throw new InvalidDataException("<executable> is empty"); }
        return d;
    }

    private static XmlElement First(XmlElement parent, string name)
    {
        XmlNodeList nodes = parent.GetElementsByTagName(name);
        return nodes.Count == 0 ? null : nodes[0] as XmlElement;
    }

    private static string Text(XmlElement parent, string name)
    {
        XmlElement e = First(parent, name);
        return e == null ? "" : e.InnerText.Trim();
    }

    private static int ParseInt(string value, int fallback)
    {
        int parsed;
        return int.TryParse(value, out parsed) ? parsed : fallback;
    }

    // "10 sec", "1 hour", "500 ms", "3600". Anything unreadable keeps the
    // fallback rather than becoming zero: a restart delay of zero is a crash
    // loop at whatever rate the child can fail, and a reset window of zero
    // means the SCM never stops counting failures.
    private static int ParseDuration(string value, int fallback)
    {
        if (value == null) { return fallback; }
        string v = value.Trim().ToLowerInvariant();
        if (v.Length == 0) { return fallback; }
        string digits = "";
        int i = 0;
        while (i < v.Length && char.IsDigit(v[i])) { digits += v[i]; i++; }
        if (digits.Length == 0) { return fallback; }
        int n = int.Parse(digits);
        string unit = v.Substring(i).Trim();
        // Milliseconds are kept as a unit but FLOORED AT ONE SECOND, because
        // this type counts seconds and "500 ms" would otherwise integer-divide
        // to the zero the paragraph above refuses. Dropping the unit instead
        // would be worse than either: "500 ms" would fall through to the bare
        // number and become a five-hundred-SECOND restart delay. Nothing this
        // repository writes uses ms today; this is about what the next caller
        // gets when it does.
        if (unit.StartsWith("ms")) { int s = n / 1000; return s < 1 ? 1 : s; }
        if (unit.StartsWith("min")) { return n * 60; }
        if (unit.StartsWith("hour") || unit.StartsWith("hr")) { return n * 3600; }
        return n;
    }
}

// One child process, supervised, with its output rolled to a file beside the
// config. Everything the SCM needs is here and nothing else is.
internal sealed class ShimService : ServiceBase
{
    private readonly ServiceDefinition _definition;
    private readonly string _logPath;
    private readonly object _logLock = new object();
    private Process _child;
    private bool _stopping;

    public ShimService(ServiceDefinition definition, string configPath)
    {
        _definition = definition;
        ServiceName = definition.Id;
        _logPath = Path.Combine(
            Path.GetDirectoryName(Path.GetFullPath(configPath)), definition.Id + ".out.log");
        AutoLog = false;
    }

    protected override void OnStart(string[] args)
    {
        ProcessStartInfo psi = new ProcessStartInfo(_definition.Executable, _definition.Arguments);
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.WorkingDirectory = Path.GetDirectoryName(Path.GetFullPath(_logPath));
        foreach (KeyValuePair<string, string> kv in _definition.Environment)
        {
            psi.EnvironmentVariables[kv.Key] = kv.Value;
        }

        _child = new Process();
        _child.StartInfo = psi;
        _child.EnableRaisingEvents = true;
        _child.OutputDataReceived += (s, e) => Append(e.Data);
        _child.ErrorDataReceived += (s, e) => Append(e.Data);
        _child.Exited += OnChildExited;
        _child.Start();
        _child.BeginOutputReadLine();
        _child.BeginErrorReadLine();
        Append("shim: started " + _definition.Executable + " " + _definition.Arguments);
    }

    // The child dying while the service is still RUNNING is the case the whole
    // restart policy exists for, and the SCM only applies that policy to a
    // service that stopped with an ERROR. Stopping cleanly here would leave a
    // publisher-less host that the controller reads as busy forever.
    private void OnChildExited(object sender, EventArgs e)
    {
        if (_stopping) { return; }
        int code = -1;
        try { code = _child.ExitCode; } catch (InvalidOperationException) { }
        Append("shim: child exited with " + code + " -- stopping so the SCM restarts us");
        ExitCode = code == 0 ? 1 : code;
        Stop();
    }

    protected override void OnStop()
    {
        _stopping = true;
        if (_child == null || _child.HasExited) { return; }
        try
        {
            // The tree, not the process. The beacon's child is powershell.exe
            // and the broker's is python.exe; either can leave a grandchild
            // holding the log file or the broker's port, and a port still held
            // when the SCM restarts the service is a broker that never answers.
            Process killer = Process.Start(new ProcessStartInfo("taskkill.exe",
                "/PID " + _child.Id + " /T /F")
            { UseShellExecute = false, CreateNoWindow = true });
            if (killer != null) { killer.WaitForExit(10000); }
            _child.WaitForExit(10000);
        }
        catch (Exception ex)
        {
            Append("shim: could not stop the child -- " + ex.Message);
        }
    }

    private void Append(string line)
    {
        if (line == null) { return; }
        lock (_logLock)
        {
            try
            {
                Roll();
                File.AppendAllText(_logPath,
                    DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ") + " " + line +
                    System.Environment.NewLine, new UTF8Encoding(false));
            }
            catch (IOException)
            {
                // Diagnostics. Losing a log line must not take the service down.
            }
        }
    }

    private void Roll()
    {
        FileInfo info = new FileInfo(_logPath);
        // sizeThreshold is KB, matching the unit the boot script's documents are
        // written in. Reading it as bytes would roll a 10 KB log every few
        // seconds and keep nothing worth reading.
        if (!info.Exists || info.Length < (long)_definition.LogSizeThresholdKb * 1024L) { return; }
        for (int i = _definition.LogKeepFiles; i >= 1; i--)
        {
            string older = _logPath + "." + i;
            string newer = i == 1 ? _logPath : _logPath + "." + (i - 1);
            if (File.Exists(older)) { File.Delete(older); }
            if (File.Exists(newer)) { File.Move(newer, older); }
        }
    }
}

internal static class Program
{
    private static int Main(string[] argv)
    {
        if (argv.Length != 2)
        {
            Console.Error.WriteLine("usage: ci-service-shim.exe <install|run> <config.xml>");
            return 2;
        }
        string verb = argv[0].ToLowerInvariant();
        string configPath = Path.GetFullPath(argv[1]);

        ServiceDefinition definition;
        try
        {
            definition = ServiceDefinition.Load(configPath);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("ci-service-shim: cannot read " + configPath + " -- " + ex.Message);
            return 3;
        }

        if (verb == "run")
        {
            ServiceBase.Run(new ShimService(definition, configPath));
            return 0;
        }
        if (verb == "install")
        {
            return Install(definition, configPath);
        }
        Console.Error.WriteLine("ci-service-shim: unknown verb '" + verb + "'");
        return 2;
    }

    private static int Install(ServiceDefinition d, string configPath)
    {
        string self = Process.GetCurrentProcess().MainModule.FileName;
        // sc.exe wants `key= value` with the space AFTER the equals sign, and
        // the inner quotes are what survive a path with a space in it.
        string binPath = "\"" + self + "\" run \"" + configPath + "\"";
        bool exists = ServiceExists(d.Id);
        string startMode = d.StartMode.Equals("Manual", StringComparison.OrdinalIgnoreCase)
            ? "demand"
            : d.StartMode.Equals("Disabled", StringComparison.OrdinalIgnoreCase) ? "disabled" : "auto";

        // Reconfigure rather than recreate when it is already there: a delete is
        // not synchronous while a service is running, so create-after-delete
        // fails with "marked for deletion" on exactly the path that matters --
        // the reboot of a host that is already serving.
        int rc = exists
            ? Sc("config " + Quote(d.Id) + " binPath= " + Quote(binPath) +
                 " start= " + startMode + " DisplayName= " + Quote(d.DisplayName))
            : Sc("create " + Quote(d.Id) + " binPath= " + Quote(binPath) +
                 " start= " + startMode + " DisplayName= " + Quote(d.DisplayName));
        if (rc != 0) { return rc; }

        if (d.Description.Length > 0)
        {
            Sc("description " + Quote(d.Id) + " " + Quote(d.Description));
        }

        if (d.RestartActions > 0)
        {
            string actions = "";
            for (int i = 0; i < d.RestartActions; i++)
            {
                if (i > 0) { actions += "/"; }
                actions += "restart/" + (d.RestartDelaySeconds * 1000);
            }
            Sc("failure " + Quote(d.Id) + " reset= " + d.ResetFailureSeconds + " actions= " + actions);
        }
        return 0;
    }

    private static string Quote(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }

    private static bool ServiceExists(string name)
    {
        foreach (ServiceController c in ServiceController.GetServices())
        {
            if (string.Equals(c.ServiceName, name, StringComparison.OrdinalIgnoreCase)) { return true; }
        }
        return false;
    }

    private static int Sc(string arguments)
    {
        Process p = Process.Start(new ProcessStartInfo("sc.exe", arguments)
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        });
        string stdout = p.StandardOutput.ReadToEnd();
        string stderr = p.StandardError.ReadToEnd();
        p.WaitForExit();
        if (p.ExitCode != 0)
        {
            Console.Error.WriteLine("ci-service-shim: sc " + arguments + " failed (" + p.ExitCode + ")");
            Console.Error.WriteLine(stdout + stderr);
        }
        return p.ExitCode;
    }
}
