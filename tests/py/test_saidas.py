import hashlib
import sys
import tempfile
import unittest
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(RAIZ))

import ConsolidaColetas as cc  # noqa: E402


class TestSaidas(unittest.TestCase):
    def setUp(self):
        self.con = cc.abrir_base(Path(':memory:'))
        self.addCleanup(self.con.close)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.pasta = Path(self.tmp.name)

    def _preparar(self, linhas07):
        for idc, sit in (('U', 'Usada'), ('S', 'Substituida')):
            self.con.execute('INSERT INTO coletas (IdColeta, Situacao) VALUES (?, ?)', (idc, sit))
        cc.inserir_linhas(self.con, cc.AREAS['07'], 'U', linhas07)
        cc.inserir_linhas(self.con, cc.AREAS['07'], 'S', [{'Hostname': 'ANTIGA'}])
        cc.criar_indices_e_views(self.con)

    def test_consolidado_so_usadas(self):
        self._preparar([{'Hostname': 'PC1'}])
        cc.exportar_consolidados(self.con, self.pasta)
        cab, linhas = cc.ler_csv((self.pasta / '07_Software_Instalado.csv').read_bytes())
        self.assertEqual([l['Hostname'] for l in linhas], ['PC1'])
        txt = (self.pasta / '07_Software_Instalado.csv').read_bytes()[3:].decode('utf-8')
        self.assertTrue(txt.startswith('"Hostname";"IdEquipamento";"DataColeta";"Fonte"'))
        self.assertNotIn('IdColeta', cab)

    def test_consolidado_vazio_tem_cabecalho(self):
        self._preparar([])
        cc.exportar_consolidados(self.con, self.pasta)
        dados = (self.pasta / '16_Arquivos_Completa.csv').read_bytes()
        cab, linhas = cc.ler_csv(dados)
        self.assertEqual(linhas, [])
        self.assertEqual(cab, list(cc.COLUNAS_COMUNS) + list(cc.AREAS['16'].colunas))
        self.assertEqual(dados.count(b'\r\n'), 1)

    def test_campos_dificeis_ida_e_volta(self):
        v07 = {'Hostname': 'PC1', 'Desinstalador': '"C:\\x\\u.exe" /S'}
        v11 = {'Hostname': 'PC1', 'Argumentos': 'a;b\r\nc'}
        for area, v in (('07', v07), ('11', v11)):
            for k in v:
                self.assertIn(k, list(cc.COLUNAS_COMUNS) + list(cc.AREAS[area].colunas))
        self._preparar([v07])
        cc.inserir_linhas(self.con, cc.AREAS['11'], 'U', [v11])
        cc.exportar_consolidados(self.con, self.pasta)
        for area, v in (('07', v07), ('11', v11)):
            _, linhas = cc.ler_csv((self.pasta / cc.AREAS[area].arquivo).read_bytes())
            for k, x in v.items():
                self.assertEqual(linhas[0][k], x)

    def test_chave_desconhecida_levanta(self):
        with self.assertRaises(ValueError):
            cc.gravar_analises(self.con, {'A_Inexistente': (('X',), [])})

    def test_sha256sums(self):
        (self.pasta / 'sub').mkdir()
        (self.pasta / 'b.csv').write_bytes(b'b')
        (self.pasta / 'B.csv').write_bytes(b'B')
        (self.pasta / 'sub' / 'a.csv').write_bytes(b'a')
        (self.pasta / 'SHA256SUMS.txt').write_bytes(b'velho')
        destino = cc.escrever_sha256sums(self.pasta)
        dados = destino.read_bytes()
        self.assertFalse(dados.startswith(b'\xef\xbb\xbf'))
        self.assertNotIn(b'\r', dados)
        linhas = dados.decode('utf-8').splitlines()
        self.assertEqual([l[66:] for l in linhas], ['B.csv', 'b.csv', 'sub/a.csv'])
        for l in linhas:
            h, rel = l[:64], l[66:]
            self.assertEqual(h, hashlib.sha256((self.pasta / rel).read_bytes()).hexdigest())
        self.assertTrue(dados.endswith(b'\n'))

    def test_chaves_internas_fora(self):
        cols = ('Produto', 'Maquinas')
        linhas = [{'Produto': 'P', 'Maquinas': 2, '_Mapeado': True}]
        self.con.execute('INSERT INTO coletas (IdColeta, Situacao) VALUES ("U", "Usada")')
        analises = {'A_Catalogo_Softwares': (cols, linhas),
                    'A_Matriz_Softwares': (('Produto', 'PC1'), [{'Produto': 'P', 'PC1': True}]),
                    'A_Coletas': (('IdColeta',), [{'IdColeta': 'U'}])}
        cc.exportar_analises(self.pasta, analises)
        cc.gravar_analises(self.con, dict(analises, A_Softwares_Por_Maquina=(('Produto',), []),
                                          A_Vestigios_Sem_Instalacao=(('Produto',), [])))
        for nome in analises:
            self.assertTrue((self.pasta / (nome + '.csv')).exists())
            self.assertNotIn(b'_Mapeado', (self.pasta / (nome + '.csv')).read_bytes())
        cols_t = [r[1] for r in self.con.execute('PRAGMA table_info(catalogo_softwares)')]
        self.assertEqual(cols_t, ['Produto', 'Maquinas'])
        self.assertEqual(self.con.execute('SELECT Maquinas FROM catalogo_softwares').fetchall(),
                         [('2',)])
        _, l = cc.ler_csv((self.pasta / 'A_Matriz_Softwares.csv').read_bytes())
        self.assertEqual(l[0]['PC1'], 'Sim')
        tabelas = {r[0] for r in self.con.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        self.assertNotIn('matriz_softwares', tabelas)

    def test_mapa_e_execucao(self):
        m = cc.Mapa([cc.RegraMapa(2, 'x*', 'X', 'F', 'C', True)], 'embutido')
        cc.gravar_mapa_e_execucao(self.con, m, {'Versao': '1.0.0'})
        self.assertEqual(self.con.execute('SELECT * FROM mapa').fetchall(),
                         [('2', 'x*', 'X', 'F', 'C', 'Sim')])
        self.assertEqual(self.con.execute('SELECT * FROM execucao').fetchall(),
                         [('Versao', '1.0.0')])


if __name__ == '__main__':
    unittest.main()
