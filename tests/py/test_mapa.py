import sys
import tempfile
import unittest
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(RAIZ))

import ConsolidaColetas as cc  # noqa: E402

CAB = 'Padrao;Produto;Fabricante;Categoria;Ignorar\n'


class TestNormalizar(unittest.TestCase):
    def test_normalizar_exemplos(self):
        casos = {
            '7-Zip 26.05 (x64)': '7-Zip',
            'Microsoft .NET Host - 10.0.11 (x64)': 'Microsoft .NET Host',
            'NVIDIA App 11.0.9.565': 'NVIDIA App',
            'Microsoft Visual C++ 2022 X64 Minimum Runtime - 14.51.36247':
                'Microsoft Visual C++ 2022 Minimum Runtime',
            'Microsoft.WindowsCamera': 'Microsoft.WindowsCamera',
            'Microsoft 365 Apps for enterprise - en-us': 'Microsoft 365 Apps for enterprise',
            'Java(TM) SE Development Kit 25.0.4 (64-bit)': 'Java(TM) SE Development Kit',
            '1.2.3': '1.2.3',
            'Notepad++ (64-bit x64)': 'Notepad++',
            'Git version 2.45.1.windows.1': 'Git version',
            'Mozilla Firefox (x64 pt-BR)': 'Mozilla Firefox',
            'Mozilla Firefox (pt-BR)': 'Mozilla Firefox',
            'Mozilla Maintenance Service (x86 en-US)': 'Mozilla Maintenance Service',
        }
        for entrada, esperado in casos.items():
            self.assertEqual(cc.normalizar_nome(entrada), esperado, entrada)


