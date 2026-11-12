import logging
import sys
import tempfile
import unittest
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(RAIZ))

import ConsolidaColetas as cc  # noqa: E402
from tests.py import fabrica  # noqa: E402

CAB = 'Padrao;Produto;Fabricante;Categoria;Ignorar\n'


def sw(nome, **kw):
    d = {'Fonte': 'HKLM64', 'Nome': nome}
    d.update(kw)
    return d


def ev(fonte, item='', **kw):
    d = {'Fonte': fonte, 'Item': item}
    d.update(kw)
    return d


def pasta(caminho):
    raiz, _, nome = caminho.rpartition('\\')
    return {'Raiz': raiz, 'Pasta': nome, 'Caminho': caminho}


REMOVIDO_FOO = ev('EventoMSI', 'Foo Pro 2.1', Data='2026-03-01 10:00:00', TipoData='Removido')


class Base(unittest.TestCase):
    def setUp(self):
        logging.getLogger('consolida').addHandler(logging.NullHandler())
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.pasta = Path(self.tmp.name)
        self.con = cc.abrir_base(Path(':memory:'))
        self.addCleanup(self.con.close)
        self.mapa = cc.Mapa.de_texto(CAB + 'Lixo*;;;Sistema;Sim\n', 'MapaSoftwares.csv')

    def coleta(self, s07=(), s08=(), s14=(), **kw):
        zp = fabrica.nova_coleta(self.pasta, areas={'07': list(s07), '08': list(s08),
                                                    '14': list(s14)}, **kw)
        v = cc.verificar_zip(zp)
        sit, mot = cc.situacao_inicial(v, False)
        c, _ = cc.carregar_coleta(self.con, v, sit, mot)
        return c

    def vest(self, s07=(), s08=(), s14=()):
        self.n = getattr(self, 'n', 0) + 1
        c = self.coleta(s07, s08, s14, hostname=f'V{self.n}')
        spm = cc.softwares_da_coleta(self.con, c, self.mapa)
        return cc.vestigios_da_coleta(self.con, c, spm, self.mapa)


class TestNormalizarCaminho(unittest.TestCase):
    def test_exemplo(self):
        a = cc.normalizar_caminho('\\Device\\HarddiskVolume3\\Program Files\\X\\a.exe')
        b = cc.normalizar_caminho('C:\\Program Files\\X\\a.exe')
        self.assertEqual(a, '\\program files\\x\\a.exe')
        self.assertEqual(b, a)
        self.assertEqual(cc.normalizar_caminho('c:/Program Files/X/'), '\\program files\\x')

    def test_prefixos_e_aspas(self):
        esperado = '\\program files\\x\\a.exe'
        for c in ('\\\\?\\C:\\Program Files\\X\\a.exe', '\\??\\C:\\Program Files\\X\\a.exe',
                  '"C:\\Program Files\\X\\a.exe"', ' "C:\\Program Files\\X\\a.exe" '):
            self.assertEqual(cc.normalizar_caminho(c), esperado, c)
        self.assertEqual(cc.normalizar_caminho('"C:\\Program Files\\X\\"'), '\\program files\\x')


