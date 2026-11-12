import contextlib
import hashlib
import io
import logging
import re
import sqlite3
import sys
import tempfile
import time
import unittest
from datetime import datetime
from pathlib import Path
from unittest import mock

RAIZ = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(RAIZ))

import ConsolidaColetas as cc  # noqa: E402
from tests.py import fabrica  # noqa: E402

ID_A, ID_B, ID_C = 'A' * 64, 'B' * 64, 'C' * 64
RELOGIO = datetime(2026, 11, 12, 12, 0, 0)


def ler_csv_saida(caminho: Path):
    _, linhas = cc.ler_csv(caminho.read_bytes())
    return linhas


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.raiz = Path(self.tmp.name)
        self.entrada = self.raiz / 'entrada'
        self.saida = self.raiz / 'saida'
        self.mapa = cc.Mapa.de_texto(cc.MAPA_EMBUTIDO, 'embutido')

    def criar_coletas(self):
        e = self.entrada
        sw = {'07': [{'Fonte': 'Uninstall', 'Nome': 'Foo 1.0', 'Versao': '1.0', 'Fabricante': 'Acme'}]}
        fabrica.nova_coleta(e, hostname='PCA', id_equipamento=ID_A, data='2026-11-12 11:00:00',
                            modo='Padrao', areas=sw)
        fabrica.nova_coleta(e, hostname='PCA', id_equipamento=ID_A, data='2026-11-12 10:00:00',
                            modo='Completa', areas=sw)
        zb = fabrica.nova_coleta(e, hostname='PCB', id_equipamento=ID_B, areas=sw)
        Path(str(zb) + '.sha256').write_text(f'{"0" * 64}  {zb.name}\n', encoding='utf-8')
        fabrica.nova_coleta(e, hostname='PCC', id_equipamento=ID_C, areas=sw)

    def rodar(self, aceitar=False):
        with mock.patch.object(cc, '_agora', return_value=RELOGIO):
            return cc.consolidar(self.entrada, self.saida, self.mapa, aceitar, 'teste')


