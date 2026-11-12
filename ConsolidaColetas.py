#!/usr/bin/env python3
"""ConsolidaColetas: consolida pacotes InventarioForense_*.zip em tabelas CSV e relatorios.

Somente biblioteca padrao (Python 3.10+).

Copyright 2026 Thiago Canozzo Lahr
Licenciado sob a Apache License 2.0 (veja o arquivo LICENSE).

Repositorio (ultima versao): https://github.com/tclahr/inventario-forense
"""
import csv
import hashlib
import html
import io
import json
import argparse
import logging
import os
import platform
import re
import shlex
import sqlite3
import sys
import tempfile
import time
import traceback
import zipfile
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Dict, Iterable, List, Mapping, NamedTuple, Optional, Sequence, Tuple

# === Fundacao ===

csv.field_size_limit(min(sys.maxsize, 2**31 - 1))

VERSAO = '1.0.0'
AUTOR = 'Thiago Canozzo Lahr'
EMAIL_AUTOR = 'thiago@peritoemti.com.br'
COLUNAS_COMUNS = ('Hostname', 'IdEquipamento', 'DataColeta')


class Area(NamedTuple):
    numero: str
    arquivo: str
    tabela: str
    colunas: "tuple[str, ...]"  # colunas do contrato, sem as comuns


AREAS = {
    '01': Area('01', '01_Resumo.csv', 'resumo', (
        'Etiqueta',
        'Setor',
        'ExecutadoPor',
        'Observacao',
        'Fabricante',
        'Modelo',
        'NumeroSerie',
        'SistemaOperacional',
        'Edicao',
        'Versao',
        'Build',
        'Arquitetura',
        'SOInstaladoEm',
        'SOAtualizadoEm',
        'UltimoBoot',
        'DominioOuGrupo',
        'ParteDeDominio',
        'UsuarioLogado',
        'Processador',
        'Nucleos',
        'Threads',
        'MemoriaGB',
        'DiscoTotalGB',
        'EnderecosIP',
        'EnderecosMAC',
        'AtivacaoWindows',
        'TotalSoftwaresInstalados',
        'TotalVestigios',
        'ExecutadoComoAdmin',
        'Modo',
        'FusoHorario',
        'DuracaoSegundos',
        'AreasComFalha',
        'AreasPuladas',
    )),
    '02': Area('02', '02_Hardware.csv', 'hardware', (
        'Tipo',
        'Descricao',
        'Fabricante',
        'Modelo',
        'NumeroSerie',
        'Capacidade',
        'Unidade',
        'Versao',
        'Detalhe',
    )),
    '03': Area('03', '03_Volumes.csv', 'volumes', (
        'Letra',
        'Rotulo',
        'SistemaArquivos',
        'TipoUnidade',
        'TotalGB',
        'LivreGB',
        'SerialVolume',
        'BitLocker',
    )),
    '04': Area('04', '04_Rede.csv', 'rede', (
        'Tipo',
        'Nome',
        'Descricao',
        'Fabricante',
        'MAC',
        'Fisico',
        'Habilitado',
        'Status',
        'VelocidadeMbps',
        'DHCP',
        'EnderecosIP',
        'Mascaras',
        'Gateway',
        'DNS',
        'ServidorDHCP',
    )),
    '05': Area('05', '05_Contas.csv', 'contas', (
        'Nome',
        'SID',
        'Habilitada',
        'UltimoLogon',
        'SenhaExpira',
        'SenhaAlteradaEm',
        'Descricao',
        'Fonte',
        'MembroAdministradores',
    )),
    '06': Area('06', '06_Perfis.csv', 'perfis', (
        'SID',
        'NomeResolvido',
        'Caminho',
        'UltimoUso',
        'ContaLocalCorrespondente',
        'ProvavelDominio',
        'Carregado',
        'Especial',
    )),
    '07': Area('07', '07_Software_Instalado.csv', 'software_instalado', (
        'Fonte',
        'Nome',
        'Versao',
        'Fabricante',
        'DataInstalacao',
        'LocalInstalacao',
        'Desinstalador',
        'Usuario',
        'ComponenteSistema',
        'ChaveRegistro',
    )),
    '08': Area('08', '08_Software_Vestigios.csv', 'software_vestigios', (
        'Fonte',
        'Item',
        'Caminho',
        'Fabricante',
        'Versao',
        'Data',
        'TipoData',
        'Usuario',
        'Detalhe',
    )),
    '09': Area('09', '09_Licencas.csv', 'licencas', (
        'Produto',
        'Descricao',
        'Canal',
        'EstadoLicenca',
        'ChaveParcial',
        'ServidorKMS',
        'PortaKMS',
        'Detalhe',
    )),
    '10': Area('10', '10_Servicos.csv', 'servicos', (
        'Nome',
        'NomeExibicao',
        'Estado',
        'TipoInicio',
        'Conta',
        'Executavel',
        'ExecutavelExiste',
    )),
    '11': Area('11', '11_Tarefas.csv', 'tarefas', (
        'Caminho',
        'Nome',
        'Autor',
        'Estado',
        'Acao',
        'Argumentos',
        'ExecutavelExiste',
        'UltimaExecucao',
        'ProximaExecucao',
        'CriadaEm',
    )),
    '12': Area('12', '12_Drivers.csv', 'drivers', (
        'Dispositivo',
        'Classe',
        'Fabricante',
        'Provedor',
        'Versao',
        'Data',
        'Inf',
        'Assinado',
        'Assinante',
    )),
    '13': Area('13', '13_Atualizacoes.csv', 'atualizacoes', (
        'Fonte',
        'Id',
        'Titulo',
        'InstaladoEm',
        'InstaladoPor',
        'Resultado',
    )),
    '14': Area('14', '14_Pastas_Programas.csv', 'pastas_programas', (
        'Raiz',
        'Usuario',
        'Pasta',
        'Caminho',
        'CriadoEm',
        'ModificadoEm',
    )),
    '15': Area('15', '15_Arquivos_Instaladores.csv', 'arquivos_instaladores', (
        'Local',
        'Usuario',
        'Caminho',
        'Arquivo',
        'Extensao',
        'TamanhoBytes',
        'CriadoEm',
        'ModificadoEm',
        'ProductName',
        'CompanyName',
        'ProductVersion',
        'SHA256',
    )),
    '16': Area('16', '16_Arquivos_Completa.csv', 'arquivos_completa', (
        'Local',
        'Usuario',
        'Caminho',
        'Arquivo',
        'Extensao',
        'TamanhoBytes',
        'CriadoEm',
        'ModificadoEm',
        'ProductName',
        'CompanyName',
        'ProductVersion',
        'SHA256',
    )),
}


class ErroCsv(Exception):
    pass


def ler_csv(dados: bytes):
    """Le um CSV do coletor: devolve (cabecalho, lista de dicts)."""
    try:
        texto = dados.decode('utf-8-sig')
    except UnicodeDecodeError as e:
        raise ErroCsv(f'UTF-8 invalido: {e}') from e
    try:
        linhas = list(csv.reader(io.StringIO(texto, newline=''), delimiter=';', quotechar='"'))
    except csv.Error as e:
        raise ErroCsv(f'CSV malformado: {e}') from e
    if not linhas or not any(c.strip() for c in linhas[0]):
        raise ErroCsv('cabecalho vazio')
    cab = linhas[0]
    regs = []
    for i, campos in enumerate(linhas[1:], start=2):
        if not campos:
            continue
        if len(campos) > len(cab):
            raise ErroCsv(f'linha {i} tem {len(campos)} campos; cabecalho tem {len(cab)}')
        campos = campos + [''] * (len(cab) - len(campos))
        regs.append(dict(zip(cab, campos)))
    return cab, regs


def formatar_valor(v: object) -> str:
    if v is None:
        return ''
    if isinstance(v, bool):
        return 'Sim' if v else 'Nao'
    if isinstance(v, float):
        return f'{v:.10g}'.replace('.', ',')
    return str(v)


def escrever_csv(caminho: Path, colunas: Sequence[str], linhas: Iterable[Mapping[str, object]]) -> int:
    caminho = Path(caminho)
    caminho.parent.mkdir(parents=True, exist_ok=True)
    n = 0
    with open(caminho, 'w', encoding='utf-8-sig', newline='') as f:
        w = csv.writer(f, delimiter=';', quotechar='"', quoting=csv.QUOTE_ALL, lineterminator='\r\n')
        w.writerow(colunas)
        for linha in linhas:
            w.writerow([formatar_valor(linha.get(c, '')) for c in colunas])
            n += 1
    return n