class TestVestigios(Base):
    def test_removido_nao_reinstalado(self):
        r = self.vest(s08=[REMOVIDO_FOO])
        self.assertEqual(len(r), 1)
        v = r[0]
        self.assertEqual(v['Produto'], 'Foo Pro')
        self.assertIs(v['Removido'], True)
        self.assertEqual(v['DataRemocao'], '2026-03-01 10:00:00')
        self.assertIn('Removido 2026-03-01 10:00:00 (EventoMSI)', v['Evidencias'])
        self.assertEqual(v['Fontes'], 'EventoMSI')
        self.assertEqual(v['PrimeiraData'], '2026-03-01 10:00:00')
        self.assertEqual(v['UltimaData'], '2026-03-01 10:00:00')
        self.assertFalse(v['_Mapeado'])
        self.assertEqual(v['_NomesOriginais'], 'Foo Pro 2.1')
        self.assertEqual(set(cc.COLUNAS_VESTIGIOS) - set(v), set())

    def test_removido_e_reinstalado(self):
        self.assertEqual(self.vest(s07=[sw('Foo Pro 2.2')], s08=[REMOVIDO_FOO]), [])

    def test_installer_cache_sozinho(self):
        r = self.vest(s08=[ev('InstallerCache', 'Bar Tool', Caminho='C:\\WINDOWS\\Installer\\5dc41.msi',
                              Data='2025-11-10 08:00:00', TipoData='ArquivoCriado')])
        self.assertEqual(len(r), 1)
        self.assertEqual(r[0]['Produto'], 'Bar Tool')
        self.assertEqual(r[0]['Fontes'], 'InstallerCache')
        self.assertIs(r[0]['Removido'], False)
        self.assertEqual(r[0]['Evidencias'],
                         '.msi no cache criado 2025-11-10 08:00:00 (InstallerCache)')

    def test_amcache_appx_ignorado(self):
        appx = ev('Amcache', 'Some.App', TipoData='Instalado',
                  Detalhe='Origem=AppxPackage;Desinstalador=;ProgramId=1')
        self.assertEqual(self.vest(s08=[appx]), [])
        msi = ev('Amcache', 'Baz 1.0', TipoData='Instalado',
                 Detalhe='Origem=AddRemoveProgram;Desinstalador=;ProgramId=2')
        r = self.vest(s08=[msi])
        self.assertEqual([v['Produto'] for v in r], ['Baz'])
        self.assertEqual(r[0]['Evidencias'], 'Registrado no Amcache')
        self.assertEqual(r[0]['PrimeiraData'], '')

    def test_chave_software(self):
        chave = ev('ChaveSoftware', 'Chrome', Fabricante='Google', Data='2026-01-05 12:00:00',
                   Caminho='HKEY_LOCAL_MACHINE\\SOFTWARE\\Google\\Chrome', TipoData='ChaveModificada')
        self.assertEqual(self.vest(s07=[sw('Google Chrome', Fabricante='Google LLC')], s08=[chave]), [])
        r = self.vest(s08=[chave])
        self.assertEqual([v['Produto'] for v in r], ['Google Chrome'])
        self.assertEqual(r[0]['Evidencias'], 'Chave HKEY_LOCAL_MACHINE\\SOFTWARE\\Google\\Chrome '
                                             'modificada 2026-01-05 12:00:00')
        ms = dict(chave, Fabricante='Microsoft', Item='Office')
        self.assertEqual(self.vest(s08=[ms]), [])
        setup = dict(chave, Fabricante='Acme', Item='Setup')
        self.assertEqual(self.vest(s08=[setup]), [])

    def test_chave_software_fabricante_e_palavra(self):
        chave = ev('ChaveSoftware', 'Reader', Fabricante='Adobe', TipoData='ChaveModificada',
                   Caminho='HKEY_LOCAL_MACHINE\\SOFTWARE\\Adobe\\Reader')
        s07 = [sw('Acrobat Reader DC', Fabricante='Adobe Systems')]
        self.assertEqual(self.vest(s07=s07, s08=[chave]), [])
        s07 = [sw('Google Chrome Beta')]
        chave = dict(chave, Fabricante='Google', Item='Chrome')
        self.assertEqual(self.vest(s07=s07, s08=[chave]), [])

    def test_pasta_remanescente_com_execucao(self):
        s08 = [ev('BAM', 'velho.exe', Caminho='\\Device\\HarddiskVolume3\\Program Files\\Velho\\velho.exe',
                  Data='2026-02-01 08:00:00', TipoData='UltimaExecucao'),
               ev('AmcacheArquivo', 'velho.exe', Caminho='c:\\program files\\velho\\velho.exe'),
               ev('Prefetch', 'VELHO.EXE', Data='2026-02-10 09:00:00', TipoData='UltimaExecucao'),
               ev('Prefetch', 'OUTRO.EXE', Data='2026-05-10 09:00:00', TipoData='UltimaExecucao'),
               ev('BAM', 'x.exe', Caminho='\\Device\\HarddiskVolume3\\Program Files\\Velhox\\x.exe',
                  Data='2026-06-01 08:00:00', TipoData='UltimaExecucao')]
        r = self.vest(s07=[sw('Outro', LocalInstalacao='C:\\Program Files\\Outro')],
                      s08=s08, s14=[pasta('C:\\Program Files\\Velho')])
        self.assertEqual([v['Produto'] for v in r], ['Velho'])
        v = r[0]
        self.assertEqual(v['PastaRemanescente'], 'C:\\Program Files\\Velho')
        self.assertEqual(v['UltimaExecucao'], '2026-02-10 09:00:00')
        self.assertEqual(v['Fontes'], 'AmcacheArquivo;BAM;PastasProgramas;Prefetch')
        self.assertEqual(v['Evidencias'],
                         'Pasta C:\\Program Files\\Velho; '
                         'Ultima execucao 2026-02-01 08:00:00 (BAM); '
                         'Ultima execucao 2026-02-10 09:00:00 (Prefetch)')

    def test_pasta_anexada_a_produto(self):
        s08 = [REMOVIDO_FOO,
               ev('BAM', 'foo.exe', Caminho='C:\\Program Files\\Foo Pro\\foo.exe',
                  Data='2026-02-01 08:00:00', TipoData='UltimaExecucao')]
        r = self.vest(s08=s08, s14=[pasta('C:\\Program Files\\Foo Pro')])
        self.assertEqual(len(r), 1)
        self.assertEqual(r[0]['PastaRemanescente'], 'C:\\Program Files\\Foo Pro')
        self.assertEqual(r[0]['UltimaExecucao'], '2026-02-01 08:00:00')
        self.assertEqual(r[0]['PrimeiraData'], '2026-02-01 08:00:00')
        self.assertEqual(r[0]['UltimaData'], '2026-03-01 10:00:00')

    def test_produto_sem_pasta_sem_execucao(self):
        s08 = [REMOVIDO_FOO,
               ev('Prefetch', 'FOO.EXE', Data='2026-02-10 09:00:00', TipoData='UltimaExecucao')]
        r = self.vest(s08=s08)
        self.assertEqual(r[0]['UltimaExecucao'], '')

    def test_pasta_do_software_instalado_nao_gera(self):
        s07 = [sw('Prog A', LocalInstalacao='C:\\Program Files\\Alfa\\bin\\'),
               sw('Prog B', Desinstalador='"C:\\Program Files\\BetaApp\\Uninstall.exe" /S'),
               sw('Prog C', Desinstalador='D:\\Apps\\Gama\\unins000.exe /SILENT'),
               sw('Prog D', Desinstalador='MsiExec.exe /X{1234}')]
        s14 = [pasta('C:\\Program Files\\Alfa'), pasta('c:\\program files\\betaapp'),
               pasta('C:\\Apps\\Gama')]
        self.assertEqual(self.vest(s07=s07, s14=s14), [])

    def test_local_instalacao_entre_aspas_nao_gera_pasta(self):
        s07 = [sw('Prog A', LocalInstalacao='"C:\\Program Files\\Alfa\\"')]
        self.assertEqual(self.vest(s07=s07, s14=[pasta('C:\\Program Files\\Alfa')]), [])

    def test_execucao_com_prefixo_longo(self):
        s08 = [ev('ShimCache', 'v.exe', Caminho='\\??\\C:\\Program Files\\Velho\\v.exe',
                  Data='2026-02-01 08:00:00', TipoData='ArquivoModificado')]
        r = self.vest(s08=s08, s14=[pasta('C:\\Program Files\\Velho')])
        self.assertEqual(r[0]['UltimaExecucao'], '2026-02-01 08:00:00')

    def test_raiz_ampla_instalada_nao_suprime(self):
        s07 = [sw('Prog A', LocalInstalacao='C:\\Program Files'),
               sw('Prog B', Desinstalador='"C:\\Uninstall.exe"')]
        r = self.vest(s07=s07, s14=[pasta('C:\\Program Files\\Velho')])
        self.assertEqual([v['Produto'] for v in r], ['Velho'])

    def test_chave_so_fabricante(self):
        chave = ev('ChaveSoftware', 'Acme', Fabricante='Acme', TipoData='ChaveModificada',
                   Caminho='HKEY_LOCAL_MACHINE\\SOFTWARE\\Acme')
        r = self.vest(s08=[chave])
        self.assertEqual([v['Produto'] for v in r], ['Acme'])
        self.assertEqual(r[0]['_NomesOriginais'], 'Acme')
        self.assertEqual(r[0]['Evidencias'], 'Chave HKEY_LOCAL_MACHINE\\SOFTWARE\\Acme modificada')
        self.assertEqual(self.vest(s07=[sw('Acme')], s08=[chave]), [])

    def test_datas_vazias_sem_espaco_duplo(self):
        s08 = [ev('EventoMSI', 'Foo', TipoData='Removido'),
               ev('InstallerCache', 'Foo', TipoData='ArquivoCriado')]
        r = self.vest(s08=s08)
        self.assertEqual(r[0]['Evidencias'], 'Removido (EventoMSI); '
                                             '.msi no cache criado (InstallerCache)')
        self.assertIs(r[0]['Removido'], True)
        self.assertEqual(r[0]['DataRemocao'], '')

    def test_pasta_instalada_pelo_nome_nao_gera(self):
        self.assertEqual(self.vest(s07=[sw('Zeta 1.0')], s14=[pasta('C:\\Program Files\\Zeta')]), [])

    def test_pasta_generica(self):
        s14 = [pasta('C:\\Program Files\\Common Files'), pasta('C:\\Program Files\\Windows Mail'),
               pasta('C:\\Program Files (x86)\\Microsoft Office'), pasta('C:\\Program Files\\dotnet')]
        self.assertEqual(self.vest(s14=s14), [])

    def test_ignorar_suprime(self):
        s08 = [ev('EventoMSI', 'Lixo Util 1.0', Data='2026-03-01 10:00:00', TipoData='Removido')]
        self.assertEqual(self.vest(s08=s08, s14=[pasta('C:\\Program Files\\Lixo Velho')]), [])

    def test_mapeado(self):
        self.mapa = cc.Mapa.de_texto(CAB + 'Foo Pro*;Foo Profissional;Foo Inc;Comercial;Nao\n', 'M.csv')
        r = self.vest(s08=[REMOVIDO_FOO])
        self.assertEqual(r[0]['Produto'], 'Foo Profissional')
        self.assertEqual(r[0]['Categoria'], 'Comercial')
        self.assertEqual(r[0]['Fabricante'], 'Foo Inc')
        self.assertTrue(r[0]['_Mapeado'])

    def test_data_compilacao_excluida(self):
        s08 = [ev('AmcacheArquivo', 'v.exe', Caminho='c:\\program files\\velho\\v.exe',
                  Data='2071-12-22 21:52:09', TipoData='ArquivoCompilado'),
               ev('BAM', 'v.exe', Caminho='C:\\Program Files\\Velho\\v.exe',
                  Data='2026-02-01 08:00:00', TipoData='UltimaExecucao')]
        r = self.vest(s08=s08, s14=[pasta('C:\\Program Files\\Velho')])
        self.assertEqual(len(r), 1)
        self.assertNotEqual(r[0]['UltimaData'], '2071-12-22 21:52:09')
        self.assertEqual(r[0]['PrimeiraData'], '2026-02-01 08:00:00')
        self.assertEqual(r[0]['UltimaData'], '2026-02-01 08:00:00')
        self.assertNotEqual(r[0]['UltimaExecucao'], '2071-12-22 21:52:09')
        self.assertEqual(r[0]['UltimaExecucao'], '2026-02-01 08:00:00')
        self.assertNotIn('2071', r[0]['Evidencias'])

    def test_ordem_e_evidencias_sem_repetir(self):
        s08 = [ev('InstallerCache', 'Zz', Data='2026-01-01 00:00:00', TipoData='ArquivoCriado'),
               ev('InstallerCache', 'Zz', Data='2026-01-01 00:00:00', TipoData='ArquivoCriado'),
               ev('EventoMSI', 'Zz', Data='2025-01-01 00:00:00', TipoData='Instalado'),
               ev('InstallerCache', 'aa', Data='2026-01-01 00:00:00', TipoData='ArquivoCriado')]
        r = self.vest(s08=s08)
        self.assertEqual([v['Produto'] for v in r], ['aa', 'Zz'])
        self.assertEqual(r[1]['Evidencias'], 'Instalado 2025-01-01 00:00:00 (EventoMSI); '
                                             '.msi no cache criado 2026-01-01 00:00:00 (InstallerCache)')
        self.assertEqual(r[1]['Fontes'], 'EventoMSI;InstallerCache')


