param(
    [string]$Repository = $env:GITHUB_REPOSITORY,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '../out'),
    [switch]$CheckOnly,
    [switch]$DownloadOnly
)
$ErrorActionPreference = 'Stop'
$env:GODEBUG = 'http2client=0'
$pageUrl = 'https://www.sysceo.com/software-softwarei-id-258.html'

function Read-OfficialRelease {
    param([string]$Html)
    $plain = [Net.WebUtility]::HtmlDecode(($Html -replace '<[^>]+>', ' '))
    $version = [regex]::Match($plain, '版本\s*[:：]\s*(\d+(?:\.\d+){1,3})')
    $md5 = [regex]::Match($plain, '当前文件MD5值\s*[:：]\s*([a-fA-F0-9]{32})')
    $links = @(
        foreach ($a in [regex]::Matches($Html, '(?is)<a\b[^>]*\bhref=["''](?<url>[^"'']+)["''][^>]*>(?<text>.*?)</a>')) {
            $label = [Net.WebUtility]::HtmlDecode(($a.Groups['text'].Value -replace '<[^>]+>', ' '))
            if ($label -match '普通下载') { [Net.WebUtility]::HtmlDecode($a.Groups['url'].Value) }
        }
    ) | Select-Object -Unique
    if (-not $version.Success -or -not $md5.Success -or @($links).Count -ne 1) {
        throw 'Official page must provide exactly one normal download link, version, and MD5.'
    }
    $links = @($links)
    $uri = [uri]$links[0]
    if ($uri.Scheme -ne 'https' -or -not $uri.AbsolutePath.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Official installer link is not an HTTPS executable.'
    }
    [pscustomobject]@{ Version=$version.Groups[1].Value; MD5=$md5.Groups[1].Value.ToUpperInvariant(); Url=$uri.AbsoluteUri }
}

function Invoke-Gh {
    param([string[]]$Arguments, [switch]$AllowFailure)
    $saved = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& gh @Arguments 2>&1)
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $saved }
    if ($code -ne 0 -and -not $AllowFailure) { throw ('gh failed: ' + ($output -join [Environment]::NewLine)) }
    if ($code -eq 0) { return ($output -join [Environment]::NewLine) }
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$response = Invoke-WebRequest -Uri $pageUrl -TimeoutSec 30 -MaximumRedirection 0 -UseBasicParsing
$release = Read-OfficialRelease -Html $response.Content
Write-Host ('Official version: ' + $release.Version + '; MD5: ' + $release.MD5)
if ($CheckOnly) { $release; return }
if (-not $DownloadOnly -and $Repository -notmatch '^[\w.-]+/[\w.-]+$') { throw 'Repository is required.' }
[void][IO.Directory]::CreateDirectory($OutputDirectory)

# Only skip when the published manifest and GitHub's asset digest agree.
if (-not $DownloadOnly) {
    $previousJson = Invoke-Gh -Arguments @('release','view','--repo',$Repository,'--json','tagName,assets') -AllowFailure
    if ($previousJson) {
        $previous = $previousJson | ConvertFrom-Json
        $manifestAsset = @($previous.assets | Where-Object name -eq 'manifest.json')
        $exeAsset = @($previous.assets | Where-Object name -eq 'DrvCeo.exe')
        if ($manifestAsset.Count -eq 1 -and $exeAsset.Count -eq 1) {
            $previousFile = Join-Path $OutputDirectory 'manifest.json'
            Invoke-Gh -Arguments @('release','download',$previous.tagName,'--repo',$Repository,'--pattern','manifest.json','--dir',$OutputDirectory,'--clobber') | Out-Null
            $old = Get-Content -LiteralPath $previousFile -Raw | ConvertFrom-Json
            if ($old.version -eq $release.Version -and $old.md5 -eq $release.MD5 -and
                $exeAsset[0].digest -eq ('sha256:' + $old.sha256.ToLowerInvariant()) -and $exeAsset[0].size -eq $old.size) {
                Write-Host 'Latest verified installer already published; no changes.'
                if ($env:GITHUB_STEP_SUMMARY) { Add-Content $env:GITHUB_STEP_SUMMARY ('No update: ' + $release.Version) }
                return
            }
        }
    }
}

