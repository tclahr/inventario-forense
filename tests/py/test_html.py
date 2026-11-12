import json
import re
import sys
import unittest
from html.parser import HTMLParser
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(RAIZ))

import ConsolidaColetas as cc  # noqa: E402
from tests.py.test_carga_selecao import Base  # noqa: E402

ABAS = ('Visão geral', 'Máquinas', 'Softwares', 'Vestígios sem instalação', 'Instaladores',
        'Licenças', 'Ficha da máquina')


class _Script(HTMLParser):
    def __init__(self):
        super().__init__()
        self.dentro = False
        self.texto = ''

    def handle_starttag(self, tag, attrs):
        if tag == 'script' and dict(attrs).get('id') == 'dados':
            self.dentro = True

    def handle_endtag(self, tag):
        if tag == 'script':
            self.dentro = False

    def handle_data(self, data):
        if self.dentro:
            self.texto += data


def _dados_minimos(**extra):
    d = {'execucao': {}, 'totais': {}, 'alertas': [], 'maquinas': [], 'catalogo': [],
         'softwares': [], 'vestigios': [], 'vestigios_produto': [], 'instaladores': [],
         'licencas': [], 'fichas': {}}
    d.update(extra)
    return d


class TestHtml(Base):
    def gerar(self, dados):
        destino = self.pasta / 'Relatorio.html'
        cc.gerar_html(destino, dados)
        return destino.read_text(encoding='utf-8')

    def test_json_embutido_valido(self):
        dados = _dados_minimos(execucao={'Perigo': '</script><script>alert(1)</script> <!-- x'})
        html = self.gerar(dados)
        p = _Script()
        p.feed(html)
        self.assertEqual(json.loads(p.texto), dados)
        self.assertEqual(html.count('</script>'), 2)

    def test_sem_recursos_externos(self):
        dados = _dados_minimos(execucao={'Url': 'https://exemplo.invalid/a', 'Cdn': '//cdn.x'})
        html = self.gerar(dados)
        self.assertIsNone(re.search(r'https?://|//cdn', html))

    def test_abas_e_aviso(self):
        html = self.gerar(_dados_minimos())
        self.assertIn('<title>Consolidação de Coletas</title>', html)
        for aba in ABAS:
            self.assertIn('>' + aba + '</button>', html)
        self.assertIn(cc.AVISO_CRUZAMENTO, html)

    def test_expandir_agrupa_produto_sem_caixa(self):
        js = cc._MODELO_HTML
        self.assertIn('function chaveProduto(s) { return String(s == null ? \'\' : s).toLowerCase(); }', js)
        self.assertIn('var k = chaveProduto(r[campo]);', js)
        self.assertIn('swPorProduto[chaveProduto(r.Produto)]', js)
        self.assertIn('vePorProduto[chaveProduto(r.Produto)]', js)
        self.assertNotIn('swPorProduto[r.Produto]', js)
        self.assertNotIn('vePorProduto[r.Produto]', js)

    def test_ignorados_fora_por_padrao(self):
        html = self.gerar(_dados_minimos())
        m = re.search(r'<input[^>]*id="mostrar-ignorados"[^>]*>', html)
        self.assertIsNotNone(m)
        self.assertNotIn('checked', m.group(0))
        self.assertIn('Mostrar ignorados', html)

    def test_dados_html(self):
        c1, _ = self.carregar(hostname='PC1', resumo={'Etiqueta': 'E1'}, areas={
            '02': [{'Tipo': 'Memoria'}], '03': [{'Letra': 'C:'}], '04': [{'Nome': 'Eth'}],
            '15': [{'Arquivo': 'a.exe', 'SHA256': 'aa'}]})
        c2, _ = self.carregar(hostname='PC2', id_equipamento='B' * 64)
        c1.situacao, c2.situacao = 'Usada', 'Rejeitada'
        spm = [{'IdColeta': c1.id_coleta, 'Hostname': 'PC1', 'Produto': 'X', 'Ignorar': False,
                '_Mapeado': True},
               {'IdColeta': c1.id_coleta, 'Hostname': 'PC1', 'Produto': 'Y', 'Ignorar': True}]
        vest = [{'IdColeta': c1.id_coleta, 'Hostname': 'PC1', 'Produto': 'Z', 'Removido': True,
                 '_NomesOriginais': 'z'}]
        analises = {
            'A_Softwares_Por_Maquina': (cc.COLUNAS_SPM, spm),
            'A_Catalogo_Softwares': (cc.COLUNAS_CATALOGO, [
                {'Produto': 'X', 'Ignorar': False, 'Maquinas': 1},
                {'Produto': 'Y', 'Ignorar': True, 'Maquinas': 1}]),
            'A_Vestigios_Sem_Instalacao': (cc.COLUNAS_VESTIGIOS, vest),
            'A_Instaladores': (cc.COLUNAS_INSTALADORES, [{'SHA256': 'ab', 'Maquinas': 1},
                                                         {'SHA256': 'cd', 'Maquinas': 1}]),
            'A_Alertas': (cc.COLUNAS_ALERTAS, [{'Tipo': 'ColetaRejeitada'}]),
        }
        d = cc.dados_html(self.con, [c1, c2], analises, {'Versao': cc.VERSAO})
        self.assertEqual(d['totais']['maquinas'], '1')
        self.assertEqual(d['totais']['coletas_usadas'], '1')
        self.assertEqual(d['totais']['rejeitadas'], '1')
        self.assertEqual(d['totais']['substituidas'], '0')
        self.assertEqual(d['totais']['produtos'], '1')
        self.assertEqual(d['totais']['vestigios'], '1')
        self.assertEqual(d['totais']['instaladores'], '1')
        self.assertEqual([r['SHA256'] for r in d['instaladores']], ['aa'])
        self.assertEqual([m['Hostname'] for m in d['maquinas']], ['PC1'])
        m = d['maquinas'][0]
        self.assertEqual(m['IdColeta'], c1.id_coleta)
        self.assertEqual(m['Etiqueta'], 'E1')
        self.assertEqual(m['TotalSoftwares'], '1')
        self.assertEqual(m['TotalVestigiosSemInstalacao'], '1')
        self.assertEqual([s['Ignorar'] for s in d['softwares']], ['Nao', 'Sim'])
        self.assertNotIn('_Mapeado', d['softwares'][0])
        self.assertNotIn('_NomesOriginais', d['vestigios'][0])
        self.assertEqual(d['vestigios'][0]['Removido'], 'Sim')
        self.assertEqual(list(d['fichas']), [c1.id_coleta])
        f = d['fichas'][c1.id_coleta]
        self.assertEqual(f['resumo']['Etiqueta'], 'E1')
        self.assertEqual(f['hardware'][0]['Tipo'], 'Memoria')
        self.assertEqual(f['volumes'][0]['Letra'], 'C:')
        self.assertEqual(f['rede'][0]['Nome'], 'Eth')

        def so_str(v):
            if isinstance(v, dict):
                return all(isinstance(k, str) and so_str(x) for k, x in v.items())
            if isinstance(v, list):
                return all(so_str(x) for x in v)
            return isinstance(v, str)
        self.assertTrue(so_str(d))
        html = self.gerar(d)
        p = _Script()
        p.feed(html)
        self.assertEqual(json.loads(p.texto), d)

    def test_sem_autor_no_html(self):
        c, _ = self.carregar(hostname='PC1')
        c.situacao = 'Usada'
        execucao = {'VersaoScript': cc.VERSAO, 'Autor': cc.AUTOR, 'EmailAutor': cc.EMAIL_AUTOR,
                    'Outro': 'Autor ' + cc.AUTOR, 'Contato': f'x <{cc.EMAIL_AUTOR}>'}
        html = self.gerar(cc.dados_html(self.con, [c], {}, execucao))
        self.assertNotIn(cc.AUTOR, html)
        self.assertNotIn(cc.EMAIL_AUTOR, html)
        self.assertIn('VersaoScript', html)

    def test_instaladores_da_ficha_por_coleta(self):
        c1, _ = self.carregar(hostname='PC1', areas={'15': [{'Arquivo': 'a.exe', 'SHA256': 'aa'}]})
        c2, _ = self.carregar(hostname='PC1', id_equipamento='B' * 64, data='2026-11-12 11:00:00',
                             modo='Completa', areas={
            '16': [{'Arquivo': 'b.exe', 'SHA256': 'bb'}]})
        self.assertNotEqual(c1.id_coleta, c2.id_coleta)
        c1.situacao = c2.situacao = 'Usada'
        d = cc.dados_html(self.con, [c1, c2], {}, {})
        f1 = d['fichas'][c1.id_coleta]['instaladores']
        f2 = d['fichas'][c2.id_coleta]['instaladores']
        self.assertEqual([r['Arquivo'] for r in f1], ['a.exe'])
        self.assertEqual(f2, [])

    def test_area_16_fora_do_html(self):
        def completa(n):
            return [{'Local': 'C:', 'Arquivo': f'arq{i}.exe', 'Caminho': f'C:/d/arq{i}.exe',
                     'TamanhoBytes': str(i), 'SHA256': f'{i:064x}'} for i in range(n)]

        tamanhos = []
        for n in (10, 3000):
            ids = []
            for k in range(3):
                c, _ = self.carregar(hostname=f'N{n}K{k}', id_equipamento=f'{n:04d}{k:060d}',
                                     modo='Completa', areas={
                    '15': [{'Arquivo': 'setup.exe', 'SHA256': 'ee'}], '16': completa(n)})
                c.situacao = 'Usada'
                ids.append(c)
            d = cc.dados_html(self.con, ids, {}, {})
            for c in ids:
                self.assertEqual([r['Arquivo'] for r in d['fichas'][c.id_coleta]['instaladores']],
                                 ['setup.exe'])
            self.assertEqual([r['Arquivo'] for r in d['instaladores']], ['setup.exe'])
            tamanhos.append(len(self.gerar(d)))
        self.assertLess(abs(tamanhos[1] - tamanhos[0]), 2000)

    def test_colunas_da_ficha_sem_linhas(self):
        c, _ = self.carregar(hostname='PC1')
        c.situacao = 'Usada'
        d = cc.dados_html(self.con, [c], {}, {})
        self.assertEqual(d['fichas'][c.id_coleta]['hardware'], [])
        self.assertEqual(d['colunas']['ficha_hardware'],
                         list(cc.COLUNAS_COMUNS) + list(cc.AREAS['02'].colunas))
        self.assertEqual(d['colunas']['ficha_instaladores'],
                         list(cc.COLUNAS_COMUNS) + list(cc.AREAS['15'].colunas))
        for chave in ('volumes', 'rede'):
            self.assertIn('ficha_' + chave, d['colunas'])


if __name__ == '__main__':
    unittest.main()
