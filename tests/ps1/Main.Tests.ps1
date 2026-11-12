BeforeAll {
  . "$PSScriptRoot/../../InventarioForense.ps1"

  function Set-MocksColeta {
    Mock Write-Host {}
    Mock Read-Host {}
    Mock Test-Admin { $true }
    Mock Get-CimSafe { @() }
    Mock Get-DadosIdEquipamento { [pscustomobject]@{ Id = 'ABC123'; Origem = 'UUID=X|BIOS=|PLACA=|DISCO=' } }
    Mock Get-ColetaHardware { [pscustomobject]@{ Tipo = 'BIOS'; Descricao = 'B' } }
    Mock Get-ColetaVolumes { @() }
    Mock Get-ColetaRede { @() }
    Mock Get-ColetaContas { [pscustomobject]@{ Nome = 'José'; SID = 'S-1-5-21-1-2-3-1001' } }
    Mock Get-ColetaPerfis { @() }
    Mock Get-ColetaLicencas { @() }
    Mock Get-ColetaServicos { @() }
    Mock Get-ColetaTarefas { @() }
    Mock Get-ColetaDrivers { @() }
    Mock Get-ColetaAtualizacoes { @() }
    Mock Get-PerfisSistema { [pscustomobject]@{ SID = 'S-1-5-21-1-2-3-1001'; Usuario = 'José'; Caminho = '/nao/existe'; Carregado = $false } }
    Mock Mount-HivesColeta { [pscustomobject]@{ SID = 'S-1-5-21-1-2-3-1001'; Usuario = 'José'; Caminho = '/nao/existe'; RaizUsuario = ''; RaizClasses = ''; Disponivel = $false } }
    Mock Dismount-HivesColeta {}
    Mock Get-ColetaSoftwareInstalado { [pscustomobject]@{ Nome = 'Programa A'; Fonte = 'HKLM64' } }
    Mock Get-ColetaVestigios { @() }
    Mock Get-RaizesPastasProgramas { @() }
    Mock Get-ColetaPastasProgramas { @() }
    Mock Get-RaizesInstaladores { @() }
    Mock Get-ColetaArquivosInstaladores { @() }
    Mock Get-ColetaArquivosCompleta { @() }
    Mock Get-ColetaResumo { [pscustomobject]@{ Etiqueta = 'PAT'; Hostname = 'H' } }
    Mock Complete-Coleta {
      $Script:CsvsAntesDoZip = @(Get-ChildItem -LiteralPath (Join-Path $Pasta 'csv') -Name)
      $Script:TmpAntesDoZip = Test-Path -LiteralPath (Join-Path $Pasta '_tmp')
      @{ Zip = "$Pasta.zip"; HashZip = "$Pasta.zip.sha256"; Hash = ('0' * 64); Ok = $true; Divergencias = @() }
    }
  }

  function Get-PastaColetaTeste {
    param([string]$Raiz)
    @(Get-ChildItem -LiteralPath $Raiz -Directory -Filter 'InventarioForense_*')
  }
}

Describe 'Write-CabecalhoTela' {
  It 'Mostra nome, versao e autor' {
    $Script:Saida = @()
    Mock Write-Host { $Script:Saida += [string]$Object }
    Write-CabecalhoTela
    $texto = $Script:Saida -join "`n"
    $texto | Should -Match 'InventarioForense\.ps1'
    $texto | Should -Match ([regex]::Escape($Script:VersaoScript))
    $texto | Should -Match ([regex]::Escape($Script:Autor))
    $texto | Should -Match ([regex]::Escape($Script:EmailAutor))
  }
}

