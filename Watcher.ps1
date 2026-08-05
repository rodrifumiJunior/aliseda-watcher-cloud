# Watcher.ps1
# Comprueba todas las zonas configuradas en config.json contra la API publica de Aliseda,
# y notifica (toast de Windows) los inmuebles nuevos y las bajadas de precio.
# La primera vez que se vigila una zona no se notifica nada: solo se guarda la foto inicial.

. (Join-Path $PSScriptRoot 'Common.ps1')

function Send-Toast {
    param([string]$Title, [string]$Message, [string]$Url)
    if ($IsLinux -or $IsMacOS) { return }
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null

        $safeTitle = Escape-Xml $Title
        $safeMessage = Escape-Xml $Message
        $safeUrl = Escape-Xml $Url

        [xml]$template = @"
<toast activationType="protocol" launch="$safeUrl">
  <visual>
    <binding template="ToastGeneric">
      <text>$safeTitle</text>
      <text>$safeMessage</text>
    </binding>
  </visual>
  <actions>
    <action content="Ver anuncio" activationType="protocol" arguments="$safeUrl" />
  </actions>
</toast>
"@
        $xmlDoc = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xmlDoc.LoadXml($template.OuterXml)
        $toast = New-Object Windows.UI.Notifications.ToastNotification $xmlDoc
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
    } catch {
        Write-Log "AVISO: no se pudo mostrar la notificacion ('$Title'): $($_.Exception.Message)"
    }
}

function Get-Listings {
    param([int]$Tipo, [string]$Comunidad, [string]$Provincia, [string]$Localidad)

    $results = @{}
    $page = 1
    $lastPage = 1
    $maxPages = 300

    do {
        $qs = "tipo=$Tipo&page=$page"
        if ($Comunidad) { $qs += "&comunidad=$Comunidad" }
        if ($Provincia) { $qs += "&provincia=$Provincia" }
        if ($Localidad) { $qs += "&localidad=$Localidad" }
        $resp = Invoke-AlisedaApi "$ApiBase/v2/new-search?$qs"
        if (-not $resp -or -not $resp.data) { break }

        foreach ($item in $resp.data) {
            $precio = $null
            if ($item.operacion) { $precio = $item.operacion.Precio }
            $ciudad = $null
            $provinciaNombre = $null
            if ($item.address) {
                $ciudad = $item.address.Ciudad
                if ($item.address.provincia) { $provinciaNombre = $item.address.provincia.Nombre }
            }
            $desc = $item.Description
            if ($desc -and $desc.Length -gt 90) { $desc = $desc.Substring(0, 90) + '...' }
            $estado = Format-Estado -Posesion $item.posesion -Particular $item.Particular

            $results[[string]$item.id] = [PSCustomObject]@{
                Precio      = $precio
                Ciudad      = $ciudad
                Provincia   = $provinciaNombre
                Descripcion = $desc
                Estado      = $estado
                Url         = "$SiteBase/inmueble/$($item.id)"
            }
        }

        if ($resp.last_page) { $lastPage = [int]$resp.last_page }
        $page++
        Start-Sleep -Milliseconds 300
    } while ($page -le $lastPage -and $page -le $maxPages)

    if ($lastPage -gt $maxPages) {
        Write-Log "AVISO: la zona tiene mas de $maxPages paginas de resultados; solo se han revisado las primeras. Considera acotar por provincia/localidad."
    }

    return $results
}

# ---- Main ----
# Bloqueo para evitar que dos comprobaciones se ejecuten a la vez (por ejemplo si una
# ejecucion manual se solapa con la tarea programada porque la lista de zonas es grande
# y tarda mas de lo esperado).

$lockPath = Join-Path $PSScriptRoot 'watcher.lock'
if (Test-Path $lockPath) {
    $lockPid = Get-Content $lockPath -Raw -ErrorAction SilentlyContinue
    $lockProc = $null
    if ($lockPid -match '^\d+$') { $lockProc = Get-Process -Id ([int]$lockPid) -ErrorAction SilentlyContinue }
    if ($lockProc) {
        Write-Log "Ya hay una comprobacion en curso (PID $lockPid). Saliendo para no solapar."
        return
    } else {
        Write-Log "AVISO: bloqueo antiguo sin proceso activo detectado; se ignora y se continua."
    }
}
Set-Content -Path $lockPath -Value $PID -Encoding ASCII

