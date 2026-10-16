Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Fix DPI awareness BEFORE any window is created - PowerShell isn't DPI-aware by default,
# which can cause layout miscalculation in nested Dock+AutoScroll containers.
try {
    Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition '
        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    ' -ErrorAction SilentlyContinue
    [Win32.NativeMethods]::SetProcessDPIAware() | Out-Null
} catch {}
[System.Windows.Forms.Application]::EnableVisualStyles()

# ============================================================
#  Look at the Latency - v17 Smart Gaming + Artwork (stable scroll retained)
#  Features: theme presets, synthetic LOOK score, game library + optional Steam artwork, reversible game profile,
#  Adobe app scan, vendor graphics panel launcher and baseline/compare OC workflow.
# ============================================================

try {
    $scriptPath = $null
    if ($PSCommandPath) { $scriptPath = $PSCommandPath }
    elseif ($MyInvocation.MyCommand.Path) { $scriptPath = $MyInvocation.MyCommand.Path }
    else { $scriptPath = $MyInvocation.MyCommand.Definition }

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        if (-not $scriptPath -or -not (Test-Path $scriptPath)) {
            [System.Windows.Forms.MessageBox]::Show("Script path not found. Copy the .ps1 to Desktop and run again.", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::None) | Out-Null
            exit
        }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "powershell.exe"
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
        $psi.Verb = "runas"
        try { [System.Diagnostics.Process]::Start($psi) | Out-Null }
        catch { [System.Windows.Forms.MessageBox]::Show("Admin access denied or failed.`n$($_.Exception.Message)", "Admin Required", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::None) | Out-Null }
        exit
    }

    $rpChoice = [System.Windows.Forms.MessageBox]::Show(
        "Create a System Restore Point before making changes?`n`nRecommended.",
        "Look at the Latency - Setup",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::None)
    if ($rpChoice -eq [System.Windows.Forms.DialogResult]::Yes) {
        try {
            Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
            Checkpoint-Computer -Description "LookAtTheLatency-BeforeOptimize" -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Could not create a restore point (Windows limits one per 24h, or System Restore is off). Continuing.", "Notice", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::None) | Out-Null
        }
    }

    # ---------------- Gradient panel class ----------------
    Add-Type @"
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;
public class GradientPanel : Panel {
    public Color ColorTop = Color.FromArgb(26,30,26);
    public Color ColorBottom = Color.FromArgb(14,16,14);
    public float Angle = 90f;
    protected override void OnPaint(PaintEventArgs e) {
        using (LinearGradientBrush b = new LinearGradientBrush(this.ClientRectangle, ColorTop, ColorBottom, Angle)) {
            e.Graphics.FillRectangle(b, this.ClientRectangle);
        }
    }
}
"@ -ReferencedAssemblies System.Drawing, System.Windows.Forms

    # ---------------- Stable scroll wheel filter ----------------
    # Intercept WM_MOUSEWHEEL once at the message level. Adding MouseWheel handlers to
    # every nested control can cause duplicate handling and AutoScrollPosition resets.
    Add-Type @"
using System;
using System.Drawing;
using System.Windows.Forms;

public sealed class StableSmoothWheelFilter : IMessageFilter, IDisposable {
    private readonly Panel _host;
    private readonly Timer _timer;
    private int _targetY;
    private bool _disposed;

    public StableSmoothWheelFilter(Panel host) {
        _host = host;
        _targetY = 0;
        _timer = new Timer();
        _timer.Interval = 12;
        _timer.Tick += AnimateStep;
    }

    private int MaxScroll() {
        if (_host == null || _host.IsDisposed) return 0;
        int extent = _host.AutoScrollMinSize.Height;
        if (extent <= 0) extent = _host.DisplayRectangle.Height;
        return Math.Max(0, extent - _host.ClientSize.Height);
    }

    private static int Clamp(int value, int minimum, int maximum) {
        return Math.Max(minimum, Math.Min(maximum, value));
    }

    private Control DeepestAt(Control parent, Point screenPoint) {
        if (parent == null || parent.IsDisposed) return parent;
        Point local = parent.PointToClient(screenPoint);
        Control child = parent.GetChildAtPoint(local, GetChildAtPointSkip.Invisible);
        if (child == null) return parent;
        return DeepestAt(child, screenPoint);
    }

    private bool IsNativeScrollableControlUnderPointer() {
        Control underPointer = DeepestAt(_host, Control.MousePosition);
        ComboBox combo = underPointer as ComboBox;
        if (combo != null) return true;
        TextBox text = underPointer as TextBox;
        if (text != null && text.Multiline && text.ScrollBars != ScrollBars.None) return true;
        RichTextBox rich = underPointer as RichTextBox;
        if (rich != null && rich.ScrollBars != RichTextBoxScrollBars.None) return true;
        ListBox list = underPointer as ListBox;
        if (list != null && list.ScrollAlwaysVisible) return true;
        return false;
    }

    public bool PreFilterMessage(ref Message m) {
        if (_disposed || _host == null || _host.IsDisposed || !_host.IsHandleCreated || m.Msg != 0x020A) return false;
        Rectangle hostBounds = _host.RectangleToScreen(_host.ClientRectangle);
        if (!hostBounds.Contains(Control.MousePosition)) return false;
        if (IsNativeScrollableControlUnderPointer()) return false;

        int delta = unchecked((short)((m.WParam.ToInt64() >> 16) & 0xffff));
        if (delta == 0) return false;

        int current = Math.Max(0, -_host.AutoScrollPosition.Y);
        int max = MaxScroll();
        int lines = SystemInformation.MouseWheelScrollLines;
        int pixels = lines < 0 ? Math.Max(80, _host.ClientSize.Height - 40) : Math.Max(1, lines) * 24;
        int basis = _timer.Enabled ? _targetY : current;
        _targetY = Clamp(basis - (int)Math.Round((delta / 120.0) * pixels), 0, max);
        if (max <= 0) {
            _targetY = 0;
            _timer.Stop();
            _host.AutoScrollPosition = new Point(0, 0);
        } else {
            _timer.Start();
        }
        // Returning true prevents the same wheel message from also scrolling the host natively.
        return true;
    }

    private void AnimateStep(object sender, EventArgs e) {
        if (_disposed || _host == null || _host.IsDisposed) { _timer.Stop(); return; }
        int max = MaxScroll();
        _targetY = Clamp(_targetY, 0, max);
        int current = Math.Max(0, -_host.AutoScrollPosition.Y);
        int diff = _targetY - current;
        if (Math.Abs(diff) < 2) {
            _host.AutoScrollPosition = new Point(0, _targetY);
            _timer.Stop();
            return;
        }
        int step = Math.Max(2, (int)Math.Ceiling(Math.Abs(diff) * 0.28));
        int next = current + (diff > 0 ? step : -step);
        _host.AutoScrollPosition = new Point(0, Clamp(next, 0, max));
    }

    public void SetPosition(int y) {
        if (_disposed || _host == null || _host.IsDisposed) return;
        _timer.Stop();
        _targetY = Clamp(y, 0, MaxScroll());
        _host.AutoScrollPosition = new Point(0, _targetY);
    }

    public void Dispose() {
        if (_disposed) return;
        _disposed = true;
        _timer.Stop();
        _timer.Dispose();
    }
}
"@ -ReferencedAssemblies System.Drawing, System.Windows.Forms

    # ---------------- Colors ----------------
    $cBg        = [System.Drawing.Color]::FromArgb(10,12,10)
    $cCard      = [System.Drawing.Color]::FromArgb(22,24,22)
    $cCardHover = [System.Drawing.Color]::FromArgb(32,36,32)
    $cGreen     = [System.Drawing.Color]::FromArgb(60,220,110)
    $cGreenDark = [System.Drawing.Color]::FromArgb(20,120,60)
    $cText      = [System.Drawing.Color]::FromArgb(235,240,235)
    $cSubText   = [System.Drawing.Color]::FromArgb(150,160,150)
    $cWarn      = [System.Drawing.Color]::FromArgb(230,190,90)
    $script:themeDefinitions = [ordered]@{
        Emerald = @{ Background=[System.Drawing.Color]::FromArgb(10,12,10); Card=[System.Drawing.Color]::FromArgb(22,24,22); Hover=[System.Drawing.Color]::FromArgb(32,36,32); Accent=[System.Drawing.Color]::FromArgb(60,220,110); AccentDark=[System.Drawing.Color]::FromArgb(20,120,60); Text=[System.Drawing.Color]::FromArgb(235,240,235); SubText=[System.Drawing.Color]::FromArgb(150,160,150); Warning=[System.Drawing.Color]::FromArgb(230,190,90); Header=[System.Drawing.Color]::FromArgb(18,32,20); Log=[System.Drawing.Color]::FromArgb(6,10,8); Danger=[System.Drawing.Color]::FromArgb(150,60,60) }
        Ocean   = @{ Background=[System.Drawing.Color]::FromArgb(9,14,22); Card=[System.Drawing.Color]::FromArgb(19,28,42); Hover=[System.Drawing.Color]::FromArgb(30,44,62); Accent=[System.Drawing.Color]::FromArgb(72,190,255); AccentDark=[System.Drawing.Color]::FromArgb(22,85,130); Text=[System.Drawing.Color]::FromArgb(235,243,250); SubText=[System.Drawing.Color]::FromArgb(151,174,194); Warning=[System.Drawing.Color]::FromArgb(255,198,95); Header=[System.Drawing.Color]::FromArgb(12,36,60); Log=[System.Drawing.Color]::FromArgb(5,10,18); Danger=[System.Drawing.Color]::FromArgb(145,52,60) }
        Violet  = @{ Background=[System.Drawing.Color]::FromArgb(17,12,24); Card=[System.Drawing.Color]::FromArgb(31,22,43); Hover=[System.Drawing.Color]::FromArgb(48,34,65); Accent=[System.Drawing.Color]::FromArgb(190,130,255); AccentDark=[System.Drawing.Color]::FromArgb(91,46,135); Text=[System.Drawing.Color]::FromArgb(245,239,252); SubText=[System.Drawing.Color]::FromArgb(180,164,195); Warning=[System.Drawing.Color]::FromArgb(255,203,112); Header=[System.Drawing.Color]::FromArgb(43,22,62); Log=[System.Drawing.Color]::FromArgb(12,8,18); Danger=[System.Drawing.Color]::FromArgb(150,55,75) }
        Amber   = @{ Background=[System.Drawing.Color]::FromArgb(22,16,8); Card=[System.Drawing.Color]::FromArgb(39,29,15); Hover=[System.Drawing.Color]::FromArgb(58,43,22); Accent=[System.Drawing.Color]::FromArgb(255,183,66); AccentDark=[System.Drawing.Color]::FromArgb(135,79,15); Text=[System.Drawing.Color]::FromArgb(250,244,232); SubText=[System.Drawing.Color]::FromArgb(193,177,150); Warning=[System.Drawing.Color]::FromArgb(255,215,125); Header=[System.Drawing.Color]::FromArgb(58,37,10); Log=[System.Drawing.Color]::FromArgb(14,10,5); Danger=[System.Drawing.Color]::FromArgb(150,52,45) }
        Rose    = @{ Background=[System.Drawing.Color]::FromArgb(22,10,15); Card=[System.Drawing.Color]::FromArgb(40,20,29); Hover=[System.Drawing.Color]::FromArgb(60,30,43); Accent=[System.Drawing.Color]::FromArgb(255,105,150); AccentDark=[System.Drawing.Color]::FromArgb(135,35,73); Text=[System.Drawing.Color]::FromArgb(250,238,244); SubText=[System.Drawing.Color]::FromArgb(194,158,174); Warning=[System.Drawing.Color]::FromArgb(255,198,120); Header=[System.Drawing.Color]::FromArgb(57,18,37); Log=[System.Drawing.Color]::FromArgb(13,6,9); Danger=[System.Drawing.Color]::FromArgb(155,45,50) }
        Light   = @{ Background=[System.Drawing.Color]::FromArgb(237,242,248); Card=[System.Drawing.Color]::FromArgb(255,255,255); Hover=[System.Drawing.Color]::FromArgb(222,231,241); Accent=[System.Drawing.Color]::FromArgb(0,116,170); AccentDark=[System.Drawing.Color]::FromArgb(20,82,122); Text=[System.Drawing.Color]::FromArgb(25,34,45); SubText=[System.Drawing.Color]::FromArgb(83,96,110); Warning=[System.Drawing.Color]::FromArgb(153,83,0); Header=[System.Drawing.Color]::FromArgb(211,228,244); Log=[System.Drawing.Color]::FromArgb(247,250,253); Danger=[System.Drawing.Color]::FromArgb(160,45,52) }
    }
    $script:themePalette = $script:themeDefinitions['Emerald']
    # Shared mutable holder is intentionally captured by event closures created with GetNewClosure().
    $script:themePaletteRef = [pscustomobject]@{ Current = $script:themePalette }
    $fontTitle  = New-Object System.Drawing.Font("Segoe UI", 20, [System.Drawing.FontStyle]::Bold)
    $fontCardT  = New-Object System.Drawing.Font("Segoe UI", 10.5, [System.Drawing.FontStyle]::Bold)
    $fontCardS  = New-Object System.Drawing.Font("Segoe UI", 8.5)
    $fontNormal = New-Object System.Drawing.Font("Segoe UI", 9.5)
    $fontSmall  = New-Object System.Drawing.Font("Segoe UI", 8.5)

    # ---------------- Logo (speedometer/gauge - distinct from a lightning bolt) ----------------
    $logoBmp = New-Object System.Drawing.Bitmap(64,64)
    $g = [System.Drawing.Graphics]::FromImage($logoBmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)
    $circleBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.Rectangle(0,0,64,64)), ([System.Drawing.Color]::FromArgb(15,20,18)), ([System.Drawing.Color]::FromArgb(5,8,6)), 45)
    $g.FillEllipse($circleBrush, 2, 2, 60, 60)
    $arcPen = New-Object System.Drawing.Pen($cGreen, 5)
    $arcPen.StartCap = 'Round'; $arcPen.EndCap = 'Round'
    $g.DrawArc($arcPen, 10, 10, 44, 44, 135, 270)
    $needlePen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 3.5)
    $needlePen.StartCap = 'Round'; $needlePen.EndCap = 'Round'
    $g.DrawLine($needlePen, 32, 32, 46, 20)
    $hubBrush = New-Object System.Drawing.SolidBrush($cGreen)
    $g.FillEllipse($hubBrush, 27, 27, 10, 10)
    $g.Dispose()
    $logoIcon = [System.Drawing.Icon]::FromHandle($logoBmp.GetHicon())

    # ---------------- Animated toggle switch (replaces plain checkboxes) ----------------
    Add-Type @"
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

public class ToggleSwitch : Control {
    private bool _checked = false;
    private float _knobPos = 3f;
    public Color OnColor = Color.FromArgb(60,220,110);
    public Color OffColor = Color.FromArgb(70,74,70);
    public event EventHandler CheckedChangedX;
    private System.Windows.Forms.Timer animTimer;

    public ToggleSwitch() {
        this.Size = new Size(42, 22);
        this.DoubleBuffered = true;
        this.Cursor = Cursors.Hand;
        animTimer = new System.Windows.Forms.Timer();
        animTimer.Interval = 12;
        animTimer.Tick += (s, e) => AnimateStep();
        this.Click += (s, e) => { Checked = !Checked; };
    }
    public bool Checked {
        get { return _checked; }
        set { _checked = value; animTimer.Start(); if (CheckedChangedX != null) CheckedChangedX(this, EventArgs.Empty); }
    }
    private void AnimateStep() {
        float target = _checked ? (this.Width - this.Height + 3) : 3f;
        float speed = 3.5f;
        if (Math.Abs(_knobPos - target) < speed) { _knobPos = target; animTimer.Stop(); }
        else if (_knobPos < target) { _knobPos += speed; }
        else { _knobPos -= speed; }
        this.Invalidate();
    }
    protected override void OnPaint(PaintEventArgs e) {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        Color trackColor = _checked ? OnColor : OffColor;
        using (GraphicsPath path = RoundedRect(new Rectangle(0,0,this.Width-1,this.Height-1), this.Height/2)) {
            using (SolidBrush b = new SolidBrush(Color.FromArgb(60, trackColor))) { e.Graphics.FillPath(b, path); }
            using (Pen p = new Pen(trackColor, 1.5f)) { e.Graphics.DrawPath(p, path); }
        }
        int knobSize = this.Height - 6;
        using (SolidBrush kb = new SolidBrush(trackColor)) {
            e.Graphics.FillEllipse(kb, _knobPos, 3, knobSize, knobSize);
        }
    }
    private GraphicsPath RoundedRect(Rectangle bounds, int radius) {
        GraphicsPath path = new GraphicsPath();
        int d = radius * 2;
        path.AddArc(bounds.X, bounds.Y, d, d, 180, 90);
        path.AddArc(bounds.Right - d, bounds.Y, d, d, 270, 90);
        path.AddArc(bounds.Right - d, bounds.Bottom - d, d, d, 0, 90);
        path.AddArc(bounds.X, bounds.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }
}
"@ -ReferencedAssemblies System.Drawing, System.Windows.Forms

    # ---------------- C# network probe helper (compiled at runtime - no extra install needed) ----------------
    Add-Type @"
using System;
using System.Net;
using System.Net.Sockets;
using System.Diagnostics;

public class NetProbe {
    // Measures DNS resolution time + a TCP connect time to a well-known host,
    // using the DNS server currently configured on the system (via .NET's resolver).
    public static string TestResolveAndConnect(string hostname, int port) {
        var sw = Stopwatch.StartNew();
        IPAddress[] addrs;
        try {
            addrs = Dns.GetHostAddresses(hostname);
        } catch (Exception ex) {
            return "RESOLVE_FAILED:" + ex.Message;
        }
        long resolveMs = sw.ElapsedMilliseconds;
        sw.Restart();
        try {
            using (TcpClient tcp = new TcpClient()) {
                var result = tcp.BeginConnect(addrs[0], port, null, null);
                bool ok = result.AsyncWaitHandle.WaitOne(2000);
                if (!ok || !tcp.Connected) return "CONNECT_FAILED:timeout";
                tcp.EndConnect(result);
            }
        } catch (Exception ex) {
            return "CONNECT_FAILED:" + ex.Message;
        }
        long connectMs = sw.ElapsedMilliseconds;
        return "OK:" + resolveMs + ":" + connectMs + ":" + addrs[0];
    }
}
"@ -ReferencedAssemblies System.Net, System.Net.Sockets -ErrorAction SilentlyContinue

    # ---------------- Animated text field (floating label + typing underline) ----------------
    Add-Type @"
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

public class AnimatedTextField : Panel {
    public TextBox Input;
    private Label _floatLabel;
    private string _placeholder;
    private float _underlineProgress = 0f;
    private System.Windows.Forms.Timer _timer;
    public Color AccentColor = Color.FromArgb(60,220,110);
    public Color IdleColor = Color.FromArgb(80,86,80);

    public AnimatedTextField(string placeholder, string defaultValue) {
        _placeholder = placeholder;
        this.Size = new Size(180, 46);
        this.DoubleBuffered = true;
        this.BackColor = Color.FromArgb(16,18,16);

        _floatLabel = new Label();
        _floatLabel.Text = placeholder;
        _floatLabel.ForeColor = Color.FromArgb(150,160,150);
        _floatLabel.Font = new Font("Segoe UI", 8.5f);
        _floatLabel.AutoSize = true;
        _floatLabel.Location = new Point(8, 6);
        _floatLabel.BackColor = Color.Transparent;
        this.Controls.Add(_floatLabel);

        Input = new TextBox();
        Input.BorderStyle = BorderStyle.None;
        Input.Font = new Font("Segoe UI", 10f);
        Input.ForeColor = Color.White;
        Input.BackColor = Color.FromArgb(16,18,16);
        Input.Location = new Point(8, 22);
        Input.Width = this.Width - 16;
        Input.Text = defaultValue;
        Input.Enter += (s, e) => { _timer.Start(); };
        Input.Leave += (s, e) => { _timer.Start(); };
        Input.TextChanged += (s, e) => { this.Invalidate(); };
        this.Controls.Add(Input);

        _timer = new System.Windows.Forms.Timer();
        _timer.Interval = 12;
        _timer.Tick += (s, e) => {
            float target = Input.Focused ? 1f : 0f;
            float step = 0.15f;
            if (Math.Abs(_underlineProgress - target) < step) { _underlineProgress = target; _timer.Stop(); }
            else if (_underlineProgress < target) { _underlineProgress += step; }
            else { _underlineProgress -= step; }
            this.Invalidate();
        };
    }

    protected override void OnResize(EventArgs e) {
        base.OnResize(e);
        if (Input != null) Input.Width = this.Width - 16;
    }

    protected override void OnPaint(PaintEventArgs e) {
        base.OnPaint(e);
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        int y = this.Height - 3;
        using (Pen idlePen = new Pen(IdleColor, 1.5f)) {
            e.Graphics.DrawLine(idlePen, 4, y, this.Width - 4, y);
        }
        if (_underlineProgress > 0.01f) {
            float w = (this.Width - 8) * _underlineProgress;
            float cx = this.Width / 2f;
            using (Pen accentPen = new Pen(AccentColor, 2.2f)) {
                e.Graphics.DrawLine(accentPen, cx - w/2, y, cx + w/2, y);
            }
        }
    }
}
"@ -ReferencedAssemblies System.Drawing, System.Windows.Forms -ErrorAction SilentlyContinue