$exe = Join-Path $OutputDirectory 'DrvCeo.exe'
$part = $exe + '.part'
try {
    & curl.exe --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 20 --max-time 300 --retry 2 --max-filesize 536870912 --output $part $release.Url
    if ($LASTEXITCODE -ne 0) { throw 'Official installer download failed.' }
    if ((Get-Item -LiteralPath $part).Length -lt 1MB) { throw 'Installer is unexpectedly small.' }
    if ((Get-FileHash -LiteralPath $part -Algorithm MD5).Hash -ne $release.MD5) { throw 'Official MD5 mismatch; will not publish.' }
    Move-Item -LiteralPath $part -Destination $exe -Force
} finally { if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force } }

$sig = Get-AuthenticodeSignature -LiteralPath $exe
if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notlike '*Jiangmen Eyun Network Co., Ltd.*') {
    throw ('Publisher verification failed; will not publish. Status=' + $sig.Status)
}
$sha = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()
$size = (Get-Item -LiteralPath $exe).Length
$fileVersion = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion
$manifest = [ordered]@{
    version=$release.Version; fileVersion=$fileVersion; asset='DrvCeo.exe'; size=$size
    md5=$release.MD5; sha256=$sha; sourcePage=$pageUrl; sourceUrl=$release.Url
    publisher=$sig.SignerCertificate.Subject; certificateThumbprint=$sig.SignerCertificate.Thumbprint
    verifiedAtUtc=[DateTime]::UtcNow.ToString('o')
}
$utf8 = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'manifest.json'), ($manifest | ConvertTo-Json -Depth 4), $utf8)
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'SHA256SUMS.txt'), ($sha + '  DrvCeo.exe' + [Environment]::NewLine), $utf8)
if ($DownloadOnly) { Write-Host 'Downloaded and verified. Nothing was installed or published.'; return }

# Publish a complete draft, then make it latest. Older verified releases stay available.
$tag = 'v' + $release.Version + '-' + $sha.Substring(0,12)
$existing = Invoke-Gh -Arguments @('release','view',$tag,'--repo',$Repository,'--json','isDraft') -AllowFailure
if (-not $existing) {
    Invoke-Gh -Arguments @('release','create',$tag,'--repo',$Repository,'--draft','--title',('DrvCeo ' + $release.Version),'--notes',('Official installer mirror. MD5 and Authenticode publisher verified. SHA256: ' + $sha)) | Out-Null
} elseif (-not ($existing | ConvertFrom-Json).isDraft) {
    throw 'A published release with this hash already exists but latest metadata differed. Manual review required.'
}
Invoke-Gh -Arguments @('release','upload',$tag,'--repo',$Repository,$exe,(Join-Path $OutputDirectory 'manifest.json'),(Join-Path $OutputDirectory 'SHA256SUMS.txt'),'--clobber') | Out-Null
Invoke-Gh -Arguments @('release','edit',$tag,'--repo',$Repository,'--draft=false','--latest') | Out-Null
$published = (Invoke-Gh -Arguments @('release','view',$tag,'--repo',$Repository,'--json','assets')) | ConvertFrom-Json
$uploaded = @($published.assets | Where-Object name -eq 'DrvCeo.exe')
if ($uploaded.Count -ne 1 -or $uploaded[0].digest -ne ('sha256:' + $sha) -or $uploaded[0].size -ne $size) {
    throw 'Published asset digest or size mismatch.'
}
Write-Host ('Published and verified: ' + $tag)
if ($env:GITHUB_STEP_SUMMARY) { Add-Content $env:GITHUB_STEP_SUMMARY ('Published ' + $release.Version + ' — SHA256: `' + $sha + '`') }
