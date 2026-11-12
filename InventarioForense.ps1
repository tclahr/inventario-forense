<#
.SYNOPSIS
    InventarioForense.ps1 - Coleta de inventario e vestigios de uma estacao Windows.

.DESCRIPTION
    Coleta, em modo somente leitura, informacoes de hardware, sistema, contas,
    software, rede, eventos e vestigios de uso de uma estacao Windows, e grava
    o resultado (TXT, JSON, CSV, log e manifesto SHA-256) em uma pasta e em um
    arquivo ZIP com o mesmo nome.

    Compativel com Windows PowerShell 5.1.

    Versao : 1.0.0
    Autor  : Thiago Canozzo Lahr <thiago@peritoemti.com.br>

    Copyright 2026 Thiago Canozzo Lahr
    Licenciado sob a Apache License 2.0 (veja o arquivo LICENSE).

    Repositorio (ultima versao): https://github.com/tclahr/inventario-forense

.PARAMETER Etiqueta
    Identificador livre do equipamento (por exemplo, numero de patrimonio).

.PARAMETER Setor
    Setor ou local onde o equipamento se encontra.

.PARAMETER ExecutadoPor
    Nome de quem executa a coleta (opcional).

.PARAMETER Observacao
    Texto livre registrado junto com a coleta.

.PARAMETER Completa
    Inclui as fontes mais demoradas ou volumosas.

.NOTES
    Codigos de saida:
      0 - coleta concluida e ZIP verificado contra o manifesto.
      1 - a verificacao do ZIP falhou (ou o manifesto/ZIP nao foi gerado); a pasta e mantida.
      2 - a pasta do script nao aceita escrita; nada foi gravado.
      3 - coleta incompleta: um erro inesperado interrompeu as areas; o ZIP foi gerado e verificado.

.EXAMPLE
    .\InventarioForense.ps1 -Etiqueta 'PAT-0001' -Setor 'Financeiro'

.EXAMPLE
    .\InventarioForense.ps1 -Completa -Observacao 'Coleta apos troca de disco'
#>

#region Cabecalho/Parametros
[CmdletBinding()]
param(
    [string]$Etiqueta = '',
    [string]$Setor = '',
    [string]$ExecutadoPor = '',
    [string]$Observacao = '',
    [switch]$Completa
)

$Script:VersaoScript = '1.0.0'
$Script:Autor        = 'Thiago Canozzo Lahr'
$Script:EmailAutor   = 'thiago@peritoemti.com.br'
$Script:Ctx          = $null
# Parametros do script guardados para o Main (o param nao e visivel dentro das funcoes).
$Script:ParametrosEntrada = [ordered]@{
    Etiqueta    = $Etiqueta
    Setor       = $Setor
    ExecutadoPor = $ExecutadoPor
    Observacao  = $Observacao
    Completa    = [bool]$Completa
}
#endregion Cabecalho/Parametros

#region Infra
function New-ContextoColeta {
    <# Cria o contexto da coleta e o atribui a $Script:Ctx. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Parametros)

    $params = [ordered]@{}
    foreach ($k in $Parametros.Keys) { $params[$k] = $Parametros[$k] }

    $ctx = [ordered]@{
        Hostname            = ''
        IdEquipamento       = ''
        IdEquipamentoOrigem = ''
        DataColeta          = ''
        Inicio              = [datetime]::Now
        PastaColeta         = ''
        LogPath             = ''
        Admin               = $false
        Parametros          = $params
        Resultados          = [ordered]@{}
        Status              = (New-Object 'System.Collections.Generic.List[object]')
        FontesComFalha      = (New-Object 'System.Collections.Generic.List[string]')
        FontesPuladas       = (New-Object 'System.Collections.Generic.List[string]')
        Escritas            = (New-Object 'System.Collections.Generic.List[string]')
        Cache               = @{}
        HivesMontadas       = (New-Object System.Collections.Generic.List[string])
        HashScript          = ''
    }
    $ctx.DataColeta = $ctx.Inicio.ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
    $Script:Ctx = $ctx
    return $ctx
}

function Write-TextoUtf8Bom {
    <# Grava texto em UTF-8 com BOM (sem BOM duplicado ao anexar). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Caminho,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Texto,
        [switch]$Anexar
    )
    $enc = New-Object System.Text.UTF8Encoding $true
    if ($Anexar) {
        [System.IO.File]::AppendAllText($Caminho, $Texto, $enc)
    } else {
        [System.IO.File]::WriteAllText($Caminho, $Texto, $enc)
    }
}

function Write-Log {
    <# Anexa uma linha ao log da coleta e mostra AVISO/ERRO no console. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('INFO', 'AVISO', 'ERRO')][string]$Nivel,
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Mensagem
    )
    $linha = '{0} [{1}] [{2}] {3}' -f [datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss.fff', [System.Globalization.CultureInfo]::InvariantCulture), $Nivel, $Area, $Mensagem
    if ($Script:Ctx -and $Script:Ctx.LogPath) {
        Write-TextoUtf8Bom -Caminho $Script:Ctx.LogPath -Texto ($linha + "`r`n") -Anexar
    }
    switch ($Nivel) {
        'AVISO' { Write-Host $linha -ForegroundColor Yellow }
        'ERRO'  { Write-Host $linha -ForegroundColor Red }
    }
}

function ConvertTo-DataTexto {
    <# Converte datas (DateTime, DMTF, yyyyMMdd ou texto) para 'yyyy-MM-dd HH:mm:ss'. #>
    [CmdletBinding()]
    param([AllowNull()][object]$Valor)

    $fmt = 'yyyy-MM-dd HH:mm:ss'
    if ($null -eq $Valor) { return '' }
    if ($Valor -is [datetime]) { return $Valor.ToString($fmt, [System.Globalization.CultureInfo]::InvariantCulture) }

    $txt = ([string]$Valor).Trim()
    if ($txt -eq '' -or $txt -eq '0') { return '' }
    $cult = [System.Globalization.CultureInfo]::InvariantCulture

    # DMTF: o offset e ignorado; vale a hora local gravada nos 14 primeiros digitos.
    if ($txt -match '^\d{14}\.\d{6}[+-]\d{3}$') {
        $dt = [datetime]::MinValue
        if ([datetime]::TryParseExact($txt.Substring(0, 14), 'yyyyMMddHHmmss', $cult, [System.Globalization.DateTimeStyles]::None, [ref]$dt)) {
            return $dt.ToString($fmt, [System.Globalization.CultureInfo]::InvariantCulture)
        }
    }
    if ($txt -match '^\d{8}$') {
        $dt = [datetime]::MinValue
        if ([datetime]::TryParseExact($txt, 'yyyyMMdd', $cult, [System.Globalization.DateTimeStyles]::None, [ref]$dt)) {
            return $dt.ToString($fmt, [System.Globalization.CultureInfo]::InvariantCulture)
        }
    }
    $dt = [datetime]::MinValue
    if ([datetime]::TryParse($txt, $cult, [System.Globalization.DateTimeStyles]::None, [ref]$dt)) {
        return $dt.ToString($fmt, [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return $txt
}

function ConvertFrom-FileTime {
    <# Converte FILETIME (long) para texto; vazio se <= 0 ou fora do intervalo. #>
    [CmdletBinding()]
    param([AllowNull()][long]$Valor)

    if ($Valor -le 0) { return '' }
    try {
        return [datetime]::FromFileTime($Valor).ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
    } catch {
        return ''
    }
}

function Get-NomeSeguro {
    <# Normaliza texto para uso em nome de arquivo (ASCII, max. 40 caracteres). #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Texto)

    if ([string]::IsNullOrEmpty($Texto)) { return '' }
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $Texto.Normalize([System.Text.NormalizationForm]::FormD).ToCharArray()) {
        if ([System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($c)
        }
    }
    $s = [regex]::Replace($sb.ToString(), '[^A-Za-z0-9_-]', '_')
    $s = [regex]::Replace($s, '_+', '_').Trim('_')
    if ($s.Length -gt 40) { $s = $s.Substring(0, 40) }
    return $s
}

function Get-NomeColeta {
    <# Monta InventarioForense_<HOST>[_<Etiqueta>]_<yyyyMMddHHmmss>. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Hostname,
        [AllowEmptyString()][string]$Etiqueta = '',
        [Parameter(Mandatory)][datetime]$Data
    )
    $partes = @('InventarioForense', $Hostname)
    $et = Get-NomeSeguro $Etiqueta
    if ($et) { $partes += $et }
    $partes += $Data.ToString('yyyyMMddHHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
    return ($partes -join '_')
}

function Test-Admin {
    <# Indica se a sessao atual esta elevada (administrador). #>
    [CmdletBinding()]
    param()
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object System.Security.Principal.WindowsPrincipal($id)
        return [bool]$pr.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

$Script:QuebrasCampo = [char[]]@("`r", "`n", "`t")

function ConvertTo-CampoTexto {
    <# Converte um valor para o texto de um campo de CSV (sem aspas). Funcao simples (chamada por celula). #>
    param($Valor)

    if ($Valor -is [string]) {
        if ($Valor.IndexOfAny($Script:QuebrasCampo) -ge 0) { return ($Valor -replace "[`r`n`t]+", ' ').Trim() }
        return $Valor.Trim()
    }
    if ($null -eq $Valor) { return '' }
    if ($Valor -is [bool]) { if ($Valor) { return 'Sim' } else { return 'Nao' } }
    if ($Valor -is [datetime]) { return (ConvertTo-DataTexto -Valor $Valor) }
    if ($Valor -is [System.Collections.IEnumerable]) {
        $partes = @(foreach ($i in $Valor) { ConvertTo-CampoTexto $i })
        return ($partes -join ', ')
    }
    if ($Valor -is [double] -or $Valor -is [single] -or $Valor -is [decimal]) {
        return $Valor.ToString('0.##########', [System.Globalization.CultureInfo]'pt-BR')
    }
    if ($Valor -is [int16] -or $Valor -is [int32] -or $Valor -is [int64] -or $Valor -is [uint16] -or
        $Valor -is [uint32] -or $Valor -is [uint64] -or $Valor -is [byte] -or $Valor -is [sbyte]) {
        return $Valor.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }
    return ([string]$Valor -replace "[`r`n`t]+", ' ').Trim()
}

$Script:SeriaisGenericos = @(
    'TOBEFILLEDBYO.E.M.', 'DEFAULTSTRING', 'SYSTEMSERIALNUMBER', 'NONE', 'N/A', '0', '00000000', '123456789',
    'FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF', '00000000-0000-0000-0000-000000000000'
)

function ConvertTo-SerialNormalizado {
    <# Normaliza um serial: Trim, maiusculas invariantes, sem espacos; vazio se generico. #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Texto)

    if ([string]::IsNullOrEmpty($Texto)) { return '' }
    $s = ($Texto.Trim().ToUpperInvariant()) -replace '\s', ''
    if ($Script:SeriaisGenericos -contains $s) { return '' }
    return $s
}

function Get-IdEquipamento {
    <# ID estavel do equipamento: SHA-256 (UTF-8 sem BOM) da string de origem. Funcao pura. #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Uuid,
        [AllowNull()][AllowEmptyString()][string]$SerialBios,
        [AllowNull()][AllowEmptyString()][string]$SerialPlaca,
        [AllowNull()][string[]]$SeriaisDisco
    )

    $discos = New-Object System.Collections.Generic.List[string]
    foreach ($d in @($SeriaisDisco)) {
        $n = ConvertTo-SerialNormalizado $d
        if ($n -ne '') { $discos.Add($n) }
    }
    $arr = $discos.ToArray()
    [Array]::Sort($arr, [StringComparer]::Ordinal)

    $origem = 'UUID={0}|BIOS={1}|PLACA={2}|DISCO={3}' -f (ConvertTo-SerialNormalizado $Uuid),
        (ConvertTo-SerialNormalizado $SerialBios), (ConvertTo-SerialNormalizado $SerialPlaca), ($arr -join ',')
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash((New-Object System.Text.UTF8Encoding $false).GetBytes($origem))
    } finally { $sha.Dispose() }
    $id = ($hash | ForEach-Object { $_.ToString('X2', [System.Globalization.CultureInfo]::InvariantCulture) }) -join ''
    return [pscustomobject]@{ Id = $id; Origem = $origem }
}

function Get-CimSafe {
    <# Consulta CIM com fallback para WMI legado (se existir); relanca a excecao original se tudo falhar. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ClassName,
        [string]$Namespace = 'root\cimv2',
        [string]$Filter
    )
    try {
        $p = @{ ClassName = $ClassName; Namespace = $Namespace; ErrorAction = 'Stop' }
        if ($Filter) { $p['Filter'] = $Filter }
        return @(Get-CimInstance @p)
    } catch {
        $original = $_
        if (-not (Get-Command Get-WmiObject -ErrorAction SilentlyContinue)) { throw $original }
        try {
            $w = @{ Class = $ClassName; Namespace = $Namespace; ErrorAction = 'Stop' }
            if ($Filter) { $w['Filter'] = $Filter }
            return @(Get-WmiObject @w)
        } catch {
            throw $original
        }
    }
}
#endregion Infra

#region Contrato
$Script:ColunasComuns = @('Hostname', 'IdEquipamento', 'DataColeta')

$Script:Contrato = [ordered]@{
    '01' = @{ Arquivo = '01_Resumo.csv'; Chave = 'Resumo'; Nome = 'Resumo'; Colunas = [string[]]@(
        'Etiqueta', 'Setor', 'ExecutadoPor', 'Observacao', 'Fabricante', 'Modelo', 'NumeroSerie', 'SistemaOperacional', 'Edicao', 'Versao', 'Build', 'Arquitetura', 'SOInstaladoEm', 'SOAtualizadoEm', 'UltimoBoot', 'DominioOuGrupo', 'ParteDeDominio', 'UsuarioLogado', 'Processador', 'Nucleos', 'Threads', 'MemoriaGB', 'DiscoTotalGB', 'EnderecosIP', 'EnderecosMAC', 'AtivacaoWindows', 'TotalSoftwaresInstalados', 'TotalVestigios', 'ExecutadoComoAdmin', 'Modo', 'FusoHorario', 'DuracaoSegundos', 'AreasComFalha', 'AreasPuladas'
    ) }
    '02' = @{ Arquivo = '02_Hardware.csv'; Chave = 'Hardware'; Nome = 'Hardware'; Colunas = [string[]]@(
        'Tipo', 'Descricao', 'Fabricante', 'Modelo', 'NumeroSerie', 'Capacidade', 'Unidade', 'Versao', 'Detalhe'
    ) }
    '03' = @{ Arquivo = '03_Volumes.csv'; Chave = 'Volumes'; Nome = 'Volumes'; Colunas = [string[]]@(
        'Letra', 'Rotulo', 'SistemaArquivos', 'TipoUnidade', 'TotalGB', 'LivreGB', 'SerialVolume', 'BitLocker'
    ) }
    '04' = @{ Arquivo = '04_Rede.csv'; Chave = 'Rede'; Nome = 'Rede'; Colunas = [string[]]@(
        'Tipo', 'Nome', 'Descricao', 'Fabricante', 'MAC', 'Fisico', 'Habilitado', 'Status', 'VelocidadeMbps', 'DHCP', 'EnderecosIP', 'Mascaras', 'Gateway', 'DNS', 'ServidorDHCP'
    ) }
    '05' = @{ Arquivo = '05_Contas.csv'; Chave = 'Contas'; Nome = 'Contas locais'; Colunas = [string[]]@(
        'Nome', 'SID', 'Habilitada', 'UltimoLogon', 'SenhaExpira', 'SenhaAlteradaEm', 'Descricao', 'Fonte', 'MembroAdministradores'
    ) }
    '06' = @{ Arquivo = '06_Perfis.csv'; Chave = 'Perfis'; Nome = 'Perfis de usuario'; Colunas = [string[]]@(
        'SID', 'NomeResolvido', 'Caminho', 'UltimoUso', 'ContaLocalCorrespondente', 'ProvavelDominio', 'Carregado', 'Especial'
    ) }
    '07' = @{ Arquivo = '07_Software_Instalado.csv'; Chave = 'SoftwareInstalado'; Nome = 'Software instalado'; Colunas = [string[]]@(
        'Fonte', 'Nome', 'Versao', 'Fabricante', 'DataInstalacao', 'LocalInstalacao', 'Desinstalador', 'Usuario', 'ComponenteSistema', 'ChaveRegistro'
    ) }
    '08' = @{ Arquivo = '08_Software_Vestigios.csv'; Chave = 'SoftwareVestigios'; Nome = 'Vestigios de software'; Colunas = [string[]]@(
        'Fonte', 'Item', 'Caminho', 'Fabricante', 'Versao', 'Data', 'TipoData', 'Usuario', 'Detalhe'
    ) }
    '09' = @{ Arquivo = '09_Licencas.csv'; Chave = 'Licencas'; Nome = 'Licencas'; Colunas = [string[]]@(
        'Produto', 'Descricao', 'Canal', 'EstadoLicenca', 'ChaveParcial', 'ServidorKMS', 'PortaKMS', 'Detalhe'
    ) }
    '10' = @{ Arquivo = '10_Servicos.csv'; Chave = 'Servicos'; Nome = 'Servicos'; Colunas = [string[]]@(
        'Nome', 'NomeExibicao', 'Estado', 'TipoInicio', 'Conta', 'Executavel', 'ExecutavelExiste'
    ) }
    '11' = @{ Arquivo = '11_Tarefas.csv'; Chave = 'Tarefas'; Nome = 'Tarefas agendadas'; Colunas = [string[]]@(
        'Caminho', 'Nome', 'Autor', 'Estado', 'Acao', 'Argumentos', 'ExecutavelExiste', 'UltimaExecucao', 'ProximaExecucao', 'CriadaEm'
    ) }
    '12' = @{ Arquivo = '12_Drivers.csv'; Chave = 'Drivers'; Nome = 'Drivers'; Colunas = [string[]]@(
        'Dispositivo', 'Classe', 'Fabricante', 'Provedor', 'Versao', 'Data', 'Inf', 'Assinado', 'Assinante'
    ) }
    '13' = @{ Arquivo = '13_Atualizacoes.csv'; Chave = 'Atualizacoes'; Nome = 'Atualizacoes'; Colunas = [string[]]@(
        'Fonte', 'Id', 'Titulo', 'InstaladoEm', 'InstaladoPor', 'Resultado'
    ) }
    '14' = @{ Arquivo = '14_Pastas_Programas.csv'; Chave = 'PastasProgramas'; Nome = 'Pastas de programas'; Colunas = [string[]]@(
        'Raiz', 'Usuario', 'Pasta', 'Caminho', 'CriadoEm', 'ModificadoEm'
    ) }
    '15' = @{ Arquivo = '15_Arquivos_Instaladores.csv'; Chave = 'ArquivosInstaladores'; Nome = 'Arquivos instaladores'; Colunas = [string[]]@(
        'Local', 'Usuario', 'Caminho', 'Arquivo', 'Extensao', 'TamanhoBytes', 'CriadoEm', 'ModificadoEm', 'ProductName', 'CompanyName', 'ProductVersion', 'SHA256'
    ) }
    '16' = @{ Arquivo = '16_Arquivos_Completa.csv'; Chave = 'ArquivosCompleta'; Nome = 'Varredura completa'; Colunas = [string[]]@(
        'Local', 'Usuario', 'Caminho', 'Arquivo', 'Extensao', 'TamanhoBytes', 'CriadoEm', 'ModificadoEm', 'ProductName', 'CompanyName', 'ProductVersion', 'SHA256'
    ) }
}

function Export-CsvPadrao {
    <# Grava um CSV padrao: colunas comuns + colunas da area, ';', todos os campos entre aspas, UTF-8 com BOM, CRLF. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Caminho,
        [Parameter(Mandatory)][string[]]$Colunas,
        [AllowNull()][AllowEmptyCollection()][object[]]$Itens,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Comum
    )
    $pasta = Split-Path -Path $Caminho -Parent
    if ($pasta -and -not (Test-Path -LiteralPath $pasta)) {
        New-Item -ItemType Directory -Path $pasta -Force | Out-Null
    }
    # StringBuilder e laco direto: sem pipeline nem scriptblock por celula (areas 15/16 tem dezenas de milhares de linhas)
    $sb = New-Object System.Text.StringBuilder
    $primeiro = $true
    foreach ($n in (@($Script:ColunasComuns) + @($Colunas))) {
        if (-not $primeiro) { $null = $sb.Append(';') }
        $primeiro = $false
        $null = $sb.Append('"').Append((ConvertTo-CampoTexto $n).Replace('"', '""')).Append('"')
    }
    $null = $sb.Append("`r`n")

    $pc = New-Object System.Text.StringBuilder
    $primeiro = $true
    foreach ($n in $Script:ColunasComuns) {
        if (-not $primeiro) { $null = $pc.Append(';') }
        $primeiro = $false
        $null = $pc.Append('"').Append((ConvertTo-CampoTexto $Comum[$n]).Replace('"', '""')).Append('"')
    }
    $prefixo = $pc.ToString()
    $temPrefixo = $prefixo.Length -gt 0

    foreach ($item in @($Itens)) {
        if ($null -eq $item) { continue }
        $null = $sb.Append($prefixo)
        $sep = $temPrefixo
        $dic = $item -is [System.Collections.IDictionary]
        if (-not $dic) { $props = $item.PSObject.Properties }
        foreach ($col in $Colunas) {
            $valor = $null
            if ($dic) {
                if ($item.Contains($col)) { $valor = $item[$col] }
            } else {
                $prop = $props[$col]
                if ($prop) { $valor = $prop.Value }
            }
            if ($sep) { $null = $sb.Append(';') }
            $sep = $true
            # caminho rapido para texto simples (o caso comum); o resto passa por ConvertTo-CampoTexto
            if ($valor -is [string] -and $valor.IndexOfAny($Script:QuebrasCampo) -lt 0) { $t = $valor.Trim() } else { $t = ConvertTo-CampoTexto $valor }
            $null = $sb.Append('"').Append($t.Replace('"', '""')).Append('"')
        }
        $null = $sb.Append("`r`n")
    }
    Write-TextoUtf8Bom -Caminho $Caminho -Texto $sb.ToString()
}
#endregion Contrato

#region Executor
function Format-Segundos {
    param([double]$Segundos)
    return $Segundos.ToString('0.0', [System.Globalization.CultureInfo]'pt-BR')
}

