# Development-only component experiment; actual Windows supervision, no product tuning.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PythonExecutable,
    [string]$AssetDirectory = 'work/models/potion-multilingual-128M',
    [Parameter(Mandatory)][string]$ResultDirectory,
    [ValidateRange(1,8)][int]$Threads = 4,
    [ValidateRange(60,1200)][int]$TimeoutSeconds = 600
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$workRoot = [IO.Path]::GetFullPath((Join-Path $root 'work')) + [IO.Path]::DirectorySeparatorChar
function Owned-Path([string]$Value) {
    $path = [IO.Path]::GetFullPath((Join-Path $root $Value))
    if (-not $path.StartsWith($workRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Experimental outputs/assets must remain in owned work/' }
    return $path
}
$results = Owned-Path $ResultDirectory
$assets = Owned-Path $AssetDirectory
$python = [IO.Path]::GetFullPath($PythonExecutable)
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw 'Explicit isolated Python executable is missing' }
if (Test-Path -LiteralPath $results) { throw 'Refusing to overwrite existing evidence' }
New-Item -ItemType Directory -Path $results | Out-Null
$benchmarkResults = Join-Path $results 'measurements'
$ownedTemp = Join-Path $results 'temp'
$ownedProfile = Join-Path $results 'profile'
$ownedRoaming = Join-Path $ownedProfile 'AppData/Roaming'
$ownedLocal = Join-Path $ownedProfile 'AppData/Local'
$ownedHub = Join-Path $ownedProfile 'huggingface'
New-Item -ItemType Directory -Path $ownedTemp,$ownedRoaming,$ownedLocal,$ownedHub | Out-Null
$windows = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
if (-not $windows) { throw 'Required Windows system folder unavailable' }
# Only explicit system/Python execution settings reach the owned process tree.
# CI tokens, proxy credentials, user startup paths and unrelated environment
# variables never enter its Unicode environment block.
$childEnvironment = [ordered]@{
    SystemRoot = $windows; WINDIR = $windows; SystemDrive = [IO.Path]::GetPathRoot($windows).TrimEnd('\');
    COMSPEC = (Join-Path $windows 'System32/cmd.exe');
    PATH = ([IO.Path]::GetDirectoryName($python), (Join-Path $windows 'System32'), $windows) -join ';';
    TEMP = $ownedTemp; TMP = $ownedTemp;
    USERPROFILE = $ownedProfile; APPDATA = $ownedRoaming; LOCALAPPDATA = $ownedLocal; HF_HOME = $ownedHub;
    PYTHONDONTWRITEBYTECODE = '1'; PYTHONNOUSERSITE = '1'; PYTHONUTF8 = '1';
    OPENBLAS_NUM_THREADS = '1'; MKL_NUM_THREADS = '1'; OMP_NUM_THREADS = [string]$Threads;
    HF_HUB_OFFLINE = '1'; TRANSFORMERS_OFFLINE = '1'; HF_HUB_DISABLE_TELEMETRY = '1'; DO_NOT_TRACK = '1';
    TOKENIZERS_PARALLELISM = 'false'
}
if ($env:GITHUB_ACTIONS -eq 'true') { $childEnvironment['GITHUB_ACTIONS'] = 'true' }
$report = [ordered]@{
    status = 'NOT_STARTED'; classification = 'SILVER component experiment / cloud, not consumer-target16GB';
    started_utc = [DateTime]::UtcNow.ToString('o'); process_job_cap_bytes = [long]6GB;
    per_process_cap_bytes = [long]4GB; reserve_floor_bytes = [long]3GB; required_available_bytes = [long]9GB;
    initial_linux_quantization_os_peak_bytes = [long]3177345024;
    admission_basis = 'Conservative experimental budget: measured Linux preparation peak plus >1GiB per-process headroom; not Windows production overhead';
    controlled_process_limit = 4; process_limit_reason = 'One sequential Python parent/worker plus Windows venv redirectors; never two model flavors or an LLM';
    python_executable_sha256 = (Get-FileHash -LiteralPath $python -Algorithm SHA256).Hash.ToLowerInvariant();
    source_sha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 's4-static-embeddings.py') -Algorithm SHA256).Hash.ToLowerInvariant();
    supervisor_sha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant();
    native_windows_network_proof = 'NOT_MEASURED; local paths, offline flags and Python guard do not prove all native C++ network syscalls';
    samples = 0; job_peak_private_committed_bytes = [long]0; owned_launcher_pid = $null;
    child_environment = [ordered]@{ mode = 'Explicit Unicode allowlist; no inherited CI credentials/proxies'; names = @($childEnvironment.Keys) };
    error = $null; cleanup = 'NOT_STARTED'; python_network_attempts = 'See per-process reports';
    hardware = [ordered]@{
      os = (Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber,TotalVisibleMemorySize);
      processors = @(Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors,MaxClockSpeed);
      logical_processors = [Environment]::ProcessorCount;
      defender_real_time = [bool](Get-MpComputerStatus).RealTimeProtectionEnabled
    }
}
# Reusable native Windows APIs; assignment occurs before the owned child runs.
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
namespace StaticEmbeddingSpike {
 public sealed class Counters : IDisposable {
  IntPtr query;
  readonly Dictionary<string,IntPtr> handles = new Dictionary<string,IntPtr>();
  public readonly List<string> Unavailable = new List<string>();
  [StructLayout(LayoutKind.Explicit)] struct Value { [FieldOffset(0)] public uint Status; [FieldOffset(8)] public double Number; }
  [DllImport("pdh.dll",CharSet=CharSet.Unicode)] static extern uint PdhOpenQuery(string source,UIntPtr user,out IntPtr query);
  [DllImport("pdh.dll",CharSet=CharSet.Unicode)] static extern uint PdhAddEnglishCounter(IntPtr query,string path,UIntPtr user,out IntPtr counter);
  [DllImport("pdh.dll")] static extern uint PdhCollectQueryData(IntPtr query);
  [DllImport("pdh.dll")] static extern uint PdhGetFormattedCounterValue(IntPtr counter,uint format,out uint type,out Value value);
  [DllImport("pdh.dll")] static extern uint PdhCloseQuery(IntPtr query);
  public Counters() {
   uint result=PdhOpenQuery(null,UIntPtr.Zero,out query); if(result!=0) throw new Exception("PdhOpenQuery error "+result);
   Add("available_mib",@"\Memory\Available MBytes"); Add("pages_input_per_sec",@"\Memory\Pages Input/sec");
   Add("page_reads_per_sec",@"\Memory\Page Reads/sec"); Add("committed_bytes",@"\Memory\Committed Bytes");
   Add("commit_limit_bytes",@"\Memory\Commit Limit"); PdhCollectQueryData(query);
  }
  void Add(string name,string path) { IntPtr handle; uint code=PdhAddEnglishCounter(query,path,UIntPtr.Zero,out handle); if(code==0) handles.Add(name,handle); else Unavailable.Add(name+": "+code); }
  public Dictionary<string,object> Sample() {
   var values=new Dictionary<string,object>(); uint collected=PdhCollectQueryData(query);
   foreach(var item in handles) {uint type; Value value; uint code=PdhGetFormattedCounterValue(item.Value,0x200,out type,out value);
    values[item.Key]=collected==0 && code==0 && value.Status<=1 && !double.IsNaN(value.Number) && !double.IsInfinity(value.Number) ? (object)value.Number : null;}
   return values;
  }
  public void Dispose() {if(query!=IntPtr.Zero) {PdhCloseQuery(query);query=IntPtr.Zero;}}
 }
 public sealed class OwnedProcess : IDisposable {
  IntPtr job,process;
  public uint Pid {get;private set;}
  public bool UsedFallbackTermination {get;private set;}
  [StructLayout(LayoutKind.Sequential)] struct SecurityAttributes {public int Length; public IntPtr Descriptor; public int Inherit;}
  [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct StartupInfo {public uint Size; public string Reserved,Desktop,Title; public uint X,Y,XSize,YSize,XChars,YChars,Fill,Flags; public ushort Show,ReservedSize; public IntPtr ReservedBytes,Input,Output,Error;}
  [StructLayout(LayoutKind.Sequential)] struct StartupEx {public StartupInfo Startup; public IntPtr Attributes;}
  [StructLayout(LayoutKind.Sequential)] struct ProcessInfo {public IntPtr Process,Thread;public uint Pid,Tid;}
  [StructLayout(LayoutKind.Sequential)] struct BasicLimits {public long ProcessTime,JobTime;public uint Flags;public UIntPtr MinimumWorkingSet,MaximumWorkingSet;public uint ActiveProcesses;public UIntPtr Affinity;public uint Priority,Scheduling;}
  [StructLayout(LayoutKind.Sequential)] struct IoCounters {public ulong ReadOperations,WriteOperations,OtherOperations,ReadBytes,WriteBytes,OtherBytes;}
  [StructLayout(LayoutKind.Sequential)] struct ExtendedLimits {public BasicLimits Basic;public IoCounters Io;public UIntPtr ProcessMemory,JobMemory,PeakProcessMemory,PeakJobMemory;}
  [StructLayout(LayoutKind.Sequential)] struct MemoryInfo {public uint Size,PageFaultCount;public UIntPtr PeakWorkingSet,WorkingSet,QuotaPeakPaged,QuotaPaged,QuotaPeakNonPaged,QuotaNonPaged,Pagefile,PeakPagefile,PrivateUsage,PrivateWorkingSet,SharedCommit;}
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr attributes,string name);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job,int info,ref ExtendedLimits limits,uint length);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job,int info,out ExtendedLimits limits,uint length,IntPtr returnLength);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcess(string application,StringBuilder command,IntPtr processAttributes,IntPtr threadAttributes,bool inherit,uint flags,IntPtr environment,string directory,ref StartupEx startup,out ProcessInfo info);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool InitializeProcThreadAttributeList(IntPtr list,int count,uint flags,ref UIntPtr bytes);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool UpdateProcThreadAttribute(IntPtr list,uint flags,IntPtr attribute,IntPtr value,UIntPtr bytes,IntPtr previous,IntPtr returned);
  [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateFile(string path,uint access,uint sharing,ref SecurityAttributes attributes,uint disposition,uint flags,IntPtr template);
  [DllImport("kernel32.dll",SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
  [DllImport("kernel32.dll",SetLastError=true)] static extern uint WaitForSingleObject(IntPtr handle,uint milliseconds);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr handle,out uint code);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateProcess(IntPtr handle,uint code);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
  [DllImport("psapi.dll",SetLastError=true)] static extern bool GetProcessMemoryInfo(IntPtr process,ref MemoryInfo info,uint size);
  [DllImport("iphlpapi.dll",SetLastError=true)] static extern uint GetExtendedTcpTable(IntPtr table,ref int bytes,bool sorted,int family,int tableClass,uint reserved);
  static void Check(bool ok,string operation) {if(!ok) throw new Win32Exception(Marshal.GetLastWin32Error(),operation);}
  static IntPtr FileHandle(string path,uint access,uint disposition) {
   var attrs=new SecurityAttributes {Length=Marshal.SizeOf<SecurityAttributes>(),Inherit=1};
   IntPtr handle=CreateFile(path,access,3,ref attrs,disposition,0x80,IntPtr.Zero);
   if(handle==new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error(),"Create owned stdio file");return handle;
  }
  public static string QuoteArgument(string value) {
   var output=new StringBuilder("\"");int slashes=0;
   foreach(char c in value) {if(c=='\\') {slashes++;continue;} if(c=='\"') {output.Append('\\',slashes*2+1);output.Append(c);} else {output.Append('\\',slashes);output.Append(c);} slashes=0;}
   output.Append('\\',slashes*2);output.Append('"');return output.ToString();
  }
  public static OwnedProcess Start(string executable,string[] arguments,string stdout,string stderr,ulong commitLimit,string[] environmentEntries) {
   var owned=new OwnedProcess();IntPtr input=IntPtr.Zero,output=IntPtr.Zero,error=IntPtr.Zero,list=IntPtr.Zero,handleList=IntPtr.Zero,environment=IntPtr.Zero;var info=new ProcessInfo();bool initialized=false,started=false;
   try {
    owned.job=CreateJobObject(IntPtr.Zero,null);if(owned.job==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(),"Create owned Job");
    var limits=new ExtendedLimits();limits.Basic.Flags=0x2000|0x100|0x200|0x8;limits.Basic.ActiveProcesses=4;limits.ProcessMemory=new UIntPtr(4UL*1024*1024*1024);limits.JobMemory=new UIntPtr(commitLimit);
    Check(SetInformationJobObject(owned.job,9,ref limits,(uint)Marshal.SizeOf<ExtendedLimits>()),"Set 4GiB per-process / 6GiB aggregate private-commit / kill-on-close / four-process Job");
    input=FileHandle("NUL",0x80000000,3);output=FileHandle(stdout,0x40000000,1);error=FileHandle(stderr,0x40000000,1);
    UIntPtr size=UIntPtr.Zero;InitializeProcThreadAttributeList(IntPtr.Zero,1,0,ref size);if(size==UIntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(),"Size restricted handle list");
    list=Marshal.AllocHGlobal(checked((int)size.ToUInt64()));Check(InitializeProcThreadAttributeList(list,1,0,ref size),"Initialize restricted handle list");initialized=true;
    handleList=Marshal.AllocHGlobal(IntPtr.Size*3);Marshal.WriteIntPtr(handleList,0,input);Marshal.WriteIntPtr(handleList,IntPtr.Size,output);Marshal.WriteIntPtr(handleList,IntPtr.Size*2,error);
    Check(UpdateProcThreadAttribute(list,0,new IntPtr(0x20002),handleList,(UIntPtr)(IntPtr.Size*3),IntPtr.Zero,IntPtr.Zero),"Restrict inherited handles to stdio");
    var startup=new StartupEx();startup.Startup.Size=(uint)Marshal.SizeOf<StartupEx>();startup.Startup.Flags=0x100;startup.Startup.Input=input;startup.Startup.Output=output;startup.Startup.Error=error;startup.Attributes=list;
    var command=new StringBuilder(QuoteArgument(executable));foreach(string argument in arguments) command.Append(' ').Append(QuoteArgument(argument));
    Array.Sort(environmentEntries,StringComparer.OrdinalIgnoreCase);
    foreach(string entry in environmentEntries) if(entry.IndexOf('\0')>=0 || entry.IndexOf('=')<1) throw new ArgumentException("Invalid explicit child environment entry");
    environment=Marshal.StringToHGlobalUni(string.Join("\0",environmentEntries)+"\0\0");
    Check(CreateProcess(executable,command,IntPtr.Zero,IntPtr.Zero,true,0x4|0x80000|0x08000000|0x400,environment,Path.GetDirectoryName(executable),ref startup,out info),"Create owned child suspended with explicit Unicode environment");started=true;
    Check(AssignProcessToJobObject(owned.job,info.Process),"Assign suspended child to bounded Job (nested Job must work)");
    if(ResumeThread(info.Thread)==0xffffffff) throw new Win32Exception(Marshal.GetLastWin32Error(),"Resume bounded owned child");
    owned.process=info.Process;owned.Pid=info.Pid;info.Process=IntPtr.Zero;return owned;
   } catch {if(started && info.Process!=IntPtr.Zero) TerminateProcess(info.Process,0xbad);owned.Dispose();throw;}
   finally {if(info.Thread!=IntPtr.Zero) CloseHandle(info.Thread);if(info.Process!=IntPtr.Zero) CloseHandle(info.Process);if(initialized) DeleteProcThreadAttributeList(list);if(list!=IntPtr.Zero) Marshal.FreeHGlobal(list);if(handleList!=IntPtr.Zero) Marshal.FreeHGlobal(handleList);if(environment!=IntPtr.Zero) Marshal.FreeHGlobal(environment);foreach(IntPtr handle in new[]{input,output,error}) if(handle!=IntPtr.Zero && handle!=new IntPtr(-1)) CloseHandle(handle);}
  }
  public bool HasExited {get {uint wait=WaitForSingleObject(process,0);if(wait==0xffffffff) throw new Win32Exception(Marshal.GetLastWin32Error(),"Wait owned child");return wait==0;}}
  public uint ExitCode {get {uint code;Check(GetExitCodeProcess(process,out code),"Get owned child exit code");return code;}}
  public ulong JobPeakPrivateCommit() {
   ExtendedLimits limits;Check(QueryInformationJobObject(job,9,out limits,(uint)Marshal.SizeOf<ExtendedLimits>(),IntPtr.Zero),"Read retained aggregate Job private-commit peak");return limits.PeakJobMemory.ToUInt64();
  }
  public Dictionary<string,object> Memory() {
   var info=new MemoryInfo();info.Size=(uint)Marshal.SizeOf<MemoryInfo>();Check(GetProcessMemoryInfo(process,ref info,info.Size),"Read PROCESS_MEMORY_COUNTERS_EX2");
   ExtendedLimits limits;Check(QueryInformationJobObject(job,9,out limits,(uint)Marshal.SizeOf<ExtendedLimits>(),IntPtr.Zero),"Read Job private-commit peak");
   return new Dictionary<string,object>{{"working_set_bytes",info.WorkingSet.ToUInt64()},{"native_peak_working_set_bytes",info.PeakWorkingSet.ToUInt64()},{"private_working_set_bytes",info.PrivateWorkingSet.ToUInt64()},{"private_committed_bytes",info.PrivateUsage.ToUInt64()},{"job_peak_private_committed_bytes",limits.PeakJobMemory.ToUInt64()},{"page_fault_count",info.PageFaultCount}};
  }
  public uint StopAndWait() {
   if(job!=IntPtr.Zero) {IntPtr handle=job;job=IntPtr.Zero;Check(CloseHandle(handle),"Close owned kill-on-close Job");}
   if(process==IntPtr.Zero) return 0;
   uint wait=WaitForSingleObject(process,10000);
   if(wait==258) {UsedFallbackTermination=true;Check(TerminateProcess(process,0xbad),"Stop owned child after Job-close timeout");wait=WaitForSingleObject(process,10000);}
   if(wait!=0) throw new Exception("Owned child cleanup wait failed: "+wait);
   return ExitCode;
  }
  public void Dispose() {try {StopAndWait();} finally {if(process!=IntPtr.Zero) {CloseHandle(process);process=IntPtr.Zero;}}}
 }
}
'@
$owned = $null; $counters = $null; $writer = $null
$watch = [Diagnostics.Stopwatch]::StartNew()
$exitCode = 1
try {
    $system = Get-CimInstance Win32_OperatingSystem
    $report.admission = [ordered]@{ total_bytes = [long]$system.TotalVisibleMemorySize * 1024;
        available_bytes = [long]$system.FreePhysicalMemory * 1024; at_utc = [DateTime]::UtcNow.ToString('o') }
    if ($report.admission.available_bytes -lt $report.required_available_bytes) {
        $report.status = 'NOT_ADMITTED'; $exitCode = 2
    } else {
        $counters = [StaticEmbeddingSpike.Counters]::new()
        $snapshot = $null
        for ($attempt = 0; $attempt -lt 12; $attempt++) {
            Start-Sleep -Milliseconds 250
            $snapshot = $counters.Sample()
            if ($null -ne $snapshot['available_mib'] -and $null -ne $snapshot['pages_input_per_sec']) { break }
        }
        if ($null -eq $snapshot['available_mib'] -or $null -eq $snapshot['pages_input_per_sec']) { throw 'Mandatory Windows PDH memory safety counters unavailable' }
        if ([double]$snapshot['available_mib'] * 1MB -lt $report.required_available_bytes) { throw 'Admission changed before suspended-child launch' }
        $writer = [IO.StreamWriter]::new((Join-Path $results 'supervisor-memory.jsonl'), $false, [Text.UTF8Encoding]::new($false))
        $command = @((Join-Path $PSScriptRoot 's4-static-embeddings.py'), 'benchmark', '--assets', $assets, '--results', $benchmarkResults, '--threads', [string]$Threads)
        $environmentEntries = @($childEnvironment.GetEnumerator() | ForEach-Object { [string]$_.Key + '=' + [string]$_.Value })
        $owned = [StaticEmbeddingSpike.OwnedProcess]::Start($python, $command, (Join-Path $results 'owned.stdout.log'), (Join-Path $results 'owned.stderr.log'), [ulong]$report.process_job_cap_bytes, $environmentEntries)
        $report.owned_launcher_pid = $owned.Pid
        $report.status = 'RUNNING'
        $pressureSince = $null
        while (-not $owned.HasExited) {
            $snapshot = $counters.Sample()
            if ($null -eq $snapshot['available_mib'] -or $null -eq $snapshot['pages_input_per_sec']) { throw 'Mandatory Windows PDH memory safety counters lost' }
            $process = $owned.Memory()
            $row = [ordered]@{ sample_index = $report.samples; elapsed_ms = $watch.Elapsed.TotalMilliseconds;
                available_bytes = [long]([double]$snapshot['available_mib'] * 1MB); pages_input_per_sec = $snapshot['pages_input_per_sec'];
                launcher_working_set_bytes = $process['working_set_bytes']; job_peak_private_committed_bytes = $process['job_peak_private_committed_bytes'] }
            $writer.WriteLine(($row | ConvertTo-Json -Compress)); $writer.Flush()
            $report.samples++
            $report.job_peak_private_committed_bytes = [Math]::Max($report.job_peak_private_committed_bytes, [long]$row.job_peak_private_committed_bytes)
            if ($row.available_bytes -lt ([long]3GB + [long]512MB)) { throw 'EARLY_PRESSURE_CANCEL before reserved 3GiB RAM floor' }
            if ([double]$row.pages_input_per_sec -gt 500 -and $row.available_bytes -lt [long]4GB) {
                if ($null -eq $pressureSince) { $pressureSince = $watch.Elapsed.TotalSeconds }
                if ($watch.Elapsed.TotalSeconds - $pressureSince -gt 5) { throw 'THRASH_CANCEL: paging near reserved RAM floor' }
            } else { $pressureSince = $null }
            if ($watch.Elapsed.TotalSeconds -gt $TimeoutSeconds) { throw 'OWNED_TIMEOUT_CANCEL: bounded component deadline' }
            Start-Sleep -Milliseconds 250
        }
        $report.owned_exit_code = $owned.ExitCode
        if ($owned.ExitCode -ne 0) { throw 'Owned benchmark failed; its local diagnostics are preserved, never uploaded blindly' }
        $summary = Get-Content -LiteralPath (Join-Path $benchmarkResults 'summary.json') -Raw | ConvertFrom-Json
        if ($summary.status -ne 'MEASURED_PARTIAL' -or $summary.numerical_parity.fp32_vs_numpy_mean_l2 -ne 'PASS' -or $summary.configuration.quantization.actual_embedding_table_dtype -ne 'UINT8') { throw 'Required measurement/parity metadata missing' }
        $report.status = 'MEASURED_PARTIAL'; $exitCode = 0
    }
} catch {
    $report.status = 'FAILED_OR_SAFELY_CANCELED'; $report.error = $_.Exception.Message
} finally {
    try {
        if ($null -ne $owned) {
            try {
                $report.job_peak_private_committed_bytes = [Math]::Max($report.job_peak_private_committed_bytes, [long]$owned.JobPeakPrivateCommit())
                $report.job_peak_method = 'Native retained Job PeakJobMemory queried after exit/before Job close; includes parent/worker redirectors'
            } finally {
                try { $report.cleanup_exit_code = $owned.StopAndWait(); $report.cleanup_used_fallback = $owned.UsedFallbackTermination }
                finally { $owned.Dispose() }
            }
        }
        $report.cleanup = 'OWNED_JOB_CLOSED_AND_LAUNCHER_EXITED'
    } catch { $report.cleanup = 'FAILED'; $report.cleanup_error = $_.Exception.Message; $exitCode = 1 }
    if ($null -ne $writer) { $writer.Dispose() }
    if ($null -ne $counters) { $counters.Dispose() }
    $report.elapsed_ms = $watch.Elapsed.TotalMilliseconds
    $report.finished_utc = [DateTime]::UtcNow.ToString('o')
    $report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $results 'windows-supervisor.json') -Encoding utf8NoBOM
    $report | ConvertTo-Json -Depth 12 | Write-Output
}
exit $exitCode
