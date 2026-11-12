BeforeAll {
    . "$PSScriptRoot/../../InventarioForense.ps1"
    # Stubs sem tipos, sempre definidos: no Windows os mocks dos comandos reais herdam os
    # parametros tipados (ex.: CimInstance) e rejeitam os objetos simples usados nos testes.
    foreach ($n in 'Get-PhysicalDisk', 'Get-LocalUser', 'Get-LocalGroupMember', 'Get-ScheduledTask', 'Get-ScheduledTaskInfo', 'Get-HotFix') {
        Set-Item -Path "function:global:$n" -Value { param($TaskName, $TaskPath, $SID) }
    }
    function global:Get-CimInstance { param($ClassName, $Namespace, $Filter) }
    function global:Get-WmiObject { param($Class, $Namespace, $Filter) }
    function global:Get-CimAssociatedInstance { param($InputObject, $ResultClassName) }
    if (-not (Get-Command netsh -ErrorAction SilentlyContinue)) { function global:netsh { } }
    function New-CtxTeste { param([bool]$Admin = $false) $null = New-ContextoColeta -Parametros @{}; $Script:Ctx.Admin = $Admin }
}

Describe 'Get-CimSafe' {
    It 'relanca a excecao original quando CIM e WMI falham' {
        Mock Get-CimInstance { throw 'falha cim' }
        Mock Get-WmiObject { throw 'falha wmi' }
        { Get-CimSafe -ClassName Win32_BIOS } | Should -Throw '*falha cim*'
    }
}

Describe 'Dados do ID' {
    It 'ID usa so discos nao USB e cacheia' {
        New-CtxTeste
        Mock Get-CimSafe { @([pscustomobject]@{ UUID = 'U-1'; SerialNumber = 'SB'; IdentifyingNumber = 'X' }) } -ParameterFilter { $ClassName -ne 'Win32_DiskDrive' }
        Mock Get-CimSafe {
            @([pscustomobject]@{ InterfaceType = 'SATA'; SerialNumber = 'S1'; PNPDeviceID = 'IDE\X' },
              [pscustomobject]@{ InterfaceType = 'USB'; SerialNumber = 'U1'; PNPDeviceID = 'USBSTOR\Y' })
        } -ParameterFilter { $ClassName -eq 'Win32_DiskDrive' }
        $r = Get-DadosIdEquipamento
        $r.Origem | Should -BeLike '*DISCO=S1'
        $Script:Ctx.Cache.BIOS | Should -Not -BeNullOrEmpty
        @($Script:Ctx.Cache.Discos).Count | Should -Be 2
    }
}

