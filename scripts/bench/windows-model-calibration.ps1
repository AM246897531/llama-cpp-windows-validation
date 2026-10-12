#requires -Version 7.3
[CmdletBinding()]
param(
    [string]$ResultDirectory,
    [string]$RuntimeDirectory,
    [string]$ModelPath,
    [switch]$ProbeOnly,
    [switch]$WarmBenchmark,
    [ValidateNotNullOrEmpty()][ValidateSet('pp500', 'pp1500', 'pp3000', 'tg128', 'full-context', 'thermal')]
    [string[]]$ProbeSet = @('pp500', 'pp1500', 'pp3000', 'tg128', 'full-context', 'thermal'),
    [ValidateSet(0, 2, 4)][int]$BallastGiB = 0,
    [ValidateRange(3, 20)][int]$WarmupRuns = 3,
    [ValidateRange(30, 120)][int]$Repetitions = 30,
    [ValidateRange(360, 18000)][int]$BenchmarkTimeoutSeconds = 6900,
    [ValidateRange(1, 128)][int]$Threads = 4,
    [ValidateRange(60, 1800)][int]$TimeoutSeconds = 360,
    [ValidateSet('GITHUB_WINDOWS_RUNNER', 'REPRESENTATIVE_16GB_WINDOWS', 'TARGET_MACHINE')]
    [string]$ExecutionEnvironment = 'GITHUB_WINDOWS_RUNNER'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($ProbeOnly -and $WarmBenchmark) { throw 'ProbeOnly and WarmBenchmark are mutually exclusive.' }
if (-not $WarmBenchmark -and ($BallastGiB -ne 0 -or $PSBoundParameters.ContainsKey('ProbeSet') -or
    $PSBoundParameters.ContainsKey('WarmupRuns') -or $PSBoundParameters.ContainsKey('Repetitions') -or
    $PSBoundParameters.ContainsKey('BenchmarkTimeoutSeconds'))) { throw 'Benchmark selections require WarmBenchmark; short calibration is preserved.' }
if (-not $IsWindows -or -not [Environment]::Is64BitProcess -or [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne 'X64') {
    throw 'This diagnostic requires real x64 Windows and PowerShell 7.3+. Linux/ARM execution is not Windows x64 evidence.'
}
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$runId = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
if (-not $ResultDirectory) { $ResultDirectory = Join-Path $repoRoot "work/bench/windows-calibration-$runId" }
if (-not $RuntimeDirectory) { $RuntimeDirectory = Join-Path $repoRoot 'work/bench/cache/windows-runtime' }
if (-not $ModelPath) { $ModelPath = Join-Path $repoRoot 'work/models/dicta-12b/model.gguf' }
$ResultDirectory = [IO.Path]::GetFullPath($ResultDirectory)
$RuntimeDirectory = [IO.Path]::GetFullPath($RuntimeDirectory)
$ModelPath = [IO.Path]::GetFullPath($ModelPath)
if ((Test-Path -LiteralPath $ResultDirectory) -and @(Get-ChildItem -LiteralPath $ResultDirectory -Force).Count) {
    throw 'ResultDirectory must be new or empty. Existing evidence is preserved.'
}
New-Item -ItemType Directory -Path $ResultDirectory -Force | Out-Null
$floorBytes = [long]3GB
$privateCommitLimitBytes = [long]2GB
$cancelBufferBytes = [long]512MB
$minimumVisibleBytes = [long]15GB
$sampleIntervalMs = 250
$modelManifestPath = Join-Path $repoRoot 'manifests/dicta-12b.json'
$runtimeManifestPath = Join-Path $repoRoot 'manifests/llama-runtime.json'
$model = Get-Content -Raw -LiteralPath $modelManifestPath | ConvertFrom-Json
$runtime = Get-Content -Raw -LiteralPath $runtimeManifestPath | ConvertFrom-Json
$requiredAvailableBytes = [long]$model.bytes + $privateCommitLimitBytes + $floorBytes
$admissions = [Collections.Generic.List[object]]::new()
$memorySampleRetentionLimit = 64
$samples = [Collections.Generic.Queue[object]]::new($memorySampleRetentionLimit)
$memorySampleCount = [long]0
$lastMemorySample = $null
$memoryPeakMetrics = @('working_set_bytes', 'native_peak_working_set_bytes', 'private_working_set_bytes', 'private_committed_bytes', 'job_peak_private_committed_bytes')
$memoryPeaks = [ordered]@{}
foreach ($metric in $memoryPeakMetrics) { $memoryPeaks[$metric] = $null }
$ownedChild = $null; $counters = $null; $memoryWriter = $null; $http = $null
$keyDirectory = $null; $keyPath = $null; $token = $null; $exitCode = 1
$probeCleanupSafe = $true
$phase = 'capability-probe'; $watch = [Diagnostics.Stopwatch]::StartNew()
$pressureSince = $null
$ballast = $null; $benchmarkWriter = $null
$effectiveTimeoutSeconds = $TimeoutSeconds
$selectedProbes = @($ProbeSet | Select-Object -Unique)

function Write-Json([object]$Value, [string]$Path) {
    $Value | ConvertTo-Json -Depth 25 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
}
function Get-Sha256([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Get-AvailableMemory {
    $system = Get-CimInstance Win32_OperatingSystem
    return [ordered]@{ available_bytes = [long]$system.FreePhysicalMemory * 1024; total_bytes = [long]$system.TotalVisibleMemorySize * 1024 }
}
function Test-Admission([string]$Stage, [long]$AdditionalBallastBytes = 0) {
    $memory = Get-AvailableMemory
    $ok = $memory.total_bytes -ge $minimumVisibleBytes -and $memory.available_bytes -ge ($requiredAvailableBytes + $AdditionalBallastBytes)
    $admissions.Add([ordered]@{ stage = $Stage; at_utc = [DateTime]::UtcNow.ToString('o'); admitted = $ok;
        total_bytes = $memory.total_bytes; available_bytes = $memory.available_bytes;
        minimum_visible_bytes = $minimumVisibleBytes; nominal_target_bytes = [long]16GB;
        full_model_mapping_reserved_bytes = [long]$model.bytes; experimental_private_commit_cap_bytes = $privateCommitLimitBytes;
        floor_bytes = $floorBytes; required_available_bytes = $requiredAvailableBytes + $AdditionalBallastBytes;
        additional_ballast_reserved_bytes = $AdditionalBallastBytes;
        overhead_status = 'INITIAL bounded experiment informed by Linux; NOT measured Windows overhead; NOT production admission' })
    return $ok
}
function Get-VerifiedDownload([string]$Uri, [string]$Destination, [string]$Digest, [long]$Bytes = 0) {
    if (Test-Path -LiteralPath $Destination) {
        if ((Get-Sha256 $Destination) -ne $Digest -or ($Bytes -gt 0 -and (Get-Item -LiteralPath $Destination).Length -ne $Bytes)) { throw 'Existing cached asset failed pinned SHA256/size verification.' }
        return
    }
    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($Destination)) -Force | Out-Null
    $partial = $Destination + '.partial-' + [Guid]::NewGuid().ToString('N')
    try {
        Invoke-WebRequest -Uri $Uri -OutFile $partial
        if ((Get-Sha256 $partial) -ne $Digest -or ($Bytes -gt 0 -and (Get-Item -LiteralPath $partial).Length -ne $Bytes)) { throw 'Downloaded asset failed pinned SHA256/size verification.' }
        Move-Item -LiteralPath $partial -Destination $Destination
    } finally { if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial } }
}

# Assignment happens while the child is suspended. The restricted inherited
# handle list contains only NUL/stdout/stderr; a Job is never assigned afterward.
# PROCESS_MEMORY_LIMIT bounds private committed memory, NOT file-backed residency.
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
namespace KesherCalibration {
 public sealed class Ballast : IDisposable {
  IntPtr address; readonly ulong bytes;
  [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr VirtualAlloc(IntPtr address,UIntPtr bytes,uint type,uint protection);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool VirtualFree(IntPtr address,UIntPtr bytes,uint type);
  public Ballast(ulong count) {
   bytes=count;if(count==0) return;
   address=VirtualAlloc(IntPtr.Zero,(UIntPtr)count,0x2000,0x04);
   if(address==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(),"Reserve owned ballast");
  }
  public void CommitAndTouch(ulong offset,ulong count) {
   if(offset>bytes || count>bytes-offset) throw new ArgumentOutOfRangeException("count");
   IntPtr start=new IntPtr(checked(address.ToInt64()+(long)offset));
   if(VirtualAlloc(start,(UIntPtr)count,0x1000,0x04)==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(),"Commit owned ballast chunk");
   for(ulong page=0;page<count;page+=4096) Marshal.WriteByte(new IntPtr(checked(start.ToInt64()+(long)page)),1);
  }
  public void Dispose() {
   if(address!=IntPtr.Zero) {if(!VirtualFree(address,UIntPtr.Zero,0x8000)) throw new Win32Exception(Marshal.GetLastWin32Error(),"Release owned ballast");address=IntPtr.Zero;}
  }
 }
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
  public static OwnedProcess Start(string executable,string[] arguments,string stdout,string stderr,ulong commitLimit) {
   var owned=new OwnedProcess();IntPtr input=IntPtr.Zero,output=IntPtr.Zero,error=IntPtr.Zero,list=IntPtr.Zero,handleList=IntPtr.Zero;var info=new ProcessInfo();bool initialized=false,started=false;
   try {
    owned.job=CreateJobObject(IntPtr.Zero,null);if(owned.job==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(),"Create owned Job");
    var limits=new ExtendedLimits();limits.Basic.Flags=0x2000|0x100|0x8;limits.Basic.ActiveProcesses=1;limits.ProcessMemory=(UIntPtr)commitLimit;
    Check(SetInformationJobObject(owned.job,9,ref limits,(uint)Marshal.SizeOf<ExtendedLimits>()),"Set private-commit cap / kill-on-close / one-process Job");
    input=FileHandle("NUL",0x80000000,3);output=FileHandle(stdout,0x40000000,1);error=FileHandle(stderr,0x40000000,1);
    UIntPtr size=UIntPtr.Zero;InitializeProcThreadAttributeList(IntPtr.Zero,1,0,ref size);if(size==UIntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(),"Size restricted handle list");
    list=Marshal.AllocHGlobal(checked((int)size.ToUInt64()));Check(InitializeProcThreadAttributeList(list,1,0,ref size),"Initialize restricted handle list");initialized=true;
    handleList=Marshal.AllocHGlobal(IntPtr.Size*3);Marshal.WriteIntPtr(handleList,0,input);Marshal.WriteIntPtr(handleList,IntPtr.Size,output);Marshal.WriteIntPtr(handleList,IntPtr.Size*2,error);
    Check(UpdateProcThreadAttribute(list,0,new IntPtr(0x20002),handleList,(UIntPtr)(IntPtr.Size*3),IntPtr.Zero,IntPtr.Zero),"Restrict inherited handles to stdio");
    var startup=new StartupEx();startup.Startup.Size=(uint)Marshal.SizeOf<StartupEx>();startup.Startup.Flags=0x100;startup.Startup.Input=input;startup.Startup.Output=output;startup.Startup.Error=error;startup.Attributes=list;
    var command=new StringBuilder(QuoteArgument(executable));foreach(string argument in arguments) command.Append(' ').Append(QuoteArgument(argument));
    Check(CreateProcess(executable,command,IntPtr.Zero,IntPtr.Zero,true,0x4|0x80000|0x08000000,IntPtr.Zero,Path.GetDirectoryName(executable),ref startup,out info),"Create owned child suspended");started=true;
    Check(AssignProcessToJobObject(owned.job,info.Process),"Assign suspended child to bounded Job (nested Job must work)");
    if(ResumeThread(info.Thread)==0xffffffff) throw new Win32Exception(Marshal.GetLastWin32Error(),"Resume bounded owned child");
    owned.process=info.Process;owned.Pid=info.Pid;info.Process=IntPtr.Zero;return owned;
   } catch {if(started && info.Process!=IntPtr.Zero) TerminateProcess(info.Process,0xbad);owned.Dispose();throw;}
   finally {if(info.Thread!=IntPtr.Zero) CloseHandle(info.Thread);if(info.Process!=IntPtr.Zero) CloseHandle(info.Process);if(initialized) DeleteProcThreadAttributeList(list);if(list!=IntPtr.Zero) Marshal.FreeHGlobal(list);if(handleList!=IntPtr.Zero) Marshal.FreeHGlobal(handleList);foreach(IntPtr handle in new[]{input,output,error}) if(handle!=IntPtr.Zero && handle!=new IntPtr(-1)) CloseHandle(handle);}
  }
  public bool HasExited {get {uint wait=WaitForSingleObject(process,0);if(wait==0xffffffff) throw new Win32Exception(Marshal.GetLastWin32Error(),"Wait owned child");return wait==0;}}
  public uint ExitCode {get {uint code;Check(GetExitCodeProcess(process,out code),"Get owned child exit code");return code;}}
  public Dictionary<string,object> Memory() {
   var info=new MemoryInfo();info.Size=(uint)Marshal.SizeOf<MemoryInfo>();Check(GetProcessMemoryInfo(process,ref info,info.Size),"Read PROCESS_MEMORY_COUNTERS_EX2");
   ExtendedLimits limits;Check(QueryInformationJobObject(job,9,out limits,(uint)Marshal.SizeOf<ExtendedLimits>(),IntPtr.Zero),"Read Job private-commit peak");
   return new Dictionary<string,object>{{"working_set_bytes",info.WorkingSet.ToUInt64()},{"native_peak_working_set_bytes",info.PeakWorkingSet.ToUInt64()},{"private_working_set_bytes",info.PrivateWorkingSet.ToUInt64()},{"private_committed_bytes",info.PrivateUsage.ToUInt64()},{"job_peak_private_committed_bytes",limits.PeakProcessMemory.ToUInt64()},{"page_fault_count",info.PageFaultCount}};
  }
  public static uint ListenerPid(int port) {
   int bytes=0;uint code=GetExtendedTcpTable(IntPtr.Zero,ref bytes,false,2,3,0);if(code!=122 && code!=0) throw new Exception("Size TCP listener table error "+code);
   IntPtr buffer=Marshal.AllocHGlobal(bytes);try {code=GetExtendedTcpTable(buffer,ref bytes,false,2,3,0);if(code!=0) throw new Exception("Read TCP listener table error "+code);
    int rows=Marshal.ReadInt32(buffer);for(int i=0;i<rows;i++) {int offset=4+i*24;uint address=unchecked((uint)Marshal.ReadInt32(buffer,offset+4));uint encoded=unchecked((uint)Marshal.ReadInt32(buffer,offset+8));int localPort=IPAddress.NetworkToHostOrder(unchecked((short)(encoded&0xffff)))&0xffff;
     if(address==0x0100007f && localPort==port) return unchecked((uint)Marshal.ReadInt32(buffer,offset+20));}return 0;
   } finally {Marshal.FreeHGlobal(buffer);}
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

function Get-CounterReadiness {
    $last = $null
    for ($attempt = 0; $attempt -lt 12; $attempt++) {
        Start-Sleep -Milliseconds $sampleIntervalMs
        $last = $counters.Sample()
        if ($last.ContainsKey('available_mib') -and $null -ne $last['available_mib'] -and
            $last.ContainsKey('pages_input_per_sec') -and $null -ne $last['pages_input_per_sec']) { return $last }
    }
    throw 'Safety prerequisite unavailable: real Available MBytes and Pages Input/sec PDH values are required.'
}
function Assert-SampleSafety([long]$Available, [object]$PagesInput, [double]$ElapsedSeconds) {
    if ($Available -lt ($floorBytes + $cancelBufferBytes)) { throw 'EARLY_PRESSURE_CANCEL: available RAM approached reserved 3 GiB floor within 512 MiB.' }
    if ($null -eq $PagesInput) { throw 'Safety prerequisite lost: Pages Input/sec must remain measurable.' }
    if ([double]$PagesInput -gt 500 -and $Available -lt ($floorBytes + 1GB)) {
        if ($null -eq $script:pressureSince) { $script:pressureSince = $ElapsedSeconds }
        if ($ElapsedSeconds - $script:pressureSince -gt 5) { throw 'THRASHING_CANCEL: sustained Pages Input >500/sec near memory floor; INITIAL diagnostic threshold.' }
    } else { $script:pressureSince = $null }
}
function Add-MemorySample([object]$Snapshot) {
    # Raw observations stay complete on disk. Only recent objects remain in
    # heap; indices and all-run peaks must never depend on the bounded queue.
    $Snapshot['sample_index'] = $script:memorySampleCount
    $memoryWriter.WriteLine(($Snapshot | ConvertTo-Json -Depth 10 -Compress)); $memoryWriter.Flush()
    foreach ($metric in $memoryPeakMetrics) {
        $value = $Snapshot[$metric]
        if ($null -ne $value -and ($null -eq $memoryPeaks[$metric] -or [ulong]$value -gt [ulong]$memoryPeaks[$metric])) {
            $memoryPeaks[$metric] = [ulong]$value
        }
    }
    if ($samples.Count -ge $memorySampleRetentionLimit) { [void]$samples.Dequeue() }
    $samples.Enqueue($Snapshot)
    $script:lastMemorySample = $Snapshot
    $script:memorySampleCount++
}
function Invoke-Watchdog {
    if ($ownedChild.HasExited) { throw "Owned child exited unexpectedly (exit $($ownedChild.ExitCode)); inspect sanitized native logs." }
    $native = $ownedChild.Memory()
    $pdh = $counters.Sample()
    if (-not $pdh.ContainsKey('available_mib') -or $null -eq $pdh['available_mib']) { throw 'Safety prerequisite lost: Available MBytes must remain measurable.' }
    $available = [long]($pdh['available_mib'] * 1MB)
    $snapshot = [ordered]@{ elapsed_ms = $watch.Elapsed.TotalMilliseconds; phase = $phase; owned_pid = $ownedChild.Pid;
        available_bytes = $available; pdh = $pdh; memory_source = 'Windows PROCESS_MEMORY_COUNTERS_EX2 and bounded Job counters' }
    foreach ($key in $native.Keys) { $snapshot[$key] = $native[$key] }
    Add-MemorySample $snapshot
    Assert-SampleSafety $available $pdh['pages_input_per_sec'] $watch.Elapsed.TotalSeconds
    if ($watch.Elapsed.TotalSeconds -gt $effectiveTimeoutSeconds) { throw 'Calibration/benchmark exceeded bounded case timeout.' }
}
function Wait-OwnedTask([object]$Task) {
    while (-not $Task.IsCompleted) { Invoke-Watchdog; Start-Sleep -Milliseconds $sampleIntervalMs }
    Invoke-Watchdog
    return $Task.GetAwaiter().GetResult()
}
function Invoke-LocalRequest([string]$Route, [bool]$Authenticated, [object]$Body = $null, [int]$RequestTimeoutSeconds = 10) {
    $request = [Net.Http.HttpRequestMessage]::new($(if ($null -ne $Body) { [Net.Http.HttpMethod]::Post } else { [Net.Http.HttpMethod]::Get }), ($base + $Route))
    $cancel = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($RequestTimeoutSeconds))
    try {
        if ([KesherCalibration.OwnedProcess]::ListenerPid($port) -ne $ownedChild.Pid) { throw 'Loopback listener is not owned by the bounded child; no request or session key sent to another process.' }
        if ($Authenticated) {
            $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)
        }
        if ($null -ne $Body) { $request.Content = [Net.Http.StringContent]::new(($Body | ConvertTo-Json -Depth 12 -Compress), [Text.Encoding]::UTF8, 'application/json') }
        return Wait-OwnedTask ($http.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseContentRead, $cancel.Token))
    } finally { $request.Dispose(); $cancel.Dispose() }
}
function New-PrivateKeyFile([switch]$EmptyProbe) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $sid = $identity.User
        $script:keyDirectory = Join-Path $ResultDirectory ('session-private-' + [Guid]::NewGuid().ToString('N'))
        $directory = New-Item -ItemType Directory -Path $keyDirectory
        $security = [Security.AccessControl.DirectorySecurity]::new()
        $security.SetOwner($sid); $security.SetAccessRuleProtection($true, $false)
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid, [Security.AccessControl.FileSystemRights]::FullControl,
            ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit),
            [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
        $security.AddAccessRule($rule)
        [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]$directory, $security)
        $actual = [IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]$directory)
        if (-not $actual.AreAccessRulesProtected -or @($actual.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.IdentityReference -ne $sid -or $_.AccessControlType -ne 'Allow' }).Count) { throw 'Session directory ACL verification failed; no secret written.' }
        $script:keyPath = Join-Path $keyDirectory 'api-key'
        # Verify an empty file first. No key bytes exist before both ACL checks.
        [IO.File]::WriteAllBytes($keyPath, [byte[]]::new(0))
        $fileAcl = [IO.FileSystemAclExtensions]::GetAccessControl([IO.FileInfo]::new($keyPath))
        if (@($fileAcl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.IdentityReference -ne $sid -or $_.AccessControlType -ne 'Allow' }).Count) { throw 'Session file ACL verification failed.' }
        if (-not $EmptyProbe) {
            $script:token = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
            [IO.File]::WriteAllText($keyPath, $token, [Text.UTF8Encoding]::new($false))
        }
    } finally { $identity.Dispose() }
}