def sha256_bytes(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def sha256_arquivo(caminho: Path) -> str:
    h = hashlib.sha256()
    with open(caminho, 'rb') as f:
        for bloco in iter(lambda: f.read(1 << 20), b''):
            h.update(bloco)
    return h.hexdigest()


# === Verificacao ===

@dataclass
class Verificacao:
    arquivo: Path
    id_coleta: str
    hash_zip: str = ''
    hash_confere: Optional[bool] = None
    manifesto_confere: Optional[bool] = None
    raiz: str = ''
    entradas: Dict[str, str] = field(default_factory=dict)
    erro_fatal: str = ''
    motivos: List[str] = field(default_factory=list)


_RE_HEX64 = re.compile(r'^[0-9a-fA-F]{64}$')


def _hash_confere_sidecar(caminho: Path, hash_zip: str) -> Optional[bool]:
    lado = Path(str(caminho) + '.sha256')
    if not lado.is_file():
        return None
    try:
        texto = lado.read_text(encoding='utf-8-sig', errors='replace')
    except OSError:
        return False
    linhas = [l for l in texto.splitlines() if l.strip()]
    if not linhas:
        return False
    partes = linhas[0].strip().split(None, 1)
    if not _RE_HEX64.match(partes[0]):
        return False
    if len(partes) > 1:
        nome = partes[1].strip().lstrip('*').replace('\\', '/').split('/')[-1]
        if nome != caminho.name:
            return False
    return partes[0].lower() == hash_zip


def _ler_manifesto(dados: bytes) -> Dict[str, str]:
    saida: Dict[str, str] = {}
    for linha in dados.decode('utf-8-sig', errors='replace').splitlines():
        linha = linha.strip()
        if len(linha) < 66 or not _RE_HEX64.match(linha[:64]):
            continue
        nome = linha[64:].lstrip(' \t').lstrip('*').replace('\\', '/')
        if nome:
            saida[nome] = linha[:64].lower()
    return saida


def verificar_zip(caminho: Path) -> Verificacao:
    caminho = Path(caminho)
    v = Verificacao(arquivo=caminho, id_coleta=caminho.name[:-4] if caminho.name.lower().endswith('.zip') else caminho.name)
    try:
        v.hash_zip = sha256_arquivo(caminho)
    except Exception as e:
        v.erro_fatal = f'ZIP ilegivel: {e}'
        return v
    v.hash_confere = _hash_confere_sidecar(caminho, v.hash_zip)
    if v.hash_confere is None:
        v.motivos.append('Sem arquivo .zip.sha256')
    elif v.hash_confere is False:
        v.motivos.append('Hash do ZIP diverge do .zip.sha256')
    try:
        zf = zipfile.ZipFile(caminho)
    except Exception as e:
        v.erro_fatal = f'ZIP ilegivel: {e}'
        return v
    with zf:
        try:
            reais: Dict[str, str] = {}
            duplicadas: List[str] = []
            for info in zf.infolist():
                norm = info.filename.replace('\\', '/')
                if norm.endswith('/'):
                    continue
                if norm in reais:
                    duplicadas.append(norm)
                reais[norm] = info.filename
            raizes = {n.split('/', 1)[0] for n in reais if '/' in n}
            if not reais or len(raizes) != 1 or any('/' not in n for n in reais):
                v.erro_fatal = 'ZIP sem pasta raiz unica'
                return v
            v.raiz = next(iter(raizes))
            prefixo = v.raiz + '/'
            if duplicadas:
                v.erro_fatal = f'ZIP com entrada duplicada: {sorted(duplicadas)[0][len(prefixo):]}'
                return v
            v.entradas = {n[len(prefixo):]: real for n, real in reais.items()}
            esperado = v.entradas.get('SHA256SUMS.txt')
            if esperado is None:
                v.motivos.append('Sem SHA256SUMS.txt')
                return v
            manifesto = _ler_manifesto(zf.read(esperado))
            ok = True
            for rel, h in sorted(manifesto.items()):
                real = v.entradas.get(rel)
                if real is None:
                    v.motivos.append(f'Manifesto: Ausente: {rel}')
                    ok = False
                    continue
                dig = hashlib.sha256()
                with zf.open(real) as f:
                    for bloco in iter(lambda: f.read(1 << 20), b''):
                        dig.update(bloco)
                if dig.hexdigest() != h:
                    v.motivos.append(f'Manifesto: Hash: {rel}')
                    ok = False
            for rel in sorted(v.entradas):
                if rel != 'SHA256SUMS.txt' and rel not in manifesto:
                    v.motivos.append(f'Manifesto: Extra: {rel}')
                    ok = False
            v.manifesto_confere = ok
        except Exception as e:
            # zlib.error, CRC, E/S ou qualquer outra falha de leitura: a coleta e rejeitada.
            v.erro_fatal = f'ZIP ilegivel: {e}'
    return v


def descobrir_zips(entrada: Path) -> List[Path]:
    """InventarioForense_*.zip da pasta (nao recursivo), so arquivos regulares, em ordem de nome."""
    raiz = Path(entrada)
    zips = [p for p in raiz.glob('InventarioForense_*.zip') if p.is_file()]
    return sorted(zips, key=lambda p: p.name)


def situacao_inicial(v: Verificacao, aceitar_nao_verificadas: bool) -> Tuple[str, str]:
    if v.erro_fatal:
        return 'Rejeitada', v.erro_fatal
    if not v.motivos:
        return 'Verificada', ''
    motivo = '; '.join(v.motivos)
    if aceitar_nao_verificadas:
        return 'NaoVerificada', motivo
    return 'Rejeitada', motivo


# === Base ===

def q(nome: str) -> str:
    return '"' + nome.replace('"', '""') + '"'


COLUNAS_COLETAS = ('IdColeta', 'Arquivo', 'Hostname', 'IdEquipamento', 'DataColeta', 'Modo',
                    'ExecutadoComoAdmin', 'HashZip', 'HashConfere', 'ManifestoConfere',
                    'Situacao', 'SubstituidaPor', 'MotivoSelecao', 'Motivo')


def abrir_base(caminho: Path) -> sqlite3.Connection:
    con = sqlite3.connect(str(caminho))
    con.execute('PRAGMA journal_mode=MEMORY')
    con.execute('PRAGMA synchronous=OFF')
    for area in AREAS.values():
        cols = ['IdColeta'] + list(COLUNAS_COMUNS) + list(area.colunas)
        con.execute(f"CREATE TABLE {q(area.tabela)} ({', '.join(q(c) + ' TEXT' for c in cols)})")
    defs = ', '.join(q(c) + (' TEXT PRIMARY KEY' if c == 'IdColeta' else ' TEXT')
                     for c in COLUNAS_COLETAS)
    con.execute(f'CREATE TABLE coletas ({defs})')
    return con


def _colunas_tabela(area: Area) -> List[str]:
    return list(COLUNAS_COMUNS) + list(area.colunas)


def inserir_linhas(con: sqlite3.Connection, area: Area, id_coleta: str,
                   linhas: Iterable[Mapping[str, str]]) -> int:
    cols = _colunas_tabela(area)
    sql = (f"INSERT INTO {q(area.tabela)} ({', '.join(q(c) for c in ['IdColeta'] + cols)}) "
           f"VALUES ({', '.join('?' * (len(cols) + 1))})")
    dados = [[id_coleta] + [l.get(c, '') for c in cols] for l in linhas]
    con.executemany(sql, dados)
    return len(dados)


def linhas_area(con: sqlite3.Connection, numero: str, id_coleta: str) -> List[Dict[str, str]]:
    area = AREAS[numero]
    cols = _colunas_tabela(area)
    cur = con.execute(f"SELECT {', '.join(q(c) for c in cols)} FROM {q(area.tabela)} "
                      f"WHERE IdColeta = ? ORDER BY rowid", (id_coleta,))
    return [dict(zip(cols, r)) for r in cur]


def criar_indices_e_views(con: sqlite3.Connection) -> None:
    for area in AREAS.values():
        t = area.tabela
        for c in ('IdColeta', 'IdEquipamento'):
            con.execute(f"CREATE INDEX {q('ix_' + t + '_' + c)} ON {q(t)} ({q(c)})")
        if t in ('arquivos_instaladores', 'arquivos_completa'):
            con.execute(f"CREATE INDEX {q('ix_' + t + '_SHA256')} ON {q(t)} ({q('SHA256')})")
        con.execute(f"CREATE VIEW {q('v_' + t)} AS SELECT * FROM {q(t)} WHERE IdColeta IN "
                    f"(SELECT IdColeta FROM coletas WHERE Situacao IN ('Usada','NaoVerificada'))")
    con.commit()


# === Carga ===

log = logging.getLogger('consolida')


@dataclass
class Alerta:
    tipo: str
    id_coleta: str
    hostname: str
    id_equipamento: str
    mensagem: str


@dataclass
class Coleta:
    verificacao: Verificacao
    situacao: str
    motivo: str
    resumo: Dict[str, str]
    areas_carregadas: List[str]
    substituida_por: str = ''
    motivo_selecao: str = ''

    @property
    def id_coleta(self) -> str:
        return self.verificacao.id_coleta

    @property
    def hostname(self) -> str:
        return self.resumo.get('Hostname', '') or _hostname_do_nome(self.verificacao.id_coleta)

    @property
    def id_equipamento(self) -> str:
        return self.resumo.get('IdEquipamento', '')

    @property
    def data_coleta(self) -> str:
        return self.resumo.get('DataColeta', '')

    @property
    def modo(self) -> str:
        return self.resumo.get('Modo', '')

    @property
    def admin(self) -> bool:
        return self.resumo.get('ExecutadoComoAdmin', '') == 'Sim'

    @property
    def verificada(self) -> bool:
        return self.situacao != 'NaoVerificada'


def _hostname_do_nome(id_coleta: str) -> str:
    prefixo = 'InventarioForense_'
    if id_coleta.startswith(prefixo):
        return id_coleta[len(prefixo):].split('_', 1)[0]
    return ''


def _itens_lista(texto: str) -> List[str]:
    return [i.strip() for i in (texto or '').split(',') if i.strip()]


def _rejeitar(v: Verificacao, motivo: str) -> Tuple[Coleta, List[Alerta]]:
    c = Coleta(v, 'Rejeitada', motivo, {}, [])
    return c, [Alerta('ColetaRejeitada', c.id_coleta, c.hostname, '', motivo)]


class _ErroZip(Exception):
    """Falha ao ler ou descompactar uma entrada do ZIP."""


def carregar_coleta(con: sqlite3.Connection, v: Verificacao, situacao: str,
                    motivo: str) -> Tuple[Coleta, List[Alerta]]:
    """Carrega uma coleta dentro de um SAVEPOINT: se ela falhar, so as linhas dela saem."""
    if situacao == 'Rejeitada':
        return _rejeitar(v, motivo)
    con.execute('SAVEPOINT coleta')
    try:
        c, alertas = _carregar_coleta(con, v, situacao, motivo)
    except _ErroZip as e:
        c, alertas = _rejeitar(v, f'ZIP ilegivel: {e}')
    except Exception as e:
        log.exception('Erro ao carregar %s', v.id_coleta)
        c, alertas = _rejeitar(v, f'Erro ao carregar: {e}')
    try:
        if c.situacao == 'Rejeitada':
            con.execute('ROLLBACK TO coleta')
        con.execute('RELEASE coleta')
    except sqlite3.Error:
        # O SQLite pode ter desfeito a transacao sozinho (ex.: disco cheio); as coletas
        # anteriores ja foram gravadas no RELEASE delas.
        log.exception('Erro ao fechar o SAVEPOINT de %s', v.id_coleta)
        if con.in_transaction:
            con.rollback()
    return c, alertas


def _carregar_coleta(con: sqlite3.Connection, v: Verificacao, situacao: str,
                     motivo: str) -> Tuple[Coleta, List[Alerta]]:
    try:
        zf = zipfile.ZipFile(v.arquivo)
    except Exception as e:
        raise _ErroZip(str(e)) from e
    with zf:
        def ler(numero: str):
            rel = 'csv/' + AREAS[numero].arquivo
            if rel not in v.entradas:
                return None
            try:
                dados = zf.read(v.entradas[rel])
            except Exception as e:
                raise _ErroZip(f'{rel}: {e}') from e
            return ler_csv(dados)

        if 'csv/' + AREAS['01'].arquivo not in v.entradas:
            return _rejeitar(v, 'Resumo ausente')
        try:
            cab_resumo, linhas_resumo = ler('01')
        except ErroCsv as e:
            return _rejeitar(v, f'Resumo ilegivel: {e}')
        if len(linhas_resumo) != 1:
            return _rejeitar(v, f'Resumo com {len(linhas_resumo)} linhas')
        resumo = dict(linhas_resumo[0])
        if not resumo.get('Hostname'):
            resumo['Hostname'] = _hostname_do_nome(v.id_coleta)
        coleta = Coleta(v, situacao, motivo, resumo, [])
        alertas: List[Alerta] = []

        def alerta(tipo: str, msg: str) -> None:
            alertas.append(Alerta(tipo, coleta.id_coleta, coleta.hostname,
                                  coleta.id_equipamento, msg))

        if situacao == 'NaoVerificada':
            alerta('ColetaNaoVerificada', motivo)
        if not coleta.admin:
            alerta('SemAdmin', 'Coleta sem administrador: vestigios incompletos')
        for item in _itens_lista(resumo.get('AreasComFalha', '')):
            alerta('AreaComFalha', item)
        for item in _itens_lista(resumo.get('AreasPuladas', '')):
            alerta('AreaPulada', item)
        justificadas = _itens_lista(resumo.get('AreasComFalha', '')) + \
            _itens_lista(resumo.get('AreasPuladas', ''))

        for numero, area in AREAS.items():
            if numero == '01':
                dados = (cab_resumo, linhas_resumo)
            else:
                rel = 'csv/' + area.arquivo
                if rel not in v.entradas:
                    if numero == '16' and coleta.modo != 'Completa':
                        continue
                    if any(i.startswith(numero + ' ') for i in justificadas):
                        continue
                    alerta('AreaAusente', f'{area.arquivo} ausente')
                    continue
                try:
                    dados = ler(numero)
                except ErroCsv as e:
                    alerta('AreaAusente', f'{area.arquivo}: {e}')
                    continue
            cab, linhas = dados
            esperadas = list(COLUNAS_COMUNS) + list(area.colunas)
            faltam = [c for c in esperadas if c not in cab]
            extras = [c for c in cab if c not in esperadas]
            if faltam:
                alerta('ColunaAusente', f"{area.arquivo}: colunas ausentes: {', '.join(faltam)}")
            if extras:
                log.info('%s: %s: colunas extras ignoradas: %s', v.id_coleta, area.arquivo,
                         ', '.join(extras))
            inserir_linhas(con, area, v.id_coleta, linhas)
            coleta.areas_carregadas.append(numero)
    return coleta, alertas


# === Selecao ===

def _chave_vencedor(c: Coleta):
    return (c.modo != 'Completa', not c.admin, not c.verificada)


def selecionar_coletas(coletas: List[Coleta]) -> List[Alerta]:
    alertas: List[Alerta] = []
    grupos: Dict[str, List[Coleta]] = {}
    for c in coletas:
        if c.situacao not in ('Verificada', 'NaoVerificada'):
            continue
        # Sem IdEquipamento nao ha como agrupar: cada coleta fica isolada.
        grupos.setdefault(c.id_equipamento or ('?' + c.id_coleta), []).append(c)
    usadas: List[Coleta] = []
    for grupo in grupos.values():
        ordem = sorted(grupo, key=lambda c: c.id_coleta)
        ordem.sort(key=lambda c: c.data_coleta, reverse=True)
        ordem.sort(key=_chave_vencedor)
        venc = ordem[0]
        termos = [venc.modo or 'Padrao', 'admin' if venc.admin else 'sem admin']
        if len(grupo) == 1:
            termos.append('unica coleta')
        elif venc.data_coleta == max(c.data_coleta for c in grupo):
            termos.append('mais recente')
        venc.motivo_selecao = '; '.join(termos)
        if venc.situacao == 'Verificada':
            venc.situacao = 'Usada'
        usadas.append(venc)
        for perd in ordem[1:]:
            perd.situacao = 'Substituida'
            perd.substituida_por = venc.id_coleta
            perd.motivo_selecao = f'Substituida por {venc.id_coleta}'
            alertas.append(Alerta('Substituida', perd.id_coleta, perd.hostname,
                                  perd.id_equipamento, perd.motivo_selecao))
    por_host: Dict[str, List[str]] = {}
    for c in usadas:
        por_host.setdefault(c.hostname, []).append(c.id_equipamento)
    for host in sorted(por_host):
        ids = sorted(set(i for i in por_host[host] if i))
        if len(ids) > 1:
            alertas.append(Alerta('HostnameRepetido', '', host, '',
                                  f"Hostname {host} com {len(ids)} IdEquipamento distintos: "
                                  f"{', '.join(i[:8] for i in ids)}"))
    return alertas


def _sim_nao(v: Optional[bool]) -> str:
    return '' if v is None else ('Sim' if v else 'Nao')


def linhas_coletas(coletas: List[Coleta]) -> List[dict]:
    linhas = []
    for c in coletas:
        v = c.verificacao
        linhas.append({
            'IdColeta': c.id_coleta, 'Arquivo': v.arquivo.name, 'Hostname': c.hostname,
            'IdEquipamento': c.id_equipamento, 'DataColeta': c.data_coleta, 'Modo': c.modo,
            'ExecutadoComoAdmin': c.resumo.get('ExecutadoComoAdmin', ''), 'HashZip': v.hash_zip,
            'HashConfere': _sim_nao(v.hash_confere), 'ManifestoConfere': _sim_nao(v.manifesto_confere),
            'Situacao': c.situacao, 'SubstituidaPor': c.substituida_por,
            'MotivoSelecao': c.motivo_selecao, 'Motivo': c.motivo,
        })
    return linhas


def gravar_coletas(con: sqlite3.Connection, coletas: List[Coleta]) -> None:
    cols = ', '.join(q(c) for c in COLUNAS_COLETAS)
    sql = f"INSERT INTO coletas ({cols}) VALUES ({', '.join('?' * len(COLUNAS_COLETAS))})"
    con.executemany(sql, [tuple(l[c] for c in COLUNAS_COLETAS) for l in linhas_coletas(coletas)])
    con.commit()


# === Mapa ===

_RE_IDIOMA = re.compile(r'\s*-\s*[A-Za-z]{2}-[A-Za-z]{2}\s*$')
_RE_ARQ_PAREN = re.compile(r'\(\s*(?:x64|x86|amd64|arm64|64-bit|32-bit)\s*\)', re.IGNORECASE)
# Parenteses so com tokens de arquitetura e/ou idioma: "(x64 pt-BR)", "(pt-BR)".
_RE_ARQ_IDIOMA_PAREN = re.compile(
    r'\(\s*(?:(?:x64|x86|amd64|arm64|64-bit|32-bit|[A-Za-z]{2}-[A-Za-z]{2})(?:[\s,]+|(?=\s*\))))+\s*\)',
    re.IGNORECASE)
_RE_ARQ_TOKEN = re.compile(r'(?<![\w.-])(?:x64|x86|amd64|64-bit|32-bit)(?![\w-])', re.IGNORECASE)
_RE_VERSAO = re.compile(r'\bv?\d+(?:\.\d+)+[\w.-]*', re.IGNORECASE)
_RE_SEPARADORES = re.compile(r'(?:\s+-)+(?=\s+-\s|\s*$)')


def normalizar_nome(nome: str) -> str:
    r = _RE_IDIOMA.sub('', nome)
    r = _RE_ARQ_IDIOMA_PAREN.sub(' ', r)
    r = _RE_ARQ_PAREN.sub(' ', r)
    r = _RE_ARQ_TOKEN.sub(' ', r)
    r = _RE_VERSAO.sub(' ', r)
    r = re.sub(r'\(\s*\)', ' ', r)
    r = re.sub(r'\s+', ' ', r)
    r = _RE_SEPARADORES.sub('', r)
    r = r.strip(' -–_,.')
    return r or nome


class ErroMapa(Exception):
    pass


@dataclass
class RegraMapa:
    linha: int
    padrao: str
    produto: str
    fabricante: str
    categoria: str
    ignorar: bool


@dataclass
class Classificacao:
    produto: str
    fabricante: str
    categoria: str
    ignorar: bool
    mapeado: bool
    regra: Optional[int]


_CABECALHO_MAPA = ['Padrao', 'Produto', 'Fabricante', 'Categoria', 'Ignorar']

_REGRAS_EMBUTIDAS = [
    # Runtimes e frameworks (antes de Microsoft.Windows*, que pegaria WindowsAppRuntime).
    ('Microsoft.VCLibs*', 'Runtime'),
    ('Microsoft.NET.*', 'Runtime'),
    ('Microsoft.WindowsAppRuntime*', 'Runtime'),
    ('Microsoft.UI.Xaml*', 'Runtime'),
    ('Microsoft.WidgetsPlatformRuntime*', 'Runtime'),
    ('Microsoft.*Extension*', 'Runtime'),
    ('Microsoft Visual C++ *', 'Runtime'),
    ('Microsoft .NET *', 'Runtime'),
    ('Microsoft Edge WebView2*', 'Runtime'),
    ('Microsoft GameInput*', 'Runtime'),
    # Componentes e pacotes Appx que acompanham o Windows.
    ('Microsoft.Windows*', 'Sistema'),
    ('MicrosoftWindows.*', 'Sistema'),
    ('Windows.*', 'Sistema'),
    ('Microsoft Windows Application Compatibility*', 'Sistema'),
    ('Microsoft Update Health Tools*', 'Sistema'),
    ('Microsoft.Xbox*', 'Sistema'),
    ('Microsoft.AAD.BrokerPlugin*', 'Sistema'),
    ('Microsoft.AccountsControl*', 'Sistema'),
    ('Microsoft.AIFabric*', 'Sistema'),
    ('Microsoft.LockApp*', 'Sistema'),
    ('Microsoft.Services.Store*', 'Sistema'),
    ('Microsoft.DesktopAppInstaller*', 'Sistema'),
    ('Microsoft.StorePurchaseApp*', 'Sistema'),
    ('Microsoft.Win32WebViewHost*', 'Sistema'),
    ('Microsoft.ECApp*', 'Sistema'),
    ('Microsoft.CredDialogHost*', 'Sistema'),
    ('Microsoft.AsyncTextService*', 'Sistema'),
    ('Microsoft.BioEnrollment*', 'Sistema'),
    ('Microsoft.Ink.*', 'Sistema'),
    ('Microsoft.ApplicationCompatibilityEnhancements*', 'Sistema'),
    ('Microsoft.MicrosoftEdgeDevToolsClient*', 'Sistema'),
    ('Microsoft.Winget.*', 'Sistema'),
    ('Microsoft.GetHelp*', 'Sistema'),
    ('Microsoft.BingSearch*', 'Sistema'),
    ('Microsoft.SecHealthUI*', 'Sistema'),
    ('Microsoft.LanguageExperiencePack*', 'Sistema'),
    # Drivers e utilitarios de fabricantes de hardware.
    ('re:^NVIDIA( |$)', 'Driver'),
    ('NVIDIACorp.*', 'Driver'),
    ('Realtek*', 'Driver'),
    (r're:^Intel(\(R\)|®)?( |$)', 'Driver'),
    ('AppUp.*', 'Driver'),
    ('Dolby*', 'Driver'),
    ('Synaptics*', 'Driver'),
    # Pastas estruturais do perfil e do Windows (nomes em ingles e em portugues).
    *((p, 'Sistema') for p in (
        'Application Data', 'Dados de Aplicativos', 'Local Settings', 'Configurações Locais',
        'My Documents', 'Meus Documentos', 'Documents', 'Documentos', 'Desktop',
        'Área de Trabalho', 'Templates', 'Modelos', 'Start Menu', 'Menu Iniciar', 'Programs',
        'Programas', 'Cookies', 'Recent', 'SendTo', 'NetHood', 'Ambiente de Rede', 'PrintHood',
        'Ambiente de Impressão', 'History', 'Histórico', 'Temporary Internet Files',
        'Favorites', 'Favoritos', 'Arquivos Comuns', 'System', 'Sistema', 'Publishers',
        'PlaceholderTileLogoFolder', 'VirtualStore', 'SoftwareDistribution', 'USOShared',
        'USOPrivate', 'D3DSCache', 'ssh', 'WindowsPowerShell', 'WindowsPerformanceRecorder',
        'Whesvc', 'IdentityService', 'regid.*', 'Packages', 'ConnectedDevicesPlatform',
        'PeerDistRepub', 'Comms', 'CrashDumps', 'Temp')),
    # Chaves estruturais de HKLM\SOFTWARE (o candidato e "<Fabricante> <Item>").
    ('re:^AppDataLow( |$)', 'Sistema'),
    ('re:^MozillaPlugins( |$)', 'Sistema'),
    ('re:^OEM( |$)', 'Sistema'),
    ('re:^SyncIntegrationClients( |$)', 'Sistema'),
    ('re:^ChangeTracker( |$)', 'Sistema'),
    (r're:^OpenSSH\s', 'Sistema'),
    ('re:^Netscape( |$)', 'Sistema'),
    (r're:^Chromium\s', 'Sistema'),
]

MAPA_EMBUTIDO = '\n'.join(
    [';'.join(_CABECALHO_MAPA)] + [f'{p};;;{c};Sim' for p, c in _REGRAS_EMBUTIDAS]) + '\n'


def _compilar_padrao(padrao: str):
    """Retorna (regex, usa_search)."""
    if padrao.lower().startswith('re:'):
        return re.compile(padrao[3:], re.IGNORECASE), True
    rx = re.escape(padrao).replace(r'\*', '.*').replace(r'\?', '.')
    return re.compile('^' + rx + '$', re.IGNORECASE | re.DOTALL), False


@dataclass
class Mapa:
    regras: List[RegraMapa]
    origem: str
    sha256: str = ''
    codificacao: str = 'utf-8'
    _compiladas: list = field(default_factory=list, repr=False)
    _cache: dict = field(default_factory=dict, repr=False)

    @classmethod
    def de_texto(cls, texto: str, origem: str) -> 'Mapa':
        nome = Path(origem).name
        if texto.startswith('﻿'):
            texto = texto[1:]
        leitor = csv.reader(io.StringIO(texto, newline=''), delimiter=';')
        regras: List[RegraMapa] = []
        compiladas = []
        cabecalho_ok = False
        for campos in leitor:
            n = leitor.line_num
            if not cabecalho_ok:
                if campos != _CABECALHO_MAPA:
                    raise ErroMapa(f'Mapa {nome}, linha {n}: cabecalho deve ser '
                                   f'{";".join(_CABECALHO_MAPA)}')
                cabecalho_ok = True
                continue
            if not campos or all(not c.strip() for c in campos):
                continue
            if len(campos) != 5:
                raise ErroMapa(f'Mapa {nome}, linha {n}: esperadas 5 colunas, '
                               f'encontradas {len(campos)}')
            padrao, produto, fabricante, categoria, ign = [c.strip() for c in campos]
            if not padrao:
                raise ErroMapa(f'Mapa {nome}, linha {n}: Padrao vazio')
            if padrao.lower().startswith('re:') and not padrao[3:].strip():
                raise ErroMapa(f'Mapa {nome}, linha {n}: expressao regular vazia')
            if ign.casefold() not in ('', 'sim', 'nao'):
                raise ErroMapa(f'Mapa {nome}, linha {n}: Ignorar deve ser Sim ou Nao')
            try:
                compiladas.append(_compilar_padrao(padrao))
            except re.error as e:
                raise ErroMapa(f'Mapa {nome}, linha {n}: expressao regular invalida: {e}')
            regras.append(RegraMapa(n, padrao, produto, fabricante, categoria,
                                    ign.casefold() == 'sim'))
        if not cabecalho_ok:
            raise ErroMapa(f'Mapa {nome}, linha 1: arquivo vazio, cabecalho ausente')
        m = cls(regras, origem, hashlib.sha256(texto.encode('utf-8')).hexdigest(), 'utf-8')
        m._compiladas = compiladas
        return m

    @classmethod
    def carregar(cls, caminho: Optional[Path], pasta_script: Path) -> 'Mapa':
        if caminho is None:
            padrao = Path(pasta_script) / 'MapaSoftwares.csv'
            if not padrao.exists():
                return cls.de_texto(MAPA_EMBUTIDO, 'embutido')
            caminho = padrao
        dados = Path(caminho).read_bytes()
        try:
            texto, cod = dados.decode('utf-8-sig'), 'utf-8-sig'
        except UnicodeDecodeError:
            try:
                texto, cod = dados.decode('cp1252'), 'cp1252'
            except UnicodeDecodeError:
                raise ErroMapa(f'Mapa {Path(caminho).name}: codificacao nao reconhecida '
                               f'(esperado UTF-8 ou cp1252)')
        m = cls.de_texto(texto, str(caminho))
        m.sha256 = hashlib.sha256(dados).hexdigest()
        m.codificacao = cod
        return m

    def _achar(self, texto: str) -> Optional[int]:
        for i, (rx, busca) in enumerate(self._compiladas):
            if (rx.search(texto) if busca else rx.match(texto)):
                return i
        return None

    def classificar(self, nome: str, fabricante: str = '') -> Classificacao:
        chave = (nome, fabricante)
        if chave in self._cache:
            return self._cache[chave]
        norm = normalizar_nome(nome)
        i = self._achar(nome)
        if i is None:
            i = self._achar(norm)
        if i is None:
            res = Classificacao(norm, fabricante, '', False, False, None)
        else:
            r = self.regras[i]
            res = Classificacao(r.produto or norm, r.fabricante or fabricante, r.categoria,
                                r.ignorar, True, r.linha)
        self._cache[chave] = res
        return res


def gerar_mapa(destino: Path) -> None:
    destino = Path(destino)
    if destino.exists():
        raise FileExistsError(str(destino))
    with open(destino, 'xb') as f:
        f.write(b'\xef\xbb\xbf' + MAPA_EMBUTIDO.replace('\n', '\r\n').encode('utf-8'))


# === Softwares ===

COLUNAS_SPM = ('IdColeta', 'Hostname', 'IdEquipamento', 'Produto', 'Fabricante', 'Categoria',
               'Ignorar', 'Versoes', 'NomesOriginais', 'Fontes', 'DatasInstalacao', 'Usuarios',
               'ComponenteSistema')
COLUNAS_CATALOGO = ('Produto', 'Fabricante', 'Categoria', 'Ignorar', 'Maquinas', 'Versoes',
                    'NomesOriginais', 'Fontes')
COLUNAS_NAO_MAPEADOS = ('Padrao', 'Produto', 'Fabricante', 'Categoria', 'Ignorar', 'Maquinas',
                        'NomesOriginais', 'Origem')
_SEP = ' | '


def _unicos(valores: Iterable[str]) -> List[str]:
    return sorted({v for v in valores if v})


def _juntar(valores: Iterable[str]) -> str:
    return _SEP.join(_unicos(valores))


def _primeiro(valores: Iterable[str]) -> str:
    return next((v for v in valores if v), '')


def softwares_da_coleta(con: sqlite3.Connection, coleta: Coleta, mapa: Mapa) -> List[dict]:
    grupos: Dict[str, List[Tuple[Dict[str, str], Classificacao]]] = {}
    for l in linhas_area(con, '07', coleta.id_coleta):
        nome = l.get('Nome', '')
        if not nome:
            continue
        cl = mapa.classificar(nome, l.get('Fabricante', ''))
        grupos.setdefault(cl.produto.casefold(), []).append((l, cl))
    saida = []
    for itens in grupos.values():
        mapeadas = [cl for _, cl in itens if cl.mapeado]
        ref = mapeadas[0] if mapeadas else itens[0][1]
        linhas = [l for l, _ in itens]
        categoria = ref.categoria
        if not mapeadas and any(l.get('Fonte') == 'Appx' for l in linhas):
            categoria = 'Appx'
        saida.append({
            'IdColeta': coleta.id_coleta,
            'Hostname': coleta.hostname,
            'IdEquipamento': coleta.id_equipamento,
            'Produto': ref.produto,
            'Fabricante': ref.fabricante or _primeiro(l.get('Fabricante', '') for l in linhas),
            'Categoria': categoria,
            'Ignorar': any(cl.ignorar for cl in mapeadas),
            'Versoes': _juntar(l.get('Versao', '') for l in linhas),
            'NomesOriginais': _juntar(l.get('Nome', '') for l in linhas),
            'Fontes': _juntar(l.get('Fonte', '') for l in linhas),
            'DatasInstalacao': _juntar(l.get('DataInstalacao', '') for l in linhas),
            'Usuarios': _juntar(l.get('Usuario', '') for l in linhas),
            'ComponenteSistema': ('Sim' if any(l.get('ComponenteSistema') == 'Sim'
                                               for l in linhas) else 'Nao'),
            '_Mapeado': bool(mapeadas),
        })
    saida.sort(key=lambda r: r['Produto'].casefold())
    return saida


def _agrupar_produtos(spm: List[dict]) -> Dict[str, List[dict]]:
    g: Dict[str, List[dict]] = {}
    for r in spm:
        g.setdefault(r['Produto'].casefold(), []).append(r)
    return g


def _uniao(rows: List[dict], campo: str) -> str:
    return _juntar(v for r in rows for v in r[campo].split(_SEP))


def catalogo(spm: List[dict]) -> List[dict]:
    saida = []
    for rows in _agrupar_produtos(spm).values():
        saida.append({
            'Produto': rows[0]['Produto'],
            'Fabricante': _primeiro(r['Fabricante'] for r in rows),
            'Categoria': _primeiro(r['Categoria'] for r in rows),
            'Ignorar': any(r['Ignorar'] for r in rows),
            'Maquinas': len({r['IdColeta'] for r in rows}),
            'Versoes': _uniao(rows, 'Versoes'),
            'NomesOriginais': _uniao(rows, 'NomesOriginais'),
            'Fontes': _uniao(rows, 'Fontes'),
        })
    saida.sort(key=lambda r: (-r['Maquinas'], r['Produto'].casefold()))
    return saida


def matriz(spm: List[dict], coletas: List[Coleta]) -> Tuple[List[str], List[dict]]:
    ordem = sorted(coletas, key=lambda c: (c.hostname.casefold(), c.id_equipamento))
    rotulos = {c.id_coleta: f'{c.hostname} ({c.id_equipamento[:8]})' for c in ordem}
    for _ in range(2):
        cont: Dict[str, int] = {}
        for rot in rotulos.values():
            cont[rot] = cont.get(rot, 0) + 1
        for c in ordem:
            if cont[rotulos[c.id_coleta]] > 1:
                if _ == 0:
                    rotulos[c.id_coleta] = f'{c.hostname} ({c.id_equipamento})'
                else:
                    rotulos[c.id_coleta] += f' [{c.id_coleta}]'
    colunas = ['Produto', 'Fabricante', 'Categoria'] + [rotulos[c.id_coleta] for c in ordem]
    linhas = []
    for rows in _agrupar_produtos(spm).values():
        if any(r['Ignorar'] for r in rows):
            continue
        lin = {'Produto': rows[0]['Produto'],
               'Fabricante': _primeiro(r['Fabricante'] for r in rows),
               'Categoria': _primeiro(r['Categoria'] for r in rows)}
        for c in ordem:
            lin[rotulos[c.id_coleta]] = ''
        for r in rows:
            if r['IdColeta'] in rotulos:
                lin[rotulos[r['IdColeta']]] = r['Versoes'] or 'Sim'
        linhas.append(lin)
    linhas.sort(key=lambda l: l['Produto'].casefold())
    return colunas, linhas


def nao_mapeados(spm: List[dict], vestigios: List[dict]) -> List[dict]:
    grupos: Dict[str, dict] = {}
    for origem, rows in (('Instalado', spm), ('Vestigio', vestigios)):
        for r in rows:
            g = grupos.setdefault(r['Produto'].casefold(), {
                'produto': r['Produto'], 'fab': [], 'maq': set(), 'nomes': [], 'orig': set()})
            g['fab'].append(r.get('Fabricante', ''))
            g['maq'].add(r['IdColeta'])
            g['nomes'].extend((r.get('NomesOriginais') or r.get('_NomesOriginais') or '')
                              .split(_SEP))
            g['orig'].add(origem)
    saida = []
    for g in grupos.values():
        p = g['produto']
        padrao = 're:^' + re.escape(p) + '$' if ('*' in p or '?' in p) else p
        saida.append({
            'Padrao': padrao, 'Produto': p, 'Fabricante': _primeiro(g['fab']),
            'Categoria': '', 'Ignorar': 'Nao', 'Maquinas': len(g['maq']),
            'NomesOriginais': _juntar(g['nomes']),
            'Origem': '; '.join(o for o in ('Instalado', 'Vestigio') if o in g['orig']),
        })
    saida.sort(key=lambda r: (-r['Maquinas'], r['Produto'].casefold()))
    return saida


# === Vestigios ===

CHAVES_GENERICAS = frozenset(s.casefold() for s in (
    'Microsoft', 'Classes', 'Clients', 'Policies', 'RegisteredApplications', 'WOW6432Node',
    'Windows', 'Wow6432Node', 'ODBC', 'Intel', 'DefaultUserEnvironment', 'Partner', 'Setup',
    'Khronos'))
ITENS_GENERICOS = frozenset(s.casefold() for s in (
    'Setup', 'Installer', 'Capabilities', 'NativeMessagingHosts', 'Policies'))
PASTAS_GENERICAS = frozenset(s.casefold() for s in (
    'Common Files', 'Windows *', 'WindowsApps', 'Microsoft*', 'Internet Explorer',
    'ModifiableWindowsApps', 'Reference Assemblies', 'MSBuild', 'dotnet', 'Uninstall Information',
    'Package Cache', 'Packages'))
COLUNAS_VESTIGIOS = ('IdColeta', 'Hostname', 'IdEquipamento', 'Produto', 'Fabricante', 'Categoria',
                     'Fontes', 'PrimeiraData', 'UltimaData', 'Removido', 'DataRemocao',
                     'PastaRemanescente', 'UltimaExecucao', 'Evidencias')
COLUNAS_VESTIGIOS_PRODUTO = ('Produto', 'Fabricante', 'Categoria', 'Maquinas', 'MaquinasComRemocao',
                             'Hostnames', 'PrimeiraData', 'UltimaData')
FONTES_EXECUCAO = ('Prefetch', 'BAM', 'AmcacheArquivo', 'ShimCache', 'UserAssist',
                   'CompatAssistant', 'Atalho')
TIPOS_EXECUCAO = ('UltimaExecucao', 'PrimeiraExecucao', 'ArquivoModificado')
TIPO_COMPILACAO = 'ArquivoCompilado'
FONTE_PASTA = 'PastasProgramas'

_RE_VOLUME = re.compile(r'^\\device\\harddiskvolume\d+', re.IGNORECASE)
_RE_UNIDADE = re.compile(r'^[a-z]:', re.IGNORECASE)
_RE_PASTAS_GENERICAS = [_compilar_padrao(p)[0] for p in PASTAS_GENERICAS]


def normalizar_caminho(c: str) -> str:
    r = c.strip().strip('"').strip().replace('/', '\\')
    if r.startswith('\\\\?\\') or r.startswith('\\??\\'):
        r = r[4:]
    r = _RE_VOLUME.sub('', r)
    r = _RE_UNIDADE.sub('', r)
    return r.casefold().rstrip('\\')


def _dentro(caminho: str, pasta: str) -> bool:
    """caminho e pasta normalizados: True se caminho == pasta ou esta abaixo dela."""
    return caminho == pasta or caminho.startswith(pasta + '\\')


def _pasta_desinstalador(desinstalador: str) -> str:
    d = desinstalador.strip()
    if d.startswith('"'):
        exe = d[1:].split('"', 1)[0]
    else:
        m = re.match(r'^(.*?\.exe)(?:\s|$)', d, re.IGNORECASE)
        exe = m.group(1) if m else ''
    if not re.match(r'^(?:[A-Za-z]:\\|\\\\)', exe):
        return ''
    return exe.rsplit('\\', 1)[0]


def _com_data(antes: str, data: str, depois: str = '') -> str:
    return ' '.join(x for x in (antes, data, depois) if x)


@dataclass
class _Evidencia:
    fonte: str
    data: str
    tipo: str
    texto: str


@dataclass
class _Vestigio:
    produto: str
    fabricante: str
    categoria: str
    mapeado: bool
    ignorar: bool
    nomes: List[str] = field(default_factory=list)
    evidencias: List[_Evidencia] = field(default_factory=list)
    pastas: List[str] = field(default_factory=list)
    execucoes: List[_Evidencia] = field(default_factory=list)


_RE_ESPACOS = re.compile(r'\s+')


def _sem_espacos(texto: str) -> str:
    return _RE_ESPACOS.sub('', texto.casefold())


def nome_casa(candidato: str, produto: str) -> bool:
    """Regra das secoes 7.2 e 7.3: iguais (sem espacos), ou um e prefixo do outro por palavra."""
    c, p = candidato.casefold().strip(), produto.casefold().strip()
    if not c or not p:
        return False
    if _sem_espacos(c) == _sem_espacos(p):
        return True
    return p.startswith(c + ' ') or c.startswith(p + ' ')


class _Acumulador:
    def __init__(self, instalados: Iterable[str]):
        self.produtos = list(dict.fromkeys(instalados))
        self.instalados = {p.casefold() for p in self.produtos}
        self.itens: Dict[str, _Vestigio] = {}

    def instalado(self, produto: str) -> bool:
        return produto.casefold() in self.instalados

    def casa_instalado(self, candidato: str) -> bool:
        return self.instalado(candidato) or any(nome_casa(candidato, p) for p in self.produtos)

    def adicionar(self, cl: Classificacao, nome: str, fab: str) -> Optional[_Vestigio]:
        """Retorna o vestigio do produto, ou None se ele esta instalado (igualdade, secao 7.1)."""
        if self.instalado(cl.produto):
            return None
        v = self.itens.get(cl.produto.casefold())
        if v is None:
            v = self.itens[cl.produto.casefold()] = _Vestigio(
                cl.produto, cl.fabricante or fab, cl.categoria, cl.mapeado, cl.ignorar)
        elif cl.mapeado and not v.mapeado:
            v.produto, v.categoria, v.mapeado = cl.produto, cl.categoria, True
            v.fabricante = cl.fabricante or v.fabricante
        v.ignorar = v.ignorar or cl.ignorar
        v.fabricante = v.fabricante or fab
        v.nomes.append(nome)
        return v


def _evidencia_produto(l: Dict[str, str]) -> Optional[_Evidencia]:
    """Evidencia da secao 7.1 para EventoMSI, Amcache e InstallerCache."""
    fonte, data, tipo = l.get('Fonte', ''), l.get('Data', ''), l.get('TipoData', '')
    if fonte == 'EventoMSI' and tipo in ('Instalado', 'Removido'):
        return _Evidencia(fonte, data, tipo, _com_data(tipo, data, '(EventoMSI)'))
    if fonte == 'Amcache' and 'Origem=AppxPackage' not in l.get('Detalhe', ''):
        return _Evidencia(fonte, data, tipo, _com_data('Registrado no Amcache', data))
    if fonte == 'InstallerCache':
        return _Evidencia(fonte, data, tipo,
                          _com_data('.msi no cache criado', data, '(InstallerCache)'))
    return None


def _chave_casa_instalado(cands: List[str], fab: str, item: str, softwares: List[dict]) -> bool:
    palavra = re.compile(r'(?<!\w)' + re.escape(item) + r'(?!\w)', re.IGNORECASE)
    for s in softwares:
        p = s['Produto']
        if any(nome_casa(c, p) for c in cands):
            return True
        if fab and _sem_espacos(fab) == _sem_espacos(p):
            return True
        if (fab and s.get('Fabricante', '').casefold().startswith(fab.casefold())
                and palavra.search(s['Produto'])):
            return True
    return False


def _coletar_chave(acc: _Acumulador, l: Dict[str, str], softwares: List[dict], mapa: Mapa) -> None:
    fab, item = l.get('Fabricante', ''), l.get('Item', '')
    if not item or fab.casefold() in CHAVES_GENERICAS or item.casefold() in ITENS_GENERICOS:
        return
    i, f = item.casefold(), fab.casefold()
    # Item igual ao fabricante, ou que ja comeca com ele: o candidato e so o Item.
    so_fabricante = not fab or i == f or i.startswith(f + ' ')
    nome = item if so_fabricante else f'{fab} {item}'
    completo = mapa.classificar(nome, fab)
    cands = [completo.produto]
    if not so_fabricante:
        cands.append(mapa.classificar(item, fab).produto)
    if _chave_casa_instalado(cands, fab, item, softwares):
        return
    v = acc.adicionar(completo, nome, fab)
    if v is not None:
        data, cam = l.get('Data', ''), l.get('Caminho', '')
        v.evidencias.append(_Evidencia('ChaveSoftware', data, l.get('TipoData', ''),
                                       _com_data(f'Chave {cam} modificada', data)))


def _coletar_evidencias(acc: _Acumulador, linhas08: List[Dict[str, str]], softwares: List[dict],
                        mapa: Mapa) -> None:
    for l in linhas08:
        if l.get('Fonte') == 'ChaveSoftware':
            _coletar_chave(acc, l, softwares, mapa)
            continue
        e = _evidencia_produto(l)
        item = l.get('Item', '')
        if e is None or not item:
            continue
        v = acc.adicionar(mapa.classificar(item, l.get('Fabricante', '')), item,
                          l.get('Fabricante', ''))
        if v is not None:
            v.evidencias.append(e)


def _pastas_instaladas(linhas07: List[Dict[str, str]]) -> List[str]:
    saida = []
    for l in linhas07:
        for p in (l.get('LocalInstalacao', ''), _pasta_desinstalador(l.get('Desinstalador', ''))):
            n = normalizar_caminho(p.strip())
            if n:
                saida.append(n)
    return saida


def _pasta_generica(nome: str) -> bool:
    return any(rx.match(nome) for rx in _RE_PASTAS_GENERICAS)


def _coletar_pastas(acc: _Acumulador, linhas14: List[Dict[str, str]],
                    linhas07: List[Dict[str, str]], mapa: Mapa) -> Dict[str, List[_Vestigio]]:
    """Pastas remanescentes (7.3). Retorna caminho normalizado -> vestigios anexados."""
    instaladas = _pastas_instaladas(linhas07)
    saida: Dict[str, List[_Vestigio]] = {}
    for l in linhas14:
        cam = l.get('Caminho', '')
        n = normalizar_caminho(cam)
        nome = l.get('Pasta', '') or cam.replace('/', '\\').rstrip('\\').rsplit('\\', 1)[-1]
        if not n or not nome or _pasta_generica(nome):
            continue
        if any(_dentro(i, n) for i in instaladas):
            continue
        cl = mapa.classificar(nome)
        if acc.casa_instalado(cl.produto):
            continue
        v = acc.adicionar(cl, nome, '')
        if v is None:
            continue
        if cam not in v.pastas:
            v.pastas.append(cam)
            v.evidencias.append(_Evidencia(FONTE_PASTA, '', '', f'Pasta {cam}'))
        saida.setdefault(n, []).append(v)
    return saida


def _caminho_execucao(l: Dict[str, str]) -> str:
    cam = l.get('Caminho', '')
    if not cam and l.get('Fonte') == 'UserAssist' and '\\' in l.get('Item', ''):
        cam = l.get('Item', '')
    return normalizar_caminho(cam)


def _anexar_execucao(vs: Iterable[_Vestigio], l: Dict[str, str]) -> None:
    fonte, data, tipo = l.get('Fonte', ''), l.get('Data', ''), l.get('TipoData', '')
    conta = tipo in TIPOS_EXECUCAO and bool(data)
    texto = f'Ultima execucao {data} ({fonte})' if conta else ''
    e = _Evidencia(fonte, data, tipo, texto)
    for v in vs:
        v.execucoes.append(e)


def _coletar_execucoes(pastas: Dict[str, List[_Vestigio]], linhas08: List[Dict[str, str]]) -> None:
    exes: Dict[str, List[_Vestigio]] = {}
    prefetch_sem_caminho = []
    for l in linhas08:
        if l.get('Fonte') not in FONTES_EXECUCAO:
            continue
        cam = _caminho_execucao(l)
        if not cam:
            if l.get('Fonte') == 'Prefetch':
                prefetch_sem_caminho.append(l)
            continue
        vs = [v for p, lista in pastas.items() if _dentro(cam, p) for v in lista]
        if vs:
            _anexar_execucao(vs, l)
            lst = exes.setdefault(cam.rsplit('\\', 1)[-1], [])
            lst.extend(v for v in vs if v not in lst)
    for l in prefetch_sem_caminho:
        vs = exes.get(l.get('Item', '').casefold())
        if vs:
            _anexar_execucao(vs, l)


def _datas(evs: Iterable[_Evidencia]) -> List[str]:
    return sorted(e.data for e in evs if e.data and e.tipo != TIPO_COMPILACAO)


def _linha_vestigio(coleta: Coleta, v: _Vestigio) -> dict:
    todas = v.evidencias + v.execucoes
    datas = _datas(todas)
    remocoes = [e.data for e in v.evidencias if e.fonte == 'EventoMSI' and e.tipo == 'Removido']
    execucoes = _datas(e for e in v.execucoes if e.tipo in TIPOS_EXECUCAO)
    textos = [e.texto for e in sorted(todas, key=lambda e: (e.data, e.fonte, e.texto)) if e.texto]
    return {
        'IdColeta': coleta.id_coleta,
        'Hostname': coleta.hostname,
        'IdEquipamento': coleta.id_equipamento,
        'Produto': v.produto,
        'Fabricante': v.fabricante,
        'Categoria': v.categoria,
        'Fontes': ';'.join(_unicos(e.fonte for e in todas)),
        'PrimeiraData': datas[0] if datas else '',
        'UltimaData': datas[-1] if datas else '',
        'Removido': bool(remocoes),
        'DataRemocao': max((d for d in remocoes if d), default=''),
        'PastaRemanescente': _SEP.join(v.pastas),
        'UltimaExecucao': execucoes[-1] if execucoes else '',
        'Evidencias': '; '.join(dict.fromkeys(textos)),
        '_Mapeado': v.mapeado,
        '_NomesOriginais': _juntar(v.nomes),
    }


def vestigios_da_coleta(con: sqlite3.Connection, coleta: Coleta, softwares: List[dict],
                        mapa: Mapa) -> List[dict]:
    linhas07 = linhas_area(con, '07', coleta.id_coleta)
    linhas08 = linhas_area(con, '08', coleta.id_coleta)
    acc = _Acumulador(s['Produto'] for s in softwares)
    _coletar_evidencias(acc, linhas08, softwares, mapa)
    pastas = _coletar_pastas(acc, linhas_area(con, '14', coleta.id_coleta), linhas07, mapa)
    _coletar_execucoes(pastas, linhas08)
    saida = [_linha_vestigio(coleta, v) for v in acc.itens.values() if not v.ignorar]
    saida.sort(key=lambda r: r['Produto'].casefold())
    return saida


def vestigios_por_produto(linhas: List[dict]) -> List[dict]:
    saida = []
    for rows in _agrupar_produtos(linhas).values():
        primeiras = [r['PrimeiraData'] for r in rows if r['PrimeiraData']]
        ultimas = [r['UltimaData'] for r in rows if r['UltimaData']]
        saida.append({
            'Produto': rows[0]['Produto'],
            'Fabricante': _primeiro(r['Fabricante'] for r in rows),
            'Categoria': _primeiro(r['Categoria'] for r in rows),
            'Maquinas': len({r['IdColeta'] for r in rows}),
            'MaquinasComRemocao': len({r['IdColeta'] for r in rows if r['Removido']}),
            'Hostnames': _juntar(r['Hostname'] for r in rows),
            'PrimeiraData': min(primeiras, default=''),
            'UltimaData': max(ultimas, default=''),
        })
    saida.sort(key=lambda r: (-r['Maquinas'], r['Produto'].casefold()))
    return saida


# === Analises ===

COLUNAS_INSTALADORES = ('SHA256', 'Arquivo', 'TamanhoBytes', 'ProductName', 'CompanyName',
                        'ProductVersion', 'Maquinas', 'Hostnames', 'Caminhos')
COLUNAS_LICENCAS = ('Hostname', 'IdEquipamento', 'Produto', 'Descricao', 'Canal', 'EstadoLicenca',
                    'ChaveParcial', 'ServidorKMS', 'PortaKMS', 'Detalhe')
COLUNAS_ALERTAS = ('Tipo', 'IdColeta', 'Hostname', 'IdEquipamento', 'Mensagem')


def _distintos(valores: Iterable[str], chave=None) -> str:
    return ' | '.join(sorted({v for v in valores if v}, key=chave))


_COLUNAS_AGRUPADAS_INSTALADORES = ('SHA256', 'Arquivo', 'TamanhoBytes', 'ProductName',
                                   'CompanyName', 'ProductVersion', 'Host', 'Caminho')


def instaladores(con: sqlite3.Connection, coletas_usadas: List[Coleta],
                 areas: Sequence[str] = ('15', '16')) -> List[dict]:
    """Instaladores agrupados por SHA256 (ou nome+tamanho, sem hash), agrupados no SQLite.

    So os grupos e os valores distintos de cada grupo chegam ao Python: a memoria nao cresce
    com o numero de linhas da area 16.
    """
    con.create_function('casefold', 1, lambda t: t.casefold() if isinstance(t, str) else t,
                        deterministic=True)
    con.execute('DROP TABLE IF EXISTS temp._inst_coletas')
    con.execute('DROP TABLE IF EXISTS temp._inst')
    con.execute('CREATE TEMP TABLE _inst_coletas (IdColeta TEXT PRIMARY KEY, Host TEXT)')
    con.executemany('INSERT OR IGNORE INTO temp._inst_coletas VALUES (?, ?)',
                    [(c.id_coleta, c.hostname) for c in coletas_usadas])
    cols = ', '.join(f"coalesce(t.{q(c)}, '') AS {q(c)}" for c in _COLUNAS_AGRUPADAS_INSTALADORES
                     if c != 'Host')
    partes = [f"SELECT t.IdColeta AS IdColeta, coalesce(k.Host, '') AS Host, {cols}, "
              f"CASE WHEN coalesce(t.SHA256, '') <> '' THEN 'h' || lower(t.SHA256) "
              f"ELSE 'n' || casefold(coalesce(t.Arquivo, '')) || char(31) || "
              f"coalesce(t.TamanhoBytes, '') END AS Chave "
              f"FROM {q(AREAS[n].tabela)} t JOIN temp._inst_coletas k ON k.IdColeta = t.IdColeta"
              for n in areas]
    try:
        con.execute('CREATE TEMP TABLE _inst AS ' + ' UNION ALL '.join(partes))
        grupos: Dict[str, dict] = {}
        for chave, n in con.execute('SELECT Chave, COUNT(DISTINCT IdColeta) FROM temp._inst '
                                    'GROUP BY Chave'):
            grupos[chave] = {'Maquinas': n}
        distintos = ' UNION '.join(
            f"SELECT Chave, {i} AS Col, {q(c)} AS Valor FROM temp._inst WHERE {q(c)} <> ''"
            for i, c in enumerate(_COLUNAS_AGRUPADAS_INSTALADORES))
        for chave, i, valores in con.execute(
                f"SELECT Chave, Col, group_concat(Valor, char(31)) FROM ({distintos}) "
                f"GROUP BY Chave, Col"):
            grupos[chave][_COLUNAS_AGRUPADAS_INSTALADORES[i]] = valores.split('\x1f')
    finally:
        con.execute('DROP TABLE IF EXISTS temp._inst')
        con.execute('DROP TABLE IF EXISTS temp._inst_coletas')
    saida = []
    for g in grupos.values():
        def juntar(c, chave=None):
            return ' | '.join(sorted(set(g.get(c, [])), key=chave))
        saida.append({
            'SHA256': juntar('SHA256'),
            'Arquivo': juntar('Arquivo'),
            'TamanhoBytes': juntar('TamanhoBytes'),
            'ProductName': juntar('ProductName'),
            'CompanyName': juntar('CompanyName'),
            'ProductVersion': juntar('ProductVersion'),
            'Maquinas': g['Maquinas'],
            'Hostnames': juntar('Host', str.casefold),
            'Caminhos': juntar('Caminho'),
        })
    saida.sort(key=lambda r: (-r['Maquinas'], r['Arquivo'].casefold()))
    return saida


def licencas(con: sqlite3.Connection, coletas_usadas: List[Coleta]) -> List[dict]:
    saida = []
    for c in sorted(coletas_usadas, key=lambda c: (c.hostname.casefold(), c.id_equipamento)):
        base = {'Hostname': c.hostname, 'IdEquipamento': c.id_equipamento}
        linha = {k: '' for k in COLUNAS_LICENCAS}
        linha.update(base)
        linha['Produto'] = 'Windows'
        linha['EstadoLicenca'] = c.resumo.get('AtivacaoWindows', '')
        saida.append(linha)
        for l in linhas_area(con, '09', c.id_coleta):
            linha = {k: l.get(k, '') for k in COLUNAS_LICENCAS}
            linha.update(base)
            saida.append(linha)
    return saida


# === Saidas ===

NOMES_ANALISES = {
    'A_Coletas': 'coletas',
    'A_Catalogo_Softwares': 'catalogo_softwares',
    'A_Matriz_Softwares': None,
    'A_Softwares_Por_Maquina': 'softwares_por_maquina',
    'A_Vestigios_Sem_Instalacao': 'vestigios_sem_instalacao',
    'A_Vestigios_Sem_Instalacao_Por_Produto': 'vestigios_sem_instalacao_por_produto',
    'A_Instaladores': 'instaladores',
    'A_Licencas': 'licencas_consolidadas',
    'A_Softwares_Nao_Mapeados': 'softwares_nao_mapeados',
    'A_Alertas': 'alertas',
}


def gravar_tabela(con: sqlite3.Connection, nome: str, colunas: Sequence[str],
                  linhas: List[dict]) -> None:
    con.execute(f'DROP TABLE IF EXISTS {q(nome)}')
    con.execute(f"CREATE TABLE {q(nome)} ({', '.join(q(c) + ' TEXT' for c in colunas)})")
    sql = (f"INSERT INTO {q(nome)} ({', '.join(q(c) for c in colunas)}) "
           f"VALUES ({', '.join('?' * len(colunas))})")
    con.executemany(sql, ([formatar_valor(l.get(c, '')) for c in colunas] for l in linhas))
    con.commit()


def criar_indices_analises(con: sqlite3.Connection) -> None:
    for t in ('softwares_por_maquina', 'vestigios_sem_instalacao'):
        con.execute(f"CREATE INDEX {q('ix_' + t + '_Produto')} ON {q(t)} ({q('Produto')})")
    con.commit()


def gravar_analises(con: sqlite3.Connection, analises: Dict[str, tuple]) -> None:
    for chave, (colunas, linhas) in analises.items():
        if chave not in NOMES_ANALISES:
            raise ValueError(f'analise desconhecida: {chave}')
        tabela = NOMES_ANALISES[chave]
        if not tabela or tabela == 'coletas':
            continue
        gravar_tabela(con, tabela, colunas, linhas)
    criar_indices_analises(con)


def exportar_consolidados(con: sqlite3.Connection, pasta_csv: Path) -> None:
    for area in AREAS.values():
        cols = _colunas_tabela(area)
        cur = con.execute(f"SELECT {', '.join(q(c) for c in cols)} FROM {q('v_' + area.tabela)} "
                          f"ORDER BY rowid")
        linhas = (dict(zip(cols, r)) for r in cur)
        escrever_csv(Path(pasta_csv) / area.arquivo, cols, linhas)


def exportar_analises(pasta_csv: Path, analises: Dict[str, tuple]) -> None:
    for chave, (colunas, linhas) in analises.items():
        escrever_csv(Path(pasta_csv) / (chave + '.csv'), colunas, linhas)


def gravar_mapa_e_execucao(con: sqlite3.Connection, mapa: Mapa, execucao: Dict[str, str]) -> None:
    gravar_tabela(con, 'mapa', ('Linha', 'Padrao', 'Produto', 'Fabricante', 'Categoria', 'Ignorar'),
                  [{'Linha': r.linha, 'Padrao': r.padrao, 'Produto': r.produto,
                    'Fabricante': r.fabricante, 'Categoria': r.categoria, 'Ignorar': r.ignorar}
                   for r in mapa.regras])
    gravar_tabela(con, 'execucao', ('Chave', 'Valor'),
                  [{'Chave': k, 'Valor': v} for k, v in execucao.items()])


def escrever_sha256sums(pasta: Path) -> Path:
    pasta = Path(pasta)
    destino = pasta / 'SHA256SUMS.txt'
    itens = []
    for f in pasta.rglob('*'):
        if not f.is_file():
            continue
        rel = f.relative_to(pasta).as_posix()
        if rel == 'SHA256SUMS.txt':
            continue
        itens.append((rel, f))
    linhas = [f'{sha256_arquivo(f)}  {rel}\n' for rel, f in sorted(itens, key=lambda t: t[0])]
    with open(destino, 'w', encoding='utf-8', newline='') as fh:
        fh.write(''.join(linhas))
    return destino


# === HTML ===

AVISO_CRUZAMENTO = ('O cruzamento compara nomes e caminhos. Um vestígio pode ter nome diferente do '
                    'software instalado correspondente; cada linha deve ser conferida pelas '
                    'evidências.')
COLUNAS_MAQUINAS = ('IdColeta', 'Hostname', 'IdEquipamento', 'Etiqueta', 'Setor', 'Fabricante',
                    'Modelo', 'SistemaOperacional', 'Build', 'AtivacaoWindows',
                    'ExecutadoComoAdmin', 'Modo', 'DataColeta', 'Situacao', 'TotalSoftwares',
                    'TotalVestigiosSemInstalacao', 'AreasComFalha', 'AreasPuladas')
_TABELAS_HTML = {
    'alertas': ('A_Alertas', COLUNAS_ALERTAS),
    'catalogo': ('A_Catalogo_Softwares', COLUNAS_CATALOGO),
    'softwares': ('A_Softwares_Por_Maquina', COLUNAS_SPM),
    'vestigios': ('A_Vestigios_Sem_Instalacao', COLUNAS_VESTIGIOS),
    'vestigios_produto': ('A_Vestigios_Sem_Instalacao_Por_Produto', COLUNAS_VESTIGIOS_PRODUTO),
    'instaladores': ('A_Instaladores', COLUNAS_INSTALADORES),
    'licencas': ('A_Licencas', COLUNAS_LICENCAS),
}
_AREAS_FICHA = {'hardware': ('02',), 'volumes': ('03',), 'rede': ('04',), 'instaladores': ('15',)}
_EXECUCAO_OCULTA = ('autor', 'emailautor')


def _colunas_ficha(numeros: Sequence[str]) -> List[str]:
    cols = _colunas_tabela(AREAS[numeros[0]])
    return ['Origem'] + cols if len(numeros) > 1 else cols


def _execucao_html(execucao: Dict[str, str]) -> Dict[str, str]:
    ocultos = [AUTOR.casefold(), EMAIL_AUTOR.casefold()]
    return {str(k): formatar_valor(v) for k, v in execucao.items()
            if str(k).casefold() not in _EXECUCAO_OCULTA
            and not any(o in formatar_valor(v).casefold() for o in ocultos)}


def _linhas_texto(colunas: Sequence[str], linhas: Iterable[Mapping[str, object]]) -> List[Dict[str, str]]:
    cols = [c for c in colunas if not c.startswith('_')]
    return [{c: formatar_valor(l.get(c, '')) for c in cols} for l in linhas]


def dados_html(con: sqlite3.Connection, coletas: List[Coleta], analises: dict,
               execucao: Dict[str, str]) -> dict:
    ativas = sorted((c for c in coletas if c.situacao in ('Usada', 'NaoVerificada')),
                    key=lambda c: (c.hostname.casefold(), c.id_equipamento, c.id_coleta))
    dados: dict = {'execucao': _execucao_html(execucao)}
    colunas = {}
    for chave, (nome, padrao) in _TABELAS_HTML.items():
        if chave == 'instaladores':
            # A area 16 (Completa) fica so nos CSVs e no SQLite: o HTML mostra a area 15.
            try:
                cols, linhas = padrao, instaladores(con, ativas, ('15',))
            except Exception:
                log.exception('Erro ao agrupar os instaladores do HTML')
                cols, linhas = padrao, []
        else:
            cols, linhas = analises.get(nome, (padrao, []))
        dados[chave] = _linhas_texto(cols, linhas)
        colunas[chave] = [c for c in cols if not c.startswith('_')]
    sw: Dict[str, int] = {}
    for s in dados['softwares']:
        if s.get('Ignorar') != 'Sim':
            sw[s.get('IdColeta', '')] = sw.get(s.get('IdColeta', ''), 0) + 1
    vs: Dict[str, int] = {}
    for v in dados['vestigios']:
        vs[v.get('IdColeta', '')] = vs.get(v.get('IdColeta', ''), 0) + 1
    maquinas, fichas = [], {}
    for c in ativas:
        linha = {k: formatar_valor(c.resumo.get(k, '')) for k in COLUNAS_MAQUINAS}
        linha.update(IdColeta=c.id_coleta, Hostname=c.hostname, IdEquipamento=c.id_equipamento,
                     Situacao=c.situacao, TotalSoftwares=str(sw.get(c.id_coleta, 0)),
                     TotalVestigiosSemInstalacao=str(vs.get(c.id_coleta, 0)))
        maquinas.append(linha)
        resumo = linhas_area(con, '01', c.id_coleta)
        ficha = {'resumo': {k: formatar_valor(v) for k, v in (resumo[0] if resumo else c.resumo).items()}}
        for chave, numeros in _AREAS_FICHA.items():
            linhas = [dict(l, Origem=AREAS[num].arquivo[:-4]) for num in numeros
                      for l in linhas_area(con, num, c.id_coleta)]
            ficha[chave] = _linhas_texto(_colunas_ficha(numeros), linhas)
        fichas[c.id_coleta] = ficha
    colunas['maquinas'] = list(COLUNAS_MAQUINAS)
    for chave, numeros in _AREAS_FICHA.items():
        colunas['ficha_' + chave] = _colunas_ficha(numeros)
    situacoes = [c.situacao for c in coletas]
    dados['totais'] = {k: str(v) for k, v in (
        ('maquinas', len(ativas)),
        ('coletas_usadas', situacoes.count('Usada')),
        ('nao_verificadas', situacoes.count('NaoVerificada')),
        ('substituidas', situacoes.count('Substituida')),
        ('rejeitadas', situacoes.count('Rejeitada')),
        ('produtos', sum(1 for r in dados['catalogo'] if r.get('Ignorar') != 'Sim')),
        ('vestigios', len(dados['vestigios'])),
        ('instaladores', len(dados['instaladores'])))}
    dados['maquinas'] = maquinas
    dados['fichas'] = fichas
    dados['colunas'] = colunas
    return dados


def gerar_html(caminho: Path, dados: dict) -> None:
    js = json.dumps(dados, ensure_ascii=False, separators=(',', ':'))
    js = js.replace('<', '\\u003c').replace('/', '\\/')
    texto = (_MODELO_HTML.replace('@@AVISO@@', html.escape(AVISO_CRUZAMENTO))
             .replace('@@DADOS@@', js))
    with open(caminho, 'w', encoding='utf-8', newline='\n') as fh:
        fh.write(texto)


_MODELO_HTML = r'''<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Consolidação de Coletas</title>
<style>
:root {
  --fundo: #ffffff; --texto: #1d2329; --suave: #5b6670; --borda: #d5dbe0;
  --painel: #f4f6f8; --destaque: #1f5fa8; --destaque-texto: #ffffff;
  --aviso-fundo: #fff4d6; --aviso-borda: #d9a400; --linha-par: #f9fafb;
}
@media (prefers-color-scheme: dark) {
  :root {
    --fundo: #15191d; --texto: #e3e7eb; --suave: #9aa5b0; --borda: #343c44;
    --painel: #1f252b; --destaque: #6fa8ea; --destaque-texto: #0d1114;
    --aviso-fundo: #3a3016; --aviso-borda: #b8902a; --linha-par: #1a1f24;
  }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--fundo); color: var(--texto);
  font: 14px/1.45 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
header { padding: 14px 20px 0; }
h1 { font-size: 20px; margin: 0 0 10px; }
h2 { font-size: 16px; margin: 22px 0 8px; }
nav[role=tablist] { display: flex; flex-wrap: wrap; gap: 4px; border-bottom: 1px solid var(--borda); }
nav button { border: 1px solid var(--borda); border-bottom: none; background: var(--painel);
  color: var(--texto); padding: 7px 12px; border-radius: 6px 6px 0 0; cursor: pointer; font: inherit; }
nav button[aria-selected=true] { background: var(--destaque); color: var(--destaque-texto);
  border-color: var(--destaque); }
main { padding: 8px 20px 30px; }
button, select, input { font: inherit; color: inherit; }
button:focus-visible, select:focus-visible, input:focus-visible { outline: 2px solid var(--destaque); outline-offset: 1px; }
.controles { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin: 8px 0; }
.controles input[type=search], .controles select { padding: 5px 8px; border: 1px solid var(--borda);
  border-radius: 4px; background: var(--fundo); min-width: 220px; }
.controles button, button.mais { padding: 5px 10px; border: 1px solid var(--borda); border-radius: 4px;
  background: var(--painel); cursor: pointer; }
.contador { color: var(--suave); }
.rolagem { overflow-x: auto; }
table { border-collapse: collapse; width: 100%; }
th, td { border: 1px solid var(--borda); padding: 4px 6px; text-align: left; vertical-align: top; }
td { word-break: break-word; }
thead th { background: var(--painel); position: sticky; top: 0; }
th button { all: unset; cursor: pointer; font-weight: 600; display: block; width: 100%; }
th button:focus-visible { outline: 2px solid var(--destaque); }
th[aria-sort=ascending] button::after { content: " \25B2"; }
th[aria-sort=descending] button::after { content: " \25BC"; }
tbody tr:nth-child(even) { background: var(--linha-par); }
tr.detalhe > td { background: var(--painel); padding: 8px 12px; }
button.link { all: unset; color: var(--destaque); text-decoration: underline; cursor: pointer; }
button.link:focus-visible { outline: 2px solid var(--destaque); }
button.expandir { width: 26px; padding: 0; border: 1px solid var(--borda); border-radius: 4px;
  background: var(--fundo); cursor: pointer; }
.aviso { background: var(--aviso-fundo); border-left: 4px solid var(--aviso-borda); padding: 8px 12px; margin: 12px 0; }
.totais { display: grid; grid-template-columns: repeat(auto-fill, minmax(170px, 1fr)); gap: 8px; margin: 10px 0; }
.totais div { background: var(--painel); border: 1px solid var(--borda); border-radius: 6px; padding: 8px 10px; }
.totais strong { display: block; font-size: 20px; }
.totais span { color: var(--suave); }
.nota { color: var(--suave); }
@media print {
  nav, .controles, button.mais, button.expandir, .sem-impressao { display: none !important; }
  button.link { color: inherit; text-decoration: none; }
  thead th { position: static; }
  body { font-size: 11px; }
  main { padding: 0; }
}
</style>
</head>
<body>
<header>
<h1>Consolidação de Coletas</h1>
<nav role="tablist" aria-label="Seções do relatório">
<button type="button" role="tab" id="aba-geral" aria-controls="painel-geral" aria-selected="true">Visão geral</button>
<button type="button" role="tab" id="aba-maquinas" aria-controls="painel-maquinas" aria-selected="false" tabindex="-1">Máquinas</button>
<button type="button" role="tab" id="aba-softwares" aria-controls="painel-softwares" aria-selected="false" tabindex="-1">Softwares</button>
<button type="button" role="tab" id="aba-vestigios" aria-controls="painel-vestigios" aria-selected="false" tabindex="-1">Vestígios sem instalação</button>
<button type="button" role="tab" id="aba-instaladores" aria-controls="painel-instaladores" aria-selected="false" tabindex="-1">Instaladores</button>
<button type="button" role="tab" id="aba-licencas" aria-controls="painel-licencas" aria-selected="false" tabindex="-1">Licenças</button>
<button type="button" role="tab" id="aba-ficha" aria-controls="painel-ficha" aria-selected="false" tabindex="-1">Ficha da máquina</button>
</nav>
</header>
<main>
<section role="tabpanel" id="painel-geral" aria-labelledby="aba-geral">
<div class="totais" id="totais"></div>
<p class="aviso" role="note">@@AVISO@@</p>
<p class="nota">A matriz completa de softwares, os vestígios brutos (área 08), os serviços, as tarefas, os drivers e as atualizações não entram neste relatório. Esses dados estão nos CSVs e no SQLite da consolidação.</p>
<h2>Alertas</h2>
<div id="tabela-alertas"></div>
<h2>Execução</h2>
<div id="tabela-execucao"></div>
</section>
<section role="tabpanel" id="painel-maquinas" aria-labelledby="aba-maquinas" hidden>
<p class="nota">Uma linha por coleta usada. Clique no hostname para abrir a ficha da máquina.</p>
<div id="tabela-maquinas"></div>
</section>
<section role="tabpanel" id="painel-softwares" aria-labelledby="aba-softwares" hidden>
<div class="controles">
<label>Categoria <select id="filtro-categoria"><option value="">Todas</option></select></label>
<label><input type="checkbox" id="mostrar-ignorados"> Mostrar ignorados</label>
</div>
<div id="tabela-catalogo"></div>
</section>
<section role="tabpanel" id="painel-vestigios" aria-labelledby="aba-vestigios" hidden>
<p class="aviso" role="note">@@AVISO@@</p>
<div id="tabela-vestigios"></div>
</section>
<section role="tabpanel" id="painel-instaladores" aria-labelledby="aba-instaladores" hidden>
<p class="nota">Instaladores encontrados nas pastas que a coleta verifica (área 15). A varredura completa dos discos (área 16, modo Completa) fica em A_Instaladores.csv e no SQLite.</p>
<div id="tabela-instaladores"></div>
</section>
<section role="tabpanel" id="painel-licencas" aria-labelledby="aba-licencas" hidden>
<div id="tabela-licencas"></div>
</section>
<section role="tabpanel" id="painel-ficha" aria-labelledby="aba-ficha" hidden>
<div class="controles">
<label>Máquina <select id="escolha-maquina"><option value="">Selecione</option></select></label>
</div>
<div id="conteudo-ficha"><p class="nota">Selecione uma máquina ou clique num hostname nas outras abas.</p></div>
</section>
</main>
<script id="dados" type="application/json">@@DADOS@@</script>
<script>
(function () {
'use strict';
var D = JSON.parse(document.getElementById('dados').textContent);
var COL = D.colunas || {};
var LIMITE = 500;
var colador = new Intl.Collator('pt-BR', {numeric: true, sensitivity: 'base'});
var numero = new Intl.NumberFormat('pt-BR');

function el(tag, attrs, filhos) {
  var e = document.createElement(tag);
  if (attrs) {
    Object.keys(attrs).forEach(function (k) {
      var v = attrs[k];
      if (k === 'text') e.textContent = v;
      else if (k === 'class') e.className = v;
      else if (k.slice(0, 2) === 'on') e.addEventListener(k.slice(2), v);
      else e.setAttribute(k, v);
    });
  }
  (filhos || []).forEach(function (f) {
    if (f != null) e.appendChild(typeof f === 'string' ? document.createTextNode(f) : f);
  });
  return e;
}
function lista(v) { return Array.isArray(v) ? v : []; }
function normalizar(s) {
  return String(s).normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase();
}
function colunasDe(nome, linhas) {
  if (COL[nome]) return COL[nome];
  return linhas.length ? Object.keys(linhas[0]) : [];
}
function chaveProduto(s) { return String(s == null ? '' : s).toLowerCase(); }
function agrupar(linhas, campo) {
  var g = Object.create(null);
  linhas.forEach(function (r) { var k = chaveProduto(r[campo]); (g[k] = g[k] || []).push(r); });
  return g;
}
function seguro(s) { return String(s).replace(/[^\w.-]+/g, '_').slice(0, 60); }

var fichas = D.fichas || {};
var maquinas = lista(D.maquinas);
var porEquipamento = Object.create(null);
maquinas.forEach(function (m) { porEquipamento[m.Hostname + '\u0000' + m.IdEquipamento] = m.IdColeta; });
function idDaLinha(r) {
  if (r.IdColeta && fichas[r.IdColeta]) return r.IdColeta;
  if (r.Hostname !== undefined) return porEquipamento[r.Hostname + '\u0000' + (r.IdEquipamento || '')] || null;
  return null;
}

function tabela(opc) {
  var linhas = opc.linhas;
  var colunas = opc.colunas;
  var estado = {coluna: null, direcao: 1, limite: LIMITE};
  var atual = [];
  var cache = new WeakMap();
  var busca = el('input', {type: 'search', placeholder: 'Buscar...', 'aria-label': 'Buscar em ' + opc.titulo});
  var contador = el('span', {'class': 'contador', 'aria-live': 'polite'});
  var exportar = el('button', {type: 'button', text: 'Exportar CSV', onclick: exportarCsv});
  var mais = el('button', {type: 'button', 'class': 'mais', text: 'Mostrar mais', onclick: function () {
    estado.limite += LIMITE; desenhar();
  }});
  var cabecalho = el('tr');
  var corpo = el('tbody');
  var tab = el('table', null, [el('caption', {'class': 'sem-impressao', text: opc.titulo, style: 'text-align:left;font-weight:600'}), el('thead', null, [cabecalho]), corpo]);
  if (opc.expandir) cabecalho.appendChild(el('th', {scope: 'col'}, [el('span', {'aria-label': 'Detalhes'})]));
  var ths = colunas.map(function (c) {
    var th = el('th', {scope: 'col', 'aria-sort': 'none'}, [el('button', {type: 'button', text: c, onclick: function () {
      if (estado.coluna === c) estado.direcao = -estado.direcao; else { estado.coluna = c; estado.direcao = 1; }
      ths.forEach(function (t, i) {
        t.setAttribute('aria-sort', colunas[i] !== c ? 'none' : (estado.direcao > 0 ? 'ascending' : 'descending'));
      });
      atualizar();
    }})]);
    cabecalho.appendChild(th);
    return th;
  });
  var espera = null;
  busca.addEventListener('input', function () { clearTimeout(espera); espera = setTimeout(atualizar, 200); });

  function texto(r) {
    var t = cache.get(r);
    if (t === undefined) {
      t = normalizar(colunas.map(function (c) { return r[c] || ''; }).join('\u0001'));
      cache.set(r, t);
    }
    return t;
  }
  function atualizar() {
    var base = opc.filtro ? linhas.filter(opc.filtro) : linhas.slice();
    var termos = normalizar(busca.value.trim()).split(/\s+/).filter(Boolean);
    if (termos.length) {
      base = base.filter(function (r) {
        var t = texto(r);
        return termos.every(function (x) { return t.indexOf(x) >= 0; });
      });
    }
    if (estado.coluna) {
      var c = estado.coluna, d = estado.direcao;
      base.sort(function (a, b) { return d * colador.compare(a[c] || '', b[c] || ''); });
    }
    atual = base;
    estado.limite = LIMITE;
    desenhar();
  }
  function celula(c, r) {
    var td = el('td');
    var v = r[c] == null ? '' : r[c];
    var id = c === 'Hostname' ? idDaLinha(r) : null;
    if (id) td.appendChild(el('button', {type: 'button', 'class': 'link', text: v || id, title: 'Abrir a ficha da máquina', onclick: function () { abrirFicha(id); }}));
    else td.textContent = v;
    return td;
  }
  function linha(r) {
    var tr = el('tr');
    if (opc.expandir) {
      var b = el('button', {type: 'button', 'class': 'expandir', 'aria-expanded': 'false', 'aria-label': 'Expandir detalhes', text: '+'});
      b.addEventListener('click', function () {
        var prox = tr.nextSibling;
        if (b.getAttribute('aria-expanded') === 'true') {
          if (prox && prox.className === 'detalhe') prox.parentNode.removeChild(prox);
          b.setAttribute('aria-expanded', 'false'); b.textContent = '+';
        } else {
          var det = el('tr', {'class': 'detalhe'}, [el('td', {colspan: String(colunas.length + 1)}, [opc.expandir(r)])]);
          tr.parentNode.insertBefore(det, prox);
          b.setAttribute('aria-expanded', 'true'); b.textContent = '\u2212';
        }
      });
      tr.appendChild(el('td', null, [b]));
    }
    colunas.forEach(function (c) { tr.appendChild(celula(c, r)); });
    return tr;
  }
  function desenhar() {
    var n = Math.min(atual.length, estado.limite);
    var frag = document.createDocumentFragment();
    for (var i = 0; i < n; i++) frag.appendChild(linha(atual[i]));
    corpo.textContent = '';
    corpo.appendChild(frag);
    contador.textContent = numero.format(atual.length) + ' de ' + numero.format(linhas.length) + ' linhas' +
      (n < atual.length ? ' (exibindo ' + numero.format(n) + ')' : '');
    mais.hidden = n >= atual.length;
  }
  function aspas(v) { return '"' + String(v == null ? '' : v).replace(/"/g, '""') + '"'; }
  function exportarCsv() {
    var saida = [colunas.map(aspas).join(';')];
    atual.forEach(function (r) { saida.push(colunas.map(function (c) { return aspas(r[c]); }).join(';')); });
    var blob = new Blob(['\ufeff' + saida.join('\r\n') + '\r\n'], {type: 'text/csv;charset=utf-8'});
    var url = URL.createObjectURL(blob);
    var a = el('a', {href: url, download: seguro(opc.nome) + '.csv'});
    document.body.appendChild(a);
    a.click();
    setTimeout(function () { URL.revokeObjectURL(url); a.parentNode.removeChild(a); }, 0);
  }
  var raiz = el('div', {'class': 'bloco-tabela'}, [
    el('div', {'class': 'controles'}, [busca, contador, exportar]),
    el('div', {'class': 'rolagem'}, [tab]), mais]);
  atualizar();
  return {raiz: raiz, atualizar: atualizar};
}
function montar(destino, opc) {
  var t = tabela(opc);
  var alvo = typeof destino === 'string' ? document.getElementById(destino) : destino;
  alvo.textContent = '';
  alvo.appendChild(t.raiz);
  return t;
}
function sem(colunas, fora) { return colunas.filter(function (c) { return fora.indexOf(c) < 0; }); }

/* Abas */
var abas = Array.prototype.slice.call(document.querySelectorAll('nav [role=tab]'));
var montadas = {};
function ativar(aba, foco) {
  abas.forEach(function (a) {
    var sel = a === aba;
    a.setAttribute('aria-selected', sel ? 'true' : 'false');
    a.tabIndex = sel ? 0 : -1;
    document.getElementById(a.getAttribute('aria-controls')).hidden = !sel;
  });
  var nome = aba.id.slice(4);
  if (!montadas[nome] && construtores[nome]) { montadas[nome] = true; construtores[nome](); }
  if (foco) aba.focus();
}
abas.forEach(function (a, i) {
  a.addEventListener('click', function () { ativar(a, false); });
  a.addEventListener('keydown', function (ev) {
    var j = null;
    if (ev.key === 'ArrowRight') j = (i + 1) % abas.length;
    else if (ev.key === 'ArrowLeft') j = (i - 1 + abas.length) % abas.length;
    else if (ev.key === 'Home') j = 0;
    else if (ev.key === 'End') j = abas.length - 1;
    if (j !== null) { ev.preventDefault(); ativar(abas[j], true); }
  });
});

var softwares = lista(D.softwares), vestigios = lista(D.vestigios), instaladores = lista(D.instaladores);
var swPorProduto = null, vePorProduto = null;

var construtores = {
  geral: function () {
    var t = D.totais || {};
    var rotulos = [['maquinas', 'Máquinas'], ['coletas_usadas', 'Coletas usadas'], ['nao_verificadas', 'Não verificadas aceitas'],
      ['substituidas', 'Substituídas'], ['rejeitadas', 'Rejeitadas'], ['produtos', 'Produtos (sem ignorados)'],
      ['vestigios', 'Vestígios sem instalação'], ['instaladores', 'Instaladores distintos']];
    var caixa = document.getElementById('totais');
    rotulos.forEach(function (p) {
      if (t[p[0]] !== undefined) caixa.appendChild(el('div', null, [el('strong', {text: t[p[0]]}), el('span', {text: p[1]})]));
    });
    var alertas = lista(D.alertas);
    montar('tabela-alertas', {nome: 'Alertas', titulo: 'Alertas', linhas: alertas, colunas: colunasDe('alertas', alertas)});
    var ex = D.execucao || {};
    montar('tabela-execucao', {nome: 'Execucao', titulo: 'Execução', colunas: ['Chave', 'Valor'],
      linhas: Object.keys(ex).map(function (k) { return {Chave: k, Valor: ex[k]}; })});
  },
  maquinas: function () {
    montar('tabela-maquinas', {nome: 'Maquinas', titulo: 'Máquinas', linhas: maquinas,
      colunas: sem(colunasDe('maquinas', maquinas), ['IdColeta'])});
  },
  softwares: function () {
    var catalogo = lista(D.catalogo);
    swPorProduto = swPorProduto || agrupar(softwares, 'Produto');
    var cat = document.getElementById('filtro-categoria');
    var ign = document.getElementById('mostrar-ignorados');
    var cats = {};
    catalogo.forEach(function (r) { if (r.Categoria) cats[r.Categoria] = true; });
    Object.keys(cats).sort(colador.compare).forEach(function (c) { cat.appendChild(el('option', {value: c, text: c})); });
    var t = montar('tabela-catalogo', {nome: 'Catalogo_Softwares', titulo: 'Catálogo de softwares', linhas: catalogo,
      colunas: colunasDe('catalogo', catalogo),
      filtro: function (r) { return (ign.checked || r.Ignorar !== 'Sim') && (!cat.value || r.Categoria === cat.value); },
      expandir: function (r) {
        var ls = swPorProduto[chaveProduto(r.Produto)] || [];
        return tabela({nome: 'Softwares_' + r.Produto, titulo: 'Máquinas com ' + r.Produto, linhas: ls,
          colunas: sem(colunasDe('softwares', ls), ['IdColeta', 'Produto', 'Fabricante', 'Categoria', 'Ignorar'])}).raiz;
      }});
    cat.addEventListener('change', t.atualizar);
    ign.addEventListener('change', t.atualizar);
  },
  vestigios: function () {
    var vp = lista(D.vestigios_produto);
    vePorProduto = vePorProduto || agrupar(vestigios, 'Produto');
    montar('tabela-vestigios', {nome: 'Vestigios_Sem_Instalacao_Por_Produto', titulo: 'Vestígios sem instalação por produto',
      linhas: vp, colunas: colunasDe('vestigios_produto', vp),
      expandir: function (r) {
        var ls = vePorProduto[chaveProduto(r.Produto)] || [];
        return tabela({nome: 'Vestigios_' + r.Produto, titulo: 'Máquinas com vestígios de ' + r.Produto, linhas: ls,
          colunas: sem(colunasDe('vestigios', ls), ['IdColeta', 'Produto', 'Fabricante', 'Categoria'])}).raiz;
      }});
  },
  instaladores: function () {
    montar('tabela-instaladores', {nome: 'Instaladores', titulo: 'Instaladores', linhas: instaladores,
      colunas: colunasDe('instaladores', instaladores)});
  },
  licencas: function () {
    var ls = lista(D.licencas);
    montar('tabela-licencas', {nome: 'Licencas', titulo: 'Licenças', linhas: ls, colunas: colunasDe('licencas', ls)});
  },
  ficha: function () {
    var sel = document.getElementById('escolha-maquina');
    maquinas.forEach(function (m) {
      sel.appendChild(el('option', {value: m.IdColeta, text: m.Hostname + ' (' + String(m.IdEquipamento || '').slice(0, 8) + ') ' + m.DataColeta}));
    });
    sel.addEventListener('change', function () { desenharFicha(sel.value); });
  }
};

function desenharFicha(id) {
  var alvo = document.getElementById('conteudo-ficha');
  alvo.textContent = '';
  var f = fichas[id];
  if (!f) { alvo.appendChild(el('p', {'class': 'nota', text: 'Selecione uma máquina.'})); return; }
  var m = maquinas.filter(function (x) { return x.IdColeta === id; })[0] || {};
  var nome = seguro(m.Hostname || id);
  alvo.appendChild(el('h2', {text: (m.Hostname || id) + ' \u2014 ' + id}));
  alvo.appendChild(el('h2', {text: 'Resumo'}));
  var resumo = f.resumo || {};
  alvo.appendChild(el('div', {'class': 'rolagem'}, [el('table', null, [
    el('thead', null, [el('tr', null, [el('th', {scope: 'col', text: 'Campo'}), el('th', {scope: 'col', text: 'Valor'})])]),
    el('tbody', null, Object.keys(resumo).map(function (k) {
      return el('tr', null, [el('th', {scope: 'row', text: k}), el('td', {text: resumo[k]})]);
    }))])]));
  function secao(titulo, nomeCsv, linhas, colunas, extra, filtro) {
    alvo.appendChild(el('h2', {text: titulo}));
    if (extra) alvo.appendChild(extra);
    var caixa = el('div');
    alvo.appendChild(caixa);
    return montar(caixa, {nome: nomeCsv + '_' + nome, titulo: titulo, linhas: linhas, colunas: colunas, filtro: filtro});
  }
  var comuns = ['Hostname', 'IdEquipamento', 'DataColeta'];
  [['hardware', 'Hardware'], ['volumes', 'Volumes'], ['rede', 'Rede']].forEach(function (p) {
    var ls = lista(f[p[0]]);
    secao(p[1], p[1], ls, sem(colunasDe('ficha_' + p[0], ls), comuns));
  });
  var ign = el('input', {type: 'checkbox', id: 'ficha-mostrar-ignorados'});
  var sw = softwares.filter(function (r) { return r.IdColeta === id; });
  var tsw = secao('Softwares', 'Softwares', sw, sem(colunasDe('softwares', sw), ['IdColeta', 'Hostname', 'IdEquipamento']),
    el('div', {'class': 'controles'}, [el('label', null, [ign, ' Mostrar ignorados'])]),
    function (r) { return ign.checked || r.Ignorar !== 'Sim'; });
  ign.addEventListener('change', tsw.atualizar);
  var ve = vestigios.filter(function (r) { return r.IdColeta === id; });
  secao('Vestígios sem instalação', 'Vestigios', ve, sem(colunasDe('vestigios', ve), ['IdColeta', 'Hostname', 'IdEquipamento']));
  var ins = lista(f.instaladores);
  secao('Instaladores', 'Instaladores', ins, sem(colunasDe('ficha_instaladores', ins), comuns));
}
function abrirFicha(id) {
  var aba = document.getElementById('aba-ficha');
  ativar(aba, false);
  document.getElementById('escolha-maquina').value = id;
  desenharFicha(id);
  window.scrollTo(0, 0);
}

ativar(abas[0], false);
})();
</script>
</body>
</html>
'''


# === CLI ===

FORMATO_LOG = '%(asctime)s [%(levelname)s] %(message)s'


def _agora() -> datetime:
    return datetime.now()


class _ArquivoLog(logging.FileHandler):
    """FileHandler que grava em UTF-8 com BOM e CRLF."""

    def _open(self):
        return open(self.baseFilename, self.mode, encoding=self.encoding, newline='\r\n')


def _criar_pasta_saida(saida_base: Path) -> Path:
    Path(saida_base).mkdir(parents=True, exist_ok=True)
    base = f"Consolidacao_{_agora().strftime('%Y%m%d%H%M%S')}"
    n = 1
    while True:
        pasta = Path(saida_base) / (base if n == 1 else f'{base}_{n}')
        try:
            pasta.mkdir()
            return pasta
        except FileExistsError:
            n += 1


def _log_verificacao(v: Verificacao, c: Coleta) -> None:
    lado = {True: 'confere', False: 'diverge', None: 'ausente'}[v.hash_confere]
    manifesto = {True: 'confere', False: 'diverge', None: 'nao verificado'}[v.manifesto_confere]
    if v.erro_fatal:
        resumo = v.erro_fatal
    elif c.resumo:
        resumo = 'ok'
    else:
        resumo = c.motivo or 'nao carregado'
    log.info('%s: hash do ZIP %s; .zip.sha256 %s; manifesto %s; resumo %s; situacao %s%s',
             v.id_coleta, v.hash_zip or '-', lado, manifesto, resumo, c.situacao,
             f' ({c.motivo})' if c.motivo else '')


def _tabela_vazia(colunas: Sequence[str]) -> tuple:
    return (list(colunas), [])


CODIGO_INCOMPLETA = 3


def _gravar_alertas_emergencia(con: Optional[sqlite3.Connection], pasta_csv: Path,
                               alertas: List[Alerta]) -> None:
    """Melhor esforco depois de erro inesperado: grava A_Alertas no CSV e no SQLite."""
    linhas = [{'Tipo': a.tipo, 'IdColeta': a.id_coleta, 'Hostname': a.hostname,
               'IdEquipamento': a.id_equipamento, 'Mensagem': a.mensagem} for a in alertas]
    try:
        escrever_csv(pasta_csv / 'A_Alertas.csv', COLUNAS_ALERTAS, linhas)
    except Exception:
        log.exception('Nao foi possivel gravar A_Alertas.csv')
    if con is not None:
        try:
            gravar_tabela(con, 'alertas', COLUNAS_ALERTAS, linhas)
        except Exception:
            log.exception('Nao foi possivel gravar a tabela alertas')


def consolidar(entrada: Path, saida_base: Path, mapa: Mapa, aceitar_nao_verificadas: bool,
               linha_comando: str, console: bool = False) -> Tuple[int, Path]:
    inicio = time.monotonic()
    entrada = Path(entrada)
    pasta = _criar_pasta_saida(Path(saida_base))
    pasta_csv = pasta / 'csv'
    handlers: List[logging.Handler] = [_ArquivoLog(str(pasta / 'Consolidacao.log'),
                                                   encoding='utf-8-sig')]
    if console:
        handlers.append(logging.StreamHandler(sys.stderr))
    for h in handlers:
        h.setFormatter(logging.Formatter(FORMATO_LOG))
        log.addHandler(h)
    nivel_anterior = log.level
    log.setLevel(logging.INFO)
    con: Optional[sqlite3.Connection] = None
    codigo = 0
    coletas: List[Coleta] = []
    alertas: List[Alerta] = []
    try:
        pasta_csv.mkdir()
        agora = _agora().strftime('%Y-%m-%d %H:%M:%S')
        sistema = platform.platform()
        log.info('ConsolidaColetas %s', VERSAO)
        log.info('Autor: %s <%s>', AUTOR, EMAIL_AUTOR)
        log.info('SHA-256 do script: %s', sha256_arquivo(Path(__file__)))
        log.info('Linha de comando: %s', linha_comando)
        log.info('Python %s; %s', platform.python_version(), sistema)
        log.info('Pasta de entrada: %s', entrada)
        log.info('Mapa: %s (SHA-256 %s)', mapa.origem, mapa.sha256)
        log.info('Aviso: %s', AVISO_CRUZAMENTO)

        con = abrir_base(pasta / 'Consolidacao.sqlite')
        zips = descobrir_zips(entrada)
        log.info('Coletas encontradas: %d', len(zips))
        for z in zips:
            try:
                v = verificar_zip(z)
            except Exception as e:
                log.exception('Erro ao verificar %s', z.name)
                v = Verificacao(arquivo=z, id_coleta=z.name[:-4], erro_fatal=f'ZIP ilegivel: {e}')
            situacao, motivo = situacao_inicial(v, aceitar_nao_verificadas)
            c, al = carregar_coleta(con, v, situacao, motivo)
            coletas.append(c)
            alertas.extend(al)
        alertas.extend(selecionar_coletas(coletas))
        for c in coletas:
            _log_verificacao(c.verificacao, c)
            if c.situacao in ('Usada', 'NaoVerificada', 'Substituida'):
                log.info('%s: %s%s', c.id_coleta, c.situacao,
                         f' ({c.motivo_selecao})' if c.motivo_selecao else '')
        gravar_coletas(con, coletas)
        criar_indices_e_views(con)
        usadas = [c for c in coletas if c.situacao in ('Usada', 'NaoVerificada')]
        log.info('Coletas usadas: %d de %d', len(usadas), len(coletas))

        erros = 0

        def falha(nome: str) -> None:
            nonlocal erros
            erros += 1
            log.exception('Erro na analise %s', nome)
            alertas.append(Alerta('ErroAnalise', '', '', '',
                                  f'Analise {nome} falhou: {sys.exc_info()[1]}'))

        spm: List[dict] = []
        vest: List[dict] = []
        sw_ok = True
        try:
            for c in usadas:
                spm.extend(softwares_da_coleta(con, c, mapa))
        except Exception:
            falha('softwares')
            sw_ok = False
            spm = []
        vest_ok = sw_ok
        if sw_ok:
            try:
                for c in usadas:
                    vest.extend(vestigios_da_coleta(
                        con, c, [r for r in spm if r['IdColeta'] == c.id_coleta], mapa))
            except Exception:
                falha('vestigios')
                vest_ok = False
                vest = []
        analises: Dict[str, tuple] = {}

        def familia(chave: str, colunas: Sequence[str], fn) -> None:
            try:
                analises[chave] = fn()
            except Exception:
                falha(chave)
                analises[chave] = _tabela_vazia(colunas)

        familia('A_Coletas', COLUNAS_COLETAS,
                lambda: (COLUNAS_COLETAS, linhas_coletas(coletas)))
        familia('A_Catalogo_Softwares', COLUNAS_CATALOGO,
                lambda: (COLUNAS_CATALOGO, catalogo(spm)))
        familia('A_Matriz_Softwares', ('Produto', 'Fabricante', 'Categoria'),
                lambda: matriz(spm, usadas))
        familia('A_Softwares_Por_Maquina', COLUNAS_SPM, lambda: (COLUNAS_SPM, spm))
        familia('A_Vestigios_Sem_Instalacao', COLUNAS_VESTIGIOS,
                lambda: (COLUNAS_VESTIGIOS, vest))
        familia('A_Vestigios_Sem_Instalacao_Por_Produto', COLUNAS_VESTIGIOS_PRODUTO,
                lambda: (COLUNAS_VESTIGIOS_PRODUTO, vestigios_por_produto(vest)))
        familia('A_Instaladores', COLUNAS_INSTALADORES,
                lambda: (COLUNAS_INSTALADORES, instaladores(con, usadas)))
        familia('A_Licencas', COLUNAS_LICENCAS,
                lambda: (COLUNAS_LICENCAS, licencas(con, usadas)))
        familia('A_Softwares_Nao_Mapeados', COLUNAS_NAO_MAPEADOS,
                lambda: (COLUNAS_NAO_MAPEADOS, nao_mapeados(
                    [r for r in spm if not r['_Mapeado']],
                    [r for r in vest if not r['_Mapeado']])))
        log.info('Softwares por maquina: %d; vestigios sem instalacao: %d%s', len(spm), len(vest),
                 '' if vest_ok else ' (analise falhou)')

        def linhas_alertas():
            return [{'Tipo': a.tipo, 'IdColeta': a.id_coleta, 'Hostname': a.hostname,
                     'IdEquipamento': a.id_equipamento, 'Mensagem': a.mensagem}
                    for a in alertas]

        familia('A_Alertas', COLUNAS_ALERTAS, lambda: (COLUNAS_ALERTAS, linhas_alertas()))
        for a in alertas:
            if a.tipo != 'Substituida':
                log.warning('Alerta %s: %s %s', a.tipo, a.id_coleta, a.mensagem)
        log.info('Alertas: %d', len(alertas))

        execucao = {
            'VersaoScript': VERSAO, 'Autor': AUTOR, 'EmailAutor': EMAIL_AUTOR, 'Data': agora,
            'PastaEntrada': str(entrada), 'LinhaComando': linha_comando,
            'AceitarNaoVerificadas': 'Sim' if aceitar_nao_verificadas else 'Nao',
            'MapaOrigem': mapa.origem, 'MapaSha256': mapa.sha256,
            'MapaCodificacao': mapa.codificacao, 'Python': platform.python_version(),
            'SistemaOperacional': sistema,
        }
        erros_saida = 0

        def etapa(nome: str, fn) -> None:
            nonlocal erros_saida
            try:
                fn()
            except Exception:
                erros_saida += 1
                log.exception('Erro na etapa de saida %s', nome)
                alertas.append(Alerta('ErroAnalise', '', '', '',
                                      f'Etapa {nome} falhou: {sys.exc_info()[1]}'))

        etapa('gravar_analises', lambda: gravar_analises(con, analises))
        etapa('gravar_mapa_e_execucao', lambda: gravar_mapa_e_execucao(con, mapa, execucao))
        etapa('exportar_consolidados', lambda: exportar_consolidados(con, pasta_csv))
        etapa('exportar_analises', lambda: exportar_analises(pasta_csv, analises))
        etapa('gerar_html', lambda: gerar_html(pasta / 'Relatorio.html',
                                               dados_html(con, coletas, analises, execucao)))
        etapa('commit', con.commit)
        if erros_saida:
            # Melhor esforco: registra os alertas de erro nas saidas que ainda forem possiveis.
            analises['A_Alertas'] = (COLUNAS_ALERTAS, linhas_alertas())
            etapa('regravar_alertas', lambda: (
                gravar_tabela(con, 'alertas', COLUNAS_ALERTAS, linhas_alertas()),
                escrever_csv(pasta_csv / 'A_Alertas.csv', COLUNAS_ALERTAS, linhas_alertas()),
                con.commit()))
        if (any(c.situacao in ('Rejeitada', 'NaoVerificada') for c in coletas)
                or erros or erros_saida):
            codigo = 1
        log.info('Saidas gravadas em %s', pasta)
        log.info('Codigo de saida: %d; tempo total: %.1f s', codigo, time.monotonic() - inicio)
    except Exception as e:
        codigo = CODIGO_INCOMPLETA
        log.exception('Erro inesperado; consolidacao incompleta')
        alertas.append(Alerta('ErroInesperado', '', '', '',
                              f'Erro inesperado; consolidacao incompleta: {e}'))
        _gravar_alertas_emergencia(con, pasta_csv, alertas)
        log.info('Codigo de saida: %d (consolidacao incompleta); tempo total: %.1f s', codigo,
                 time.monotonic() - inicio)
    finally:
        if con is not None:
            con.close()
        for h in handlers:
            log.removeHandler(h)
            h.close()
        log.setLevel(nivel_anterior)
    escrever_sha256sums(pasta)
    return codigo, pasta


class _FormatoAjuda(argparse.HelpFormatter):
    def add_usage(self, usage, actions, groups, prefix=None):
        return super().add_usage(usage, actions, groups, 'uso: ' if prefix is None else prefix)


_TRADUCOES_ARGPARSE = (
    (re.compile(r'^unrecognized arguments: (.*)$'), r'argumentos nao reconhecidos: \1'),
    (re.compile(r'^argument (\S+): expected one argument$'), r'o argumento \1 exige um valor'),
    (re.compile(r'^the following arguments are required: (.*)$'),
     r'argumentos obrigatorios ausentes: \1'),
    (re.compile(r'^argument (\S+): ignored explicit argument (.*)$'),
     r'o argumento \1 nao aceita valor: \2'),
    (re.compile(r'^ambiguous option: (\S+) could match (.*)$'),
     r'opcao ambigua: \1 pode ser \2'),
)


class _Parser(argparse.ArgumentParser):
    """ArgumentParser com mensagens em portugues."""

    def error(self, message):
        for rx, trad in _TRADUCOES_ARGPARSE:
            if rx.match(message):
                message = rx.sub(trad, message)
                break
        self.print_usage(sys.stderr)
        self.exit(2, f'Erro: {message}\n')


def _montar_parser() -> argparse.ArgumentParser:
    p = _Parser(
        prog='ConsolidaColetas.py', add_help=False, formatter_class=_FormatoAjuda,
        description='Consolida pacotes InventarioForense_*.zip em tabelas CSV, SQLite e relatorio HTML.')
    p._positionals.title = 'argumentos posicionais'
    p._optionals.title = 'opcoes'
    p.add_argument('-h', '--help', '--ajuda', action='help', default=argparse.SUPPRESS,
                   help='mostra esta ajuda e termina')
    p.add_argument('pasta_entrada', nargs='?',
                   help='pasta com os InventarioForense_*.zip e .zip.sha256 (nao recursiva)')
    p.add_argument('-o', dest='saida', metavar='PASTA_SAIDA',
                   help='pasta onde sera criada Consolidacao_<AAAAMMDDHHMMSS>/ '
                        '(padrao: a pasta de entrada)')
    p.add_argument('--mapa', metavar='ARQUIVO.csv',
                   help='mapa de softwares (padrao: MapaSoftwares.csv ao lado do script; '
                        'se nao existir, o mapa embutido)')
    p.add_argument('--aceitar-nao-verificadas', action='store_true',
                   help='inclui coletas sem .zip.sha256 ou com divergencia, como NaoVerificada')
    p.add_argument('--gerar-mapa', metavar='ARQUIVO.csv',
                   help='grava o mapa embutido no arquivo indicado (sem sobrescrever) e termina')
    return p


def _saida_gravavel(pasta: Path) -> bool:
    """Verifica se da para gravar em `pasta` sem criar nada."""
    try:
        alvo = pasta
        while not alvo.exists():
            if alvo.parent == alvo:
                return False
            alvo = alvo.parent
        if not alvo.is_dir():
            return False
        if alvo == pasta:
            with tempfile.TemporaryFile(dir=str(pasta)):
                pass
            return True
        return os.access(alvo, os.W_OK | os.X_OK)
    except OSError:
        return False


def main(argv=None) -> int:
    def erro(msg: str) -> int:
        print(f'Erro: {msg}', file=sys.stderr)
        return 2

    parser = _montar_parser()
    try:
        args = parser.parse_args(argv)
    except SystemExit as e:
        return e.code if isinstance(e.code, int) else 2
    if args.gerar_mapa:
        destino = Path(args.gerar_mapa)
        if destino.exists():
            return erro(f'o arquivo {destino} ja existe; nao sera sobrescrito')
        try:
            gerar_mapa(destino)
        except OSError as e:
            return erro(f'nao foi possivel gravar {destino}: {e}')
        print(f'Mapa gravado em {destino}')
        return 0
    if not args.pasta_entrada:
        return erro('informe a pasta de entrada')
    entrada = Path(args.pasta_entrada)
    if not entrada.is_dir():
        return erro(f'a pasta de entrada {entrada} nao existe')
    if not descobrir_zips(entrada):
        return erro(f'nenhum InventarioForense_*.zip em {entrada}')
    try:
        mapa = Mapa.carregar(Path(args.mapa) if args.mapa else None,
                             Path(__file__).resolve().parent)
    except (ErroMapa, OSError) as e:
        return erro(str(e))
    saida = Path(args.saida) if args.saida else entrada
    if not _saida_gravavel(saida):
        return erro(f'a pasta de saida {saida} nao aceita gravacao')
    if argv is None:
        linha = shlex.join(sys.argv)
    else:
        linha = shlex.join(['ConsolidaColetas.py'] + [str(a) for a in argv])
    try:
        codigo, pasta = consolidar(entrada, saida, mapa, args.aceitar_nao_verificadas, linha,
                                   console=True)
    except Exception as e:
        traceback.print_exc(file=sys.stderr)
        print(f'Erro inesperado; consolidacao incompleta: {e}', file=sys.stderr)
        return CODIGO_INCOMPLETA
    if codigo == CODIGO_INCOMPLETA:
        print(f'Erro inesperado; consolidacao incompleta em {pasta} (veja o Consolidacao.log)',
              file=sys.stderr)
    else:
        print(f'Consolidacao gravada em {pasta}', file=sys.stderr)
    return codigo


if __name__ == '__main__':
    sys.exit(main())