function Invoke-Area {
    <# Executa uma area isolando falhas; grava o CSV e registra o status. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Numero,
        [switch]$RequerAdmin,
        [Parameter(Mandatory)][scriptblock]$Bloco,
        [int]$Posicao = 0,
        [int]$Total = 0
    )
    $def = $Script:Contrato[$Numero]
    $nome = $def.Nome
    $areaLog = '{0} {1}' -f $Numero, $nome
    $prefixo = if ($Posicao -gt 0 -and $Total -gt 0) {
        '[{0}/{1}]' -f $Posicao.ToString('00'), $Total.ToString('00')
    } else {
        '[{0}]' -f $Numero
    }
    $comum = [ordered]@{
        Hostname      = $Script:Ctx.Hostname
        IdEquipamento = $Script:Ctx.IdEquipamento
        DataColeta    = $Script:Ctx.DataColeta
    }
    $csv = Join-Path (Join-Path $Script:Ctx.PastaColeta 'csv') $def.Arquivo
    $itens = @()
    $status = 'OK'
    $mensagem = ''
    $sw = [Diagnostics.Stopwatch]::StartNew()

    if ($RequerAdmin -and -not $Script:Ctx.Admin) {
        $status = 'Pulada'
        $mensagem = 'requer administrador'
        Write-Log -Nivel AVISO -Area $areaLog -Mensagem 'Area pulada: requer administrador'
    } else {
        Write-Log -Nivel INFO -Area $areaLog -Mensagem 'Inicio'
        try {
            $itens = @(& { $ErrorActionPreference = 'Stop'; & $Bloco })
        } catch {
            $status = 'Falha'
            $mensagem = [string]$_.Exception.Message
            $linha = $_.InvocationInfo.ScriptLineNumber
            $itens = @()
            Write-Log -Nivel ERRO -Area $areaLog -Mensagem ('Falha: {0} (linha {1})' -f $mensagem, $linha)
        }
    }
    $sw.Stop()
    $seg = Format-Segundos $sw.Elapsed.TotalSeconds
    $itens = [object[]]@($itens)
    try {
        Export-CsvPadrao -Caminho $csv -Colunas $def.Colunas -Itens $itens -Comum $comum
    } catch {
        if ($status -eq 'OK') { $status = 'Falha'; $mensagem = 'Falha ao gravar CSV: ' + $_.Exception.Message }
        Write-Log -Nivel ERRO -Area $areaLog -Mensagem ('Falha ao gravar CSV: ' + $_.Exception.Message)
    }
    if ($status -eq 'OK') {
        Write-Log -Nivel INFO -Area $areaLog -Mensagem ('Fim: {0} itens em {1} s' -f $itens.Count, $seg)
        Write-Host ('{0} {1}... OK ({2} s, {3} itens)' -f $prefixo, $nome, $seg, $itens.Count)
    } elseif ($status -eq 'Pulada') {
        Write-Host ('{0} {1}... PULADA (requer administrador)' -f $prefixo, $nome)
    } else {
        Write-Host ('{0} {1}... FALHA ({2})' -f $prefixo, $nome, $mensagem)
    }
    $Script:Ctx.Resultados[$Numero] = $itens
    $Script:Ctx.Status.Add([pscustomobject]@{
        Numero   = $Numero
        Nome     = $nome
        Status   = $status
        Itens    = $itens.Count
        Segundos = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        Mensagem = $mensagem
    })
}

function Invoke-Fonte {
    <# Executa uma fonte dentro de uma area isolando falhas; devolve os itens (ou vazio). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][string]$Nome,
        [switch]$RequerAdmin,
        [Parameter(Mandatory)][scriptblock]$Bloco
    )
    $areaLog = '{0}:{1}' -f $Area, $Nome
    if ($RequerAdmin -and -not $Script:Ctx.Admin) {
        $Script:Ctx.FontesPuladas.Add($areaLog)
        Write-Log -Nivel AVISO -Area $areaLog -Mensagem 'Fonte pulada: requer administrador'
        return
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $itens = @(& { $ErrorActionPreference = 'Stop'; & $Bloco })
    } catch {
        $Script:Ctx.FontesComFalha.Add($areaLog)
        Write-Log -Nivel ERRO -Area $areaLog -Mensagem ('Falha: {0} (linha {1}, {2} s)' -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber, (Format-Segundos $sw.Elapsed.TotalSeconds))
        return
    }
    Write-Log -Nivel INFO -Area $areaLog -Mensagem ('{0} itens em {1} s' -f $itens.Count, (Format-Segundos $sw.Elapsed.TotalSeconds))
    $itens
}

function Get-ListaFalhas {
    <# Areas com falha e depois as fontes, sem repetir (ex.: 'Main' e status e fonte ao mesmo tempo). #>
    $n = New-Object System.Collections.Generic.List[string]
    $numeros = @{}
    foreach ($s in $Script:Ctx.Status) {
        if ($s.Status -eq 'Falha') { $n.Add(('{0} {1}' -f $s.Numero, $s.Nome)); $numeros[[string]$s.Numero] = $true }
    }
    foreach ($f in @($Script:Ctx.FontesComFalha)) {
        if ($numeros.ContainsKey([string]$f) -or $n.Contains([string]$f)) { continue }
        $n.Add([string]$f)
    }
    return ($n -join ', ')
}

function Get-ListaPuladas {
    $n = @()
    foreach ($s in $Script:Ctx.Status) { if ($s.Status -eq 'Pulada') { $n += ('{0} {1}' -f $s.Numero, $s.Nome) } }
    $n += @($Script:Ctx.FontesPuladas)
    return ($n -join ', ')
}

function Add-EscritaSistema {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Descricao)
    $Script:Ctx.Escritas.Add($Descricao)
    Write-Log -Nivel AVISO -Area 'Sistema' -Mensagem ('Escrita: ' + $Descricao)
}
#endregion Executor

#region Parsers

function ConvertFrom-ShimCache {
    <# Parser do AppCompatCache (Win10/11, entradas '10ts'). Entradas posteriores invalidas ou truncadas encerram a leitura sem erro. #>
    [CmdletBinding()]
    param([byte[]]$Dados)

    if ($null -eq $Dados -or $Dados.Length -lt 4) { throw 'Formato ShimCache nao suportado' }
    $offset = [int64][BitConverter]::ToUInt32($Dados, 0)
    # cabecalho valido sem nenhuma entrada (visto no Windows 11 25H2, valor de 52 bytes)
    if ($offset -ge 0x30 -and $offset -eq $Dados.Length) { return @() }
    if ($offset + 12 -gt $Dados.Length -or
        [System.Text.Encoding]::ASCII.GetString($Dados, [int]$offset, 4) -ne '10ts') {
        throw 'Formato ShimCache nao suportado'
    }
    $lista = New-Object System.Collections.Generic.List[object]
    $pos = 0
    while ($offset + 12 -le $Dados.Length) {
        if ([System.Text.Encoding]::ASCII.GetString($Dados, [int]$offset, 4) -ne '10ts') { break }
        $tam = [int64][BitConverter]::ToUInt32($Dados, [int]$offset + 8)
        $p = [int]$offset + 12
        if ($p + 2 -gt $Dados.Length) { break }
        $len = [int][BitConverter]::ToUInt16($Dados, $p); $p += 2
        if ($p + $len + 8 -gt $Dados.Length) { break }
        $caminho = [System.Text.Encoding]::Unicode.GetString($Dados, $p, $len); $p += $len
        $ft = [BitConverter]::ToInt64($Dados, $p)
        $pos++
        $lista.Add([pscustomobject]@{ Posicao = $pos; Caminho = $caminho; Modificado = (ConvertFrom-FileTime -Valor $ft) })
        $offset += 12 + $tam
    }
    return $lista.ToArray()
}

function ConvertFrom-Rot13 {
    <# ROT13 apenas para letras ASCII. #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Texto)

    if ([string]::IsNullOrEmpty($Texto)) { return '' }
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $Texto.ToCharArray()) {
        $i = [int]$c
        if ($i -ge 97 -and $i -le 122) { [void]$sb.Append([char]((($i - 97 + 13) % 26) + 97)) }
        elseif ($i -ge 65 -and $i -le 90) { [void]$sb.Append([char]((($i - 65 + 13) % 26) + 65)) }
        else { [void]$sb.Append($c) }
    }
    return $sb.ToString()
}

function ConvertFrom-UserAssistValor {
    <# Valor UserAssist (Win7+, 72 bytes): contagem em 4, FILETIME em 60. #>
    [CmdletBinding()]
    param([byte[]]$Dados)

    if ($null -eq $Dados -or $Dados.Length -lt 68) { return $null }
    return @{
        Execucoes      = [int][BitConverter]::ToUInt32($Dados, 4)
        UltimaExecucao = (ConvertFrom-FileTime -Valor ([BitConverter]::ToInt64($Dados, 60)))
    }
}

function ConvertFrom-WmiCharArray {
    <# Converte array de uint16 (ex.: nomes de monitor em WmiMonitorID) em texto, parando no primeiro zero. #>
    [CmdletBinding()]
    param([AllowNull()][uint16[]]$Valor)

    if ($null -eq $Valor) { return '' }
    $sb = New-Object System.Text.StringBuilder
    foreach ($v in $Valor) {
        if ($v -eq 0) { break }
        [void]$sb.Append([char]$v)
    }
    return $sb.ToString().Trim()
}
#endregion Parsers

#region Registro
$Script:TipoPInvoke = $null