    function New-ToggleRow($labelText, $y, $parent) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $labelText
        $lbl.Font = $fontNormal; $lbl.ForeColor = $cText; $lbl.AutoSize = $true
        $lbl.Location = New-Object System.Drawing.Point(60,$y)
        $tgl = New-Object ToggleSwitch
        $tgl.Location = New-Object System.Drawing.Point(10,($y-2))
        $parent.Controls.AddRange(@($tgl,$lbl))
        return $tgl
    }

    # ---------------- Custom synthesized UI audio with hard mute/stop ----------------
    # Native PlaySound is used only with in-memory, app-generated WAV data. The mute gate
    # exists both here and in the native helper so no queued/cached effect can bypass OFF.
    if (-not ('LookAtLatencyAudioV14' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class LookAtLatencyAudioV14 {
    [DllImport("winmm.dll", EntryPoint="PlaySoundW", SetLastError=true)]
    private static extern bool PlaySound(IntPtr sound, IntPtr module, uint flags);
    private const uint SND_ASYNC = 0x0001;
    private const uint SND_NODEFAULT = 0x0002;
    private const uint SND_MEMORY = 0x0004;
    private static readonly object Gate = new object();
    private static GCHandle pinned;
    private static byte[] currentWave;
    private static bool muted = false;

    public static void SetMuted(bool value) {
        lock (Gate) {
            muted = value;
            if (muted) StopInternal();
        }
    }

    public static bool Play(byte[] wave) {
        if (wave == null || wave.Length < 44) return false;
        lock (Gate) {
            if (muted) return false;
            StopInternal();
            currentWave = wave;
            pinned = GCHandle.Alloc(currentWave, GCHandleType.Pinned);
            bool ok = PlaySound(pinned.AddrOfPinnedObject(), IntPtr.Zero,
                                SND_ASYNC | SND_MEMORY | SND_NODEFAULT);
            if (!ok) StopInternal();
            return ok;
        }
    }

    public static void Stop() {
        lock (Gate) { StopInternal(); }
    }

    private static void StopInternal() {
        // PlaySound(NULL, NULL, 0) stops the current asynchronous PlaySound operation.
        try { PlaySound(IntPtr.Zero, IntPtr.Zero, 0); } catch { }
        if (pinned.IsAllocated) pinned.Free();
        currentWave = null;
    }
}
'@ -ErrorAction Stop
    }

    $script:uiSoundsEnabled = $true
    $script:uiSoundStateRef = [pscustomobject]@{ Enabled = $true }
    $script:uiSoundCache = @{}
    [LookAtLatencyAudioV14]::SetMuted($false)

    function New-UiToneWave([int]$Frequency, [int]$DurationMs, [double]$Volume = 0.20) {
        $sampleRate = 22050
        $sampleCount = [int]([Math]::Max(1, [Math]::Round($sampleRate * $DurationMs / 1000.0)))
        $dataBytes = $sampleCount * 2
        $stream = New-Object System.IO.MemoryStream
        $writer = New-Object System.IO.BinaryWriter($stream)
        try {
            $writer.Write([byte[]][System.Text.Encoding]::ASCII.GetBytes('RIFF'))
            $writer.Write([int](36 + $dataBytes))
            $writer.Write([byte[]][System.Text.Encoding]::ASCII.GetBytes('WAVE'))
            $writer.Write([byte[]][System.Text.Encoding]::ASCII.GetBytes('fmt '))
            $writer.Write([int]16)
            $writer.Write([int16]1)
            $writer.Write([int16]1)
            $writer.Write([int]$sampleRate)
            $writer.Write([int]($sampleRate * 2))
            $writer.Write([int16]2)
            $writer.Write([int16]16)
            $writer.Write([byte[]][System.Text.Encoding]::ASCII.GetBytes('data'))
            $writer.Write([int]$dataBytes)
            for ($i = 0; $i -lt $sampleCount; $i++) {
                $t = $i / [double]$sampleRate
                $fadeIn = [Math]::Min(1.0, $i / [Math]::Max(1.0, $sampleRate * 0.006))
                $fadeOut = [Math]::Min(1.0, ($sampleCount - $i) / [Math]::Max(1.0, $sampleRate * 0.015))
                $edge = [Math]::Min($fadeIn, $fadeOut)
                $value = [Math]::Sin(2.0 * [Math]::PI * $Frequency * $t) * $Volume * $edge
                $pcm = [int]([Math]::Max(-1.0, [Math]::Min(1.0, $value)) * 32767)
                $writer.Write([int16]$pcm)
            }
            $writer.Flush()
            return ,([byte[]]$stream.ToArray())
        } finally {
            try { $writer.Dispose() } catch {}
            try { $stream.Dispose() } catch {}
        }
    }

    function Initialize-UiSoundAssets {
        $specs = @{
            click    = @(720, 32, 0.17)
            navigate = @(540, 52, 0.19)
            success  = @(920, 82, 0.20)
            warning  = @(390, 72, 0.18)
        }
        foreach ($name in $specs.Keys) {
            try { $script:uiSoundCache[$name] = New-UiToneWave $specs[$name][0] $specs[$name][1] $specs[$name][2] } catch {}
        }
    }

    function Stop-UiSounds {
        # Stop the native asynchronous player, then make a second mute-state check happen in C#.
        try { [LookAtLatencyAudioV14]::Stop() } catch {}
    }

    function Dispose-UiSounds {
        Stop-UiSounds
        $script:uiSoundCache.Clear()
    }

    function Invoke-UiSound([string]$Kind) {
        # Both gates are required: PowerShell gate prevents calls; native gate prevents races.
        if (-not $script:uiSoundStateRef.Enabled) { return }
        try {
            if (-not $script:uiSoundCache.ContainsKey($Kind)) { $Kind = 'click' }
            $wave = [byte[]]$script:uiSoundCache[$Kind]
            if ($script:uiSoundStateRef.Enabled -and $wave) {
                [void][LookAtLatencyAudioV14]::Play($wave)
            }
        } catch { }
    }

    Initialize-UiSoundAssets

    # ---------------- Splash / opening animation ----------------
    $splash = New-Object System.Windows.Forms.Form
    $splash.FormBorderStyle = 'None'
    $splash.Size = New-Object System.Drawing.Size(420,220)
    $splash.StartPosition = 'CenterScreen'
    $splash.BackColor = [System.Drawing.Color]::FromArgb(8,10,8)
    $splashLogo = New-Object System.Windows.Forms.PictureBox
    $splashLogo.Image = $logoBmp
    $splashLogo.Size = New-Object System.Drawing.Size(56,56)
    $splashLogo.Location = New-Object System.Drawing.Point(182,26)
    $splashLogo.SizeMode = 'Zoom'
    $splash.Controls.Add($splashLogo)
    $splashTitle = New-Object System.Windows.Forms.Label
    $splashTitle.Text = "Look at the Latency"
    $splashTitle.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
    $splashTitle.ForeColor = [System.Drawing.Color]::White
    $splashTitle.AutoSize = $true
    $splashTitle.Location = New-Object System.Drawing.Point(115,90)
    $splash.Controls.Add($splashTitle)
    $splashStatus = New-Object System.Windows.Forms.Label
    $splashStatus.Text = "Starting local diagnostics..."
    $splashStatus.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $splashStatus.ForeColor = $cGreen
    $splashStatus.AutoSize = $true
    $splashStatus.Location = New-Object System.Drawing.Point(120,130)
    $splash.Controls.Add($splashStatus)
    $splashBar = New-Object System.Windows.Forms.ProgressBar
    $splashBar.Location = New-Object System.Drawing.Point(20,165)
    $splashBar.Size = New-Object System.Drawing.Size(380,18)
    $splashBar.Style = 'Continuous'
    $splash.Controls.Add($splashBar)

    $splashStep = 0
    $splashTimer = New-Object System.Windows.Forms.Timer
    $splashTimer.Interval = 22
    $splashTimer.Add_Tick({
        $splashStep += 2
        $splashBar.Value = [Math]::Min($splashStep,100)
        if ($splashStep -lt 35) { $splashStatus.Text = "Preparing interface..." }
        elseif ($splashStep -lt 70) { $splashStatus.Text = "Loading local gaming assistant..." }
        else { $splashStatus.Text = "Ready..." }
        if ($splashStep -ge 100) { $splashTimer.Stop(); $splash.Close() }
    })
    # Hard failsafe: no matter what, force-close the splash after ~3 seconds total.
    $splashFailsafe = New-Object System.Windows.Forms.Timer
    $splashFailsafe.Interval = 3000
    $splashFailsafe.Add_Tick({
        $splashFailsafe.Stop()
        $splashTimer.Stop()
        try { $splash.Close() } catch {}
    })
    $splash.Add_Shown({ $splashTimer.Start(); $splashFailsafe.Start() })
    [void]$splash.ShowDialog()

    # ---------------- Main Form ----------------
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "LOOK at the Latency | v17 Smart Gaming + Artwork"
    $form.Icon = $logoIcon
    $form.Size = New-Object System.Drawing.Size(700, 760)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = 'Sizable'
    $form.BackColor = $cBg

    $rootPanel = New-Object System.Windows.Forms.Panel
    $rootPanel.Dock = 'Fill'
    $rootPanel.BackColor = $cBg
    $form.Controls.Add($rootPanel)

    $headerPanel = New-Object GradientPanel
    $headerPanel.Dock = 'Top'
    $headerPanel.Height = 80
    $headerPanel.ColorTop = [System.Drawing.Color]::FromArgb(18,32,20)
    $headerPanel.ColorBottom = $cBg
    $rootPanel.Controls.Add($headerPanel)

    $picLogo = New-Object System.Windows.Forms.PictureBox
    $picLogo.Image = $logoBmp
    $picLogo.Size = New-Object System.Drawing.Size(36,36)
    $picLogo.Location = New-Object System.Drawing.Point(24,20)
    $picLogo.SizeMode = 'Zoom'
    $picLogo.BackColor = [System.Drawing.Color]::Transparent
    $headerPanel.Controls.Add($picLogo)

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "Look at the Latency"
    $lblTitle.Font = $fontTitle
    $lblTitle.ForeColor = [System.Drawing.Color]::White
    $lblTitle.AutoSize = $true
    $lblTitle.Location = New-Object System.Drawing.Point(68,22)
    $headerPanel.Controls.Add($lblTitle)

    $lblRam = New-Object System.Windows.Forms.Label
    $lblRam.Text = "RAM: --%"
    $lblRam.Font = $fontSmall
    $lblRam.ForeColor = $cSubText
    $lblRam.AutoSize = $true
    $lblRam.Location = New-Object System.Drawing.Point(600,28)
    $lblRam.Anchor = 'Top,Right'
    $headerPanel.Controls.Add($lblRam)

    $btnUiSound = New-Object System.Windows.Forms.Button
    $btnUiSound.Text = 'Sound: ON'
    $btnUiSound.Font = $fontSmall
    $btnUiSound.ForeColor = [System.Drawing.Color]::White
    $btnUiSound.BackColor = $script:themePalette.AccentDark
    $btnUiSound.FlatStyle = 'Flat'
    $btnUiSound.FlatAppearance.BorderSize = 0
    $btnUiSound.Size = New-Object System.Drawing.Size(88,27)
    $btnUiSound.Location = New-Object System.Drawing.Point(492,25)
    $btnUiSound.Anchor = 'Top,Right'
    $btnUiSound.Cursor = 'Hand'
    $themePaletteRef = $script:themePaletteRef
    $uiSoundStateRef = $script:uiSoundStateRef
    $btnUiSound.Add_Click({
        if ($uiSoundStateRef.Enabled) {
            # Hard mute inside the audio backend first; this button must never make a sound.
            $uiSoundStateRef.Enabled = $false
            [LookAtLatencyAudioV14]::SetMuted($true)
            Stop-UiSounds
            $btnUiSound.Text = 'Sound: OFF'
            $btnUiSound.BackColor = $themePaletteRef.Current.Card
        } else {
            [LookAtLatencyAudioV14]::SetMuted($false)
            $uiSoundStateRef.Enabled = $true
            $btnUiSound.Text = 'Sound: ON'
            $btnUiSound.BackColor = $themePaletteRef.Current.AccentDark
            # Deliberately do not play a sound during the toggle action.
        }
    }.GetNewClosure())
    $headerPanel.Controls.Add($btnUiSound)

    $lblTheme = New-Object System.Windows.Forms.Label
    $lblTheme.Text = 'Theme'
    $lblTheme.Font = $fontSmall
    $lblTheme.ForeColor = $cSubText
    $lblTheme.AutoSize = $true
    $lblTheme.Location = New-Object System.Drawing.Point(340,30)
    $headerPanel.Controls.Add($lblTheme)
    $cmbTheme = New-Object System.Windows.Forms.ComboBox
    $cmbTheme.Font = $fontSmall
    $cmbTheme.DropDownStyle = 'DropDownList'
    [void]$cmbTheme.Items.AddRange(@('Emerald','Ocean','Violet','Amber','Rose','Light'))
    $cmbTheme.SelectedIndex = 0
    $cmbTheme.Size = New-Object System.Drawing.Size(92,25)
    $cmbTheme.Location = New-Object System.Drawing.Point(390,25)
    $cmbTheme.Anchor = 'Top,Right'
    $headerPanel.Controls.Add($cmbTheme)

    $barBack = New-Object System.Windows.Forms.Panel
    $barBack.Height = 0
    $barBack.Dock = 'Top'
    $barBack.BackColor = $cGreenDark
    $barBack.Visible = $false
    $lblBack = New-Object System.Windows.Forms.Label
    $lblBack.Text = "< Back to Dashboard"
    $lblBack.Font = $fontCardT
    $lblBack.ForeColor = [System.Drawing.Color]::White
    $lblBack.AutoSize = $false
    $lblBack.Dock = 'Fill'
    $lblBack.TextAlign = 'MiddleCenter'
    $lblBack.Cursor = 'Hand'
    $barBack.Controls.Add($lblBack)
    $rootPanel.Controls.Add($barBack)

    $footerPanel = New-Object System.Windows.Forms.Panel
    $footerPanel.Dock = 'Bottom'
    $footerPanel.Height = 190
    $footerPanel.BackColor = $cBg
    $rootPanel.Controls.Add($footerPanel)

    $contentHost = New-Object System.Windows.Forms.Panel
    $contentHost.AutoScroll = $true
    $contentHost.BackColor = $cBg
    $rootPanel.Controls.Add($contentHost)

    function Resize-ContentHost {
        $topOffset = $headerPanel.Height + $barBack.Height
        $ch = $rootPanel.ClientSize.Height - $topOffset - $footerPanel.Height
        if ($ch -lt 50) { $ch = 50 }
        $contentHost.Location = New-Object System.Drawing.Point(0, $topOffset)
        $contentHost.Size = New-Object System.Drawing.Size($rootPanel.ClientSize.Width, $ch)
    }
    $rootPanel.Add_Resize({ Resize-ContentHost })

    # ---------------- Stable scroll extent ----------------
    $script:scrollTarget = 0
    $script:dashboardExtentHeight = 0
    $script:activeScrollView = 'dashboard'
    $script:activeSectionKey = $null

    function Get-ContentMaxScroll {
        $extentHeight = [int]$contentHost.AutoScrollMinSize.Height
        if ($extentHeight -le 0) { $extentHeight = [int]$contentHost.DisplayRectangle.Height }
        return [Math]::Max(0, $extentHeight - [int]$contentHost.ClientSize.Height)
    }

    function Update-ContentScrollExtent {
        if ($script:activeScrollView -eq 'section' -and $script:activeSectionKey -and $sectionPanels.ContainsKey($script:activeSectionKey)) {
            $activePanel = $sectionPanels[$script:activeSectionKey]
            $extentHeight = [int]$activePanel.Height
            foreach ($childControl in $activePanel.Controls) {
                if ($childControl.Visible) {
                    $extentHeight = [Math]::Max($extentHeight, [int]$childControl.Bottom + 20)
                }
            }
        } else {
            $extentHeight = [int]$script:dashboardExtentHeight
        }
        if ($extentHeight -lt 1) { $extentHeight = [int]$contentHost.ClientSize.Height }
        $contentHost.AutoScrollMinSize = New-Object System.Drawing.Size(0, $extentHeight)
        $contentHost.PerformLayout()
    }

    # A single IMessageFilter handles wheel input from nested controls exactly once.
    $script:wheelScrollFilter = New-Object StableSmoothWheelFilter($contentHost)
    [System.Windows.Forms.Application]::AddMessageFilter($script:wheelScrollFilter)

    $dashboardPanel = $contentHost

    $sectionPanels = @{}

    # Slide each section into place from just left of the viewport. The animation only
    # changes X coordinates; the Y/AutoScroll state remains owned by the stable v5 wheel handler.
    $script:sectionEntrancePanel = $null
    $script:sectionEntranceTimer = New-Object System.Windows.Forms.Timer
    $script:sectionEntranceTimer.Interval = 12
    $script:sectionEntranceTimer.Add_Tick({
        try {
            $movingPanel = $script:sectionEntrancePanel
            if ($null -eq $movingPanel -or $movingPanel.IsDisposed) {
                $script:sectionEntranceTimer.Stop()
                $script:sectionEntrancePanel = $null
                return
            }
            $nextLeft = [int]$movingPanel.Left + 4
            if ($nextLeft -ge 0) {
                $movingPanel.Left = 0
                $script:sectionEntranceTimer.Stop()
                $script:sectionEntrancePanel = $null
            } else {
                $movingPanel.Left = $nextLeft
            }
        } catch {
            $script:sectionEntranceTimer.Stop()
            $script:sectionEntrancePanel = $null
        }
    })

    function Show-Dashboard {
        $wasSection = ($script:activeScrollView -eq 'section')
        if ($script:sectionEntranceTimer) { $script:sectionEntranceTimer.Stop() }
        $script:sectionEntrancePanel = $null
        foreach ($panelToReset in $sectionPanels.Values) {
            if ($panelToReset -and -not $panelToReset.IsDisposed) {
                $panelToReset.Location = New-Object System.Drawing.Point(0,0)
            }
        }
        if ($wasSection) { Invoke-UiSound 'navigate' }
        $script:activeScrollView = 'dashboard'
        $script:activeSectionKey = $null
        $barBack.Height = 0
        $barBack.Visible = $false
        Resize-ContentHost
        $contentHost.AutoScroll = $true
        foreach ($row in $script:dashRows) { $row.Visible = $true }
        foreach ($p in $sectionPanels.Values) { $p.Visible = $false }
        Update-ContentScrollExtent
        $script:scrollTarget = 0
        $script:wheelScrollFilter.SetPosition(0)
        if ($script:dashRows.Count -gt 0) { $contentHost.ScrollControlIntoView($script:dashRows[0]) }
    }
    function Show-Section($key) {
        if ($script:sectionEntranceTimer) { $script:sectionEntranceTimer.Stop() }
        $script:sectionEntrancePanel = $null
        Invoke-UiSound 'navigate'
        $script:activeScrollView = 'section'
        $script:activeSectionKey = [string]$key
        $barBack.Height = 34
        $barBack.Visible = $true
        Resize-ContentHost
        foreach ($row in $script:dashRows) { $row.Visible = $false }
        $contentHost.AutoScroll = $true
        foreach ($k in $sectionPanels.Keys) {
            $sectionPanels[$k].Visible = ($k -eq $key)
            if ($k -ne $key) { $sectionPanels[$k].Location = New-Object System.Drawing.Point(0,0) }
        }
        if ($sectionPanels.ContainsKey($key)) {
            $activePanel = $sectionPanels[$key]
            if ($key -eq 'games') {
                try {
                    $foundCount = Refresh-GameLibrary -Silent
                    if (-not $script:gameAutoOpenPromptDone) {
                        $script:gameAutoOpenPromptDone = $true
                        if ($foundCount -gt 0) {
                            $choice = [System.Windows.Forms.MessageBox]::Show("Found $foundCount installed game/client entries. Apply the reversible LOOK Gaming Mode profile to the detected executable paths now? Your optional power-plan and UI-animation checkboxes control those additional settings.",'Installed Game Library',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::None)
                            if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) { Invoke-LookGamingModeCore }
                        } else { Log '[Games] First-entry scan completed; no supported game was found in common locations. Use Scan / Refresh or install paths may be custom.' }
                    }
                } catch { Log "[Games] Auto-scan issue: $($_.Exception.Message)" }
            }
            if ($key -eq 'adobe' -and -not $script:adobeAutoScanDone) {
                $script:adobeAutoScanDone = $true
                try { Detect-AdobeApps } catch { Log "[Adobe] Auto-detection issue: $($_.Exception.Message)" }
            }
            if ($key -eq 'oc' -and -not $script:ocAutoScanDone) {
                $script:ocAutoScanDone = $true
                try { $txtOcSupport.Text = Get-OverclockCompatibilityReport; Log '[Overclock] Read-only compatibility scan ran on first section open.' } catch { Log "[Overclock] Scan issue: $($_.Exception.Message)" }
            }
            # Begin 20 px left of its final position, then ease into place without touching Y.
            $activePanel.Location = New-Object System.Drawing.Point(-20,0)
            $activePanel.Visible = $true
            Update-ContentScrollExtent
            $script:scrollTarget = 0
            $script:wheelScrollFilter.SetPosition(0)
            $script:sectionEntrancePanel = $activePanel
            $script:sectionEntranceTimer.Start()
        }
    }
    $lblBack.Add_Click({ Show-Dashboard })

    $script:dashRows = @()
    $script:uiAnimationTimers = @()

    # Simple, bulletproof vertical list row - no grid math, no docking tricks.
    function New-DashRow($number, $title, $subtitle, $key, $y) {
        $row = New-Object System.Windows.Forms.Panel
        $row.Location = New-Object System.Drawing.Point(10, $y)
        $row.Size = New-Object System.Drawing.Size(660, 64)
        $row.BackColor = $cCard
        $row.Cursor = 'Hand'
        $row.Tag = $key
        $row.Anchor = 'Top,Left,Right'

        $lblNum = New-Object System.Windows.Forms.Label
        $lblNum.Text = "$number."
        $lblNum.Font = $fontCardT
        $lblNum.ForeColor = $cGreen
        $lblNum.AutoSize = $true
        $lblNum.Location = New-Object System.Drawing.Point(16,12)
        $lblNum.BackColor = $cCard

        $lblT = New-Object System.Windows.Forms.Label
        $lblT.Text = $title
        $lblT.Font = $fontCardT
        $lblT.ForeColor = $cText
        $lblT.AutoSize = $true
        $lblT.Location = New-Object System.Drawing.Point(46,12)
        $lblT.BackColor = $cCard

        $lblS = New-Object System.Windows.Forms.Label
        $lblS.Text = $subtitle
        $lblS.Font = $fontCardS
        $lblS.ForeColor = $cSubText
        $lblS.AutoSize = $true
        $lblS.Location = New-Object System.Drawing.Point(46,36)
        $lblS.BackColor = $cCard

        $row.Controls.Add($lblNum)
        $row.Controls.Add($lblT)
        $row.Controls.Add($lblS)

        $accentStrip = New-Object System.Windows.Forms.Panel
        $accentStrip.Location = New-Object System.Drawing.Point(0,0)
        $accentStrip.Size = New-Object System.Drawing.Size(0,64)
        $accentStrip.BackColor = $cGreen
        $row.Controls.Add($accentStrip)
        $accentStrip.BringToFront()
        $accentState = [pscustomobject]@{ Target = 0 }
        $accentTimer = New-Object System.Windows.Forms.Timer
        $accentTimer.Interval = 12
        $accentTimer.Add_Tick({
            $targetWidth = [int]$accentState.Target
            $currentWidth = [int]$accentStrip.Width
            if ($currentWidth -lt $targetWidth) { $accentStrip.Width = [Math]::Min($targetWidth, $currentWidth + 1) }
            elseif ($currentWidth -gt $targetWidth) { $accentStrip.Width = [Math]::Max($targetWidth, $currentWidth - 1) }
            if ($accentStrip.Width -eq $targetWidth) { $accentTimer.Stop() }
        }.GetNewClosure())
        $script:uiAnimationTimers += $accentTimer
        $row.Tag = [pscustomobject]@{ Section = $key; Accent = $accentStrip }

        $themePaletteRef = $script:themePaletteRef
        $fallbackHoverColor = $cCardHover
        $fallbackCardColor = $cCard
        $fallbackAccentColor = $cGreen
        $enterHandler = {
            $hoverColor = $fallbackHoverColor
            $accentColor = $fallbackAccentColor
            try { if ($themePaletteRef -and $themePaletteRef.Current -and $themePaletteRef.Current.Hover) { $hoverColor = $themePaletteRef.Current.Hover } } catch {}
            try { if ($themePaletteRef -and $themePaletteRef.Current -and $themePaletteRef.Current.Accent) { $accentColor = $themePaletteRef.Current.Accent } } catch {}
            $row.BackColor = $hoverColor; $lblNum.BackColor = $hoverColor; $lblT.BackColor = $hoverColor; $lblS.BackColor = $hoverColor
            $accentStrip.BackColor = $accentColor
            $accentState.Target = 4
            if (-not $accentTimer.Enabled) { $accentTimer.Start() }
        }.GetNewClosure()
        $leaveHandler = {
            $normalColor = $fallbackCardColor
            $accentColor = $fallbackAccentColor
            try { if ($themePaletteRef -and $themePaletteRef.Current -and $themePaletteRef.Current.Card) { $normalColor = $themePaletteRef.Current.Card } } catch {}
            try { if ($themePaletteRef -and $themePaletteRef.Current -and $themePaletteRef.Current.Accent) { $accentColor = $themePaletteRef.Current.Accent } } catch {}
            $row.BackColor = $normalColor; $lblNum.BackColor = $normalColor; $lblT.BackColor = $normalColor; $lblS.BackColor = $normalColor
            $accentStrip.BackColor = $accentColor
            $accentState.Target = 0
            if (-not $accentTimer.Enabled) { $accentTimer.Start() }
        }.GetNewClosure()
        $clickHandler = { Show-Section $row.Tag.Section }.GetNewClosure()
        foreach ($ctrl in @($row,$lblNum,$lblT,$lblS,$accentStrip)) {
            $ctrl.Add_MouseEnter($enterHandler)
            $ctrl.Add_MouseLeave($leaveHandler)
            $ctrl.Add_Click($clickHandler)
        }
        $contentHost.Controls.Add($row)
        $script:dashRows += $row
        return $row
    }

    $cards = @(
        @{n=1;  t="Start";        s="Create a backup and check your PC.";              k="start"}
        @{n=2;  t="Driver";       s="Detect + optimize your GPU driver.";              k="gpu"}
        @{n=3;  t="Bloatware";    s="Remove common preinstalled Windows apps.";        k="bloat"}
        @{n=4;  t="Telemetry";    s="Reduce Windows telemetry/background tasks.";      k="telemetry"}
        @{n=5;  t="Latency";      s="Measure jitter/loss and tune safe Windows latency defaults.";                  k="latency"}
        @{n=6;  t="Network";      s="Adapter tweaks and connection info.";             k="network"}
        @{n=7;  t="Overclocking"; s="Scan hardware and check vendor-supported tuning options.";      k="oc"}
        @{n=8;  t="Games";        s="FPS boost and game mode tips.";                   k="games"}
        @{n=9;  t="Miscellaneous";s="Offline gaming assistant, custom commands, power plan.";           k="misc"}
        @{n=10; t="Cleanup";      s="Free up RAM and disk cache space.";               k="cleanup"}
        @{n=11; t="BIOS";         s="Audit UEFI settings and apply safe Windows-side gaming profile."; k="bios"}
        @{n=12; t="Experimental"; s="Live Mode, QoS/DSCP, and other beta tweaks.";     k="experimental"}
        @{n=13; t="Adobe Apps";   s="Audit Adobe bottlenecks and apply reversible per-app GPU routing."; k="adobe"}
        @{n=14; t="Game Engines"; s="Apply safe Windows tuning for Unreal, DirectX, and Vulkan apps."; k="engines"}
    )
    $y = 40
    foreach ($c in $cards) {
        New-DashRow $c.n $c.t $c.s $c.k $y | Out-Null
        $y += 72
    }
    # Cache a stable dashboard extent once; control coordinates may appear offset after scrolling.
    foreach ($dashRow in $script:dashRows) {
        $script:dashboardExtentHeight = [Math]::Max([int]$script:dashboardExtentHeight, [int]$dashRow.Top + [int]$dashRow.Height + 16)
    }

    function New-SectionPanel($key, $title) {
        $p = New-Object System.Windows.Forms.Panel
        $p.Size = New-Object System.Drawing.Size(700,590)
        $p.Location = New-Object System.Drawing.Point(0,0)
        $p.BackColor = $cBg
        $p.Visible = $false
        $lblH = New-Object System.Windows.Forms.Label
        $lblH.Text = $title
        $lblH.Font = $fontTitle
        $lblH.ForeColor = $cGreen
        $lblH.AutoSize = $true
        $lblH.Location = New-Object System.Drawing.Point(20,12)
        $p.Controls.Add($lblH)
        $contentHost.Controls.Add($p)
        $sectionPanels[$key] = $p
        return $p
    }

    $logBox = New-Object System.Windows.Forms.TextBox
    $logBox.Multiline = $true
    $logBox.ScrollBars = 'Vertical'
    $logBox.ReadOnly = $true
    $logBox.Font = New-Object System.Drawing.Font("Consolas", 8.5)
    $logBox.BackColor = [System.Drawing.Color]::FromArgb(6,10,8)
    $logBox.ForeColor = $cGreen
    $logBox.Size = New-Object System.Drawing.Size(660,140)
    $logBox.Anchor = 'Left,Right,Bottom'

    function Log($msg) {
        $logBox.AppendText("$msg`r`n")
        $logBox.SelectionStart = $logBox.Text.Length
        $logBox.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    }

    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Size = New-Object System.Drawing.Size(660,14)
    $progress.Style = 'Continuous'
    $progress.Anchor = 'Left,Right,Bottom'

    function Set-Progress($val) { $progress.Value = [Math]::Min([Math]::Max($val,0),100); [System.Windows.Forms.Application]::DoEvents() }
    function Safe-Run($sb, $label) { try { & $sb } catch { Log "WARNING - $label : $($_.Exception.Message)" } }
    function Set-VerifiedRegValue($path, $name, $value, $type, $label) {
        try {
            if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
            New-ItemProperty -Path $path -Name $name -Value $value -PropertyType $type -Force | Out-Null
            $rb = (Get-ItemProperty -Path $path -Name $name -ErrorAction Stop).$name
            if ("$rb" -eq "$value") { Log "   OK   $label = $rb"; return $true }
            else { Log "   MISMATCH  $label (wrote $value, read $rb)"; return $false }
        } catch { Log "   FAILED  $label : $($_.Exception.Message)"; return $false }
    }
    function Wrap-Click($sb, $label) {
        return {
            try { & $sb } catch {
                Invoke-UiSound 'warning'
                Log "===================================================="
                Log "CRITICAL ERROR in '$label': $($_.Exception.Message)"
                [System.Windows.Forms.MessageBox]::Show("Something failed when running '$label'.`n`n$($_.Exception.Message)", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::None) | Out-Null
            }
        }.GetNewClosure()
    }
    function New-SectionButton($text, $color) {
        $btn = New-Object System.Windows.Forms.Button
        $themePaletteRef = $script:themePaletteRef
        $fallbackAccentColor = $cGreen
        $fallbackAccentDarkColor = $cGreenDark
        $btn.Text = $text; $btn.Font = $fontNormal
        $btn.Size = New-Object System.Drawing.Size(300,36)
        $btn.BackColor = $color; $btn.ForeColor = [System.Drawing.Color]::White
        $btn.FlatStyle = 'Flat'; $btn.FlatAppearance.BorderSize = 0
        $btn.Cursor = 'Hand'
        $btn.Add_Click({ Invoke-UiSound 'click' })
        $btn.Add_MouseEnter({
            param($sender, $eventArgs)
            $colorToApply = $fallbackAccentColor
            try { if ($themePaletteRef -and $themePaletteRef.Current -and $themePaletteRef.Current.Accent) { $colorToApply = $themePaletteRef.Current.Accent } } catch {}
            if ($sender -and $colorToApply) { $sender.BackColor = $colorToApply }
        }.GetNewClosure())
        $btn.Add_MouseLeave({
            param($sender, $eventArgs)
            $colorToApply = $fallbackAccentDarkColor
            try { if ($themePaletteRef -and $themePaletteRef.Current -and $themePaletteRef.Current.AccentDark) { $colorToApply = $themePaletteRef.Current.AccentDark } } catch {}
            if ($sender -and $colorToApply) { $sender.BackColor = $colorToApply }
        }.GetNewClosure())
        return $btn
    }

    # 1. START
    $pStart = New-SectionPanel "start" "1. Start"
    $lblStartInfo = New-Object System.Windows.Forms.Label
    $lblStartInfo.Text = "A restore point was already offered when this app launched.`nUse the button below to create another one anytime, or run a quick system summary."
    $lblStartInfo.Font = $fontSmall; $lblStartInfo.ForeColor = $cWarn
    $lblStartInfo.Size = New-Object System.Drawing.Size(640,40)
    $lblStartInfo.Location = New-Object System.Drawing.Point(20,55)
    $pStart.Controls.Add($lblStartInfo)
    $btnRestorePoint = New-SectionButton "Create Restore Point Now" $cGreenDark
    $btnRestorePoint.Location = New-Object System.Drawing.Point(20,105)
    $btnBenchmark = New-SectionButton "Run Benchmark + Get LOOK Score" $cGreenDark
    $btnBenchmark.Size = New-Object System.Drawing.Size(505,36)
    $btnBenchmark.Location = New-Object System.Drawing.Point(20,150)
    $lblLookScore = New-Object System.Windows.Forms.Label
    $lblLookScore.Text = 'LOOK Score: -- / 100 | Run the synthetic benchmark to create a local score.'
    $lblLookScore.Font = $fontSmall; $lblLookScore.ForeColor = $cWarn
    $lblLookScore.Size = New-Object System.Drawing.Size(650,42)
    $lblLookScore.Location = New-Object System.Drawing.Point(20,198)
    $pStart.Controls.AddRange(@($btnRestorePoint,$btnBenchmark,$lblLookScore))

    # 2. DRIVER / GPU
    $pGpu = New-SectionPanel "gpu" "2. Driver"
    $lblGpuInfo = New-Object System.Windows.Forms.Label
    $lblGpuInfo.Text = "Auto-updating GPU drivers in the background is risky (can break your display).`nThis detects your GPU and opens the official vendor update page, plus applies safe scheduling tweaks."
    $lblGpuInfo.Font = $fontSmall; $lblGpuInfo.ForeColor = $cWarn
    $lblGpuInfo.Size = New-Object System.Drawing.Size(640,40)
    $lblGpuInfo.Location = New-Object System.Drawing.Point(20,55)
    $pGpu.Controls.Add($lblGpuInfo)
    $btnGpuDetect = New-SectionButton "Detect GPU + Open Official Update Page" $cGreenDark
    $btnGpuDetect.Location = New-Object System.Drawing.Point(20,105)
    $btnGpuOptimize = New-SectionButton "Apply Safe Windows GPU Optimizations" $cGreenDark
    $btnGpuOptimize.Location = New-Object System.Drawing.Point(20,150)
    $btnOpenNvidiaPanel = New-SectionButton "Open NVIDIA Control Panel" $cGreenDark
    $btnOpenNvidiaPanel.Size = New-Object System.Drawing.Size(505,32)
    $btnOpenNvidiaPanel.Location = New-Object System.Drawing.Point(20,195)
    $btnOpenIntelPanel = New-SectionButton "Open Intel Graphics Software / Command Center" $cGreenDark
    $btnOpenIntelPanel.Size = New-Object System.Drawing.Size(505,32)
    $btnOpenIntelPanel.Location = New-Object System.Drawing.Point(20,235)
    $btnGraphicsGuide = New-SectionButton "Detect GPU + Show Recommended Game Profile" $cGreenDark
    $btnGraphicsGuide.Size = New-Object System.Drawing.Size(505,32)
    $btnGraphicsGuide.Location = New-Object System.Drawing.Point(20,275)
    $pGpu.Size = New-Object System.Drawing.Size(700,340)
    $pGpu.Controls.AddRange(@($btnGpuDetect,$btnGpuOptimize,$btnOpenNvidiaPanel,$btnOpenIntelPanel,$btnGraphicsGuide))

    # 3. BLOATWARE
    $pBloat = New-SectionPanel "bloat" "3. Bloatware"
    $lblBloatInfo = New-Object System.Windows.Forms.Label
    $lblBloatInfo.Text = "Removes common preinstalled apps (Xbox extras, 3D Viewer, Mixed Reality, etc).`nOnly removes the app for your user - does not touch personal files. Safe to reinstall from Microsoft Store later."
    $lblBloatInfo.Font = $fontSmall; $lblBloatInfo.ForeColor = $cWarn
    $lblBloatInfo.Size = New-Object System.Drawing.Size(640,40)
    $lblBloatInfo.Location = New-Object System.Drawing.Point(20,55)
    $pBloat.Controls.Add($lblBloatInfo)
    $btnBloatRemove = New-SectionButton "Remove Common Bloatware Apps" $cGreenDark
    $btnBloatRemove.Location = New-Object System.Drawing.Point(20,105)
    $pBloat.Controls.Add($btnBloatRemove)

    # 4. TELEMETRY
    $pTelemetry = New-SectionPanel "telemetry" "4. Telemetry"
    $lblTelInfo = New-Object System.Windows.Forms.Label
    $lblTelInfo.Text = "Reduces Windows diagnostic data collection and disables a few non-essential`nscheduled tasks (Customer Experience Improvement, application telemetry)."
    $lblTelInfo.Font = $fontSmall; $lblTelInfo.ForeColor = $cWarn
    $lblTelInfo.Size = New-Object System.Drawing.Size(640,40)
    $lblTelInfo.Location = New-Object System.Drawing.Point(20,55)
    $pTelemetry.Controls.Add($lblTelInfo)
    $btnTelemetry = New-SectionButton "Reduce Telemetry" $cGreenDark
    $btnTelemetry.Location = New-Object System.Drawing.Point(20,105)
    $pTelemetry.Controls.Add($btnTelemetry)

    # 5. LATENCY
    $pLatency = New-SectionPanel "latency" "5. Latency"
    $lblServer = New-Object System.Windows.Forms.Label
    $lblServer.Text = "Server:"; $lblServer.Font = $fontNormal; $lblServer.ForeColor = $cText; $lblServer.AutoSize = $true
    $lblServer.Location = New-Object System.Drawing.Point(20,58)
    $txtServer = New-Object System.Windows.Forms.TextBox
    $txtServer.Font = $fontNormal; $txtServer.Size = New-Object System.Drawing.Size(220,24)
    $txtServer.Location = New-Object System.Drawing.Point(80,55); $txtServer.Text = "mc.hypixel.net"
    $lblPort = New-Object System.Windows.Forms.Label
    $lblPort.Text = "Port:"; $lblPort.Font = $fontNormal; $lblPort.ForeColor = $cText; $lblPort.AutoSize = $true
    $lblPort.Location = New-Object System.Drawing.Point(310,58)
    $txtPort = New-Object System.Windows.Forms.TextBox
    $txtPort.Font = $fontNormal; $txtPort.Size = New-Object System.Drawing.Size(55,24)
    $txtPort.Location = New-Object System.Drawing.Point(350,55); $txtPort.Text = "25565"
    $cmbProtocol = New-Object System.Windows.Forms.ComboBox
    $cmbProtocol.Font = $fontSmall; $cmbProtocol.DropDownStyle = 'DropDownList'
    $cmbProtocol.Items.AddRange(@("Auto","ICMP only","TCP only")); $cmbProtocol.SelectedIndex = 0
    $cmbProtocol.Size = New-Object System.Drawing.Size(90,24)
    $cmbProtocol.Location = New-Object System.Drawing.Point(415,55)
    $pLatency.Controls.AddRange(@($lblServer,$txtServer,$lblPort,$txtPort,$cmbProtocol))
    $btnTestPing = New-SectionButton "Test Ping" $cGreenDark
    $btnTestPing.Size = New-Object System.Drawing.Size(505,30)
    $btnTestPing.Location = New-Object System.Drawing.Point(20,90)
    $btnLatencyOptimize = New-SectionButton "Apply Safe TCP Baseline (before/after test)" $cGreenDark
    $btnLatencyOptimize.Size = New-Object System.Drawing.Size(505,34)
    $btnLatencyOptimize.Location = New-Object System.Drawing.Point(20,130)
    $btnHitRegTest = New-SectionButton "HitReg / Jitter / Packet-Loss Diagnostic (12 samples)" $cGreenDark
    $btnHitRegTest.Size = New-Object System.Drawing.Size(505,32)
    $btnHitRegTest.Location = New-Object System.Drawing.Point(20,171)
    $btnLatencyOpenGameMode = New-SectionButton "Open Windows Game Mode Settings" $cGreenDark
    $btnLatencyOpenGameMode.Size = New-Object System.Drawing.Size(505,32)
    $btnLatencyOpenGameMode.Location = New-Object System.Drawing.Point(20,209)
    $pLatency.Controls.AddRange(@($btnTestPing,$btnLatencyOptimize,$btnHitRegTest,$btnLatencyOpenGameMode))
    $chkVisualFX = New-ToggleRow "Also reduce Windows visual effects (optional, off by default)" 252 $pLatency

    # 6. NETWORK
    $pNetwork = New-SectionPanel "network" "6. Network"
    $lblNetInfo = New-Object System.Windows.Forms.Label
    $lblNetInfo.Text = "Inspects active adapter settings. Network driver properties vary by adapter, so this tool will not blindly force Ethernet-only options on Wi-Fi hardware."
    $lblNetInfo.Font = $fontSmall; $lblNetInfo.ForeColor = $cWarn
    $lblNetInfo.Size = New-Object System.Drawing.Size(640,40)
    $lblNetInfo.Location = New-Object System.Drawing.Point(20,55)
    $pNetwork.Controls.Add($lblNetInfo)
    $btnNetInfo = New-SectionButton "Show Active Adapters" $cGreenDark
    $btnNetInfo.Location = New-Object System.Drawing.Point(20,105)
    $btnNetAdapterTweak = New-SectionButton "Inspect Adapter Settings" $cGreenDark
    $btnNetAdapterTweak.Location = New-Object System.Drawing.Point(20,150)
    $btnNetReset = New-SectionButton "Reset Network Stack (fixes corrupted TCP/IP settings)" $cGreenDark
    $btnNetReset.Size = New-Object System.Drawing.Size(505,32)
    $btnNetReset.Location = New-Object System.Drawing.Point(20,195)
    $pNetwork.Controls.AddRange(@($btnNetInfo,$btnNetAdapterTweak,$btnNetReset))

    $sepNet = New-Object System.Windows.Forms.Label
    $sepNet.BorderStyle = 'Fixed3D'
    $sepNet.Size = New-Object System.Drawing.Size(640,2)
    $sepNet.Location = New-Object System.Drawing.Point(20,233)
    $pNetwork.Controls.Add($sepNet)

    $lblIpInfo = New-Object System.Windows.Forms.Label
    $lblIpInfo.Text = "Change your local IP (release/renew from your router) and set custom DNS servers.`nThis does not hide your identity online - it only affects your local network address and DNS resolver."
    $lblIpInfo.Font = $fontSmall; $lblIpInfo.ForeColor = $cWarn
    $lblIpInfo.Size = New-Object System.Drawing.Size(640,32)
    $lblIpInfo.Location = New-Object System.Drawing.Point(20,243)
    $pNetwork.Controls.Add($lblIpInfo)

    $btnIpRenew = New-SectionButton "Release + Renew My IP Address" $cGreenDark
    $btnIpRenew.Location = New-Object System.Drawing.Point(20,280)
    $pNetwork.Controls.Add($btnIpRenew)

    $lblCurrentIp = New-Object System.Windows.Forms.Label
    $lblCurrentIp.Text = "Current IP: (click 'Show Active Adapters' above to see it)"
    $lblCurrentIp.Font = $fontSmall; $lblCurrentIp.ForeColor = $cSubText; $lblCurrentIp.AutoSize = $true
    $lblCurrentIp.Location = New-Object System.Drawing.Point(20,320)
    $pNetwork.Controls.Add($lblCurrentIp)

    $fldDns1 = New-Object AnimatedTextField("Primary DNS", "1.1.1.1")
    $fldDns1.Location = New-Object System.Drawing.Point(20,338)
    $fldDns2 = New-Object AnimatedTextField("Secondary DNS", "1.0.0.1")
    $fldDns2.Location = New-Object System.Drawing.Point(215,338)
    $pNetwork.Controls.AddRange(@($fldDns1,$fldDns2))

    $btnDnsApply = New-SectionButton "Apply DNS to Active Adapters" $cGreenDark
    $btnDnsApply.Size = New-Object System.Drawing.Size(300,32)
    $btnDnsApply.Location = New-Object System.Drawing.Point(20,394)
    $btnDnsTest = New-SectionButton "Test DNS Speed (before/after)" $cGreenDark
    $btnDnsTest.Size = New-Object System.Drawing.Size(300,32)
    $btnDnsTest.Location = New-Object System.Drawing.Point(330,394)
    $pNetwork.Controls.AddRange(@($btnDnsApply,$btnDnsTest))

    # 7. OVERCLOCKING
    $pOc = New-SectionPanel "oc" "7. Overclocking"
    $lblOcInfo = New-Object System.Windows.Forms.Label
    $lblOcInfo.Text = "Hardware-aware OC workflow: baseline score, detect supported vendor tool, and compare results after tuning.`nThis app does not guess clock/voltage values or claim an untested OC is stable. Use the vendor's own Auto Tuning only when supported."
    $lblOcInfo.Font = $fontSmall; $lblOcInfo.ForeColor = $cWarn
    $lblOcInfo.Size = New-Object System.Drawing.Size(640,55)
    $lblOcInfo.Location = New-Object System.Drawing.Point(20,55)
    $pOc.Controls.Add($lblOcInfo)
    $btnOcNvidia = New-SectionButton "Open MSI Afterburner download page" $cGreenDark
    $btnOcNvidia.Location = New-Object System.Drawing.Point(20,120)
    $btnOcIntel = New-SectionButton "Open Intel XTU (CPU) page" $cGreenDark
    $btnOcIntel.Location = New-Object System.Drawing.Point(20,165)
    $btnOcCheck = New-SectionButton "Check Current CPU/GPU Clock Speeds vs Rated Base" $cGreenDark
    $btnOcCheck.Size = New-Object System.Drawing.Size(505,36)
    $btnOcCheck.Location = New-Object System.Drawing.Point(20,210)
    $lblOcPower = New-Object System.Windows.Forms.Label
    $lblOcPower.Text = "NVIDIA only - safe Power Limit (not voltage/clock offset, officially supported by NVIDIA):"
    $lblOcPower.Font = $fontSmall; $lblOcPower.ForeColor = $cText
    $lblOcPower.Size = New-Object System.Drawing.Size(505,18)
    $lblOcPower.Location = New-Object System.Drawing.Point(20,256)
    $btnOcPowerCheck = New-SectionButton "Check Safe Power Limit Range" $cGreenDark
    $btnOcPowerCheck.Size = New-Object System.Drawing.Size(245,32)
    $btnOcPowerCheck.Location = New-Object System.Drawing.Point(20,278)
    $btnOcPowerMax = New-SectionButton "Set NVIDIA Limit to Driver Ceiling (confirm)" $cGreenDark
    $btnOcPowerMax.Size = New-Object System.Drawing.Size(245,32)
    $btnOcPowerMax.Location = New-Object System.Drawing.Point(280,278)

    $sepOc = New-Object System.Windows.Forms.Label
    $sepOc.BorderStyle = 'Fixed3D'
    $sepOc.Size = New-Object System.Drawing.Size(505,2)
    $sepOc.Location = New-Object System.Drawing.Point(20,318)

    $lblOcCpu = New-Object System.Windows.Forms.Label
    $lblOcCpu.Text = "CPU/GPU boost - works safely for Intel AND AMD (native Windows settings, not manual overclocking):"
    $lblOcCpu.Font = $fontSmall; $lblOcCpu.ForeColor = $cText
    $lblOcCpu.Size = New-Object System.Drawing.Size(505,18)
    $lblOcCpu.Location = New-Object System.Drawing.Point(20,326)

    $btnOcCpuBoost = New-SectionButton "Enable Max CPU Boost (Intel Turbo Boost / AMD Precision Boost)" $cGreenDark
    $btnOcCpuBoost.Size = New-Object System.Drawing.Size(505,32)
    $btnOcCpuBoost.Location = New-Object System.Drawing.Point(20,348)

    $btnOcGpuVendor = New-SectionButton "Check My GPU + Show Safe Tuning Option (AMD/Intel/NVIDIA)" $cGreenDark
    $btnOcGpuVendor.Size = New-Object System.Drawing.Size(505,32)
    $btnOcGpuVendor.Location = New-Object System.Drawing.Point(20,386)
    $btnOcSupportScan = New-SectionButton "Scan Hardware + Verify OC Support (read-only)" $cGreenDark
    $btnOcSupportScan.Size = New-Object System.Drawing.Size(505,32)
    $btnOcSupportScan.Location = New-Object System.Drawing.Point(20,424)
    $btnOcWizard = New-SectionButton "Guided Tune Wizard (detect first; ask before changes)" $cGreenDark
    $btnOcWizard.Size = New-Object System.Drawing.Size(505,28)
    $btnOcWizard.Location = New-Object System.Drawing.Point(20,462)
    $txtOcSupport = New-Object System.Windows.Forms.TextBox
    $txtOcSupport.Multiline = $true; $txtOcSupport.ReadOnly = $true; $txtOcSupport.ScrollBars = 'Vertical'
    $txtOcSupport.Font = New-Object System.Drawing.Font("Consolas", 8)
    $txtOcSupport.BackColor = [System.Drawing.Color]::FromArgb(10,14,10); $txtOcSupport.ForeColor = $cText
    $txtOcSupport.Location = New-Object System.Drawing.Point(20,494)
    $txtOcSupport.Size = New-Object System.Drawing.Size(505,60)
    $txtOcSupport.Text = "No scan yet. Scan is read-only. The guided wizard uses vendor-supported tools only and asks before supported changes."
    $pOc.Size = New-Object System.Drawing.Size(700,650)
    $btnOcStartWorkflow = New-SectionButton "Start Guided OC: Baseline + Detect Vendor Tool" $cGreenDark
    $btnOcStartWorkflow.Size = New-Object System.Drawing.Size(245,32)
    $btnOcStartWorkflow.Location = New-Object System.Drawing.Point(20,562)
    $btnOcValidateWorkflow = New-SectionButton "Compare Score After Tuning" $cGreenDark
    $btnOcValidateWorkflow.Size = New-Object System.Drawing.Size(245,32)
    $btnOcValidateWorkflow.Location = New-Object System.Drawing.Point(280,562)
    $pOc.Controls.AddRange(@($btnOcNvidia,$btnOcIntel,$btnOcCheck,$lblOcPower,$btnOcPowerCheck,$btnOcPowerMax,$sepOc,$lblOcCpu,$btnOcCpuBoost,$btnOcGpuVendor,$btnOcSupportScan,$btnOcWizard,$txtOcSupport,$btnOcStartWorkflow,$btnOcValidateWorkflow))

    # 8. GAMES
    $pGames = New-SectionPanel "games" "8. Games"
    $btnFPS = New-SectionButton "Boost FPS / Reduce Heat-rage Lag" $cGreenDark
    $btnFPS.Size = New-Object System.Drawing.Size(505,36)
    $btnFPS.Location = New-Object System.Drawing.Point(20,60)
    $cmbGameMode = New-Object System.Windows.Forms.ComboBox
    $cmbGameMode.Font = $fontSmall; $cmbGameMode.DropDownStyle = 'DropDownList'
    $cmbGameMode.Items.AddRange(@("PvP - TNT / Sumo","Bedwars / Bedfight","Bridging (speed bridge / practice)","Fireball / Ghast Defense","Survival / Building","Skyblock / AFK-heavy"))
    $cmbGameMode.SelectedIndex = 0
    $cmbGameMode.Size = New-Object System.Drawing.Size(300,24)
    $cmbGameMode.Location = New-Object System.Drawing.Point(20,106)
    $btnGameTips = New-SectionButton "Show Tips" $cGreenDark
    $btnGameTips.Size = New-Object System.Drawing.Size(190,28)
    $btnGameTips.Location = New-Object System.Drawing.Point(330,104)
    $pGames.Controls.AddRange(@($btnFPS,$cmbGameMode,$btnGameTips))

    $sepGames = New-Object System.Windows.Forms.Label
    $sepGames.BorderStyle = 'Fixed3D'
    $sepGames.Size = New-Object System.Drawing.Size(505,2)
    $sepGames.Location = New-Object System.Drawing.Point(20,144)
    $pGames.Controls.Add($sepGames)

    $btnDetectGames = New-SectionButton "Detect Installed Minecraft Launchers/Clients" $cGreenDark
    $btnDetectGames.Size = New-Object System.Drawing.Size(505,32)
    $btnDetectGames.Location = New-Object System.Drawing.Point(20,152)
    $pGames.Controls.Add($btnDetectGames)

    $lblPingStability = New-Object System.Windows.Forms.Label
    $lblPingStability.Text = "Find bandwidth-heavy activity that may create ping spikes; no essential services are stopped:"
    $lblPingStability.Font = $fontSmall; $lblPingStability.ForeColor = $cWarn
    $lblPingStability.Size = New-Object System.Drawing.Size(505,18)
    $lblPingStability.Location = New-Object System.Drawing.Point(20,192)
    $pGames.Controls.Add($lblPingStability)

    $btnPingStability = New-SectionButton "Check Background Bandwidth (no services stopped)" $cGreenDark
    $btnPingStability.Size = New-Object System.Drawing.Size(505,32)
    $btnPingStability.Location = New-Object System.Drawing.Point(20,214)
    $pGames.Controls.Add($btnPingStability)

    $chkPingMonitor = New-ToggleRow "Live ping stability monitor (logs spikes over 100ms while enabled)" 254 $pGames
    $btnLookGamingMode = New-SectionButton "Enable LOOK GAMING MODE (Game Mode + optional QoL + per-game routing)" $cGreenDark
    $btnLookGamingMode.Size = New-Object System.Drawing.Size(505,34)
    $btnLookGamingMode.Location = New-Object System.Drawing.Point(20,292)
    $btnRestoreGamingMode = New-SectionButton "Restore Previous Game Mode Settings" $cGreenDark
    $btnRestoreGamingMode.Size = New-Object System.Drawing.Size(505,32)
    $btnRestoreGamingMode.Location = New-Object System.Drawing.Point(20,333)
    $lblLookGamingInfo = New-Object System.Windows.Forms.Label
    $lblLookGamingInfo.Text = "Enables Windows Game Mode and can set per-app GPU preference for detected running games. Security and Windows Update stay enabled; dedicated GPU routing only helps systems that have one."
    $lblLookGamingInfo.Font = $fontSmall; $lblLookGamingInfo.ForeColor = $cSubText
    $lblLookGamingInfo.Size = New-Object System.Drawing.Size(640,34)
    $lblLookGamingInfo.Location = New-Object System.Drawing.Point(20,375)
    $chkGamingPowerPlan = New-Object System.Windows.Forms.CheckBox
    $chkGamingPowerPlan.Text = 'Optional: use High Performance power plan (more heat / battery drain)'
    $chkGamingPowerPlan.Font = $fontSmall; $chkGamingPowerPlan.ForeColor = $cText; $chkGamingPowerPlan.BackColor = $cBg
    $chkGamingPowerPlan.AutoSize = $true; $chkGamingPowerPlan.Checked = $false
    $chkGamingPowerPlan.Location = New-Object System.Drawing.Point(20,414)
    $chkGamingVisuals = New-Object System.Windows.Forms.CheckBox
    $chkGamingVisuals.Text = 'Optional: reduce Windows transparency and window animations (reversible)'
    $chkGamingVisuals.Font = $fontSmall; $chkGamingVisuals.ForeColor = $cText; $chkGamingVisuals.BackColor = $cBg
    $chkGamingVisuals.AutoSize = $true; $chkGamingVisuals.Checked = $true
    $chkGamingVisuals.Location = New-Object System.Drawing.Point(20,440)
    $chkGamingDvr = New-Object System.Windows.Forms.CheckBox
    $chkGamingDvr.Text = 'Optional: disable Xbox Game DVR background capture (recording features may change)'
    $chkGamingDvr.Font = $fontSmall; $chkGamingDvr.ForeColor = $cText; $chkGamingDvr.BackColor = $cBg
    $chkGamingDvr.AutoSize = $true; $chkGamingDvr.Checked = $false
    $chkGamingDvr.Location = New-Object System.Drawing.Point(20,466)
    $btnPerformanceRadar = New-SectionButton "LOOK Performance Radar (CPU / RAM / Disk / Games)" $cGreenDark
    $btnPerformanceRadar.Size = New-Object System.Drawing.Size(505,32)
    $btnPerformanceRadar.Location = New-Object System.Drawing.Point(20,493)
    $lblGameLibrary = New-Object System.Windows.Forms.Label
    $lblGameLibrary.Text = 'Installed Game Library (local game icons; optional Steam cover art)'
    $lblGameLibrary.Font = $fontCardT; $lblGameLibrary.ForeColor = $cGreen
    $lblGameLibrary.AutoSize = $true; $lblGameLibrary.Location = New-Object System.Drawing.Point(20,536)
    $btnRefreshGameLibrary = New-SectionButton 'Scan / Refresh Installed Games' $cGreenDark
    $btnRefreshGameLibrary.Size = New-Object System.Drawing.Size(195,30); $btnRefreshGameLibrary.Location = New-Object System.Drawing.Point(20,562)
    $btnOptimizeSelectedGame = New-SectionButton 'Optimize Selected' $cGreenDark
    $btnOptimizeSelectedGame.Size = New-Object System.Drawing.Size(155,30); $btnOptimizeSelectedGame.Location = New-Object System.Drawing.Point(225,562)
    $btnOptimizeAllGames = New-SectionButton 'Optimize All Detected' $cGreenDark
    $btnOptimizeAllGames.Size = New-Object System.Drawing.Size(180,30); $btnOptimizeAllGames.Location = New-Object System.Drawing.Point(390,562)
    $btnLoadGameArt = New-SectionButton 'Load Cover Art' $cGreenDark
    $btnLoadGameArt.Size = New-Object System.Drawing.Size(90,30); $btnLoadGameArt.Location = New-Object System.Drawing.Point(580,562)
    $imgGames = New-Object System.Windows.Forms.ImageList
    $imgGames.ImageSize = New-Object System.Drawing.Size(48,48)
    $imgGames.ColorDepth = [System.Windows.Forms.ColorDepth]::Depth32Bit
    $lvGames = New-Object System.Windows.Forms.ListView
    $lvGames.View = [System.Windows.Forms.View]::Details
    $lvGames.FullRowSelect = $true; $lvGames.GridLines = $false; $lvGames.HideSelection = $false
    $lvGames.MultiSelect = $false; $lvGames.SmallImageList = $imgGames
    $lvGames.Font = $fontSmall; $lvGames.BackColor = $cCard; $lvGames.ForeColor = $cText
    $lvGames.Location = New-Object System.Drawing.Point(20,600); $lvGames.Size = New-Object System.Drawing.Size(650,160)
    [void]$lvGames.Columns.Add('Game',190)
    [void]$lvGames.Columns.Add('Detection',100)
    [void]$lvGames.Columns.Add('Executable / install path',340)
    $pGames.Size = New-Object System.Drawing.Size(700,780)
    $pGames.Controls.AddRange(@($btnLookGamingMode,$btnRestoreGamingMode,$lblLookGamingInfo,$chkGamingPowerPlan,$chkGamingVisuals,$chkGamingDvr,$btnPerformanceRadar,$lblGameLibrary,$btnRefreshGameLibrary,$btnOptimizeSelectedGame,$btnOptimizeAllGames,$btnLoadGameArt,$lvGames))

    # 9. MISCELLANEOUS
    $pMisc = New-SectionPanel "misc" "9. Miscellaneous"
    $lblCustom = New-Object System.Windows.Forms.Label
    $lblCustom.Text = "Custom: type what to optimize (e.g. 'just tcp', 'only fps', 'tcp and gpu')"
    $lblCustom.Font = $fontSmall; $lblCustom.ForeColor = $cText; $lblCustom.AutoSize = $true
    $lblCustom.Location = New-Object System.Drawing.Point(20,58)
    $txtCustom = New-Object System.Windows.Forms.TextBox
    $txtCustom.Font = $fontNormal; $txtCustom.Size = New-Object System.Drawing.Size(400,24)
    $txtCustom.Location = New-Object System.Drawing.Point(20,80)
    $btnCustom = New-SectionButton "Run" $cGreenDark
    $btnCustom.Size = New-Object System.Drawing.Size(105,28)
    $btnCustom.Location = New-Object System.Drawing.Point(425,79)
    $lblOfflineAi = New-Object System.Windows.Forms.Label
    $lblOfflineAi.Text = "Offline Gaming Assistant - local expert rules, hardware-aware tips, no API key or internet."
    $lblOfflineAi.Font = $fontSmall; $lblOfflineAi.ForeColor = $cGreen; $lblOfflineAi.AutoSize = $true
    $lblOfflineAi.Location = New-Object System.Drawing.Point(20,118)
    $btnAiAnalyze = New-SectionButton "Analyze My PC" $cGreenDark
    $btnAiAnalyze.Size = New-Object System.Drawing.Size(145,26); $btnAiAnalyze.Location = New-Object System.Drawing.Point(20,140)
    $btnAiBenchmark = New-SectionButton "Quick Benchmark" $cGreenDark
    $btnAiBenchmark.Size = New-Object System.Drawing.Size(145,26); $btnAiBenchmark.Location = New-Object System.Drawing.Point(175,140)
    $btnAiClear = New-SectionButton "Clear Chat" $cGreenDark
    $btnAiClear.Size = New-Object System.Drawing.Size(105,26); $btnAiClear.Location = New-Object System.Drawing.Point(330,140)
    $chatHistory = New-Object System.Windows.Forms.TextBox
    $chatHistory.Multiline = $true; $chatHistory.ScrollBars = 'Vertical'; $chatHistory.ReadOnly = $true
    $chatHistory.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $chatHistory.BackColor = [System.Drawing.Color]::FromArgb(10,14,10); $chatHistory.ForeColor = $cText
    $chatHistory.Location = New-Object System.Drawing.Point(20,173)
    $chatHistory.Size = New-Object System.Drawing.Size(660,170)
    $txtChatInput = New-Object System.Windows.Forms.TextBox
    $txtChatInput.Font = $fontNormal
    $txtChatInput.Location = New-Object System.Drawing.Point(20,350)
    $txtChatInput.Size = New-Object System.Drawing.Size(555,26)
    $btnChatSend = New-SectionButton "Send" $cGreenDark
    $btnChatSend.Size = New-Object System.Drawing.Size(105,28)
    $btnChatSend.Location = New-Object System.Drawing.Point(580,349)
    $btnPowerPlan = New-SectionButton "Enable LOOK Performance Power Plan (saved backup)" $cGreenDark
    $btnPowerPlan.Size = New-Object System.Drawing.Size(505,32)
    $btnPowerPlan.Location = New-Object System.Drawing.Point(20,390)
    $btnPowerRestore = New-SectionButton "Restore Previous Power Plan" $cGreenDark
    $btnPowerRestore.Size = New-Object System.Drawing.Size(505,30)
    $btnPowerRestore.Location = New-Object System.Drawing.Point(20,429)
    $pMisc.Controls.AddRange(@($lblCustom,$txtCustom,$btnCustom,$lblOfflineAi,$btnAiAnalyze,$btnAiBenchmark,$btnAiClear,$chatHistory,$txtChatInput,$btnChatSend,$btnPowerPlan,$btnPowerRestore))

    # 10. CLEANUP
    $pCleanup = New-SectionPanel "cleanup" "10. Cleanup"
    $lblCleanupInfo = New-Object System.Windows.Forms.Label
    $lblCleanupInfo.Text = "Trims RAM and clears real Windows caches. Nothing here closes your programs.`nRAM trimming has limited real-world benefit - Windows already manages memory well."
    $lblCleanupInfo.Font = $fontSmall; $lblCleanupInfo.ForeColor = $cWarn
    $lblCleanupInfo.Size = New-Object System.Drawing.Size(640,40)
    $lblCleanupInfo.Location = New-Object System.Drawing.Point(20,55)
    $pCleanup.Controls.Add($lblCleanupInfo)
    $btnCleanNow = New-SectionButton "Clean RAM Now" $cGreenDark
    $btnCleanNow.Location = New-Object System.Drawing.Point(20,130)
    $btnCleanCaches = New-SectionButton "Clear Safe User Caches (Temp/DNS/Unlocked Thumbnails)" $cGreenDark
    $btnCleanCaches.Size = New-Object System.Drawing.Size(505,50)
    $btnCleanCaches.Location = New-Object System.Drawing.Point(20,175)
    $pCleanup.Controls.AddRange(@($btnCleanNow,$btnCleanCaches))
    $chkRamClean = New-ToggleRow "Auto RAM trim every 5 minutes (background, safe per-process)" 103 $pCleanup

    # 11. BIOS
    $pBios = New-SectionPanel "bios" "11. BIOS"
    $lblBiosInfo = New-Object System.Windows.Forms.Label
    $lblBiosInfo.Text = "Nothing here changes anything automatically - just information and a clear recommendation.`nWindows software can't safely change BIOS settings while running; that part stays fully in your control."
    $lblBiosInfo.Font = $fontSmall; $lblBiosInfo.ForeColor = $cWarn
    $lblBiosInfo.Size = New-Object System.Drawing.Size(640,40)
    $lblBiosInfo.Location = New-Object System.Drawing.Point(20,55)
    $pBios.Controls.Add($lblBiosInfo)
    $btnBiosCheck = New-SectionButton "Check My Motherboard + BIOS Version" $cGreenDark
    $btnBiosCheck.Size = New-Object System.Drawing.Size(505,36)
    $btnBiosCheck.Location = New-Object System.Drawing.Point(20,105)
    $btnBiosRestart = New-SectionButton "Restart Into UEFI Setup (optional; firmware options stay manual)" $cGreenDark
    $btnBiosRestart.Size = New-Object System.Drawing.Size(505,34)
    $btnBiosRestart.Location = New-Object System.Drawing.Point(20,150)
    $btnBiosAudit = New-SectionButton "Run BIOS / UEFI Gaming-Readiness Audit" $cGreenDark
    $btnBiosAudit.Size = New-Object System.Drawing.Size(505,34)
    $btnBiosAudit.Location = New-Object System.Drawing.Point(20,191)
    $btnBiosSafeProfile = New-SectionButton "Apply Windows Game Mode (BIOS stays unchanged)" $cGreenDark
    $btnBiosSafeProfile.Size = New-Object System.Drawing.Size(505,34)
    $btnBiosSafeProfile.Location = New-Object System.Drawing.Point(20,232)
    $btnBiosOemTool = New-SectionButton "Open Detected OEM Performance Utility" $cGreenDark
    $btnBiosOemTool.Size = New-Object System.Drawing.Size(505,32)
    $btnBiosOemTool.Location = New-Object System.Drawing.Point(20,273)
    $lblBiosAuditNote = New-Object System.Windows.Forms.Label
    $lblBiosAuditNote.Text = "Checks UEFI mode, Secure Boot, virtualization and RAM speed. Firmware changes remain model-specific; the OEM utility button can launch a supported vendor control app if installed."
    $lblBiosAuditNote.Font = $fontSmall; $lblBiosAuditNote.ForeColor = $cSubText
    $lblBiosAuditNote.Size = New-Object System.Drawing.Size(650,48)
    $lblBiosAuditNote.Location = New-Object System.Drawing.Point(20,313)
    $pBios.Controls.AddRange(@($btnBiosCheck,$btnBiosRestart,$btnBiosAudit,$btnBiosSafeProfile,$btnBiosOemTool,$lblBiosAuditNote))

    # 12. EXPERIMENTAL
    $pExp = New-SectionPanel "experimental" "12. Experimental"
    $lblExpInfo = New-Object System.Windows.Forms.Label
    $lblExpInfo.Text = "Beta features - test at your own pace, use Restore Default Settings if unsure."
    $lblExpInfo.Font = $fontSmall; $lblExpInfo.ForeColor = $cWarn
    $lblExpInfo.AutoSize = $true
    $lblExpInfo.Location = New-Object System.Drawing.Point(20,55)
    $pExp.Controls.Add($lblExpInfo)
    $lblLiveStatus = New-Object System.Windows.Forms.Label
    $lblLiveStatus.Text = "Live Mode: OFF"; $lblLiveStatus.Font = $fontSmall; $lblLiveStatus.ForeColor = [System.Drawing.Color]::Gray
    $lblLiveStatus.AutoSize = $true; $lblLiveStatus.Location = New-Object System.Drawing.Point(60,110)
    $btnRestoreDefaults = New-SectionButton "Restore Saved Settings and Windows Defaults" ([System.Drawing.Color]::FromArgb(150,60,60))
    $btnRestoreDefaults.Size = New-Object System.Drawing.Size(505,36)
    $btnRestoreDefaults.Location = New-Object System.Drawing.Point(20,140)
    $pExp.Controls.AddRange(@($lblLiveStatus,$btnRestoreDefaults))
    $chkLive = New-ToggleRow "Live Mode: keep boosting Minecraft priority while this app is open" 88 $pExp

    # 13. ADOBE APPS
    $pAdobe = New-SectionPanel "adobe" "13. Adobe Apps"
    $lblAdobeInfo = New-Object System.Windows.Forms.Label
    $lblAdobeInfo.Text = "Auto-detects installed Premiere Pro, After Effects and Photoshop. Apply Windows per-app GPU preference where supported; app-specific Mercury/GPU settings remain inside Adobe."
    $lblAdobeInfo.Font = $fontSmall; $lblAdobeInfo.ForeColor = $cWarn
    $lblAdobeInfo.Size = New-Object System.Drawing.Size(640,40)
    $lblAdobeInfo.Location = New-Object System.Drawing.Point(20,55)
    $pAdobe.Controls.Add($lblAdobeInfo)
    $btnAdobeDetect = New-SectionButton "Detect Installed Adobe Apps" $cGreenDark
    $btnAdobeDetect.Location = New-Object System.Drawing.Point(20,105)
    $btnAdobeCache = New-SectionButton "Clear Adobe Media Cache (Premiere/After Effects)" $cGreenDark
    $btnAdobeCache.Location = New-Object System.Drawing.Point(20,150)
    $btnAdobePerf = New-SectionButton "Apply Windows GPU Preference (Adobe apps)" $cGreenDark
    $btnAdobePerf.Size = New-Object System.Drawing.Size(505,32)
    $btnAdobePerf.Location = New-Object System.Drawing.Point(20,195)
    $btnAdobeAudit = New-SectionButton "Audit Adobe Bottlenecks (RAM / Disk / Cache / Processes)" $cGreenDark
    $btnAdobeAudit.Size = New-Object System.Drawing.Size(505,32)
    $btnAdobeAudit.Location = New-Object System.Drawing.Point(20,235)
    $btnAdobeRestoreGpu = New-SectionButton "Restore Previous Adobe GPU Preferences" $cGreenDark
    $btnAdobeRestoreGpu.Size = New-Object System.Drawing.Size(505,32)
    $btnAdobeRestoreGpu.Location = New-Object System.Drawing.Point(20,275)
    $btnAdobeOpenGraphics = New-SectionButton "Open Windows Per-App Graphics Settings" $cGreenDark
    $btnAdobeOpenGraphics.Size = New-Object System.Drawing.Size(505,32)
    $btnAdobeOpenGraphics.Location = New-Object System.Drawing.Point(20,315)
    $pAdobe.Controls.AddRange(@($btnAdobeDetect,$btnAdobeCache,$btnAdobePerf,$btnAdobeAudit,$btnAdobeRestoreGpu,$btnAdobeOpenGraphics))

    # 14. GAME ENGINES - Windows-side actions, without an engine report text box.
    $pEngines = New-SectionPanel "engines" "14. Game Engines"
    $lblEngineInfo = New-Object System.Windows.Forms.Label
    $lblEngineInfo.Text = "Unreal Engine, DirectX and Vulkan. Actions run against Windows settings; status/results are sent to the main activity log, not a separate text box."
    $lblEngineInfo.Font = $fontSmall; $lblEngineInfo.ForeColor = $cWarn
    $lblEngineInfo.Size = New-Object System.Drawing.Size(650,42)
    $lblEngineInfo.Location = New-Object System.Drawing.Point(20,55)
    $pEngines.Controls.Add($lblEngineInfo)
    $lblEngineTarget = New-Object System.Windows.Forms.Label
    $lblEngineTarget.Text = "Target:"; $lblEngineTarget.Font = $fontNormal; $lblEngineTarget.ForeColor = $cText; $lblEngineTarget.AutoSize = $true
    $lblEngineTarget.Location = New-Object System.Drawing.Point(20,107)
    $cmbEngineTarget = New-Object System.Windows.Forms.ComboBox
    $cmbEngineTarget.Font = $fontSmall; $cmbEngineTarget.DropDownStyle = 'DropDownList'
    [void]$cmbEngineTarget.Items.AddRange(@("All Supported", "Unreal Engine", "DirectX", "Vulkan"))
    $cmbEngineTarget.SelectedIndex = 0
    $cmbEngineTarget.Location = New-Object System.Drawing.Point(80,103)
    $cmbEngineTarget.Size = New-Object System.Drawing.Size(200,26)
    $btnEngineScan = New-SectionButton "Scan Support" $cGreenDark
    $btnEngineScan.Size = New-Object System.Drawing.Size(150,30); $btnEngineScan.Location = New-Object System.Drawing.Point(295,101)
    $btnEngineTips = New-SectionButton "Optimization Guide" $cGreenDark
    $btnEngineTips.Size = New-Object System.Drawing.Size(170,30); $btnEngineTips.Location = New-Object System.Drawing.Point(455,101)
    $btnEngineDxDiag = New-SectionButton "Open DirectX Diagnostics" $cGreenDark
    $btnEngineDxDiag.Size = New-Object System.Drawing.Size(220,30); $btnEngineDxDiag.Location = New-Object System.Drawing.Point(20,143)
    $btnEngineGraphics = New-SectionButton "Windows Graphics Settings" $cGreenDark
    $btnEngineGraphics.Size = New-Object System.Drawing.Size(220,30); $btnEngineGraphics.Location = New-Object System.Drawing.Point(250,143)
    $btnEngineBenchmark = New-SectionButton "Run Lightweight CPU/RAM Benchmark" $cGreenDark
    $btnEngineBenchmark.Size = New-Object System.Drawing.Size(200,30); $btnEngineBenchmark.Location = New-Object System.Drawing.Point(480,143); $btnEngineBenchmark.Font = $fontSmall
    $btnEngineApply = New-SectionButton "Apply Safe Windows Engine Profile" $cGreenDark
    $btnEngineApply.Size = New-Object System.Drawing.Size(315,34); $btnEngineApply.Location = New-Object System.Drawing.Point(20,185)
    $btnEngineRestore = New-SectionButton "Restore Engine GPU Preferences" $cGreenDark
    $btnEngineRestore.Size = New-Object System.Drawing.Size(315,34); $btnEngineRestore.Location = New-Object System.Drawing.Point(350,185)
    $btnEngineOpenUnreal = New-SectionButton "Launch Detected Unreal Editor (if installed)" $cGreenDark
    $btnEngineOpenUnreal.Size = New-Object System.Drawing.Size(505,34); $btnEngineOpenUnreal.Location = New-Object System.Drawing.Point(20,227)
    $lblEngineStatus = New-Object System.Windows.Forms.Label
    $lblEngineStatus.Text = "Safe scope: Windows Game Mode + per-app GPU preference for detected Unreal Editor executables. API/runtime support is inspected, not forcibly changed globally."
    $lblEngineStatus.Font = $fontSmall; $lblEngineStatus.ForeColor = $cSubText
    $lblEngineStatus.Size = New-Object System.Drawing.Size(650,58)
    $lblEngineStatus.Location = New-Object System.Drawing.Point(20,273)
    $pEngines.Controls.AddRange(@($lblEngineTarget,$cmbEngineTarget,$btnEngineScan,$btnEngineTips,$btnEngineDxDiag,$btnEngineGraphics,$btnEngineBenchmark,$btnEngineApply,$btnEngineRestore,$btnEngineOpenUnreal,$lblEngineInfo,$lblEngineStatus))

    $logBox.Location = New-Object System.Drawing.Point(20,40)
    $logBox.Size = New-Object System.Drawing.Size(660,140)
    $logBox.Anchor = 'Top,Left,Right,Bottom'
    $progress.Location = New-Object System.Drawing.Point(20,16)
    $progress.Size = New-Object System.Drawing.Size(660,14)
    $progress.Anchor = 'Top,Left,Right'
    $footerPanel.Controls.Add($logBox)
    $footerPanel.Controls.Add($progress)

    function Test-ServerPing($address, $port) {
        if ([string]::IsNullOrWhiteSpace($address)) { Log "No server address entered."; return $null }
        try { $resolved = [System.Net.Dns]::GetHostAddresses($address) | Select-Object -First 1; Log "Resolved '$address' -> $resolved" }
        catch { Log "FAILED - could not resolve '$address': $($_.Exception.Message)"; return $null }
        $mode = $cmbProtocol.SelectedItem
        if ($mode -ne "TCP only") {
            try {
                $results = Test-Connection -ComputerName $address -Count 4 -ErrorAction Stop
                $avg = [math]::Round(($results | Measure-Object -Property ResponseTime -Average).Average, 1)
                Log "ICMP ping to $address -> avg ${avg}ms"; return $avg
            } catch {
                if ($mode -eq "ICMP only") { Log "FAILED - ICMP only and ICMP failed."; return $null }
                Log "ICMP blocked - trying TCP on port $port..."
            }
        }
        try {
            $times = @()
            for ($i=0; $i -lt 4; $i++) {
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                $tcp = New-Object System.Net.Sockets.TcpClient
                $iar = $tcp.BeginConnect($address, [int]$port, $null, $null)
                $ok = $iar.AsyncWaitHandle.WaitOne(2000, $false)
                $sw.Stop()
                if ($ok -and $tcp.Connected) { $times += $sw.Elapsed.TotalMilliseconds; $tcp.EndConnect($iar) }
                $tcp.Close()
            }
            if ($times.Count -gt 0) { $avg = [math]::Round(($times | Measure-Object -Average).Average, 1); Log "TCP connect time -> avg ${avg}ms"; return $avg }
            else { Log "FAILED - port $port did not respond."; return $null }
        } catch { Log "FAILED - TCP test error: $($_.Exception.Message)"; return $null }
    }
    function Test-HitRegNetworkQuality {
        $server = $txtServer.Text.Trim()
        $portText = $txtPort.Text.Trim()
        $port = 25565
        if (-not [string]::IsNullOrWhiteSpace($portText)) { [void][int]::TryParse($portText, [ref]$port) }
        if ([string]::IsNullOrWhiteSpace($server)) { Log '[HitReg] Enter the actual game server host first.'; return }
        Log '===================================================='
        Log "[HitReg] Quality test for $server (port $port). This measures the route, not the game server's hit-registration code."
        $pingTimes = New-Object System.Collections.Generic.List[double]
        $lost = 0
        $p = New-Object System.Net.NetworkInformation.Ping
        for ($i = 1; $i -le 12; $i++) {
            try {
                $reply = $p.Send($server, 900)
                if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    $pingTimes.Add([double]$reply.RoundtripTime)
                } else { $lost++ }
            } catch { $lost++ }
            Log "   ICMP sample $i/12 complete"
            [System.Windows.Forms.Application]::DoEvents()
        }
        $p.Dispose()
        if ($pingTimes.Count -gt 0) {
            $avg = [Math]::Round((($pingTimes | Measure-Object -Average).Average),1)
            $min = [Math]::Round((($pingTimes | Measure-Object -Minimum).Minimum),1)
            $max = [Math]::Round((($pingTimes | Measure-Object -Maximum).Maximum),1)
            $jitterValues = @()
            for ($i = 1; $i -lt $pingTimes.Count; $i++) { $jitterValues += [Math]::Abs($pingTimes[$i] - $pingTimes[$i-1]) }
            $jitter = if ($jitterValues.Count -gt 0) { [Math]::Round((($jitterValues | Measure-Object -Average).Average),1) } else { 0 }
            $lossPct = [Math]::Round(($lost / 12.0) * 100,1)
            Log "   ICMP results: received $($pingTimes.Count)/12 | loss $lossPct% | avg $avg ms | min $min ms | max $max ms | average consecutive variation (rough jitter) $jitter ms"
        } else {
            Log '   ICMP samples failed or were blocked by the server/network. ICMP loss must not be mistaken for game packet loss.'
        }
        $connectTimes = New-Object System.Collections.Generic.List[double]
        for ($i = 1; $i -le 5; $i++) {
            $tcp = $null
            try {
                $tcp = New-Object System.Net.Sockets.TcpClient
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                $ar = $tcp.BeginConnect($server, $port, $null, $null)
                if ($ar.AsyncWaitHandle.WaitOne(1200, $false) -and $tcp.Connected) {
                    $tcp.EndConnect($ar); $sw.Stop(); $connectTimes.Add([double]$sw.Elapsed.TotalMilliseconds)
                } else { $sw.Stop() }
            } catch {} finally { if ($tcp) { $tcp.Close() } }
            [System.Windows.Forms.Application]::DoEvents()
        }
        if ($connectTimes.Count -gt 0) {
            $tcpAvg = [Math]::Round((($connectTimes | Measure-Object -Average).Average),1)
            Log "   TCP connect timing: $($connectTimes.Count)/5 completed | avg $tcpAvg ms (connection setup timing, not a direct in-game ping measurement)."
        } else { Log "   TCP connection test could not connect to $server`:$port. Confirm the host and game port." }
        Log '   How to interpret: stable ping + unstable clicks can be local frame-time/input delay; real hit registration also depends on server TPS/netcode and client tick timing.'
        Log '   No settings were modified by this diagnostic.'
    }

    function Reset-NetworkStack {
        Log "[Network] Resetting TCP/IP stack and Winsock catalog..."
        Safe-Run { netsh winsock reset | Out-Null; Log "   Winsock reset" } "WinsockReset"
        Safe-Run { netsh int ip reset | Out-Null; Log "   TCP/IP stack reset" } "TcpIpReset"
        Log "Done. A restart is required for this to take effect."
        Prompt-Restart
    }
    function Backup-Registry {
        Log "Backing up registry..."
        Safe-Run { reg export "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" "$env:TEMP\tcpip_backup.reg" /y 2>$null } "Backup Tcpip"
        Safe-Run { reg export "HKCU\System\GameConfigStore" "$env:TEMP\gamecfg_backup.reg" /y 2>$null } "Backup GameConfig"
        Log "Backup saved."
    }
    function Prompt-Restart {
        $r = [System.Windows.Forms.MessageBox]::Show("Restart now for full effect?", "Restart", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::None)
        if ($r -eq [System.Windows.Forms.DialogResult]::Yes) { Log "Restarting in 5s..."; Start-Sleep -Seconds 5; Restart-Computer -Force }
        else { Log "Restart postponed." }
    }
    function Do-TcpTweaks {
        Log "[TCP] Applying a conservative Windows TCP baseline, not registry folklore..."
        Safe-Run { netsh int tcp set global autotuninglevel=normal | Out-Null; Log "   TCP receive-window autotuning set to Windows default: normal" } "AutoTuning"
        Safe-Run { netsh int tcp set global rss=enabled | Out-Null; Log "   Receive Side Scaling enabled where supported" } "RSS"
        Safe-Run { ipconfig /flushdns | Out-Null; Log "   DNS cache flushed (affects name lookup, not existing server route latency)" } "FlushDNS"
        Log "   Skipped undocumented Nagle/DSCP/CTCP/NetDMA/DCA and aggressive registry overrides; they are not universal ping optimizations."
        Log "   No guarantee of a lower game ping: ISP routing, Wi-Fi contention and server location dominate baseline RTT."
    }
    function Do-AdapterTweaksOnly {
        Log '[Network] Inspecting active adapter capabilities...'
        try {
            $adapters = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })
            if ($adapters.Count -eq 0) { Log '   No active physical adapters found.'; return }
            foreach ($adapter in $adapters) {
                Log "   Adapter: $($adapter.Name) | $($adapter.InterfaceDescription) | Link $($adapter.LinkSpeed) | MAC $($adapter.MacAddress)"
                try {
                    $props = @(Get-NetAdapterAdvancedProperty -Name $adapter.Name -ErrorAction Stop | Where-Object { $_.DisplayName -match '(?i)power|band|roaming|interrupt|energy|throughput|MIMO' })
                    foreach ($prop in $props) { Log "      $($prop.DisplayName): $($prop.DisplayValue)" }
                } catch { Log '      Advanced-property query not supported by this driver.' }
            }
            Log '   No adapter properties were changed. Use the exact adapter driver options and test one change at a time; Ethernet-only options are not applied to Wi-Fi automatically.'
            try { Start-Process 'ms-settings:network-status' } catch {}
        } catch { Log "   Adapter inspection failed: $($_.Exception.Message)" }
    }
    function Do-FpsTweaks {
        Log "[Gaming] Applying reversible user-level Windows gaming settings..."
        $gameBarPath = "HKCU:\Software\Microsoft\GameBar"
        try { Save-RegistrySnapshot (Get-GameModeRegistrySpecs) (Get-RegistryBackupFile 'gaming-mode-backup.json') } catch { Log "Could not save Game Mode backup: $($_.Exception.Message)"; return }
        Set-VerifiedRegValue $gameBarPath "AllowAutoGameMode" 1 "DWord" "AllowAutoGameMode"
        Set-VerifiedRegValue $gameBarPath "AutoGameModeEnabled" 1 "DWord" "AutoGameModeEnabled"
        if ($chkVisualFX.Checked) {
            Log "   Visual effects option selected. Windows UI animations may be reduced; this does not change game GPU capability."
            try {
                $visualSpecs = @(@{ Path = 'HKCU:\Control Panel\Desktop'; Name = 'UserPreferencesMask' })
                Save-RegistrySnapshot $visualSpecs (Get-RegistryBackupFile 'visual-effects-backup.json')
            } catch { Log "   Could not save visual-effects backup: $($_.Exception.Message)"; return }
            Safe-Run { Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "UserPreferencesMask" -Value ([byte[]](0x90,0x12,0x03,0x80,0x10,0x00,0x00,0x00)) -Force } "VisualFX"
        } else { Log "   Left Windows visual effects unchanged (opt-in is off)." }
        Safe-Run {
            $procs = Get-Process -Name "javaw","java" -ErrorAction SilentlyContinue
            foreach ($proc in $procs) {
                try { $proc.PriorityClass = "AboveNormal"; Log "   Temporarily set $($proc.ProcessName) PID $($proc.Id) to AboveNormal priority (resets when process exits)." } catch { Log "   Could not adjust PID $($proc.Id): $($_.Exception.Message)" }
            }
            if (-not $procs) { Log "   No Java/Minecraft process is currently running; launch the game and use Live Mode if you need temporary priority management." }
        } "GameProcessPriority"
        Log "   Security and core services left alone: no Defender exclusion, no Windows Update/SysMain disabling, no guessed TDR/HAGS or core-parking edits."
        Log "Done. Game Mode can reduce OS interference on some systems, but FPS gains depend on the actual bottleneck."
    }
    function Optimize-Network {
        $server = $txtServer.Text.Trim(); $port = $txtPort.Text.Trim(); if (-not $port) { $port = 25565 }
        Log "===================================================="
        $before = Test-ServerPing $server $port
        Set-Progress 5; Backup-Registry; Set-Progress 15
        Do-TcpTweaks; Set-Progress 90
        Log "Measuring ping AFTER..."
        $after = Test-ServerPing $server $port
        Set-Progress 100
        Log "===================================================="
        if ($before -ne $null -and $after -ne $null) { $diff = [math]::Round($before - $after, 1); Log "RESULT: before=${before}ms after=${after}ms change=${diff}ms" }
        else { Log "Could not fully compare before/after." }
        Log "DONE. Network defaults apply immediately; compare another set of samples before deciding whether they helped. No restart is normally required."
    }
    function Optimize-FPS { Backup-Registry; Set-Progress 10; Do-FpsTweaks; Set-Progress 100; Log "DONE - safe gaming settings applied. Reopen the game and compare the same scene; no restart is normally required." }
    function Set-LookPerformancePowerPlan([switch]$Silent) {
        if (-not $Silent) {
            $choice = [System.Windows.Forms.MessageBox]::Show('Switch the active Windows power plan to High Performance (SCHEME_MIN)? This can increase heat, fan noise and battery drain on laptops. It does not overclock the CPU or change voltage. The current plan will be saved for restore.', 'Confirm performance power plan', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::None)
            if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { Log 'Power plan change cancelled.'; return }
        }
        $backup = Get-RegistryBackupFile 'power-plan-backup.txt'
        try {
            $activeText = (powercfg /getactivescheme 2>&1 | Out-String)
            if ($activeText -notmatch '([a-fA-F0-9]{8}-(?:[a-fA-F0-9]{4}-){3}[a-fA-F0-9]{12})') { Log 'Could not identify the active power plan. No change made.'; return }
            if (-not (Test-Path -LiteralPath $backup)) { Set-Content -LiteralPath $backup -Value $Matches[1] -Encoding ASCII }
            powercfg /setactive SCHEME_MIN | Out-Null
            if ($LASTEXITCODE -eq 0) { Log 'High Performance power scheme activated. Compare temperature and performance; if heat/noise increases, restore the previous scheme.' }
            else { Log 'Windows did not activate SCHEME_MIN. No successful change is claimed; previous-plan backup retained.' }
        } catch { Log "Power plan switch failed: $($_.Exception.Message)" }
    }

    function Restore-LookPerformancePowerPlan([switch]$Silent) {
        $backup = Get-RegistryBackupFile 'power-plan-backup.txt'
        if (-not (Test-Path -LiteralPath $backup)) { Log 'No saved previous power plan exists.'; return }
        if (-not $Silent) {
            $choice = [System.Windows.Forms.MessageBox]::Show('Restore the power plan that was active before LOOK Performance Mode?', 'Restore previous power plan', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::None)
            if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { Log 'Power plan restore cancelled.'; return }
        }
        try {
            $guid = (Get-Content -LiteralPath $backup -Raw -ErrorAction Stop).Trim()
            if ($guid -notmatch '^[a-fA-F0-9]{8}-(?:[a-fA-F0-9]{4}-){3}[a-fA-F0-9]{12}$') { Log 'Saved power-plan ID is invalid; no change made.'; return }
            powercfg /setactive $guid | Out-Null
            if ($LASTEXITCODE -eq 0) { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue; Log "Restored previous power scheme $guid." }
            else { Log 'Windows could not restore the saved scheme. Backup retained.' }
        } catch { Log "Power plan restore failed: $($_.Exception.Message)" }
    }

    function Restore-Defaults {
        $choice = [System.Windows.Forms.MessageBox]::Show('Restore saved Look at the Latency snapshots and return supported network globals to Windows defaults? Your active power plan and unrelated registry values will be left unchanged.', 'Confirm restore', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::None)
        if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { Log 'Restore cancelled.'; return }
        Set-Progress 10; Log 'Restoring saved app snapshots and supported TCP defaults...'
        Safe-Run { if (Test-Path "$env:TEMP\tcpip_backup.reg") { reg import "$env:TEMP\tcpip_backup.reg" 2>$null } } 'Restore Tcpip Backup'
        Safe-Run { if (Test-Path "$env:TEMP\gamecfg_backup.reg") { reg import "$env:TEMP\gamecfg_backup.reg" 2>$null } } 'Restore GameConfig Backup'
        Set-Progress 35
        Safe-Run { netsh int tcp set global autotuninglevel=normal | Out-Null } 'TCP AutoTuning default'
        Safe-Run { netsh int tcp set global rss=enabled | Out-Null } 'TCP RSS default'
        Safe-Run { Remove-NetQosPolicy -Name 'LookAtTheLatency-Java' -Confirm:$false -ErrorAction SilentlyContinue } 'Remove app Java QoS policy'
        Safe-Run { Remove-NetQosPolicy -Name 'LookAtTheLatency-AntiSpike' -Confirm:$false -ErrorAction SilentlyContinue } 'Remove app AntiSpike QoS policy'
        Set-Progress 55
        foreach ($backupName in @('gaming-mode-backup.json','gaming-gpu-preferences-backup.json','engine-gpu-preferences-backup.json','adobe-gpu-preferences-backup.json','visual-effects-backup.json')) {
            try { Restore-RegistrySnapshot (Get-RegistryBackupFile $backupName) } catch { Log "Could not restore $backupName : $($_.Exception.Message)" }
        }
        try { Restore-LookPerformancePowerPlan -Silent } catch {}
        Set-Progress 100
        Log 'Restore finished. Supported app snapshots and any saved power plan were restored; unrelated registry values and essential services were left alone.'
        Prompt-Restart
    }
    function Clean-RamNow {
        Log "[Cleanup] Trimming RAM per-process (safe, gradual - like MemReduct/RAMMap)..."
        Safe-Run {
            Add-Type -MemberDefinition '
[DllImport("kernel32.dll")] public static extern bool SetProcessWorkingSetSize(IntPtr proc, int min, int max);
' -Name "Ps2" -Namespace "Win32" -ErrorAction SilentlyContinue
            $procs = Get-Process | Where-Object { $_.WorkingSet64 -gt 50MB -and $_.Id -ne $PID } | Sort-Object WorkingSet64 -Descending | Select-Object -First 25
            $trimmed = 0
            foreach ($p in $procs) {
                try {
                    [Win32.Ps2]::SetProcessWorkingSetSize($p.Handle, -1, -1) | Out-Null
                    $trimmed++
                    Start-Sleep -Milliseconds 15
                } catch {}
            }
            Log "   Trimmed $trimmed processes one at a time (no system-wide freeze)."
        } "RAMTrim"
        Log "Done. Note: real-world benefit is limited - Windows already manages memory well."
    }
    function Clean-WindowsCaches {
        $choice = [System.Windows.Forms.MessageBox]::Show('Clean files in your user TEMP folder, flush DNS, and remove unlocked thumbnail-cache files? This will NOT empty the Recycle Bin, clear Windows Update downloads, delete Prefetch, or stop Windows services.', 'Confirm safe cache cleanup', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::None)
        if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { Log '[Cleanup] Cancelled by user.'; return }
        Log '[Cleanup] Cleaning limited user-level caches...'
        Set-Progress 10
        $tempRoot = $env:TEMP
        if ($tempRoot -and (Test-Path -LiteralPath $tempRoot)) {
            try {
                $tempItems = @(Get-ChildItem -LiteralPath $tempRoot -Force -ErrorAction SilentlyContinue)
                $removed = 0
                foreach ($item in $tempItems) {
                    try { Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop; $removed++ }
                    catch { Log "   Skipped locked temp item: $($item.Name)" }
                }
                Log "   User TEMP: removed $removed item(s); locked items were skipped."
            } catch { Log "   TEMP cleanup issue: $($_.Exception.Message)" }
        } else { Log '   User TEMP folder not found.' }
        Set-Progress 55
        Safe-Run { ipconfig /flushdns | Out-Null; Log '   DNS cache flushed (affects name resolution only, not existing route latency)' } 'FlushDNS'
        Set-Progress 75
        $thumbPath = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'
        if (Test-Path -LiteralPath $thumbPath) {
            try {
                $thumbFiles = @(Get-ChildItem -LiteralPath $thumbPath -Filter 'thumbcache_*.db' -File -ErrorAction SilentlyContinue)
                $removedThumbs = 0
                foreach ($file in $thumbFiles) { try { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop; $removedThumbs++ } catch {} }
                Log "   Unlocked thumbnail-cache files removed: $removedThumbs (Windows may rebuild them)."
            } catch { Log '   Thumbnail cache was left unchanged.' }
        }
        Set-Progress 100
        Log 'Cleanup complete. No Windows Update, security, Prefetch, font-cache or Recycle Bin changes were made.'
    }
    function Detect-Gpu {
        Safe-Run {
            $gpus = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch "Basic|Remote" }
            if ($gpus) {
                $names = ($gpus | ForEach-Object { $_.Name }) -join ", "
                Log "Detected GPU(s): $names"
                if ($names -match "NVIDIA") { Start-Process "https://www.nvidia.com/Download/index.aspx" }
                elseif ($names -match "AMD|Radeon") { Start-Process "https://www.amd.com/en/support" }
                elseif ($names -match "Intel") { Start-Process "https://www.intel.com/content/www/us/en/download-center/home.html" }
                else { Log "Unknown vendor - search manually." }
            } else { Log "Could not detect GPU." }
        } "GPUDetect"
    }
    function Optimize-Gpu {
        Log "[GPU] Inspecting graphics hardware and opening supported Windows GPU controls..."
        try {
            $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction Stop | Where-Object { $_.Name -notmatch "Basic|Remote" })
            foreach ($gpu in $gpus) { Log "   GPU: $($gpu.Name) | driver $($gpu.DriverVersion)" }
            if (-not $gpus) { Log "   No GPU adapter reported by WMI." }
        } catch { Log "   GPU query failed: $($_.Exception.Message)" }
        Log "   No global TDR, HAGS, voltage, clock or registry changes were applied. Use per-app GPU preference where supported."
        try { Start-Process 'ms-settings:display-graphics'; Log "   Opened Windows Graphics settings." } catch { Log "   Open Settings manually: System > Display > Graphics." }
    }
    function Show-GameModeTips {
        $mode = $cmbGameMode.SelectedItem
        Log "Recommended settings for: $mode"
        switch -Wildcard ($mode) {
            "PvP*" {
                Log " - Render Distance 4-6 | Particles Minimal | Shadows/Dynamic Lights OFF | VSync OFF"
                Log " - Max FPS: unlimited or match monitor Hz | Mouse sensitivity: keep consistent, don't change it per-fight"
            }
            "Bedwars*" { Log " - Render Distance 6-8 | Particles Minimal | Fast Graphics ON" }
            "Bridging*" {
                Log " - FOV: keep FIXED (changing FOV mid-bridge throws off your muscle memory for block placement)"
                Log " - Render Distance 6-8 | Smooth Lighting OFF (helps you see block edges clearly)"
                Log " - Max FPS: match your monitor Hz exactly - inconsistent FPS is the #1 cause of missed bridge clicks"
                Log " - Enable Live Mode (Optimize tab) so priority stays high even if you alt-tab to check a guide"
            }
            "Fireball*" {
                Log " - Particles: Minimal - this is the single biggest FPS killer during ghast/fireball fights"
                Log " - Entity Shadows/Clouds/Dynamic Lights: OFF"
                Log " - Reduce Render Distance to 4-6 during heavy fireball spam specifically"
                Log " - Run 'Boost FPS' above - it applies CPU core-parking-off and I/O priority tweaks that specifically target this kind of burst lag"
            }
            "Survival*" { Log " - Render Distance 10-16 | Smooth Lighting ON" }
            "Skyblock*" { Log " - Render Distance 6-10 | Particles Minimal" }
            default { Log " - Particles Minimal | Render Distance 6-10" }
        }
    }
    function Detect-GameClients {
        Log "===================================================="
        Log "[Games] Scanning for installed Minecraft launchers/clients..."
        Safe-Run {
            $found = @()
            $checks = @(
                @{n="Official Minecraft Launcher"; p="$env:APPDATA\.minecraft"},
                @{n="TLauncher";                   p="$env:APPDATA\.tlauncher"},
                @{n="Lunar Client";                p="$env:USERPROFILE\.lunarclient"},
                @{n="Badlion Client";               p="$env:APPDATA\.minecraft\Badlion Client"},
                @{n="Feather Client";               p="$env:APPDATA\.minecraft\feather"},
                @{n="CurseForge / Overwolf";         p="$env:APPDATA\Overwolf"},
                @{n="MultiMC / Prism Launcher";     p="$env:APPDATA\PrismLauncher"}
            )
            foreach ($c in $checks) {
                if (Test-Path $c.p) { $found += $c.n }
            }
            if ($found.Count -gt 0) { Log "   Found: $($found -join ', ')" }
            else { Log "   No common launchers found in default locations - if you use a custom install path, tweaks still apply system-wide." }
        } "GameDetect"
    }
    function Enable-AntiSpikeMode {
        Log "===================================================="
        Log "[Games] Checking for common bandwidth-heavy apps. Essential Windows services will not be stopped."
        foreach ($name in @('OneDrive','steam','steamwebhelper','EpicGamesLauncher','Battle.net','DeliveryOptimization')) {
            $running = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
            if ($running.Count -gt 0) { Log "   $name is running ($($running.Count) process(es)); pause downloads/sync manually if a match is active." }
        }
        $wu = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
        if ($wu) { Log "   Windows Update status: $($wu.Status). This tool leaves the service unchanged." }
        Log "   Tip: for hit-registration troubleshooting, run the Latency > HitReg / Jitter / Packet-Loss Diagnostic while no downloads are active."
        Log "Done. This check does not promise lower ping; it avoids changing update, security, or sync services automatically."
    }
    function Remove-Bloatware {
        $apps = @("Microsoft.3DBuilder","Microsoft.MixedReality.Portal","Microsoft.XboxApp","Microsoft.YourPhone","Microsoft.BingWeather","Microsoft.BingNews","Microsoft.GetHelp","Microsoft.Getstarted","Microsoft.MicrosoftSolitaireCollection","Microsoft.ZuneMusic","Microsoft.ZuneVideo","Microsoft.MicrosoftOfficeHub","Microsoft.People","Microsoft.WindowsFeedbackHub","Microsoft.Wallet","microsoft.windowscommunicationsapps")
        $choice = [System.Windows.Forms.MessageBox]::Show("This uninstalls selected built-in apps for the current user. Apps may be reinstallable through Microsoft Store but this is still a removal operation.`n`nContinue?", 'Confirm app removal', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::None)
        if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { Log '[Bloatware] Removal cancelled.'; return }
        Log "[Bloatware] Removing selected built-in apps for this user..."
        foreach ($app in $apps) {
            Safe-Run {
                $pkg = Get-AppxPackage -Name $app -ErrorAction SilentlyContinue
                if ($pkg) { Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction Stop; Log "   Removed: $app" }
                else { Log "   Not installed: $app" }
            } "Remove $app"
        }
        Log "Done. Reinstall any of these anytime from the Microsoft Store."
    }
    function Reduce-Telemetry {
        Log "[Telemetry] Reducing diagnostic data + disabling non-essential scheduled tasks..."
        Set-VerifiedRegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowTelemetry" 0 "DWord" "AllowTelemetry"
        $tasks = @(
            "\Microsoft\Windows\Customer Experience Improvement Program\Consolidator",
            "\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip",
            "\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser",
            "\Microsoft\Windows\Application Experience\ProgramDataUpdater"
        )
        foreach ($t in $tasks) { Safe-Run { Disable-ScheduledTask -TaskPath ($t | Split-Path) -TaskName ($t | Split-Path -Leaf) -ErrorAction Stop | Out-Null; Log "   Disabled task: $t" } "Task $t" }
        Log "[Telemetry] Disabling Advertising ID (used for personalized ads across apps)..."
        Set-VerifiedRegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo" "DisabledByGroupPolicy" 1 "DWord" "AdvertisingID"
        Log "Done. This does not stop Windows Update or security features."
    }
    function Invoke-PerformanceRadar {
        Log '===================================================='
        Log '[LOOK Performance Radar] Taking a read-only resource snapshot...'
        try {
            $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
            $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            $drive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'" -ErrorAction SilentlyContinue | Select-Object -First 1
            Log "CPU: $($cpu.Name) | cores $($cpu.NumberOfCores) | logical $($cpu.NumberOfLogicalProcessors)"
            $totalRam = [Math]::Round($cs.TotalPhysicalMemory / 1GB,1)
            $freeRam = [Math]::Round($os.FreePhysicalMemory / 1MB,1)
            Log "RAM: $freeRam GB free / $totalRam GB total"
            if ($drive) { Log "System drive: $([Math]::Round($drive.FreeSpace/1GB,1)) GB free / $([Math]::Round($drive.Size/1GB,1)) GB" }
            try {
                $cpuLoad = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop
                if ($null -ne $cpuLoad.PercentProcessorTime) { Log "Current total CPU load: $($cpuLoad.PercentProcessorTime)% (one snapshot; not a benchmark)." }
            } catch { Log 'Current CPU load counter is unavailable on this Windows build.' }
            $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch 'Basic|Remote' })
            foreach ($gpu in $gpus) { Log "GPU: $($gpu.Name) | driver $($gpu.DriverVersion)" }
            $busy = @(Get-Process -ErrorAction SilentlyContinue | Sort-Object WorkingSet64 -Descending | Select-Object -First 6)
            Log 'Top memory consumers right now:'
            foreach ($proc in $busy) { Log ("   {0} | {1:N0} MB" -f $proc.ProcessName, ($proc.WorkingSet64 / 1MB)) }
            $gameProcesses = @(Get-Process -Name 'javaw','java','cs2','cs2_win64','UnrealEditor','AfterFX','Photoshop' -ErrorAction SilentlyContinue)
            if ($gameProcesses.Count -gt 0) { Log ("Detected active game/creator processes: " + (($gameProcesses | ForEach-Object { $_.ProcessName } | Sort-Object -Unique) -join ', ')) }
            else { Log 'No common game/creator process was detected; launch the target app and run the radar again for a process-specific snapshot.' }
            Log 'Radar is diagnostic only. Compare the same scene before/after a change; one snapshot cannot prove the bottleneck.'
        } catch { Log "[LOOK Performance Radar] Scan failed: $($_.Exception.Message)" }
    }

    function Show-SystemSummary {
        Log "===================================================="
        try {
            $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
            $ram = Get-CimInstance Win32_ComputerSystem
            $os = Get-CimInstance Win32_OperatingSystem
            $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
            $gpus = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch "Basic|Remote" }
            Log "CPU: $($cpu.Name)"
            Log "RAM: $([math]::Round($ram.TotalPhysicalMemory/1GB,1)) GB total, $([math]::Round($os.FreePhysicalMemory/1MB,1)) GB free"
            if ($disk) { Log "Disk C: $([math]::Round($disk.FreeSpace/1GB,1)) GB free of $([math]::Round($disk.Size/1GB,1)) GB" }
            foreach ($gpu in $gpus) { Log "GPU: $($gpu.Name)" }
            Log "OS: $($os.Caption) (Build $($os.BuildNumber))"
        } catch { Log "Could not read full system info: $($_.Exception.Message)" }
    }
    function Renew-IpAddress {
        Log "[Network] Releasing and renewing IP address..."
        Safe-Run {
            ipconfig /release | Out-Null
            Start-Sleep -Milliseconds 500
            ipconfig /renew | Out-Null
            $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notmatch "^127\.|^169\.254\." } | Select-Object -First 1).IPAddress
            $lblCurrentIp.Text = "Current IP: $ip"
            Log "   New IP: $ip"
        } "RenewIP"
    }
    function Apply-CustomDns {
        $d1 = $fldDns1.Input.Text.Trim(); $d2 = $fldDns2.Input.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($d1)) { Log "Enter at least a primary DNS address."; return }
        Log "[DNS] Applying $d1, $d2 to active adapters..."
        Safe-Run {
            foreach ($a in (Get-NetAdapter | Where-Object {$_.Status -eq "Up"})) {
                if ([string]::IsNullOrWhiteSpace($d2)) {
                    Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses $d1
                } else {
                    Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses @($d1,$d2)
                }
                Log "   Applied to $($a.Name)"
            }
            ipconfig /flushdns | Out-Null
        } "ApplyDNS"
        Log "Done."
    }
    function Test-DnsSpeed {
        Log "===================================================="
        Log "[DNS] Testing resolve + connect time via current DNS settings (C# probe)..."
        $result = [NetProbe]::TestResolveAndConnect("mc.hypixel.net", 25565)
        if ($result -match "^OK:(\d+):(\d+):(.+)$") {
            Log "   Resolve time: $($Matches[1])ms | Connect time: $($Matches[2])ms | Resolved to: $($Matches[3])"
        } elseif ($result -match "^RESOLVE_FAILED:(.+)$") {
            Log "   DNS resolve failed: $($Matches[1])"
        } else {
            Log "   $result"
        }
    }
    function Get-AdobeExecutablePaths {
        $apps = New-Object System.Collections.Generic.List[object]
        $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:ProgramFiles\Adobe", "${env:ProgramFiles(x86)}\Adobe") | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
        foreach ($root in $roots) {
            $adobeRoot = if ($root -match '(?i)\\Adobe$') { $root } elseif (Test-Path (Join-Path $root 'Adobe')) { Join-Path $root 'Adobe' } else { $null }
            if (-not $adobeRoot) { continue }
            try {
                foreach ($dir in (Get-ChildItem -LiteralPath $adobeRoot -Directory -ErrorAction SilentlyContinue)) {
                    $exeCandidates = @()
                    if ($dir.Name -match '(?i)Premiere Pro') { $exeCandidates += Join-Path $dir.FullName 'Adobe Premiere Pro.exe' }
                    if ($dir.Name -match '(?i)After Effects') { $exeCandidates += Join-Path $dir.FullName 'Support Files\AfterFX.exe' }
                    if ($dir.Name -match '(?i)Photoshop') { $exeCandidates += Join-Path $dir.FullName 'Photoshop.exe' }
                    if ($dir.Name -match '(?i)Lightroom') { $exeCandidates += Join-Path $dir.FullName 'Lightroom.exe'; $exeCandidates += Join-Path $dir.FullName 'Lightroom.exe' }
                    foreach ($exe in $exeCandidates) { if (Test-Path -LiteralPath $exe) { $apps.Add([pscustomobject]@{ Name = $dir.Name; Path = $exe }) } }
                }
            } catch {}
        }
        # Add uninstall-registry locations for custom-drive Adobe installs.
        $regRoots = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')
        foreach ($key in $regRoots) {
            try {
                foreach ($entry in @(Get-ItemProperty $key -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match '(?i)Adobe (Premiere Pro|After Effects|Photoshop)' })) {
                    $root=[string]$entry.InstallLocation; if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
                    $candidate=@()
                    if ($entry.DisplayName -match '(?i)Premiere Pro') { $candidate += Join-Path $root 'Adobe Premiere Pro.exe' }
                    if ($entry.DisplayName -match '(?i)After Effects') { $candidate += Join-Path $root 'Support Files\AfterFX.exe'; $candidate += Join-Path $root 'AfterFX.exe' }
                    if ($entry.DisplayName -match '(?i)Photoshop') { $candidate += Join-Path $root 'Photoshop.exe' }
                    foreach ($exe in $candidate) { if (Test-Path -LiteralPath $exe) { $apps.Add([pscustomobject]@{ Name=[string]$entry.DisplayName; Path=$exe }) } }
                }
            } catch {}
        }
        $unique = @{}
        foreach ($app in $apps) { $unique[$app.Path.ToLowerInvariant()] = $app }
        return @($unique.Values | Sort-Object Path)
    }

    function Detect-AdobeApps {
        Log '[Adobe] Scanning common Adobe install locations...'
        $apps = @(Get-AdobeExecutablePaths)
        if ($apps.Count -gt 0) {
            foreach ($app in $apps) { Log "   Found: $($app.Name) -> $($app.Path)" }
        } else { Log '   No supported Adobe executable found in common Program Files paths. Custom drives may require Windows Graphics Settings.' }
    }

    function Test-AdobePerformanceReadiness {
        Log '===================================================='
        Log '[Adobe Audit] Checking resource headroom without changing settings...'
        $apps = @(Get-AdobeExecutablePaths)
        if ($apps.Count -gt 0) { foreach ($app in $apps) { Log "   App: $($app.Name) | $($app.Path)" } }
        else { Log '   No Adobe install found in the default locations.' }
        try {
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            $total = [Math]::Round(($os.TotalVisibleMemorySize / 1MB),1)
            $free = [Math]::Round(($os.FreePhysicalMemory / 1MB),1)
            Log "   RAM: $free GB available of $total GB visible to Windows"
        } catch { Log '   RAM availability query failed.' }
        try {
            $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'" -ErrorAction Stop | Select-Object -First 1
            if ($disk) { Log "   System drive free: $([Math]::Round($disk.FreeSpace / 1GB,1)) GB of $([Math]::Round($disk.Size / 1GB,1)) GB" }
        } catch {}
        $cacheRoots = @("$env:APPDATA\Adobe\Common", "$env:LOCALAPPDATA\Adobe", "$env:LOCALAPPDATA\Temp")
        foreach ($root in $cacheRoots) {
            if (Test-Path -LiteralPath $root) {
                try {
                    $bytes = (Get-ChildItem -LiteralPath $root -File -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
                    if ($null -eq $bytes) { $bytes = 0 }
                    Log "   Cache candidate: $root | about $([Math]::Round($bytes / 1GB,2)) GB (includes non-Adobe temp data for Local Temp; informational only)"
                } catch { Log "   Could not size $root" }
            }
        }
        foreach ($procName in @('Adobe Premiere Pro','AfterFX','Photoshop','Lightroom')) {
            $running = @(Get-Process -Name $procName -ErrorAction SilentlyContinue)
            if ($running.Count -gt 0) { Log "   Running: $procName ($($running.Count))" }
        }
        Log '   Guidance: keep cache/scratch disks on a fast drive with free space; use app Performance/Memory preferences to configure GPU acceleration. Audit made no changes.'
    }

    function Clear-AdobeCache {
        $choice = [System.Windows.Forms.MessageBox]::Show('Clear Adobe media-cache/preview contents in common cache folders? Adobe may need to rebuild previews and shaders. Save projects and close Adobe apps first.', 'Confirm Adobe cache cleanup', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::None)
        if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { Log '[Adobe] Cache cleanup cancelled.'; return }
        Log '[Adobe] Clearing only the known cache folders selected by this routine...'
        Safe-Run {
            $cachePaths = @(
                "$env:APPDATA\Adobe\Common\Media Cache Files",
                "$env:APPDATA\Adobe\Common\Media Cache",
                "$env:LOCALAPPDATA\Adobe\Premiere Pro\*\Adobe Premiere Pro Video Previews",
                "$env:LOCALAPPDATA\Adobe\Photoshop\*\Cache"
            )
            $cleared = 0
            foreach ($cp in $cachePaths) {
                $items = Get-Item $cp -ErrorAction SilentlyContinue
                foreach ($it in $items) {
                    if (Test-Path -LiteralPath $it.FullName) {
                        Remove-Item (Join-Path $it.FullName '*') -Recurse -Force -ErrorAction SilentlyContinue
                        $cleared++
                        Log "   Cleared cache contents: $($it.FullName)"
                    }
                }
            }
            if ($cleared -eq 0) { Log '   No common Adobe cache folders found.' }
        } 'AdobeCacheClear'
        Log 'Done. Close Adobe apps before running this for best results.'
    }

    function Apply-AdobePerfTweaks {
        $apps = @(Get-AdobeExecutablePaths)
        if ($apps.Count -eq 0) {
            Log '[Adobe] No Adobe executables detected in common install paths. Opening per-app Windows Graphics settings instead.'
            try { Start-Process 'ms-settings:display-graphics' } catch {}
            Log 'Add each Adobe executable manually in Windows Graphics settings, then choose Options > High performance only if a discrete GPU is available.'
            return
        }
        $choice = [System.Windows.Forms.MessageBox]::Show("Set Windows per-app GPU preference to High performance for the detected Adobe executables? This is a user-level preference, may be ignored on single-GPU PCs, and does not change Adobe project settings.", 'Confirm Adobe GPU routing', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::None)
        if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { Log '[Adobe] GPU preference changes cancelled.'; return }
        $prefPath = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
        $specs = @()
        foreach ($app in $apps) { $specs += @{ Path = $prefPath; Name = $app.Path } }
        $backup = Get-RegistryBackupFile 'adobe-gpu-preferences-backup.json'
        Save-RegistrySnapshot $specs $backup
        New-Item -Path $prefPath -Force | Out-Null
        foreach ($app in $apps) {
            try {
                New-ItemProperty -LiteralPath $prefPath -Name $app.Path -Value 'GpuPreference=2;' -PropertyType String -Force -ErrorAction Stop | Out-Null
                Log "   Windows High performance GPU preference saved for: $($app.Name)"
            } catch { Log "   Could not set GPU preference for $($app.Name): $($_.Exception.Message)" }
        }
        Log '   For Photoshop/Premiere/After Effects, also verify GPU acceleration inside the app itself. On integrated-only systems, this preference cannot create a discrete GPU.'
        try { Start-Process 'ms-settings:display-graphics' } catch {}
    }

    function Restore-AdobeGpuPreferences {
        Restore-RegistrySnapshot (Get-RegistryBackupFile 'adobe-gpu-preferences-backup.json')
    }

    function Check-NvidiaPowerLimit {
        Log "===================================================="
        Safe-Run {
            $nvidiaSmi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
            if (-not $nvidiaSmi) { Log "nvidia-smi not found - this only works with NVIDIA GPUs + driver installed."; return }
            $result = & nvidia-smi --query-gpu=power.limit,power.min_limit,power.max_limit,power.default_limit --format=csv,noheader,nounits
            Log "Power limit info (Watts) - current, min, max, default:"
            Log "   $result"
            Log "The max value here is NVIDIA's own official safe ceiling for your specific card - not a risky overclock."
        } "NvidiaPowerCheck"
    }
    function Set-NvidiaPowerLimitMax {
        Log "===================================================="
        try {
            $sys = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
            if ($sys.PCSystemType -eq 2) {
                Log 'Blocked: this is identified as a laptop/mobile system. This script will not automatically raise the GPU power limit on a laptop.'
                [System.Windows.Forms.MessageBox]::Show('Automatic maximum power-limit changes are disabled on laptops because cooling and OEM power limits vary. Use the laptop/GPU vendor utility for supported controls.', 'Laptop safety check', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::None) | Out-Null
                return
            }
            $nvidiaSmi = Get-Command 'nvidia-smi.exe' -ErrorAction SilentlyContinue
            if (-not $nvidiaSmi) { Log 'nvidia-smi not found - NVIDIA driver/telemetry interface unavailable.'; return }
            $telemetry = (& $nvidiaSmi.Source --query-gpu=name,temperature.gpu,power.limit,power.max_limit --format=csv,noheader,nounits 2>$null | Select-Object -First 1)
            if (-not $telemetry) { Log 'Could not read NVIDIA power/temperature telemetry; refusing to change power limit.'; return }
            $parts = @($telemetry -split ',\s*')
            if ($parts.Count -lt 4) { Log "Unrecognized nvidia-smi response: $telemetry"; return }
            $gpuName = $parts[0]; $temp = 0.0; $current = 0.0; $maxLimit = 0.0
            $tempOk = [double]::TryParse($parts[1], [ref]$temp)
            $currentOk = [double]::TryParse($parts[2], [ref]$current)
            $maxOk = [double]::TryParse($parts[3], [ref]$maxLimit)
            Log "GPU: $gpuName | temperature: $($parts[1]) C | current power limit: $($parts[2]) W | driver-reported max: $($parts[3]) W"
            if (-not ($tempOk -and $currentOk -and $maxOk)) { Log 'Telemetry values could not be parsed. No change made.'; return }
            if ($temp -ge 75) { Log 'Blocked: GPU temperature is 75 C or higher. Cool the system and use the vendor control panel; no change made.'; return }
            $choice = [System.Windows.Forms.MessageBox]::Show("GPU: $gpuName`nCurrent temperature: $temp C`nCurrent power limit: $current W`nDriver-reported ceiling: $maxLimit W`n`nRaising the power limit can increase heat, fan noise and throttling. Continue only if this desktop has adequate cooling?", 'Confirm GPU power-limit change', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::None)
            if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { Log 'Cancelled by user; no change made.'; return }
            & $nvidiaSmi.Source -pl $maxLimit | Out-Null
            if ($LASTEXITCODE -eq 0) { Log "Power limit changed to driver-reported maximum $maxLimit W. This is not a GPU clock/voltage overclock and may reset on reboot." }
            else { Log 'NVIDIA rejected the power-limit request; no success is claimed.' }
        } catch { Log "Power-limit preflight failed; no change was confirmed: $($_.Exception.Message)" }
    }
    function Enable-SafeCpuBoost {
        Log "===================================================="
        $choice = [System.Windows.Forms.MessageBox]::Show("This changes the active Windows power plan's processor boost policy to Aggressive for AC power. It is not a manual overclock, and may increase heat, fan noise and battery/power use. Continue?", 'Confirm CPU Boost Policy', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::None)
        if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { Log 'CPU boost-policy change cancelled; no settings changed.'; return }
        try {
            $sys = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
            if ($sys.PCSystemType -eq 2) {
                $battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($battery -and $battery.BatteryStatus -eq 1) {
                    Log 'Blocked while laptop battery is discharging. Plug in AC power before enabling an aggressive boost policy.'
                    return
                }
            }
            $active = (powercfg /getactivescheme | Out-String)
            if ($active -notmatch '([a-fA-F0-9]{8}-(?:[a-fA-F0-9]{4}-){3}[a-fA-F0-9]{12})') { Log 'Could not identify the active power plan. No setting changed.'; return }
            $guid = $Matches[1]
            $query = (powercfg /query $guid SUB_PROCESSOR PERFBOOSTMODE 2>&1 | Out-String)
            if ($query -match 'Invalid Parameters|Unable to perform operation|not supported') { Log 'This Windows build/firmware does not expose PERFBOOSTMODE. No setting changed.'; return }
            powercfg /setacvalueindex $guid SUB_PROCESSOR PERFBOOSTMODE 2 | Out-Null
            if ($LASTEXITCODE -ne 0) { Log 'Windows rejected the boost policy. No successful change is claimed.'; return }
            powercfg /setactive $guid | Out-Null
            Log 'Windows processor boost policy set to Aggressive for AC power. This does not unlock manual CPU overclocking.'
            Log 'If temperatures/noise become excessive, use Restore Defaults or set the previous boost policy in Advanced Power Options.'
        } catch { Log "CPU boost policy could not be changed: $($_.Exception.Message)" }
    }
    function Apply-SafeGpuVendorTweaks {
        Log "===================================================="
        Safe-Run {
            $gpus = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch "Basic|Remote" }
            foreach ($gpu in $gpus) {
                Log "GPU: $($gpu.Name)"
                if ($gpu.Name -match "AMD|Radeon") {
                    Log "AMD GPU detected. Windows doesn't expose a safe scriptable power-limit API for AMD like it does for NVIDIA."
                    Log "Safest real option: open Radeon Software > Performance > Tuning > 'Automatic Tuning' (AMD's own safe auto-OC, reversible)."
                    Start-Process "https://www.amd.com/en/support"
                } elseif ($gpu.Name -match "Intel") {
                    Log "Intel GPU detected. Use Intel Graphics Command Center > Performance tab for safe tuning within Intel's own limits."
                    Start-Process "https://www.intel.com/content/www/us/en/download-center/home.html"
                } elseif ($gpu.Name -match "NVIDIA") {
                    Log "NVIDIA GPU - use the Power Limit buttons above, or NVIDIA Control Panel for more options."
                }
            }
        } "GpuVendorTweaks"
    }
    function Show-ClockSpeeds {
        Log "===================================================="
        Log "[Overclocking] Reading current clock speeds (read-only, nothing is changed)..."
        Safe-Run {
            $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
            Log "CPU: $($cpu.Name)"
            Log "   Rated max clock: $($cpu.MaxClockSpeed) MHz"
            Log "   Current clock:   $($cpu.CurrentClockSpeed) MHz"
            if ($cpu.CurrentClockSpeed -lt ($cpu.MaxClockSpeed * 0.7)) {
                Log "   NOTE: Current clock is well below rated max - likely power-saving throttling, not a fault."
                Log "   Check your power plan (Miscellaneous tab) if you want max performance."
            }
        } "CPU Clock"
        Safe-Run {
            $gpus = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch "Basic|Remote" }
            foreach ($gpu in $gpus) {
                Log "GPU: $($gpu.Name)"
                if ($gpu.CurrentRefreshRate) { Log "   Current refresh rate: $($gpu.CurrentRefreshRate) Hz" }
                Log "   For real GPU clock/voltage curves, use MSI Afterburner or your vendor's tool - Windows doesn't expose safe write access to this from a script."
            }
        } "GPU Info"
    }
    function Show-FirmwareInfo {
        Safe-Run {
            $bios = Get-CimInstance Win32_BIOS
            $board = Get-CimInstance Win32_BaseBoard
            $sys = Get-CimInstance Win32_ComputerSystem
            Log "===================================================="
            Log "Motherboard: $($board.Manufacturer) $($board.Product)"
            Log "System: $($sys.Manufacturer) $($sys.Model)"
            Log "BIOS/Firmware version: $($bios.SMBIOSBIOSVersion)"
            Log "BIOS release date: $($bios.ReleaseDate)"
            Log ""
            Log "Recommendation: search '$($board.Manufacturer) $($board.Product) BIOS update' on the manufacturer's"
            Log "support site and compare against '$($bios.SMBIOSBIOSVersion)' above. Only update if you see a newer"
            Log "version listed there - don't update BIOS unless there's a real reason (stability/security fix)."
            Log "No browser opened automatically. Use the PC manufacturer's official support page for BIOS firmware; never flash a BIOS solely for FPS."
        } "BIOSInfo"
    }
    function Get-BiosGamingAudit {
        $lines = New-Object System.Collections.Generic.List[string]
        $h = Get-LocalHardwareProfile
        $lines.Add('BIOS / UEFI GAMING-READINESS AUDIT (read-only)')
        $lines.Add("System: $($h.Computer)")
        $lines.Add("Motherboard: $($h.Motherboard)")
        $lines.Add("BIOS: $($h.Bios)")
        try {
            $fw = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name PEFirmwareType -ErrorAction Stop
            if ($fw.PEFirmwareType -eq 2) { $lines.Add('Boot mode: UEFI') }
            elseif ($fw.PEFirmwareType -eq 1) { $lines.Add('Boot mode: Legacy BIOS/CSM') }
            else { $lines.Add("Boot mode: unrecognized value $($fw.PEFirmwareType)") }
        } catch { $lines.Add('Boot mode: not readable from this Windows build.') }
        try {
            $sb = Confirm-SecureBootUEFI -ErrorAction Stop
            $lines.Add("Secure Boot: $sb")
            if (-not $sb) { $lines.Add('Suggestion: check the exact PC vendor manual; Secure Boot may require UEFI mode and a compatible disk configuration. Do not toggle blindly.') }
        } catch { $lines.Add('Secure Boot: not exposed (legacy boot, unsupported firmware, or firmware query unavailable).') }
        try {
            $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
            $lines.Add("Virtualization firmware enabled: $($cpu.VirtualizationFirmwareEnabled)")
            $lines.Add("Second-level address translation: $($cpu.SecondLevelAddressTranslationExtensions)")
            if ($cpu.VirtualizationFirmwareEnabled -eq $false) { $lines.Add('Suggestion: enable Intel VT-x / AMD SVM in UEFI only if you need virtualization, WSL2, or emulator features.') }
        } catch { $lines.Add('CPU virtualization status: not detected.') }
        try {
            $modules = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop)
            if ($modules.Count -gt 0) {
                $speeds = @($modules | ForEach-Object { if ($_.ConfiguredClockSpeed) { [string]$_.ConfiguredClockSpeed } elseif ($_.Speed) { [string]$_.Speed } } | Where-Object { $_ } | Sort-Object -Unique)
                $lines.Add("Memory modules: $($modules.Count); reported speed(s): $(if($speeds.Count){$speeds -join ', '}else{'not exposed'}) MHz")
                $lines.Add('XMP/EXPO status: not universally exposed by Windows. Only enable a memory profile if the motherboard, RAM and vendor guidance explicitly support it.')
            }
        } catch { $lines.Add('Memory speed: not detected.') }
        try { $lines.Add("Current power scheme: $((powercfg /getactivescheme 2>&1 | Out-String).Trim())") } catch {}
        $lines.Add('No BIOS/UEFI values were changed. Voltage, XMP/EXPO, Secure Boot and CPU boost settings must be verified in firmware for the exact PC model.')
        return ($lines -join "`r`n")
    }

    function Get-RegistryBackupFile($name) {
        $dir = Join-Path $env:LOCALAPPDATA 'LookAtTheLatency\Backups'
        if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
        return (Join-Path $dir $name)
    }

    function Save-RegistrySnapshot($specs, $file) {
        $snapshot = @()
        if (Test-Path -LiteralPath $file) {
            try { $snapshot = @(Get-Content -LiteralPath $file -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop) } catch { $snapshot = @() }
        }
        foreach ($spec in $specs) {
            $already = @($snapshot | Where-Object { ([string]$_.Path -eq [string]$spec.Path) -and ([string]$_.Name -eq [string]$spec.Name) }).Count -gt 0
            if ($already) { continue }
            $exists = $false; $value = $null; $kind = 'String'
            try {
                $key = Get-Item -LiteralPath $spec.Path -ErrorAction SilentlyContinue
                if ($key -and ($key.GetValueNames() -contains [string]$spec.Name)) {
                    $exists = $true
                    $value = $key.GetValue([string]$spec.Name)
                    $kind = $key.GetValueKind([string]$spec.Name).ToString()
                }
            } catch {}
            $snapshot += [pscustomobject]@{ Path = [string]$spec.Path; Name = [string]$spec.Name; Exists = $exists; Value = $value; Kind = $kind }
        }
        $snapshot | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $file -Encoding UTF8
        Log "   Backup baseline preserved/updated: $file"
    }

    function Restore-RegistrySnapshot($file) {
        if (-not (Test-Path $file)) { Log "   No snapshot exists at $file"; return }
        try {
            $entries = @(Get-Content -LiteralPath $file -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
            foreach ($entry in $entries) {
                try {
                    if ($entry.Exists) {
                        if (-not (Test-Path -LiteralPath $entry.Path)) { New-Item -Path $entry.Path -Force | Out-Null }
                        $kind = [string]$entry.Kind
                        if ($kind -notin @('String','ExpandString','Binary','DWord','MultiString','QWord')) { $kind = 'String' }
                        New-ItemProperty -LiteralPath $entry.Path -Name ([string]$entry.Name) -Value $entry.Value -PropertyType $kind -Force -ErrorAction Stop | Out-Null
                    } else {
                        Remove-ItemProperty -LiteralPath $entry.Path -Name ([string]$entry.Name) -ErrorAction SilentlyContinue
                    }
                } catch { Log "   Could not restore $($entry.Name): $($_.Exception.Message)" }
            }
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
            Log '   Saved settings restored; backup consumed.'
        } catch { Log "   Restore failed: $($_.Exception.Message)" }
    }

    function Get-GameModeRegistrySpecs {
        return @(
            @{ Path = 'HKCU:\Software\Microsoft\GameBar'; Name = 'AllowAutoGameMode' },
            @{ Path = 'HKCU:\Software\Microsoft\GameBar'; Name = 'AutoGameModeEnabled' },
            @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'EnableTransparency' },
            @{ Path = 'HKCU:\Control Panel\Desktop\WindowMetrics'; Name = 'MinAnimate' },
            @{ Path = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_Enabled' },
            @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'AppCaptureEnabled' }
        )
    }

    function Enable-WindowsGameModeCore {
        $backup = Get-RegistryBackupFile 'gaming-mode-backup.json'
        Save-RegistrySnapshot (Get-GameModeRegistrySpecs) $backup
        Set-VerifiedRegValue 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1 'DWord' 'Windows Game Mode allowed'
        Set-VerifiedRegValue 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1 'DWord' 'Windows Game Mode enabled'
        Log 'LOOK GAMING MODE: applied user-level Windows Game Mode flags. Optional power/visual settings are separate and backed up; no BIOS, voltage, security, Update service or network driver changes were made.'
        Log 'Note: Windows builds can manage Game Mode internally; verify Settings > Gaming > Game Mode if the UI does not reflect this change.'
    }

    function Invoke-LookGamingModeCore([object[]]$TargetGames) {
        Enable-WindowsGameModeCore
        if ($chkGamingVisuals -and $chkGamingVisuals.Checked) {
            $visualPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
            $animPath = 'HKCU:\Control Panel\Desktop\WindowMetrics'
            Set-VerifiedRegValue $visualPath 'EnableTransparency' 0 'DWord' 'Windows transparency reduced (optional UI rendering QoL)'
            Set-VerifiedRegValue $animPath 'MinAnimate' '0' 'String' 'Window minimize/maximize animation reduced (optional)'
        } else { Log '   Left Windows transparency/animation preferences unchanged (option not selected).' }
        if ($chkGamingDvr -and $chkGamingDvr.Checked) {
            Set-VerifiedRegValue 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0 'DWord' 'Xbox Game DVR background capture disabled (optional)'
            Set-VerifiedRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0 'DWord' 'App capture disabled (optional)'
            Log '   Game recording/capture features may change; use Windows Settings to re-enable if needed.'
        } else { Log '   Xbox Game DVR background capture unchanged (option not selected).' }
        if ($chkGamingPowerPlan -and $chkGamingPowerPlan.Checked) { Set-LookPerformancePowerPlan -Silent }
        else { Log '   Left Windows power plan unchanged (optional power plan checkbox is off).' }

        $paths = @()
        if ($TargetGames -and $TargetGames.Count -gt 0) {
            $paths = @($TargetGames | Where-Object { $_.Exe -and (Test-Path -LiteralPath $_.Exe) } | ForEach-Object { $_.Exe })
        } elseif ($script:gameCatalog -and $script:gameCatalog.Count -gt 0) {
            $paths = @($script:gameCatalog | Where-Object { $_.Exe -and (Test-Path -LiteralPath $_.Exe) } | ForEach-Object { $_.Exe })
        }
        if ($paths.Count -eq 0) {
            $names = @('javaw','java','cs2','cs2_win64','UnrealEditor','UE4Editor','VALORANT-Win64-Shipping','FortniteClient-Win64-Shipping','RobloxPlayerBeta')
            foreach ($name in $names) {
                foreach ($proc in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
                    try { if ($proc.Path -and (Test-Path -LiteralPath $proc.Path)) { $paths += $proc.Path } } catch {}
                }
            }
        }
        $paths = @($paths | Sort-Object -Unique)
        foreach ($exe in $paths) {
            foreach ($proc in @(Get-Process -ErrorAction SilentlyContinue)) {
                try {
                    if ($proc.Path -and $proc.Path.Equals($exe,[System.StringComparison]::OrdinalIgnoreCase)) {
                        if ($proc.PriorityClass -ne [System.Diagnostics.ProcessPriorityClass]::AboveNormal) {
                            $alreadyTracked = @($script:raisedGamePrioritySnapshots | Where-Object { $_.Id -eq $proc.Id }).Count -gt 0
                            if (-not $alreadyTracked) { $script:raisedGamePrioritySnapshots += [pscustomobject]@{ Id=$proc.Id; Name=$proc.ProcessName; Original=[string]$proc.PriorityClass } }
                            $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::AboveNormal
                            Log "   Temporary AboveNormal priority set for active game PID $($proc.Id). Original priority saved for Restore."
                        }
                    }
                } catch {}
            }
        }
        $h = Get-LocalHardwareProfile
        $hasMultipleGpus = @($h.GpuObjects).Count -gt 1
        if ($paths.Count -gt 0 -and $hasMultipleGpus) {
            $prefPath = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
            $specs = @(); foreach ($exe in $paths) { $specs += @{ Path = $prefPath; Name = $exe } }
            $gpuBackup = Get-RegistryBackupFile 'gaming-gpu-preferences-backup.json'
            Save-RegistrySnapshot $specs $gpuBackup
            New-Item -Path $prefPath -Force | Out-Null
            foreach ($exe in $paths) {
                try { New-ItemProperty -LiteralPath $prefPath -Name $exe -Value 'GpuPreference=2;' -PropertyType String -Force -ErrorAction Stop | Out-Null; Log "   Windows High performance GPU preference saved for: $exe" }
                catch { Log "   Could not set GPU preference for $exe : $($_.Exception.Message)" }
            }
        } elseif ($paths.Count -gt 0) {
            Log '   Games were detected, but only one GPU adapter is reported. Windows GPU preference cannot create a discrete GPU; no per-app GPU values were written.'
        } else { Log '   No game executable was detected. Use the game library scan or run this profile while a game is open.' }
        try { Start-Process 'ms-settings:gaming-gamemode' } catch {}
        Log 'LOOK GAMING MODE complete: Game Mode + selected optional QoL settings + compatible per-app GPU routing. Nothing changed in BIOS or voltage.'
    }

    function Apply-LookGamingMode {
        $powerText = if ($chkGamingPowerPlan -and $chkGamingPowerPlan.Checked) { 'High Performance power plan WILL be enabled (may increase heat and battery drain).' } else { 'Power plan stays unchanged.' }
        $visualText = if ($chkGamingVisuals -and $chkGamingVisuals.Checked) { 'Windows transparency and minimize/maximize animation will be reduced; a backup is made.' } else { 'Visual effects stay unchanged.' }
        $dvrText = if ($chkGamingDvr -and $chkGamingDvr.Checked) { 'Xbox background capture will be disabled (Game DVR recording behavior may change).' } else { 'Xbox background capture stays unchanged.' }
        $choice = [System.Windows.Forms.MessageBox]::Show("Apply the full reversible LOOK GAMING MODE profile?`n`n- Enable Windows Game Mode`n- Set per-app high-performance GPU preference for detected games only if multiple GPU adapters are present`n- $powerText`n- $visualText`n- $dvrText`n`nNo BIOS, voltage, network, Defender or Windows Update settings are changed.", 'LOOK GAMING MODE', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::None)
        if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { Log 'LOOK GAMING MODE cancelled; no change made.'; return }
        Invoke-LookGamingModeCore
    }

    function Restore-LookGamingMode {
        Restore-RegistrySnapshot (Get-RegistryBackupFile 'gaming-mode-backup.json')
        Restore-RegistrySnapshot (Get-RegistryBackupFile 'gaming-gpu-preferences-backup.json')
        Restore-LookPerformancePowerPlan -Silent
        foreach ($snap in @($script:raisedGamePrioritySnapshots)) {
            try {
                $proc = Get-Process -Id ([int]$snap.Id) -ErrorAction Stop
                $original = [System.Enum]::Parse([System.Diagnostics.ProcessPriorityClass], [string]$snap.Original)
                $proc.PriorityClass = $original
                Log "   Restored $($snap.Name) PID $($snap.Id) priority to $original."
            } catch { }
        }
        $script:raisedGamePrioritySnapshots = @()
        Log 'LOOK GAMING MODE restore completed where backups existed. Restart or sign out only if Windows does not immediately reflect a user-interface setting.'
    }

    function Open-OemPerformanceUtility {
        Log '[BIOS/OEM] Looking for installed manufacturer control apps...'
        $matches = @()
        try {
            $matches = @(Get-StartApps -ErrorAction Stop | Where-Object { $_.Name -match '(?i)MyASUS|Armoury Crate|Lenovo Vantage|Dell Power Manager|Alienware Command Center|OMEN Gaming Hub|HP Command Center|MSI Center|NitroSense|PredatorSense|Gigabyte Control Center|Control Center' } | Sort-Object Name)
        } catch { Log '   Windows Start-app inventory is unavailable on this build.' }
        if ($matches.Count -eq 0) {
            Log '   No common OEM performance utility was detected. BIOS controls are vendor-specific; use Restart Into UEFI and the exact manufacturer manual.'
            return
        }
        $labels = @($matches | ForEach-Object { "{0}  [{1}]" -f $_.Name, $_.AppID })
        Log ('   Found: ' + ($labels -join '; '))
        $app = $matches[0]
        $choice = [System.Windows.Forms.MessageBox]::Show("Open the detected OEM utility?`n`n$($app.Name)`n`nThe tool may expose manufacturer-supported fan/power profiles, but this optimizer will not write BIOS values by itself.", 'Open OEM Performance Utility', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::None)
        if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { Log '   OEM utility launch cancelled.'; return }
        try {
            Start-Process -FilePath "$env:WINDIR\explorer.exe" -ArgumentList "shell:AppsFolder\$($app.AppID)"
            Log "   Launched $($app.Name). Verify the utility matches this PC model before applying changes."
        } catch { Log "   Could not launch $($app.Name): $($_.Exception.Message)" }
    }

    function Restart-ToUefi {
        $r = [System.Windows.Forms.MessageBox]::Show("This restarts your PC directly into UEFI/BIOS setup. Continue?", "Confirm", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::None)
        if ($r -eq [System.Windows.Forms.DialogResult]::Yes) { shutdown.exe /r /fw /t 3; Log "Restarting into UEFI setup..." }
    }
    function Get-LocalHardwareProfile {
        $cpu = $null; $cs = $null; $os = $null; $bios = $null; $board = $null; $gpus = @(); $disk = $null
        try { $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1 } catch {}
        try { $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop } catch {}
        try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch {}
        try { $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop } catch {}
        try { $board = Get-CimInstance Win32_BaseBoard -ErrorAction Stop } catch {}
        try { $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction Stop | Where-Object { $_.Name -and $_.Name -notmatch 'Microsoft Basic|Remote Display' }) } catch {}
        try { $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'" -ErrorAction Stop | Select-Object -First 1 } catch {}
        $ramGB = 0
        if ($cs -and $cs.TotalPhysicalMemory) { $ramGB = [Math]::Round(($cs.TotalPhysicalMemory / 1GB),1) }
        $freeGB = $null
        if ($disk -and $disk.FreeSpace) { $freeGB = [Math]::Round(($disk.FreeSpace / 1GB),1) }
        $gpuNames = @($gpus | ForEach-Object { $_.Name } | Where-Object { $_ })
        return [pscustomobject]@{
            Cpu = $(if ($cpu) { [string]$cpu.Name } else { 'Not detected' })
            Cores = $(if ($cpu) { $cpu.NumberOfCores } else { 'Unknown' })
            LogicalProcessors = $(if ($cpu) { $cpu.NumberOfLogicalProcessors } else { 'Unknown' })
            RamGB = $ramGB
            Gpus = $(if ($gpuNames.Count -gt 0) { $gpuNames -join '; ' } else { 'Not detected' })
            GpuObjects = $gpus
            Os = $(if ($os) { "$($os.Caption) (build $($os.BuildNumber))" } else { 'Not detected' })
            Computer = $(if ($cs) { "$($cs.Manufacturer) $($cs.Model)" } else { 'Not detected' })
            Bios = $(if ($bios) { "$($bios.SMBIOSBIOSVersion) ($($bios.ReleaseDate))" } else { 'Not detected' })
            Motherboard = $(if ($board) { "$($board.Manufacturer) $($board.Product)" } else { 'Not detected' })
            SystemDriveFreeGB = $freeGB
            PCSystemType = $(if ($cs) { $cs.PCSystemType } else { 0 })
        }
    }

    function Format-LocalHardwareReport {
        $h = Get-LocalHardwareProfile
        $freeSpaceText = 'Not detected'
        if ($null -ne $h.SystemDriveFreeGB) { $freeSpaceText = ([string]$h.SystemDriveFreeGB) + ' GB' }
        $text = @(
            "System: $($h.Computer)",
            "OS: $($h.Os)",
            "CPU: $($h.Cpu)",
            "CPU cores/logical processors: $($h.Cores) / $($h.LogicalProcessors)",
            "RAM: $($h.RamGB) GB",
            "GPU(s): $($h.Gpus)",
            "System drive free space: $freeSpaceText",
            "Motherboard: $($h.Motherboard)",
            "BIOS: $($h.Bios)"
        )
        return ($text -join "`r`n")
    }

    function Get-OverclockCompatibilityReport {
        $h = Get-LocalHardwareProfile
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add('HARDWARE / OVERCLOCK SUPPORT SCAN (READ-ONLY)')
        $lines.Add("System: $($h.Computer)")
        $lines.Add("CPU: $($h.Cpu)")
        $lines.Add("GPU: $($h.Gpus)")
        $lines.Add("Motherboard: $($h.Motherboard)")
        $lines.Add("BIOS: $($h.Bios)")
        if ($h.PCSystemType -eq 2) { $lines.Add('System type: mobile/laptop - thermal and firmware limits often restrict manual overclocking.') }
        else { $lines.Add('System type: not identified as a mobile system by Windows; firmware limits still need vendor confirmation.') }

        $nvidiaSmi = Get-Command 'nvidia-smi.exe' -ErrorAction SilentlyContinue
        $ryzenMasterPaths = @("$env:ProgramFiles\AMD\RyzenMaster\bin\AMD Ryzen Master.exe", "$env:ProgramFiles\AMD\RyzenMaster\AMD Ryzen Master.exe")
        $xtuPaths = @("$env:ProgramFiles\Intel\Intel(R) Extreme Tuning Utility\Client\XTU.exe", "${env:ProgramFiles(x86)}\Intel\Intel(R) Extreme Tuning Utility\Client\XTU.exe")
        $afterburnerPaths = @("${env:ProgramFiles(x86)}\MSI Afterburner\MSIAfterburner.exe", "$env:ProgramFiles\MSI Afterburner\MSIAfterburner.exe")
        $vendorTools = @()
        if ($nvidiaSmi) { $vendorTools += 'NVIDIA nvidia-smi found (telemetry/power query only; this does not prove clock overclock is allowed).' }
        if ($ryzenMasterPaths | Where-Object { Test-Path $_ }) { $vendorTools += 'AMD Ryzen Master installation detected.' }
        if ($xtuPaths | Where-Object { Test-Path $_ }) { $vendorTools += 'Intel XTU installation detected.' }
        if ($afterburnerPaths | Where-Object { Test-Path $_ }) { $vendorTools += 'MSI Afterburner installation detected.' }
        if ($vendorTools.Count -gt 0) { foreach ($tool in $vendorTools) { $lines.Add("Tool: $tool") } }
        else { $lines.Add('Vendor tuning interface: no common vendor utility was found in its default install path.') }

        if ($h.Cpu -match '(?i)\b(KF?|KS|HK|HX)\b') {
            $lines.Add('CPU naming suggests a potentially tunable SKU, but the BIOS/OEM can still lock tuning. Not confirmed.')
        } elseif ($h.Cpu -match '(?i)AMD Ryzen') {
            $lines.Add('AMD Ryzen detected. Manual/PBO control depends on the exact CPU, motherboard, firmware and OEM policy; not confirmed by model family alone.')
        } else {
            $lines.Add('CPU overclock permission: not confirmed. Windows WMI does not expose a universal, trustworthy overclock-support flag.')
        }
        if ($h.Gpus -match '(?i)Intel UHD|Intel Graphics|Iris Xe' -and $h.Gpus -notmatch '(?i)Arc') {
            $lines.Add('GPU tuning: integrated Intel graphics detected; generic PowerShell cannot safely set a supported GPU voltage/clock offset.')
        }
        $lines.Add('RESULT: This scan did not change voltage, clock speed, power limits, BIOS, or registry settings.')
        $lines.Add('NEXT: If a manufacturer tool is detected, use that tool and only its explicitly supported controls. No automatic voltage tuning is performed.')
        return ($lines -join "`r`n")
    }

    function Start-SupportedTuningWorkflow {
        $h = Get-LocalHardwareProfile
        $txtOcSupport.Text = Get-OverclockCompatibilityReport
        if ($h.PCSystemType -eq 2) {
            $choice = [System.Windows.Forms.MessageBox]::Show("Laptop/mobile system detected. Generic automatic voltage or clock changes are disabled. The wizard can open a detected manufacturer tuning utility, but it will not invent values. Continue to locate a supported utility?", 'Guided tuning preflight', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::None)
            if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { Log 'Guided tuning cancelled; no settings changed.'; return }
        }
        $nvidiaSmi = Get-Command 'nvidia-smi.exe' -ErrorAction SilentlyContinue
        if ($h.PCSystemType -ne 2 -and $nvidiaSmi -and $h.Gpus -match '(?i)NVIDIA') {
            Log 'Guided wizard found NVIDIA telemetry on a non-mobile system. Calling the separate preflight/confirmation flow; this adjusts only the driver power limit, not clock/voltage.'
            Set-NvidiaPowerLimitMax
            return
        }
        $tool = $null
        $toolPaths = @()
        if ($h.Cpu -match '(?i)Intel') { $toolPaths += @("$env:ProgramFiles\Intel\Intel(R) Extreme Tuning Utility\Client\XTU.exe", "${env:ProgramFiles(x86)}\Intel\Intel(R) Extreme Tuning Utility\Client\XTU.exe") }
        if ($h.Cpu -match '(?i)AMD Ryzen') { $toolPaths += @("$env:ProgramFiles\AMD\RyzenMaster\bin\AMD Ryzen Master.exe", "$env:ProgramFiles\AMD\RyzenMaster\AMD Ryzen Master.exe") }
        $toolPaths += @("${env:ProgramFiles(x86)}\MSI Afterburner\MSIAfterburner.exe", "$env:ProgramFiles\MSI Afterburner\MSIAfterburner.exe", "$env:ProgramFiles\AMD\CNext\CNext\RadeonSoftware.exe")
        foreach ($path in $toolPaths) { if (Test-Path $path) { $tool = $path; break } }
        if ($tool) {
            $launch = [System.Windows.Forms.MessageBox]::Show("Detected vendor tuning utility:`n$tool`n`nOpen it now? This app will not set clock/voltage values itself.", 'Open vendor tuning utility', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::None)
            if ($launch -eq [System.Windows.Forms.DialogResult]::Yes) { Start-Process -FilePath $tool; Log "Opened vendor tuning utility: $tool" }
            else { Log 'Vendor utility launch cancelled; no settings changed.' }
        } else {
            $txtOcSupport.Text += "`r`n`r`nNO SCRIPTABLE TUNING TOOL CONFIRMED. No clock, voltage or BIOS setting was changed. Use only a tuning option listed by your PC/GPU manufacturer."
            [System.Windows.Forms.MessageBox]::Show('No compatible vendor tuning tool was found in the common install paths. No overclock was applied. See the scan report for details.', 'No supported tuning interface detected', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::None) | Out-Null
            Log 'Guided tuning: no compatible utility found. No settings changed.'
        }
    }

    function Write-ReportToLog($heading, $report) {
        Log '===================================================='
        Log $heading
        foreach ($line in ([string]$report -split "\r?\n")) {
            if (-not [string]::IsNullOrWhiteSpace($line)) { Log "   $line" }
        }
    }

    function Get-UnrealEditorPaths {
        $found = New-Object System.Collections.Generic.List[string]
        $roots = @("$env:ProgramFiles\Epic Games", "${env:ProgramFiles(x86)}\Epic Games") | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
        foreach ($root in $roots) {
            try {
                foreach ($version in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^UE_[45]' })) {
                    foreach ($relative in @('Engine\Binaries\Win64\UnrealEditor.exe','Engine\Binaries\Win64\UE4Editor.exe')) {
                        $exe = Join-Path $version.FullName $relative
                        if (Test-Path -LiteralPath $exe) { $found.Add($exe) }
                    }
                }
            } catch {}
        }
        return @($found | Sort-Object -Unique)
    }

    function Apply-EngineWindowsOptimizations {
        $editors = @(Get-UnrealEditorPaths)
        $message = "Apply Windows Game Mode and per-app GPU preference for detected Unreal Editor executables?`n`nFound Unreal editor executables: $($editors.Count)`nThis does not modify engine project files, force DirectX/Vulkan, or improve ping by itself."
        $choice = [System.Windows.Forms.MessageBox]::Show($message, 'Confirm Windows Engine Profile', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::None)
        if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { Log '[Game Engines] Windows engine profile cancelled.'; return }
        Enable-WindowsGameModeCore
        if ($editors.Count -gt 0) {
            $prefPath = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
            $specs = @()
            foreach ($exe in $editors) { $specs += @{ Path = $prefPath; Name = $exe } }
            $backup = Get-RegistryBackupFile 'engine-gpu-preferences-backup.json'
            Save-RegistrySnapshot $specs $backup
            New-Item -Path $prefPath -Force | Out-Null
            foreach ($exe in $editors) {
                try { New-ItemProperty -LiteralPath $prefPath -Name $exe -Value 'GpuPreference=2;' -PropertyType String -Force -ErrorAction Stop | Out-Null; Log "[Game Engines] Windows High performance GPU preference set for $exe" }
                catch { Log "[Game Engines] Could not set GPU preference for $exe : $($_.Exception.Message)" }
            }
            Log 'If the system has only one integrated GPU, Windows cannot select a separate high-performance GPU. The preference can be ignored by some apps/drivers.'
        } else {
            Log '[Game Engines] No Unreal Editor executable found in common Epic Games install paths. No per-app GPU preference was added.'
        }
        Log 'DirectX/Vulkan are audited per driver/app. No global API switch or project file change was made.'
        try { Start-Process 'ms-settings:display-graphics' } catch {}
    }

    function Restore-EngineWindowsOptimizations {
        Restore-RegistrySnapshot (Get-RegistryBackupFile 'engine-gpu-preferences-backup.json')
        Log 'Game Mode settings are restored separately with Restore Previous Game Mode Settings in section 8.'
    }

    function Open-DetectedUnrealEditor {
        $editors = @(Get-UnrealEditorPaths)
        if ($editors.Count -eq 0) { Log '[Game Engines] Unreal Editor was not found in common Epic Games locations.'; return }
        $path = $editors[0]
        $choice = [System.Windows.Forms.MessageBox]::Show("Open detected Unreal Editor?`n$path", 'Launch Unreal Editor', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::None)
        if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) { Start-Process -FilePath $path; Log "Launched $path" }
    }

    function Get-EngineReport($target) {
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add("GAME ENGINE / GRAPHICS RUNTIME SCAN - $target")
        $h = Get-LocalHardwareProfile
        $lines.Add("GPU(s): $($h.Gpus)")
        foreach ($gpu in @($h.GpuObjects)) {
            if ($gpu.Name) { $lines.Add("Driver: $($gpu.Name) | version $($gpu.DriverVersion) | date $($gpu.DriverDate)") }
        }

        if ($target -eq 'All Supported' -or $target -eq 'Unreal Engine') {
            $ueFound = @()
            $ueRoots = @("$env:ProgramFiles\Epic Games", "${env:ProgramFiles(x86)}\Epic Games")
            foreach ($root in $ueRoots) {
                if (Test-Path $root) {
                    try { $ueFound += Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^UE_[45]' } | ForEach-Object { $_.FullName } } catch {}
                }
            }
            try {
                $launcher = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match '(?i)Epic Games Launcher' } | Select-Object -First 1
                if ($launcher) { $ueFound += "Epic Games Launcher detected ($($launcher.DisplayVersion)); engine install location may be custom." }
            } catch {}
            $ueFound = @($ueFound | Sort-Object -Unique)
            if ($ueFound.Count) { $lines.Add('Unreal Engine: found: ' + ($ueFound -join '; ')) }
            else { $lines.Add('Unreal Engine: no UE_4/UE_5 installation detected in common Epic Games locations. Custom paths may not be detected.') }
        }

        if ($target -eq 'All Supported' -or $target -eq 'DirectX') {
            $dxdiag = Join-Path $env:WINDIR 'System32\dxdiag.exe'
            if (Test-Path $dxdiag) {
                $lines.Add('DirectX diagnostics: dxdiag.exe is present.')
                $lines.Add('Exact DirectX feature-level support depends on GPU + driver. Use Open DirectX Diagnostics for the OS-reported details; no DirectX registry tweak is applied.')
            } else { $lines.Add('DirectX diagnostics: dxdiag.exe was not found at the standard Windows path.') }
        }

        if ($target -eq 'All Supported' -or $target -eq 'Vulkan') {
            $vkLoaderPaths = @((Join-Path $env:WINDIR 'System32\vulkan-1.dll'), (Join-Path $env:WINDIR 'SysWOW64\vulkan-1.dll'))
            $vkLoader = @($vkLoaderPaths | Where-Object { Test-Path $_ })
            $vkInfo = Get-Command 'vulkaninfo.exe' -ErrorAction SilentlyContinue
            $vkRegistry = Test-Path 'HKLM:\SOFTWARE\Khronos\Vulkan\Drivers'
            if ($vkLoader.Count -gt 0 -or $vkRegistry) {
                $lines.Add('Vulkan: loader/driver registry signal found.')
                if ($vkInfo) {
                    try { $vkOutput = (& $vkInfo.Source --summary 2>&1 | Select-Object -First 16) -join "`r`n"; $lines.Add('vulkaninfo --summary:'); $lines.Add($vkOutput) }
                    catch { $lines.Add('vulkaninfo exists but could not query a physical device. Update/check the official GPU driver.') }
                } else { $lines.Add('Physical Vulkan device support is not fully verified because vulkaninfo.exe is not installed/on PATH.') }
            } else { $lines.Add('Vulkan: no standard loader or driver-registry signal found. A compatible GPU driver may be missing, or the installation uses a nonstandard path.') }
        }
        $lines.Add('')
        $lines.Add('Safety note: Scan only. Project-specific renderer/API settings are not changed automatically.')
        return ($lines -join "`r`n")
    }

    function Get-EngineOptimizationGuide($target) {
        switch ($target) {
            'Unreal Engine' { return "UNREAL ENGINE GUIDE`r`n- Use Unreal Insights / Stat Unit / Stat GPU to identify the actual bottleneck.`r`n- Shader compilation can cause first-run hitches; compare after compilation completes.`r`n- Tune shadows, view distance, Lumen/Nanite and scalability one at a time inside the project.`r`n- Windows GPU preference can prioritize a discrete GPU for UnrealEditor.exe when one exists; it cannot create extra GPU hardware or force an unsupported renderer." }
            'DirectX' { return "DIRECTX GUIDE`r`n- Open dxdiag and check driver and feature-level details.`r`n- Use official PC/GPU drivers; DirectX runtime version is not the same as feature-level support.`r`n- Windows per-app GPU routing can be set for a specific executable; no global registry setting can unlock unsupported DirectX features." }
            'Vulkan' { return "VULKAN GUIDE`r`n- Use a current official GPU driver and vulkaninfo --summary if the tool is installed.`r`n- Vulkan is application + driver + GPU specific; Windows has no universal Vulkan performance switch.`r`n- Compare the same scene/build before and after a driver or renderer change." }
            default { return "ENGINE GUIDE`r`n- This section covers Unreal Engine, DirectX and Vulkan.`r`n- Safe Windows-side actions include Game Mode and per-app GPU preference for detected Unreal Editor executables.`r`n- Project-specific renderer/scalability settings must be changed inside the project after profiling.`r`n- Results are written to the main activity log. No renderer is forced globally." }
        }
    }

    function Invoke-QuickBenchmark {
        $lines = New-Object System.Collections.Generic.List[string]
        $h = Get-LocalHardwareProfile
        $lines.Add('LOOK SYNTHETIC PERFORMANCE BENCHMARK')
        $lines.Add("System: $($h.Computer) | CPU: $($h.Cpu) | RAM $($h.RamGB) GB")
        $lines.Add('Score is an internal repeatable indicator, not an industry-standard benchmark or a direct FPS estimate.')

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $n = 0L
        while ($sw.ElapsedMilliseconds -lt 750) {
            $n++
            $dummy = [Math]::Sqrt([double](($n % 100000) + 1))
            if (($n % 25000) -eq 0) { [System.Windows.Forms.Application]::DoEvents() }
        }
        $sw.Stop()
        $cpuOps = if ($sw.Elapsed.TotalSeconds -gt 0) { [Math]::Round($n / $sw.Elapsed.TotalSeconds,0) } else { 0 }
        $lines.Add("CPU loop: $n iterations in $([Math]::Round($sw.Elapsed.TotalSeconds,3)) s ($cpuOps iterations/s)")

        $ramRate = 0.0
        try {
            $size = 32 * 1024 * 1024
            $a = New-Object 'System.Byte[]' $size
            $b = New-Object 'System.Byte[]' $size
            $memSw = [System.Diagnostics.Stopwatch]::StartNew()
            for ($i=0; $i -lt 8; $i++) { [System.Buffer]::BlockCopy($a,0,$b,0,$size) }
            $memSw.Stop()
            $mb = [Math]::Round((($size * 8) / 1MB),1)
            if ($memSw.Elapsed.TotalSeconds -gt 0) { $ramRate = [Math]::Round(($mb / $memSw.Elapsed.TotalSeconds),1) }
            $lines.Add("RAM copy: $mb MiB in $([Math]::Round($memSw.Elapsed.TotalSeconds,3)) s (~$ramRate MiB/s)")
            $a = $null; $b = $null
        } catch { $lines.Add("RAM test unavailable: $($_.Exception.Message)") }

        $diskRate = 0.0
        $testFile = Join-Path $env:TEMP ('LookLatencyBench-' + [Guid]::NewGuid().ToString('N') + '.tmp')
        try {
            $chunk = New-Object 'System.Byte[]' (1024 * 1024)
            $rng = New-Object System.Random(47)
            $rng.NextBytes($chunk)
            $diskSw = [System.Diagnostics.Stopwatch]::StartNew()
            $fs = New-Object System.IO.FileStream($testFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 1048576, [System.IO.FileOptions]::WriteThrough)
            try { for ($i=0; $i -lt 32; $i++) { $fs.Write($chunk,0,$chunk.Length) }; $fs.Flush() } finally { $fs.Dispose() }
            $diskSw.Stop()
            if ($diskSw.Elapsed.TotalSeconds -gt 0) { $diskRate = [Math]::Round((32 / $diskSw.Elapsed.TotalSeconds),1) }
            $lines.Add("Temp-disk sequential write: 32 MiB in $([Math]::Round($diskSw.Elapsed.TotalSeconds,3)) s (~$diskRate MiB/s)")
        } catch { $lines.Add("Disk test unavailable: $($_.Exception.Message)") }
        finally { Remove-Item -LiteralPath $testFile -Force -ErrorAction SilentlyContinue }

        # Logarithmic components avoid treating one very fast subtest as the whole PC.
        $cpuScore = [Math]::Min(100,[Math]::Max(0,100 * [Math]::Log10(1 + ($cpuOps / 10000.0)) / [Math]::Log10(41)))
        $ramScore = [Math]::Min(100,[Math]::Max(0,100 * [Math]::Log10(1 + ($ramRate / 250.0)) / [Math]::Log10(41)))
        $diskScore = [Math]::Min(100,[Math]::Max(0,100 * [Math]::Log10(1 + ($diskRate / 10.0)) / [Math]::Log10(101)))
        $score = [int][Math]::Round(($cpuScore * 0.45) + ($ramScore * 0.20) + ($diskScore * 0.35),0)
        $tier = if ($score -lt 35) { 'Entry' } elseif ($score -lt 55) { 'Everyday' } elseif ($score -lt 70) { 'Balanced' } elseif ($score -lt 85) { 'Strong' } else { 'Very Strong' }
        $lines.Add(('Component scores (heuristic): CPU {0:N0}/100 | RAM {1:N0}/100 | Disk {2:N0}/100' -f $cpuScore,$ramScore,$diskScore))
        $lines.Add("LOOK SCORE: $score / 100 | Tier: $tier")
        $lines.Add('Weights: CPU 45%, RAM copy 20%, temporary sequential disk write 35%. Scores vary by power mode, temperature, background load, PowerShell version and storage caching; compare the same PC under similar conditions.')
        $lines.Add('This benchmark does not stress the GPU, estimate FPS, check stability after overclocking, or rank PCs against a public database.')
        try {
            $prefDir = Join-Path $env:LOCALAPPDATA 'LookAtTheLatency'
            if (-not (Test-Path -LiteralPath $prefDir)) { New-Item -Path $prefDir -ItemType Directory -Force | Out-Null }
            $record = [pscustomobject]@{ Date=(Get-Date).ToString('o'); Score=$score; Tier=$tier; Cpu=$h.Cpu; RamGB=$h.RamGB; Gpus=$h.Gpus; CpuIterationsPerSecond=$cpuOps; RamMiBPerSecond=$ramRate; DiskMiBPerSecond=$diskRate; Components=[pscustomobject]@{CPU=[Math]::Round($cpuScore,1); RAM=[Math]::Round($ramScore,1); Disk=[Math]::Round($diskScore,1)} }
            $record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $prefDir 'last-benchmark.json') -Encoding UTF8
        } catch { $lines.Add("Could not save benchmark result: $($_.Exception.Message)") }
        try { if ($lblLookScore) { $lblLookScore.Text = "LOOK Score: $score / 100 ($tier) | CPU $([Math]::Round($cpuScore,0)) · RAM $([Math]::Round($ramScore,0)) · Disk $([Math]::Round($diskScore,0))" } } catch {}
        return ($lines -join "`r`n")
    }

    # ---------------- Theme system ----------------
    $script:themeRoleMap = @{}
    function Get-ThemeColorByRole($role) {
        switch ($role) {
            'background' { return $script:themePalette.Background }
            'card' { return $script:themePalette.Card }
            'hover' { return $script:themePalette.Hover }
            'accent' { return $script:themePalette.Accent }
            'accentdark' { return $script:themePalette.AccentDark }
            'text' { return $script:themePalette.Text }
            'subtext' { return $script:themePalette.SubText }
            'warning' { return $script:themePalette.Warning }
            'log' { return $script:themePalette.Log }
            'danger' { return $script:themePalette.Danger }
            'white' { return [System.Drawing.Color]::White }
            default { return [System.Drawing.Color]::Transparent }
        }
    }
    function Apply-UiTheme([string]$name) {
        if (-not $script:themeDefinitions.Contains($name)) { $name = 'Emerald' }
        $script:themePalette = $script:themeDefinitions[$name]
        if ($script:themePaletteRef) { $script:themePaletteRef.Current = $script:themePalette }
        $queue = New-Object 'System.Collections.Generic.Queue[System.Windows.Forms.Control]'
        $queue.Enqueue($form)
        while ($queue.Count -gt 0) {
            $ctrl = $queue.Dequeue()
            $id = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($ctrl)
            if (-not $script:themeRoleMap.ContainsKey($id)) {
                $backRole = 'preserve'; $foreRole = 'preserve'
                if ($ctrl -is [System.Windows.Forms.Form]) { $backRole = 'background' }
                elseif ($ctrl -is [GradientPanel]) { $backRole = 'header' }
                elseif ($ctrl -is [System.Windows.Forms.Button]) { if ($ctrl -eq $btnRestoreDefaults) { $backRole = 'danger' } else { $backRole = 'accentdark' }; $foreRole = 'white' }
                elseif ($ctrl -is [System.Windows.Forms.TextBox] -or $ctrl -is [System.Windows.Forms.RichTextBox]) { if ($ctrl -eq $logBox) { $backRole = 'log'; $foreRole = 'accent' } else { $backRole = 'card'; $foreRole = 'text' } }
                elseif ($ctrl -is [System.Windows.Forms.ListView]) { $backRole = 'card'; $foreRole = 'text' }
                elseif ($ctrl -is [System.Windows.Forms.ComboBox]) { $backRole = 'card'; $foreRole = 'text' }
                elseif ($ctrl -is [ToggleSwitch]) { $backRole = 'background'; $foreRole = 'text' }
                else {
                    $ba = $ctrl.BackColor.ToArgb()
                    if ($ctrl.BackColor -eq [System.Drawing.Color]::Transparent) { $backRole = 'transparent' }
                    elseif ($ba -eq $cBg.ToArgb()) { $backRole = 'background' }
                    elseif ($ba -eq $cCard.ToArgb()) { $backRole = 'card' }
                    elseif ($ba -eq $cCardHover.ToArgb()) { $backRole = 'hover' }
                    elseif ($ba -eq $cGreen.ToArgb()) { $backRole = 'accent' }
                    elseif ($ba -eq $cGreenDark.ToArgb()) { $backRole = 'accentdark' }
                    elseif ($ctrl.BackColor.R -gt 100 -and $ctrl.BackColor.G -lt 100 -and $ctrl.BackColor.B -lt 100) { $backRole = 'danger' }
                    $fa = $ctrl.ForeColor.ToArgb()
                    if ($ctrl.ForeColor -eq [System.Drawing.Color]::White) { $foreRole = 'white' }
                    elseif ($fa -eq $cGreen.ToArgb()) { $foreRole = 'accent' }
                    elseif ($fa -eq $cSubText.ToArgb()) { $foreRole = 'subtext' }
                    elseif ($fa -eq $cWarn.ToArgb()) { $foreRole = 'warning' }
                    elseif ($fa -eq $cText.ToArgb()) { $foreRole = 'text' }
                }
                $script:themeRoleMap[$id] = @{ Back=$backRole; Fore=$foreRole; Type=$ctrl.GetType().FullName }
            }
            $role = $script:themeRoleMap[$id]
            if ($ctrl -is [GradientPanel]) {
                $ctrl.ColorTop = $script:themePalette.Header; $ctrl.ColorBottom = $script:themePalette.Background; $ctrl.Invalidate()
            } elseif ($role.Back -ne 'preserve' -and $role.Back -ne 'transparent' -and $role.Back -ne 'header') {
                $ctrl.BackColor = Get-ThemeColorByRole $role.Back
            }
            if ($role.Fore -ne 'preserve') { $ctrl.ForeColor = Get-ThemeColorByRole $role.Fore }
            if ($ctrl -is [ToggleSwitch]) { $ctrl.OnColor = $script:themePalette.Accent; $ctrl.OffColor = $script:themePalette.SubText }
            if ($ctrl -is [System.Windows.Forms.ProgressBar]) { $ctrl.ForeColor = $script:themePalette.Accent }
            foreach ($child in $ctrl.Controls) { $queue.Enqueue($child) }
        }
        $lblBack.BackColor = $script:themePalette.AccentDark
        $lblBack.ForeColor = [System.Drawing.Color]::White
        $btnUiSound.BackColor = if ($script:uiSoundsEnabled) { $script:themePalette.AccentDark } else { $script:themePalette.Card }
        $btnUiSound.ForeColor = [System.Drawing.Color]::White
        $lblTitle.ForeColor = if ($name -eq 'Light') { $script:themePalette.Text } else { [System.Drawing.Color]::White }
        try {
            $prefDir = Join-Path $env:LOCALAPPDATA 'LookAtTheLatency'
            if (-not (Test-Path -LiteralPath $prefDir)) { New-Item -Path $prefDir -ItemType Directory -Force | Out-Null }
            [pscustomobject]@{ Theme=$name } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $prefDir 'preferences.json') -Encoding UTF8
        } catch { Log "[Theme] Could not save theme preference: $($_.Exception.Message)" }
        try { Log "[Theme] Applied $name theme." } catch {}
    }

    # ---------------- Installed game library ----------------
    $script:gameCatalog = @()
    $script:raisedGamePrioritySnapshots = @()
    $script:gameAutoOpenPromptDone = $false
    $script:adobeAutoScanDone = $false
    function Test-IsRecognizedGameName([string]$name) {
        return ($name -match '(?i)Minecraft|Badlion|Lunar Client|Feather Client|Counter.?Strike|\bCS2\b|Valorant|Fortnite|Roblox|Rocket League|Grand Theft Auto|\bGTA\b|Apex Legends|Dota 2|League of Legends|Overwatch|PUBG|Genshin Impact|Elden Ring|Cyberpunk|Terraria|Stardew Valley|Palworld|Battlefield|Call of Duty|Forza|Euro Truck Simulator|Among Us|Fall Guys|Warframe|Destiny|Hogwarts Legacy|Baldur|FIFA|EA SPORTS FC|Red Dead Redemption|The Witcher|War Thunder|World of Tanks|Wuthering Waves|Zenless Zone Zero|Riot Client')
    }
    function Find-GameExecutable([string]$root, [string]$displayName) {
        if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) { return $null }
        $queue = New-Object System.Collections.Queue
        $queue.Enqueue(@($root,0))
        $visited = 0
        $best = $null; $bestScore = -999
        $clean = (($displayName -replace '(?i)the |edition|remastered|deluxe|ultimate|standard|game of the year|\W','').ToLowerInvariant())
        while ($queue.Count -gt 0 -and $visited -lt 130) {
            $entry = $queue.Dequeue(); $dirPath = [string]$entry[0]; $depth = [int]$entry[1]; $visited++
            try {
                foreach ($file in @(Get-ChildItem -LiteralPath $dirPath -Filter '*.exe' -File -ErrorAction SilentlyContinue)) {
                    $base = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
                    if ($base -match '(?i)unins|uninstall|crashreport|crashhandler|setup|updater|bootstrap|redist|vc_redist|easyanticheat|prereq|reporter|launcherinstaller') { continue }
                    $score = 1
                    $compact = ($base -replace '\W','').ToLowerInvariant()
                    if ($clean.Length -ge 4 -and $compact.Contains($clean.Substring(0,[Math]::Min(8,$clean.Length)))) { $score += 8 }
                    if ($base -match '(?i)win64-shipping|\bcs2\b|valorant|robloxplayerbeta|minecraft|photoshop|afterfx|premiere') { $score += 7 }
                    if ($base -match '(?i)unrealeditor|ue4editor|unitycrashhandler|crashreportclient|launcher$') { $score -= 3 }
                    if ($score -gt $bestScore) { $bestScore = $score; $best = $file.FullName }
                }
            } catch {}
            if ($depth -lt 4) {
                try {
                    foreach ($sub in @(Get-ChildItem -LiteralPath $dirPath -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '(?i)^(_?commonredist|redist|redistributables|easyanticheat|eac|crashreportclient|crashreports|downloads|cache|logs|saved|content|packages|shadercache|\.git)$' })) {
                        if ($visited + $queue.Count -lt 160) { $queue.Enqueue(@($sub.FullName,$depth+1)) }
                    }
                } catch {}
            }
        }
        if ($bestScore -le 0) { return $null }
        return $best
    }
    function Get-InstalledGameCatalog {
        $results = New-Object System.Collections.Generic.List[object]
        $seen = @{}
        $uninstallPaths = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')
        foreach ($key in $uninstallPaths) {
            try {
                foreach ($item in @(Get-ItemProperty $key -ErrorAction SilentlyContinue)) {
                    if (-not $item.DisplayName -or -not (Test-IsRecognizedGameName ([string]$item.DisplayName))) { continue }
                    $root = [string]$item.InstallLocation; $exe = $null
                    if ($item.DisplayIcon) {
                        $iconText = [string]$item.DisplayIcon
                        if ($iconText -match '^"?(.+?\.exe)"?(?:,\s*\-?\d+)?$' -and (Test-Path -LiteralPath $Matches[1])) { $exe = $Matches[1] }
                    }
                    if (-not $exe -and $root) { $exe = Find-GameExecutable $root ([string]$item.DisplayName) }
                    $id = ([string]$item.DisplayName + '|' + [string]$exe + '|' + [string]$root).ToLowerInvariant()
                    if (-not $seen.ContainsKey($id)) { $seen[$id]=$true; $results.Add([pscustomobject]@{ Name=[string]$item.DisplayName; Exe=$exe; Root=$root; Source='Installed Apps' }) }
                }
            } catch {}
        }
        # Steam game manifests (also honor additional Steam libraries).
        $steamRoots = @("${env:ProgramFiles(x86)}\Steam", "$env:ProgramFiles\Steam", "$env:LOCALAPPDATA\Steam") | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
        $libraries = New-Object System.Collections.Generic.List[string]
        foreach ($sr in $steamRoots) {
            if (-not $libraries.Contains($sr)) { $libraries.Add($sr) }
            $vdf = Join-Path $sr 'steamapps\libraryfolders.vdf'
            if (Test-Path -LiteralPath $vdf) {
                try { $raw=Get-Content -LiteralPath $vdf -Raw; foreach ($match in [regex]::Matches($raw,'"path"\s+"([^"]+)"')) { $path=$match.Groups[1].Value.Replace('\\','\'); if (Test-Path -LiteralPath $path -and -not $libraries.Contains($path)) { $libraries.Add($path) } } } catch {}
            }
        }
        foreach ($lib in $libraries) {
            $manifests = Join-Path $lib 'steamapps'
            if (-not (Test-Path -LiteralPath $manifests)) { continue }
            foreach ($acf in @(Get-ChildItem -LiteralPath $manifests -Filter 'appmanifest_*.acf' -File -ErrorAction SilentlyContinue)) {
                try {
                    $txt = Get-Content -LiteralPath $acf.FullName -Raw
                    $mn = [regex]::Match($txt,'"name"\s+"([^"]+)"'); $mi = [regex]::Match($txt,'"installdir"\s+"([^"]+)"')
                    if (-not $mn.Success -or -not (Test-IsRecognizedGameName $mn.Groups[1].Value)) { continue }
                    $title=$mn.Groups[1].Value; $root=Join-Path (Join-Path $manifests 'common') $mi.Groups[1].Value
                    if (-not $mi.Success -or -not (Test-Path -LiteralPath $root)) { continue }
                    $idMatch=[regex]::Match($acf.Name,'appmanifest_(\d+)\.acf')
                    $steamAppId=if ($idMatch.Success) { $idMatch.Groups[1].Value } else { $null }
                    $exe=Find-GameExecutable $root $title
                    $id=($title+'|'+[string]$exe+'|'+$root).ToLowerInvariant()
                    if (-not $seen.ContainsKey($id)) { $seen[$id]=$true; $results.Add([pscustomobject]@{ Name=$title; Exe=$exe; Root=$root; Source='Steam'; AppId=$steamAppId }) }
                } catch {}
            }
        }
        # Epic Games manifests expose install roots and launch executables without deep drive scans.
        $epicManifests = Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\Manifests'
        if (Test-Path -LiteralPath $epicManifests) {
            foreach ($manifest in @(Get-ChildItem -LiteralPath $epicManifests -Filter '*.item' -File -ErrorAction SilentlyContinue)) {
                try {
                    $doc=Get-Content -LiteralPath $manifest.FullName -Raw | ConvertFrom-Json -ErrorAction Stop
                    $title=[string]$doc.DisplayName; if (-not (Test-IsRecognizedGameName $title)) { continue }
                    $root=[string]$doc.InstallLocation; $exe=$null
                    if ($root -and $doc.LaunchExecutable) { $candidate=Join-Path $root ([string]$doc.LaunchExecutable); if (Test-Path -LiteralPath $candidate) { $exe=$candidate } }
                    if (-not $exe -and $root) { $exe=Find-GameExecutable $root $title }
                    $id=($title+'|'+[string]$exe+'|'+$root).ToLowerInvariant()
                    if (-not $seen.ContainsKey($id)) { $seen[$id]=$true; $results.Add([pscustomobject]@{ Name=$title; Exe=$exe; Root=$root; Source='Epic' }) }
                } catch {}
            }
        }
        # Start-menu shortcuts are a useful fallback for custom/launcher-based installs.
        try {
            $shortcutRoots = @((Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'),(Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),(Join-Path $env:USERPROFILE 'Desktop')) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
            $wsh = New-Object -ComObject WScript.Shell
            foreach ($sr in $shortcutRoots) {
                foreach ($shortcut in @(Get-ChildItem -LiteralPath $sr -Filter '*.lnk' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 350)) {
                    if (-not (Test-IsRecognizedGameName $shortcut.BaseName)) { continue }
                    try {
                        $link = $wsh.CreateShortcut($shortcut.FullName); $exe=[string]$link.TargetPath
                        if (-not $exe -or -not (Test-Path -LiteralPath $exe -PathType Leaf)) { continue }
                        $title=[string]$shortcut.BaseName; $id=($title+'|'+$exe).ToLowerInvariant()
                        if (-not $seen.ContainsKey($id)) { $seen[$id]=$true; $results.Add([pscustomobject]@{ Name=$title; Exe=$exe; Root=(Split-Path $exe -Parent); Source='Start menu shortcut' }) }
                    } catch {}
                }
            }
        } catch {}

        # Common Minecraft clients that can be installed outside traditional uninstall registry entries.
        $known = @(
            @{Name='Minecraft Java';Root=(Join-Path $env:APPDATA '.minecraft')},
            @{Name='Badlion Client';Root=(Join-Path $env:APPDATA 'Badlion Client')},
            @{Name='Lunar Client';Root=(Join-Path $env:USERPROFILE '.lunarclient')},
            @{Name='Feather Client';Root=(Join-Path $env:APPDATA 'feather')},
            @{Name='Prism Launcher';Root=(Join-Path $env:APPDATA 'PrismLauncher')}
        )
        foreach ($item in $known) {
            if (Test-Path -LiteralPath $item.Root) {
                $exe = Find-GameExecutable $item.Root $item.Name
                $id=($item.Name+'|'+[string]$exe+'|'+$item.Root).ToLowerInvariant()
                if (-not $seen.ContainsKey($id)) { $seen[$id]=$true; $results.Add([pscustomobject]@{ Name=$item.Name; Exe=$exe; Root=$item.Root; Source='Known game client folder' }) }
            }
        }
        # Currently running supported game executables are high-confidence entries.
        foreach ($proc in @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '(?i)javaw|cs2|valorant|fortnite|robloxplayer|unrealeditor|ue4editor|dota2|leagueclient|overwatch|r5apex|eldenring|gta5' })) {
            try {
                $exe=$proc.Path
                if ($exe -and (Test-Path -LiteralPath $exe)) {
                    $title=$proc.ProcessName
                    $id=($title+'|'+$exe).ToLowerInvariant()
                    if (-not $seen.ContainsKey($id)) { $seen[$id]=$true; $results.Add([pscustomobject]@{ Name=$title; Exe=$exe; Root=(Split-Path $exe -Parent); Source='Running process' }) }
                }
            } catch {}
        }
        return @($results | Sort-Object Name,Exe)
    }
    function New-GameFallbackIcon([string]$label) {
        $bmp=New-Object System.Drawing.Bitmap(32,32); $g=[System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.SmoothingMode='AntiAlias'; $g.Clear($script:themePalette.AccentDark)
            $pen=New-Object System.Drawing.Pen($script:themePalette.Accent,2); $g.DrawEllipse($pen,1,1,30,30)
            $brush=New-Object System.Drawing.SolidBrush($script:themePalette.Text)
            $initials=([string]$label -split '\s+' | Where-Object { $_ } | Select-Object -First 2 | ForEach-Object { $_.Substring(0,1).ToUpperInvariant() }) -join ''
            if (-not $initials) { $initials='G' }
            $font=New-Object System.Drawing.Font('Segoe UI',10,[System.Drawing.FontStyle]::Bold)
            $size=$g.MeasureString($initials,$font)
            $g.DrawString($initials,$font,$brush,[single](($bmp.Width-$size.Width)/2),[single](($bmp.Height-$size.Height)/2))
            $brush.Dispose(); $font.Dispose(); $pen.Dispose()
        } catch {} finally { $g.Dispose() }
        return $bmp
    }
    function Refresh-GameLibrary([switch]$Silent) {
        try {
            $script:gameCatalog = @(Get-InstalledGameCatalog)
            $lvGames.BeginUpdate(); $lvGames.Items.Clear(); $imgGames.Images.Clear()
            foreach ($game in $script:gameCatalog) {
                $image=$null
                if ($game.Exe -and (Test-Path -LiteralPath $game.Exe)) {
                    try { $ico=[System.Drawing.Icon]::ExtractAssociatedIcon($game.Exe); if ($ico) { $image=$ico.ToBitmap(); $ico.Dispose() } } catch {}
                }
                if (-not $image) { $image=New-GameFallbackIcon $game.Name }
                [void]$imgGames.Images.Add($image); $image.Dispose()
                $status=if ($game.Exe -and (Test-Path -LiteralPath $game.Exe)) { 'Executable found' } else { 'Install found; EXE unknown' }
                $pathText=if ($game.Exe) { $game.Exe } elseif ($game.Root) { $game.Root } else { 'Not exposed by installer' }
                $li=New-Object System.Windows.Forms.ListViewItem([string]$game.Name,($imgGames.Images.Count-1))
                [void]$li.SubItems.Add($status); [void]$li.SubItems.Add($pathText); $li.Tag=$game
                [void]$lvGames.Items.Add($li)
            }
            $lvGames.EndUpdate()
            if (-not $Silent) { Log "[Games] Found $($script:gameCatalog.Count) installed/known games or clients. Executable icons are extracted locally; no images were downloaded." }
            if ($script:gameCatalog.Count -eq 0) {
                $lblGameLibrary.Text = 'Installed Game Library — no supported games detected in common registry/Steam/Epic/client locations.'
            } else { $lblGameLibrary.Text = "Installed Game Library — $($script:gameCatalog.Count) game/client entries found." }
            return $script:gameCatalog.Count
        } catch {
            try { $lvGames.EndUpdate() } catch {}
            Log "[Games] Library scan failed: $($_.Exception.Message)"
            return 0
        }
    }
    function Get-GameSteamAppId($game) {
        if ($game -and $game.PSObject.Properties['AppId'] -and $game.AppId) { return [string]$game.AppId }
        $name = [string]$game.Name
        if ($name -match '(?i)Counter.?Strike|\bCS2\b') { return '730' }
        if ($name -match '(?i)^Dota 2') { return '570' }
        if ($name -match '(?i)Apex Legends') { return '1172470' }
        if ($name -match '(?i)Grand Theft Auto V|\bGTA V\b') { return '271590' }
        if ($name -match '(?i)Rocket League') { return '252950' }
        if ($name -match '(?i)PUBG|Battlegrounds') { return '578080' }
        if ($name -match '(?i)Elden Ring') { return '1245620' }
        if ($name -match '(?i)Cyberpunk 2077') { return '1091500' }
        if ($name -match '(?i)Terraria') { return '105600' }
        if ($name -match '(?i)Stardew Valley') { return '413150' }
        if ($name -match '(?i)Palworld') { return '1623730' }
        if ($name -match '(?i)Warframe') { return '230410' }
        if ($name -match '(?i)Destiny 2') { return '1085660' }
        if ($name -match '(?i)Hogwarts Legacy') { return '990080' }
        if ($name -match '(?i)Baldur.s Gate 3') { return '1086940' }
        if ($name -match '(?i)Among Us') { return '945360' }
        if ($name -match '(?i)Fall Guys') { return '1097150' }
        if ($name -match '(?i)War Thunder') { return '236390' }
        if ($name -match '(?i)Forza Horizon 5') { return '1551360' }
        if ($name -match '(?i)Red Dead Redemption 2') { return '1174180' }
        if ($name -match '(?i)The Witcher 3') { return '292030' }
        if ($name -match '(?i)Euro Truck Simulator 2') { return '227300' }
        return $null
    }
    function Load-GameArtworkAsync {
        $themePaletteRef = $script:themePaletteRef
        $candidates = New-Object System.Collections.Generic.List[object]
        foreach ($game in @($script:gameCatalog)) {
            $appId = Get-GameSteamAppId $game
            if ($appId -match '^\d+$') {
                $key = ([string]$game.Name + '|' + [string]$game.Exe + '|' + [string]$game.Root)
                $candidates.Add([pscustomobject]@{ Name=[string]$game.Name; Key=$key; AppId=$appId })
            }
        }
        if ($candidates.Count -eq 0) {
            Log '[Game Art] No Steam app ID was identified for detected entries. Local executable icons remain in place.'
            return
        }
        $choice=[System.Windows.Forms.MessageBox]::Show("Download optional game thumbnails from Steam's public CDN for up to 12 identified games? This sends only public Steam app IDs to the CDN. Other games keep their local icons. Downloads happen in the background.",'Load Game Cover Art',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::None)
        if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { Log '[Game Art] Cover-art download cancelled.'; return }
        $cacheDir=Join-Path (Join-Path $env:LOCALAPPDATA 'LookAtTheLatency') 'GameArt'
        if (-not (Test-Path -LiteralPath $cacheDir)) { New-Item -Path $cacheDir -ItemType Directory -Force | Out-Null }
        $tasks = @($candidates | Sort-Object AppId -Unique | Select-Object -First 12 | ForEach-Object {
            [pscustomobject]@{ Name=$_.Name; Key=$_.Key; AppId=$_.AppId; Cache=(Join-Path $cacheDir ($_.AppId + '.jpg')) }
        })
        $worker=New-Object System.ComponentModel.BackgroundWorker
        $worker.WorkerSupportsCancellation=$false
        $worker.add_DoWork({
            param($sender,$e)
            $items=New-Object System.Collections.Generic.List[object]
            $oldProtocol=[System.Net.ServicePointManager]::SecurityProtocol
            try {
                [System.Net.ServicePointManager]::SecurityProtocol=[System.Net.SecurityProtocolType]::Tls12
                foreach ($task in @($e.Argument.Tasks)) {
                    if (-not (Test-Path -LiteralPath $task.Cache)) {
                        $temp=$task.Cache + '.download'
                        $downloaded=$false
                        foreach ($suffix in @('header.jpg','library_600x900.jpg')) {
                            $response=$null; $stream=$null; $fs=$null
                            try {
                                $uri="https://cdn.akamai.steamstatic.com/steam/apps/$($task.AppId)/$suffix"
                                $request=[System.Net.HttpWebRequest]::Create($uri)
                                $request.Method='GET'; $request.Timeout=2200; $request.ReadWriteTimeout=2200; $request.UserAgent='LOOK-at-the-Latency/17'
                                $response=$request.GetResponse()
                                if ($response.ContentType -notlike 'image/*' -or ($response.ContentLength -gt 0 -and $response.ContentLength -gt 3000000)) { continue }
                                $stream=$response.GetResponseStream()
                                $fs=New-Object System.IO.FileStream($temp,[System.IO.FileMode]::Create,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)
                                $stream.CopyTo($fs); $fs.Flush(); $fs.Dispose(); $fs=$null
                                $stream.Dispose(); $stream=$null; $response.Close(); $response=$null
                                if ((Test-Path -LiteralPath $temp) -and (Get-Item -LiteralPath $temp).Length -gt 1000) { Move-Item -LiteralPath $temp -Destination $task.Cache -Force; $downloaded=$true; break }
                            } catch {} finally {
                                try { if ($fs) { $fs.Dispose() } } catch {}
                                try { if ($stream) { $stream.Dispose() } } catch {}
                                try { if ($response) { $response.Close() } } catch {}
                                Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
                            }
                        }
                    }
                    if (Test-Path -LiteralPath $task.Cache) { $items.Add([pscustomobject]@{ Name=$task.Name; Key=$task.Key; AppId=$task.AppId; Path=$task.Cache }) }
                }
            } catch {} finally { [System.Net.ServicePointManager]::SecurityProtocol=$oldProtocol }
            $e.Result=@($items.ToArray())
        }.GetNewClosure())
        $worker.add_RunWorkerCompleted({
            param($sender,$e)
            try {
                $loaded=0
                foreach ($art in @($e.Result)) {
                    try {
                        $matched=$null
                        foreach ($item in $lvGames.Items) {
                            $g=$item.Tag; $itemKey=([string]$g.Name+'|'+[string]$g.Exe+'|'+[string]$g.Root)
                            if ($itemKey -eq $art.Key) { $matched=$item; break }
                        }
                        if (-not $matched) { continue }
                        $src=[System.Drawing.Image]::FromFile($art.Path)
                        $tile=New-Object System.Drawing.Bitmap(48,48)
                        $gfx=[System.Drawing.Graphics]::FromImage($tile)
                        try {
                            $gfx.Clear($themePaletteRef.Current.Card)
                            $gfx.InterpolationMode=[System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                            $scale=[Math]::Min(44.0/$src.Width,44.0/$src.Height)
                            $w=[int][Math]::Max(1,$src.Width*$scale); $h=[int][Math]::Max(1,$src.Height*$scale)
                            $x=[int](($tile.Width-$w)/2); $y=[int](($tile.Height-$h)/2)
                            $gfx.DrawImage($src,$x,$y,$w,$h)
                        } finally { $gfx.Dispose(); $src.Dispose() }
                        $newIndex=$imgGames.Images.Add($tile); $tile.Dispose()
                        $matched.ImageIndex=$newIndex
                        $loaded++
                    } catch {}
                }
                Log "[Game Art] Loaded $loaded cached/downloaded Steam thumbnails. Entries without matching public artwork keep their local icons."
                $lvGames.Invalidate()
            } catch { Log "[Game Art] Could not apply thumbnails: $($_.Exception.Message)" }
            try { $sender.Dispose() } catch {}
        }.GetNewClosure())
        Log "[Game Art] Fetching up to $($tasks.Count) cover thumbnails in the background..."
        $worker.RunWorkerAsync(@{Tasks=$tasks})
    }

    function Optimize-GameEntries($entries) {
        $games=@($entries | Where-Object { $_ -and $_.Exe -and (Test-Path -LiteralPath $_.Exe) } | Sort-Object Exe -Unique)
        if ($games.Count -eq 0) { Log '[Games] No executable path is available for the selection. Windows GPU routing needs a real .exe path.'; return }
        $choice=[System.Windows.Forms.MessageBox]::Show("Apply reversible Windows Game Mode and, if the PC has multiple GPU adapters, per-app High performance GPU preference to $($games.Count) selected game executable(s)?`n`nOptional power-plan and transparency/animation settings are controlled by the checkboxes above. Nothing will modify game files or BIOS.",'Confirm per-game optimization',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::None)
        if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { Log '[Games] Per-game optimization cancelled.'; return }
        Invoke-LookGamingModeCore -TargetGames $games
        foreach ($game in $games) { Log "[Games] Profile processed: $($game.Name) -> $($game.Exe)" }
    }

    # ---------------- Graphics software discovery ----------------
    function Get-GraphicsControlApps {
        $apps=New-Object System.Collections.Generic.List[object]
        try {
            foreach ($app in @(Get-StartApps -ErrorAction Stop)) {
                if ($app.Name -match '(?i)NVIDIA Control Panel|NVIDIA App|Intel Graphics Command Center|Intel Graphics Software|AMD Software|Radeon Software') {
                    $vendor=if ($app.Name -match '(?i)NVIDIA') {'NVIDIA'} elseif ($app.Name -match '(?i)Intel') {'Intel'} else {'AMD'}
                    $apps.Add([pscustomobject]@{ Name=[string]$app.Name; AppID=[string]$app.AppID; Path=$null; Vendor=$vendor })
                }
            }
        } catch {}
        $classic=@(
            @{Name='NVIDIA Control Panel';Vendor='NVIDIA';Path="$env:ProgramFiles\NVIDIA Corporation\Control Panel Client\nvcplui.exe"},
            @{Name='Intel Graphics Command Center';Vendor='Intel';Path="$env:ProgramFiles\WindowsApps\IntelGraphicsExperience.exe"},
            @{Name='AMD Software';Vendor='AMD';Path="$env:ProgramFiles\AMD\CNext\CNext\RadeonSoftware.exe"}
        )
        foreach ($candidate in $classic) {
            if ($candidate.Path -and (Test-Path -LiteralPath $candidate.Path) -and -not (@($apps | Where-Object { $_.Name -eq $candidate.Name }).Count)) {
                $apps.Add([pscustomobject]@{ Name=$candidate.Name; AppID=$null; Path=$candidate.Path; Vendor=$candidate.Vendor })
            }
        }
        return @($apps | Sort-Object Vendor,Name -Unique)
    }
    function Open-GraphicsControlPanel([string]$vendor) {
        $apps=@(Get-GraphicsControlApps | Where-Object { $_.Vendor -eq $vendor } | Sort-Object @{Expression={
            if ($vendor -eq 'NVIDIA' -and $_.Name -match '(?i)NVIDIA Control Panel') { 0 }
            elseif ($vendor -eq 'Intel' -and $_.Name -match '(?i)Intel Graphics Software') { 0 }
            elseif ($vendor -eq 'Intel' -and $_.Name -match '(?i)Command Center') { 1 }
            else { 2 }
        }},Name)
        if ($apps.Count -eq 0) {
            Log "[Graphics] $vendor control app not found. Check Microsoft Store or the official PC/GPU maker support page; no third-party download was attempted."
            if ($vendor -eq 'NVIDIA') { try { Start-Process 'ms-settings:display-graphics' } catch {} }
            return
        }
        $app=$apps[0]
        $choice=[System.Windows.Forms.MessageBox]::Show("Open detected $vendor graphics utility?`n$($app.Name)`n`nThis tool will open the vendor UI; the optimizer cannot reliably write all driver-specific profile options through a universal Windows interface.",'Open graphics utility',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::None)
        if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { Log "[Graphics] Launch of $($app.Name) cancelled."; return }
        try {
            if ($app.AppID) { Start-Process -FilePath "$env:WINDIR\explorer.exe" -ArgumentList "shell:AppsFolder\$($app.AppID)" }
            elseif ($app.Path) { Start-Process -FilePath $app.Path }
            Log "[Graphics] Opened $($app.Name)."
        } catch { Log "[Graphics] Could not launch $($app.Name): $($_.Exception.Message)" }
    }
    function Show-RecommendedGraphicsProfile {
        $h=Get-LocalHardwareProfile
        $apps=@(Get-GraphicsControlApps)
        Log '[Graphics Profile] Hardware and local vendor utility discovery:'
        Log "   CPU: $($h.Cpu)"
        Log "   GPU(s): $($h.Gpus)"
        foreach ($app in $apps) { Log "   Available utility: $($app.Name) [$($app.Vendor)]" }
        if ($h.Gpus -match '(?i)NVIDIA') {
            Log '   NVIDIA recommended baseline: use Program Settings for each game; Power management = Normal/Optimal by default and Prefer maximum performance only for that game if clocks downshift too aggressively; Low Latency Mode = On when the game does not already manage latency; Texture filtering quality = Performance for competitive FPS; keep shader cache driver-managed.'
        }
        if ($h.Gpus -match '(?i)Intel') {
            Log '   Intel recommended baseline: choose per-game Performance/Balanced profile in Intel Graphics Software/Command Center; keep drivers OEM-approved on laptops; do not force V-Sync globally if a game needs low latency.'
        }
        if ($h.Gpus -match '(?i)AMD|Radeon') {
            Log '   AMD recommended baseline: use per-game profile in AMD Software; start with Standard/Default and enable Anti-Lag only for supported titles; avoid global image-sharpening/boost features until baseline FPS and frame times are measured.'
        }
        Log '   Windows-side automatic control: per-app GPU preference is available in the Game Library if multiple GPU adapters are present. NVIDIA/Intel driver-specific preferences are not rewritten blindly because their supported interfaces vary by driver version.'
        try { Start-Process 'ms-settings:display-graphics' } catch {}
    }

    # ---------------- Guided overclock benchmark workflow ----------------
    function Get-DetectedTuningTools {
        $tools=New-Object System.Collections.Generic.List[object]
        $paths=@(
            @{Name='MSI Afterburner';Path="${env:ProgramFiles(x86)}\MSI Afterburner\MSIAfterburner.exe"},
            @{Name='MSI Afterburner';Path="$env:ProgramFiles\MSI Afterburner\MSIAfterburner.exe"},
            @{Name='Intel Extreme Tuning Utility';Path="$env:ProgramFiles\Intel\Intel(R) Extreme Tuning Utility\Client\XTU.exe"},
            @{Name='Intel Extreme Tuning Utility';Path="${env:ProgramFiles(x86)}\Intel\Intel(R) Extreme Tuning Utility\Client\XTU.exe"},
            @{Name='AMD Ryzen Master';Path="$env:ProgramFiles\AMD\RyzenMaster\bin\AMD Ryzen Master.exe"},
            @{Name='AMD Ryzen Master';Path="$env:ProgramFiles\AMD\RyzenMaster\AMD Ryzen Master.exe"},
            @{Name='AMD Software';Path="$env:ProgramFiles\AMD\CNext\CNext\RadeonSoftware.exe"},
            @{Name='ASUS GPU Tweak III';Path="$env:ProgramFiles\ASUS\GPU TweakIII\GPU Tweak III.exe"},
            @{Name='Gigabyte Control Center';Path="$env:ProgramFiles\GIGABYTE\Control Center\GCC.exe"}
        )
        foreach ($p in $paths) { if ($p.Path -and (Test-Path -LiteralPath $p.Path) -and -not (@($tools | Where-Object Path -eq $p.Path).Count)) { $tools.Add([pscustomobject]@{Name=$p.Name;Path=$p.Path}) } }
        try {
            foreach ($app in @(Get-StartApps -ErrorAction Stop | Where-Object { $_.Name -match '(?i)Armoury Crate|MyASUS|Lenovo Vantage|MSI Center|OMEN Gaming Hub|Intel Graphics Software|NVIDIA App|AMD Software' })) {
                $tools.Add([pscustomobject]@{Name=[string]$app.Name;Path='APPID:'+[string]$app.AppID})
            }
        } catch {}
        return @($tools | Sort-Object @{Expression={ if ($_.Name -match '(?i)Afterburner|XTU|Ryzen Master|GPU Tweak') { 0 } elseif ($_.Name -match '(?i)Armoury Crate|MyASUS|Lenovo Vantage|MSI Center|OMEN Gaming Hub|PredatorSense|NitroSense') { 1 } else { 2 } }},Name -Unique)
    }
    function Start-GuidedOCWorkflow {
        $h=Get-LocalHardwareProfile
        $benchmarkText=Invoke-QuickBenchmark
        Write-ReportToLog '[OC workflow] Baseline benchmark before user-managed tuning' $benchmarkText
        $m=[regex]::Match($benchmarkText,'LOOK SCORE:\s*(\d+)\s*/\s*100')
        if (-not $m.Success) { Log '[OC workflow] Could not extract baseline score; no tuning utility launched.'; return }
        $dir=Join-Path $env:LOCALAPPDATA 'LookAtTheLatency'; if (-not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
        $base=[pscustomobject]@{Date=(Get-Date).ToString('o');Score=[int]$m.Groups[1].Value;Cpu=$h.Cpu;Gpus=$h.Gpus;RamGB=$h.RamGB}
        $file=Join-Path $dir 'oc-baseline.json'; $base | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $file -Encoding UTF8
        $tools=@(Get-DetectedTuningTools)
        if ($tools.Count -eq 0) {
            Log '[OC workflow] No vendor tuning utility was detected in common paths. No clock/voltage change was applied.'
            [void][System.Windows.Forms.MessageBox]::Show("Baseline LOOK Score: $($base.Score)/100.`nNo common vendor tuning utility was detected. The baseline has been saved to:`n$file`n`nManual voltage/clock changes are not applied by this script.",'Guided OC preflight',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::None)
            return
        }
        $toolLines=@($tools | ForEach-Object { if ($_.Path -like 'APPID:*') { "$($_.Name) (Start menu app; path not exposed)" } else { "$($_.Name) — $($_.Path)" } }) -join "`r`n"
        Log '[OC workflow] Detected tuning interfaces:'; foreach ($t in $tools) { Log "   $($t.Name): $($t.Path)" }
        $choice=[System.Windows.Forms.MessageBox]::Show("Baseline LOOK Score: $($base.Score)/100.`nDetected tools:`n$toolLines`n`nOpen the first available vendor utility now? Use its Auto Tuning / Scan feature only if it explicitly supports this hardware. Then return and click Compare Score After Tuning.",'Guided OC workflow',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::None)
        if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) {
            $tool=$tools[0]
            try { if ($tool.Path -like 'APPID:*') { $appId=$tool.Path.Substring(6); Start-Process -FilePath "$env:WINDIR\explorer.exe" -ArgumentList "shell:AppsFolder\$appId" } else { Start-Process -FilePath $tool.Path }; Log "[OC workflow] Launched $($tool.Name). No values were automatically changed by LOOK." }
            catch { Log "[OC workflow] Could not launch $($tool.Name): $($_.Exception.Message)" }
        }
    }
    function Compare-GuidedOCWorkflow {
        $file=Join-Path (Join-Path $env:LOCALAPPDATA 'LookAtTheLatency') 'oc-baseline.json'
        if (-not (Test-Path -LiteralPath $file)) { Log '[OC workflow] Run Start Guided OC first to create a baseline.'; return }
        try { $baseline=Get-Content -LiteralPath $file -Raw | ConvertFrom-Json } catch { Log '[OC workflow] Baseline file is invalid; rerun the baseline.'; return }
        $text=Invoke-QuickBenchmark
        Write-ReportToLog '[OC workflow] Post-tune benchmark' $text
        $m=[regex]::Match($text,'LOOK SCORE:\s*(\d+)\s*/\s*100')
        if (-not $m.Success) { Log '[OC workflow] Unable to compare score.'; return }
        $now=[int]$m.Groups[1].Value; $delta=$now-[int]$baseline.Score
        Log "[OC workflow] Baseline $($baseline.Score)/100 -> current $now/100 | change $delta points. This synthetic score has run-to-run noise and is not a stability/safety certificate. If crashes, artifacts, unusual temperatures or fan noise occur, revert the vendor tool profile immediately."
    }

    $script:offlineAiHistory = @()
    $script:offlineAiLastTopic = 'general'
    function Get-OfflineAiReply($msg) {
        $m = $msg.ToLowerInvariant()
        if ($m -match '^(hi|hello|hey|yo|salam|سلام)\b') {
            $script:offlineAiLastTopic = 'general'
            return "Hey! I'm the offline gaming assistant. Ask naturally about getting more FPS, stutters/input delay, ping, hardware specs, benchmarks, engines, or overclock support. I can read local hardware data and use built-in expert rules without internet; I am not a cloud LLM."
        }
        if ($m -match 'thank|thanks|cheers|مرسی|ممنون') { return "No problem! Change one setting at a time and measure the result so we know what actually helped." }
        if ($m -match 'benchmark|performance test|test my pc|run a test|بنچمارک|تست عملکرد') {
            $script:offlineAiLastTopic = 'benchmark'
            return (Invoke-QuickBenchmark)
        }
        if ($m -match 'overclock|over.?clock|voltage|volt|clock speed|فرکانس|ولتاژ|اورکلاک') {
            $script:offlineAiLastTopic = 'overclock'
            return (Get-OverclockCompatibilityReport)
        }
        if ($m -match 'unreal|directx|vulkan|game engine|انجین|موتور بازی') {
            $script:offlineAiLastTopic = 'engine'
            $target = 'All Supported'
            if ($m -match 'unreal') { $target = 'Unreal Engine' }
            elseif ($m -match 'directx|direct x') { $target = 'DirectX' }
            elseif ($m -match 'vulkan') { $target = 'Vulkan' }
            return ((Get-EngineReport $target) + "`r`n`r`n" + (Get-EngineOptimizationGuide $target))
        }
        if ($m -match 'analy[sz]e|specs|hardware|my pc|my computer|system info|computer details|مشخصات|سیستمم|سخت افزار') {
            $script:offlineAiLastTopic = 'hardware'
            $h = Get-LocalHardwareProfile
            $advice = Format-LocalHardwareReport
            $advice += "`r`n`r`nLocal analysis:`r`n"
            if ($h.RamGB -gt 0 -and $h.RamGB -lt 8) { $advice += "- RAM is under 8 GB: keep background apps minimal; for Minecraft, start around 2-3 GB allocation and retest.`r`n" }
            elseif ($h.RamGB -lt 16 -and $h.RamGB -gt 0) { $advice += "- RAM is 8-16 GB: avoid allocating almost all RAM to a game; leave memory for Windows and launchers.`r`n" }
            else { $advice += '- Leave enough RAM for Windows and background apps; more game allocation is not automatically better.`r`n' }
            if ($h.Gpus -match '(?i)Intel UHD|Intel Graphics|Iris Xe' -and $h.Gpus -notmatch '(?i)Arc') { $advice += "- Integrated graphics detected: lower render distance/effects first and avoid heavy shaders for FPS-sensitive play.`r`n" }
            $advice += '- Use the Overclocking > Scan Hardware button to review whether vendor tuning tools are detected. Detection is not proof that firmware permits overclocking.'
            return $advice
        }
        if ($m -match 'input.?lag|input.?delay|mouse delay|keyboard delay|stutter|hitch|freeze|micro.?stutter|تاخیر ورودی|لگ|افت فریم') {
            $script:offlineAiLastTopic = 'stutter'
            $h = Get-LocalHardwareProfile
            $adviceLines = @(
                "Let's separate frame-time stutter from network lag. Detected GPU: $($h.Gpus).",
                '1. Log FPS/frame time during the hitch; note whether FPS drops at the same moment.',
                '2. Check Task Manager CPU, GPU, memory and disk during the event.',
                '3. For Minecraft chunk-load spikes, test a smaller render distance, close disk-heavy apps, and compare vanilla vs client on the same world.',
                '4. Keep the graphics driver current from the laptop maker or GPU vendor; change only one thing and retest.',
                "Tell me the game and what the FPS graph does, and I will narrow this down."
            )
            $advice = $adviceLines -join "`r`n"
            if ($h.RamGB -gt 0 -and $h.RamGB -lt 8) { $advice += "`r`nRAM is below 8 GB, so memory pressure may contribute." }
            return $advice
        }
        if ($m -match 'fps|frames per second|frame rate|more frames|graphics performance|اف پی اس|فریم') {
            $script:offlineAiLastTopic = 'fps'
            $h = Get-LocalHardwareProfile
            $advice = "For more FPS, I need the game and your current FPS for precise advice. Detected GPU: $($h.Gpus); RAM: $($h.RamGB) GB.`r`nTry this order:`r`n1. Use the laptop maker's plugged-in performance profile if available.`r`n2. Lower render distance, shadows, particles and post-processing one at a time.`r`n3. Close heavy background apps, but do not disable Defender, Windows Update, or essential services.`r`n4. Record average FPS and 1% lows in the same scene before/after each change.`r`n5. If FPS drops only while loading chunks/shaders, investigate stutter rather than applying random registry tweaks."
            if ($h.Gpus -match '(?i)Intel UHD|Intel Graphics|Iris Xe' -and $h.Gpus -notmatch '(?i)Arc') { $advice += "`r`nFor integrated Intel graphics: avoid shaders, try a lower render distance (e.g. 6-8) and keep V-Sync/frame limit matched to your display preference." }
            if ($m -match 'minecraft|bedwars|badlion') { $advice += "`r`nMinecraft/Bedwars: test the same client/world/server, keep render distance around 6-8 as a starting point, particles minimal, and avoid allocating all system RAM to Java." }
            if ($m -match 'cs2|counter.?strike') { $advice += "`r`nCS2: lower resolution/render scale and shadows first; keep mouse polling stable and check frame-time spikes before changing launch options." }
            return $advice
        }
        if ($m -match 'ping|latency|network delay|server delay|پینگ|پینگم') {
            $script:offlineAiLastTopic = 'ping'
            return "Network ping and input delay are different. Detected network settings cannot predict your ISP route. Test the same server several times, compare idle ping with ping during upload/download, and check Wi-Fi signal/interference. If FPS or frame time spikes when it feels delayed, it may be local stutter instead of ping. Registry tweaks cannot guarantee lower route latency or zero delay. Share the game/server and baseline ping to narrow it down."
        }
        if ($m -match 'ram|memory|disk|storage|low space|رم|حافظه') {
            $script:offlineAiLastTopic = 'memory'
            $h = Get-LocalHardwareProfile
            $driveName = [string]$env:SystemDrive
            $freeSpace = 'unknown'
            if ($null -ne $h.SystemDriveFreeGB) { $freeSpace = ([string]$h.SystemDriveFreeGB) + ' GB' }
            return ("Detected RAM: {0} GB; free space on {1}: {2}.`r`nCheck Task Manager while the issue happens. Avoid RAM-cleaner loops: they can create extra work and usually do not improve game performance. Keep sufficient free SSD space for paging, shader caches and updates." -f $h.RamGB, $driveName, $freeSpace)
        }
        if ($m -match 'driver|gpu|graphics card|video card|درایور|کارت گرافیک') {
            $script:offlineAiLastTopic = 'driver'
            $h = Get-LocalHardwareProfile
            return ("Detected GPU(s): {0}.`r`nUse the PC manufacturer driver page first for laptops, or the official Intel/AMD/NVIDIA source. Record the installed version, install one driver at a time, and keep a rollback path. A driver update is not guaranteed to improve every game." -f $h.Gpus)
        }
        if ($m -match 'bios|uefi|firmware|بایوس') {
            $script:offlineAiLastTopic = 'bios'
            return (Get-BiosGamingAudit)
        }
        if ($m -match 'adobe|photoshop|premiere|after effects|lightroom') {
            $script:offlineAiLastTopic = 'adobe'
            return "Use section 13 (Adobe Apps). Run 'Audit Adobe Bottlenecks' first to inspect RAM, system-drive space, common cache size and installed executables. If a compatible executable is detected, 'Apply Windows GPU Preference' can add a reversible per-app Windows preference; this is most useful on systems with a discrete GPU. It does not change project settings or guarantee faster exports."
        }
        if ($m -match 'what should i change|what now|how do i apply|apply it|do it|which setting|next step|چی کار کنم|بعدش چی') {
            switch ($script:offlineAiLastTopic) {
                'fps' { return 'Start with one reversible in-game change (render distance or shadows), then repeat the same scene and compare average FPS plus 1% lows. Tell me the game and current FPS to choose the next step.' }
                'ping' { return 'First collect a baseline: server hostname, average ping, and whether ping rises during upload/download. That tells us whether this is Wi-Fi, bufferbloat, or a route issue.' }
                'stutter' { return 'Capture what CPU/GPU/RAM/disk do during the hitch and whether FPS falls. That distinguishes chunk/shader loading, resource pressure, and input-only delay.' }
                'overclock' { return 'Open section 7 and click Scan Hardware + Verify OC Support. If a supported vendor tool is not detected or firmware support cannot be verified, leave manual voltage/clock controls untouched.' }
                default { return 'Tell me the game, your goal, and the current measurement (FPS/ping/temperature if available). I will pick a targeted test and explain how to undo the change.' }
            }
        }
        $script:offlineAiLastTopic = 'general'
        return "I can help with local hardware info, FPS/stutter, input delay, ping, RAM, drivers, engine runtimes, benchmarks and overclock capability checks. Try: 'I want more FPS in Minecraft', 'analyze my PC', 'run a benchmark', 'check Vulkan', 'BIOS audit', 'Adobe audit', or 'scan overclock support'. This is an offline expert system, not a generative LLM, so it uses built-in diagnostic rules instead of inventing free-form answers."
    }

    function Send-ChatMessage {
        $msg = $txtChatInput.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($msg)) { return }
        $chatHistory.AppendText("You: $msg`r`n`r`n")
        $txtChatInput.Clear()
        try {
            $reply = Get-OfflineAiReply $msg
            $chatHistory.AppendText("Offline Assistant: $reply`r`n`r`n")
            $script:offlineAiHistory += @(@{ role = 'user'; content = $msg }, @{ role = 'assistant'; content = $reply })
            if ($script:offlineAiHistory.Count -gt 12) { $script:offlineAiHistory = @($script:offlineAiHistory | Select-Object -Last 12) }
        } catch {
            $chatHistory.AppendText("Assistant error: $($_.Exception.Message)`r`n`r`n")
        }
        $chatHistory.SelectionStart = $chatHistory.Text.Length
        $chatHistory.ScrollToCaret()
        $txtChatInput.Focus()
    }

    $liveTimer = New-Object System.Windows.Forms.Timer
    $liveTimer.Interval = 5000
    $liveTimer.Add_Tick({
        try {
            $procs = Get-Process -Name "javaw","java" -ErrorAction SilentlyContinue
            if ($procs) { foreach ($p in $procs) { if ($p.PriorityClass -ne "High") { $p.PriorityClass = "High"; Log "[Live Mode] Boosted PID $($p.Id)" } } }
        } catch { Log "[Live Mode] WARNING: $($_.Exception.Message)" }
    })
    $chkLive.add_CheckedChangedX({
        if ($chkLive.Checked) { $liveTimer.Start(); $lblLiveStatus.Text = "Live Mode: ON"; $lblLiveStatus.ForeColor = $cGreen }
        else { $liveTimer.Stop(); $lblLiveStatus.Text = "Live Mode: OFF"; $lblLiveStatus.ForeColor = [System.Drawing.Color]::Gray }
    })
    $ramTimer = New-Object System.Windows.Forms.Timer
    $ramTimer.Interval = 300000
    $ramTimer.Add_Tick({ Clean-RamNow })
    $chkRamClean.add_CheckedChangedX({ if ($chkRamClean.Checked) { $ramTimer.Start() } else { $ramTimer.Stop() } })

    $script:pingBaseline = $null
    $pingMonitorTimer = New-Object System.Windows.Forms.Timer
    $pingMonitorTimer.Interval = 4000
    $pingMonitorTimer.Add_Tick({
        try {
            $server = if ($txtServer -and $txtServer.Text.Trim()) { $txtServer.Text.Trim() } else { "mc.hypixel.net" }
            $t = [NetProbe]::TestResolveAndConnect($server, 25565)
            if ($t -match "^OK:(\d+):(\d+):") {
                $ms = [int]$Matches[2]
                if ($null -eq $script:pingBaseline) { $script:pingBaseline = $ms }
                elseif ($ms -gt ($script:pingBaseline + 100)) {
                    Log "[Ping Monitor] SPIKE detected: ${ms}ms (baseline was $($script:pingBaseline)ms)"
                }
                $script:pingBaseline = [Math]::Round((($script:pingBaseline * 0.8) + ($ms * 0.2)), 0)
            }
        } catch {}
    })
    $chkPingMonitor.add_CheckedChangedX({
        if ($chkPingMonitor.Checked) { $script:pingBaseline = $null; $pingMonitorTimer.Start(); Log "[Ping Monitor] Started - watching for spikes over 100ms." }
        else { $pingMonitorTimer.Stop(); Log "[Ping Monitor] Stopped." }
    })
    $ramMeterTimer = New-Object System.Windows.Forms.Timer
    $ramMeterTimer.Interval = 2000
    $ramMeterTimer.Add_Tick({
        try {
            $os = Get-CimInstance Win32_OperatingSystem
            $used = [math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100)
            $lblRam.Text = "RAM: $used%"
        } catch {}
    })
    $ramMeterTimer.Start()
    $form.Add_FormClosing({
        $liveTimer.Stop(); $ramTimer.Stop(); $ramMeterTimer.Stop(); $pingMonitorTimer.Stop()
        try { [System.Windows.Forms.Application]::RemoveMessageFilter($script:wheelScrollFilter); $script:wheelScrollFilter.Dispose() } catch {}
    })
    $form.Add_Resize({
        # Preserve the currently visible offset while the viewport is resized.
        $keepScroll = [Math]::Max(0, -[int]$contentHost.AutoScrollPosition.Y)
        Resize-ContentHost
        if ($contentHost.AutoScroll) {
            Update-ContentScrollExtent
            $maxScroll = Get-ContentMaxScroll
            $keepScroll = [Math]::Min($maxScroll, $keepScroll)
            $script:scrollTarget = $keepScroll
            $script:wheelScrollFilter.SetPosition($keepScroll)
        }
    })
    $form.Add_Shown({
        Resize-ContentHost
        Update-ContentScrollExtent
        $script:scrollTarget = 0
        $script:wheelScrollFilter.SetPosition(0)
        if ($script:dashRows.Count -gt 0) { $contentHost.ScrollControlIntoView($script:dashRows[0]) }
        $contentHost.Refresh()
        $form.Refresh()
    })

    $btnRestorePoint.Add_Click((Wrap-Click { Log "Creating restore point..."; Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue; Checkpoint-Computer -Description "Manual" -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop; Log "Done." } "Restore Point"))
    $btnBenchmark.Add_Click((Wrap-Click { Show-SystemSummary; Write-ReportToLog '[LOOK Score] Benchmark result' (Invoke-QuickBenchmark) } "LOOK Score Benchmark"))
    $btnGpuDetect.Add_Click((Wrap-Click { Detect-Gpu } "Detect GPU"))
    $btnGpuOptimize.Add_Click((Wrap-Click { Optimize-Gpu } "Optimize GPU"))
    $btnOpenNvidiaPanel.Add_Click((Wrap-Click { Open-GraphicsControlPanel 'NVIDIA' } "Open NVIDIA Control Panel"))
    $btnOpenIntelPanel.Add_Click((Wrap-Click { Open-GraphicsControlPanel 'Intel' } "Open Intel Graphics Software"))
    $btnGraphicsGuide.Add_Click((Wrap-Click { Show-RecommendedGraphicsProfile } "Graphics Profile Guide"))
    $btnBloatRemove.Add_Click((Wrap-Click { Remove-Bloatware } "Remove Bloatware"))
    $btnTelemetry.Add_Click((Wrap-Click { Reduce-Telemetry } "Reduce Telemetry"))
    $btnTestPing.Add_Click((Wrap-Click { Test-ServerPing $txtServer.Text.Trim() $txtPort.Text.Trim() | Out-Null } "Test Ping"))
    $btnHitRegTest.Add_Click((Wrap-Click { Test-HitRegNetworkQuality } "HitReg Quality Test"))
    $btnLatencyOpenGameMode.Add_Click((Wrap-Click { Start-Process 'ms-settings:gaming-gamemode' } "Open Game Mode Settings"))
    $btnLatencyOptimize.Add_Click((Wrap-Click { Optimize-Network } "Safe TCP Baseline"))
    $btnNetInfo.Add_Click((Wrap-Click { Get-NetAdapter | Where-Object {$_.Status -eq "Up"} | ForEach-Object { Log "$($_.Name): $($_.LinkSpeed), MAC $($_.MacAddress)" } } "Adapter Info"))
    $btnNetAdapterTweak.Add_Click((Wrap-Click { Do-AdapterTweaksOnly } "Inspect Adapter Settings"))
    $btnNetReset.Add_Click((Wrap-Click { Reset-NetworkStack } "Reset Network Stack"))
    $btnIpRenew.Add_Click((Wrap-Click { Renew-IpAddress } "Renew IP"))
    $btnDnsApply.Add_Click((Wrap-Click { Apply-CustomDns } "Apply DNS"))
    $btnDnsTest.Add_Click((Wrap-Click { Test-DnsSpeed } "Test DNS"))
    $btnOcNvidia.Add_Click((Wrap-Click { Start-Process "https://www.msi.com/Landing/afterburner/graphics-cards" } "Open OC Tool"))
    $btnOcIntel.Add_Click((Wrap-Click { Start-Process "https://www.intel.com/content/www/us/en/download/17881/intel-extreme-tuning-utility-intel-xtu.html" } "Open XTU"))
    $btnOcCheck.Add_Click((Wrap-Click { Show-ClockSpeeds } "Check Clocks"))
    $btnOcSupportScan.Add_Click((Wrap-Click { $txtOcSupport.Text = Get-OverclockCompatibilityReport; Log "[Overclock] Read-only hardware capability scan completed. No settings changed." } "OC Support Scan"))
    $btnOcWizard.Add_Click((Wrap-Click { Start-SupportedTuningWorkflow } "Guided Tuning Wizard"))
    $btnOcStartWorkflow.Add_Click((Wrap-Click { Start-GuidedOCWorkflow } "Guided OC Baseline"))
    $btnOcValidateWorkflow.Add_Click((Wrap-Click { Compare-GuidedOCWorkflow } "Compare OC Score"))
    $btnOcPowerCheck.Add_Click((Wrap-Click { Check-NvidiaPowerLimit } "Check Power Limit"))
    $btnOcPowerMax.Add_Click((Wrap-Click { Set-NvidiaPowerLimitMax } "Set Power Limit"))
    $btnOcCpuBoost.Add_Click((Wrap-Click { Enable-SafeCpuBoost } "CPU Boost"))
    $btnOcGpuVendor.Add_Click((Wrap-Click { Apply-SafeGpuVendorTweaks } "GPU Vendor Tweaks"))
    $btnFPS.Add_Click((Wrap-Click { Optimize-FPS } "Boost FPS"))
    $btnGameTips.Add_Click((Wrap-Click { Show-GameModeTips } "Game Tips"))
    $btnDetectGames.Add_Click((Wrap-Click { Detect-GameClients } "Detect Games"))
    $btnPingStability.Add_Click((Wrap-Click { Enable-AntiSpikeMode } "Check Background Bandwidth"))
    $btnLookGamingMode.Add_Click((Wrap-Click { Apply-LookGamingMode } "LOOK GAMING MODE"))
    $btnRestoreGamingMode.Add_Click((Wrap-Click { Restore-LookGamingMode } "Restore Gaming Mode"))
    $btnPerformanceRadar.Add_Click((Wrap-Click { Invoke-PerformanceRadar } "LOOK Performance Radar"))
    $btnRefreshGameLibrary.Add_Click((Wrap-Click { Refresh-GameLibrary } "Refresh Game Library"))
    $btnOptimizeSelectedGame.Add_Click((Wrap-Click { if ($lvGames.SelectedItems.Count -eq 0) { Log '[Games] Select a game first.' } else { Optimize-GameEntries @($lvGames.SelectedItems | ForEach-Object { $_.Tag }) } } "Optimize Selected Game"))
    $btnOptimizeAllGames.Add_Click((Wrap-Click { Optimize-GameEntries @($script:gameCatalog) } "Optimize All Detected Games"))
    $btnLoadGameArt.Add_Click((Wrap-Click { Load-GameArtworkAsync } "Load Steam Game Artwork"))
    $btnCustom.Add_Click((Wrap-Click {
        $t = $txtCustom.Text.ToLower(); $ran = $false
        if ($t -match "tcp|network|ping") { Backup-Registry; Do-TcpTweaks; $ran = $true }
        if ($t -match "fps|graphics|game") { Backup-Registry; Do-FpsTweaks; $ran = $true }
        if ($t -match "gpu") { Optimize-Gpu; $ran = $true }
        if ($t -match "ram|memory|clean|cache") { Clean-RamNow; Clean-WindowsCaches; $ran = $true }
        if (-not $ran) { Log "Didn't recognize a category. Try: tcp, fps, gpu, ram, cache." }
    } "Custom Command"))
    $btnChatSend.Add_Click((Wrap-Click { Send-ChatMessage } "Chat Send"))
    $btnAiAnalyze.Add_Click((Wrap-Click { $txtChatInput.Text = "Analyze my PC"; Send-ChatMessage } "Offline AI Analyze PC"))
    $btnAiBenchmark.Add_Click((Wrap-Click { $txtChatInput.Text = "Run benchmark"; Send-ChatMessage } "Offline AI Benchmark"))
    $btnAiClear.Add_Click({ $chatHistory.Clear(); $script:offlineAiHistory = @(); $script:offlineAiLastTopic = 'general' })
    $btnEngineScan.Add_Click((Wrap-Click { Write-ReportToLog "[Game Engines] Scan: $($cmbEngineTarget.SelectedItem)" (Get-EngineReport ([string]$cmbEngineTarget.SelectedItem)) } "Game Engine Scan"))
    $btnEngineTips.Add_Click((Wrap-Click { Write-ReportToLog "[Game Engines] Guide: $($cmbEngineTarget.SelectedItem)" (Get-EngineOptimizationGuide ([string]$cmbEngineTarget.SelectedItem)) } "Engine Optimization Guide"))
    $btnEngineDxDiag.Add_Click((Wrap-Click { $dx = Join-Path $env:WINDIR 'System32\\dxdiag.exe'; if (Test-Path $dx) { Start-Process $dx } else { Log 'dxdiag.exe not found in the normal Windows system path.' } } "Open DirectX Diagnostics"))
    $btnEngineGraphics.Add_Click((Wrap-Click { Start-Process 'ms-settings:display-graphics' } "Open Graphics Settings"))
    $btnEngineBenchmark.Add_Click((Wrap-Click { Write-ReportToLog '[Benchmark] Lightweight CPU/RAM benchmark' (Invoke-QuickBenchmark) } "CPU RAM Benchmark"))
    $btnEngineApply.Add_Click((Wrap-Click { Apply-EngineWindowsOptimizations } "Apply Windows Engine Profile"))
    $btnEngineRestore.Add_Click((Wrap-Click { Restore-EngineWindowsOptimizations } "Restore Engine GPU Preferences"))
    $btnEngineOpenUnreal.Add_Click((Wrap-Click { Open-DetectedUnrealEditor } "Launch Unreal Editor"))
    $txtChatInput.Add_KeyDown({ if ($_.KeyCode -eq 'Enter') { Send-ChatMessage; $_.SuppressKeyPress = $true } })
    $btnPowerPlan.Add_Click((Wrap-Click { Set-LookPerformancePowerPlan } "LOOK Performance Power Plan"))
    $btnPowerRestore.Add_Click((Wrap-Click { Restore-LookPerformancePowerPlan } "Restore Previous Power Plan"))
    $btnCleanNow.Add_Click((Wrap-Click { Clean-RamNow } "Clean RAM"))
    $btnCleanCaches.Add_Click((Wrap-Click { Clean-WindowsCaches } "Clean Caches"))
    $btnBiosCheck.Add_Click((Wrap-Click { Show-FirmwareInfo } "BIOS Info"))
    $btnBiosRestart.Add_Click((Wrap-Click { Restart-ToUefi } "Restart UEFI"))
    $btnBiosAudit.Add_Click((Wrap-Click { Write-ReportToLog 'BIOS / UEFI gaming readiness' (Get-BiosGamingAudit) } "BIOS Gaming Audit"))
    $btnBiosSafeProfile.Add_Click((Wrap-Click { Apply-LookGamingMode } "BIOS Safe Windows Profile"))
    $btnBiosOemTool.Add_Click((Wrap-Click { Open-OemPerformanceUtility } "Open OEM Performance Utility"))
    $btnAdobeDetect.Add_Click((Wrap-Click { Detect-AdobeApps } "Detect Adobe"))
    $btnAdobeCache.Add_Click((Wrap-Click { Clear-AdobeCache } "Clear Adobe Cache"))
    $btnAdobePerf.Add_Click((Wrap-Click { Apply-AdobePerfTweaks } "Adobe GPU Profile"))
    $btnAdobeAudit.Add_Click((Wrap-Click { Test-AdobePerformanceReadiness } "Adobe Bottleneck Audit"))
    $btnAdobeRestoreGpu.Add_Click((Wrap-Click { Restore-AdobeGpuPreferences } "Restore Adobe GPU Preferences"))
    $btnAdobeOpenGraphics.Add_Click((Wrap-Click { Start-Process 'ms-settings:display-graphics' } "Open Windows Graphics Settings"))
    $cmbTheme.Add_SelectedIndexChanged({ if ($cmbTheme.SelectedItem) { Apply-UiTheme ([string]$cmbTheme.SelectedItem) } })
    try {
        $themeFile = Join-Path (Join-Path $env:LOCALAPPDATA 'LookAtTheLatency') 'preferences.json'
        if (Test-Path -LiteralPath $themeFile) {
            $savedTheme = Get-Content -LiteralPath $themeFile -Raw | ConvertFrom-Json
            if ($savedTheme.Theme -and $cmbTheme.Items.Contains([string]$savedTheme.Theme)) { $cmbTheme.SelectedItem = [string]$savedTheme.Theme }
        }
    } catch {}
    if (-not $cmbTheme.SelectedItem) { $cmbTheme.SelectedItem = 'Emerald' }
    Apply-UiTheme ([string]$cmbTheme.SelectedItem)
    $btnRestoreDefaults.Add_Click((Wrap-Click { Restore-Defaults } "Restore Defaults"))

    $form.Add_FormClosed({
        try { Dispose-UiSounds } catch {}
        try { if ($script:sectionEntranceTimer) { $script:sectionEntranceTimer.Stop(); $script:sectionEntranceTimer.Dispose() } } catch {}
        try { foreach ($uiTimer in $script:uiAnimationTimers) { if ($uiTimer) { $uiTimer.Stop(); $uiTimer.Dispose() } } } catch {}
        try { if ($script:wheelScrollFilter) { [System.Windows.Forms.Application]::RemoveMessageFilter($script:wheelScrollFilter); $script:wheelScrollFilter.Dispose() } } catch {}
    })
    Show-Dashboard
    [void]$form.ShowDialog()

} catch {
    $caughtError = $_
    $errorText = "Unexpected error:`r`n$($caughtError.Exception.Message)`r`n`r`n$($caughtError.InvocationInfo.PositionMessage)`r`n`r`n$($caughtError.ScriptStackTrace)"
    $errorLog = Join-Path $env:TEMP 'LookAtTheLatency-startup-error.log'
    try {
        Add-Content -LiteralPath $errorLog -Value ("[{0}]`r`n{1}`r`n---`r`n" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $errorText) -Encoding UTF8
    } catch {}
    try { [Console]::Error.WriteLine($errorText) } catch {}
    try {
        $displayMessage = "The app hit an error. Details were saved to:`r`n{0}`r`n`r`n{1}`r`n`r`n{2}" -f $errorLog, $caughtError.Exception.Message, $caughtError.InvocationInfo.PositionMessage
        [void][System.Windows.Forms.MessageBox]::Show($displayMessage, 'Look at the Latency - Error', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::None)
    } catch {}
}