Describe 'ID sem discos USB UASP nem o disco da coleta' {
    BeforeEach {
        New-CtxTeste
        Mock Get-CimSafe { @([pscustomobject]@{ UUID = 'U-1'; SerialNumber = 'SB'; IdentifyingNumber = 'X' }) } -ParameterFilter { $ClassName -ne 'Win32_DiskDrive' -and $ClassName -ne 'Win32_LogicalDiskToPartition' }
        Mock Get-CimSafe { @() } -ParameterFilter { $ClassName -eq 'Win32_LogicalDiskToPartition' }
        Mock Get-CimSafe {
            @([pscustomobject]@{ InterfaceType = 'SCSI'; SerialNumber = 'S0'; PNPDeviceID = 'SCSI\DISK&VEN_NVME'; Index = 0 },
              [pscustomobject]@{ InterfaceType = 'SCSI'; SerialNumber = 'UASP1'; PNPDeviceID = 'SCSI\DISK&VEN_SAMSUNG'; Index = 1 },
              [pscustomobject]@{ InterfaceType = 'SCSI'; SerialNumber = 'UASP2'; PNPDeviceID = 'SCSI\DISK&VEN_WD'; Index = 2 },
              [pscustomobject]@{ InterfaceType = 'SCSI'; SerialNumber = 'COLETA'; PNPDeviceID = 'SCSI\DISK&VEN_X'; Index = 3 })
        } -ParameterFilter { $ClassName -eq 'Win32_DiskDrive' }
    }
    It 'BusType USB numerico ou texto sai do ID' {
        Mock Get-PhysicalDisk { @([pscustomobject]@{ DeviceId = '0'; BusType = 17 }, [pscustomobject]@{ DeviceId = '1'; BusType = 7 }, [pscustomobject]@{ DeviceId = '2'; BusType = 'USB' }) }
        $r = Get-DadosIdEquipamento
        $r.Origem | Should -BeLike '*DISCO=COLETA,S0'
    }
    It 'Disco que contem a unidade da coleta sai do ID (CIM e WMI legado)' {
        Mock Get-PhysicalDisk { @() }
        Mock Get-CimSafe {
            @([pscustomobject]@{ Antecedent = [pscustomobject]@{ DeviceID = 'Disk #0, Partition #1' }; Dependent = [pscustomobject]@{ DeviceID = 'C:' } },
              [pscustomobject]@{ Antecedent = '\\H\root\cimv2:Win32_DiskPartition.DeviceID="Disk #3, Partition #0"'; Dependent = '\\H\root\cimv2:Win32_LogicalDisk.DeviceID="E:"' })
        } -ParameterFilter { $ClassName -eq 'Win32_LogicalDiskToPartition' }
        $r = Get-DadosIdEquipamento -PastaReferencia 'e:\Coletas'
        $r.Origem | Should -BeLike '*DISCO=S0,UASP1,UASP2'
    }
    It 'Coleta gravada na unidade do sistema nao tira o disco do sistema do ID' {
        Mock Get-PhysicalDisk { @() }
        Mock Get-CimSafe {
            @([pscustomobject]@{ Antecedent = [pscustomobject]@{ DeviceID = 'Disk #0, Partition #1' }; Dependent = [pscustomobject]@{ DeviceID = 'C:' } })
        } -ParameterFilter { $ClassName -eq 'Win32_LogicalDiskToPartition' }
        $antes = $env:SystemDrive
        try {
            $env:SystemDrive = 'C:'
            $r = Get-DadosIdEquipamento -PastaReferencia 'C:\Coletas'
            $r.Origem | Should -BeLike '*DISCO=COLETA,S0,UASP1,UASP2'
        } finally { $env:SystemDrive = $antes }
    }
    It 'Falha do Get-PhysicalDisk mantem so o filtro atual' {
        Mock Get-PhysicalDisk { throw 'sem Storage' }
        $r = Get-DadosIdEquipamento
        $r.Origem | Should -BeLike '*DISCO=COLETA,S0,UASP1,UASP2'
    }
    It 'Erro nao terminante do Get-PhysicalDisk tambem e tolerado' {
        Mock Get-PhysicalDisk { Write-Error 'parcial' }
        { Get-DadosIdEquipamento } | Should -Not -Throw
    }
}

Describe 'Hardware' {
    BeforeEach {
        New-CtxTeste
        Mock Get-CimSafe { @() }
        Mock Get-CimSafe {
            @([pscustomobject]@{ DeviceLocator = 'D0'; Manufacturer = 'M'; PartNumber = 'P'; SerialNumber = 'SN'; Capacity = 8589934592; Speed = 3200; BankLabel = 'B0' })
        } -ParameterFilter { $ClassName -eq 'Win32_PhysicalMemory' }
        Mock Get-CimSafe {
            @([pscustomobject]@{ Model = 'Disco A'; Manufacturer = 'F'; SerialNumber = 'S1'; Size = 500107862016; FirmwareRevision = 'fw'; InterfaceType = 'SATA'; Index = 0; PNPDeviceID = 'IDE' })
        } -ParameterFilter { $ClassName -eq 'Win32_DiskDrive' }
    }
    It 'RAM em GB e Detalhe' {
        Mock Get-PhysicalDisk { @() }
        $l = @(Get-ColetaHardware) | Where-Object Tipo -eq 'RAM'
        ConvertTo-CampoTexto $l.Capacidade | Should -Be '8'
        $l.Unidade | Should -Be 'GB'
        $l.Detalhe | Should -Be 'Velocidade=3200MHz;Banco=B0'
        ConvertTo-CampoTexto ([math]::Round(12884901888 / 1GB, 1)) | Should -Be '12'
        ConvertTo-CampoTexto ([math]::Round(4.5GB / 1GB, 1)) | Should -Be '4,5'
    }
    It 'Colunas seguem o contrato' {
        Mock Get-PhysicalDisk { @() }
        $l = @(Get-ColetaHardware)[0]
        ($l.PSObject.Properties.Name -join ',') | Should -Be ($Script:Contrato['02'].Colunas -join ',')
    }
    It 'Midia do disco vem de Get-PhysicalDisk' {
        Mock Get-PhysicalDisk { @([pscustomobject]@{ DeviceId = '0'; MediaType = 'SSD'; BusType = 'NVMe' }) }
        $l = @(Get-ColetaHardware) | Where-Object Tipo -eq 'Disco'
        $l.Detalhe | Should -Be 'Interface=SATA;Midia=SSD;Barramento=NVMe'
    }
    It 'Falha do Get-PhysicalDisk nao derruba Hardware' {
        Mock Get-PhysicalDisk { throw 'x' }
        $l = @(Get-ColetaHardware) | Where-Object Tipo -eq 'Disco'
        @($l).Count | Should -Be 1
        $l.Detalhe | Should -BeLike '*Midia=Desconhecido*'
        $Script:Ctx.FontesComFalha | Should -Contain '02:MidiaDisco'
    }
    It 'WmiMonitorID sem suporte (VM, RDP, sem EDID) cai para Win32_DesktopMonitor sem falhar a fonte' {
        Mock Get-PhysicalDisk { @() }
        Mock Write-Log { }
        Mock Get-CimSafe { throw 'Not supported ' } -ParameterFilter { $ClassName -eq 'WmiMonitorID' }
        Mock Get-CimSafe {
            @([pscustomobject]@{ Name = 'Monitor PnP generico'; MonitorManufacturer = '(Tipos de monitor padrao)'; PNPDeviceID = 'DISPLAY\\X'; ScreenWidth = 1920; ScreenHeight = 1080 })
        } -ParameterFilter { $ClassName -eq 'Win32_DesktopMonitor' }
        $l = @(Get-ColetaHardware) | Where-Object Tipo -eq 'Monitor'
        @($l).Count | Should -Be 1
        $l.Descricao | Should -Be 'Monitor PnP generico'
        $l.Detalhe | Should -Be 'Origem=Win32_DesktopMonitor;Resolucao=1920x1080'
        $Script:Ctx.FontesComFalha | Should -Not -Contain '02:Monitor'
        Should -Invoke Write-Log -ParameterFilter { $Nivel -eq 'AVISO' -and $Mensagem -like 'WmiMonitorID indisponivel*' }
    }
}

