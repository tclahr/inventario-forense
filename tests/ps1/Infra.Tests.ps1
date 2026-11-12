BeforeAll { . "$PSScriptRoot/../../InventarioForense.ps1" }

Describe 'Carga do script' {
  It 'dot-source nao executa o Main' { { . "$PSScriptRoot/../../InventarioForense.ps1" } | Should -Not -Throw; Get-Command Invoke-InventarioForense | Should -Not -BeNullOrEmpty }
  It 'arquivo tem BOM UTF-8' { ([IO.File]::ReadAllBytes("$PSScriptRoot/../../InventarioForense.ps1"))[0..2] | Should -Be @(0xEF,0xBB,0xBF) }
  It 'sem sintaxe exclusiva do PS7' {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot/../../InventarioForense.ps1",[ref]$null,[ref]$null)
    $ast.FindAll({ param($n) $n.GetType().Name -in 'TernaryExpressionAst','PipelineChainAst' -or ($n -is [System.Management.Automation.Language.BinaryExpressionAst] -and $n.Operator -eq 'QuestionQuestion') -or ($n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Operator -eq 'QuestionQuestionEquals') }, $true) | Should -BeNullOrEmpty
  }
  It 'sem Win32_Product e sem termos proibidos' {
    $t = Get-Content "$PSScriptRoot/../../InventarioForense.ps1" -Raw
    $t | Should -Not -Match 'Win32_Product\b'
    ($t -replace 'thiago@peritoemti\.com\.br','') | Should -Not -Match '(?i)\b(perito|pericia|perícia|autos|vara|laudo|juiz)\b'
  }
}
Describe 'ConvertTo-DataTexto' {
  It 'DateTime'      { ConvertTo-DataTexto ([datetime]'2026-07-28 13:05:09') | Should -Be '2026-07-28 13:05:09' }
  It 'yyyyMMdd'      { ConvertTo-DataTexto '20260728' | Should -Be '2026-07-28 00:00:00' }
  It 'DMTF'          { ConvertTo-DataTexto '20260728130509.000000-180' | Should -Be '2026-07-28 13:05:09' }
  It 'nulo/vazio/0'  { ConvertTo-DataTexto $null | Should -Be ''; ConvertTo-DataTexto '' | Should -Be ''; ConvertTo-DataTexto '0' | Should -Be '' }
  It 'texto invalido devolve o original aparado' { ConvertTo-DataTexto ' 28-07-26x ' | Should -Be '28-07-26x' }
}
Describe 'ConvertFrom-FileTime' {
  It 'converte'    { ConvertFrom-FileTime ([datetime]'2026-01-02 03:04:05').ToFileTime() | Should -Be '2026-01-02 03:04:05' }
  It 'zero vazio'  { ConvertFrom-FileTime 0 | Should -Be '' }
}
Describe 'Get-NomeColeta' {
  It 'sem etiqueta' { Get-NomeColeta -Hostname 'PC-01' -Etiqueta '' -Data ([datetime]'2026-11-12 14:30:00') | Should -Be 'InventarioForense_PC-01_20261112143000' }
  It 'etiqueta com espaco, barra e acento' { Get-NomeColeta -Hostname 'PC-01' -Etiqueta 'PAT 01/ção' -Data ([datetime]'2026-11-12 14:30:00') | Should -Be 'InventarioForense_PC-01_PAT_01_cao_20261112143000' }
  It 'etiqueta limitada a 40 caracteres' { (Get-NomeSeguro ('x'*100)).Length | Should -Be 40 }
}
Describe 'Write-Log' {
  It 'grava linha formatada com BOM' {
    $p = Join-Path $TestDrive 'l.log'; New-ContextoColeta -Parametros @{} | Out-Null; $Script:Ctx.LogPath = $p
    Write-TextoUtf8Bom -Caminho $p -Texto "cab`r`n"; Write-Log -Nivel INFO -Area 'Teste' -Mensagem 'olá'
    ([IO.File]::ReadAllBytes($p))[0..2] | Should -Be @(0xEF,0xBB,0xBF)
    (Get-Content $p -Encoding UTF8)[1] | Should -Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} \[INFO\] \[Teste\] olá$'
  }
}
Describe 'Cultura' {
  It 'datas independem da cultura atual (th-TH)' {
    $orig = [System.Threading.Thread]::CurrentThread.CurrentCulture
    try {
      [System.Threading.Thread]::CurrentThread.CurrentCulture = 'th-TH'
      ConvertTo-DataTexto ([datetime]'2026-07-28 13:05:09') | Should -Be '2026-07-28 13:05:09'
      ConvertFrom-FileTime ([datetime]'2026-07-28 13:05:09').ToFileTime() | Should -Be '2026-07-28 13:05:09'
      Get-NomeColeta -Hostname 'PC' -Etiqueta '' -Data ([datetime]'2026-07-28 13:05:09') | Should -Be 'InventarioForense_PC_20260728130509'
    } finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $orig }
  }
}