function Split-CaminhoRegistro {
    <# 'Registry::HKEY_LOCAL_MACHINE\a\b' -> @{ Hive = LocalMachine; Sub = 'a\b' }; $null para outras raizes. #>
    param([string]$Caminho)
    $c = [string]$Caminho
    if ($c.StartsWith('Registry::', [System.StringComparison]::OrdinalIgnoreCase)) { $c = $c.Substring(10) }
    $c = $c.Trim('\')
    $i = $c.IndexOf('\')
    if ($i -ge 0) { $raiz = $c.Substring(0, $i); $sub = $c.Substring($i + 1).Trim('\') } else { $raiz = $c; $sub = '' }
    $hive = $null
    switch ($raiz.ToUpperInvariant()) {
        'HKEY_LOCAL_MACHINE' { $hive = [Microsoft.Win32.RegistryHive]::LocalMachine }
        'HKLM' { $hive = [Microsoft.Win32.RegistryHive]::LocalMachine }
        'HKEY_USERS' { $hive = [Microsoft.Win32.RegistryHive]::Users }
        'HKU' { $hive = [Microsoft.Win32.RegistryHive]::Users }
    }
    if ($null -eq $hive) { return $null }
    @{ Hive = $hive; Sub = $sub }
}

function Open-ChaveRegistro {
    <# RegistryKey somente leitura (vista 64 bits); $null se nao existir, acesso negado ou sem registro (Linux). #>
    param([string]$Caminho)
    $partes = Split-CaminhoRegistro -Caminho $Caminho
    if ($null -eq $partes) { return $null }
    $base = $null
    try {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($partes.Hive, [Microsoft.Win32.RegistryView]::Registry64)
        if (-not $partes.Sub) { $chave = $base; $base = $null; return $chave }
        return $base.OpenSubKey($partes.Sub, $false)
    } catch {
        return $null
    } finally {
        if ($null -ne $base) { $base.Dispose() }
    }
}

function Get-RegSubchaves {
    <# Nomes das subchaves (sem abrir as filhas); vazio se a chave nao existir ou o acesso for negado. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Caminho)
    $chave = Open-ChaveRegistro -Caminho $Caminho
    if ($null -eq $chave) { return @() }
    try {
        return [string[]]@($chave.GetSubKeyNames())
    } catch {
        return @()
    } finally {
        $chave.Dispose()
    }
}

function Get-RegValores {
    <# Valores da chave (nome -> valor bruto, sem expandir %VAR%); @{} se nao existir. Valor ilegivel e pulado. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Caminho)
    $h = @{}
    $chave = Open-ChaveRegistro -Caminho $Caminho
    if ($null -eq $chave) { return $h }
    try {
        $nomes = @()
        try { $nomes = @($chave.GetValueNames()) } catch { return $h }
        foreach ($n in $nomes) {
            $nome = [string]$n
            if ($nome -eq '') { $nome = '(default)' }
            try {
                $h[$nome] = $chave.GetValue([string]$n, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            } catch { }
        }
    } finally {
        $chave.Dispose()
    }
    return $h
}

function Get-TipoPInvokeRegistro {
    <# Tipo dinamico (em memoria, sem compilar C#) com RegQueryInfoKey; criado uma unica vez. #>
    [CmdletBinding()]
    param()
    if ($null -ne $Script:TipoPInvoke) { return $Script:TipoPInvoke }

    $nome = New-Object System.Reflection.AssemblyName('InventarioForense.PInvoke')
    $acesso = [System.Reflection.Emit.AssemblyBuilderAccess]::Run
    $dominio = [AppDomain]::CurrentDomain
    if ($dominio.GetType().GetMethod('DefineDynamicAssembly', [type[]]@([System.Reflection.AssemblyName], [System.Reflection.Emit.AssemblyBuilderAccess]))) {
        $asm = $dominio.DefineDynamicAssembly($nome, $acesso)
    } else {
        # .NET Core/pwsh 7: AppDomain nao define assemblies dinamicos.
        $asm = [System.Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly($nome, $acesso)
    }
    $mod = $asm.DefineDynamicModule('InventarioForense.PInvoke')
    $tb = $mod.DefineType('InventarioForense.Advapi32', [System.Reflection.TypeAttributes]'Public, Class, Sealed, Abstract')

    $params = [type[]](@([IntPtr]) + @(1..10 | ForEach-Object { [IntPtr] }) + @([long].MakeByRefType()))
    $atrib = [System.Reflection.MethodAttributes]'Public, Static, PinvokeImpl'
    $m = $tb.DefinePInvokeMethod('RegQueryInfoKey', 'advapi32.dll', $atrib,
        [System.Reflection.CallingConventions]::Standard, [int], $params,
        [System.Runtime.InteropServices.CallingConvention]::Winapi,
        [System.Runtime.InteropServices.CharSet]::Unicode)
    $m.SetImplementationFlags($m.GetMethodImplementationFlags() -bor [System.Reflection.MethodImplAttributes]::PreserveSig)

    $Script:TipoPInvoke = $tb.CreateType()
    return $Script:TipoPInvoke
}

function Get-RegUltimaEscrita {
    <# Data da ultima escrita da chave (RegQueryInfoKey); '' em erro. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Caminho)

    $c = $Caminho -replace '^(Microsoft\.PowerShell\.Core\\)?Registry::', ''
    $raiz, $sub = $c -split '\\', 2
    $hive = switch ($raiz.ToUpperInvariant()) {
        'HKEY_LOCAL_MACHINE'  { [Microsoft.Win32.RegistryHive]::LocalMachine }
        'HKLM'                { [Microsoft.Win32.RegistryHive]::LocalMachine }
        'HKEY_USERS'          { [Microsoft.Win32.RegistryHive]::Users }
        'HKU'                 { [Microsoft.Win32.RegistryHive]::Users }
        'HKEY_CURRENT_USER'   { [Microsoft.Win32.RegistryHive]::CurrentUser }
        'HKEY_CLASSES_ROOT'   { [Microsoft.Win32.RegistryHive]::ClassesRoot }
        default               { $null }
    }
    if ($null -eq $hive) { return '' }

    $base = $null
    $chave = $null
    try {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, [Microsoft.Win32.RegistryView]::Registry64)
        if ($sub) { $chave = $base.OpenSubKey($sub) } else { $chave = $base }
        if ($null -eq $chave) { return '' }
        $tipo = Get-TipoPInvokeRegistro
        $z = [IntPtr]::Zero
        [long]$ft = 0
        $rc = $tipo::RegQueryInfoKey($chave.Handle.DangerousGetHandle(), $z, $z, $z, $z, $z, $z, $z, $z, $z, $z, [ref]$ft)
        if ($rc -ne 0) { return '' }
        return (ConvertFrom-FileTime $ft)
    } catch {
        return ''
    } finally {
        if ($null -ne $chave -and -not [object]::ReferenceEquals($chave, $base)) { $chave.Dispose() }
        if ($null -ne $base) { $base.Dispose() }
    }
}

function Get-PerfisSistema {
    <# Perfis do ProfileList (+ Win32_UserProfile), sem SYSTEM/LocalService/NetworkService. #>
    [CmdletBinding()]
    param()
    $lista = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    $excluir = @('S-1-5-18', 'S-1-5-19', 'S-1-5-20')

    $wmi = @{}
    try {
        foreach ($w in @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop)) {
            if ($w.SID) { $wmi[[string]$w.SID] = $w }
        }
    } catch {
        Write-Log -Nivel AVISO -Area 'Perfis' -Mensagem ('Win32_UserProfile indisponivel: ' + $_.Exception.Message)
    }

    foreach ($sid in @(Get-RegSubchaves -Caminho $lista)) {
        if ($excluir -contains $sid) { continue }
        $v = Get-RegValores -Caminho ($lista + '\' + $sid)
        # REG_EXPAND_SZ (%SystemDrive%\Users\...): Get-RegValores devolve o valor bruto
        $caminho = [System.Environment]::ExpandEnvironmentVariables([string]$v['ProfileImagePath'])

        $usuario = ''
        try {
            $obj = New-Object System.Security.Principal.SecurityIdentifier($sid)
            $usuario = $obj.Translate([System.Security.Principal.NTAccount]).Value
        } catch {
            $usuario = ''
        }
        if (-not $usuario) {
            if ($caminho) { $usuario = @($caminho.TrimEnd('\', '/') -split '[\\/]')[-1] } else { $usuario = $sid }
        }

        $carregado = $false
        try { $carregado = [bool](Test-Path -LiteralPath ('Registry::HKEY_USERS\' + $sid)) } catch { $carregado = $false }

        $ultimo = ''
        $especial = $false
        if ($wmi.ContainsKey($sid)) {
            $w = $wmi[$sid]
            $ultimo = ConvertTo-DataTexto $w.LastUseTime
            $especial = [bool]$w.Special
            if (-not $caminho -and $w.LocalPath) { $caminho = [string]$w.LocalPath }
        }

        [pscustomobject]@{
            SID       = $sid
            Usuario   = $usuario
            Caminho   = $caminho
            UltimoUso = $ultimo
            Carregado = $carregado
            Especial  = $especial
        }
    }
}

function Invoke-RegExe {
    <# Executa reg.exe e devolve a saida (stdout+stderr) como texto; o codigo fica em $LASTEXITCODE. #>
    param([string[]]$Argumentos)
    # No PS 5.1, stderr de comando nativo com 2>&1 e 'Stop' vira excecao; aqui vale 'Continue'.
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    $saida = & reg.exe @Argumentos 2>&1
    return ((@($saida) | ForEach-Object { [string]$_ }) -join ' ').Trim()
}

function Test-NomeHiveLivre {
    <# Indica se HKU\COLETA_<n> e HKU\COLETA_<n>_C estao livres. #>
    param([int]$N)
    foreach ($nome in @(('COLETA_{0}' -f $N), ('COLETA_{0}_C' -f $N))) {
        if ($Script:Ctx.HivesMontadas -contains ('HKU\' + $nome)) { return $false }
        $emUso = $false
        try { $emUso = [bool](Test-Path -LiteralPath ('Registry::HKEY_USERS\' + $nome)) } catch { $emUso = $false }
        if ($emUso) { return $false }
    }
    return $true
}

function Copy-HiveArquivos {
    <# Copia o hive e todos os arquivos <original>* da mesma pasta (LOG1/LOG2, .blf, .regtrans-ms); devolve o caminho da copia. #>
    param([string]$Original, [string]$Destino, [string]$Area = 'Hive')
    $pasta = [System.IO.Path]::GetDirectoryName($Original)
    $base = [System.IO.Path]::GetFileName($Original)
    $copia = [System.IO.Path]::Combine($Destino, $base)
    # Falhar na copia do hive base e falha da montagem.
    Copy-Item -LiteralPath $Original -Destination $copia -Force -ErrorAction Stop
    $extras = @()
    try { $extras = @([System.IO.Directory]::GetFiles($pasta, $base + '*')) } catch {
        Write-Log -Nivel AVISO -Area $Area -Mensagem ('Falha ao listar arquivos auxiliares de {0}: {1}' -f $Original, $_.Exception.Message)
    }
    foreach ($arq in $extras) {
        $nome = [System.IO.Path]::GetFileName($arq)
        if ($nome -eq $base) { continue }
        try {
            Copy-Item -LiteralPath $arq -Destination ([System.IO.Path]::Combine($Destino, $nome)) -Force -ErrorAction Stop
        } catch {
            Write-Log -Nivel AVISO -Area $Area -Mensagem ('Arquivo auxiliar nao copiado ({0}): {1}' -f $arq, $_.Exception.Message)
        }
    }
    return $copia
}

function Mount-HivesColeta {
    <# Define as raizes de registro de cada perfil; monta COPIAS dos hives de perfis nao carregados. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$Perfis,
        [Parameter(Mandatory)][string]$PastaTmp
    )
    if ($null -eq $Perfis) { return }
    foreach ($p in $Perfis) {
        if ($null -eq $p) { continue }
        $sid = [string]$p.SID
        $usuario = [string]$p.Usuario
        $r = [ordered]@{}
        foreach ($prop in $p.PSObject.Properties) { $r[$prop.Name] = $prop.Value }
        $r['RaizUsuario'] = ''
        $r['RaizClasses'] = ''
        $r['Montado'] = $false
        $r['Disponivel'] = $false

        if ($p.Carregado) {
            $r['RaizUsuario'] = 'Registry::HKEY_USERS\' + $sid
            $r['RaizClasses'] = 'Registry::HKEY_USERS\' + $sid + '_Classes'
            $r['Disponivel'] = $true
            [pscustomobject]$r
            continue
        }

        $ntuser = ''
        if ($p.Caminho) { $ntuser = [System.IO.Path]::Combine([string]$p.Caminho, 'NTUSER.DAT') }
        if (-not $Script:Ctx.Admin -or -not $ntuser -or -not (Test-Path -LiteralPath $ntuser -PathType Leaf)) {
            $motivo = if (-not $Script:Ctx.Admin) { 'requer administrador' } else { 'NTUSER.DAT nao encontrado' }
            Write-Log -Nivel AVISO -Area ('Hive:' + $usuario) -Mensagem ('Perfil {0} pulado: {1}' -f $sid, $motivo)
            $Script:Ctx.FontesPuladas.Add('Hive:' + $usuario)
            [pscustomobject]$r
            continue
        }

        try {
            $destino = Join-Path (Join-Path $PastaTmp 'hives') $sid
            $null = New-Item -ItemType Directory -Path $destino -Force -ErrorAction Stop
            $copia = Copy-HiveArquivos -Original $ntuser -Destino $destino -Area ('Hive:' + $usuario)

            $n = 1
            while (-not (Test-NomeHiveLivre -N $n)) { $n++ }
            $chave = 'HKU\COLETA_{0}' -f $n

            $saida = Invoke-RegExe -Argumentos @('load', $chave, $copia)
            if ($LASTEXITCODE -ne 0) { throw ('reg load {0} falhou (codigo {1}): {2}' -f $chave, $LASTEXITCODE, $saida) }
            $Script:Ctx.HivesMontadas.Add($chave)
            Add-EscritaSistema -Descricao ('reg load {0} (copia de {1})' -f $chave, $ntuser)
            $r['RaizUsuario'] = 'Registry::HKEY_USERS\COLETA_{0}' -f $n
            $r['Montado'] = $true
            $r['Disponivel'] = $true
        } catch {
            Write-Log -Nivel ERRO -Area ('Hive:' + $usuario) -Mensagem ('Falha ao montar a copia do hive de {0}: {1}' -f $sid, $_.Exception.Message)
            $Script:Ctx.FontesComFalha.Add('Hive:' + $usuario)
            [pscustomobject]$r
            continue
        }

        $usrclass = [System.IO.Path]::Combine([string]$p.Caminho, 'AppData', 'Local', 'Microsoft', 'Windows', 'UsrClass.dat')
        if (Test-Path -LiteralPath $usrclass) {
            try {
                $copiaUc = Copy-HiveArquivos -Original $usrclass -Destino $destino -Area ('Hive:' + $usuario)
                $chaveC = '{0}_C' -f $chave
                $saida = Invoke-RegExe -Argumentos @('load', $chaveC, $copiaUc)
                if ($LASTEXITCODE -ne 0) { throw ('reg load {0} falhou (codigo {1}): {2}' -f $chaveC, $LASTEXITCODE, $saida) }
                $Script:Ctx.HivesMontadas.Add($chaveC)
                Add-EscritaSistema -Descricao ('reg load {0} (copia de {1})' -f $chaveC, $usrclass)
                $r['RaizClasses'] = 'Registry::HKEY_USERS\COLETA_{0}_C' -f $n
            } catch {
                Write-Log -Nivel AVISO -Area ('Hive:' + $usuario) -Mensagem ('UsrClass.dat de {0} nao montado: {1}' -f $sid, $_.Exception.Message)
            }
        } else {
            Write-Log -Nivel AVISO -Area ('Hive:' + $usuario) -Mensagem ('UsrClass.dat de {0} nao encontrado' -f $sid)
        }
        [pscustomobject]$r
    }
}

function Dismount-HivesColeta {
    <# Desmonta as copias de hives montadas (todas ou so as de -Somente). Idempotente. #>
    [CmdletBinding()]
    param([string[]]$Somente)
    if ($null -eq $Script:Ctx -or $null -eq $Script:Ctx.HivesMontadas) { return }
    $filtrar = $PSBoundParameters.ContainsKey('Somente')
    $alvos = @($Script:Ctx.HivesMontadas | Where-Object { -not $filtrar -or $Somente -contains $_ })
    foreach ($k in $alvos) {
        $ok = $false
        $msg = ''
        for ($t = 1; $t -le 3; $t++) {
            [gc]::Collect()
            [gc]::WaitForPendingFinalizers()
            try {
                $saida = Invoke-RegExe -Argumentos @('unload', $k)
                if ($LASTEXITCODE -eq 0) { $ok = $true; break }
                $msg = 'codigo {0}: {1}' -f $LASTEXITCODE, $saida
            } catch {
                $msg = $_.Exception.Message
            }
            if ($t -lt 3) { Start-Sleep -Seconds 1 }
        }
        if ($ok) {
            Write-Log -Nivel INFO -Area 'Sistema' -Mensagem ('reg unload {0} OK' -f $k)
        } else {
            Write-Log -Nivel ERRO -Area 'Sistema' -Mensagem ('reg unload {0} falhou apos 3 tentativas ({1})' -f $k, $msg)
        }
        $null = $Script:Ctx.HivesMontadas.Remove($k)
    }
}
#endregion Registro

#region Coletores
function New-LinhaHardware {
    param([string]$Tipo, $Descricao, $Fabricante, $Modelo, $NumeroSerie, $Capacidade, [string]$Unidade, $Versao, [string]$Detalhe)
    $o = [ordered]@{}
    $o['Tipo'] = $Tipo; $o['Descricao'] = $Descricao; $o['Fabricante'] = $Fabricante; $o['Modelo'] = $Modelo
    $o['NumeroSerie'] = $NumeroSerie; $o['Capacidade'] = $Capacidade; $o['Unidade'] = $Unidade
    $o['Versao'] = $Versao; $o['Detalhe'] = $Detalhe
    return [pscustomobject]$o
}

function Get-IndicesDiscoForaDoId {
    <# Index (Win32_DiskDrive) dos discos que nao entram no ID: barramento USB segundo Get-PhysicalDisk
       (UASP aparece como SCSI no Win32_DiskDrive) e o disco que contem a unidade da coleta. #>
    param([string]$PastaReferencia)
    $fora = New-Object 'System.Collections.Generic.HashSet[string]'
    try {
        $ErrorActionPreference = 'Stop'
        foreach ($f in @(Get-PhysicalDisk)) {
            $bt = [string]$f.BusType
            if ($bt -eq '7' -or $bt -eq 'USB') { [void]$fora.Add([string]$f.DeviceId) }
        }
    } catch { }
    $unidade = Get-UnidadeColeta -Caminho $PastaReferencia
    # executando a partir do disco do sistema, ele continua no ID
    $sistema = ([string]$env:SystemDrive).TrimEnd('\').ToUpperInvariant()
    if ($unidade -and $unidade -ne $sistema) {
        try {
            foreach ($a in @(Get-CimSafe -ClassName Win32_LogicalDiskToPartition)) {
                $dep = $a.Dependent; $ant = $a.Antecedent
                if ($dep -isnot [string]) { $dep = [string]$dep.DeviceID }
                if ($ant -isnot [string]) { $ant = [string]$ant.DeviceID }
                if ($dep -match '(?i)(?:^|")([A-Z]:)(?:"|$)' -and $Matches[1].ToUpperInvariant() -eq $unidade -and $ant -match 'Disk #(\d+)') {
                    [void]$fora.Add($Matches[1])
                }
            }
        } catch { }
    }
    $saida = New-Object 'string[]' $fora.Count
    $fora.CopyTo($saida)
    return $saida
}

function Get-DadosIdEquipamento {
    <# Le BIOS/placa/produto/discos fisicos (nao USB), guarda no cache e calcula o ID do equipamento. #>
    [CmdletBinding()]
    param([string]$PastaReferencia)
    $bios = @(Get-CimSafe -ClassName Win32_BIOS)
    $placa = @(Get-CimSafe -ClassName Win32_BaseBoard)
    $produto = @(Get-CimSafe -ClassName Win32_ComputerSystemProduct)
    $discos = @(Get-CimSafe -ClassName Win32_DiskDrive)
    $fora = @(Get-IndicesDiscoForaDoId -PastaReferencia $PastaReferencia)
    $discosId = @($discos | Where-Object { $_.InterfaceType -ne 'USB' -and $_.PNPDeviceID -notlike 'USBSTOR*' -and ($fora -notcontains [string]$_.Index) })
    $Script:Ctx.Cache['BIOS'] = $bios
    $Script:Ctx.Cache['BaseBoard'] = $placa
    $Script:Ctx.Cache['Produto'] = $produto
    $Script:Ctx.Cache['Discos'] = $discos

    $uuid = ''; if ($produto.Count -gt 0) { $uuid = [string]$produto[0].UUID }
    $sb = ''; if ($bios.Count -gt 0) { $sb = [string]$bios[0].SerialNumber }
    $sp = ''; if ($placa.Count -gt 0) { $sp = [string]$placa[0].SerialNumber }
    $seriais = @(foreach ($d in $discosId) { [string]$d.SerialNumber })
    return (Get-IdEquipamento -Uuid $uuid -SerialBios $sb -SerialPlaca $sp -SeriaisDisco $seriais)
}

function Get-CacheOuCim {
    param([string]$Chave, [string]$Classe)
    if ($Script:Ctx.Cache.ContainsKey($Chave) -and $null -ne $Script:Ctx.Cache[$Chave]) { return @($Script:Ctx.Cache[$Chave]) }
    return @(Get-CimSafe -ClassName $Classe)
}

function Get-ColetaHardware {
    <# Area 02: linhas de hardware (BIOS, placa, sistema, CPU, RAM, discos, video, monitores). #>
    [CmdletBinding()]
    param()
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $linhas = New-Object System.Collections.Generic.List[object]

    foreach ($b in (Get-CacheOuCim 'BIOS' 'Win32_BIOS')) {
        $linhas.Add((New-LinhaHardware 'BIOS' $b.Name $b.Manufacturer '' $b.SerialNumber $null '' $b.SMBIOSBIOSVersion ('Data=' + (ConvertTo-DataTexto $b.ReleaseDate))))
    }
    foreach ($p in (Get-CacheOuCim 'BaseBoard' 'Win32_BaseBoard')) {
        $linhas.Add((New-LinhaHardware 'PlacaMae' $p.Product $p.Manufacturer $p.Product $p.SerialNumber $null '' $p.Version ''))
    }
    $produto = @(Get-CacheOuCim 'Produto' 'Win32_ComputerSystemProduct')
    $idNum = ''; $uuid = ''
    if ($produto.Count -gt 0) { $idNum = $produto[0].IdentifyingNumber; $uuid = $produto[0].UUID }
    foreach ($cs in @(Get-CimSafe -ClassName Win32_ComputerSystem)) {
        $det = 'UUID={0};Familia={1};SKU={2};Tipo={3}' -f $uuid, $cs.SystemFamily, $cs.SystemSKUNumber, $cs.PCSystemType
        $linhas.Add((New-LinhaHardware 'Sistema' $cs.Model $cs.Manufacturer $cs.Model $idNum $null '' '' $det))
    }
    foreach ($c in @(Get-CimSafe -ClassName Win32_Processor)) {
        $det = 'Nucleos={0};Threads={1};Socket={2}' -f $c.NumberOfCores, $c.NumberOfLogicalProcessors, $c.SocketDesignation
        $linhas.Add((New-LinhaHardware 'CPU' $c.Name $c.Manufacturer $c.Name $c.ProcessorId $c.MaxClockSpeed 'MHz' '' $det))
    }
    foreach ($m in @(Get-CimSafe -ClassName Win32_PhysicalMemory)) {
        $det = 'Velocidade={0}MHz;Banco={1}' -f $m.Speed, $m.BankLabel
        $linhas.Add((New-LinhaHardware 'RAM' $m.DeviceLocator $m.Manufacturer $m.PartNumber $m.SerialNumber ([math]::Round([double]$m.Capacity / 1GB, 1)) 'GB' '' $det))
    }

    # Midia/barramento dos discos: fonte propria, a falha nao afeta o resto
    $fisicos = @(Invoke-Fonte -Area '02' -Nome 'MidiaDisco' -Bloco { @(Get-PhysicalDisk) })
    $discos = @(Get-CacheOuCim 'Discos' 'Win32_DiskDrive')
    foreach ($d in $discos) {
        $midia = 'Desconhecido'; $barra = ''
        $fis = $fisicos | Where-Object { [string]$_.DeviceId -eq [string]$d.Index } | Select-Object -First 1
        if ($fis) {
            if ([string]$fis.MediaType -in @('SSD', 'HDD')) { $midia = [string]$fis.MediaType }
            $barra = [string]$fis.BusType
        }
        $det = 'Interface={0};Midia={1};Barramento={2}' -f $d.InterfaceType, $midia, $barra
        $cap = $null; if ($null -ne $d.Size) { $cap = [math]::Round([double]$d.Size / 1GB, 1) }
        $linhas.Add((New-LinhaHardware 'Disco' $d.Model $d.Manufacturer $d.Model $d.SerialNumber $cap 'GB' $d.FirmwareRevision $det))
    }
    foreach ($v in @(Get-CimSafe -ClassName Win32_VideoController)) {
        $cap = $null; if ($null -ne $v.AdapterRAM) { $cap = [math]::Round([double]$v.AdapterRAM / 1GB, 1) }
        $det = 'Resolucao={0}x{1}' -f $v.CurrentHorizontalResolution, $v.CurrentVerticalResolution
        $linhas.Add((New-LinhaHardware 'Video' $v.Name $v.AdapterCompatibility $v.VideoProcessor '' $cap 'GB' $v.DriverVersion $det))
    }
    $mons = @(Invoke-Fonte -Area '02' -Nome 'Monitor' -Bloco {
        $edid = $null
        try {
            $edid = @(Get-CimSafe -ClassName WmiMonitorID -Namespace 'root\wmi')
        } catch {
            # sem EDID (VM, sessao RDP, alguns drivers de video): WBEM 'Not supported'
            Write-Log -Nivel 'AVISO' -Area '02:Monitor' -Mensagem ('WmiMonitorID indisponivel, usando Win32_DesktopMonitor: ' + ([string]$_.Exception.Message).Trim())
        }
        if ($null -ne $edid) {
            foreach ($m in $edid) {
                New-LinhaHardware 'Monitor' (ConvertFrom-WmiCharArray $m.UserFriendlyName) (ConvertFrom-WmiCharArray $m.ManufacturerName) (ConvertFrom-WmiCharArray $m.ProductCodeID) (ConvertFrom-WmiCharArray $m.SerialNumberID) $null '' '' ('AnoFabricacao=' + $m.YearOfManufacture)
            }
        } else {
            foreach ($m in @(Get-CimSafe -ClassName Win32_DesktopMonitor)) {
                $det = 'Origem=Win32_DesktopMonitor'
                if ($m.ScreenWidth -and $m.ScreenHeight) { $det += (';Resolucao={0}x{1}' -f $m.ScreenWidth, $m.ScreenHeight) }
                New-LinhaHardware 'Monitor' $m.Name $m.MonitorManufacturer '' '' $null '' '' $det
            }
        }
    })
    foreach ($m in $mons) { $linhas.Add($m) }
    return $linhas.ToArray()
}

function Get-ColetaVolumes {
    <# Area 03: volumes logicos e estado do BitLocker (este so com administrador). #>
    [CmdletBinding()]
    param()
    $tipos = @{ 2 = 'Removivel'; 3 = 'Fixo'; 4 = 'Rede'; 5 = 'Optico' }
    $bl = @{}
    $enc = @(Invoke-Fonte -Area '03' -Nome 'BitLocker' -RequerAdmin -Bloco {
        foreach ($e in @(Get-CimSafe -ClassName Win32_EncryptableVolume -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption')) {
            $txt = if ($null -eq $e.ProtectionStatus) { '' } else { switch ([int]$e.ProtectionStatus) { 0 { 'Desativado' } 1 { 'Ativado' } 2 { 'Desconhecido' } default { [string]$e.ProtectionStatus } } }
            [pscustomobject]@{ Letra = [string]$e.DriveLetter; Status = $txt }
        }
    })
    foreach ($e in $enc) { $bl[$e.Letra] = $e.Status }

    $linhas = New-Object System.Collections.Generic.List[object]
    foreach ($v in @(Get-CimSafe -ClassName Win32_LogicalDisk)) {
        $tipo = $tipos[[int]$v.DriveType]; if (-not $tipo) { $tipo = [string]$v.DriveType }
        $total = $null; if ($null -ne $v.Size) { $total = [math]::Round([double]$v.Size / 1GB, 1) }
        $livre = $null; if ($null -ne $v.FreeSpace) { $livre = [math]::Round([double]$v.FreeSpace / 1GB, 1) }
        $b = ''; if ($bl.ContainsKey([string]$v.DeviceID)) { $b = $bl[[string]$v.DeviceID] }
        $o = [ordered]@{}
        $o['Letra'] = $v.DeviceID; $o['Rotulo'] = $v.VolumeName; $o['SistemaArquivos'] = $v.FileSystem
        $o['TipoUnidade'] = $tipo; $o['TotalGB'] = $total; $o['LivreGB'] = $livre
        $o['SerialVolume'] = $v.VolumeSerialNumber; $o['BitLocker'] = $b
        $linhas.Add([pscustomobject]$o)
    }
    return $linhas.ToArray()
}

function New-LinhaRede {
    param([string]$Tipo, $Nome, $Descricao, $Fabricante, $MAC, $Fisico, $Habilitado, $Status, $Velocidade, $DHCP, $IPs, $Mascaras, $Gateway, $DNS, $ServidorDHCP)
    $o = [ordered]@{}
    $o['Tipo'] = $Tipo; $o['Nome'] = $Nome; $o['Descricao'] = $Descricao; $o['Fabricante'] = $Fabricante
    $o['MAC'] = $MAC; $o['Fisico'] = $Fisico; $o['Habilitado'] = $Habilitado; $o['Status'] = $Status
    $o['VelocidadeMbps'] = $Velocidade; $o['DHCP'] = $DHCP; $o['EnderecosIP'] = $IPs; $o['Mascaras'] = $Mascaras
    $o['Gateway'] = $Gateway; $o['DNS'] = $DNS; $o['ServidorDHCP'] = $ServidorDHCP
    return [pscustomobject]$o
}

function Get-ColetaRede {
    <# Area 04: adaptadores de rede (com configuracao IP) e nomes dos perfis Wi-Fi. #>
    [CmdletBinding()]
    param()
    $confs = @{}
    foreach ($c in @(Get-CimSafe -ClassName Win32_NetworkAdapterConfiguration)) { $confs[[string]$c.Index] = $c }
    $linhas = New-Object System.Collections.Generic.List[object]
    foreach ($a in @(Get-CimSafe -ClassName Win32_NetworkAdapter)) {
        if (-not ($a.MACAddress -or $a.PhysicalAdapter)) { continue }
        $c = $confs[[string]$a.Index]
        $status = switch ($a.NetConnectionStatus) { $null { '' } 2 { 'Conectado' } 7 { 'Desconectado' } default { [string]$a.NetConnectionStatus } }
        $vel = $null; if ($null -ne $a.Speed) { $vel = [math]::Round([double]$a.Speed / 1e6, 1) }
        $ip = ''; $mask = ''; $gw = ''; $dns = ''; $dhcp = $null; $srv = ''
        if ($c) {
            $ip = (@($c.IPAddress) -join ', '); $mask = (@($c.IPSubnet) -join ', ')
            $gw = (@($c.DefaultIPGateway) -join ', '); $dns = (@($c.DNSServerSearchOrder) -join ', ')
            $dhcp = $c.DHCPEnabled; $srv = [string]$c.DHCPServer
        }
        $linhas.Add((New-LinhaRede 'Adaptador' $a.NetConnectionID $a.Description $a.Manufacturer $a.MACAddress $a.PhysicalAdapter $a.NetEnabled $status $vel $dhcp $ip $mask $gw $dns $srv))
    }
    $wifi = @(Invoke-Fonte -Area '04' -Nome 'Wifi' -Bloco {
        $ErrorActionPreference = 'Continue'
        $saida = @(netsh wlan show profiles 2>&1)
        if ($LASTEXITCODE -ne 0 -or $saida.Count -eq 0) { return }
        foreach ($l in $saida) {
            $t = [string]$l
            if (($t -like '*All User Profile*' -or $t -like '*Todos os Perfis de Usu*') -and $t -match ':\s*(.+)$') {
                New-LinhaRede 'PerfilWifi' $Matches[1].Trim() '' '' '' $null $null '' $null $null '' '' '' '' ''
            }
        }
    })
    foreach ($w in $wifi) { $linhas.Add($w) }
    return $linhas.ToArray()
}

function New-LinhaContrato {
    <# Monta a linha na ordem exata das colunas do contrato; chave desconhecida e erro de programacao. #>
    param([Parameter(Mandatory)][string]$Area, [Parameter(Mandatory)][hashtable]$Valores)
    $cols = $Script:Contrato[$Area].Colunas
    foreach ($k in $Valores.Keys) {
        if ($cols -notcontains [string]$k) { throw ('Coluna desconhecida na area {0}: {1}' -f $Area, $k) }
    }
    $o = [ordered]@{}
    foreach ($c in $cols) {
        if ($Valores.ContainsKey($c)) { $o[$c] = $Valores[$c] } else { $o[$c] = '' }
    }
    return [pscustomobject]$o
}

function Get-PrefixoSid {
    param([string]$Sid)
    if ($Sid -match '^(S-1-5-21-\d+-\d+-\d+)-\d+$') { return $Matches[1] }
    return ''
}

function Get-ColetaContas {
    <# Area 05: contas locais (Get-LocalUser; fallback Win32_UserAccount) e participacao no grupo Administradores. #>
    [CmdletBinding()]
    param()
    $contas = New-Object System.Collections.Generic.List[object]
    $fonte = ''
    try {
        if (-not (Get-Command Get-LocalUser -ErrorAction SilentlyContinue)) { throw 'Get-LocalUser indisponivel' }
        foreach ($u in @(Get-LocalUser -ErrorAction Stop)) {
            $sid = ''; if ($null -ne $u.SID) { $sid = [string]$u.SID.Value; if (-not $sid) { $sid = [string]$u.SID } }
            $expira = $null; if ($null -ne $u.Enabled) { $expira = ($null -ne $u.PasswordExpires) }
            $hab = $null; if ($null -ne $u.Enabled) { $hab = [bool]$u.Enabled }
            $contas.Add([pscustomobject]@{
                Nome = [string]$u.Name; SID = $sid; Habilitada = $hab
                UltimoLogon = (ConvertTo-DataTexto $u.LastLogon); SenhaExpira = $expira
                SenhaAlteradaEm = (ConvertTo-DataTexto $u.PasswordLastSet); Descricao = [string]$u.Description
            })
        }
        $fonte = 'LocalUser'
    } catch {
        Write-Log -Nivel AVISO -Area '05' -Mensagem ('Get-LocalUser indisponivel, usando WMI: ' + $_.Exception.Message)
        $contas.Clear()
        foreach ($u in @(Get-CimSafe -ClassName Win32_UserAccount -Filter 'LocalAccount=True')) {
            $hab = $null; if ($null -ne $u.Disabled) { $hab = -not [bool]$u.Disabled }
            $exp = $null; if ($null -ne $u.PasswordExpires) { $exp = [bool]$u.PasswordExpires }
            $contas.Add([pscustomobject]@{
                Nome = [string]$u.Name; SID = [string]$u.SID; Habilitada = $hab
                UltimoLogon = ''; SenhaExpira = $exp; SenhaAlteradaEm = ''; Descricao = [string]$u.Description
            })
        }
        $fonte = 'WMI'
    }

    # Administradores: conjunto de SIDs (Get-LocalGroupMember ou associacao WMI do grupo); $null = indeterminado
    $admSids = $null; $admNomes = $null
    $membros = @(Invoke-Fonte -Area '05' -Nome 'MembrosAdmin' -Bloco {
        $r = $null
        try {
            if (-not (Get-Command Get-LocalGroupMember -ErrorAction SilentlyContinue)) { throw 'Get-LocalGroupMember indisponivel' }
            $sids = @(foreach ($m in @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop)) {
                if ($null -ne $m.SID) { [string]$m.SID.Value; if (-not $m.SID.Value) { [string]$m.SID } }
            })
            $r = [pscustomobject]@{ Tipo = 'SID'; Itens = $sids }
        } catch {
            Write-Log -Nivel AVISO -Area '05:MembrosAdmin' -Mensagem ('Get-LocalGroupMember falhou, usando associacao WMI do grupo: ' + $_.Exception.Message)
            # so o grupo local Administradores e seus membros (sem varrer Win32_GroupUser inteiro)
            $grupos = @(Get-CimSafe -ClassName Win32_Group -Filter "LocalAccount=True AND SID='S-1-5-32-544'")
            if ($grupos.Count -eq 0) { throw 'Grupo Administradores nao encontrado' }
            $grupo = $grupos[0]
            $contasGrupo = $null
            try {
                $contasGrupo = @(Get-CimAssociatedInstance -InputObject $grupo -ResultClassName Win32_UserAccount -ErrorAction Stop)
            } catch {
                # Get-CimSafe pode ter caido no WMI legado: o objeto nao e CimInstance
                if ($grupo.PSObject.Methods['GetRelated']) { $contasGrupo = @($grupo.GetRelated('Win32_UserAccount')) } else { throw }
            }
            $sidsGrupo = @(foreach ($u in $contasGrupo) { if ($u.SID) { [string]$u.SID } })
            $r = [pscustomobject]@{ Tipo = 'SID'; Itens = $sidsGrupo }
        }
        $r
    })
    if ($membros.Count -gt 0) {
        if ($membros[0].Tipo -eq 'SID') { $admSids = @($membros[0].Itens) } else { $admNomes = @($membros[0].Itens) }
    }

    $linhas = New-Object System.Collections.Generic.List[object]
    foreach ($c in $contas) {
        $adm = $null
        if ($null -ne $admSids) { $adm = [bool]($admSids -contains $c.SID) }
        elseif ($null -ne $admNomes) { $adm = [bool]($admNomes -contains $c.Nome) }
        $linhas.Add((New-LinhaContrato '05' @{
            Nome = $c.Nome; SID = $c.SID; Habilitada = $c.Habilitada; UltimoLogon = $c.UltimoLogon
            SenhaExpira = $c.SenhaExpira; SenhaAlteradaEm = $c.SenhaAlteradaEm; Descricao = $c.Descricao
            Fonte = $fonte; MembroAdministradores = $adm
        }))
    }
    return $linhas.ToArray()
}

function Get-ColetaPerfis {
    <# Area 06: perfis do sistema, comparados com as contas locais ja coletadas. #>
    [CmdletBinding()]
    param([AllowNull()][object[]]$Contas = @())
    $sidsLocais = @(foreach ($c in @($Contas)) { [string]$c.SID })
    $prefixos = @(foreach ($s in $sidsLocais) { $p = Get-PrefixoSid $s; if ($p) { $p } })
    $linhas = New-Object System.Collections.Generic.List[object]
    foreach ($p in @(Get-PerfisSistema)) {
        $sid = [string]$p.SID
        $dominio = $null
        if ($sid -like 'S-1-5-21-*' -and $prefixos.Count -gt 0) {
            $dominio = [bool]($prefixos -notcontains (Get-PrefixoSid $sid))
        }
        $linhas.Add((New-LinhaContrato '06' @{
            SID = $sid; NomeResolvido = $p.Usuario; Caminho = $p.Caminho; UltimoUso = $p.UltimoUso
            ContaLocalCorrespondente = [bool]($sidsLocais -contains $sid); ProvavelDominio = $dominio
            Carregado = $p.Carregado; Especial = $p.Especial
        }))
    }
    return $linhas.ToArray()
}

function ConvertTo-CanalLicenca {
    [CmdletBinding()]
    param([AllowNull()][string]$Descricao)
    if (-not $Descricao) { return '' }
    $mapa = [ordered]@{ 'VOLUME_KMSCLIENT' = 'Volume:KMS'; 'VOLUME_MAK' = 'Volume:MAK'; 'OEM' = 'OEM'; 'RETAIL' = 'Retail'; 'TIMEBASED' = 'Temporaria' }
    foreach ($k in $mapa.Keys) {
        if ($Descricao.IndexOf($k, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $mapa[$k] }
    }
    return ''
}

function ConvertTo-EstadoLicenca {
    [CmdletBinding()]
    param([int]$Codigo)
    switch ($Codigo) {
        0 { 'NaoLicenciado' } 1 { 'Licenciado' } 2 { 'PeriodoCarencia' } 3 { 'CarenciaForaTolerancia' }
        4 { 'CarenciaNaoGenuino' } 5 { 'Notificacao' } 6 { 'CarenciaEstendida' }
        default { [string]$Codigo }
    }
}

function Get-ColetaLicencas {
    <# Area 09: licencas com chave parcial; da chave OEM do firmware so os 5 ultimos caracteres. #>
    [CmdletBinding()]
    param()
    $linhas = New-Object System.Collections.Generic.List[object]
    foreach ($l in @(Get-CimSafe -ClassName SoftwareLicensingProduct -Filter 'PartialProductKey IS NOT NULL')) {
        $estado = ''; if ($null -ne $l.LicenseStatus) { $estado = ConvertTo-EstadoLicenca ([int]$l.LicenseStatus) }
        $linhas.Add((New-LinhaContrato '09' @{
            Produto = $l.Name; Descricao = $l.Description; Canal = (ConvertTo-CanalLicenca ([string]$l.Description))
            EstadoLicenca = $estado; ChaveParcial = $l.PartialProductKey
            ServidorKMS = $l.KeyManagementServiceMachine; PortaKMS = $l.KeyManagementServicePort
        }))
    }
    $oem = @(Invoke-Fonte -Area '09' -Nome 'ChaveOEM' -Bloco {
        $parcial = ''; $detalhe = 'Ausente'
        foreach ($s in @(Get-CimSafe -ClassName SoftwareLicensingService)) {
            $k = [string]$s.OA3xOriginalProductKey
            if ($k -and $k.Trim()) {
                $k = $k.Trim()
                $parcial = $k.Substring([math]::Max(0, $k.Length - 5)); $detalhe = 'Presente'
            }
            $k = $null
            break
        }
        New-LinhaContrato '09' @{ Produto = 'ChaveOEMFirmware'; ChaveParcial = $parcial; Detalhe = $detalhe }
    })
    foreach ($o in $oem) { $linhas.Add($o) }
    return $linhas.ToArray()
}

function ConvertTo-CaminhoNormalizado {
    <# Normaliza um caminho de executavel: prefixos do kernel, SystemRoot, caminhos relativos ao sistema e variaveis. #>
    param([string]$Caminho)
    $c = $Caminho.Trim()
    if (-not $c) { return '' }
    if ($c.StartsWith('\??\')) { $c = $c.Substring(4) }
    if ($c.StartsWith('\SystemRoot\', [System.StringComparison]::OrdinalIgnoreCase)) {
        $c = '%SystemRoot%\' + $c.Substring(12)
    } elseif ($c -match '(?i)^(system32|syswow64)\\') {
        $c = '%SystemRoot%\' + $c
    }
    return [System.Environment]::ExpandEnvironmentVariables($c)
}

function Test-CaminhoRede {
    <# Verdadeiro para caminho UNC (\\srv\share, \\?\UNC\...): nao deve ser sondado (Test-Path pode travar). #>
    param([AllowNull()][string]$Caminho)
    if (-not $Caminho) { return $false }
    return ($Caminho -match '^\\\\' -and $Caminho -notmatch '^\\\\[?.]\\[A-Za-z]:')
}

function Get-CaminhoExecutavel {
    <# Extrai o caminho do executavel de uma linha de comando. Sem aspas, testa os prefixos terminados em
       .exe/.com/.bat/.cmd/.sys (do menor para o maior) e devolve o primeiro que existe, ou o menor. #>
    [CmdletBinding()]
    param([AllowNull()][string]$Linha)
    if (-not $Linha) { return '' }
    $t = $Linha.Trim()
    if (-not $t) { return '' }
    if ($t.StartsWith('"')) {
        $fim = $t.IndexOf('"', 1)
        if ($fim -gt 0) { return (ConvertTo-CaminhoNormalizado $t.Substring(1, $fim - 1)) }
        return (ConvertTo-CaminhoNormalizado $t.Substring(1))
    }
    $candidatos = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($t, '(?i)\.(?:exe|com|bat|cmd|sys)(?=\s|$)')) {
        $n = ConvertTo-CaminhoNormalizado $t.Substring(0, $m.Index + $m.Length)
        if ($n) { $candidatos.Add($n) }
    }
    if ($candidatos.Count -eq 0) { return '' }
    # UNC: sem sondar a rede, devolve o menor prefixo
    if (Test-CaminhoRede $candidatos[0]) { return $candidatos[0] }
    foreach ($c in $candidatos) {
        $existe = $false
        try { $existe = [bool](Test-Path -LiteralPath $c) } catch { $existe = $false }
        if ($existe) { return $c }
    }
    return $candidatos[0]
}

function Test-ExecutavelExiste {
    <# 'Sim'/'Nao' conforme o executavel da linha de comando exista; '' sem caminho. #>
    [CmdletBinding()]
    param([AllowNull()][string]$Linha)
    $c = Get-CaminhoExecutavel -Linha $Linha
    if (-not $c) { return '' }
    if (Test-CaminhoRede $c) { return 'Rede' }
    try {
        if (Test-Path -LiteralPath $c) { return 'Sim' } else { return 'Nao' }
    } catch { return '' }
}

function Get-ColetaServicos {
    <# Area 10: servicos do Windows. #>
    [CmdletBinding()]
    param()
    $linhas = New-Object System.Collections.Generic.List[object]
    foreach ($s in @(Get-CimSafe -ClassName Win32_Service)) {
        $linhas.Add((New-LinhaContrato '10' @{
            Nome = $s.Name; NomeExibicao = $s.DisplayName; Estado = $s.State; TipoInicio = $s.StartMode
            Conta = $s.StartName; Executavel = $s.PathName; ExecutavelExiste = (Test-ExecutavelExiste ([string]$s.PathName))
        }))
    }
    return $linhas.ToArray()
}

function Get-ColetaTarefas {
    <# Area 11: tarefas agendadas, uma linha por acao Exec. #>
    [CmdletBinding()]
    param()
    $tarefas = @(Get-ScheduledTask -ErrorAction Stop)
    $infos = @{}
    $lista = @(Invoke-Fonte -Area '11' -Nome 'InfoTarefa' -Bloco {
        $falhas = 0
        foreach ($t in $tarefas) {
            try {
                $i = Get-ScheduledTaskInfo -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop
                [pscustomobject]@{ Chave = ([string]$t.TaskPath + [string]$t.TaskName); Ultima = (ConvertTo-DataTexto $i.LastRunTime); Proxima = (ConvertTo-DataTexto $i.NextRunTime) }
            } catch { $falhas++ }
        }
        if ($falhas -gt 0) { Write-Log -Nivel AVISO -Area '11:InfoTarefa' -Mensagem ('{0} tarefas sem informacao de execucao' -f $falhas) }
    })
    foreach ($i in $lista) { $infos[$i.Chave] = $i }

    $linhas = New-Object System.Collections.Generic.List[object]
    foreach ($t in $tarefas) {
        $ultima = ''; $proxima = ''
        $k = [string]$t.TaskPath + [string]$t.TaskName
        if ($infos.ContainsKey($k)) { $ultima = $infos[$k].Ultima; $proxima = $infos[$k].Proxima }
        $autor = ''; $criada = ''
        if ($t.Author) { $autor = [string]$t.Author }
        elseif ($t.RegistrationInfo -and $t.RegistrationInfo.Author) { $autor = [string]$t.RegistrationInfo.Author }
        if ($t.Date) { $criada = ConvertTo-DataTexto $t.Date }
        elseif ($t.RegistrationInfo -and $t.RegistrationInfo.Date) { $criada = ConvertTo-DataTexto $t.RegistrationInfo.Date }
        $base = @{
            Caminho = $t.TaskPath; Nome = $t.TaskName; Autor = $autor; Estado = [string]$t.State
            UltimaExecucao = $ultima; ProximaExecucao = $proxima; CriadaEm = $criada
        }
        $acoes = @($t.Actions)
        if ($acoes.Count -eq 0) { $acoes = @($null) }
        foreach ($a in $acoes) {
            $v = $base.Clone()
            if ($null -ne $a -and $null -ne $a.PSObject.Properties['Execute']) {
                $v['Acao'] = $a.Execute; $v['Argumentos'] = $a.Arguments
                $v['ExecutavelExiste'] = Test-ExecutavelExiste ([string]$a.Execute)
            } elseif ($null -ne $a) {
                $tipo = ''
                if ($a.CimClass) { $tipo = [string]$a.CimClass.CimClassName } else { $tipo = $a.GetType().Name }
                $v['Acao'] = $tipo
            }
            $linhas.Add((New-LinhaContrato '11' $v))
        }
    }
    return $linhas.ToArray()
}

function Get-ColetaDrivers {
    <# Area 12: drivers PnP assinados/nao assinados. #>
    [CmdletBinding()]
    param()
    $linhas = New-Object System.Collections.Generic.List[object]
    foreach ($d in @(Get-CimSafe -ClassName Win32_PnPSignedDriver)) {
        $ass = $null; if ($null -ne $d.IsSigned) { $ass = [bool]$d.IsSigned }
        $linhas.Add((New-LinhaContrato '12' @{
            Dispositivo = $d.DeviceName; Classe = $d.DeviceClass; Fabricante = $d.Manufacturer; Provedor = $d.DriverProviderName
            Versao = $d.DriverVersion; Data = (ConvertTo-DataTexto $d.DriverDate); Inf = $d.InfName
            Assinado = $ass; Assinante = $d.Signer
        }))
    }
    return $linhas.ToArray()
}

function New-SessaoAtualizacao {
    <# Cria a sessao COM do Windows Update (separada para permitir teste). #>
    [CmdletBinding()]
    param()
    return (New-Object -ComObject Microsoft.Update.Session)
}

function Get-ColetaAtualizacoes {
    <# Area 13: hotfixes (Get-HotFix) e historico do Windows Update (COM). #>
    [CmdletBinding()]
    param()
    $hot = @(Invoke-Fonte -Area '13' -Nome 'HotFix' -Bloco {
        foreach ($h in @(Get-HotFix -ErrorAction Stop)) {
            New-LinhaContrato '13' @{
                Fonte = 'HotFix'; Id = $h.HotFixID; Titulo = $h.Description
                InstaladoEm = (ConvertTo-DataTexto $h.InstalledOn); InstaladoPor = $h.InstalledBy
            }
        }
    })
    $wu = @(Invoke-Fonte -Area '13' -Nome 'WindowsUpdate' -Bloco {
        $resultados = @{ 1 = 'EmAndamento'; 2 = 'Sucesso'; 3 = 'SucessoComErros'; 4 = 'Falha'; 5 = 'Cancelado' }
        $sessao = $null; $buscador = $null; $historico = $null
        try {
            $sessao = New-SessaoAtualizacao
            $buscador = $sessao.CreateUpdateSearcher()
            $total = [int]$buscador.GetTotalHistoryCount()
            if ($total -gt 0) {
                $historico = $buscador.QueryHistory(0, $total)
                foreach ($e in $historico) {
                    $id = ''; if ([string]$e.Title -match '(KB\d+)') { $id = $Matches[1] }
                    $rc = [int]$e.ResultCode
                    $res = $resultados[$rc]; if (-not $res) { $res = [string]$rc }
                    # IUpdateHistoryEntry.Date vem em UTC
                    $quando = $e.Date; if ($quando -is [datetime]) { $quando = $quando.ToLocalTime() }
                    New-LinhaContrato '13' @{
                        Fonte = 'WindowsUpdate'; Id = $id; Titulo = $e.Title
                        InstaladoEm = (ConvertTo-DataTexto $quando); Resultado = $res
                    }
                }
            }
        } finally {
            foreach ($o in @($historico, $buscador, $sessao)) {
                if ($null -ne $o -and [System.Runtime.InteropServices.Marshal]::IsComObject($o)) {
                    try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($o) } catch { $null = $_ }
                }
            }
        }
    })
    return @($hot) + @($wu)
}

$Script:CacheNomesSid = @{}

function Resolve-NomeSid {
    <# Nome da conta do SID; SIDs de servico conhecidos fixos; falha de traducao devolve o proprio SID. Com cache. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Sid)
    $conhecidos = @{ 'S-1-5-18' = 'SYSTEM'; 'S-1-5-19' = 'LOCAL SERVICE'; 'S-1-5-20' = 'NETWORK SERVICE' }
    if ($conhecidos.ContainsKey($Sid)) { return $conhecidos[$Sid] }
    if ($Script:CacheNomesSid.ContainsKey($Sid)) { return $Script:CacheNomesSid[$Sid] }
    $nome = $Sid
    try {
        $obj = New-Object System.Security.Principal.SecurityIdentifier($Sid)
        $nome = [string]$obj.Translate([System.Security.Principal.NTAccount]).Value
    } catch {
        $nome = $Sid
    }
    $Script:CacheNomesSid[$Sid] = $nome
    return $nome
}

function New-LinhaUninstall {
    <# Uma linha do 07 a partir de uma chave Uninstall; nada se nao houver DisplayName. #>
    param([string]$Fonte, [string]$Caminho, [string]$Usuario)
    $v = Get-RegValores -Caminho $Caminho
    if (-not $v['DisplayName']) { return }
    $des = [string]$v['UninstallString']
    if (-not $des) { $des = [string]$v['QuietUninstallString'] }
    New-LinhaContrato '07' @{
        Fonte = $Fonte; Nome = [string]$v['DisplayName']; Versao = [string]$v['DisplayVersion']
        Fabricante = [string]$v['Publisher']; DataInstalacao = (ConvertTo-DataTexto $v['InstallDate'])
        LocalInstalacao = [string]$v['InstallLocation']; Desinstalador = $des; Usuario = $Usuario
        ComponenteSistema = [bool]($v['SystemComponent'] -eq 1)
        ChaveRegistro = ($Caminho -replace '^Registry::', '')
    }
}

function New-LinhaMsi {
    <# Linha MSI do 07; $Nome ja resolvido, $V = valores de InstallProperties, $Sid vazio = sem usuario. #>
    param([string]$Nome, [hashtable]$V, [string]$Sid, [string]$Caminho)
    $usuario = ''
    if ($Sid) { $usuario = Resolve-NomeSid -Sid $Sid }
    New-LinhaContrato '07' @{
        Fonte = 'MSI'; Nome = $Nome; Versao = [string]$V['DisplayVersion']; Fabricante = [string]$V['Publisher']
        DataInstalacao = (ConvertTo-DataTexto $V['InstallDate']); LocalInstalacao = [string]$V['InstallLocation']
        Desinstalador = [string]$V['UninstallString']; Usuario = $usuario; ComponenteSistema = [bool]($V['SystemComponent'] -eq 1)
        ChaveRegistro = ($Caminho -replace '^Registry::', '')
    }
}

function Get-ColetaSoftwareInstalado {
    <# Area 07: software instalado de todas as fontes, sem deduplicacao. #>
    [CmdletBinding()]
    param([object[]]$Perfis = @())
    $sub = '\Microsoft\Windows\CurrentVersion\Uninstall'
    $hklm = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE'

    $h64 = @(Invoke-Fonte -Area '07' -Nome 'HKLM64' -Bloco {
        foreach ($n in @(Get-RegSubchaves -Caminho ($hklm + $sub))) {
            New-LinhaUninstall -Fonte 'HKLM64' -Caminho ($hklm + $sub + '\' + $n) -Usuario ''
        }
    })
    $h32 = @(Invoke-Fonte -Area '07' -Nome 'HKLM32' -Bloco {
        $base = $hklm + '\WOW6432Node' + $sub
        foreach ($n in @(Get-RegSubchaves -Caminho $base)) {
            New-LinhaUninstall -Fonte 'HKLM32' -Caminho ($base + '\' + $n) -Usuario ''
        }
    })
    $usr = @(Invoke-Fonte -Area '07' -Nome 'Usuario' -Bloco {
        foreach ($p in @($Perfis | Where-Object { $_ -and $_.Disponivel })) {
            foreach ($base in @(($p.RaizUsuario + '\Software' + $sub), ($p.RaizUsuario + '\Software\WOW6432Node' + $sub))) {
                foreach ($n in @(Get-RegSubchaves -Caminho $base)) {
                    New-LinhaUninstall -Fonte 'Usuario' -Caminho ($base + '\' + $n) -Usuario ([string]$p.Usuario)
                }
            }
        }
    })
    $msi = @(Invoke-Fonte -Area '07' -Nome 'MSI' -Bloco {
        $prod = $hklm + '\Classes\Installer\Products'
        $ud = $hklm + '\Microsoft\Windows\CurrentVersion\Installer\UserData'
        # a juncao usa o id empacotado bruto (sem converter para GUID)
        $props = @{}
        foreach ($sid in @(Get-RegSubchaves -Caminho $ud)) {
            foreach ($id in @(Get-RegSubchaves -Caminho ($ud + '\' + $sid + '\Products'))) {
                $cam = $ud + '\' + $sid + '\Products\' + $id + '\InstallProperties'
                if (-not $props.ContainsKey($id)) { $props[$id] = New-Object System.Collections.ArrayList }
                [void]$props[$id].Add([pscustomobject]@{ Sid = $sid; Caminho = $cam; Valores = (Get-RegValores -Caminho $cam) })
            }
        }
        $vistos = @{}
        foreach ($id in @(Get-RegSubchaves -Caminho $prod)) {
            $vistos[$id] = $true
            $pv = Get-RegValores -Caminho ($prod + '\' + $id)
            $entradas = @()
            if ($props.ContainsKey($id)) { $entradas = @($props[$id]) }
            if ($entradas.Count -eq 0) { $entradas = @([pscustomobject]@{ Sid = ''; Caminho = ($prod + '\' + $id); Valores = @{} }) }
            foreach ($e in $entradas) {
                $v = $e.Valores
                $nome = [string]$pv['ProductName']
                if (-not $nome) { $nome = [string]$v['DisplayName'] }
                New-LinhaMsi -Nome $nome -V $v -Sid $e.Sid -Caminho $e.Caminho
            }
        }
        # produtos so em UserData (sem chave em Products) tambem saem
        foreach ($id in @($props.Keys | Where-Object { -not $vistos.ContainsKey($_) })) {
            foreach ($e in @($props[$id])) {
                $v = $e.Valores
                if (-not $v['DisplayName']) { continue }
                New-LinhaMsi -Nome ([string]$v['DisplayName']) -V $v -Sid $e.Sid -Caminho $e.Caminho
            }
        }
    })
    $appx = @(Invoke-Fonte -Area '07' -Nome 'Appx' -Bloco {
        if ($Script:Ctx.Admin) { $pacotes = @(Get-AppxPackage -AllUsers) } else { $pacotes = @(Get-AppxPackage) }
        foreach ($a in $pacotes) {
            $nomes = @()
            foreach ($i in @($a.PackageUserInformation)) {
                if ($null -eq $i) { continue }
                $n = ''
                $uid = $i.UserSecurityId
                if ($uid -and $uid.Username) { $n = [string]$uid.Username }
                elseif ($uid -and $uid.Sid) { $n = Resolve-NomeSid -Sid ([string]$uid.Sid) }
                if ($n) { $nomes += $n }
            }
            New-LinhaContrato '07' @{
                Fonte = 'Appx'; Nome = [string]$a.Name; Versao = [string]$a.Version; Fabricante = [string]$a.Publisher
                LocalInstalacao = [string]$a.InstallLocation; Usuario = ($nomes -join ', ')
                ComponenteSistema = [bool]($a.SignatureKind -eq 'System' -or $a.IsFramework)
            }
        }
    })
    return @($h64) + @($h32) + @($usr) + @($msi) + @($appx)
}
#endregion Coletores

#region Vestigios
function New-Vestigio {
    <# Linha do 08 com os parametros na ordem do contrato. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Fonte,
        [Parameter(Mandatory)][string]$Item,
        [string]$Caminho = '', [string]$Fabricante = '', [string]$Versao = '',
        [string]$Data = '', [string]$TipoData = '', [string]$Usuario = '', [string]$Detalhe = ''
    )
    New-LinhaContrato '08' @{
        Fonte = $Fonte; Item = $Item; Caminho = $Caminho; Fabricante = $Fabricante; Versao = $Versao
        Data = $Data; TipoData = $TipoData; Usuario = $Usuario; Detalhe = $Detalhe
    }
}

function Get-NomeArquivoCaminho {
    param([string]$Caminho)
    if ($Caminho -match '([^\\/]+)[\\/]*$') { return $Matches[1] }
    return $Caminho
}

function Get-VestigioEventoMsi {
    <# Eventos do MsiInstaller (instalacao/remocao); sem eventos devolve vazio. #>
    [CmdletBinding()]
    param()
    try {
        $eventos = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'MsiInstaller'; Id = 1033, 1034, 11707, 11724 } -ErrorAction Stop)
    } catch {
        if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*' -or $_.Exception.Message -match '(?i)no events were found|nenhum evento') { return @() }
        throw
    }
    foreach ($e in $eventos) {
        $id = [int]$e.Id
        $item = ''; $versao = ''; $fab = ''; $detalhe = 'EventId=' + $id
        if ($id -eq 1033 -or $id -eq 1034) {
            $pr = @($e.Properties)
            # EventData: [0] nome, [1] versao, [2] idioma, [3] status, [4] fabricante
            if ($pr.Count -gt 0) { $item = [string]$pr[0].Value }
            if ($pr.Count -gt 1) { $versao = [string]$pr[1].Value }
            if ($pr.Count -gt 3) { $detalhe = 'EventId=' + $id + ';Status=' + [string]$pr[3].Value }
            if ($pr.Count -gt 4) { $fab = [string]$pr[4].Value }
        } elseif ([string]$e.Message -match '(?:Product|Produto): (.+?) --') {
            $item = $Matches[1]
        }
        if (-not $item) { continue }
        $tipo = 'Instalado'
        if ($id -eq 1034 -or $id -eq 11724) { $tipo = 'Removido' }
        $usr = ''
        if ($null -ne $e.UserId) { $usr = Resolve-NomeSid -Sid ([string]$e.UserId.Value) }
        New-Vestigio -Fonte 'EventoMSI' -Item $item -Fabricante $fab -Versao $versao `
            -Data (ConvertTo-DataTexto $e.TimeCreated) -TipoData $tipo -Usuario $usr -Detalhe $detalhe
    }
}

function Get-VestigioBam {
    <# BAM/DAM: ultima execucao por usuario (requer administrador). #>
    [CmdletBinding()]
    param()
    foreach ($svc in 'bam', 'dam') {
        $base = 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\' + $svc + '\State\UserSettings'
        foreach ($sid in @(Get-RegSubchaves -Caminho $base)) {
            $usr = Resolve-NomeSid -Sid $sid
            $vals = Get-RegValores -Caminho ($base + '\' + $sid)
            foreach ($nome in @($vals.Keys)) {
                if ($nome -like 'Version*' -or $nome -like 'SequenceNumber*') { continue }
                $b = $vals[$nome] -as [byte[]]
                if ($null -eq $b -or $b.Length -lt 8) { continue }
                New-Vestigio -Fonte 'BAM' -Item (Get-NomeArquivoCaminho $nome) -Caminho $nome `
                    -Data (ConvertFrom-FileTime -Valor ([BitConverter]::ToInt64($b, 0))) -TipoData 'UltimaExecucao' -Usuario $usr -Detalhe ('Servico=' + $svc)
            }
        }
    }
}

function Get-VestigioUserAssist {
    <# UserAssist: programas executados pelo usuario (ROT13), com contagem e ultima execucao. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$Perfis)
    if ($null -eq $Perfis) { return }
    foreach ($p in $Perfis) {
        if (-not $p.Disponivel) { continue }
        $ua = $p.RaizUsuario + '\Software\Microsoft\Windows\CurrentVersion\Explorer\UserAssist'
        foreach ($guid in @(Get-RegSubchaves -Caminho $ua)) {
            $vals = Get-RegValores -Caminho ($ua + '\' + $guid + '\Count')
            foreach ($nome in @($vals.Keys)) {
                $b = $vals[$nome] -as [byte[]]
                $dec = ConvertFrom-UserAssistValor -Dados $b
                if ($null -eq $dec) { continue }
                New-Vestigio -Fonte 'UserAssist' -Item (ConvertFrom-Rot13 $nome) -Data $dec.UltimaExecucao `
                    -TipoData 'UltimaExecucao' -Usuario ([string]$p.Usuario) -Detalhe ('Execucoes=' + $dec.Execucoes)
            }
        }
    }
}

function Get-VestigioMuiCache {
    <# MUICache: nome amigavel e empresa dos executaveis abertos pelo usuario. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$Perfis)
    if ($null -eq $Perfis) { return }
    foreach ($p in $Perfis) {
        if (-not $p.Disponivel -or -not $p.RaizClasses) { continue }
        $vals = Get-RegValores -Caminho ($p.RaizClasses + '\Local Settings\Software\Microsoft\Windows\Shell\MuiCache')
        $empresas = @{}
        foreach ($nome in @($vals.Keys)) {
            if ($nome -match '^(.+)\.ApplicationCompany$') { $empresas[$Matches[1].ToLowerInvariant()] = [string]$vals[$nome] }
        }
        foreach ($nome in @($vals.Keys)) {
            if ($nome -notmatch '^(.+)\.FriendlyAppName$') { continue }
            $cam = $Matches[1]
            if (-not [string]$vals[$nome]) { continue }
            $fab = ''
            if ($empresas.ContainsKey($cam.ToLowerInvariant())) { $fab = $empresas[$cam.ToLowerInvariant()] }
            New-Vestigio -Fonte 'MUICache' -Item ([string]$vals[$nome]) -Caminho $cam -Fabricante $fab -Usuario ([string]$p.Usuario)
        }
    }
}

function Get-VestigioCompatAssistant {
    <# Compatibility Assistant Store: executaveis ja iniciados pelo usuario. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$Perfis)
    if ($null -eq $Perfis) { return }
    foreach ($p in $Perfis) {
        if (-not $p.Disponivel) { continue }
        $vals = Get-RegValores -Caminho ($p.RaizUsuario + '\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Compatibility Assistant\Store')
        foreach ($nome in @($vals.Keys)) {
            New-Vestigio -Fonte 'CompatAssistant' -Item (Get-NomeArquivoCaminho $nome) -Caminho $nome -Usuario ([string]$p.Usuario)
        }
    }
}

function Get-VestigioChaveSoftware {
    <# Chaves de fabricante/produto em SOFTWARE (HKLM, WOW6432Node e perfis), com a data da ultima escrita. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$Perfis)
    $excluir = @('Classes', 'Microsoft', 'Policies', 'Wow6432Node', 'Clients', 'RegisteredApplications', 'ODBC', 'Intel', 'DefaultUserEnvironment')
    $raizes = New-Object System.Collections.Generic.List[object]
    $raizes.Add(@{ Base = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE'; Usuario = '' })
    $raizes.Add(@{ Base = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node'; Usuario = '' })
    if ($null -ne $Perfis) {
        foreach ($p in $Perfis) {
            if ($p.Disponivel) { $raizes.Add(@{ Base = ($p.RaizUsuario + '\Software'); Usuario = [string]$p.Usuario }) }
        }
    }
    foreach ($r in $raizes) {
        foreach ($fab in @(Get-RegSubchaves -Caminho $r.Base)) {
            if ($excluir -contains $fab) { continue }
            $cFab = $r.Base + '\' + $fab
            $produtos = @(Get-RegSubchaves -Caminho $cFab)
            if ($produtos.Count -eq 0) {
                New-Vestigio -Fonte 'ChaveSoftware' -Item $fab -Caminho ($cFab -replace '^Registry::', '') -Fabricante $fab `
                    -Data (Get-RegUltimaEscrita -Caminho $cFab) -TipoData 'ChaveModificada' -Usuario $r.Usuario
                continue
            }
            foreach ($prod in $produtos) {
                $c = $cFab + '\' + $prod
                New-Vestigio -Fonte 'ChaveSoftware' -Item $prod -Caminho ($c -replace '^Registry::', '') -Fabricante $fab `
                    -Data (Get-RegUltimaEscrita -Caminho $c) -TipoData 'ChaveModificada' -Usuario $r.Usuario
            }
        }
    }
}
function Get-PastaWindows {
    if ($env:WINDIR) { return $env:WINDIR }
    return 'C:\Windows'
}

function Test-CaminhoExiste {
    <# 'Sim'/'Nao' para caminho absoluto de unidade; 'Rede' para UNC (nao sondado); '' se vazio ou nao absoluto. #>
    param([AllowNull()][string]$Caminho)
    if (-not $Caminho -or $Caminho -notmatch '^(?:[A-Za-z]:\\|\\\\)') { return '' }
    if (Test-CaminhoRede $Caminho) { return 'Rede' }
    try {
        if (Test-Path -LiteralPath $Caminho) { return 'Sim' } else { return 'Nao' }
    } catch { return '' }
}

function Test-ErroSemEventos {
    param($Erro)
    return ($Erro.FullyQualifiedErrorId -like 'NoMatchingEventsFound*' -or $Erro.Exception.Message -match '(?i)no events were found|nenhum evento')
}

function Invoke-ComMembro {
    <# Chama um membro de objeto COM via InvokeMember (o PS 5.1 nao expoe membros parametrizados de alguns COM). #>
    param($Objeto, [string]$Nome, [string]$Tipo = 'InvokeMethod', [object[]]$Argumentos = @())
    $flags = [System.Reflection.BindingFlags]$Tipo
    return $Objeto.GetType().InvokeMember($Nome, $flags, $null, $Objeto, $Argumentos)
}

function New-ObjetoCom {
    <# Cria um objeto COM pelo ProgID (isolado para poder ser simulado nos testes). #>
    param([Parameter(Mandatory)][string]$ProgId)
    return (New-Object -ComObject $ProgId)
}

function Clear-ComObjetos {
    param([object[]]$Objetos)
    foreach ($o in $Objetos) {
        if ($null -ne $o -and [System.Runtime.InteropServices.Marshal]::IsComObject($o)) {
            try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($o) } catch { $null = $_ }
        }
    }
}

function Invoke-EsentutlExe {
    <# Executa esentutl.exe e devolve a saida (stdout+stderr) como texto; o codigo fica em $LASTEXITCODE. #>
    param([string[]]$Argumentos)
    # No PS 5.1, stderr de comando nativo com 2>&1 e 'Stop' vira excecao; aqui vale 'Continue'.
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    $saida = & esentutl.exe @Argumentos 2>&1
    return ((@($saida) | ForEach-Object { [string]$_ }) -join ' ').Trim()
}

function Copy-BrutoAmcache {
    <# Copia Amcache.hve (+ .LOG1/.LOG2) via esentutl /vss para -Destino; devolve o caminho da copia. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Destino,
        [string]$Origem = ''
    )
    if (-not $Origem) { $Origem = [System.IO.Path]::Combine((Get-PastaWindows), 'appcompat', 'Programs', 'Amcache.hve') }
    $null = New-Item -ItemType Directory -Path $Destino -Force -ErrorAction Stop
    $copia = Join-Path $Destino 'Amcache.hve'
    Add-EscritaSistema -Descricao 'esentutl /vss: snapshot VSS temporario para copiar Amcache.hve'
    $saida = Invoke-EsentutlExe -Argumentos @('/y', $Origem, '/vss', '/d', $copia)
    if ($LASTEXITCODE -ne 0) { throw ('esentutl /vss falhou para {0} (codigo {1}): {2}' -f $Origem, $LASTEXITCODE, $saida) }
    foreach ($ext in '.LOG1', '.LOG2') {
        $o = $Origem + $ext
        if (-not (Test-Path -LiteralPath $o)) { continue }
        # Cada chamada /vss cria o seu proprio snapshot.
        Add-EscritaSistema -Descricao ('esentutl /vss: snapshot VSS temporario para copiar Amcache.hve' + $ext)
        $saida = Invoke-EsentutlExe -Argumentos @('/y', $o, '/vss', '/d', ($copia + $ext))
        # Sem o LOG a hive seria montada sem o replay das transacoes: falha da fonte (o .hve ja copiado fica em brutos).
        if ($LASTEXITCODE -ne 0) { throw ('esentutl /vss falhou para {0} (codigo {1}): {2}' -f $o, $LASTEXITCODE, $saida) }
    }
    return $copia
}

function Test-ChaveHklmEmUso {
    param([string]$Nome)
    if ($Script:Ctx.HivesMontadas -contains ('HKLM\' + $Nome)) { return $true }
    try { return [bool](Test-Path -LiteralPath ('Registry::HKEY_LOCAL_MACHINE\' + $Nome)) } catch { return $false }
}

function Get-NomeHiveAmcache {
    <# Primeiro nome livre: COLETA_AMCACHE, COLETA_AMCACHE_2, _3... Nome padrao ocupado = sobra de coleta anterior (nao e desmontada aqui). #>
    $nome = 'COLETA_AMCACHE'
    if (-not (Test-ChaveHklmEmUso $nome)) { return $nome }
    Write-Log -Nivel AVISO -Area '08:Amcache' -Mensagem 'HKLM\COLETA_AMCACHE ja esta montada (provavel sobra de coleta anterior); usando outro nome'
    $n = 2
    while (Test-ChaveHklmEmUso ('{0}_{1}' -f $nome, $n)) { $n++ }
    return ('{0}_{1}' -f $nome, $n)
}

function Get-VestigioAmcache {
    <# Monta uma SEGUNDA copia do Amcache (em <PastaTmp>\amcache) e le InventoryApplication/InventoryApplicationFile. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CopiaHve,
        [Parameter(Mandatory)][string]$PastaTmp
    )
    $nome = Get-NomeHiveAmcache
    $chave = 'HKLM\' + $nome
    $raiz = 'Registry::HKEY_LOCAL_MACHINE\' + $nome + '\Root'
    $dir = Join-Path $PastaTmp 'amcache'
    $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop
    # O bruto em brutos\ nao e montado: reg load altera o arquivo (replay dos LOGs).
    $trabalho = Copy-HiveArquivos -Original $CopiaHve -Destino $dir -Area '08:Amcache'
    try {
        $saida = Invoke-RegExe -Argumentos @('load', $chave, $trabalho)
        if ($LASTEXITCODE -ne 0) { throw ('reg load {0} falhou (codigo {1}): {2}' -f $chave, $LASTEXITCODE, $saida) }
        $Script:Ctx.HivesMontadas.Add($chave)
        Add-EscritaSistema -Descricao ('reg load {0} (copia de trabalho do Amcache: {1})' -f $chave, $trabalho)

        $base = $raiz + '\InventoryApplication'
        foreach ($sub in @(Get-RegSubchaves -Caminho $base)) {
            $v = Get-RegValores -Caminho ($base + '\' + $sub)
            $item = [string]$v['Name']; if (-not $item) { $item = $sub }
            New-Vestigio -Fonte 'Amcache' -Item $item -Fabricante ([string]$v['Publisher']) -Versao ([string]$v['Version']) `
                -Data (ConvertTo-DataTexto $v['InstallDate']) -TipoData 'Instalado' -Caminho ([string]$v['RootDirPath']) `
                -Detalhe ('Origem={0};Desinstalador={1};ProgramId={2}' -f [string]$v['Source'], [string]$v['UninstallString'], $sub)
        }
        $base = $raiz + '\InventoryApplicationFile'
        foreach ($sub in @(Get-RegSubchaves -Caminho $base)) {
            $v = Get-RegValores -Caminho ($base + '\' + $sub)
            $cam = [string]$v['LowerCaseLongPath']
            $item = [string]$v['Name']; if (-not $item) { $item = Get-NomeArquivoCaminho $cam }; if (-not $item) { $item = $sub }
            $sha1 = [string]$v['FileId']
            if ($sha1.StartsWith('0000')) { $sha1 = $sha1.Substring(4) }
            New-Vestigio -Fonte 'AmcacheArquivo' -Item $item -Caminho $cam -Fabricante ([string]$v['Publisher']) -Versao ([string]$v['Version']) `
                -Data (ConvertTo-DataTexto $v['LinkDate']) -TipoData 'ArquivoCompilado' `
                -Detalhe ('SHA1={0};ProgramId={1}' -f $sha1, [string]$v['ProgramId'])
        }
    } finally {
        # So a propria hive: as hives de usuario seguem montadas para as outras fontes.
        Dismount-HivesColeta -Somente $chave
    }
}

function Get-VestigioShimCache {
    <# AppCompatCache (ShimCache): caminho e data de modificacao do arquivo. #>
    [CmdletBinding()]
    param()
    $v = Get-RegValores -Caminho 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Session Manager\AppCompatCache'
    $b = $v['AppCompatCache'] -as [byte[]]
    if ($null -eq $b) { throw 'Valor AppCompatCache nao encontrado' }
    $entradas = @(ConvertFrom-ShimCache -Dados $b)
    if ($entradas.Count -eq 0) {
        Write-Log -Nivel 'INFO' -Area '08:ShimCache' -Mensagem ('AppCompatCache sem entradas ({0} bytes, so cabecalho)' -f $b.Length)
    }
    foreach ($e in $entradas) {
        $cam = [string]$e.Caminho
        $item = Get-NomeArquivoCaminho $cam; if (-not $item) { continue }
        New-Vestigio -Fonte 'ShimCache' -Item $item -Caminho $cam -Data ([string]$e.Modificado) -TipoData 'ArquivoModificado' `
            -Detalhe ('Posicao=' + $e.Posicao)
    }
}

function Copy-BrutoPrefetch {
    <# Copia os .pf para -Destino preservando as datas; devolve as datas lidas do ORIGINAL antes da copia. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Destino,
        [string]$Pasta = ''
    )
    if (-not $Pasta) { $Pasta = Join-Path (Get-PastaWindows) 'Prefetch' }
    $null = New-Item -ItemType Directory -Path $Destino -Force -ErrorAction Stop
    foreach ($arq in @(Get-ChildItem -LiteralPath $Pasta -Filter '*.pf' -File -Force -ErrorAction Stop)) {
        $criado = $arq.CreationTime
        $modificado = $arq.LastWriteTime
        $copia = Join-Path $Destino $arq.Name
        try {
            Copy-Item -LiteralPath $arq.FullName -Destination $copia -Force -ErrorAction Stop
            [System.IO.File]::SetCreationTime($copia, $criado)
            [System.IO.File]::SetLastWriteTime($copia, $modificado)
        } catch {
            Write-Log -Nivel AVISO -Area '08:Prefetch' -Mensagem ('Falha ao copiar {0}: {1}' -f $arq.FullName, $_.Exception.Message)
        }
        [pscustomobject]@{ Nome = $arq.Name; Original = $arq.FullName; Criado = $criado; Modificado = $modificado }
    }
}

function Get-VestigioPrefetch {
    <# Prefetch: copia os .pf para o bruto e gera PrimeiraExecucao (CreationTime) e UltimaExecucao (LastWriteTime). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Destino,
        [string]$Pasta = ''
    )
    foreach ($pf in @(Copy-BrutoPrefetch -Destino $Destino -Pasta $Pasta)) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($pf.Nome)
        $i = $base.LastIndexOf('-')
        $item = $base; $hash = ''
        if ($i -gt 0) { $item = $base.Substring(0, $i); $hash = $base.Substring($i + 1) }
        New-Vestigio -Fonte 'Prefetch' -Item $item -Data (ConvertTo-DataTexto $pf.Criado) -TipoData 'PrimeiraExecucao' -Detalhe ('HashCaminho=' + $hash)
        New-Vestigio -Fonte 'Prefetch' -Item $item -Data (ConvertTo-DataTexto $pf.Modificado) -TipoData 'UltimaExecucao' -Detalhe ('HashCaminho=' + $hash)
    }
}

function Get-MsiPropriedades {
    <# ProductName, Manufacturer e ProductVersion: .msi pela tabela Property (modo 0, somente leitura);
       .msp pela MsiPatchMetadata (modo 32, patch somente leitura; DisplayName/ManufacturerName). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Caminho)
    $h = @{}
    $modo = 0
    $tabela = 'Property'
    $mapa = @{ ProductName = 'ProductName'; Manufacturer = 'Manufacturer'; ProductVersion = 'ProductVersion' }
    if ([System.IO.Path]::GetExtension($Caminho) -ieq '.msp') {
        $modo = 32
        $tabela = 'MsiPatchMetadata'
        $mapa = @{ DisplayName = 'ProductName'; ManufacturerName = 'Manufacturer' }
    }
    $inst = $null; $db = $null; $view = $null; $rec = $null
    try {
        $inst = New-ObjetoCom -ProgId 'WindowsInstaller.Installer'
        $db = Invoke-ComMembro -Objeto $inst -Nome 'OpenDatabase' -Argumentos @($Caminho, $modo)
        $view = Invoke-ComMembro -Objeto $db -Nome 'OpenView' -Argumentos @('SELECT Property, Value FROM ' + $tabela)
        $null = Invoke-ComMembro -Objeto $view -Nome 'Execute'
        while ($true) {
            $rec = Invoke-ComMembro -Objeto $view -Nome 'Fetch'
            if ($null -eq $rec) { break }
            $nome = [string](Invoke-ComMembro -Objeto $rec -Nome 'StringData' -Tipo 'GetProperty' -Argumentos @(1))
            if ($mapa.ContainsKey($nome)) {
                $h[$mapa[$nome]] = [string](Invoke-ComMembro -Objeto $rec -Nome 'StringData' -Tipo 'GetProperty' -Argumentos @(2))
            }
            Clear-ComObjetos @($rec)
            $rec = $null
        }
    } finally {
        Clear-ComObjetos @($rec, $view, $db, $inst)
    }
    return $h
}

function Get-VestigioInstallerCache {
    <# C:\Windows\Installer\*.msi e *.msp: produto, fabricante e versao; falha por arquivo vira Detalhe='Erro leitura'. #>
    [CmdletBinding()]
    param([string]$Pasta = '')
    if (-not $Pasta) { $Pasta = Join-Path (Get-PastaWindows) 'Installer' }
    $arquivos = @(Get-ChildItem -LiteralPath $Pasta -File -Force -ErrorAction Stop | Where-Object { @('.msi', '.msp') -contains $_.Extension.ToLowerInvariant() })
    foreach ($a in $arquivos) {
        $pr = @{}; $det = ''
        try { $pr = Get-MsiPropriedades -Caminho $a.FullName } catch {
            $det = 'Erro leitura'
            Write-Log -Nivel AVISO -Area '08:InstallerCache' -Mensagem ('Falha ao ler {0}: {1}' -f $a.FullName, $_.Exception.Message)
        }
        $item = [string]$pr['ProductName']; if (-not $item) { $item = $a.Name }
        New-Vestigio -Fonte 'InstallerCache' -Item $item -Fabricante ([string]$pr['Manufacturer']) -Versao ([string]$pr['ProductVersion']) `
            -Data (ConvertTo-DataTexto $a.CreationTime) -TipoData 'ArquivoCriado' -Caminho $a.FullName -Detalhe $det
    }
}

function Get-VestigioAtalhos {
    <# Atalhos .lnk do Menu Iniciar e da Area de Trabalho (comuns e de cada perfil), com o alvo via WScript.Shell. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$Perfis)
    $raizes = New-Object System.Collections.Generic.List[object]
    if ($env:ProgramData) { $raizes.Add(@{ Pasta = [System.IO.Path]::Combine($env:ProgramData, 'Microsoft', 'Windows', 'Start Menu'); Usuario = '' }) }
    $raizes.Add(@{ Pasta = 'C:\Users\Public\Desktop'; Usuario = '' })
    if ($null -ne $Perfis) {
        foreach ($p in $Perfis) {
            if ($null -eq $p -or -not $p.Caminho) { continue }
            $raizes.Add(@{ Pasta = [System.IO.Path]::Combine([string]$p.Caminho, 'AppData', 'Roaming', 'Microsoft', 'Windows', 'Start Menu'); Usuario = [string]$p.Usuario })
            $raizes.Add(@{ Pasta = [System.IO.Path]::Combine([string]$p.Caminho, 'Desktop'); Usuario = [string]$p.Usuario })
        }
    }
    $shell = $null
    try {
        $shell = New-ObjetoCom -ProgId 'WScript.Shell'
        foreach ($r in $raizes) {
            if (-not (Test-Path -LiteralPath $r.Pasta)) { continue }
            $erros = $null
            $lnks = @(Get-ChildItem -LiteralPath $r.Pasta -Filter '*.lnk' -File -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable erros)
            if ($erros) { Write-Log -Nivel AVISO -Area '08:Atalho' -Mensagem ('{0}: {1} erro(s) de acesso' -f $r.Pasta, @($erros).Count) }
            foreach ($l in $lnks) {
                $alvo = ''
                $sc = $null
                try {
                    $sc = $shell.CreateShortcut($l.FullName)
                    $alvo = [string]$sc.TargetPath
                } catch {
                    Write-Log -Nivel AVISO -Area '08:Atalho' -Mensagem ('Falha ao ler {0}: {1}' -f $l.FullName, $_.Exception.Message)
                } finally {
                    Clear-ComObjetos @($sc)
                }
                New-Vestigio -Fonte 'Atalho' -Item ([System.IO.Path]::GetFileNameWithoutExtension($l.Name)) -Caminho $alvo `
                    -Data (ConvertTo-DataTexto $l.LastWriteTime) -TipoData 'ArquivoModificado' -Usuario $r.Usuario `
                    -Detalhe ('Atalho={0};AlvoExiste={1}' -f $l.FullName, (Test-CaminhoExiste $alvo))
            }
        }
    } finally {
        Clear-ComObjetos @($shell)
    }
}

function Get-VestigioFirewall {
    <# Regras de firewall com programa especifico (filtros de aplicacao carregados em lote e juntados por InstanceID). #>
    [CmdletBinding()]
    param()
    $regras = @{}
    foreach ($r in @(Get-NetFirewallRule -ErrorAction Stop)) { $regras[[string]$r.InstanceID] = $r }
    foreach ($f in @(Get-NetFirewallApplicationFilter -ErrorAction Stop)) {
        $prog = [string]$f.Program
        if (-not $prog -or $prog -eq 'Any') { continue }
        $id = [string]$f.InstanceID
        $r = $regras[$id]
        $item = $id
        $dir = ''; $acao = ''; $hab = ''
        if ($null -ne $r) {
            if ($r.DisplayName) { $item = [string]$r.DisplayName }
            $dir = [string]$r.Direction; $acao = [string]$r.Action
            if ([string]$r.Enabled -eq 'True' -or [string]$r.Enabled -eq '1') { $hab = 'Sim' } else { $hab = 'Nao' }
        }
        if (-not $item) { continue }
        $cam = ConvertTo-CaminhoNormalizado $prog
        New-Vestigio -Fonte 'Firewall' -Item $item -Caminho $cam `
            -Detalhe ('Direcao={0};Acao={1};Habilitada={2};ProgramaExiste={3}' -f $dir, $acao, $hab, (Test-CaminhoExiste $cam))
    }
}

function Get-VestigioDefender {
    <# Deteccoes do Defender (Get-MpThreatDetection) e eventos 1116/1117 do log Operational. #>
    [CmdletBinding()]
    param()
    $falhas = New-Object System.Collections.Generic.List[string]
    $saida = New-Object System.Collections.Generic.List[object]
    try {
        $nomes = @{}
        try {
            foreach ($t in @(Get-MpThreat -ErrorAction Stop)) { $nomes[[string]$t.ThreatID] = [string]$t.ThreatName }
        } catch {
            Write-Log -Nivel AVISO -Area '08:Defender' -Mensagem ('Get-MpThreat falhou: ' + $_.Exception.Message)
        }
        foreach ($d in @(Get-MpThreatDetection -ErrorAction Stop)) {
            $id = [string]$d.ThreatID
            $item = $nomes[$id]; if (-not $item) { $item = $id }
            if (-not $item) { continue }
            $acao = ''
            if ($d.ActionSuccess -is [bool]) { if ($d.ActionSuccess) { $acao = 'Sim' } else { $acao = 'Nao' } }
            $saida.Add((New-Vestigio -Fonte 'Defender' -Item $item -Caminho ((@($d.Resources) | Where-Object { $_ }) -join '; ') `
                -Data (ConvertTo-DataTexto $d.InitialDetectionTime) -TipoData 'Deteccao' -Usuario ([string]$d.DomainUser) `
                -Detalhe ('Acao={0};Processo={1}' -f $acao, [string]$d.ProcessName)))
        }
    } catch {
        $falhas.Add('Get-MpThreatDetection: ' + $_.Exception.Message)
    }
    try {
        $eventos = @()
        try {
            $eventos = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Windows Defender/Operational'; Id = 1116, 1117 } -ErrorAction Stop)
        } catch {
            if (-not (Test-ErroSemEventos $_)) { throw }
        }
        foreach ($e in $eventos) {
            $dados = @{}
            foreach ($x in @(([xml]$e.ToXml()).Event.EventData.Data)) {
                if ($null -ne $x -and $x.Name) { $dados[[string]$x.Name] = [string]$x.'#text' }
            }
            $item = $dados['Threat Name']; if (-not $item) { $item = $dados['Threat ID'] }
            if (-not $item) { continue }
            $saida.Add((New-Vestigio -Fonte 'Defender' -Item $item -Caminho ([string]$dados['Path']) -Data (ConvertTo-DataTexto $e.TimeCreated) `
                -TipoData 'Deteccao' -Usuario ([string]$dados['Detection User']) -Detalhe ('EventId=' + [int]$e.Id)))
        }
    } catch {
        $falhas.Add('Eventos: ' + $_.Exception.Message)
    }
    if ($falhas.Count -eq 2) { throw ($falhas -join ' | ') }
    foreach ($f in $falhas) { Write-Log -Nivel AVISO -Area '08:Defender' -Mensagem $f }
    $saida.ToArray()
}

function Get-ColetaVestigios {
    <# Area 08: todas as fontes de vestigios, cada uma isolada por Invoke-Fonte. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$Perfis,
        [Parameter(Mandatory)][string]$PastaColeta
    )
    $pastaBrutos = Join-Path $PastaColeta 'brutos'
    $pastaTrabalho = Join-Path $PastaColeta '_tmp'
    Invoke-Fonte -Area '08' -Nome 'EventoMSI' -Bloco { Get-VestigioEventoMsi }
    Invoke-Fonte -Area '08' -Nome 'Amcache' -RequerAdmin -Bloco {
        $null = New-Item -ItemType Directory -Path $pastaTrabalho -Force -ErrorAction Stop
        $copia = Copy-BrutoAmcache -Destino (Join-Path $pastaBrutos 'Amcache')
        Get-VestigioAmcache -CopiaHve $copia -PastaTmp $pastaTrabalho
    }
    Invoke-Fonte -Area '08' -Nome 'ShimCache' -RequerAdmin -Bloco { Get-VestigioShimCache }
    Invoke-Fonte -Area '08' -Nome 'BAM' -RequerAdmin -Bloco { Get-VestigioBam }
    Invoke-Fonte -Area '08' -Nome 'Prefetch' -RequerAdmin -Bloco { Get-VestigioPrefetch -Destino (Join-Path $pastaBrutos 'Prefetch') }
    Invoke-Fonte -Area '08' -Nome 'UserAssist' -Bloco { Get-VestigioUserAssist -Perfis $Perfis }
    Invoke-Fonte -Area '08' -Nome 'MUICache' -Bloco { Get-VestigioMuiCache -Perfis $Perfis }
    Invoke-Fonte -Area '08' -Nome 'CompatAssistant' -Bloco { Get-VestigioCompatAssistant -Perfis $Perfis }
    Invoke-Fonte -Area '08' -Nome 'ChaveSoftware' -Bloco { Get-VestigioChaveSoftware -Perfis $Perfis }
    Invoke-Fonte -Area '08' -Nome 'InstallerCache' -RequerAdmin -Bloco { Get-VestigioInstallerCache }
    Invoke-Fonte -Area '08' -Nome 'Atalho' -Bloco { Get-VestigioAtalhos -Perfis $Perfis }
    Invoke-Fonte -Area '08' -Nome 'Firewall' -Bloco { Get-VestigioFirewall }
    Invoke-Fonte -Area '08' -Nome 'Defender' -Bloco { Get-VestigioDefender }
}
#endregion Vestigios

#region Arquivos
$Script:ExtensoesInstaladores = @('.exe', '.msi', '.msix', '.msixbundle', '.appx', '.appxbundle', '.iso', '.img', '.zip', '.rar', '.7z')

function Get-EntradasDiretorio {
    <# Lista subdiretorios e (opcionalmente) arquivos de um diretorio; cada listagem tem seu try,
       os arrays sao materializados dentro dele e Falhou indica que alguma delas foi negada. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.IO.DirectoryInfo]$Dir, [bool]$ComArquivos = $true)
    $falhou = $false; $subs = @(); $arqs = @()
    try { $subs = @($Dir.GetDirectories()) } catch { $falhou = $true }
    if ($ComArquivos) {
        try { $arqs = @($Dir.GetFiles()) } catch { $falhou = $true }
    }
    return [pscustomobject]@{ Subdirs = $subs; Arquivos = $arqs; Falhou = $falhou }
}

function Get-ArquivosAlvo {
    <# Percorre Raiz (pilha de DirectoryInfo, sem seguir reparse points) e EMITE FileInfo das extensoes pedidas.
       -Excluir: itens @{Prefixo; Excecoes} comparados (sem diferenciar maiusculas) com caminho completo + separador;
       diretorios dentro de uma excecao voltam a ser varridos. Acesso negado por diretorio e contado e resumido no log. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Raiz,
        [Parameter(Mandatory)][string[]]$Extensoes,
        [object[]]$Excluir = @()
    )
    $sep = [string][System.IO.Path]::DirectorySeparatorChar
    $alt = [string][System.IO.Path]::AltDirectorySeparatorChar
    $cmp = [System.StringComparison]::OrdinalIgnoreCase
    $norm = {
        param([string]$p)
        if ($alt -ne $sep) { $p = $p.Replace($alt, $sep) }
        return ($p.TrimEnd($sep) + $sep)
    }
    $exts = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($e in $Extensoes) { $null = $exts.Add($e) }
    $regras = New-Object System.Collections.Generic.List[object]
    foreach ($x in @($Excluir)) {
        if ($null -eq $x) { continue }
        $pref = ''; $exc = @()
        if ($x -is [string]) { $pref = $x } else { $pref = [string]$x['Prefixo']; if ($x['Excecoes']) { $exc = @($x['Excecoes']) } }
        if (-not $pref) { continue }
        $regras.Add([pscustomobject]@{ Prefixo = (& $norm $pref); Excecoes = [string[]]@($exc | ForEach-Object { & $norm ([string]$_) }) })
    }

    $negadas = 0; $total = 0
    $rootInfo = New-Object System.IO.DirectoryInfo $Raiz
    if (-not $rootInfo.Exists) {
        Write-Log -Nivel 'AVISO' -Area 'Arquivos' -Mensagem ('{0}: raiz inexistente ou inacessivel' -f $Raiz)
        return
    }
    $pilha = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $pilha.Push($rootInfo)
    while ($pilha.Count -gt 0) {
        $dir = $pilha.Pop()
        $caminho = & $norm $dir.FullName
        # Regra de exclusao aplicavel e fora de qualquer excecao?
        $excluido = $false
        $excecoesAtivas = $null
        foreach ($r in $regras) {
            if ($caminho.StartsWith($r.Prefixo, $cmp)) {
                $dentro = $false
                foreach ($ex in $r.Excecoes) { if ($caminho.StartsWith($ex, $cmp)) { $dentro = $true; break } }
                if (-not $dentro) { $excluido = $true; $excecoesAtivas = $r.Excecoes; break }
            }
        }
        $ent = Get-EntradasDiretorio -Dir $dir -ComArquivos (-not $excluido)
        if ($ent.Falhou) { $negadas++ }
        $subdirs = $ent.Subdirs; $arquivos = $ent.Arquivos
        if ($arquivos) {
            foreach ($f in $arquivos) {
                if ($exts.Contains($f.Extension)) { $total++; $f }
            }
        }
        foreach ($d in $subdirs) {
            if (($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            if ($excluido) {
                # Em diretorio excluido so desce no filho que leva a uma excecao.
                $filho = & $norm $d.FullName
                $leva = $false
                foreach ($ex in $excecoesAtivas) { if ($ex.StartsWith($filho, $cmp)) { $leva = $true; break } }
                if (-not $leva) { continue }
            }
            $pilha.Push($d)
        }
    }
    $nivel = 'INFO'; if ($negadas -gt 0) { $nivel = 'AVISO' }
    Write-Log -Nivel $nivel -Area 'Arquivos' -Mensagem ('{0}: {1} arquivos, {2} pastas sem acesso' -f $Raiz, $total, $negadas)
}

function Test-ArquivoSomenteNuvem {
    <# Arquivo de nuvem nao baixado (OneDrive "sob demanda"): Offline 0x1000, RecallOnOpen 0x40000 ou
       RecallOnDataAccess 0x400000. Ler o conteudo dispararia o download. ReparsePoint sozinho nao conta. #>
    param([int]$Atributos)
    return (($Atributos -band 0x441000) -ne 0)
}

function Write-LogSomenteNuvem {
    param([string]$Raiz, [int]$Quantidade)
    if ($Quantidade -gt 0) {
        Write-Log -Nivel 'AVISO' -Area 'Arquivos' -Mensagem ('{0}: {1} arquivos somente na nuvem nao lidos' -f $Raiz, $Quantidade)
    }
}

function New-LinhaArquivo {
    <# Linha das areas 15/16. LimiteHash 0 = sem limite; acima do limite o SHA256 fica vazio. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$Arquivo,
        [Parameter(Mandatory)][string]$Local,
        [AllowEmptyString()][Parameter(Mandatory)][string]$Usuario,
        [Parameter(Mandatory)][long]$LimiteHash
    )
    $ext = $Arquivo.Extension.ToLowerInvariant()
    $produto = ''; $empresa = ''; $versao = ''
    $nuvem = Test-ArquivoSomenteNuvem -Atributos ([int]$Arquivo.Attributes)
    if ($nuvem) {
        # sem ler o conteudo (versao, propriedades MSI e hash ficam vazios)
    } elseif ($ext -eq '.exe') {
        try {
            $vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Arquivo.FullName)
            $produto = [string]$vi.ProductName; $empresa = [string]$vi.CompanyName; $versao = [string]$vi.ProductVersion
        } catch { }
    } elseif ($ext -eq '.msi') {
        try {
            $m = Get-MsiPropriedades -Caminho $Arquivo.FullName
            if ($m) { $produto = [string]$m['ProductName']; $empresa = [string]$m['Manufacturer']; $versao = [string]$m['ProductVersion'] }
        } catch { }
    }
    $tamanho = [long]$Arquivo.Length
    $hash = ''
    if ($nuvem) {
        $hash = ''
    } elseif ($LimiteHash -gt 0 -and $tamanho -gt $LimiteHash) {
        Write-Log -Nivel 'AVISO' -Area 'Arquivos' -Mensagem ('Hash omitido (> 1 GB): {0}' -f $Arquivo.FullName)
    } else {
        try {
            $hash = ([string](Get-FileHash -LiteralPath $Arquivo.FullName -Algorithm SHA256 -ErrorAction Stop).Hash).ToLowerInvariant()
        } catch {
            $hash = ''
            Write-Log -Nivel 'AVISO' -Area 'Arquivos' -Mensagem ('Hash nao calculado ({0}): {1}' -f $_.Exception.Message, $Arquivo.FullName)
        }
    }
    $area = '15'
    return New-LinhaContrato -Area $area -Valores @{
        Local = $Local; Usuario = $Usuario; Caminho = $Arquivo.FullName; Arquivo = $Arquivo.Name; Extensao = $ext
        TamanhoBytes = $tamanho; CriadoEm = $Arquivo.CreationTime; ModificadoEm = $Arquivo.LastWriteTime
        ProductName = $produto; CompanyName = $empresa; ProductVersion = $versao; SHA256 = $hash
    }
}

function Get-RaizesPastasProgramas {
    <# Raizes da area 14; inexistentes omitidas e duplicadas (SO 32 bits) removidas. #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Perfis = @())
    $cand = New-Object System.Collections.Generic.List[object]
    $pf = $env:ProgramFiles; $pf86 = ${env:ProgramFiles(x86)}
    if ($pf) {
        $cand.Add(@{ Raiz = 'ProgramFiles'; Usuario = ''; Caminho = $pf })
    }
    if ($pf86) { $cand.Add(@{ Raiz = 'ProgramFiles(x86)'; Usuario = ''; Caminho = $pf86 }) }
    if ($pf) { $cand.Add(@{ Raiz = 'ProgramFiles\Common Files'; Usuario = ''; Caminho = (Join-Path $pf 'Common Files') }) }
    if ($pf86) { $cand.Add(@{ Raiz = 'ProgramFiles(x86)\Common Files'; Usuario = ''; Caminho = (Join-Path $pf86 'Common Files') }) }
    if ($env:ProgramData) { $cand.Add(@{ Raiz = 'ProgramData'; Usuario = ''; Caminho = $env:ProgramData }) }
    foreach ($p in @($Perfis)) {
        if (-not $p -or -not $p.Caminho) { continue }
        foreach ($sub in 'AppData\Local', 'AppData\Roaming', 'AppData\LocalLow') {
            $cam = Join-Path $p.Caminho ($sub.Replace('\', [string][System.IO.Path]::DirectorySeparatorChar))
            $cand.Add(@{ Raiz = $sub; Usuario = [string]$p.Usuario; Caminho = $cam })
        }
    }
    $vistos = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $saida = New-Object System.Collections.Generic.List[object]
    foreach ($c in $cand) {
        if (-not (Test-Path -LiteralPath $c.Caminho -PathType Container)) { continue }
        if ($vistos.Add($c.Caminho.TrimEnd([System.IO.Path]::DirectorySeparatorChar))) { $saida.Add($c) }
    }
    return $saida.ToArray()
}

function Get-ColetaPastasProgramas {
    <# Area 14: so as pastas de 1o nivel de cada raiz. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Raizes)
    $linhas = New-Object System.Collections.Generic.List[object]
    foreach ($r in @($Raizes)) {
        try {
            $subs = @((New-Object System.IO.DirectoryInfo $r.Caminho).GetDirectories())
        } catch {
            Write-Log -Nivel 'AVISO' -Area 'Arquivos' -Mensagem ('{0}: pastas nao listadas ({1})' -f $r.Caminho, $_.Exception.Message)
            continue
        }
        foreach ($d in $subs) {
            $linhas.Add((New-LinhaContrato -Area '14' -Valores @{
                Raiz = [string]$r.Raiz; Usuario = [string]$r.Usuario; Pasta = $d.Name; Caminho = $d.FullName
                CriadoEm = $d.CreationTime; ModificadoEm = $d.LastWriteTime
            }))
        }
    }
    return $linhas.ToArray()
}

function Get-UnidadeColeta {
    <# Letra ('E:') do volume que contem a pasta da coleta (ou -Caminho), ou '' (UNC, vazio ou indeterminado). #>
    param([string]$Caminho)
    $p = $Caminho
    if (-not $p -and $null -ne $Script:Ctx) { $p = [string]$Script:Ctx.PastaColeta }
    if (-not $p) { return '' }
    $raiz = ''
    try { $raiz = [string][System.IO.Path]::GetPathRoot($p) } catch { $raiz = '' }
    # fora do Windows GetPathRoot nao reconhece 'X:\' (usado nos testes)
    if ($raiz -notmatch '^[A-Za-z]:' -and $p -match '^[A-Za-z]:') { $raiz = $p.Substring(0, 2) }
    $raiz = $raiz.TrimEnd('\', '/')
    if ($raiz -match '^[A-Za-z]:$') { return $raiz.ToUpperInvariant() }
    return ''
}

function Get-DiscosFixosSemColeta {
    <# Win32_LogicalDisk DriveType=3 sem a unidade onde a coleta e gravada (a midia do coletor).
       Se a coleta esta no disco do sistema, ele continua na lista (a area 16 exclui so a pasta da coleta). #>
    $unidade = Get-UnidadeColeta
    $sistema = ([string]$env:SystemDrive).TrimEnd('\').ToUpperInvariant()
    if ($unidade -and $unidade -eq $sistema) { $unidade = '' }
    foreach ($d in @(Get-CimSafe -ClassName 'Win32_LogicalDisk' -Filter 'DriveType=3')) {
        if (-not $d.DeviceID) { continue }
        if ($unidade -and [string]::Equals(([string]$d.DeviceID).TrimEnd('\'), $unidade, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Log -Nivel 'INFO' -Area 'Arquivos' -Mensagem ('Unidade da coleta excluida: ' + $unidade)
            continue
        }
        $d
    }
}

function Get-RaizesInstaladores {
    <# Raizes da area 15: Downloads, Desktop e Documents por perfil e a Lixeira de cada disco fixo. #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Perfis = @())
    $saida = New-Object System.Collections.Generic.List[object]
    foreach ($p in @($Perfis)) {
        if (-not $p -or -not $p.Caminho) { continue }
        foreach ($nome in 'Downloads', 'Desktop', 'Documents') {
            $cam = Join-Path $p.Caminho $nome
            if (Test-Path -LiteralPath $cam -PathType Container) {
                $saida.Add(@{ Local = $nome; Usuario = [string]$p.Usuario; Caminho = $cam })
            }
        }
    }
    try {
        foreach ($d in @(Get-DiscosFixosSemColeta)) {
            $saida.Add(@{ Local = 'Lixeira'; Usuario = ''; Caminho = ([string]$d.DeviceID + [System.IO.Path]::DirectorySeparatorChar + '$Recycle.Bin') })
        }
    } catch {
        Write-Log -Nivel 'AVISO' -Area 'Arquivos' -Mensagem ('Lixeira ignorada, discos nao listados: ' + $_.Exception.Message)
    }
    return $saida.ToArray()
}

function Get-ColetaArquivosInstaladores {
    <# Area 15: instaladores nas raizes, SHA-256 ate 1 GB. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Raizes)
    foreach ($r in @($Raizes)) {
        $local = [string]$r.Local; $usuario = [string]$r.Usuario
        $nuvem = 0
        Get-ArquivosAlvo -Raiz $r.Caminho -Extensoes $Script:ExtensoesInstaladores | ForEach-Object {
            $arq = $_
            if (Test-ArquivoSomenteNuvem -Atributos ([int]$arq.Attributes)) { $nuvem++ }
            try {
                New-LinhaArquivo -Arquivo $arq -Local $local -Usuario $usuario -LimiteHash 1GB
            } catch {
                Write-Log -Nivel 'AVISO' -Area 'Arquivos' -Mensagem ('{0}: {1}' -f $arq.FullName, $_.Exception.Message)
            }
        }
        Write-LogSomenteNuvem -Raiz ([string]$r.Caminho) -Quantidade $nuvem
    }
}

function Get-ColetaArquivosCompleta {
    <# Area 16: mesmas extensoes em todos os discos fixos, sem limite de hash; exclui WINDIR exceto WINDIR\Installer. #>
    [CmdletBinding()]
    param()
    $sep = [string][System.IO.Path]::DirectorySeparatorChar
    $discos = @()
    try {
        $discos = @(Get-DiscosFixosSemColeta)
    } catch {
        Write-Log -Nivel 'ERRO' -Area 'Arquivos' -Mensagem ('Discos fixos nao listados: ' + $_.Exception.Message)
        return @()
    }
    $excluir = New-Object System.Collections.Generic.List[object]
    if ($env:WINDIR) {
        $excluir.Add(@{ Prefixo = $env:WINDIR; Excecoes = [string[]]@((Join-Path $env:WINDIR 'Installer')) })
    }
    # coleta gravada num disco varrido (disco do sistema): fora a pasta da coleta e os ZIPs de coletas anteriores ao lado dela
    $pastaColeta = ''; $dirColetas = ''
    if ($null -ne $Script:Ctx -and $Script:Ctx.PastaColeta) {
        $pastaColeta = ([string]$Script:Ctx.PastaColeta).TrimEnd('\', '/')
        $excluir.Add(@{ Prefixo = $pastaColeta; Excecoes = [string[]]@() })
        $i = $pastaColeta.LastIndexOfAny([char[]]@('\', '/'))
        if ($i -gt 0) { $dirColetas = $pastaColeta.Substring(0, $i).TrimEnd('\', '/') }
    }
    $excluir = $excluir.ToArray()
    foreach ($d in $discos) {
        if (-not $d.DeviceID) { continue }
        $letra = ([string]$d.DeviceID).TrimEnd(':')
        $local = 'Disco ' + $letra
        $nuvem = 0
        Get-ArquivosAlvo -Raiz ([string]$d.DeviceID + $sep) -Extensoes $Script:ExtensoesInstaladores -Excluir $excluir | ForEach-Object {
            $arq = $_
            if ($dirColetas -and
                ([string]$arq.Name) -like 'InventarioForense_*' -and
                [string]::Equals(([string]$arq.DirectoryName).TrimEnd('\', '/'), $dirColetas, [System.StringComparison]::OrdinalIgnoreCase)) { return }
            if (Test-ArquivoSomenteNuvem -Atributos ([int]$arq.Attributes)) { $nuvem++ }
            try {
                New-LinhaArquivo -Arquivo $arq -Local $local -Usuario '' -LimiteHash 0
            } catch {
                Write-Log -Nivel 'AVISO' -Area 'Arquivos' -Mensagem ('{0}: {1}' -f $arq.FullName, $_.Exception.Message)
            }
        }
        Write-LogSomenteNuvem -Raiz ([string]$d.DeviceID + $sep) -Quantidade $nuvem
    }
}
#endregion Arquivos

#region Saidas
function Get-FusoHorarioTexto {
    <# Id do fuso local e deslocamento atual: 'Id (UTC+hh:mm)'. #>
    [CmdletBinding()]
    param()
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $off = [TimeZoneInfo]::Local.GetUtcOffset([datetime]::Now)
    $sinal = '+'
    if ($off -lt [TimeSpan]::Zero) { $sinal = '-'; $off = $off.Negate() }
    return ([TimeZoneInfo]::Local.Id + ' (UTC' + $sinal + $off.ToString('hh\:mm', $inv) + ')')
}

function ConvertFrom-InstallDateUnix {
    <# InstallDate do registro (REG_DWORD, segundos Unix UTC) -> DateTime local; $null se ausente/invalido. #>
    [CmdletBinding()]
    param([AllowNull()][object]$Valor)
    if ($null -eq $Valor) { return $null }
    try {
        $s = [long]$Valor
        if ($s -le 0) { return $null }
        return [DateTimeOffset]::FromUnixTimeSeconds($s).LocalDateTime
    } catch {
        return $null
    }
}

function Get-DataInstalacaoOriginal {
    <# Data mais antiga entre as chaves HKLM\SYSTEM\Setup\Source OS (...) (gravadas a cada atualizacao de versao); $null se nao houver. #>
    [CmdletBinding()]
    param()
    $setup = 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\Setup'
    $menor = $null
    foreach ($nome in @(Get-RegSubchaves -Caminho $setup)) {
        if ($nome -notlike 'Source OS*') { continue }
        $vals = Get-RegValores -Caminho ($setup + '\' + $nome)
        $dt = ConvertFrom-InstallDateUnix $vals['InstallDate']
        if ($null -ne $dt -and ($null -eq $menor -or $dt -lt $menor)) { $menor = $dt }
    }
    return $menor
}

function Get-ColetaResumo {
    <# Area 01: uma linha por maquina. Cada consulta CIM e isolada; em erro o campo fica vazio. #>
    [CmdletBinding()]
    param()
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $ctx = $Script:Ctx
    $v = @{}
    foreach ($k in 'Etiqueta', 'Setor', 'ExecutadoPor', 'Observacao') {
        $val = ''
        if ($ctx.Parametros.Contains($k)) { $val = [string]$ctx.Parametros[$k] }
        $v[$k] = $val
    }

    try {
        $cs = @(Get-CimSafe -ClassName Win32_ComputerSystem) | Select-Object -First 1
        if ($cs) {
            $v['Fabricante'] = $cs.Manufacturer
            $v['Modelo'] = $cs.Model
            $v['DominioOuGrupo'] = $cs.Domain
            $v['ParteDeDominio'] = $cs.PartOfDomain
            $v['UsuarioLogado'] = $cs.UserName
            if ($null -ne $cs.TotalPhysicalMemory) { $v['MemoriaGB'] = [math]::Round(([double]$cs.TotalPhysicalMemory) / 1GB, 2) }
        }
    } catch { }

    try {
        $bios = $null
        if ($ctx.Cache.ContainsKey('BIOS') -and $null -ne $ctx.Cache['BIOS']) { $bios = @($ctx.Cache['BIOS']) | Select-Object -First 1 }
        else { $bios = @(Get-CimSafe -ClassName Win32_BIOS) | Select-Object -First 1 }
        if ($bios) { $v['NumeroSerie'] = $bios.SerialNumber }
    } catch { }

    $reg = @{}
    try { $reg = Get-RegValores -Caminho 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion' } catch { }
    $os = $null
    try {
        $os = @(Get-CimSafe -ClassName Win32_OperatingSystem) | Select-Object -First 1
        if ($os) {
            $v['SistemaOperacional'] = $os.Caption
            $v['Arquitetura'] = $os.OSArchitecture
            # no WMI legado as datas vem em DMTF (texto)
            $v['SOAtualizadoEm'] = ConvertTo-DataTexto $os.InstallDate
            $v['UltimoBoot'] = ConvertTo-DataTexto $os.LastBootUpTime
        }
    } catch { }
    # InstallDate do WMI muda a cada atualizacao de versao; a original fica nas chaves Source OS
    if (-not $v['SOAtualizadoEm']) {
        $atual = ConvertFrom-InstallDateUnix $reg['InstallDate']
        if ($null -ne $atual) { $v['SOAtualizadoEm'] = ConvertTo-DataTexto $atual }
    }
    $original = $null
    try { $original = Get-DataInstalacaoOriginal } catch {
        Write-Log -Nivel AVISO -Area '01' -Mensagem ('Source OS ilegivel: ' + $_.Exception.Message)
    }
    if ($null -ne $original) { $v['SOInstaladoEm'] = ConvertTo-DataTexto $original }
    else { $v['SOInstaladoEm'] = $v['SOAtualizadoEm'] }
    if ($reg['EditionID']) { $v['Edicao'] = $reg['EditionID'] }
    elseif ($os) { $v['Edicao'] = [string]$os.OperatingSystemSKU }
    $build = ''
    if ($os -and $os.BuildNumber) { $build = [string]$os.BuildNumber } elseif ($reg['CurrentBuild']) { $build = [string]$reg['CurrentBuild'] }
    if ($build -and $reg.ContainsKey('UBR') -and $null -ne $reg['UBR']) { $build = $build + '.' + ([string]$reg['UBR']) }
    if ($build) { $v['Build'] = $build }
    if ($reg['DisplayVersion']) { $v['Versao'] = $reg['DisplayVersion'] } elseif ($reg['ReleaseId']) { $v['Versao'] = $reg['ReleaseId'] }

    try {
        $cpus = @(Get-CimSafe -ClassName Win32_Processor)
        if ($cpus.Count -gt 0) {
            $v['Processador'] = ([string]$cpus[0].Name).Trim()
            $n = 0; $t = 0
            foreach ($c in $cpus) { $n += [int]$c.NumberOfCores; $t += [int]$c.NumberOfLogicalProcessors }
            $v['Nucleos'] = $n; $v['Threads'] = $t
        }
    } catch { }

    try {
        if ($ctx.Resultados.Contains('02')) {
            $total = 0.0
            foreach ($d in @($ctx.Resultados['02'])) {
                if ($d.Tipo -eq 'Disco' -and ([string]$d.Detalhe) -notmatch 'Interface=USB' -and $null -ne $d.Capacidade -and $d.Capacidade -ne '') {
                    $total += [double]$d.Capacidade
                }
            }
            $v['DiscoTotalGB'] = [math]::Round($total, 2)
        }
    } catch { }

    try {
        if ($ctx.Resultados.Contains('04')) {
            $ad = @($ctx.Resultados['04'] | Where-Object { $_.Tipo -eq 'Adaptador' -and -not [string]::IsNullOrEmpty([string]$_.EnderecosIP) })
            $v['EnderecosIP'] = (@($ad | ForEach-Object { [string]$_.EnderecosIP }) -join ', ')
            $v['EnderecosMAC'] = (@($ad | ForEach-Object { [string]$_.MAC }) -join ', ')
        }
    } catch { }

    try {
        if ($ctx.Resultados.Contains('09')) {
            $w = @($ctx.Resultados['09'] | Where-Object { ([string]$_.Produto) -like 'Windows*' }) | Select-Object -First 1
            if ($w) { $v['AtivacaoWindows'] = $w.EstadoLicenca }
        }
    } catch { }

    $v['TotalSoftwaresInstalados'] = 0; $v['TotalVestigios'] = 0
    if ($ctx.Resultados.Contains('07')) { $v['TotalSoftwaresInstalados'] = @($ctx.Resultados['07']).Count }
    if ($ctx.Resultados.Contains('08')) { $v['TotalVestigios'] = @($ctx.Resultados['08']).Count }

    $v['ExecutadoComoAdmin'] = [bool]$ctx.Admin
    if ($ctx.Parametros.Contains('Completa') -and $ctx.Parametros['Completa']) { $v['Modo'] = 'Completa' } else { $v['Modo'] = 'Padrao' }
    $v['FusoHorario'] = Get-FusoHorarioTexto
    $v['DuracaoSegundos'] = [int][math]::Round(([datetime]::Now - $ctx.Inicio).TotalSeconds)
    $v['AreasComFalha'] = Get-ListaFalhas
    $v['AreasPuladas'] = Get-ListaPuladas
    return (New-LinhaContrato -Area '01' -Valores $v)
}

function Get-ValorPropriedade {
    param($Item, [string]$Nome)
    if ($Item -is [System.Collections.IDictionary]) { if ($Item.Contains($Nome)) { return $Item[$Nome] } else { return $null } }
    $p = $Item.PSObject.Properties[$Nome]
    if ($p) { return $p.Value }
    return $null
}

$Script:LimiteLinhasFonteTxt = 2000
$Script:LimiteArgumentosTxt = 200

function Write-ColetaTxt {
    <# Coleta.txt: cabecalho, uma secao por area (01..16) e tabela de status. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Caminho)
    $ctx = $Script:Ctx
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $barra = '=' * 78
    $sb = New-Object System.Text.StringBuilder
    $linha = { param($k, $val) [void]$sb.AppendLine(('{0} : {1}' -f $k.PadRight(22), $val)) }

    [void]$sb.AppendLine($barra)
    [void]$sb.AppendLine('INVENTÁRIO DA ESTAÇÃO')
    [void]$sb.AppendLine($barra)
    & $linha 'Hostname' $ctx.Hostname
    & $linha 'IdEquipamento' $ctx.IdEquipamento
    & $linha 'IdEquipamentoOrigem' $ctx.IdEquipamentoOrigem
    foreach ($k in 'Etiqueta', 'Setor', 'ExecutadoPor', 'Observacao') {
        $val = ''; if ($ctx.Parametros.Contains($k)) { $val = [string]$ctx.Parametros[$k] }
        & $linha $k $val
    }
    & $linha 'DataColeta' $ctx.DataColeta
    & $linha 'FusoHorario' (Get-FusoHorarioTexto)
    & $linha 'ExecutadoComoAdmin' (ConvertTo-CampoTexto ([bool]$ctx.Admin))
    $modo = 'Padrao'; if ($ctx.Parametros.Contains('Completa') -and $ctx.Parametros['Completa']) { $modo = 'Completa' }
    & $linha 'Modo' $modo
    [void]$sb.AppendLine('')

    foreach ($n in $Script:Contrato.Keys) {
        if (-not $ctx.Resultados.Contains($n)) { continue }
        $itens = @($ctx.Resultados[$n])
        [void]$sb.AppendLine($barra)
        [void]$sb.AppendLine(('{0} - {1} ({2} itens)' -f $n, $Script:Contrato[$n].Nome, $itens.Count))
        [void]$sb.AppendLine($barra)
        if ($itens.Count -eq 0) { [void]$sb.AppendLine('(sem itens)'); [void]$sb.AppendLine(''); continue }
        $cols = $Script:Contrato[$n].Colunas
        $refCsv = 'ver csv\' + $Script:Contrato[$n].Arquivo
        $prep = {
            param($lista)
            foreach ($it in $lista) {
                $o = [ordered]@{}
                foreach ($c in $cols) { $o[$c] = ConvertTo-CampoTexto (Get-ValorPropriedade $it $c) }
                # 11: argumentos longos truncados so no TXT (o CSV mantem o texto completo)
                if ($n -eq '11' -and $o.Contains('Argumentos') -and $o['Argumentos'].Length -gt $Script:LimiteArgumentosTxt) {
                    $o['Argumentos'] = $o['Argumentos'].Substring(0, $Script:LimiteArgumentosTxt) + '...'
                }
                [pscustomobject]$o
            }
        }
        if ($n -eq '01') {
            $txt = (& $prep $itens) | Format-List | Out-String -Width 4096
            [void]$sb.AppendLine($txt.TrimEnd())
        } elseif ($n -eq '15' -or $n -eq '16') {
            # listas de arquivos: so a contagem no TXT
            [void]$sb.AppendLine(('{0} itens - {1}' -f $itens.Count, $refCsv))
        } elseif ($n -eq '08') {
            $grupos = New-Object System.Collections.Generic.List[string]
            $porFonte = @{}
            foreach ($it in $itens) {
                $f = [string](Get-ValorPropriedade $it 'Fonte')
                if (-not $porFonte.ContainsKey($f)) { $porFonte[$f] = New-Object System.Collections.Generic.List[object]; $grupos.Add($f) }
                $porFonte[$f].Add($it)
            }
            foreach ($f in $grupos) {
                $g = $porFonte[$f]
                [void]$sb.AppendLine(('--- Fonte: {0} ({1} itens) ---' -f $f, $g.Count))
                if ($g.Count -gt $Script:LimiteLinhasFonteTxt) {
                    [void]$sb.AppendLine(('{0} itens - {1}' -f $g.Count, $refCsv))
                } else {
                    $txt = (& $prep $g.ToArray()) | Format-Table -AutoSize | Out-String -Width 4096
                    [void]$sb.AppendLine($txt.TrimEnd())
                }
                [void]$sb.AppendLine('')
            }
        } else {
            $txt = (& $prep $itens) | Format-Table -AutoSize | Out-String -Width 4096
            [void]$sb.AppendLine($txt.TrimEnd())
        }
        [void]$sb.AppendLine('')
    }

    [void]$sb.AppendLine($barra)
    [void]$sb.AppendLine('STATUS DAS AREAS')
    [void]$sb.AppendLine($barra)
    $st = @($ctx.Status | Select-Object Numero, Nome, Status, Itens, Segundos, Mensagem)
    if ($st.Count -gt 0) {
        [void]$sb.AppendLine((($st | Format-Table -AutoSize | Out-String -Width 4096).TrimEnd()))
    } else {
        [void]$sb.AppendLine('(sem status)')
    }
    $texto = ($sb.ToString() -replace "`r?`n", "`r`n")
    Write-TextoUtf8Bom -Caminho $Caminho -Texto $texto
}

function ConvertTo-ItensJson {
    <# Itens como [object[]] de dicionarios ordenados, valores convertidos por ConvertTo-CampoTexto. #>
    param([object[]]$Itens)
    $lista = New-Object System.Collections.Generic.List[object]
    foreach ($i in @($Itens)) {
        if ($null -eq $i) { continue }
        $o = [ordered]@{}
        if ($i -is [System.Collections.IDictionary]) {
            foreach ($k in $i.Keys) { $o[[string]$k] = ConvertTo-CampoTexto $i[$k] }
        } else {
            foreach ($p in $i.PSObject.Properties) { $o[$p.Name] = ConvertTo-CampoTexto $p.Value }
        }
        $lista.Add($o)
    }
    return , ([object[]]$lista.ToArray())
}

function Write-ColetaJson {
    <# Coleta.json: Identificacao, Execucao e uma chave por area (arrays), UTF-8 com BOM. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Caminho)
    $ctx = $Script:Ctx
    $par = { param($k) if ($ctx.Parametros.Contains($k)) { [string]$ctx.Parametros[$k] } else { '' } }
    $modo = 'Padrao'; if ($ctx.Parametros.Contains('Completa') -and $ctx.Parametros['Completa']) { $modo = 'Completa' }

    $doc = [ordered]@{}
    $doc['Identificacao'] = [ordered]@{
        Hostname            = $ctx.Hostname
        IdEquipamento       = $ctx.IdEquipamento
        IdEquipamentoOrigem = $ctx.IdEquipamentoOrigem
        DataColeta          = $ctx.DataColeta
        Etiqueta            = (& $par 'Etiqueta')
        Setor               = (& $par 'Setor')
        ExecutadoPor        = (& $par 'ExecutadoPor')
        Observacao          = (& $par 'Observacao')
        FusoHorario         = (Get-FusoHorarioTexto)
    }
    $doc['Execucao'] = [ordered]@{
        Admin           = [bool]$ctx.Admin
        Modo            = $modo
        DuracaoSegundos = [int][math]::Round(([datetime]::Now - $ctx.Inicio).TotalSeconds)
        Status          = (ConvertTo-ItensJson -Itens $ctx.Status.ToArray())
        FontesComFalha  = [object[]]$ctx.FontesComFalha.ToArray()
        FontesPuladas   = [object[]]$ctx.FontesPuladas.ToArray()
        EscritasSistema = [object[]]$ctx.Escritas.ToArray()
    }
    foreach ($n in $Script:Contrato.Keys) {
        if (-not $ctx.Resultados.Contains($n)) { continue }
        $doc[$Script:Contrato[$n].Chave] = (ConvertTo-ItensJson -Itens @($ctx.Resultados[$n]))
    }
    $json = $doc | ConvertTo-Json -Depth 6
    Write-TextoUtf8Bom -Caminho $Caminho -Texto $json
}
#endregion Saidas

#region Integridade
function Get-PastaSaida {
    param([string]$RaizScript, [string]$NomeColeta)
    Join-Path $RaizScript $NomeColeta
}

function Test-PastaGravavel {
    param([string]$Pasta)
    $teste = $null
    try {
        $teste = Join-Path $Pasta (".__teste_" + [guid]::NewGuid().ToString('N'))
        [System.IO.File]::WriteAllText($teste, 'x')
        Remove-Item -LiteralPath $teste -Force -ErrorAction Stop
        return $true
    } catch {
        if ($teste -and (Test-Path -LiteralPath $teste)) {
            try { Remove-Item -LiteralPath $teste -Force -ErrorAction Stop } catch { }
        }
        return $false
    }
}

function Get-Sha256Arquivo {
    param([string]$Caminho)
    (Get-FileHash -Algorithm SHA256 -LiteralPath $Caminho -ErrorAction Stop).Hash.ToLowerInvariant()
}

# Excecao a regra de BOM: o manifesto e o .sha256 sao UTF-8 sem BOM e com LF,
# para o sha256sum -c ler corretamente.
function Write-TextoUtf8SemBom {
    param([string]$Caminho, [string]$Texto)
    [System.IO.File]::WriteAllText($Caminho, $Texto, (New-Object System.Text.UTF8Encoding $false))
}

function Write-Manifesto {
    param([string]$Pasta)
    $raiz = (Resolve-Path -LiteralPath $Pasta).ProviderPath.TrimEnd('\', '/')
    $destino = Join-Path $raiz 'SHA256SUMS.txt'
    $mapa = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath $raiz -Recurse -File -Force -ErrorAction Stop)) {
        if ($f.FullName -eq $destino) { continue }
        $rel = $f.FullName.Substring($raiz.Length + 1).Replace('\', '/')
        # _tmp (copias de hives) nunca entra no manifesto nem no ZIP, mesmo se nao pode ser removida
        if ($rel.StartsWith('_tmp/', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $mapa[$rel] = $f.FullName
    }
    $rels = New-Object 'string[]' $mapa.Count
    $mapa.Keys.CopyTo($rels, 0)
    [Array]::Sort($rels, [System.StringComparer]::Ordinal)
    $sb = New-Object System.Text.StringBuilder
    foreach ($rel in $rels) {
        $null = $sb.Append((Get-Sha256Arquivo -Caminho $mapa[$rel])).Append('  ').Append($rel).Append("`n")
    }
    Write-TextoUtf8SemBom -Caminho $destino -Texto $sb.ToString()
    $destino
}

# No PS 5.1 o enum CompressionLevel vive em System.IO.Compression.dll, que nao e
# carregada junto com System.IO.Compression.FileSystem: carregar as duas, nesta ordem.
function Import-AssemblyCompressao {
    foreach ($nome in @('System.IO.Compression', 'System.IO.Compression.FileSystem')) {
        try { Add-Type -AssemblyName $nome } catch { Write-Warning "Add-Type $nome falhou: $($_.Exception.Message)" }
    }
}

function New-ZipColeta {
    param([string]$Pasta)
    $pasta = $Pasta.TrimEnd('\', '/')
    $zip = $pasta + '.zip'
    if (Test-Path -LiteralPath $zip) { throw "O arquivo ZIP ja existe: $zip" }
    Import-AssemblyCompressao
    $nivel = [System.IO.Compression.CompressionLevel]::Optimal
    # ZIP montado arquivo a arquivo: no PS 5.1 (.NET Framework) o ZipFile grava '\' nos nomes das
    # entradas, fora do padrao ZIP; aqui o separador e sempre '/'. A _tmp que nao pode ser removida fica fora.
    $raiz = (Resolve-Path -LiteralPath $pasta).ProviderPath.TrimEnd('\', '/')
    $base = Split-Path -Leaf $raiz
    $arq = [System.IO.Compression.ZipFile]::Open($zip, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($f in @(Get-ChildItem -LiteralPath $raiz -Recurse -File -Force -ErrorAction Stop)) {
            $rel = $f.FullName.Substring($raiz.Length + 1).Replace('\', '/')
            if ($rel.StartsWith('_tmp/', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            $null = [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($arq, $f.FullName, ($base + '/' + $rel), $nivel)
        }
    } finally { $arq.Dispose() }
    $zip
}

function Write-HashZip {
    param([string]$Zip)
    $destino = $Zip + '.sha256'
    $texto = (Get-Sha256Arquivo -Caminho $Zip) + '  ' + (Split-Path -Leaf $Zip) + "`n"
    Write-TextoUtf8SemBom -Caminho $destino -Texto $texto
    $destino
}

function Test-ZipContraManifesto {
    param([string]$Zip)
    $div = New-Object System.Collections.Generic.List[string]
    Import-AssemblyCompressao
    $hashes = @{}
    $manifesto = $null
    $vistos = @{}
    $arq = [System.IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            foreach ($e in $arq.Entries) {
                $nome = $e.FullName.Replace('\', '/')
                if ($nome.EndsWith('/')) { continue }
                $idx = $nome.IndexOf('/')
                if ($idx -lt 0) { $div.Add("Extra: $nome"); continue }
                $rel = $nome.Substring($idx + 1)
                if ($vistos.ContainsKey($rel)) { $div.Add("Duplicado: $rel"); continue }
                $vistos[$rel] = $true
                $s = $e.Open()
                try {
                    if ($rel -eq 'SHA256SUMS.txt') {
                        $ms = New-Object System.IO.MemoryStream
                        try {
                            $s.CopyTo($ms)
                            $manifesto = (New-Object System.Text.UTF8Encoding $false).GetString($ms.ToArray())
                        } finally { $ms.Dispose() }
                    } else {
                        $h = $sha.ComputeHash($s)
                        $hashes[$rel] = ([System.BitConverter]::ToString($h).Replace('-', '')).ToLowerInvariant()
                    }
                } finally { $s.Dispose() }
            }
        } finally { $sha.Dispose() }
    } finally { $arq.Dispose() }

    if ($null -eq $manifesto) {
        $div.Add('Ausente: SHA256SUMS.txt')
        return @{ Ok = $false; Divergencias = $div.ToArray() }
    }
    $esperado = @{}
    foreach ($linha in $manifesto.Split("`n")) {
        $l = $linha.TrimEnd("`r")
        if ($l -match '^([0-9a-fA-F]{64})  (.+)$') { $esperado[$Matches[2]] = $Matches[1].ToLowerInvariant() }
    }
    foreach ($rel in @($esperado.Keys | Sort-Object)) {
        if (-not $hashes.ContainsKey($rel)) { $div.Add("Ausente: $rel") }
        elseif ($hashes[$rel] -ne $esperado[$rel]) { $div.Add("Hash: $rel") }
    }
    foreach ($rel in @($hashes.Keys | Sort-Object)) {
        if (-not $esperado.ContainsKey($rel)) { $div.Add("Extra: $rel") }
    }
    @{ Ok = ($div.Count -eq 0); Divergencias = $div.ToArray() }
}

function Complete-Coleta {
    param([string]$Pasta)
    $pasta = $Pasta.TrimEnd('\', '/')
    $null = Write-Manifesto -Pasta $pasta
    $zip = New-ZipColeta -Pasta $pasta
    $hashZip = Write-HashZip -Zip $zip
    $hash = Get-Sha256Arquivo -Caminho $zip
    $v = Test-ZipContraManifesto -Zip $zip
    $ok = [bool]$v.Ok
    $div = @($v.Divergencias)
    if ($ok) {
        try {
            Remove-Item -LiteralPath $pasta -Recurse -Force -ErrorAction Stop
        } catch {
            Write-Host ('AVISO: a pasta de coleta nao foi removida por completo: {0} ({1})' -f $pasta, $_.Exception.Message) -ForegroundColor Yellow
        }
    } else {
        foreach ($d in $div) { Write-Host "Divergencia na verificacao: $d" -ForegroundColor Red }
        Write-Host "A pasta de coleta foi mantida: $pasta" -ForegroundColor Red
    }
    @{ Zip = $zip; HashZip = $hashZip; Hash = $hash; Ok = $ok; Divergencias = $div }
}
#endregion Integridade

#region Main
function ConvertTo-ArgumentoLinha {
    <# Coloca um valor entre aspas para a linha de comando do Windows (regras do CommandLineToArgvW). #>
    param([AllowEmptyString()][string]$Valor)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $barras = 0
    foreach ($c in $Valor.ToCharArray()) {
        if ($c -eq '\') { $barras++; continue }
        if ($c -eq '"') {
            [void]$sb.Append([char]'\', (2 * $barras + 1)).Append('"')
        } else {
            if ($barras -gt 0) { [void]$sb.Append([char]'\', $barras) }
            [void]$sb.Append($c)
        }
        $barras = 0
    }
    if ($barras -gt 0) { [void]$sb.Append([char]'\', (2 * $barras)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-ArgumentosRelancamento {
    <# Monta a lista de argumentos do relancamento a partir dos parametros informados ao script. #>
    param([System.Collections.IDictionary]$Ligados)
    $partes = @()
    if ($null -eq $Ligados) { return '' }
    foreach ($k in 'Etiqueta', 'Setor', 'ExecutadoPor', 'Observacao') {
        if ($Ligados.Contains($k)) { $partes += ('-{0} {1}' -f $k, (ConvertTo-ArgumentoLinha ([string]$Ligados[$k]))) }
    }
    if ($Ligados.Contains('Completa') -and [bool]$Ligados['Completa']) { $partes += '-Completa' }
    return ($partes -join ' ')
}

function Test-ArgumentoNaoInterativo {
    <# Indica se a linha de comando tem -NonInteractive (aceita abreviacoes: qualquer argumento que comece com -noni). #>
    param([string[]]$ArgumentosLinha)
    foreach ($a in @($ArgumentosLinha)) {
        if ([string]$a -match '^-noni') { return $true }
    }
    return $false
}

function Test-PausaFinal {
    <# Indica se o script deve aguardar ENTER antes de fechar (janela aberta por duplo clique). #>
    param([bool]$Interativo, [string[]]$ArgumentosLinha)
    if (-not $Interativo) { return $false }
    if (Test-ArgumentoNaoInterativo -ArgumentosLinha $ArgumentosLinha) { return $false }
    return $true
}

function New-LinhaRelancamento {
    <# Linha de comando do relancamento em 64 bits: repassa -NonInteractive e os parametros informados. #>
    param([string]$Script, [System.Collections.IDictionary]$Ligados, [string[]]$ArgumentosLinha)
    $linha = '-NoProfile'
    if (Test-ArgumentoNaoInterativo -ArgumentosLinha $ArgumentosLinha) { $linha += ' -NonInteractive' }
    $linha += ' -ExecutionPolicy Bypass -File ' + (ConvertTo-ArgumentoLinha $Script)
    $extra = ConvertTo-ArgumentosRelancamento -Ligados $Ligados
    if ($extra) { $linha = $linha + ' ' + $extra }
    return $linha
}

function Format-DataLocalUtc {
    param([datetime]$Data)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    return ('{0} | {1} UTC' -f $Data.ToString('yyyy-MM-dd HH:mm:ss', $inv), $Data.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss', $inv))
}

function Write-CabecalhoLog {
    <# Cria o Coleta.log com o cabecalho da spec 8. #>
    [CmdletBinding()]
    param()
    $ctx = $Script:Ctx
    $par = @(foreach ($k in $ctx.Parametros.Keys) {
        $v = $ctx.Parametros[$k]
        if ($v -is [bool] -or $v -is [System.Management.Automation.SwitchParameter]) { if ([bool]$v) { $v = 'Sim' } else { $v = 'Nao' } }
        '{0}={1}' -f $k, $v
    }) -join '; '
    $usuario = ''
    try { $usuario = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { $usuario = '' }
    if (-not $usuario) { $usuario = '{0}\{1}' -f [Environment]::UserDomainName, [Environment]::UserName }
    $so = ''
    try {
        $os = @(Get-CimSafe -ClassName Win32_OperatingSystem) | Select-Object -First 1
        if ($os) { $so = ('{0} {1}' -f $os.Caption, $os.BuildNumber).Trim() }
    } catch { $so = '' }
    if (-not $so) { $so = [string][Environment]::OSVersion.VersionString }
    $admin = 'Nao'; if ($ctx.Admin) { $admin = 'Sim' }

    $l = New-Object System.Text.StringBuilder
    [void]$l.Append(('Script        : InventarioForense.ps1 v{0}' -f $Script:VersaoScript) + "`r`n")
    [void]$l.Append(('Autor         : {0} <{1}>' -f $Script:Autor, $Script:EmailAutor) + "`r`n")
    [void]$l.Append(('SHA-256 script: {0}' -f $ctx.HashScript) + "`r`n")
    [void]$l.Append(('Parametros    : {0}' -f $par) + "`r`n")
    [void]$l.Append(('Hostname      : {0}' -f $ctx.Hostname) + "`r`n")
    [void]$l.Append(('Usuario       : {0}' -f $usuario) + "`r`n")
    [void]$l.Append(('Administrador : {0}' -f $admin) + "`r`n")
    [void]$l.Append(('PowerShell    : {0} | SO: {1}' -f $PSVersionTable.PSVersion, $so) + "`r`n")
    [void]$l.Append(('Fuso          : {0}' -f (Get-FusoHorarioTexto)) + "`r`n")
    [void]$l.Append(('Inicio        : {0}' -f (Format-DataLocalUtc $ctx.Inicio)) + "`r`n")
    [void]$l.Append(('-' * 78) + "`r`n")
    Write-TextoUtf8Bom -Caminho $ctx.LogPath -Texto $l.ToString()
}

function Write-RodapeLog {
    <# Fecha o log com os totais da coleta. Nada mais e gravado no log depois disto. #>
    [CmdletBinding()]
    param()
    $ctx = $Script:Ctx
    $ok = @($ctx.Status | Where-Object { $_.Status -eq 'OK' }).Count
    $falha = @($ctx.Status | Where-Object { $_.Status -eq 'Falha' }).Count
    $pul = @($ctx.Status | Where-Object { $_.Status -eq 'Pulada' }).Count
    $fontes = @($ctx.FontesComFalha) -join ', '
    if (-not $fontes) { $fontes = 'nenhuma' }
    $fim = [datetime]::Now
    $dur = Format-Segundos ($fim - $ctx.Inicio).TotalSeconds
    $t = ('-' * 78) + "`r`n"
    $t += ('Areas OK: {0} | Com falha: {1} | Puladas: {2} | Fontes com falha: {3} | Duracao: {4} s' -f $ok, $falha, $pul, $fontes, $dur) + "`r`n"
    $t += ('Fim           : {0}' -f (Format-DataLocalUtc $fim)) + "`r`n"
    Write-TextoUtf8Bom -Caminho $ctx.LogPath -Texto $t -Anexar
}

function Remove-PastaTemporaria {
    <# Remove <pasta>\_tmp registrando no log. #>
    param([string]$Pasta)
    $tmp = Join-Path $Pasta '_tmp'
    if (-not (Test-Path -LiteralPath $tmp)) { return }
    try {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction Stop
        Write-Log -Nivel INFO -Area 'Sistema' -Mensagem ('Temporarios removidos: ' + $tmp)
    } catch {
        Write-Log -Nivel ERRO -Area 'Sistema' -Mensagem ('Falha ao remover os temporarios {0}: {1}' -f $tmp, $_.Exception.Message)
    }
}

function Exit-InventarioForense {
    <# Encerra com o codigo informado; com -SemSaida apenas devolve o codigo. #>
    param([int]$Codigo, [switch]$SemSaida)
    if ($SemSaida) { return $Codigo }
    if (Test-PausaFinal -Interativo ([Environment]::UserInteractive) -ArgumentosLinha ([Environment]::GetCommandLineArgs())) {
        $null = Read-Host 'Pressione ENTER para finalizar'
    }
    exit $Codigo
}

function Write-CabecalhoTela {
    <# Primeira saida na tela: nome, versao e autor, antes das etapas que podem demorar. #>
    [CmdletBinding()]
    param()
    $barra = '=' * 60
    Write-Host $barra -ForegroundColor Cyan
    Write-Host (' InventarioForense.ps1 - versao {0}' -f $Script:VersaoScript) -ForegroundColor Cyan
    Write-Host (' Autor: {0} <{1}>' -f $Script:Autor, $Script:EmailAutor) -ForegroundColor Cyan
    Write-Host $barra -ForegroundColor Cyan
    $agora = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
    Write-Host ('Coleta iniciada em {0}. Preparando, aguarde...' -f $agora)
}

function Invoke-InventarioForense {
    <# Fluxo principal da coleta. -RaizSaida e -SemSaida existem para os testes. #>
    [CmdletBinding()]
    param(
        [System.Collections.IDictionary]$Parametros = $Script:ParametrosEntrada,
        [System.Collections.IDictionary]$ParametrosLigados = @{},
        [string]$RaizSaida = $PSScriptRoot,
        [switch]$SemSaida
    )

    # 1. Processo 32 bits em SO 64 bits: relanca no PowerShell 64 bits (sysnative) com os mesmos parametros.
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $exe = "$env:WINDIR\sysnative\WindowsPowerShell\v1.0\powershell.exe"
        $linha = New-LinhaRelancamento -Script $PSCommandPath -Ligados $ParametrosLigados -ArgumentosLinha ([Environment]::GetCommandLineArgs())
        Write-Host 'Processo 32 bits detectado; relancando no PowerShell 64 bits...' -ForegroundColor Yellow
        $p = Start-Process -FilePath $exe -ArgumentList $linha -Wait -NoNewWindow -PassThru
        if ($SemSaida) { return [int]$p.ExitCode }
        exit ([int]$p.ExitCode)
    }

    # Cabecalho logo no inicio: quem executa ve que o script esta rodando.
    Write-CabecalhoTela

    # 2. A raiz precisa aceitar escrita; nunca grava em outro local.
    $raiz = $RaizSaida
    if (-not $raiz -or -not (Test-PastaGravavel -Pasta $raiz)) {
        Write-Host ('Nao foi possivel gravar em {0}. A coleta foi cancelada; nada foi gravado.' -f $raiz) -ForegroundColor Red
        return (Exit-InventarioForense -Codigo 2 -SemSaida:$SemSaida)
    }

    # 3. Contexto.
    $null = New-ContextoColeta -Parametros $Parametros
    $ctx = $Script:Ctx
    $ctx.Admin = [bool](Test-Admin)
    $ctx.Inicio = Get-Date
    $ctx.DataColeta = $ctx.Inicio.ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
    $avisoHash = ''
    try { $ctx.HashScript = Get-Sha256Arquivo -Caminho $PSCommandPath } catch { $ctx.HashScript = ''; $avisoHash = $_.Exception.Message }
    if (-not $ctx.Admin) {
        Write-Host 'AVISO: o script nao esta sendo executado como Administrador. Recomenda-se executar como Administrador; as fontes que exigem privilegio serao puladas.' -ForegroundColor Yellow
    }

    # 4. ID do equipamento, nome e pasta da coleta, log.
    $erroId = ''
    try {
        $id = Get-DadosIdEquipamento -PastaReferencia $raiz
        $ctx.IdEquipamento = [string]$id.Id
        $ctx.IdEquipamentoOrigem = [string]$id.Origem
        if (-not $ctx.IdEquipamento) { throw 'ID vazio' }
    } catch {
        $erroId = $_.Exception.Message
        $ctx.IdEquipamento = 'INDISPONIVEL'
        $ctx.IdEquipamentoOrigem = ''
    }
    $ctx.Hostname = [string]$env:COMPUTERNAME
    if (-not $ctx.Hostname) { $ctx.Hostname = [Environment]::MachineName }
    $etiqueta = ''
    if ($ctx.Parametros.Contains('Etiqueta')) { $etiqueta = [string]$ctx.Parametros['Etiqueta'] }
    $nome = Get-NomeColeta -Hostname $ctx.Hostname -Etiqueta $etiqueta -Data $ctx.Inicio
    $pasta = Get-PastaSaida -RaizScript $raiz -NomeColeta $nome
    $ctx.PastaColeta = $pasta
    $tmp = Join-Path $pasta '_tmp'
    foreach ($sub in @('csv', (Join-Path 'brutos' 'Amcache'), (Join-Path 'brutos' 'Prefetch'), '_tmp')) {
        $null = New-Item -ItemType Directory -Path (Join-Path $pasta $sub) -Force -ErrorAction Stop
    }
    $ctx.LogPath = Join-Path $pasta 'Coleta.log'
    Write-CabecalhoLog
    Write-Log -Nivel INFO -Area 'Main' -Mensagem ('Pasta da coleta: ' + $pasta)
    if (-not $ctx.Admin) { Write-Log -Nivel AVISO -Area 'Main' -Mensagem 'Executando sem privilegio de administrador' }
    if ($avisoHash) { Write-Log -Nivel AVISO -Area 'Main' -Mensagem ('SHA-256 do script indisponivel: ' + $avisoHash) }
    if ($erroId) { Write-Log -Nivel ERRO -Area 'Main' -Mensagem ('ID do equipamento indisponivel: ' + $erroId) }

    $completa = $ctx.Parametros.Contains('Completa') -and [bool]$ctx.Parametros['Completa']
    $total = 14 + 1
    if ($completa) { $total++ }
    $pos = 0
    $agendadas = @('02', '03', '04', '05', '06', '09', '10', '11', '12', '13', '07', '08', '14', '15')
    if ($completa) { $agendadas += '16' }
    $incompleta = $false

    # 5 e 6. Areas; o finally desmonta os hives e remove _tmp (inclusive em excecao e Ctrl+C).
    $perfisColeta = @()
    try {
        $pos++; Invoke-Area -Numero '02' -Posicao $pos -Total $total -Bloco { Get-ColetaHardware }
        $pos++; Invoke-Area -Numero '03' -Posicao $pos -Total $total -Bloco { Get-ColetaVolumes }
        $pos++; Invoke-Area -Numero '04' -Posicao $pos -Total $total -Bloco { Get-ColetaRede }
        $pos++; Invoke-Area -Numero '05' -Posicao $pos -Total $total -Bloco { Get-ColetaContas }
        $pos++; Invoke-Area -Numero '06' -Posicao $pos -Total $total -Bloco { Get-ColetaPerfis -Contas @($Script:Ctx.Resultados['05']) }
        $pos++; Invoke-Area -Numero '09' -Posicao $pos -Total $total -Bloco { Get-ColetaLicencas }
        $pos++; Invoke-Area -Numero '10' -Posicao $pos -Total $total -Bloco { Get-ColetaServicos }
        $pos++; Invoke-Area -Numero '11' -Posicao $pos -Total $total -Bloco { Get-ColetaTarefas }
        $pos++; Invoke-Area -Numero '12' -Posicao $pos -Total $total -Bloco { Get-ColetaDrivers }
        $pos++; Invoke-Area -Numero '13' -Posicao $pos -Total $total -Bloco { Get-ColetaAtualizacoes }

        try {
            $perfisColeta = @(Mount-HivesColeta -Perfis @(Get-PerfisSistema) -PastaTmp $tmp)
        } catch {
            $perfisColeta = @()
            $ctx.FontesComFalha.Add('Hives')
            Write-Log -Nivel ERRO -Area 'Hives' -Mensagem ('Falha ao preparar os perfis: {0} (linha {1})' -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber)
        }

        $pos++; Invoke-Area -Numero '07' -Posicao $pos -Total $total -Bloco { Get-ColetaSoftwareInstalado -Perfis $perfisColeta }
        $pos++; Invoke-Area -Numero '08' -Posicao $pos -Total $total -Bloco { Get-ColetaVestigios -Perfis $perfisColeta -PastaColeta $Script:Ctx.PastaColeta }
        $pos++; Invoke-Area -Numero '14' -Posicao $pos -Total $total -Bloco { Get-ColetaPastasProgramas -Raizes @(Get-RaizesPastasProgramas -Perfis $perfisColeta) }
        $pos++; Invoke-Area -Numero '15' -Posicao $pos -Total $total -Bloco { Get-ColetaArquivosInstaladores -Raizes @(Get-RaizesInstaladores -Perfis $perfisColeta) }
        if ($completa) {
            $pos++; Invoke-Area -Numero '16' -Posicao $pos -Total $total -Bloco { Get-ColetaArquivosCompleta }
        }
    } catch {
        $incompleta = $true
        $msgMain = [string]$_.Exception.Message
        Write-Log -Nivel ERRO -Area 'Main' -Mensagem ('Erro inesperado: {0} (linha {1})' -f $msgMain, $_.InvocationInfo.ScriptLineNumber)
        $ctx.FontesComFalha.Add('Main')
        $ctx.Status.Add([pscustomobject]@{
            Numero = 'Main'; Nome = 'Fluxo principal'; Status = 'Falha'; Itens = 0; Segundos = 0; Mensagem = $msgMain
        })
        $executadas = @($ctx.Status | ForEach-Object { [string]$_.Numero })
        foreach ($n in $agendadas) {
            if ($executadas -notcontains $n) {
                Write-Log -Nivel AVISO -Area 'Main' -Mensagem ('Area nao executada: {0} {1}' -f $n, $Script:Contrato[$n].Nome)
            }
        }
    } finally {
        try {
            Dismount-HivesColeta
        } catch {
            Write-Log -Nivel ERRO -Area 'Sistema' -Mensagem ('Falha ao desmontar os hives: ' + $_.Exception.Message)
        }
        Remove-PastaTemporaria -Pasta $pasta
        if (Test-Path -LiteralPath $tmp) {
            $avisoTmp = 'A pasta _tmp nao pode ser removida e fica fora do manifesto e do ZIP; apague-a manualmente: ' + $tmp
            Write-Host ('AVISO: ' + $avisoTmp) -ForegroundColor Yellow
            Write-Log -Nivel AVISO -Area 'Sistema' -Mensagem $avisoTmp
        }
    }

    # 7. Resumo (01), TXT, JSON e rodape do log.
    $def = $Script:Contrato['01']
    $comum = [ordered]@{ Hostname = $ctx.Hostname; IdEquipamento = $ctx.IdEquipamento; DataColeta = $ctx.DataColeta }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $statusResumo = 'OK'; $msgResumo = ''
    $resumo = @()
    try {
        $resumo = @(Get-ColetaResumo)
    } catch {
        $statusResumo = 'Falha'; $msgResumo = $_.Exception.Message
        Write-Log -Nivel ERRO -Area '01 Resumo' -Mensagem ('Falha: {0} (linha {1})' -f $msgResumo, $_.InvocationInfo.ScriptLineNumber)
    }
    $ctx.Resultados['01'] = [object[]]$resumo
    try {
        Export-CsvPadrao -Caminho (Join-Path (Join-Path $pasta 'csv') $def.Arquivo) -Colunas $def.Colunas -Itens $resumo -Comum $comum
    } catch {
        if ($statusResumo -eq 'OK') { $statusResumo = 'Falha'; $msgResumo = 'Falha ao gravar CSV: ' + $_.Exception.Message }
        Write-Log -Nivel ERRO -Area '01 Resumo' -Mensagem ('Falha ao gravar CSV: ' + $_.Exception.Message)
    }
    $sw.Stop()
    $ctx.Status.Add([pscustomobject]@{
        Numero = '01'; Nome = $def.Nome; Status = $statusResumo; Itens = $resumo.Count
        Segundos = [math]::Round($sw.Elapsed.TotalSeconds, 1); Mensagem = $msgResumo
    })
    $pos++
    Write-Host ('[{0}/{1}] {2}... {3}' -f $pos.ToString('00'), $total.ToString('00'), $def.Nome, $statusResumo.ToUpperInvariant())
    try { Write-ColetaJson -Caminho (Join-Path $pasta 'Coleta.json') } catch {
        Write-Log -Nivel ERRO -Area 'Saidas' -Mensagem ('Falha ao gravar Coleta.json: ' + $_.Exception.Message)
    }
    try { Write-ColetaTxt -Caminho (Join-Path $pasta 'Coleta.txt') } catch {
        Write-Log -Nivel ERRO -Area 'Saidas' -Mensagem ('Falha ao gravar Coleta.txt: ' + $_.Exception.Message)
    }
    try {
        Write-Log -Nivel INFO -Area 'Main' -Mensagem 'Coleta concluida; fechando o log'
        Write-RodapeLog
    } catch {
        Write-Host ('Falha ao fechar o log: ' + $_.Exception.Message) -ForegroundColor Yellow
    }

    # 8. Manifesto, ZIP e verificacao (somente no console a partir daqui).
    $codigo = 1
    try {
        $r = Complete-Coleta -Pasta $pasta
        Write-Host ''
        Write-Host ('ZIP           : {0}' -f $r.Zip)
        Write-Host ('SHA-256 do ZIP: {0}' -f $r.Hash)
        Write-Host 'Areas:'
        foreach ($s in $ctx.Status) {
            $cor = 'Gray'
            if ($s.Status -eq 'Falha') { $cor = 'Red' } elseif ($s.Status -eq 'Pulada') { $cor = 'Yellow' }
            Write-Host ('  {0} {1}: {2} ({3} itens)' -f $s.Numero, $s.Nome, $s.Status, $s.Itens) -ForegroundColor $cor
        }
        $pul = Get-ListaPuladas
        if ($pul) { Write-Host ('Puladas: ' + $pul) -ForegroundColor Yellow }
        $fal = Get-ListaFalhas
        if ($fal) { Write-Host ('Com falha: ' + $fal) -ForegroundColor Red }
        if ($r.Ok -and $incompleta) {
            $codigo = 3
            Write-Host 'ATENCAO: coleta incompleta; um erro inesperado interrompeu as areas (veja o Coleta.log).' -ForegroundColor Red
        } elseif ($r.Ok) {
            $codigo = 0
        } else {
            Write-Host 'ATENCAO: a verificacao do ZIP contra o manifesto falhou. Confira a pasta de coleta mantida.' -ForegroundColor Red
        }
    } catch {
        Write-Host ('Falha ao gerar o manifesto/ZIP: {0}. A pasta de coleta foi mantida: {1}' -f $_.Exception.Message, $pasta) -ForegroundColor Red
        $codigo = 1
    }

    # 9. Encerramento (pausa so em janela interativa).
    return (Exit-InventarioForense -Codigo $codigo -SemSaida:$SemSaida)
}
#endregion Main

if ($MyInvocation.InvocationName -ne '.') { Invoke-InventarioForense -ParametrosLigados $PSBoundParameters }
