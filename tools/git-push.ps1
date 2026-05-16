# git-push.ps1 — push 时自动套用 Windows 系统代理 (Clash Verge / v2rayN 等),
# 不需要硬编码端口. 关闭系统代理后自动不带代理 (会失败但不会用错端口).
#
# 用法: pwsh tools/git-push.ps1 [其余 git push 参数]
#
# 实现: 从 HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings
# 读取 ProxyEnable / ProxyServer, 用 -c http.proxy / -c https.proxy 临时套给
# 本次 git 子进程, 不污染全局 config.

$ErrorActionPreference = 'Stop'

$regPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$enable = (Get-ItemProperty -Path $regPath -Name ProxyEnable -ErrorAction SilentlyContinue).ProxyEnable
$server = (Get-ItemProperty -Path $regPath -Name ProxyServer -ErrorAction SilentlyContinue).ProxyServer

$gitArgs = @()
if ($enable -eq 1 -and -not [string]::IsNullOrWhiteSpace($server)) {
    # ProxyServer 可能形如 '127.0.0.1:7897' 或 'http=...;https=...;ftp=...'
    $proxy = $null
    if ($server -match '^[^;=]+:\d+$') {
        $proxy = $server
    } elseif ($server -match 'https=([^;]+)') {
        $proxy = $matches[1]
    } elseif ($server -match 'http=([^;]+)') {
        $proxy = $matches[1]
    }
    if ($proxy) {
        if ($proxy -notmatch '^https?://') { $proxy = "http://$proxy" }
        Write-Host "[git-push] 系统代理生效: $proxy"
        $gitArgs += @('-c', "http.proxy=$proxy", '-c', "https.proxy=$proxy")
    } else {
        Write-Host "[git-push] 无法解析 ProxyServer='$server', 直连尝试."
    }
} else {
    Write-Host "[git-push] 系统代理未启用, 直连尝试."
}

$gitArgs += @('push') + $args
& git @gitArgs
exit $LASTEXITCODE