Describe 'Disco USB no Hardware' {
    BeforeEach {
        New-CtxTeste
        Mock Get-PhysicalDisk { @() }
        Mock Get-CimSafe { @([pscustomobject]@{ UUID = 'U-1'; SerialNumber = 'SB'; IdentifyingNumber = 'X' }) } -ParameterFilter { $ClassName -ne 'Win32_DiskDrive' }
        Mock Get-CimSafe {
            @([pscustomobject]@{ Model = 'Interno'; InterfaceType = 'SATA'; SerialNumber = 'S1'; PNPDeviceID = 'IDE\X'; Index = 0 },
              [pscustomobject]@{ Model = 'Pendrive'; InterfaceType = 'USB'; SerialNumber = 'U1'; PNPDeviceID = 'USBSTOR\Y'; Index = 1 })
        } -ParameterFilter { $ClassName -eq 'Win32_DiskDrive' }
    }
    It 'ID primeiro, depois Hardware: USB listado no Hardware mas fora do ID' {
        $r = Get-DadosIdEquipamento
        $r.Origem | Should -Not -BeLike '*U1*'
        $d = @(Get-ColetaHardware) | Where-Object Tipo -eq 'Disco'
        @($d).Count | Should -Be 2
        ($d | Where-Object Modelo -eq 'Pendrive').Detalhe | Should -BeLike 'Interface=USB*'
    }
    It 'Hardware sozinho tambem lista o disco USB' {
        $d = @(Get-ColetaHardware) | Where-Object Tipo -eq 'Disco'
        @($d).Count | Should -Be 2
    }
}