function Get-JsonDigest([object]$Value) {
    $json = ConvertTo-Json -InputObject $Value -Depth 15 -Compress
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($json))).ToLowerInvariant()
}
function Write-BenchmarkRecord([object]$Record) {
    $benchmarkWriter.WriteLine(($Record | ConvertTo-Json -Depth 15 -Compress)); $benchmarkWriter.Flush()
}
function Invoke-NativeBenchmarkCase([string]$Name, [int[]]$Prompt, [int]$Predict, [string]$Stage, [int]$Iteration) {
    $script:phase = "$Name/$Stage/$Iteration"
    $request = @{ prompt = $Prompt; n_predict = $Predict; cache_prompt = $false; stream = $false;
        ignore_eos = $true; temperature = 0; seed = 42; return_tokens = $true }
    $caseWatch = [Diagnostics.Stopwatch]::StartNew()
    $firstSample = $memorySampleCount
    $response = Invoke-LocalRequest '/completion' $true $request $TimeoutSeconds
    try {
        if (-not $response.IsSuccessStatusCode) { throw "Native benchmark HTTP status $([int]$response.StatusCode)." }
        $body = (Wait-OwnedTask ($response.Content.ReadAsStringAsync())) | ConvertFrom-Json
    } finally { $response.Dispose() }
    $timings = $body.timings
    $valid = [int]$timings.prompt_n -eq $Prompt.Count -and [int]$timings.predicted_n -eq $Predict -and
        [int]$timings.cache_n -eq 0 -and -not [bool]$body.truncated -and
        [double]$timings.prompt_ms -gt 0 -and [double]$timings.prompt_per_second -gt 0 -and
        ($Predict -eq 1 -or ([double]$timings.predicted_ms -gt 0 -and [double]$timings.predicted_per_second -gt 0))
    $record = [ordered]@{ case = $Name; stage = $Stage; iteration = $Iteration; validated = $valid;
        prompt_tokens = $Prompt.Count; requested_generation_tokens = $Predict; prompt_token_ids_sha256 = Get-JsonDigest $Prompt;
        native_timings = $timings; truncated = [bool]$body.truncated; stop_type = $body.stop_type;
        request_elapsed_ms = $caseWatch.Elapsed.TotalMilliseconds; first_memory_sample = $firstSample;
        after_memory_sample = $memorySampleCount; cold_warm = 'warm-only; resident server, uncontrolled filesystem cache';
        cache_prompt = $false; generation_throughput_interpretable = $Predict -gt 1; quality_claim = $false }
    Write-BenchmarkRecord $record
    if (-not $valid) { throw "Native $Name counts/cache/timings were inconsistent with the selected case; raw timing record retained." }
    return $record
}
function Get-RateSummary([object[]]$Records, [string]$Field) {
    $values = @($Records | ForEach-Object { [double]$_.native_timings.$Field } | Sort-Object)
    if (-not $values.Count) { return $null }
    $mean = [double](($values | Measure-Object -Average).Average)
    $sum = 0.0; foreach ($value in $values) { $sum += [Math]::Pow($value - $mean, 2) }
    $middle = [int][Math]::Floor($values.Count / 2)
    $median = if ($values.Count % 2) { $values[$middle] } else { ($values[$middle - 1] + $values[$middle]) / 2 }
    return [ordered]@{ count = $values.Count; mean = $mean; median = $median;
        p95 = $values[[Math]::Max(0, [int][Math]::Ceiling(0.95 * $values.Count) - 1)];
        minimum = $values[0]; maximum = $values[$values.Count - 1];
        sample_standard_deviation = if ($values.Count -gt 1) { [Math]::Sqrt($sum / ($values.Count - 1)) } else { $null } }
}
function Invoke-ThermalBenchmark([int[]]$Prompt) {
    $script:phase = 'thermal/continuous-decode'
    $request = $null; $response = $null; $reader = $null; $stream = $null; $cancel = $null
    $arrivals = [Collections.Generic.List[object]]::new()
    $thermalWatch = $null; $firstTokenLatencyMs = $null; $requestWatch = [Diagnostics.Stopwatch]::StartNew()
    $completedWindow = $false; $serverStopped = $false; $finalTimings = $null
    try {
        if ([KesherCalibration.OwnedProcess]::ListenerPid($port) -ne $ownedChild.Pid) { throw 'Thermal listener is not the owned child.' }
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, ($base + '/completion'))
        $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)
        $body = @{ prompt = $Prompt; n_predict = 4096 - $Prompt.Count; cache_prompt = $false; stream = $true;
            ignore_eos = $true; temperature = 0; seed = 42; return_tokens = $true; timings_per_token = $false }
        $request.Content = [Net.Http.StringContent]::new(($body | ConvertTo-Json -Depth 12 -Compress), [Text.Encoding]::UTF8, 'application/json')
        $cancel = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(600))
        $response = Wait-OwnedTask ($http.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cancel.Token))
        if (-not $response.IsSuccessStatusCode) { throw "Thermal HTTP status $([int]$response.StatusCode)." }
        $stream = Wait-OwnedTask ($response.Content.ReadAsStreamAsync())
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8)
        while (-not $serverStopped -and -not $completedWindow) {
            $lineTask = $reader.ReadLineAsync()
            while (-not $lineTask.IsCompleted) {
                Invoke-Watchdog
                if ($requestWatch.Elapsed.TotalSeconds -gt 600) { throw 'Thermal stream exceeded its 600-second request deadline.' }
                if ($null -ne $thermalWatch -and $thermalWatch.Elapsed.TotalSeconds -ge 300) { $completedWindow = $true; break }
                Start-Sleep -Milliseconds $sampleIntervalMs
            }
            if ($completedWindow) { break }
            Invoke-Watchdog
            $line = $lineTask.GetAwaiter().GetResult()
            if ($null -eq $line) { $serverStopped = $true; break }
            if (-not $line.StartsWith('data: ')) { continue }
            $payload = $line.Substring(6)
            if ($payload -eq '[DONE]') { $serverStopped = $true; break }
            $event = $payload | ConvertFrom-Json
            if ($null -ne $thermalWatch -and $thermalWatch.Elapsed.TotalSeconds -ge 300) { $completedWindow = $true; break }
            if ($event.PSObject.Properties['error']) { throw 'Native thermal stream reported an error.' }
            if ($event.PSObject.Properties['stop'] -and $event.stop) {
                $serverStopped = $true
                if ($event.PSObject.Properties['timings']) { $finalTimings = $event.timings }
                break
            }
            if ($event.PSObject.Properties['tokens'] -and @($event.tokens).Count -gt 0) {
                if ($null -eq $thermalWatch) { $firstTokenLatencyMs = $requestWatch.Elapsed.TotalMilliseconds; $thermalWatch = [Diagnostics.Stopwatch]::StartNew() }
                $arrival = [ordered]@{ elapsed_decode_ms = $thermalWatch.Elapsed.TotalMilliseconds; token_count = @($event.tokens).Count }
                $arrivals.Add($arrival)
                Write-BenchmarkRecord ([ordered]@{ case = 'thermal'; stage = 'token-arrival'; elapsed_decode_ms = $arrival.elapsed_decode_ms; token_count = $arrival.token_count })
            }
        }
    } finally {
        if ($null -ne $cancel) { $cancel.Cancel() }
        foreach ($resource in @($reader, $stream, $response, $request, $cancel)) { if ($null -ne $resource) { $resource.Dispose() } }
    }
    $firstCount = [int](($arrivals | Where-Object { $_.elapsed_decode_ms -lt 60000 } | Measure-Object token_count -Sum).Sum)
    $lastCount = [int](($arrivals | Where-Object { $_.elapsed_decode_ms -ge 240000 -and $_.elapsed_decode_ms -lt 300000 } | Measure-Object token_count -Sum).Sum)
    $record = [ordered]@{ case = 'thermal'; stage = 'summary'; completed_300s_continuous_decode = $completedWindow;
        elapsed_decode_ms = if ($null -ne $thermalWatch) { $thermalWatch.Elapsed.TotalMilliseconds } else { $null };
        first_token_latency_ms = $firstTokenLatencyMs; first_minute_tokens = $firstCount; last_minute_tokens = $lastCount;
        first_minute_client_arrival_tokens_per_second = if ($completedWindow) { $firstCount / 60.0 } else { $null };
        last_minute_client_arrival_tokens_per_second = if ($completedWindow) { $lastCount / 60.0 } else { $null };
        last_over_first_minute_rate = if ($completedWindow -and $firstCount -gt 0) { $lastCount / [double]$firstCount } else { $null };
        native_final_timings = $finalTimings; stopped_by_server_before_window = $serverStopped -and -not $completedWindow;
        observation = 'Client token-ID arrival times, 250ms watchdog polling; throughput change does not prove thermal cause';
        context = 4096; context_shift = $false; prompt_tokens = $Prompt.Count; maximum_generated_tokens = 4096 - $Prompt.Count;
        quality_claim = $false }
    Write-BenchmarkRecord $record
    if (-not $completedWindow -or $firstCount -eq 0 -or $lastCount -eq 0) { throw 'Continuous thermal window incomplete (possibly reached fixed context limit); no five-minute thermal comparison claimed.' }
    return $record
}
function Invoke-WarmBenchmark {
    $script:effectiveTimeoutSeconds = $BenchmarkTimeoutSeconds
    $script:phase = 'benchmark/tokenize'
    $script:benchmarkWriter = [IO.StreamWriter]::new((Join-Path $ResultDirectory 'benchmark.jsonl'), $false, [Text.UTF8Encoding]::new($false))
    $text = ('Reference entry: measured token processing preserves the complete model and original context. ' * 1024)
    $response = Invoke-LocalRequest '/tokenize' $true @{ content = $text; add_special = $true; parse_special = $false; with_pieces = $false }
    try {
        if (-not $response.IsSuccessStatusCode) { throw "Tokenize HTTP status $([int]$response.StatusCode)." }
        $tokens = [int[]]((Wait-OwnedTask ($response.Content.ReadAsStringAsync()) | ConvertFrom-Json).tokens)
    } finally { $response.Dispose() }
    if ($tokens.Count -lt 3968) { throw 'Synthetic tokenize fixture did not provide enough tokens for requested context stress.' }
    $summary = [Collections.Generic.List[object]]::new()
    foreach ($name in $selectedProbes) {
        if ($name -eq 'thermal') {
            # Thermal covers a single sustained window rather than pretending to
            # provide 30 independent five-minute windows. Explicit short warmups
            # run first; timing distributions belong to the selected pp/tg cases.
            for ($iteration = 1; $iteration -le $WarmupRuns; $iteration++) { [void](Invoke-NativeBenchmarkCase 'thermal-preparation' $tokens[0..63] 32 'warmup' $iteration) }
            $summary.Add((Invoke-ThermalBenchmark $tokens[0..63])); continue
        }
        $length = switch ($name) { 'pp500' {500}; 'pp1500' {1500}; 'pp3000' {3000}; 'tg128' {500}; 'full-context' {3968} }
        $predict = if ($name -in @('tg128', 'full-context')) { 128 } else { 1 }
        $prompt = [int[]]$tokens[0..($length - 1)]
        for ($iteration = 1; $iteration -le $WarmupRuns; $iteration++) { [void](Invoke-NativeBenchmarkCase $name $prompt $predict 'warmup' $iteration) }
        $measured = [Collections.Generic.List[object]]::new()
        for ($iteration = 1; $iteration -le $Repetitions; $iteration++) { $measured.Add((Invoke-NativeBenchmarkCase $name $prompt $predict 'measured' $iteration)) }
        $summary.Add([ordered]@{ case = $name; warmup_runs = $WarmupRuns; measured_runs = $measured.Count;
            prompt_tokens = $length; generated_tokens = $predict; context_budget_tokens = $length + $predict;
            prompt_token_ids_sha256 = Get-JsonDigest $prompt;
            prompt_tokens_per_second = Get-RateSummary $measured.ToArray() 'prompt_per_second';
            generation_tokens_per_second = if ($predict -gt 1) { Get-RateSummary $measured.ToArray() 'predicted_per_second' } else { $null } })
    }
    return $summary.ToArray()
}