Describe 'Invoke-InventarioForense' {
  BeforeEach {
    $Script:Raiz = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $Script:Raiz -Force
    $Script:CsvsAntesDoZip = $null
    $Script:TmpAntesDoZip = $null
    Set-MocksColeta
  }

  It 'Cabecalho sai antes de identificar o equipamento' {
    $Script:Ordem = @()
    Mock Write-CabecalhoTela { $Script:Ordem += 'cabecalho' }
    Mock Get-DadosIdEquipamento { $Script:Ordem += 'id'; [pscustomobject]@{ Id = 'ABC123'; Origem = 'UUID=X|BIOS=|PLACA=|DISCO=' } }
    $null = Invoke-InventarioForense -Parametros ([ordered]@{ Completa = $false }) -RaizSaida $Script:Raiz -SemSaida
    $Script:Ordem[0] | Should -Be 'cabecalho'
    Should -Invoke Write-CabecalhoTela -Times 1 -Exactly
  }

  It 'Ordem e dismount mesmo com excecao' {
    Mock Get-ColetaSoftwareInstalado { throw 'x' }
    $codigo = Invoke-InventarioForense -Parametros ([ordered]@{ Etiqueta = 'PAT'; Setor = ''; ExecutadoPor = ''; Observacao = ''; Completa = $false }) -RaizSaida $Script:Raiz -SemSaida
    $codigo | Should -Be 0
    Should -Invoke Dismount-HivesColeta -Times 1 -Exactly
    ($Script:Ctx.Status | Where-Object Numero -eq '07').Status | Should -Be 'Falha'
    $Script:CsvsAntesDoZip | Should -Contain '01_Resumo.csv'
    $Script:Ctx.Resultados.Contains('01') | Should -BeTrue
    $Script:TmpAntesDoZip | Should -BeFalse
    $ordem = @($Script:Ctx.Status | ForEach-Object { $_.Numero })
    ($ordem -join ',') | Should -Be '02,03,04,05,06,09,10,11,12,13,07,08,14,15,01'
    $Script:Ctx.IdEquipamento | Should -Be 'ABC123'
    $Script:Ctx.IdEquipamentoOrigem | Should -Be 'UUID=X|BIOS=|PLACA=|DISCO='
    Should -Invoke Mount-HivesColeta -Times 1 -Exactly
  }

  It 'Falha do Mount-HivesColeta ainda desmonta e conclui a coleta' {
    Mock Mount-HivesColeta { throw 'falha ao montar' }
    $codigo = Invoke-InventarioForense -Parametros ([ordered]@{ Completa = $false }) -RaizSaida $Script:Raiz -SemSaida
    Should -Invoke Dismount-HivesColeta -Times 1 -Exactly
    $codigo | Should -Be 0
    $Script:CsvsAntesDoZip | Should -Contain '01_Resumo.csv'
  }

  It 'Excecao fora do isolamento das areas ainda desmonta e remove _tmp' {
    Mock Invoke-Area { if ($Numero -eq '08') { throw 'interrompido' } }
    $codigo = Invoke-InventarioForense -Parametros ([ordered]@{ Completa = $false }) -RaizSaida $Script:Raiz -SemSaida
    Should -Invoke Dismount-HivesColeta -Times 1 -Exactly
    $Script:TmpAntesDoZip | Should -BeFalse
    $codigo | Should -Be 3
    $Script:Ctx.FontesComFalha | Should -Contain 'Main'
    $st = @($Script:Ctx.Status | Where-Object Numero -eq 'Main')
    $st.Count | Should -Be 1
    $st[0].Status | Should -Be 'Falha'
    $st[0].Mensagem | Should -Be 'interrompido'
    $log = Join-Path (Get-PastaColetaTeste $Script:Raiz)[0].FullName 'Coleta.log'
    $texto = [IO.File]::ReadAllText($log)
    $texto | Should -Match 'Erro inesperado: interrompido'
    $texto | Should -Match '\[AVISO\] \[Main\] Area nao executada: 08 Vestigios de software'
    $texto | Should -Match 'Area nao executada: 14 Pastas de programas'
    $texto | Should -Match 'Area nao executada: 15 Arquivos instaladores'
    $texto | Should -Not -Match 'Area nao executada: 16'
    $texto | Should -Match 'Areas OK:'
    Should -Invoke Complete-Coleta -Times 1 -Exactly
  }

  It '_tmp nao removida gera aviso amarelo e no log antes do rodape' {
    Mock Remove-PastaTemporaria {}
    $codigo = Invoke-InventarioForense -Parametros ([ordered]@{ Completa = $false }) -RaizSaida $Script:Raiz -SemSaida
    $codigo | Should -Be 0
    $Script:TmpAntesDoZip | Should -BeTrue
    Should -Invoke Write-Host -ParameterFilter { $ForegroundColor -eq 'Yellow' -and [string]$Object -like 'AVISO: A pasta _tmp nao pode ser removida*' }
    $texto = [IO.File]::ReadAllText((Join-Path (Get-PastaColetaTeste $Script:Raiz)[0].FullName 'Coleta.log'))
    $i = $texto.IndexOf('A pasta _tmp nao pode ser removida')
    $i | Should -BeGreaterThan 0
    $i | Should -BeLessThan $texto.IndexOf('Coleta concluida; fechando o log')
  }

  It 'AreasComFalha nao repete Main' {
    Mock Invoke-Area { if ($Numero -eq '08') { throw 'interrompido' } }
    $null = Invoke-InventarioForense -Parametros ([ordered]@{ Completa = $false }) -RaizSaida $Script:Raiz -SemSaida
    $l = Get-ListaFalhas
    ([regex]::Matches($l, 'Main')).Count | Should -Be 1
  }

  It 'Coleta incompleta com verificacao reprovada retorna 1' {
    Mock Invoke-Area { if ($Numero -eq '08') { throw 'interrompido' } }
    Mock Complete-Coleta { @{ Zip = 'z.zip'; HashZip = 'z.zip.sha256'; Hash = ('0' * 64); Ok = $false; Divergencias = @('x') } }
    $codigo = Invoke-InventarioForense -Parametros ([ordered]@{ Completa = $false }) -RaizSaida $Script:Raiz -SemSaida
    $codigo | Should -Be 1
  }

  It 'Falha ao fechar o log nao impede o Complete-Coleta' {
    Mock Write-RodapeLog { throw 'disco cheio' }
    $codigo = Invoke-InventarioForense -Parametros ([ordered]@{ Completa = $false }) -RaizSaida $Script:Raiz -SemSaida
    $codigo | Should -Be 0
    Should -Invoke Complete-Coleta -Times 1 -Exactly
    Should -Invoke Write-Host -ParameterFilter { $Object -like '*disco cheio*' -and $ForegroundColor -eq 'Yellow' }
  }

  It 'Sem -Completa nao cria 16' {
    $null = Invoke-InventarioForense -Parametros ([ordered]@{ Completa = $false }) -RaizSaida $Script:Raiz -SemSaida
    $Script:CsvsAntesDoZip | Should -Contain '15_Arquivos_Instaladores.csv'
    $Script:CsvsAntesDoZip | Should -Not -Contain '16_Arquivos_Completa.csv'
    Should -Invoke Get-ColetaArquivosCompleta -Times 0
  }

  It 'Com -Completa cria 16' {
    $null = Invoke-InventarioForense -Parametros ([ordered]@{ Completa = $true }) -RaizSaida $Script:Raiz -SemSaida
    $Script:CsvsAntesDoZip | Should -Contain '16_Arquivos_Completa.csv'
    Should -Invoke Get-ColetaArquivosCompleta -Times 1 -Exactly
  }

  It 'Log tem cabecalho, autor e rodape' {
    $null = Invoke-InventarioForense -Parametros ([ordered]@{ Etiqueta = 'PAT'; Completa = $false }) -RaizSaida $Script:Raiz -SemSaida
    $log = Join-Path (Get-PastaColetaTeste $Script:Raiz)[0].FullName 'Coleta.log'
    $bytes = [IO.File]::ReadAllBytes($log)
    ($bytes[0..2] -join ',') | Should -Be '239,187,191'
    $texto = [IO.File]::ReadAllText($log)
    $texto | Should -Match ([regex]::Escape('Thiago Canozzo Lahr <thiago@peritoemti.com.br>'))
    $texto | Should -Match ([regex]::Escape('InventarioForense.ps1 v1.0.0'))
    $texto | Should -Match 'SHA-256 script: [0-9a-f]{64}'
    $texto | Should -Match 'Areas OK: \d+ \| Com falha: \d+ \| Puladas: \d+ \| Fontes com falha: .* \| Duracao: [\d,]+ s'
    $texto | Should -Match 'Fim *: .+ \| .+UTC'
    $texto | Should -Match 'Temporarios removidos'
  }

  It 'Falha do ID grava INDISPONIVEL e o motivo no log' {
    Mock Get-DadosIdEquipamento { throw 'sem CIM' }
    $null = Invoke-InventarioForense -Parametros ([ordered]@{ Completa = $false }) -RaizSaida $Script:Raiz -SemSaida
    $Script:Ctx.IdEquipamento | Should -Be 'INDISPONIVEL'
    $Script:Ctx.IdEquipamentoOrigem | Should -Be ''
    $log = Join-Path (Get-PastaColetaTeste $Script:Raiz)[0].FullName 'Coleta.log'
    [IO.File]::ReadAllText($log) | Should -Match 'sem CIM'
  }

  It 'Verificacao reprovada retorna 1' {
    Mock Complete-Coleta { @{ Zip = 'z.zip'; HashZip = 'z.zip.sha256'; Hash = ('0' * 64); Ok = $false; Divergencias = @('x') } }
    $codigo = Invoke-InventarioForense -Parametros ([ordered]@{ Completa = $false }) -RaizSaida $Script:Raiz -SemSaida
    $codigo | Should -Be 1
  }

  It 'Pasta nao gravavel aborta sem criar nada' {
    Mock Test-PastaGravavel { $false }
    $codigo = Invoke-InventarioForense -Parametros ([ordered]@{ Completa = $false }) -RaizSaida $Script:Raiz -SemSaida
    $codigo | Should -Be 2
    (Get-PastaColetaTeste $Script:Raiz).Count | Should -Be 0
    Should -Invoke Write-Host -ParameterFilter { $Object -like 'Nao foi possivel gravar em*A coleta foi cancelada; nada foi gravado.' -and $ForegroundColor -eq 'Red' }
    Should -Invoke Complete-Coleta -Times 0
  }

  It 'SemSaida nao chama Read-Host' {
    $null = Invoke-InventarioForense -Parametros ([ordered]@{ Completa = $false }) -RaizSaida $Script:Raiz -SemSaida
    Should -Invoke Read-Host -Times 0
  }
}