class TestFluxo(Base):
    def test_ponta_a_ponta(self):
        self.criar_coletas()
        codigo, pasta = self.rodar()
        self.assertEqual(codigo, 1)
        esperados = ['Consolidacao.sqlite', 'Relatorio.html', 'Consolidacao.log', 'SHA256SUMS.txt']
        esperados += ['csv/' + a.arquivo for a in cc.AREAS.values()]
        esperados += ['csv/' + n + '.csv' for n in cc.NOMES_ANALISES]
        for rel in esperados:
            self.assertTrue((pasta / rel).is_file(), rel)
        linhas = ler_csv_saida(pasta / 'csv' / 'A_Coletas.csv')
        self.assertEqual([l['Situacao'] for l in linhas],
                         ['Usada', 'Substituida', 'Rejeitada', 'Usada'])
        self.assertIn('Completa', linhas[0]['Modo'])
        self.assertIn('20261112100000', linhas[0]['IdColeta'])
        self.assertIn('Completa', linhas[0]['MotivoSelecao'])
        self.assertIn('20261112110000', linhas[1]['IdColeta'])
        self.assertEqual(linhas[1]['SubstituidaPor'], linhas[0]['IdColeta'])
        log = (pasta / 'Consolidacao.log').read_text(encoding='utf-8-sig')
        validas = [l for l in log.splitlines() if linhas[3]['IdColeta'] + ': hash do ZIP' in l]
        self.assertEqual(len(validas), 1)
        for trecho in (linhas[3]['HashZip'], '.zip.sha256 confere', 'manifesto confere',
                       'resumo ok', 'situacao Usada'):
            self.assertIn(trecho, validas[0])
        div = [l for l in log.splitlines() if linhas[2]['IdColeta'] + ': hash do ZIP' in l]
        self.assertEqual(len(div), 1)
        for trecho in (linhas[2]['HashZip'], '.zip.sha256 diverge', 'manifesto',
                       'resumo', 'situacao Rejeitada'):
            self.assertIn(trecho, div[0])
        soma = (pasta / 'SHA256SUMS.txt').read_text(encoding='utf-8').splitlines()
        self.assertTrue(soma)
        for l in soma:
            h, rel = l.split('  ', 1)
            self.assertEqual(hashlib.sha256((pasta / rel).read_bytes()).hexdigest(), h, rel)
        self.assertIn('Consolidacao.log', ' '.join(soma))
        con = sqlite3.connect(str(pasta / 'Consolidacao.sqlite'))
        self.addCleanup(con.close)
        self.assertEqual(con.execute('SELECT COUNT(*) FROM v_resumo').fetchone()[0], 2)
        self.assertEqual(con.execute("SELECT Valor FROM execucao WHERE Chave='VersaoScript'")
                         .fetchone()[0], '1.0.0')
        alertas = ler_csv_saida(pasta / 'csv' / 'A_Alertas.csv')
        self.assertIn('ColetaRejeitada', [a['Tipo'] for a in alertas])
        log = (pasta / 'Consolidacao.log').read_bytes()
        self.assertTrue(log.startswith(b'\xef\xbb\xbf'))
        self.assertNotIn(b'\n', log.replace(b'\r\n', b''))
        self.assertFalse([h for h in cc.log.handlers if not isinstance(h, logging.NullHandler)])

    def test_aceitar_nao_verificadas(self):
        self.criar_coletas()
        codigo, pasta = self.rodar(aceitar=True)
        self.assertEqual(codigo, 1)
        linhas = ler_csv_saida(pasta / 'csv' / 'A_Coletas.csv')
        self.assertEqual([l['Situacao'] for l in linhas],
                         ['Usada', 'Substituida', 'NaoVerificada', 'Usada'])
        con = sqlite3.connect(str(pasta / 'Consolidacao.sqlite'))
        self.addCleanup(con.close)
        self.assertEqual(con.execute('SELECT COUNT(*) FROM v_resumo').fetchone()[0], 3)

    def test_codigo_zero_quando_tudo_verificado(self):
        fabrica.nova_coleta(self.entrada, hostname='PCC', id_equipamento=ID_C)
        codigo, pasta = self.rodar()
        self.assertEqual(codigo, 0)

    def test_erro_de_analise_da_codigo_1(self):
        fabrica.nova_coleta(self.entrada, hostname='PCC', id_equipamento=ID_C)
        with mock.patch.object(cc, 'instaladores', side_effect=RuntimeError('falha')):
            codigo, pasta = self.rodar()
        self.assertEqual(codigo, 1)
        self.assertEqual(ler_csv_saida(pasta / 'csv' / 'A_Instaladores.csv'), [])
        tipos = [a['Tipo'] for a in ler_csv_saida(pasta / 'csv' / 'A_Alertas.csv')]
        self.assertIn('ErroAnalise', tipos)
        self.assertFalse([h for h in cc.log.handlers if not isinstance(h, logging.NullHandler)])
        self.assertIn('Traceback', (pasta / 'Consolidacao.log').read_text(encoding='utf-8-sig'))

    def test_erro_nas_saidas_da_codigo_1(self):
        fabrica.nova_coleta(self.entrada, hostname='PCC', id_equipamento=ID_C)
        with mock.patch.object(cc, 'gerar_html', side_effect=OSError('disco')):
            codigo, pasta = self.rodar()
        self.assertEqual(codigo, 1)
        self.assertFalse((pasta / 'Relatorio.html').exists())
        self.assertTrue((pasta / 'SHA256SUMS.txt').is_file())
        tipos = [a['Tipo'] for a in ler_csv_saida(pasta / 'csv' / 'A_Alertas.csv')]
        self.assertIn('ErroAnalise', tipos)
        self.assertFalse([h for h in cc.log.handlers if not isinstance(h, logging.NullHandler)])

    def test_erro_em_a_coletas_da_codigo_1(self):
        fabrica.nova_coleta(self.entrada, hostname='PCC', id_equipamento=ID_C)
        real, chamadas = cc.linhas_coletas, []

        def falha_na_segunda(coletas):
            chamadas.append(1)
            if len(chamadas) > 1:
                raise RuntimeError('x')
            return real(coletas)

        with mock.patch.object(cc, 'linhas_coletas', side_effect=falha_na_segunda):
            codigo, pasta = self.rodar()
        self.assertEqual(codigo, 1)

    def test_saida_nao_sobrescreve(self):
        fabrica.nova_coleta(self.entrada, hostname='PCC', id_equipamento=ID_C)
        _, p1 = self.rodar()
        _, p2 = self.rodar()
        self.assertEqual(p1.name, 'Consolidacao_20261112120000')
        self.assertEqual(p2.name, 'Consolidacao_20261112120000_2')
        self.assertTrue(p1.is_dir() and p2.is_dir())