$manifest = [ordered]@{ schema_version = 1; status = 'INITIALIZING'; started_at_utc = [DateTime]::UtcNow.ToString('o');
    execution_environment = $ExecutionEnvironment; classification = 'WINDOWS CAPABILITY PROBE — NO MODEL LOADED';
    production_adoption = $false; target_16gb = 'NOT MEASURED ON TARGET 16GB MACHINE';
    dataset = 'SILVER synthetic structural schema fixture; not quality/GOLD'; cold_warm = 'warm-only; filesystem cache uncontrolled';
    probe_only = [bool]$ProbeOnly; artifact_logs_safe = $false; source_commit = 'NOT AVAILABLE'; script_sha256 = Get-Sha256 $PSCommandPath;
    model_manifest_sha256 = Get-Sha256 $modelManifestPath; runtime_manifest_sha256 = Get-Sha256 $runtimeManifestPath;
    model_repository = $model.repository; model_revision = $model.revision; model_sha256 = $model.sha256; model_bytes = $model.bytes;
    model_filename = $model.filename; model_quantization = 'Q4_K_M';
    runtime_release = $runtime.release; runtime_source_commit = $runtime.commit;
    rationale = 'Linux same-model c4096 no-repack peak 7893659648 bytes motivates bounded Windows calibration; NOT Windows overhead proof';
    budgets = [ordered]@{ full_mapping_reserved_bytes = [long]$model.bytes; initial_private_commit_cap_bytes = $privateCommitLimitBytes;
        floor_bytes = $floorBytes; early_cancel_buffer_bytes = $cancelBufferBytes; required_available_bytes = $requiredAvailableBytes;
        cap_scope = 'Job PROCESS_MEMORY_LIMIT covers private commitment, not mmap/file-backed working set; total residency separately sampled';
        limitations = 'No hard guarantee of OS free-memory floor; unrelated processes and allocation between samples can consume memory' };
    config = [ordered]@{ context = 4096; parallel = 1; threads = $Threads; batch_threads = $Threads; batch = 512; ubatch = 128;
        cache_k = 'f16'; cache_v = 'f16'; cache_ram_mib = 0; ctx_checkpoints = 0; kv_unified = $true; cache_idle_slots = $false;
        repack = $false; load_mode = 'mmap'; flash_attention = 'off'; gpu_layers = 0; offline = $true;
        host = '127.0.0.1'; webui = $false; fixture_max_tokens = 32; fixture_temperature = 0; sample_interval_ms = $sampleIntervalMs };
    safety = [ordered]@{ suspended_before_job_assignment = 'NOT TESTED'; restricted_inherited_handles = 'NOT TESTED';
        kill_on_close = 'CONFIGURED, cleanup observed separately'; private_commit_limit = 'NOT TESTED'; current_user_only_key_acl = 'NOT TESTED';
        pdh_available_and_pages_input = 'NOT TESTED'; cleanup = 'PENDING' };
    coverage = [ordered]@{ authenticated_local_schema = 'NOT TESTED'; sampled_load_memory = 'NOT TESTED';
        pp500_1500_3000_tg = 'NOT TESTED'; full_context_occupancy = 'NOT TESTED'; three_warmups_thirty_samples = 'NOT TESTED';
        ballast0_2_4 = 'NOT TESTED'; sustained_5min_thermal = 'NOT TESTED'; cold_reboot_purge = 'NOT TESTED';
        power_ac_battery_matrix = 'NOT TESTED'; production_flag_performance_quality = 'NOT TESTED'; full_I3 = 'NOT VALIDATED' };
    admissions = $admissions }
