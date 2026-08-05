# Funciones y rutas compartidas. Version para GitHub Actions (Linux) del proyecto local aliseda-watcher.

$Script:RootDir    = $PSScriptRoot
$Script:ConfigPath = Join-Path $RootDir 'config.json'
$Script:StatePath  = Join-Path $RootDir 'state.json'
$Script:LogPath    = Join-Path $RootDir 'watcher.log'
$Script:ApiBase    = 'https://laravel.alisedainmobiliaria.com/api'
$Script:SiteBase   = 'https://alisedainmobiliaria.com'
$Script:UserAgent  = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AlisedaWatcher/1.0'

# Orden igual al que expone la propia web en get-allowed-filters
# NOTA: las claves son texto a proposito. [ordered]@{} usa un OrderedDictionary,
# que tiene un indexador por posicion ademas del indexador por clave; si las claves
# fueran enteros, $TipoMap[10] se interpretaria como "posicion 10" en vez de "clave 10".
$Script:TipoMap = [ordered]@{
    '10' = 'Viviendas'
    '2'  = 'Garajes'
    '9'  = 'Trasteros'
    '1'  = 'Locales'
    '4'  = 'Naves'
    '6'  = 'Oficinas'
    '8'  = 'Terrenos'
    '5'  = 'Obras paradas'
    '3'  = 'Edificios'
    '11' = 'Negocios'
    '7'  = 'Otros'
}

function Write-Log {
    param([string]$Message)
    $line = "[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $Message
    Write-Host $line
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
}

function Invoke-AlisedaApi {
    param([Parameter(Mandatory)][string]$Url)
    try {
        $resp = Invoke-WebRequest -Uri $Url -Headers @{ 'User-Agent' = $UserAgent } -TimeoutSec 25 -UseBasicParsing
        # La API de Aliseda devuelve a veces "Description" y "description" en el mismo objeto.
        # ConvertFrom-Json no distingue mayusculas/minusculas en claves y falla con ese choque,
        # asi que renombramos la duplicada en minuscula antes de parsear.
        $sanitized = $resp.Content -creplace '"description":', '"description_dup":'
        return $sanitized | ConvertFrom-Json
    } catch {
        Write-Log "AVISO: fallo al consultar $Url -> $($_.Exception.Message)"
        return $null
    }
}

function Get-DynProp {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Escape-Xml {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $Text = $Text -replace '&', '&amp;'
    $Text = $Text -replace '<', '&lt;'
    $Text = $Text -replace '>', '&gt;'
    $Text = $Text -replace '"', '&quot;'
    return $Text
}

function Format-Estado {
    param($Posesion, $Particular)
    $etiquetas = @{
        'LIBRE'                  = 'Libre'
        'CON POSESION'           = 'Con posesion'
        'SIN POSESION'           = 'Sin posesion'
        'ALQUILADO'              = 'Alquilado'
        'ALQUILADO JUDICIALIZADO'= 'Alquilado (judicializado)'
        'OKUPADO'                = 'Ocupado'
    }
    $texto = $null
    if ($Posesion -and $etiquetas.ContainsKey([string]$Posesion)) {
        $texto = $etiquetas[[string]$Posesion]
    } elseif ($Posesion) {
        $texto = [string]$Posesion
    }
    $esParticular = ([string]$Particular -eq '1')
    if ($texto -and $esParticular) { return "$texto - Particular" }
    if ($texto) { return $texto }
    if ($esParticular) { return 'Particular' }
    return $null
}

function Format-Precio {
    param($Precio)
    if ($null -eq $Precio) { return 's/p' }
    $culture = [System.Globalization.CultureInfo]::GetCultureInfo('es-ES')
    return "{0} €" -f ([double]$Precio).ToString('N0', $culture)
}

function Load-Config {
    if (-not (Test-Path $ConfigPath)) { return $null }
    return Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Save-Config {
    param($Config)
    $Config | ConvertTo-Json -Depth 8 | Set-Content -Path $ConfigPath -Encoding UTF8
}

function Load-State {
    if (-not (Test-Path $StatePath)) { return New-Object PSObject }
    $raw = Get-Content -Path $StatePath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return New-Object PSObject }
    return $raw | ConvertFrom-Json
}

function Save-State {
    param($State)
    $State | ConvertTo-Json -Depth 10 | Set-Content -Path $StatePath -Encoding UTF8
}

function Get-TelegramChatIds {
    param($Telegram)
    if ($env:TELEGRAM_CHAT_IDS) {
        return @($env:TELEGRAM_CHAT_IDS -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    if (-not $Telegram) { return @() }
    $ids = Get-DynProp $Telegram 'chatIds'
    if ($ids) { return @($ids) }
    $single = Get-DynProp $Telegram 'chatId'
    if ($single) { return @($single) }
    return @()
}

function Get-TelegramToken {
    param($Telegram)
    if ($env:TELEGRAM_BOT_TOKEN) { return $env:TELEGRAM_BOT_TOKEN }
    return Get-DynProp $Telegram 'botToken'
}

function Send-Telegram {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Text)
    $tg = Get-DynProp $Config 'telegram'
    $token = Get-TelegramToken -Telegram $tg
    $chatIds = Get-TelegramChatIds -Telegram $tg
    if (-not $token -or $chatIds.Count -eq 0) { return }
    foreach ($chatId in $chatIds) {
        try {
            Invoke-RestMethod -Uri "https://api.telegram.org/bot$token/sendMessage" -Method Post -Body @{
                chat_id    = $chatId
                text       = $Text
                parse_mode = 'HTML'
            } -TimeoutSec 15 | Out-Null
        } catch {
            Write-Log "AVISO: fallo al enviar notificacion de Telegram a $chatId -> $($_.Exception.Message)"
        }
    }
}

function Get-CommunityList {
    param([int]$Typology = 10)
    $data = Invoke-AlisedaApi "$ApiBase/get-allowed-filters?type=list&listType=properties&typology=$Typology"
    if (-not $data) { return @() }
    return $data.communities
}

function Get-ProvinceList {
    param([int]$Typology = 10, [Parameter(Mandatory)][string]$CommunitySlug)
    $data = Invoke-AlisedaApi "$ApiBase/get-allowed-filters?type=list&listType=properties&typology=$Typology&community=$CommunitySlug"
    if (-not $data) { return @() }
    return $data.provinces
}

function Get-MunicipalityList {
    param([int]$Typology = 10, [Parameter(Mandatory)][string]$CommunitySlug, [Parameter(Mandatory)][string]$ProvinceSlug)
    $data = Invoke-AlisedaApi "$ApiBase/get-allowed-filters?type=list&listType=properties&typology=$Typology&community=$CommunitySlug&province=$ProvinceSlug"
    if (-not $data) { return @() }
    return $data.municipalities
}