Describe 'Volumes' {
    It 'Volumes tipo' {
        New-CtxTeste
        Mock Get-CimSafe { @([pscustomobject]@{ DeviceID = 'E:'; VolumeName = 'USB'; FileSystem = 'FAT32'; DriveType = 2; Size = 8589934592; FreeSpace = 4294967296; VolumeSerialNumber = 'AB12' }) } -ParameterFilter { $ClassName -eq 'Win32_LogicalDisk' }
        $l = @(Get-ColetaVolumes)
        $l[0].TipoUnidade | Should -Be 'Removivel'
        $l[0].BitLocker | Should -Be ''
        $Script:Ctx.FontesPuladas | Should -Contain '03:BitLocker'
    }
    It 'BitLocker com ProtectionStatus nulo fica vazio' {
        New-CtxTeste -Admin $true
        Mock Get-CimSafe { @([pscustomobject]@{ DeviceID = 'C:'; VolumeName = 'SO'; FileSystem = 'NTFS'; DriveType = 3; Size = 1GB; FreeSpace = 1GB; VolumeSerialNumber = '1' }) } -ParameterFilter { $ClassName -eq 'Win32_LogicalDisk' }
        Mock Get-CimSafe { @([pscustomobject]@{ DriveLetter = 'C:'; ProtectionStatus = $null }) } -ParameterFilter { $ClassName -eq 'Win32_EncryptableVolume' }
        @(Get-ColetaVolumes)[0].BitLocker | Should -Be ''
    }
    It 'BitLocker casa por letra com admin' {
        New-CtxTeste -Admin $true
        Mock Get-CimSafe { @([pscustomobject]@{ DeviceID = 'C:'; VolumeName = 'SO'; FileSystem = 'NTFS'; DriveType = 3; Size = 1GB; FreeSpace = 1GB; VolumeSerialNumber = '1' }) } -ParameterFilter { $ClassName -eq 'Win32_LogicalDisk' }
        Mock Get-CimSafe { @([pscustomobject]@{ DriveLetter = 'C:'; ProtectionStatus = 1 }) } -ParameterFilter { $ClassName -eq 'Win32_EncryptableVolume' }
        @(Get-ColetaVolumes)[0].BitLocker | Should -Be 'Ativado'
    }
}

Describe 'Rede' {
    BeforeEach {
        New-CtxTeste
        Mock Get-CimSafe {
            @([pscustomobject]@{ Index = 3; NetConnectionID = 'Ethernet'; Description = 'Intel'; Manufacturer = 'Intel'; MACAddress = 'AA:BB'; PhysicalAdapter = $true; NetEnabled = $true; NetConnectionStatus = 2; Speed = 1000000000 },
              [pscustomobject]@{ Index = 9; Description = 'Virtual'; MACAddress = $null; PhysicalAdapter = $false })
        } -ParameterFilter { $ClassName -eq 'Win32_NetworkAdapter' }
        Mock Get-CimSafe {
            @([pscustomobject]@{ Index = 3; IPAddress = @('10.0.0.5', 'fe80::1'); IPSubnet = @('255.255.255.0', '64'); DefaultIPGateway = @('10.0.0.1'); DNSServerSearchOrder = @('8.8.8.8'); DHCPEnabled = $true; DHCPServer = '10.0.0.1' })
        } -ParameterFilter { $ClassName -eq 'Win32_NetworkAdapterConfiguration' }
    }
    It 'Rede junta configuracao por Index' {
        Mock netsh { $global:LASTEXITCODE = 1 }
        $l = @(Get-ColetaRede)
        $l.Count | Should -Be 1
        $l[0].Status | Should -Be 'Conectado'
        $l[0].VelocidadeMbps | Should -Be 1000
        $l[0].EnderecosIP | Should -Be '10.0.0.5, fe80::1'
        $l[0].Gateway | Should -Be '10.0.0.1'
        ($l[0].PSObject.Properties.Name -join ',') | Should -Be ($Script:Contrato['04'].Colunas -join ',')
        $Script:Ctx.FontesComFalha.Count | Should -Be 0
    }
    It 'Adaptador com MAC sem configuracao fica com IP e DHCP vazios' {
        Mock Get-CimSafe { @() } -ParameterFilter { $ClassName -eq 'Win32_NetworkAdapterConfiguration' }
        Mock netsh { $global:LASTEXITCODE = 1 }
        $l = @(Get-ColetaRede)
        $l.Count | Should -Be 1
        $l[0].EnderecosIP | Should -BeNullOrEmpty
        $l[0].DHCP | Should -BeNullOrEmpty
    }
    It 'Wifi parse' {
        Mock netsh { $global:LASTEXITCODE = 0; 'Perfis na interface Wi-Fi:'; '    Todos os Perfis de Usuários : Escritório 5G'; '    All User Profile     : Home' }
        $w = @(Get-ColetaRede) | Where-Object Tipo -eq 'PerfilWifi'
        @($w).Count | Should -Be 2
        $w[0].Nome | Should -Be 'Escritório 5G'
        $w[1].Nome | Should -Be 'Home'
    }
}