def chave(fab, item, **kw):
    cam = 'HKEY_LOCAL_MACHINE\\SOFTWARE\\' + fab + ('\\' + item if item != fab else '')
    return ev('ChaveSoftware', item, Fabricante=fab, Caminho=cam, TipoData='ChaveModificada', **kw)


class TestCasamentoNomes(Base):
    """Regra R16: casamento por palavra nos dois sentidos, sem espacos e pela chave do fabricante."""

    def test_instalado_prefixo_da_candidata(self):
        for s07, ch in (([sw('7-Zip 26.05 (x64)')], chave('7-Zip', 'FM')),
                        ([sw('FileZilla 3.68.1')], chave('FileZilla 3', 'fzshellext')),
                        ([sw('LibreOffice 25.2.1.2')], chave('LibreOffice', 'UNO')),
                        ([sw('Python 3.12.1 Core Interpreter (64-bit)'), sw('Python 3.12.1')],
                         chave('Python', 'PythonCore'))):
            self.assertEqual(self.vest(s07=s07, s08=[ch]), [], ch['Caminho'])

    def test_igualdade_sem_espacos(self):
        r = self.vest(s07=[sw('Logi Download Assistant')], s08=[chave('Logi', 'DownloadAssistant')])
        self.assertEqual(r, [])

    def test_chave_do_fabricante_igual_ao_instalado(self):
        self.assertEqual(self.vest(s07=[sw('Box')], s08=[chave('Box', 'DeviceId')]), [])
        self.assertEqual(self.vest(s07=[sw('Box Drive')], s08=[chave('BoxDrive', 'Config')]), [])

    def test_item_que_ja_comeca_com_fabricante(self):
        r = self.vest(s08=[chave('AccessData', 'AccessData FTK Imager')])
        self.assertEqual([v['Produto'] for v in r], ['AccessData FTK Imager'])
        self.assertEqual(r[0]['_NomesOriginais'], 'AccessData FTK Imager')

    def test_sem_casamento_continua_vestigio(self):
        r = self.vest(s07=[sw('Java 8 Update 451')], s08=[chave('JavaSoft', 'Prefs')])
        self.assertEqual([v['Produto'] for v in r], ['JavaSoft Prefs'])
        r = self.vest(s07=[sw('Google Chrome')], s08=[chave('Google', 'Update')])
        self.assertEqual([v['Produto'] for v in r], ['Google Update'])

    def test_pasta_de_configuracao_de_instalado(self):
        s07 = [sw('VLC media player'), sw('Java 8 Update 451'), sw('Logi Download Assistant')]
        s14 = [pasta('C:\\Users\\u\\AppData\\Roaming\\vlc'),
               pasta('C:\\Users\\u\\AppData\\LocalLow\\Sun\\Java'),
               pasta('C:\\ProgramData\\Logi'), pasta('C:\\ProgramData\\Velho')]
        r = self.vest(s07=s07, s14=s14)
        self.assertEqual([v['Produto'] for v in r], ['Velho'])

    def test_evento_msi_continua_por_igualdade(self):
        s08 = [ev('EventoMSI', 'Java 8 Update 451', Data='2026-03-01 10:00:00', TipoData='Removido')]
        r = self.vest(s07=[sw('Java 8 Update 501')], s08=s08)
        self.assertEqual([v['Produto'] for v in r], ['Java 8 Update 451'])