class TestMapa(unittest.TestCase):
    def mapa(self, corpo):
        return cc.Mapa.de_texto(CAB + corpo, 'MapaSoftwares.csv')

    def test_curinga_regex_e_ordem(self):
        m = self.mapa('Microsoft 365 Apps*;Microsoft 365 Apps;Microsoft;Comercial;Nao\n'
                      're:^Adobe;;Adobe Inc.;Comercial;Nao\n'
                      'Adobe*;Outro;;X;Nao\n')
        c = m.classificar('microsoft 365 apps for enterprise - pt-br')
        self.assertEqual((c.produto, c.fabricante, c.categoria, c.ignorar, c.mapeado, c.regra),
                         ('Microsoft 365 Apps', 'Microsoft', 'Comercial', False, True, 2))
        c = m.classificar('Adobe Acrobat 24.1.2', 'Adobe')
        self.assertEqual(c.regra, 3)
        self.assertEqual(c.produto, 'Adobe Acrobat')
        self.assertEqual(c.fabricante, 'Adobe Inc.')
        self.assertEqual(c.categoria, 'Comercial')

    def test_padrao_casa_nome_normalizado(self):
        m = self.mapa('7-Zip;7-Zip;Igor Pavlov;Utilitario;Nao\n')
        c = m.classificar('7-Zip 26.05 (x64)')
        self.assertTrue(c.mapeado)
        self.assertEqual(c.fabricante, 'Igor Pavlov')

    def test_erros_mapa(self):
        casos = [
            ('Padrao;Produto;Fabricante;Categoria\nA;;;;\n', 'linha 1'),
            (CAB + 're:(;;;;Nao\n', 'linha 2'),
            (CAB + 'A;;;;Nao\nB;;;;Talvez\n', 'linha 3'),
            (CAB + ';P;;;Nao\n', 'linha 2'),
            (CAB + 'A;;;;Nao\nre:;;;;Nao\n', 'linha 3'),
        ]
        for texto, linha in casos:
            with self.assertRaises(cc.ErroMapa) as ctx:
                cc.Mapa.de_texto(texto, '/x/MapaSoftwares.csv')
            self.assertIn(linha, str(ctx.exception))
            self.assertTrue(str(ctx.exception).startswith('Mapa MapaSoftwares.csv, '))

    def test_mapa_cp1252(self):
        with tempfile.TemporaryDirectory() as t:
            p = Path(t) / 'm.csv'
            p.write_bytes((CAB + 'Contábil*;Contábil Pro;;;Nao\n').encode('cp1252'))
            m = cc.Mapa.carregar(p, Path(t))
            self.assertEqual(m.codificacao, 'cp1252')
            self.assertEqual(m.classificar('Contábil 2026').produto, 'Contábil Pro')
            self.assertEqual(len(m.sha256), 64)

    def test_codificacao_desconhecida(self):
        with tempfile.TemporaryDirectory() as t:
            p = Path(t) / 'm.csv'
            p.write_bytes((CAB + 'A;\x81;;;Nao\n').encode('latin-1'))
            with self.assertRaises(cc.ErroMapa) as ctx:
                cc.Mapa.carregar(p, Path(t))
            self.assertIn('codificacao nao reconhecida', str(ctx.exception))

    def test_carregar_padrao_embutido(self):
        with tempfile.TemporaryDirectory() as t:
            m = cc.Mapa.carregar(None, Path(t))
            self.assertEqual(m.origem, 'embutido')

    def test_embutido_ignora_sistema(self):
        m = cc.Mapa.de_texto(cc.MAPA_EMBUTIDO, 'embutido')
        self.assertTrue(m.classificar('Microsoft.WindowsCamera').ignorar)
        self.assertTrue(m.classificar('NVIDIA Graphics Driver 551.23').ignorar)
        self.assertFalse(m.classificar('7-Zip 26.05 (x64)').mapeado)

    def test_embutido_appx_inbox_e_fabricantes_de_hardware(self):
        m = cc.Mapa.de_texto(cc.MAPA_EMBUTIDO, 'embutido')
        ignorados = {
            'Microsoft.UI.Xaml.2.8': 'Runtime', 'Microsoft.UI.Xaml.CBS': 'Runtime',
            'Microsoft.VCLibs.140.00': 'Runtime', 'Microsoft.NET.Native.Framework.2.2': 'Runtime',
            'Microsoft.WindowsAppRuntime.1.5': 'Runtime', 'Microsoft.HEVCVideoExtension': 'Runtime',
            'Microsoft.VP9VideoExtensions': 'Runtime', 'Microsoft.WebpImageExtension': 'Runtime',
            'Microsoft.WidgetsPlatformRuntime': 'Runtime',
            'Microsoft.XboxGamingOverlay': 'Sistema', 'Microsoft.Xbox.TCUI': 'Sistema',
            'Microsoft.AAD.BrokerPlugin': 'Sistema', 'Microsoft.LockApp': 'Sistema',
            'Microsoft.Services.Store.Engagement': 'Sistema',
            'Microsoft.DesktopAppInstaller': 'Sistema', 'Microsoft.StorePurchaseApp': 'Sistema',
            'Microsoft.WindowsStore': 'Sistema', 'MicrosoftWindows.Client.CBS': 'Sistema',
            'Microsoft.Win32WebViewHost': 'Sistema', 'Microsoft.ECApp': 'Sistema',
            'Microsoft.CredDialogHost': 'Sistema', 'Microsoft.AsyncTextService': 'Sistema',
            'Microsoft.BioEnrollment': 'Sistema', 'Microsoft.Ink.Handwriting.Main.en-US': 'Sistema',
            'Microsoft.ApplicationCompatibilityEnhancements': 'Sistema',
            'Microsoft.MicrosoftEdgeDevToolsClient': 'Sistema', 'Microsoft.Winget.Source': 'Sistema',
            'Microsoft.GetHelp': 'Sistema', 'Microsoft.BingSearch': 'Sistema',
            'Microsoft.SecHealthUI': 'Sistema', 'Windows.PrintDialog': 'Sistema',
            'NVIDIA': 'Driver', 'NVIDIA Corporation': 'Driver', 'nvidia': 'Driver',
            'NVIDIA Graphics Driver 551.23': 'Driver', 'NVIDIACorp.NVIDIAControlPanel': 'Driver',
            'Intel': 'Driver', 'Intel(R) Wireless Bluetooth(R)': 'Driver',
            'Intel® Graphics Command Center': 'Driver', 'Intel Rapid Storage': 'Driver',
            'AppUp.IntelGraphicsExperience': 'Driver',
            'Dolby': 'Driver', 'Dolby DAX': 'Driver', 'DolbyLaboratories.DolbyAccess': 'Driver',
            'Synaptics SynTP': 'Driver', 'SynapticsIncorporated.SynHPCommercialDApp': 'Driver',
            'Realtek Audio Driver': 'Driver',
        }
        for nome, cat in ignorados.items():
            c = m.classificar(nome)
            self.assertTrue(c.ignorar, nome)
            self.assertEqual(c.categoria, cat, nome)
        for nome in ('IntelliJ IDEA Community Edition', 'Microsoft.Todos', 'Clipchamp.Clipchamp',
                     'Microsoft.MicrosoftOfficeHub', 'Microsoft.PowerToys.SparseApp',
                     'Microsoft.OneDriveSync', 'Microsoft 365 Apps for enterprise',
                     'Microsoft Teams', 'NVIDIAX Tool', 'Microsoft.Office.ActionsServer'):
            self.assertFalse(m.classificar(nome).mapeado, nome)

    def test_embutido_pastas_e_chaves_estruturais(self):
        m = cc.Mapa.de_texto(cc.MAPA_EMBUTIDO, 'embutido')
        for nome in ('Application Data', 'Dados de Aplicativos', 'Configurações Locais',
                     'Ambiente de Impressão', 'Meus Documentos', 'Modelos', 'Menu Iniciar',
                     'Cookies', 'Recent', 'SendTo', 'NetHood', 'PrintHood', 'Templates',
                     'Start Menu', 'Local Settings', 'My Documents', 'Temporary Internet Files',
                     'VirtualStore', 'SoftwareDistribution', 'USOShared', 'USOPrivate',
                     'D3DSCache', 'ssh', 'WindowsPowerShell', 'regid.1991-06.com.microsoft',
                     'Packages', 'ConnectedDevicesPlatform', 'PeerDistRepub', 'Comms',
                     'CrashDumps', 'Temp', 'appdatalow software', 'MozillaPlugins @java.com/x',
                     'OEM ADC', 'OEM', 'SyncIntegrationClients excel.exe', 'ChangeTracker',
                     'OpenSSH Agent', 'Netscape Navigator', 'Chromium BLBeacon'):
            c = m.classificar(nome)
            self.assertTrue(c.ignorar, nome)
            self.assertEqual(c.categoria, 'Sistema', nome)
        for nome in ('Temp Cleaner', 'Chromium', 'OpenSSH', 'Templates Pro', 'OEMTool'):
            self.assertFalse(m.classificar(nome).mapeado, nome)

    def test_mapa_do_repositorio_igual_ao_embutido(self):
        with tempfile.TemporaryDirectory() as t:
            p = Path(t) / 'MapaSoftwares.csv'
            cc.gerar_mapa(p)
            self.assertEqual((RAIZ / 'MapaSoftwares.csv').read_bytes(), p.read_bytes())

    def test_gerar_mapa_nao_sobrescreve(self):
        with tempfile.TemporaryDirectory() as t:
            p = Path(t) / 'MapaSoftwares.csv'
            cc.gerar_mapa(p)
            b = p.read_bytes()
            self.assertTrue(b.startswith(b'\xef\xbb\xbfPadrao;'))
            self.assertIn(b'\r\n', b)
            self.assertNotIn(b'\n', b.replace(b'\r\n', b''))
            with self.assertRaises(FileExistsError):
                cc.gerar_mapa(p)


if __name__ == '__main__':
    unittest.main()
