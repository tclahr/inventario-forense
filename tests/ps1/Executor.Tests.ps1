BeforeAll {
  . "$PSScriptRoot/../../InventarioForense.ps1"
}

Describe 'Executor' {
  BeforeEach {
    $null = New-ContextoColeta -Parametros @{}
    $Script:Ctx.PastaColeta = $TestDrive
    $Script:Ctx.LogPath = Join-Path $TestDrive 'Coleta.log'
    $Script:Ctx.Hostname = 'H'
    $Script:Ctx.IdEquipamento = 'ID'
    $Script:Ctx.DataColeta = '2026-11-12 14:30:00'
    $Script:Ctx.Admin = $true
    Mock Write-Host {}
  }

  It 'OK grava CSV e resultados' {
    Invoke-Area -Numero '05' -Bloco { [pscustomobject]@{ Nome = 'u1' } }
    $csv = Join-Path $TestDrive 'csv/05_Contas.csv'
    @([IO.File]::ReadAllText($csv) -split "`r`n" | Where-Object { $_ -ne '' }).Count | Should -Be 2
    $Script:Ctx.Status[0].Status | Should -Be 'OK'
    $Script:Ctx.Status[0].Itens | Should -Be 1
    $Script:Ctx.Resultados['05'].Count | Should -Be 1
  }

  It 'Falha isolada' {
    { Invoke-Area -Numero '05' -Bloco { throw 'boom' } } | Should -Not -Throw
    $Script:Ctx.Status[0].Status | Should -Be 'Falha'
    @([IO.File]::ReadAllText((Join-Path $TestDrive 'csv/05_Contas.csv')) -split "`r`n" | Where-Object { $_ -ne '' }).Count | Should -Be 1
    [IO.File]::ReadAllText($Script:Ctx.LogPath) | Should -Match '\[ERRO\] \[05 Contas locais\] Falha: boom \(linha \d+\)'
    $Script:Ctx.Resultados['05'].Count | Should -Be 0
  }

  It 'Erro nao terminante vira falha' {
    Invoke-Area -Numero '05' -Bloco { Get-Item 'Z:\nao\existe' }
    $Script:Ctx.Status[0].Status | Should -Be 'Falha'
  }

  It 'Pulada sem admin' {
    $Script:Ctx.Admin = $false
    $Script:Executou = $false
    Invoke-Area -Numero '05' -RequerAdmin -Bloco { $Script:Executou = $true }
    $Script:Ctx.Status[0].Status | Should -Be 'Pulada'
    $Script:Executou | Should -BeFalse
    [IO.File]::ReadAllText($Script:Ctx.LogPath) | Should -Match 'Area pulada: requer administrador'
    @([IO.File]::ReadAllText((Join-Path $TestDrive 'csv/05_Contas.csv')) -split "`r`n" | Where-Object { $_ -ne '' }).Count | Should -Be 1
  }

  It 'Fonte falha nao derruba a area' {
    Invoke-Area -Numero '08' -Bloco {
      Invoke-Fonte -Area '08' -Nome 'A' -Bloco { throw 'x' }
      Invoke-Fonte -Area '08' -Nome 'B' -Bloco { [pscustomobject]@{ Fonte = 'B' } }
    }
    $Script:Ctx.Status[0].Status | Should -Be 'OK'
    $Script:Ctx.Status[0].Itens | Should -Be 1
    $Script:Ctx.FontesComFalha | Should -Be @('08:A')
  }

  It 'Fonte loga contagem e duracao' {
    $null = @(Invoke-Fonte -Area '08' -Nome 'D' -Bloco { 1; 2 })
    [IO.File]::ReadAllText($Script:Ctx.LogPath) | Should -Match '\[08:D\] 2 itens em \d+,\d s'
  }

  It 'Fonte pulada sem admin' {
    $Script:Ctx.Admin = $false
    $r = @(Invoke-Fonte -Area '08' -Nome 'C' -RequerAdmin -Bloco { 1 })
    $r.Count | Should -Be 0
    $Script:Ctx.FontesPuladas | Should -Be @('08:C')
  }

  It 'Listas' {
    Invoke-Area -Numero '05' -Bloco { throw 'boom' }
    Invoke-Area -Numero '08' -Bloco { Invoke-Fonte -Area '08' -Nome 'A' -Bloco { throw 'x' } }
    $Script:Ctx.Admin = $false
    Invoke-Area -Numero '06' -RequerAdmin -Bloco { 1 }
    Get-ListaFalhas | Should -Be '05 Contas locais, 08:A'
    (Get-ListaPuladas) | Should -Match '^06 '
  }

  It 'Listas sem repeticao (Main como status e como fonte, fonte repetida)' {
    $Script:Ctx.Status.Add([pscustomobject]@{ Numero = 'Main'; Nome = 'Fluxo principal'; Status = 'Falha'; Itens = 0; Segundos = 0; Mensagem = 'x' })
    $Script:Ctx.FontesComFalha.Add('Main')
    $Script:Ctx.FontesComFalha.Add('08:A')
    $Script:Ctx.FontesComFalha.Add('08:A')
    Get-ListaFalhas | Should -Be 'Main Fluxo principal, 08:A'
  }

  It 'Add-EscritaSistema registra' {
    Add-EscritaSistema -Descricao 'teste'
    $Script:Ctx.Escritas | Should -Be @('teste')
    [IO.File]::ReadAllText($Script:Ctx.LogPath) | Should -Match '\[AVISO\] \[Sistema\] Escrita: teste'
  }
}