if ($WarmBenchmark) {
    $manifest.benchmark = [ordered]@{ mode = 'resident server warm benchmark'; selected_probes = $selectedProbes;
        warmup_runs_per_pp_tg_case = $WarmupRuns; measured_runs_per_pp_tg_case = $Repetitions; ballast_gib = $BallastGiB;
        maximum_owned_process_elapsed_seconds = $BenchmarkTimeoutSeconds; context_shift = $false; cache_prompt = $false;
        thermal_windows = if ('thermal' -in $selectedProbes) {1} else {0};
        thermal_scope = 'One 300-second continuous decode window; not 30 independent thermal windows';
        protocol_document = 'scripts/bench/windows-i3-protocol.md'; cases = @() }
    $manifest.benchmark_config_sha256 = Get-JsonDigest $manifest.benchmark
}

try {
    if ($runtime.release -ne 'b11559' -or $runtime.commit -ne 'f2cc7282ce0042641df55e0e563b75e824e2b647' -or
        $model.repository -ne 'dicta-il/DictaLM-3.0-Nemotron-12B-Instruct-GGUF' -or $model.revision -ne 'aa611a04a6eecb3dcd2653e63ebe58d3050f5b03' -or
        $model.filename -ne 'DictaLM-3.0-Nemotron-12B-Instruct-Q4_K_M.gguf' -or
        $model.bytes -ne 7494495200 -or $model.sha256 -ne 'ca0af13ef66768ca835fbbdb122959a06fc9d42b23a7b2b2bc38bf75b09ab0e6') { throw 'Pinned model/runtime changed; calibration requires review.' }
    if (Get-Command git -ErrorAction SilentlyContinue) { $head = & git -C $repoRoot rev-parse HEAD; if ($LASTEXITCODE -eq 0) { $manifest.source_commit = $head.Trim() } }
    $system = Get-CimInstance Win32_OperatingSystem
    $processors = @(Get-CimInstance Win32_Processor)
    $logical = [int](($processors | Measure-Object NumberOfLogicalProcessors -Sum).Sum)
    if ($logical -lt 1) { throw 'Cannot determine actual logical CPU count.' }
    if (-not $PSBoundParameters.ContainsKey('Threads')) {
        $Threads = [Math]::Min(4, $logical)
        $manifest.config.threads = $Threads; $manifest.config.batch_threads = $Threads
    } elseif ($Threads -gt $logical) { throw 'Threads must not exceed actual logical CPUs; choose an explicit admitted diagnostic configuration.' }
    $manifest.hardware = [ordered]@{ os = $system.Caption; os_version = $system.Version; total_bytes = [long]$system.TotalVisibleMemorySize * 1024;
        processors = @($processors | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed);
        memory_modules = @(Get-CimInstance Win32_PhysicalMemory | Select-Object Capacity, Speed, ConfiguredClockSpeed);
        memory_channels = 'NOT MEASURED'; disks = @(Get-CimInstance Win32_DiskDrive | Select-Object Model, InterfaceType, Size);
        active_power_plan = (& powercfg /getactivescheme) -join ' '; topology_efficiency_classes = 'NOT TESTED' }
    try { $manifest.defender = [ordered]@{ status = 'MEASURED'; realtime_enabled = [bool](Get-MpComputerStatus).RealTimeProtectionEnabled; settings_changed = $false } }
    catch { $manifest.defender = [ordered]@{ status = 'NOT TESTED'; realtime_enabled = $null; settings_changed = $false } }
    $configJson = $manifest.config | ConvertTo-Json -Depth 12 -Compress
    $manifest.config_sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($configJson))).ToLowerInvariant()
    $initialAdmission = Test-Admission 'initial capability probe before downloads or model load' ([long]$BallastGiB * 1GB)
    $counters = [KesherCalibration.Counters]::new()
    $ready = Get-CounterReadiness
    $manifest.safety.pdh_available_and_pages_input = 'MEASURED: real English PDH gauges available; no zero-fill fallback'
    $manifest.initial_pdh = $ready; $manifest.unavailable_optional_counters = @($counters.Unavailable)
    New-PrivateKeyFile -EmptyProbe
    $manifest.safety.current_user_only_key_acl = 'MEASURED on empty file: protected current-user-only directory and inherited file ACL; no secret created by capability probe'
    [IO.File]::Delete($keyPath); [IO.Directory]::Delete($keyDirectory, $false)
    $keyPath = $null; $keyDirectory = $null
    # A tiny controlled child verifies nested Job assignment even when capacity
    # rejects model loading. No external source content is read by this child.
    $probe = [KesherCalibration.OwnedProcess]::Start((Join-Path $PSHOME 'pwsh.exe'),
        [string[]]@('-NoProfile', '-NonInteractive', '-Command', '[Threading.Thread]::Sleep(5000)'),
        (Join-Path $ResultDirectory 'job-probe.stdout.log'), (Join-Path $ResultDirectory 'job-probe.stderr.log'), [ulong]$privateCommitLimitBytes)
    $probeCleanupSafe = $false
    try {
        $probePeak = [ulong]0; $probeWatch = [Diagnostics.Stopwatch]::StartNew(); $probeSamples = 0
        while ($probeSamples -lt 2) {
            if ($probeWatch.Elapsed.TotalSeconds -gt 30) { throw 'Tiny owned Job probe exceeded its 30-second deadline; model run remains forbidden.' }
            if ($probe.HasExited) { throw 'Tiny owned Job child exited before controlled Job-close verification.' }
            $probeMemory = $probe.Memory(); $probePeak = [Math]::Max($probePeak, [ulong]$probeMemory['job_peak_private_committed_bytes'])
            $probeSamples++
            Start-Sleep -Milliseconds $sampleIntervalMs
        }
        $probeExit = $probe.StopAndWait()
        if (-not $probe.HasExited -or $probe.UsedFallbackTermination) { throw 'Tiny bounded Job-close cleanup did not directly stop its owned child; model run remains forbidden.' }
        $manifest.safety.suspended_before_job_assignment = 'MEASURED: tiny owned child successfully assigned while suspended, then resumed'
        $manifest.safety.restricted_inherited_handles = 'MEASURED: child created with explicit stdio-only handle list'
        $manifest.safety.private_commit_limit = 'CONFIGURED 2 GiB and queried on tiny probe; deliberate cap-exhaustion behavior NOT TESTED'
        $manifest.safety.kill_on_close = 'MEASURED: closing owned Job stopped tiny active child; no PID/name scan'
        $manifest.job_probe = [ordered]@{ exit_code_after_controlled_job_close = $probeExit; owned_child_stopped = $true; peak_private_commit_bytes = $probePeak; model_loaded = $false }
    } finally { $probe.Dispose(); $probeCleanupSafe = $true }
    if ($ProbeOnly) { $manifest.status = if ($initialAdmission) { 'ADMITTED_FOR_BOUNDED_CALIBRATION' } else { 'NOT_ADMITTED' }; $exitCode = 0; return }
    if (-not $initialAdmission) { $manifest.status = 'NOT_ADMITTED'; $exitCode = 2; return }
    $asset = $runtime.assets.'windows-x64'
    if ($asset.name -ne 'llama-b11559-bin-win-cpu-x64.zip' -or $asset.sha256 -ne '1228f133868c02a424bcf663a688e66d8c7d5499077649f305188f756f584377') { throw 'Pinned Windows CPU asset changed; review required.' }
    $archive = Join-Path $RuntimeDirectory $asset.name
    Get-VerifiedDownload ("https://github.com/ggml-org/llama.cpp/releases/download/$($runtime.release)/$($asset.name)") $archive $asset.sha256
    if (-not (Test-Admission 'before pinned model download')) { $manifest.status = 'NOT_ADMITTED'; $exitCode = 2; return }
    Get-VerifiedDownload ("https://huggingface.co/$($model.repository)/resolve/$($model.revision)/$($model.filename)") $ModelPath $model.sha256 ([long]$model.bytes)
    $extraction = Join-Path $RuntimeDirectory ('calibration-verified-' + [Guid]::NewGuid().ToString('N'))
    Expand-Archive -LiteralPath $archive -DestinationPath $extraction
    $executables = @(Get-ChildItem -LiteralPath $extraction -Filter 'llama-server.exe' -File -Recurse)
    if ($executables.Count -ne 1) { throw 'Verified runtime archive must contain exactly one llama-server.exe.' }
    $executable = $executables[0].FullName
    $manifest.native_binary_sha256 = Get-Sha256 $executable; $manifest.native_archive_sha256 = Get-Sha256 $archive
    if ($WarmBenchmark -and $BallastGiB -gt 0) {
        if (-not (Test-Admission 'before owned ballast reservation and page touch' ([long]$BallastGiB * 1GB))) { $manifest.status = 'NOT_ADMITTED'; $exitCode = 2; return }
        $ballast = [KesherCalibration.Ballast]::new([ulong]$BallastGiB * 1GB)
        $ballastWatch = [Diagnostics.Stopwatch]::StartNew()
        for ($offset = [long]0; $offset -lt ([long]$BallastGiB * 1GB); $offset += 64MB) {
            $ready = $counters.Sample()
            if (-not $ready.ContainsKey('available_mib') -or $null -eq $ready['available_mib'] -or
                -not $ready.ContainsKey('pages_input_per_sec') -or $null -eq $ready['pages_input_per_sec']) { throw 'Required PDH gauges unavailable during ballast touch.' }
            Assert-SampleSafety ([long]($ready['available_mib'] * 1MB)) $ready['pages_input_per_sec'] $ballastWatch.Elapsed.TotalSeconds
            $ballast.CommitAndTouch([ulong]$offset, [ulong]64MB)
        }
        $manifest.benchmark.ballast_bytes_committed_and_touched = [long]$BallastGiB * 1GB
        $pressureSince = $null
    }
    if (-not (Test-Admission 'immediately before bounded model child')) { $manifest.status = 'NOT_ADMITTED'; $exitCode = 2; return }
    New-PrivateKeyFile
    $manifest.safety.current_user_only_key_acl = 'MEASURED: protected current-user-only parent ACL and verified key inheritance; 256-bit random ephemeral key'
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    try { $listener.Start(); $port = $listener.LocalEndpoint.Port } finally { $listener.Stop() }
    $base = "http://127.0.0.1:$port"
    $arguments = [string[]]@('-m', $ModelPath, '--host', '127.0.0.1', '--port', [string]$port, '--api-key-file', $keyPath,
        '--no-webui', '--offline', '-ngl', '0', '-t', [string]$Threads, '-tb', [string]$Threads, '-c', '4096', '-np', '1',
        '-b', '512', '-ub', '128', '--cache-ram', '0', '--ctx-checkpoints', '0', '--kv-unified', '--no-cache-idle-slots',
        '--load-mode', 'mmap', '-ctk', 'f16', '-ctv', 'f16', '-fa', 'off', '--no-repack', '--verbosity', '4')
    if ($WarmBenchmark) { $arguments += '--no-context-shift' }
    $manifest.native_flags = @($arguments | ForEach-Object { if ($_ -eq $keyPath) { '<ephemeral-api-key-file>' } else { $_ } })
    $memoryWriter = [IO.StreamWriter]::new((Join-Path $ResultDirectory 'memory.jsonl'), $false, [Text.UTF8Encoding]::new($false))
    $handler = [Net.Http.HttpClientHandler]::new(); $handler.UseProxy = $false
    $http = [Net.Http.HttpClient]::new($handler); $http.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    $phase = 'load'; $watch.Restart()
    $ownedChild = [KesherCalibration.OwnedProcess]::Start($executable, $arguments,
        (Join-Path $ResultDirectory 'native.stdout.log'), (Join-Path $ResultDirectory 'native.stderr.log'), [ulong]$privateCommitLimitBytes)
    $manifest.owned_pid = $ownedChild.Pid
    $healthReady = $false
    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        Invoke-Watchdog
        $listeningPid = [KesherCalibration.OwnedProcess]::ListenerPid($port)
        if ($listeningPid -eq 0) { Start-Sleep -Milliseconds $sampleIntervalMs; continue }
        if ($listeningPid -ne $ownedChild.Pid) { throw 'Selected loopback port belongs to another process; calibration cancelled.' }
        $response = $null
        try { $response = Invoke-LocalRequest '/health' $false $null 2; $healthReady = $response.IsSuccessStatusCode }
        catch {
            $exception = $_.Exception; $transportFailure = $false
            while ($null -ne $exception) {
                if ($exception -is [Net.Http.HttpRequestException] -or $exception -is [OperationCanceledException]) { $transportFailure = $true; break }
                $exception = $exception.InnerException
            }
            if (-not $transportFailure -or $ownedChild.HasExited) { throw }
        }
        finally { if ($null -ne $response) { $response.Dispose() } }
        if ($healthReady) { break }
        Start-Sleep -Milliseconds $sampleIntervalMs
    }
    if (-not $healthReady -or [KesherCalibration.OwnedProcess]::ListenerPid($port) -ne $ownedChild.Pid) { throw 'Bounded child did not become the owned healthy loopback server.' }
    $manifest.load_to_health_ms = $watch.Elapsed.TotalMilliseconds
    $manifest.load_time_scope = 'Owned process launch through healthy API; filesystem cache uncontrolled, sampled single run'
    $manifest.memory_at_health = $lastMemorySample
    $phase = 'authentication-probe'
    $response = Invoke-LocalRequest '/v1/models' $false
    try { $manifest.authentication_required = [int]$response.StatusCode -in @(401, 403) } finally { $response.Dispose() }
    if (-not $manifest.authentication_required) { throw 'Content endpoint did not reject unauthenticated access.' }
    $phase = 'schema-fixture'; $fixtureWatch = [Diagnostics.Stopwatch]::StartNew()
    $fixture = @{ messages = @(@{ role = 'user'; content = 'Return the specified JSON value.' }); max_tokens = 32; temperature = 0;
        response_format = @{ type = 'json_schema'; json_schema = @{ name = 'fixture'; schema = @{ type = 'object';
            properties = @{ answer = @{ type = 'string'; enum = @('שלום') } }; required = @('answer'); additionalProperties = $false } } } }
    $response = Invoke-LocalRequest '/v1/chat/completions' $true $fixture $TimeoutSeconds
    try {
        if (-not $response.IsSuccessStatusCode) { throw "Schema fixture HTTP status $([int]$response.StatusCode)." }
        $body = (Wait-OwnedTask ($response.Content.ReadAsStringAsync())) | ConvertFrom-Json
        $answer = $body.choices[0].message.content | ConvertFrom-Json
        if (@($answer.PSObject.Properties).Count -ne 1 -or $answer.answer -cne 'שלום') { throw 'Structural JSON schema fixture failed exact expected value.' }
        $manifest.schema_valid = $true; $manifest.fixture_usage = $body.usage; $manifest.schema_fixture_ms = $fixtureWatch.Elapsed.TotalMilliseconds
    } finally { $response.Dispose() }
    $phase = 'complete'; Invoke-Watchdog
    $manifest.memory_after_fixture = $lastMemorySample
    $manifest.coverage.authenticated_local_schema = 'MEASURED single synthetic structural fixture; not answer quality'
    $manifest.coverage.sampled_load_memory = 'MEASURED single no-repack server process; partial sampling; not full-context stress or throughput'
    if ($WarmBenchmark) {
        $manifest.benchmark.cases = @(Invoke-WarmBenchmark)
        $manifest.benchmark.defender_realtime_requirement_met = $manifest.defender.status -eq 'MEASURED' -and $manifest.defender.realtime_enabled -eq $true
        $manifest.benchmark.performance_conditions_scope = 'Defender real-time observed only; cold/power/AC-battery/consumer-target conditions remain unvalidated'
        $manifest.coverage.three_warmups_thirty_samples = 'MEASURED on each selected pp/tg/full-context case; see case counts; thermal is one continuous window'
        if (@('pp500', 'pp1500', 'pp3000', 'tg128') | Where-Object { $_ -notin $selectedProbes }) {
            $manifest.coverage.pp500_1500_3000_tg = 'PARTIAL selected cases; combine separately hashed successful jobs before claiming the complete matrix'
        } else { $manifest.coverage.pp500_1500_3000_tg = 'MEASURED selected complete prompt/decode matrix; native counts/cache validated' }
        if ('full-context' -in $selectedProbes) { $manifest.coverage.full_context_occupancy = 'MEASURED 3968 prompt +128 requested/generated tokens at context4096; native counts/truncation validated' }
        if ('thermal' -in $selectedProbes) { $manifest.coverage.sustained_5min_thermal = 'MEASURED one continuous 300-second token-ID arrival window; first/last minute comparison, not proof of thermal causation' }
        $manifest.coverage.ballast0_2_4 = "MEASURED selected ballast $BallastGiB GiB only; other admitted matrix cases require separate successful jobs"
        $manifest.coverage.sampled_load_memory = 'MEASURED owned no-repack server load and selected resident-server benchmark; see streamed PDH/private/working-set samples'
    }
    $manifest.classification = 'MEASURED PARTIAL ON WINDOWS CLOUD HARDWARE — NOT TARGET 16GB PROOF'
    $manifest.status = 'MEASURED_PARTIAL'; $exitCode = 0
} catch {
    $manifest.status = 'FAILED'; $manifest.error = $_.Exception.Message
    if ($token) { $manifest.error = $manifest.error.Replace($token, '<redacted-ephemeral-api-key>') }
    $exitCode = 1
} finally {
    $cleanupSafe = $probeCleanupSafe
    if ($null -ne $ownedChild) {
        try { $manifest.native_exit_code_after_cleanup = $ownedChild.StopAndWait(); $manifest.job_cleanup_used_fallback = $ownedChild.UsedFallbackTermination; $manifest.owned_child_stopped = $true }
        catch { $manifest.owned_child_stopped = $false; $manifest.status = 'FAILED'; $exitCode = 1; $cleanupSafe = $false }
        finally { try { $ownedChild.Dispose() } catch { $manifest.owned_child_stopped = $false; $manifest.status = 'FAILED'; $exitCode = 1; $cleanupSafe = $false }; $ownedChild = $null }
    }
    foreach ($resource in @($memoryWriter, $benchmarkWriter, $http, $counters, $ballast)) {
        if ($null -ne $resource) { try { $resource.Dispose() } catch { $manifest.status = 'FAILED'; $exitCode = 1; $cleanupSafe = $false } }
    }
    $redacted = $false
    try {
        if ($token) {
            foreach ($name in @('native.stdout.log', 'native.stderr.log')) {
                $path = Join-Path $ResultDirectory $name
                if (Test-Path -LiteralPath $path) {
                    $content = [IO.File]::ReadAllText($path)
                    if ($content.Contains($token)) { [IO.File]::WriteAllText($path, $content.Replace($token, '<redacted-ephemeral-api-key>'), [Text.UTF8Encoding]::new($false)); $redacted = $true }
                    if ([IO.File]::ReadAllText($path).Contains($token)) { throw 'Ephemeral key remained in native log.' }
                }
            }
        }
    } catch { $manifest.log_inspection = 'FAILED inspection/redaction; native logs must not be uploaded'; $manifest.status = 'FAILED'; $exitCode = 1; $cleanupSafe = $false }
    try {
        if ($keyPath -and (Test-Path -LiteralPath $keyPath)) { [IO.File]::Delete($keyPath) }
        if ($keyDirectory -and (Test-Path -LiteralPath $keyDirectory)) { [IO.Directory]::Delete($keyDirectory, $false) }
        $manifest.safety.cleanup = 'Ephemeral key file/directory removed when created; owned-child stop observation recorded separately'
    } catch { $manifest.safety.cleanup = 'FAILED key cleanup; outputs must not be uploaded'; $manifest.status = 'FAILED'; $exitCode = 1; $cleanupSafe = $false }
    $manifest.artifact_logs_safe = $cleanupSafe
    $manifest.ephemeral_key_redacted_from_logs = $redacted
    $manifest.memory_sample_count = $memorySampleCount
    $manifest.memory_sample_retained_count = $samples.Count
    $manifest.memory_sample_retention_limit = $memorySampleRetentionLimit
    $manifest.memory_sample_indices = 'Zero-based global sample_index in streamed memory.jsonl; benchmark first inclusive / after exclusive'
    $manifest.memory_peak_scope = 'Incremental maxima across every successfully streamed sample, including evicted heap snapshots'
    foreach ($metric in $memoryPeakMetrics) { $manifest['peak_' + $metric] = $memoryPeaks[$metric] }
    $manifest.finished_at_utc = [DateTime]::UtcNow.ToString('o')
    Write-Json $manifest (Join-Path $ResultDirectory 'run-manifest.json')
    Write-Host "Windows calibration $($manifest.status); manifest: $ResultDirectory/run-manifest.json"
    exit $exitCode
}