Describe 'ConvertTo-ArgumentosRelancamento' {
  It 'Repassa strings entre aspas e o switch' {
    $a = ConvertTo-ArgumentosRelancamento -Ligados @{ Etiqueta = 'PAT 01/ção'; Completa = [System.Management.Automation.SwitchParameter]$true }
    $a | Should -Be '-Etiqueta "PAT 01/ção" -Completa'
  }
  It 'Escapa aspas e barra final, omite switch falso e ignora parametros desconhecidos' {
    $a = ConvertTo-ArgumentosRelancamento -Ligados @{ Observacao = 'a "b" c\'; Completa = [System.Management.Automation.SwitchParameter]$false; Outro = 'x' }
    $a | Should -Be '-Observacao "a \"b\" c\\"'
  }
  It 'Mantem a ordem Etiqueta, Setor, ExecutadoPor, Observacao e ignora Responsavel' {
    $a = ConvertTo-ArgumentosRelancamento -Ligados @{ Observacao = 'o'; ExecutadoPor = ''; Setor = 's'; Etiqueta = 'e'; Responsavel = 'x' }
    $a | Should -Be '-Etiqueta "e" -Setor "s" -ExecutadoPor "" -Observacao "o"'
  }
}

Describe 'New-LinhaRelancamento' {
  It 'Repassa -NonInteractive logo apos -NoProfile quando o pai o recebeu (abreviado)' {
    $l = New-LinhaRelancamento -Script 'E:\Coleta Teste\InventarioForense.ps1' -Ligados @{ Etiqueta = 'PAT 01/ção' } -ArgumentosLinha @('powershell.exe', '-NonI', '-File', 'x.ps1')
    $l | Should -Be '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "E:\Coleta Teste\InventarioForense.ps1" -Etiqueta "PAT 01/ção"'
  }
  It 'Nao inclui -NonInteractive quando o pai nao o recebeu' {
    $l = New-LinhaRelancamento -Script 'C:\s.ps1' -Ligados @{} -ArgumentosLinha @('powershell.exe', '-File', 'x.ps1')
    $l | Should -Be '-NoProfile -ExecutionPolicy Bypass -File "C:\s.ps1"'
  }
}

Describe 'Test-PausaFinal' {
  It 'Nao pausa com -NonInteractive abreviado (<_>)' -ForEach @('-noni', '-NonI', '-NONINTERACTIVE', '-nonint') {
    Test-PausaFinal -Interativo $true -ArgumentosLinha @('powershell.exe', $_, '-File', 'x.ps1') | Should -BeFalse
  }
  It 'Argumento parecido que nao comeca com -noni nao conta' {
    Test-PausaFinal -Interativo $true -ArgumentosLinha @('powershell.exe', '-NoProfile', '-Etiqueta', 'noni') | Should -BeTrue
  }
  It 'Nao pausa com -NonInteractive na linha de comando' {
    Test-PausaFinal -Interativo $true -ArgumentosLinha @('powershell.exe', '-noninteractive', '-File', 'x.ps1') | Should -BeFalse
  }
  It 'Nao pausa fora de sessao interativa' {
    Test-PausaFinal -Interativo $false -ArgumentosLinha @('powershell.exe') | Should -BeFalse
  }
  It 'Pausa em sessao interativa sem -NonInteractive' {
    Test-PausaFinal -Interativo $true -ArgumentosLinha @('powershell.exe', '-File', 'x.ps1') | Should -BeTrue
  }
}

Describe 'PSScriptAnalyzer' {
  It 'PSScriptAnalyzer compatibilidade 5.1' -Skip:(-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
    $r = Invoke-ScriptAnalyzer -Path "$PSScriptRoot/../../InventarioForense.ps1" -Settings @{ Rules = @{ PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1') }; PSUseCompatibleCommands = @{ Enable = $true; TargetProfiles = @('win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework') } } }
    @($r | Where-Object Severity -eq 'Error') | Should -HaveCount 0
  }
}