Describe 'Contas' {
    BeforeEach { New-CtxTeste }
    It 'Contas fallback WMI' {
        Mock Get-LocalUser { throw 'x' }
        Mock Get-LocalGroupMember { throw 'y' }
        Mock Get-CimSafe { @([pscustomobject]@{ Name = 'adm'; SID = 'S-1-5-21-1-2-3-500'; Disabled = $false; PasswordExpires = $true; Description = 'd' }) } -ParameterFilter { $ClassName -eq 'Win32_UserAccount' }
        Mock Get-CimSafe { @([pscustomobject]@{ Name = 'Administradores'; SID = 'S-1-5-32-544' }) } -ParameterFilter { $ClassName -eq 'Win32_Group' -and $Filter -eq "LocalAccount=True AND SID='S-1-5-32-544'" }
        Mock Get-CimSafe { throw 'nao deveria varrer Win32_GroupUser' } -ParameterFilter { $ClassName -eq 'Win32_GroupUser' }
        Mock Get-CimAssociatedInstance { @([pscustomobject]@{ Name = 'adm'; SID = 'S-1-5-21-1-2-3-500' }) } -ParameterFilter { $InputObject.SID -eq 'S-1-5-32-544' -and $ResultClassName -eq 'Win32_UserAccount' }
        $c = @(Get-ColetaContas)
        $c[0].Fonte | Should -Be 'WMI'
        $c[0].Habilitada | Should -BeTrue
        $c[0].MembroAdministradores | Should -BeTrue
        ($c[0].PSObject.Properties.Name -join ',') | Should -Be ($Script:Contrato['05'].Colunas -join ',')
        Should -Invoke Get-CimSafe -Times 0 -ParameterFilter { $ClassName -eq 'Win32_GroupUser' }
        Should -Invoke Get-CimAssociatedInstance -Times 1 -Exactly
    }
    It 'Contas fallback WMI: conta fora do grupo nao e administradora' {
        Mock Get-LocalUser { throw 'x' }
        Mock Get-LocalGroupMember { throw 'y' }
        Mock Get-CimSafe { @([pscustomobject]@{ Name = 'u'; SID = 'S-1-5-21-1-2-3-1001'; Disabled = $false; PasswordExpires = $true; Description = '' }) } -ParameterFilter { $ClassName -eq 'Win32_UserAccount' }
        Mock Get-CimSafe { @([pscustomobject]@{ Name = 'Administradores'; SID = 'S-1-5-32-544' }) } -ParameterFilter { $ClassName -eq 'Win32_Group' }
        Mock Get-CimAssociatedInstance { @([pscustomobject]@{ Name = 'adm'; SID = 'S-1-5-21-1-2-3-500' }) }
        $c = @(Get-ColetaContas)
        $c[0].MembroAdministradores | Should -BeFalse
        $c[0].MembroAdministradores | Should -BeOfType [bool]
        Should -Invoke Get-CimAssociatedInstance -Times 1 -Exactly
    }
    It 'Contas fallback WMI legado usa GetRelated quando o objeto nao e CimInstance' {
        Mock Get-LocalUser { throw 'x' }
        Mock Get-LocalGroupMember { throw 'y' }
        Mock Get-CimSafe { @([pscustomobject]@{ Name = 'adm'; SID = 'S-1-5-21-1-2-3-500'; Disabled = $false; PasswordExpires = $true; Description = '' }) } -ParameterFilter { $ClassName -eq 'Win32_UserAccount' }
        $g = [pscustomobject]@{ Name = 'Administradores'; SID = 'S-1-5-32-544' }
        $g | Add-Member ScriptMethod GetRelated { param($classe) if ($classe -eq 'Win32_UserAccount') { [pscustomobject]@{ SID = 'S-1-5-21-1-2-3-500' } } }
        Mock Get-CimSafe { @($g) } -ParameterFilter { $ClassName -eq 'Win32_Group' }
        Mock Get-CimAssociatedInstance { throw 'nao e CimInstance' }
        $c = @(Get-ColetaContas)
        $c[0].MembroAdministradores | Should -BeTrue
    }
    It 'LocalUser com membros por SID' {
        Mock Get-LocalUser { @([pscustomobject]@{ Name = 'u'; SID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-1001' }; Enabled = $true; LastLogon = [datetime]'2026-01-02 03:04:05'; PasswordExpires = $null; PasswordLastSet = $null; Description = '' }) }
        Mock Get-LocalGroupMember { @() }
        $c = @(Get-ColetaContas)
        $c[0].Fonte | Should -Be 'LocalUser'
        $c[0].SID | Should -Be 'S-1-5-21-1-2-3-1001'
        $c[0].UltimoLogon | Should -Be '2026-01-02 03:04:05'
        $c[0].SenhaExpira | Should -BeFalse
        $c[0].MembroAdministradores | Should -BeFalse
    }
}

Describe 'Perfis' {
    It 'Perfil orfao' {
        New-CtxTeste
        $contas = @([pscustomobject]@{ SID = 'S-1-5-21-1-2-3-1001' })
        Mock Get-PerfisSistema {
            @([pscustomobject]@{ SID = 'S-1-5-21-1-2-3-1001'; Usuario = 'a'; Caminho = 'C:\Users\a'; UltimoUso = ''; Carregado = $false; Especial = $false },
              [pscustomobject]@{ SID = 'S-1-5-21-9-9-9-1105'; Usuario = 'b'; Caminho = 'C:\Users\b'; UltimoUso = ''; Carregado = $false; Especial = $false })
        }
        $p = @(Get-ColetaPerfis -Contas $contas)
        $p[0].ContaLocalCorrespondente | Should -BeTrue
        $p[0].ProvavelDominio | Should -BeFalse
        $p[1].ContaLocalCorrespondente | Should -BeFalse
        $p[1].ProvavelDominio | Should -BeTrue
        $p[1].NomeResolvido | Should -Be 'b'
        ($p[1].PSObject.Properties.Name -join ',') | Should -Be ($Script:Contrato['06'].Colunas -join ',')
    }
}

Describe 'Licencas' {
    It 'Canal e estado' {
        ConvertTo-CanalLicenca 'Windows(R) Operating System, VOLUME_KMSCLIENT channel' | Should -Be 'Volume:KMS'
        ConvertTo-CanalLicenca 'x retail channel' | Should -Be 'Retail'
        ConvertTo-CanalLicenca 'nada' | Should -Be ''
        ConvertTo-EstadoLicenca 1 | Should -Be 'Licenciado'
        ConvertTo-EstadoLicenca 9 | Should -Be '9'
    }
    It 'Chave OEM nunca completa' {
        New-CtxTeste
        Mock Get-CimSafe { @([pscustomobject]@{ Name = 'Windows 11 Pro'; Description = 'OEM_DM channel'; LicenseStatus = 1; PartialProductKey = 'XYZ12'; KeyManagementServiceMachine = $null; KeyManagementServicePort = 0 }) } -ParameterFilter { $ClassName -eq 'SoftwareLicensingProduct' }
        Mock Get-CimSafe { @([pscustomobject]@{ OA3xOriginalProductKey = 'AAAAA-BBBBB-CCCCC-DDDDD-EEEEE' }) } -ParameterFilter { $ClassName -eq 'SoftwareLicensingService' }
        $l = @(Get-ColetaLicencas)
        $l.Count | Should -Be 2
        $l[0].Canal | Should -Be 'OEM'
        $l[1].Produto | Should -Be 'ChaveOEMFirmware'
        $l[1].ChaveParcial | Should -Be 'EEEEE'
        $l[1].Detalhe | Should -Be 'Presente'
        foreach ($linha in $l) { foreach ($pr in $linha.PSObject.Properties) { [string]$pr.Value | Should -Not -BeLike '*AAAAA*' } }
    }
    It 'Chave OEM ausente' {
        New-CtxTeste
        Mock Get-CimSafe { @() } -ParameterFilter { $ClassName -eq 'SoftwareLicensingProduct' }
        Mock Get-CimSafe { @([pscustomobject]@{ OA3xOriginalProductKey = '' }) } -ParameterFilter { $ClassName -eq 'SoftwareLicensingService' }
        $l = @(Get-ColetaLicencas)
        $l[0].Detalhe | Should -Be 'Ausente'
        $l[0].ChaveParcial | Should -Be ''
    }
}

Describe 'Get-CaminhoExecutavel' {
    It 'extrai o executavel' {
        Get-CaminhoExecutavel '"C:\Program Files\X\a.exe" -k' | Should -Be 'C:\Program Files\X\a.exe'
        Get-CaminhoExecutavel 'C:\Program Files\Y\b.exe /s' | Should -Be 'C:\Program Files\Y\b.exe'
        Get-CaminhoExecutavel '\??\C:\Windows\z.sys' | Should -Be 'C:\Windows\z.sys'
        Get-CaminhoExecutavel '' | Should -Be ''
    }
    It 'caminho relativo ao sistema recebe SystemRoot' {
        $env:SystemRoot = 'C:\Windows'
        Get-CaminhoExecutavel 'system32\DRIVERS\y.sys' | Should -Be 'C:\Windows\system32\DRIVERS\y.sys'
    }
    It 'sem aspas: usa o primeiro prefixo que existe' {
        Mock Test-Path { $LiteralPath -eq 'C:\Program Files\App\app.exe' }
        Get-CaminhoExecutavel 'C:\Program Files\App\app.exe C:\Temp\setup.exe' | Should -Be 'C:\Program Files\App\app.exe'
    }
    It 'sem aspas: nenhum existe devolve o menor prefixo' {
        Mock Test-Path { $false }
        Get-CaminhoExecutavel 'C:\Program Files\App\app.exe C:\Temp\setup.exe' | Should -Be 'C:\Program Files\App\app.exe'
    }
    It 'sem aspas: so o segundo existe devolve o segundo' {
        Mock Test-Path { $LiteralPath -eq 'C:\Program Files\App\app.exe C:\Temp\setup.exe' }
        Get-CaminhoExecutavel 'C:\Program Files\App\app.exe C:\Temp\setup.exe' | Should -Be 'C:\Program Files\App\app.exe C:\Temp\setup.exe'
    }
    It 'expande SystemRoot' {
        $env:SystemRoot = 'C:\Windows'
        Get-CaminhoExecutavel '\SystemRoot\System32\drivers\x.sys' | Should -BeLike 'C:\Windows*'
        Get-CaminhoExecutavel '\SystemRoot\System32\drivers\x.sys' | Should -Not -BeLike '*SystemRoot*'
    }
}

Describe 'Caminhos UNC nao sao sondados' {
    It 'Test-CaminhoRede reconhece UNC e \\?\UNC, mas nao \\?\C:' {
        Test-CaminhoRede '\\srv\share\a.exe' | Should -BeTrue
        Test-CaminhoRede '\\?\UNC\srv\share\a.exe' | Should -BeTrue
        Test-CaminhoRede '\\?\C:\Windows\a.exe' | Should -BeFalse
        Test-CaminhoRede 'C:\a.exe' | Should -BeFalse
        Test-CaminhoRede '' | Should -BeFalse
    }
    It 'Test-CaminhoExiste devolve Rede sem chamar Test-Path' {
        Mock Test-Path { throw 'nao deveria sondar' }
        Test-CaminhoExiste '\\srv\share\a.exe' | Should -Be 'Rede'
        Test-CaminhoExiste '\\?\UNC\srv\share\a.exe' | Should -Be 'Rede'
        Should -Invoke Test-Path -Times 0 -Exactly
    }
    It 'Get-CaminhoExecutavel sem aspas em UNC devolve o menor prefixo sem Test-Path' {
        Mock Test-Path { throw 'nao deveria sondar' }
        Get-CaminhoExecutavel '\\srv\share\app.exe \\srv\share\b.exe' | Should -Be '\\srv\share\app.exe'
        Should -Invoke Test-Path -Times 0 -Exactly
    }
    It 'Test-ExecutavelExiste em UNC devolve Rede sem Test-Path' {
        Mock Test-Path { throw 'nao deveria sondar' }
        Test-ExecutavelExiste '"\\srv\share\s.exe" -k' | Should -Be 'Rede'
        Test-ExecutavelExiste '\\srv\share\s.exe -k' | Should -Be 'Rede'
        Should -Invoke Test-Path -Times 0 -Exactly
    }
    It 'Caminho local continua sondado' {
        Mock Test-Path { $true }
        Test-CaminhoExiste 'C:\x\a.exe' | Should -Be 'Sim'
    }
}

Describe 'Servicos, tarefas, drivers' {
    BeforeEach { New-CtxTeste }
    It 'Servico ExecutavelExiste' {
        Mock Test-Path { $false }
        Mock Get-CimSafe { @([pscustomobject]@{ Name = 's'; DisplayName = 'S'; State = 'Running'; StartMode = 'Auto'; StartName = 'LocalSystem'; PathName = '"C:\x\s.exe" -k' }) } -ParameterFilter { $ClassName -eq 'Win32_Service' }
        $s = @(Get-ColetaServicos)
        $s[0].ExecutavelExiste | Should -Be 'Nao'
        $s[0].TipoInicio | Should -Be 'Auto'
        ($s[0].PSObject.Properties.Name -join ',') | Should -Be ($Script:Contrato['10'].Colunas -join ',')
    }
    It 'Tarefa com argumentos contendo ;' {
        Mock Test-Path { $true }
        $acao = [pscustomobject]@{ Execute = 'C:\x\a.exe'; Arguments = '-a;b "c;d"' }
        Mock Get-ScheduledTask { @([pscustomobject]@{ TaskPath = '\'; TaskName = 'T1'; Author = 'me'; State = 'Ready'; Date = '2026-01-01T10:00:00'; Actions = @($acao) },
            [pscustomobject]@{ TaskPath = '\'; TaskName = 'T2'; Author = ''; State = 'Ready'; Date = $null; Actions = @() }) }
        Mock Get-ScheduledTaskInfo { if ($TaskName -eq 'T2') { throw 'x' }; [pscustomobject]@{ LastRunTime = [datetime]'2026-02-03 04:05:06'; NextRunTime = $null } }
        $t = @(Get-ColetaTarefas)
        $t.Count | Should -Be 2
        $t[0].Argumentos | Should -Be '-a;b "c;d"'
        $t[0].ExecutavelExiste | Should -Be 'Sim'
        $t[0].UltimaExecucao | Should -Be '2026-02-03 04:05:06'
        $t[0].CriadaEm | Should -Be '2026-01-01 10:00:00'
        $t[1].UltimaExecucao | Should -Be ''
        ($t[1].PSObject.Properties.Name -join ',') | Should -Be ($Script:Contrato['11'].Colunas -join ',')
    }
    It 'Drivers' {
        Mock Get-CimSafe { @([pscustomobject]@{ DeviceName = 'D'; DeviceClass = 'NET'; Manufacturer = 'M'; DriverProviderName = 'P'; DriverVersion = '1.0'; DriverDate = '20240102000000.000000-000'; InfName = 'oem1.inf'; IsSigned = $true; Signer = 'MS' }) } -ParameterFilter { $ClassName -eq 'Win32_PnPSignedDriver' }
        $d = @(Get-ColetaDrivers)
        $d[0].Assinado | Should -BeTrue
        $d[0].Data | Should -Be '2024-01-02 00:00:00'
        ($d[0].PSObject.Properties.Name -join ',') | Should -Be ($Script:Contrato['12'].Colunas -join ',')
    }
}

Describe 'Atualizacoes' {
    It 'WindowsUpdate falha isolada' {
        New-CtxTeste
        Mock Get-HotFix { @([pscustomobject]@{ HotFixID = 'KB1'; Description = 'Update'; InstalledOn = [datetime]'2026-03-04'; InstalledBy = 'NT AUTHORITY\SYSTEM' }) }
        Mock New-SessaoAtualizacao { throw 'x' }
        $a = @(Get-ColetaAtualizacoes)
        $a.Count | Should -Be 1
        $a[0].Fonte | Should -Be 'HotFix'
        $a[0].Id | Should -Be 'KB1'
        $a[0].InstaladoEm | Should -Be '2026-03-04 00:00:00'
        $Script:Ctx.FontesComFalha | Should -Contain '13:WindowsUpdate'
        Should -Invoke New-SessaoAtualizacao -Times 1
        ($a[0].PSObject.Properties.Name -join ',') | Should -Be ($Script:Contrato['13'].Colunas -join ',')
    }
    It 'WindowsUpdate historico com sucesso' {
        New-CtxTeste
        Mock Get-HotFix { @() }
        Mock New-SessaoAtualizacao {
            $busca = New-Object psobject
            $busca | Add-Member -MemberType ScriptMethod -Name GetTotalHistoryCount -Value { 2 }
            $busca | Add-Member -MemberType ScriptMethod -Name QueryHistory -Value {
                param($i, $n)
                @([pscustomobject]@{ Title = 'Atualizacao (KB5034441)'; ResultCode = 2; Date = [datetime]'2026-01-10 08:00:00' },
                  [pscustomobject]@{ Title = 'Sem kb'; ResultCode = 4; Date = [datetime]'2026-01-11 09:00:00' })
            }
            $sessao = New-Object psobject
            $sessao | Add-Member -MemberType ScriptMethod -Name CreateUpdateSearcher -Value { $busca }.GetNewClosure()
            $sessao
        }
        $a = @(Get-ColetaAtualizacoes)
        $a.Count | Should -Be 2
        $a[0].Fonte | Should -Be 'WindowsUpdate'
        $a[0].Id | Should -Be 'KB5034441'
        $a[0].Resultado | Should -Be 'Sucesso'
        # a data do COM vem em UTC: sai convertida para a hora local
        $a[0].InstaladoEm | Should -Be ([datetime]::SpecifyKind([datetime]'2026-01-10 08:00:00', 'Utc').ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss', [cultureinfo]::InvariantCulture))
        $a[1].Id | Should -Be ''
        $a[1].Resultado | Should -Be 'Falha'
        $Script:Ctx.FontesComFalha.Count | Should -Be 0
    }
}
