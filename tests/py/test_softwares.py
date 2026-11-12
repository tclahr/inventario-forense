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


def sw(nome, fonte='HKLM64', versao='', **kw):
    d = {'Fonte': fonte, 'Nome': nome, 'Versao': versao}
    d.update(kw)
    return d


class Base(unittest.TestCase):
    def setUp(self):
        logging.getLogger('consolida').addHandler(logging.NullHandler())
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.pasta = Path(self.tmp.name)
        self.con = cc.abrir_base(Path(':memory:'))
        self.addCleanup(self.con.close)
        self.mapa = cc.Mapa.de_texto(
            CAB + 'Microsoft.WindowsCamera;;;Sistema;Sim\n', 'MapaSoftwares.csv')

    def carregar(self, linhas, **kw):
        zp = fabrica.nova_coleta(self.pasta, areas={'07': linhas}, **kw)
        v = cc.verificar_zip(zp)
        sit, mot = cc.situacao_inicial(v, False)
        c, _ = cc.carregar_coleta(self.con, v, sit, mot)
        return c


class TestSoftwares(Base):
    def test_dedup_por_produto(self):
        c = self.carregar([sw('7-Zip 26.05 (x64)', 'HKLM64', '26.05', Usuario='u1'),
                           sw('7-Zip 26.05 (x64)', 'MSI', '26.05', DataInstalacao='2026-01-01'),
                           sw('7-Zip 26.02 (x64)', 'HKLM64', '26.02', ComponenteSistema='Sim')])
        spm = cc.softwares_da_coleta(self.con, c, self.mapa)
        self.assertEqual(len(spm), 1)
        r = spm[0]
        self.assertEqual(r['Produto'], '7-Zip')
        self.assertEqual(r['Versoes'], '26.02 | 26.05')
        self.assertEqual(r['Fontes'], 'HKLM64 | MSI')
        self.assertEqual(r['NomesOriginais'], '7-Zip 26.02 (x64) | 7-Zip 26.05 (x64)')
        self.assertEqual(r['DatasInstalacao'], '2026-01-01')
        self.assertEqual(r['Usuarios'], 'u1')
        self.assertEqual(r['ComponenteSistema'], 'Sim')
        self.assertEqual(r['IdColeta'], c.id_coleta)
        self.assertFalse(r['_Mapeado'])
        self.assertIs(r['Ignorar'], False)

    def test_appx_sem_mapa(self):
        c = self.carregar([sw('Clipchamp.Clipchamp', 'Appx'),
                           sw('Microsoft.WindowsCamera', 'Appx')])
        spm = {r['Produto']: r for r in cc.softwares_da_coleta(self.con, c, self.mapa)}
        self.assertEqual(spm['Clipchamp.Clipchamp']['Categoria'], 'Appx')
        cam = spm['Microsoft.WindowsCamera']
        self.assertEqual(cam['Categoria'], 'Sistema')
        self.assertIs(cam['Ignorar'], True)
        self.assertTrue(cam['_Mapeado'])

    def test_ignorar_any(self):
        m = cc.Mapa.de_texto(CAB + 'Foo A;Foo;;;Nao\nFoo B;Foo;;;Sim\n', 'M.csv')
        c = self.carregar([sw('Foo A'), sw('Foo B')])
        r = cc.softwares_da_coleta(self.con, c, m)
        self.assertEqual(len(r), 1)
        self.assertIs(r[0]['Ignorar'], True)

    def test_matriz_rotulos_repetidos(self):
        c1 = self.carregar([sw('Zed', versao='1')], data='2026-11-12 10:00:00')
        c2 = self.carregar([sw('Zed', versao='2')], data='2026-11-12 11:00:00',
                           id_equipamento='A' * 8 + 'B' * 56)
        spm = (cc.softwares_da_coleta(self.con, c1, self.mapa)
               + cc.softwares_da_coleta(self.con, c2, self.mapa))
        cols, linhas = cc.matriz(spm, [c1, c2])
        self.assertEqual(len(set(cols)), 5)
        self.assertEqual(sorted([linhas[0][k] for k in cols[3:]]), ['1', '2'])

    def test_fabricante_da_linha(self):
        c = self.carregar([sw('Foo 1.0', Fabricante='Acme')])
        r = cc.softwares_da_coleta(self.con, c, self.mapa)[0]
        self.assertEqual(r['Fabricante'], 'Acme')

    def test_catalogo_conta_maquinas(self):
        c1 = self.carregar([sw('7-Zip 26.05 (x64)', versao='26.05')])
        c2 = self.carregar([sw('7-Zip 26.02 (x64)', versao='26.02'), sw('Zed 1.0')],
                           hostname='PC2', id_equipamento='B' * 64)
        spm = (cc.softwares_da_coleta(self.con, c1, self.mapa)
               + cc.softwares_da_coleta(self.con, c2, self.mapa))
        cat = cc.catalogo(spm)
        self.assertEqual([r['Produto'] for r in cat], ['7-Zip', 'Zed'])
        self.assertEqual(cat[0]['Maquinas'], 2)
        self.assertEqual(cat[0]['Versoes'], '26.02 | 26.05')
        self.assertEqual(cat[1]['Maquinas'], 1)

    def test_matriz_cabecalho_e_ignorados(self):
        c1 = self.carregar([sw('7-Zip 26.05 (x64)', versao='26.05'),
                            sw('Microsoft.WindowsCamera', 'Appx')], hostname='PC1',
                           id_equipamento='A' * 64)
        c2 = self.carregar([sw('Zed')], hostname='PC0', id_equipamento='B' * 64)
        spm = (cc.softwares_da_coleta(self.con, c1, self.mapa)
               + cc.softwares_da_coleta(self.con, c2, self.mapa))
        cols, linhas = cc.matriz(spm, [c1, c2])
        self.assertEqual(cols, ['Produto', 'Fabricante', 'Categoria',
                                'PC0 (BBBBBBBB)', 'PC1 (AAAAAAAA)'])
        self.assertEqual([l['Produto'] for l in linhas], ['7-Zip', 'Zed'])
        self.assertEqual(linhas[0]['PC1 (AAAAAAAA)'], '26.05')
        self.assertEqual(linhas[0]['PC0 (BBBBBBBB)'], '')
        self.assertEqual(linhas[1]['PC0 (BBBBBBBB)'], 'Sim')

    def test_nao_mapeados(self):
        c1 = self.carregar([sw('Foo*Bar 1.0', Fabricante='Acme'), sw('Solo')])
        c2 = self.carregar([sw('Foo*Bar 2.0')], hostname='PC2', id_equipamento='B' * 64)
        spm = [r for c in (c1, c2)
               for r in cc.softwares_da_coleta(self.con, c, self.mapa) if not r['_Mapeado']]
        vest = [{'IdColeta': c1.id_coleta, 'Produto': 'Solo', 'Fabricante': '',
                 '_NomesOriginais': 'Solo Setup', '_Mapeado': False},
                {'IdColeta': c1.id_coleta, 'Produto': 'Fantasma', 'Fabricante': '',
                 '_NomesOriginais': 'Fantasma 3', '_Mapeado': False}]
        res = cc.nao_mapeados(spm, vest)
        self.assertEqual([r['Produto'] for r in res], ['Foo*Bar', 'Fantasma', 'Solo'])
        foo, fan, solo = res
        self.assertEqual(foo['Padrao'], 're:^Foo\\*Bar$')
        self.assertEqual(foo['Maquinas'], 2)
        self.assertEqual(foo['Origem'], 'Instalado')
        self.assertEqual(foo['Fabricante'], 'Acme')
        self.assertEqual(foo['Ignorar'], 'Nao')
        self.assertEqual(foo['Categoria'], '')
        self.assertEqual(fan['Origem'], 'Vestigio')
        self.assertEqual(fan['Padrao'], 'Fantasma')
        self.assertEqual(solo['Origem'], 'Instalado; Vestigio')
        self.assertEqual(solo['NomesOriginais'], 'Solo | Solo Setup')


if __name__ == '__main__':
    unittest.main()
