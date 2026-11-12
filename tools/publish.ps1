# 用法（在「聽力第四輯」資料夾執行）：
#   powershell -ExecutionPolicy Bypass -File tools\publish.ps1            加密並推送到 GitHub
#   powershell -ExecutionPolicy Bypass -File tools\publish.ps1 -NoPush    只加密，不推送
#
# 讀取：src\index.html（原始網頁，不會上傳）、accounts.txt（帳號:密碼，不會上傳）
# 產生：index.html（加密後的網頁 + 登入畫面）
param([switch]$NoPush, [string]$Message = "Update encrypted page")
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$utf8 = New-Object Text.UTF8Encoding($false)

$srcPath = Join-Path $root 'src\index.html'
$accPath = Join-Path $root 'accounts.txt'
$tplPath = Join-Path $PSScriptRoot 'login-template.html'
$outPath = Join-Path $root 'index.html'

$accounts = @(Get-Content -Encoding UTF8 $accPath | ForEach-Object { $_.Trim([char]0xFEFF).Trim() } |
  Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object {
    $i = $_.IndexOf(':'); if ($i -lt 1) { throw "accounts.txt 格式錯誤：$_" }
    @{ u = $_.Substring(0, $i).Trim(); p = $_.Substring($i + 1) } })
if ($accounts.Count -eq 0) { throw 'accounts.txt 裡沒有帳號' }

function RandBytes($n) { $b = New-Object byte[] $n; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); $b }
function AesCbc([byte[]]$key, [byte[]]$iv, [byte[]]$data) {
  $a = [Security.Cryptography.Aes]::Create(); $a.Mode = 'CBC'; $a.Padding = 'PKCS7'; $a.Key = $key; $a.IV = $iv
  $e = $a.CreateEncryptor(); $r = $e.TransformFinalBlock($data, 0, $data.Length); $a.Dispose(); $r }
$B64 = { param($b) [Convert]::ToBase64String($b) }

$iter = 600000
$salt = RandBytes 16
$magic = RandBytes 16
$contentKey = RandBytes 32
$iv = RandBytes 16
$ct = AesCbc $contentKey $iv ($utf8.GetBytes([IO.File]::ReadAllText($srcPath, $utf8)))

$keys = foreach ($a in $accounts) {
  $kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes(($utf8.GetBytes($a.u + "`n" + $a.p)), $salt, $iter, [Security.Cryptography.HashAlgorithmName]::SHA256)
  $dk = $kdf.GetBytes(32); $kdf.Dispose()
  $wiv = RandBytes 16
  '{"iv":"' + (& $B64 $wiv) + '","ct":"' + (& $B64 (AesCbc $dk $wiv ($contentKey + $magic))) + '"}'
}
$payload = '{"iter":' + $iter + ',"salt":"' + (& $B64 $salt) + '","magic":"' + (& $B64 $magic) + '","iv":"' + (& $B64 $iv) + '","ct":"' + (& $B64 $ct) + '","keys":[' + ($keys -join ',') + ']}'

$tpl = [IO.File]::ReadAllText($tplPath, $utf8)
if (-not $tpl.Contains('/*PAYLOAD*/null')) { throw 'login-template.html 少了 /*PAYLOAD*/null' }
[IO.File]::WriteAllText($outPath, $tpl.Replace('/*PAYLOAD*/null', $payload), $utf8)
Write-Host "已產生加密的 index.html（帳號數：$($accounts.Count)）"

if (-not $NoPush) {
  $git = 'C:\Program Files\Git\cmd\git.exe'
  Push-Location $root
  try {
    & $git add -A
    & $git commit -m $Message
    & $git push origin main
  } finally { Pop-Location }
}