try {

$config = Load-Config
if (-not $config -or -not $config.watches -or $config.watches.Count -eq 0) {
    Write-Log "No hay zonas configuradas todavia. Ejecuta Configurar.ps1 primero."
    return
}

$state = Load-State
$totalNuevos = 0
$totalBajadas = 0

foreach ($watch in $config.watches) {
    foreach ($tipo in $watch.tipos) {
        $c = if ($watch.comunidad) { $watch.comunidad } else { '_' }
        $p = if ($watch.provincia) { $watch.provincia } else { '_' }
        $l = if ($watch.localidad) { $watch.localidad } else { '_' }
        $watchKey = "$c|$p|$l|$tipo"

        Write-Log "Consultando: $($watch.label) [$($TipoMap[[string]$tipo])] ..."
        $current = Get-Listings -Tipo $tipo -Comunidad $watch.comunidad -Provincia $watch.provincia -Localidad $watch.localidad
        Write-Log "  -> $($current.Count) anuncios encontrados"

        $previous = Get-DynProp $state $watchKey

        if (-not $previous) {
            Write-Log "  -> primera vez que se vigila esta zona/tipo: guardando fotografia inicial (sin notificar)"
        } else {
            foreach ($id in $current.Keys) {
                $item = $current[$id]
                $old = Get-DynProp $previous $id

                if (-not $old) {
                    $totalNuevos++
                    $precioTxt = Format-Precio $item.Precio
                    $estadoTxt = if ($item.Estado) { " ($($item.Estado))" } else { "" }
                    Send-Toast -Title "Nuevo anuncio: $($item.Ciudad), $($item.Provincia)" `
                                -Message "$precioTxt$estadoTxt - $($item.Descripcion)" `
                                -Url $item.Url
                    $estadoLinea = if ($item.Estado) { "`n$(Escape-Xml $item.Estado)" } else { "" }
                    $tgText = "🏠 <b>Nuevo anuncio</b>`n$(Escape-Xml $item.Ciudad), $(Escape-Xml $item.Provincia)`n$precioTxt$estadoLinea`n$(Escape-Xml $item.Descripcion)`n<a href=`"$($item.Url)`">Ver anuncio</a>"
                    Send-Telegram -Config $config -Text $tgText
                    Write-Log "  NUEVO: $id ($($item.Ciudad)) $precioTxt"
                } elseif ($item.Precio -ne $null -and $old.Precio -ne $null -and [double]$item.Precio -lt [double]$old.Precio) {
                    $totalBajadas++
                    $precioAnt = Format-Precio $old.Precio
                    $precioNuevo = Format-Precio $item.Precio
                    $estadoTxt = if ($item.Estado) { " ($($item.Estado))" } else { "" }
                    Send-Toast -Title "Bajada de precio: $($item.Ciudad), $($item.Provincia)" `
                                -Message "$precioAnt -> $precioNuevo$estadoTxt - $($item.Descripcion)" `
                                -Url $item.Url
                    $estadoLinea = if ($item.Estado) { "`n$(Escape-Xml $item.Estado)" } else { "" }
                    $tgText = "📉 <b>Bajada de precio</b>`n$(Escape-Xml $item.Ciudad), $(Escape-Xml $item.Provincia)`n$precioAnt &#8594; $precioNuevo$estadoLinea`n$(Escape-Xml $item.Descripcion)`n<a href=`"$($item.Url)`">Ver anuncio</a>"
                    Send-Telegram -Config $config -Text $tgText
                    Write-Log "  BAJADA: $id ($($item.Ciudad)) $precioAnt -> $precioNuevo"
                }
            }
        }

        # Guarda la foto actual completa como nuevo estado de referencia para esta zona/tipo
        $newWatchState = New-Object PSObject
        foreach ($id in $current.Keys) {
            $newWatchState | Add-Member -NotePropertyName $id -NotePropertyValue $current[$id]
        }
        if ($state.PSObject.Properties[$watchKey]) {
            $state.$watchKey = $newWatchState
        } else {
            $state | Add-Member -NotePropertyName $watchKey -NotePropertyValue $newWatchState
        }
    }
}

Save-State -State $state
Write-Log "Comprobacion terminada. Nuevos: $totalNuevos. Bajadas de precio: $totalBajadas."

} finally {
    Remove-Item -Path $lockPath -Force -ErrorAction SilentlyContinue
}