class TestMain(Base):
    def main(self, *args):
        err = io.StringIO()
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
            codigo = cc.main([str(a) for a in args])
        return codigo, err.getvalue()

    def test_erros_de_uso(self):
        codigo, err = self.main(self.raiz / 'nao_existe')
        self.assertEqual(codigo, 2)
        self.assertTrue(err)
        self.entrada.mkdir()
        codigo, _ = self.main(self.entrada)
        self.assertEqual(codigo, 2)
        self.assertEqual(list(self.entrada.glob('Consolidacao_*')), [])
        fabrica.nova_coleta(self.entrada, hostname='PCC', id_equipamento=ID_C)
        ruim = self.raiz / 'ruim.csv'
        ruim.write_text('Coluna;Errada\n', encoding='utf-8')
        codigo, err = self.main(self.entrada, '--mapa', ruim)
        self.assertEqual(codigo, 2)
        self.assertIn('ruim.csv', err)
        self.assertEqual(list(self.entrada.glob('Consolidacao_*')), [])

    def test_mensagens_do_argparse_em_portugues(self):
        codigo, err = self.main('--xyz')
        self.assertEqual(codigo, 2)
        self.assertIn('uso: ConsolidaColetas.py', err)
        self.assertIn('Erro: argumentos nao reconhecidos: --xyz', err)
        self.assertNotIn('usage', err)
        codigo, err = self.main(self.raiz, '-o')
        self.assertEqual(codigo, 2)
        self.assertIn('o argumento -o exige um valor', err)
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(cc.main(['-h']), 0)
        ajuda = out.getvalue()
        for trecho in ('uso: ', 'argumentos posicionais', 'opcoes', 'mostra esta ajuda e termina'):
            self.assertIn(trecho, ajuda)
        for ingles in ('usage', 'show this help', 'positional arguments', 'options:'):
            self.assertNotIn(ingles, ajuda)

    def test_saida_sem_escrita_nao_cria_pastas(self):
        fabrica.nova_coleta(self.entrada, hostname='PCC', id_equipamento=ID_C)
        with mock.patch.object(cc.os, 'access', return_value=False):
            codigo, err = self.main(self.entrada, '-o', self.raiz / 'a' / 'b')
        self.assertEqual(codigo, 2)
        self.assertFalse((self.raiz / 'a').exists())

    def test_execucao_normal(self):
        fabrica.nova_coleta(self.entrada, hostname='PCC', id_equipamento=ID_C)
        codigo, _ = self.main(self.entrada, '-o', self.saida)
        self.assertEqual(codigo, 0)
        self.assertEqual(len(list(self.saida.glob('Consolidacao_*'))), 1)
        self.assertFalse([h for h in cc.log.handlers if not isinstance(h, logging.NullHandler)])

    def test_gerar_mapa(self):
        alvo = self.raiz / 'mapa.csv'
        self.assertEqual(self.main('--gerar-mapa', alvo)[0], 0)
        self.assertTrue(alvo.is_file())
        self.assertEqual(self.main('--gerar-mapa', alvo)[0], 2)


class TestVolume(Base):
    def test_volume(self):
        for i in range(60):
            linhas = [{'Fonte': 'ShimCache', 'Item': f'app{n}.exe',
                       'Caminho': f'C:\\Program Files\\Prod{n % 300}\\app{n}.exe',
                       'Data': '2026-01-01 10:00:00', 'TipoData': 'ArquivoModificado'}
                      for n in range(1500)]
            fabrica.nova_coleta(self.entrada, hostname=f'PC{i:03d}',
                                id_equipamento=f'{i:02x}' * 32, areas={'08': linhas})
        t0 = time.monotonic()
        codigo, pasta = self.rodar()
        self.assertLess(time.monotonic() - t0, 60)
        self.assertEqual(codigo, 0)
        self.assertEqual(len(ler_csv_saida(pasta / 'csv' / 'A_Coletas.csv')), 60)


class TestVolumeCompleta(Base):
    def test_area_16_grande(self):
        for i in range(20):
            linhas = [{'Local': 'C:', 'Arquivo': f'a{n}.exe', 'Caminho': f'C:\\d{n % 50}\\a{n}.exe',
                       'TamanhoBytes': str(n), 'SHA256': f'{n:064x}'} for n in range(5000)]
            fabrica.nova_coleta(self.entrada, hostname=f'PC{i:03d}', id_equipamento=f'{i:02x}' * 32,
                                modo='Completa', areas={'16': linhas})
        t0 = time.monotonic()
        codigo, pasta = self.rodar()
        self.assertLess(time.monotonic() - t0, 60)
        self.assertEqual(codigo, 0)
        inst = ler_csv_saida(pasta / 'csv' / 'A_Instaladores.csv')
        self.assertEqual(len(inst), 5000)
        self.assertEqual({r['Maquinas'] for r in inst}, {'20'})
        self.assertLess((pasta / 'Relatorio.html').stat().st_size, 200_000)


class TestLinguagem(Base):
    def test_linguagem_neutra(self):
        rx = re.compile(r'\b(perito|pericia|perícia|laudo|autos|vara)\b', re.IGNORECASE)
        fabrica.nova_coleta(self.entrada, hostname='PCC', id_equipamento=ID_C)
        _, pasta = self.rodar()
        textos = {
            'ConsolidaColetas.py': '\n'.join(
                l for l in (RAIZ / 'ConsolidaColetas.py').read_text(encoding='utf-8').splitlines()
                if 'EMAIL_AUTOR' not in l),
            'README.md': (RAIZ / 'README.md').read_text(encoding='utf-8-sig'),
            'Relatorio.html': (pasta / 'Relatorio.html').read_text(encoding='utf-8'),
        }
        for nome, texto in textos.items():
            self.assertIsNone(rx.search(texto), nome)


if __name__ == '__main__':
    unittest.main()