class TestEstruturaisEmbutidos(Base):
    def setUp(self):
        super().setUp()
        self.mapa = cc.Mapa.de_texto(cc.MAPA_EMBUTIDO, 'embutido')

    def test_pastas_e_chaves_estruturais_nao_geram(self):
        s14 = [pasta('C:\\Users\\u\\AppData\\Local\\' + n)
               for n in ('Dados de Aplicativos', 'Application Data', 'VirtualStore', 'Temp',
                         'D3DSCache', 'NVIDIA', 'Intel', 'Dolby')]
        s14.append(pasta('C:\\ProgramData\\regid.1991-06.com.microsoft'))
        s08 = [chave('OEM', 'ADC'), chave('Chromium', 'BLBeacon'), chave('ChangeTracker', 'ChangeTracker'),
               chave('appdatalow', 'Software'), chave('Synaptics', 'SynTP'), chave('Dolby', 'DAX')]
        self.assertEqual(self.vest(s08=s08, s14=s14), [])

    def test_intellij_continua(self):
        r = self.vest(s14=[pasta('C:\\Program Files\\IntelliJ IDEA')])
        self.assertEqual([v['Produto'] for v in r], ['IntelliJ IDEA'])


class TestPorProduto(Base):
    def test_por_produto(self):
        linhas = []
        for host, data in (('PC1', '2026-11-12 10:00:00'), ('PC2', '2026-11-12 11:00:00')):
            c = self.coleta(s08=[REMOVIDO_FOO], hostname=host, data=data,
                            id_equipamento=host[-1] * 64)
            linhas += cc.vestigios_da_coleta(self.con, c, [], self.mapa)
        c = self.coleta(s08=[ev('InstallerCache', 'Bar', Data='2026-01-01 00:00:00',
                                TipoData='ArquivoCriado')], hostname='PC3', id_equipamento='3' * 64)
        linhas += cc.vestigios_da_coleta(self.con, c, [], self.mapa)
        p = cc.vestigios_por_produto(linhas)
        self.assertEqual([x['Produto'] for x in p], ['Foo Pro', 'Bar'])
        self.assertEqual(p[0]['Maquinas'], 2)
        self.assertEqual(p[0]['MaquinasComRemocao'], 2)
        self.assertEqual(p[0]['Hostnames'], 'PC1 | PC2')
        self.assertEqual(p[0]['PrimeiraData'], '2026-03-01 10:00:00')
        self.assertEqual(p[1]['MaquinasComRemocao'], 0)
        self.assertEqual(tuple(p[0]), cc.COLUNAS_VESTIGIOS_PRODUTO)


if __name__ == '__main__':
    unittest.main()
