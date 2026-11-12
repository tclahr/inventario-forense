<div align="center">

# 🔎 InventarioForense

**Coleta de inventário e vestígios de software em estações Windows — e consolidação de tudo em uma única base consultável.**

![PowerShell](https://img.shields.io/badge/PowerShell-5.1-5391FE?logo=powershell&logoColor=white)
![Python](https://img.shields.io/badge/Python-3.10%2B-3776AB?logo=python&logoColor=white)
![Plataforma](https://img.shields.io/badge/coleta-Windows%2010%20%2F%2011-0078D4?logo=windows&logoColor=white)
![Licença](https://img.shields.io/badge/licen%C3%A7a-Apache%202.0-D22128)

</div>

---

## 📌 O que é

O projeto tem **duas ferramentas** que trabalham em sequência:

| Etapa | Ferramenta | Onde roda | O que faz |
|:-----:|------------|-----------|-----------|
| 1️⃣ | [`InventarioForense.ps1`](InventarioForense.ps1) | Em **cada** estação Windows | Coleta hardware, sistema, contas, softwares, rede, licenças e vestígios de uso. Gera um **ZIP** com hash SHA-256. |
| 2️⃣ | [`ConsolidaColetas.py`](ConsolidaColetas.py) | No **seu** computador (Windows, Linux ou macOS) | Junta todos os ZIPs numa base **SQLite**, planilhas **CSV** e um **relatório HTML**. |

```
  🖥️ PC 01 ─┐
  🖥️ PC 02 ─┼─►  InventarioForense_*.zip  ─►  ConsolidaColetas.py  ─►  📊 Relatorio.html
  🖥️ PC 03 ─┘     (um por máquina)                                      🗄️ Consolidacao.sqlite
                                                                         📑 CSVs de análise
```

### ✨ Destaques

- 🔒 **Somente leitura** — não instala nada e não altera a máquina inspecionada.
- 🧾 **Cadeia de custódia** — cada ZIP traz manifesto `SHA256SUMS.txt` e um arquivo `.zip.sha256`; o consolidador confere tudo e rejeita pacotes adulterados.
- 🆔 **ID estável do equipamento** — calculado a partir de UUID, BIOS, placa e discos; reconhece a mesma máquina em coletas diferentes.
- 🧩 **Falhas isoladas** — se uma fonte falhar, as demais continuam e o problema fica registrado.
- 📦 **Sem dependências** — PowerShell nativo do Windows e biblioteca padrão do Python.

---

## 🧰 Parte 1 — Coletar: `InventarioForense.ps1`

### Requisitos

- Windows 10 ou 11 com **Windows PowerShell 5.1** (já vem no sistema).
- Executar como **Administrador** (recomendado). Sem admin a coleta roda, mas **pula** as fontes que exigem privilégio (Amcache, Prefetch, BitLocker, hives de outros usuários…). Isso fica registrado no resultado.
- A pasta do script precisa aceitar gravação (pendrive ou HD externo funcionam bem).

### Passo a passo

**1. Abra o PowerShell como Administrador** — Menu Iniciar → digite `PowerShell` → botão direito → *Executar como administrador*.

**2. Vá até a pasta do script** (exemplo: pendrive na unidade `E:`):

```powershell
cd E:\InventarioForense
```

**3. Execute** (o `-ExecutionPolicy Bypass` vale só para esta execução e não altera a máquina):

```powershell
powershell -ExecutionPolicy Bypass -File .\InventarioForense.ps1 -Etiqueta "PAT-0001" -Setor "Financeiro" -ExecutadoPor "Seu Nome"
```

Acompanhe o progresso na tela. O script **não faz perguntas**.

### Parâmetros

Todos são opcionais. Use aspas quando o valor tiver espaços.

| Parâmetro | Descrição |
|-----------|-----------|
| `-Etiqueta` | Patrimônio ou identificação do equipamento. Entra no nome do arquivo. |
| `-Setor` | Setor ou local onde o equipamento está. |
| `-ExecutadoPor` | Nome de quem executa a coleta. |
| `-Observacao` | Texto livre registrado junto com a coleta. |
| `-Completa` | Varredura completa dos discos fixos atrás de instaladores. Demora mais. |

**Coleta completa:**

```powershell
powershell -ExecutionPolicy Bypass -File .\InventarioForense.ps1 -Etiqueta "PAT-0001" -Completa -Observacao "Coleta após troca de disco"
```

<details>
<summary><b>⚠️ O Windows bloqueou o script? Clique aqui</b></summary>

<br>

- **Arquivo veio da internet, e-mail ou ZIP baixado?** Desbloqueie uma vez:
  ```powershell
  Unblock-File .\InventarioForense.ps1
  ```
- **Prefere liberar a janela inteira?** (a permissão termina ao fechá-la)
  ```powershell
  Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
  .\InventarioForense.ps1
  ```
- ❌ **Nunca** use `Set-ExecutionPolicy` sem `-Scope Process`: isso muda a configuração permanente da máquina do cliente.
- **Ainda dá erro?** Pode haver política de grupo (GPO). Confira com `Get-ExecutionPolicy -List`. Se `MachinePolicy` ou `UserPolicy` estiver como `AllSigned` ou `RemoteSigned`, peça liberação à TI do cliente.

</details>

### O que é coletado

| | |
|---|---|
| 🖥️ Resumo, hardware e volumes (com BitLocker) | 🌐 Interfaces de rede, IPs, MAC, DNS, DHCP |
| 👤 Contas locais e perfis de usuário | 📦 Software instalado (registro, MSI, Appx) |
| 🕵️ Vestígios: Amcache, Prefetch, ShimCache, UserAssist, BAM, MUICache, atalhos, eventos MSI | 🔑 Licenças e ativação do Windows |
| ⚙️ Serviços, tarefas agendadas, drivers | 🩹 Atualizações instaladas |
| 📁 Pastas de programas e arquivos instaladores (com SHA-256) | 🗂️ Varredura completa dos discos (`-Completa`) |

### Resultado

Ao terminar, ficam na pasta do script:

```
InventarioForense_<HOST>_<Etiqueta>_<AAAAMMDDHHMMSS>.zip
InventarioForense_<HOST>_<Etiqueta>_<AAAAMMDDHHMMSS>.zip.sha256
```

O ZIP contém `Coleta.txt`, `Coleta.json`, `Coleta.log`, os CSVs (`csv/01_Resumo.csv` … `16_Arquivos_Completa.csv`), as cópias brutas (`brutos/`) e o `SHA256SUMS.txt`. A pasta temporária é apagada depois que o ZIP é verificado.

### Códigos de saída

Veja com `$LASTEXITCODE`:

| Código | Significado |
|:------:|-------------|
| `0` | ✅ Coleta concluída e ZIP verificado. |
| `1` | ❌ Falha na verificação do ZIP. A pasta foi mantida. |
| `2` | ⛔ A pasta do script não aceita gravação. Nada foi gravado. |
| `3` | ⚠️ Coleta incompleta, mas ZIP gerado e verificado. Veja o `Coleta.log`. |

### Conferir o hash do ZIP

```powershell
# Windows
Get-FileHash .\InventarioForense_*.zip -Algorithm SHA256
Get-Content  .\InventarioForense_*.zip.sha256     # os dois valores devem ser iguais
```

```bash
# Linux ou Git Bash
sha256sum -c InventarioForense_*.zip.sha256
```

---

## 📊 Parte 2 — Consolidar: `ConsolidaColetas.py`

Depois de coletar várias máquinas, reúna os ZIPs (e os `.zip.sha256`) **numa mesma pasta** e rode o consolidador.

### Requisitos

- **Python 3.10 ou superior**. Nenhuma biblioteca extra.

### Uso rápido

```bash
python3 ConsolidaColetas.py /caminho/para/pasta_com_os_zips
```

Será criada a pasta `Consolidacao_<AAAAMMDDHHMMSS>/` dentro da pasta de entrada. Para gravar em outro lugar, use `-o`:

```bash
python3 ConsolidaColetas.py ./coletas -o ./relatorios
```

### Opções

| Opção | Descrição |
|-------|-----------|
| `pasta_entrada` | Pasta com os `InventarioForense_*.zip` e `.zip.sha256` (não recursiva). |
| `-o PASTA_SAIDA` | Onde criar `Consolidacao_<data>/`. Padrão: a própria pasta de entrada. |
| `--mapa ARQUIVO.csv` | Mapa de softwares a usar. Padrão: `MapaSoftwares.csv` ao lado do script; se não existir, o mapa embutido. |
| `--aceitar-nao-verificadas` | Inclui coletas sem `.zip.sha256` ou com hash divergente, marcadas como `NaoVerificada`. |
| `--gerar-mapa ARQUIVO.csv` | Grava o mapa embutido no arquivo indicado (sem sobrescrever) e termina. |
| `-h`, `--help`, `--ajuda` | Mostra a ajuda. |

### O que o consolidador faz

1. 🔐 **Verifica** cada ZIP: hash contra o `.zip.sha256` e todos os arquivos contra o `SHA256SUMS.txt`. Pacotes inválidos são **rejeitados** (e listados nos alertas).
2. 🆔 **Agrupa por equipamento** (`IdEquipamento`). Se a mesma máquina foi coletada mais de uma vez, mantém a melhor coleta — preferindo modo *Completa*, com *admin* e a mais recente — e marca as demais como `Substituida`.
3. 🧮 **Normaliza nomes de software** usando o mapa (`MapaSoftwares.csv`), tirando versões, arquitetura e idioma, e classificando por produto, fabricante e categoria.
4. 🧾 **Cruza** instalados × vestígios para achar programas que deixaram rastro mas não aparecem como instalados.
5. 📤 **Gera** base SQLite, CSVs e relatório HTML.

### Resultado

```
Consolidacao_20260101120000/
├── Relatorio.html            ← abra no navegador (funciona offline)
├── Consolidacao.sqlite       ← base completa para consultas SQL
├── Consolidacao.log          ← registro da execução
├── SHA256SUMS.txt            ← hashes dos arquivos gerados
└── csv/
    ├── 01_Resumo.csv … 16_Arquivos_Completa.csv   ← dados de todas as máquinas juntos
    ├── A_Coletas.csv                              ← situação de cada ZIP processado
    ├── A_Catalogo_Softwares.csv                   ← produtos e em quantas máquinas aparecem
    ├── A_Matriz_Softwares.csv                     ← produto × máquina (versão instalada)
    ├── A_Softwares_Por_Maquina.csv
    ├── A_Vestigios_Sem_Instalacao.csv             ← rastro de uso sem instalação
    ├── A_Vestigios_Sem_Instalacao_Por_Produto.csv
    ├── A_Instaladores.csv
    ├── A_Licencas.csv
    ├── A_Softwares_Nao_Mapeados.csv               ← sugestões para ampliar o mapa
    └── A_Alertas.csv                              ← falhas, coletas sem admin, rejeições…
```

> Os CSVs usam `;` como separador e UTF-8 com BOM — abrem direto no Excel.

### Situação de cada coleta

| Situação | Significa |
|----------|-----------|
| `Usada` | Verificada e escolhida para os relatórios. |
| `Substituida` | Verificada, mas havia coleta melhor da mesma máquina. |
| `NaoVerificada` | Sem hash ou divergente; só entra com `--aceitar-nao-verificadas`. |
| `Rejeitada` | ZIP ilegível, adulterado ou sem o resumo. Não entra na base. |

### Personalizando o mapa de softwares

O `MapaSoftwares.csv` ensina o consolidador a reconhecer produtos e descartar ruído (runtimes, componentes do Windows, drivers…).

```bash
# Gera uma cópia editável do mapa embutido
python3 ConsolidaColetas.py --gerar-mapa MeuMapa.csv

# Usa o mapa editado
python3 ConsolidaColetas.py ./coletas --mapa MeuMapa.csv
```

Formato (separador `;`, cabeçalho obrigatório):

```csv
Padrao;Produto;Fabricante;Categoria;Ignorar
Microsoft.VCLibs*;;;Runtime;Sim
re:^Google Chrome;Google Chrome;Google;Navegador;Nao
```

- **`Padrao`** — texto com curingas (`*` e `?`) ou expressão regular iniciada por `re:`. A primeira regra que casar vence.
- **`Produto` / `Fabricante` / `Categoria`** — como o item deve aparecer. Em branco, mantém o valor original.
- **`Ignorar`** — `Sim` tira o item da matriz de softwares.

💡 **Dica:** rode uma vez, abra `A_Softwares_Nao_Mapeados.csv`, copie as linhas úteis para o seu mapa e rode de novo.

### Códigos de saída

| Código | Significado |
|:------:|-------------|
| `0` | ✅ Consolidação concluída. |
| `2` | ⛔ Erro de uso: pasta inexistente, sem ZIPs, mapa inválido ou saída sem permissão de escrita. |
| `3` | ⚠️ Erro inesperado; consolidação incompleta (veja o `Consolidacao.log`). |

---

## 🚀 Exemplo completo

```text
1. Em cada PC (como Administrador):
   powershell -ExecutionPolicy Bypass -File .\InventarioForense.ps1 -Etiqueta "PAT-0001" -Setor "Financeiro"

2. Copie os arquivos .zip e .zip.sha256 de todas as máquinas para a pasta  ./coletas

3. No seu computador:
   python3 ConsolidaColetas.py ./coletas

4. Abra  ./coletas/Consolidacao_<data>/Relatorio.html  no navegador.
```

---

## 📂 Estrutura do repositório

```
├── InventarioForense.ps1    Coletor (Windows PowerShell 5.1)
├── ConsolidaColetas.py      Consolidador (Python 3.10+)
├── MapaSoftwares.csv        Mapa de classificação de softwares
├── LICENSE                  Apache License 2.0
└── tests/                   Testes (Pester em ps1/, unittest em py/)
```

## 📜 Licença

Este projeto é distribuído sob a **[Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0)**.

Você pode usar, copiar, modificar e redistribuir o código, inclusive para fins comerciais, desde que:

- mantenha o aviso de copyright e uma cópia da licença;
- indique as alterações feitas nos arquivos modificados.

> ⚖️ **Uso responsável:** execute o coletor apenas em equipamentos que você tem autorização para inspecionar. As coletas reúnem dados de contas, softwares e atividade de uso que podem ser sensíveis, então armazene os ZIPs com cuidado.

Texto completo no arquivo [`LICENSE`](LICENSE) ou em <https://www.apache.org/licenses/LICENSE-2.0>.

## 👤 Autor

**Thiago Canozzo Lahr** — <thiago@peritoemti.com.br>
