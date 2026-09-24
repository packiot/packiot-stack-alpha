# Roteiro de demonstração — Bispharma (staging)

> Ambiente preparado em 24/09/2026. Tudo abaixo é a visão **real** da Bispharma (dados do
> box da fábrica), em **pt-BR**. Duração sugerida: **25 min + perguntas**.

## 1. Antes da demo (15 min antes)

| Passo | Como |
|---|---|
| Ensaio automático | `cd e2e && npm run creds && npm run demo:bispharma` → **7/7 verdes**. Capturas em `e2e/demo-shots/bispharma/`. |
| Horário | **Evite a 1ª hora após a troca de turno** (o turno atual é montado por hora e aparece zerado): SP **05:00 / 13:30 / 22:00**, BISNAGO **06:00 / 14:20 / 22:35** (horário de Brasília). |
| Endereços | front4: **https://front.staging.packiot.app** (NUNCA `staging.packiot.com`: ali os gráficos do Superset falham, cookie de terceiros). Operador: **https://operator-bispharma.staging.packiot.app** (NUNCA o `operator.staging…`, que é da CPACK). |
| Login | Usuário QA Bispharma (`qa-bispharma-staging@packiot.com`, senha em Secrets Manager `packiot/staging/e2e-test-creds` → `clients.bispharma`). Idioma já em pt-BR. |
| Abas | Abra front4 (Home), o Operador (linha **L01** ou a linha que estiver rodando) e deixe os Relatórios carregando numa 3ª aba. |
| Período | Nos filtros de data use **"Essa Semana"**, não "Esse Mês" (o início de setembro ainda tem dados de antes das correções). |

## 2. Roteiro

### 2.1 Abertura — Home (1 min)
"Bom dia/Boa tarde" já no idioma do usuário. Dois sites: **SP** (linhas L01–L20) e **BISNAGO SP** (L56–L90). Cada quadrado é uma linha, com a cor do status ao vivo.

### 2.2 Torre de Controle (4 min)
- Status ao vivo por linha: **velocidade (un/min)**, produção e OEE do **turno atual**, **turno anterior**.
- Ponto-chave: **zero digitação**. Tudo vem do CLP pelo box na fábrica.
- Linha do tempo das últimas 24 h: rodando, baixa velocidade ou parada.

### 2.3 OEE — Essa Semana (5 min)
Números de referência (semana até 24/09): **OEE ≈ 70%**, Disponibilidade ≈ 85%, Performance ≈ 83%, Qualidade ≈ 99,8%.
- **Performance** é medida contra o **melhor ritmo demonstrado pela própria linha** (p90 de 14 dias). Frase: *"Hoje comparamos cada linha com o melhor ritmo que ela mesma já mostrou. Com as velocidades nominais de placa de vocês, o número passa a ser absoluto."* → **pedir as velocidades nominais**.
- **Qualidade**: diferença entre entrada e saída da linha. O refugo medido direto (sinal de refugo do CLP) é o próximo passo de integração.

### 2.4 Paradas — Essa Semana (6 min) · momento "uau"
- ~85% do tempo executando, ~15% parado. **Paradas detectadas automaticamente** (ninguém precisou apontar).
- **AO VIVO:** na tabela *Detalhes de paradas*, lápis ✎ em uma parada → **Máquina** → **Categoria** (Falha de Equipamento, Parada Planejada, Problema de Processo, Ociosidade/Espera, Troca de Produto/Setup) → **Sub-categoria** → **EDITAR**. O gráfico *Motivos de paradas* (Pareto) passa a mostrar a causa.
- Alternativa no chão de fábrica: no **Operador → Eventos**, as paradas pendentes da linha aparecem para o operador justificar.

### 2.5 Operador — iniciar uma OP ao vivo (4 min)
- Operador (Bispharma) → **Produção** → *Escolha uma Ordem de Produção* → **Criar uma Ordem de Produção** → nome/número da OP (ex.: um número real deles) + quantidade → **CONFIRMAR** → "Sucesso! aguarde a sincronização dos dados".
- Volte à **Torre de Controle**: a OP aparece na linha, com o planejado e a produção acumulando.

### 2.6 Relatórios — Superset em pt-BR (4 min)
*Visão Geral de OEE*: velocímetro do turno, cartões D/P/Q, **tendência horária**, abas **Produção / Paradas / Ordens**. Mensagem: self-service. Eles filtram e exportam sem pedir relatório para a TI.

### 2.7 Fechamento — próximos passos (1 min)
1. **Velocidades nominais** por linha → Performance/OEE absolutos.
2. **Sinal de refugo** do CLP → Qualidade medida.
3. **L58 / L60**: CLPs sem comunicação (detectado automaticamente); religar.
4. **Leitor de caixas** (recurso-chave deles): entra quando o leitor estiver online.
5. Operadores: usuários e treinamento no Operador.

## 3. Evitar

| Não mostrar | Por quê |
|---|---|
| `staging.packiot.com` | Relatórios quebram (CSRF / cookie de terceiros). Use `front.staging.packiot.app`. |
| `operator.staging.packiot.app` | É o operador da CPACK: não vê paradas da Bispharma e bloqueia as escritas. |
| "Esse Mês" | Início de setembro com dados pré-correção. |
| 1ª hora após troca de turno | Turno atual zerado até fechar a 1ª hora. |
| L58, L60 | Sem dados (CLP offline). Se perguntarem: "a plataforma detectou a queda de comunicação". |
| Dashboard "Scanned Boxes" | Sem dados reais ainda (o leitor não está online; os dados simulados foram removidos). |
| Trocar de empresa (super-admin) | O seletor lista outros clientes. Nunca na frente do cliente. |

## 4. Perguntas prováveis

- **"Precisa de operador apontando?"** Não. Produção, velocidade, paradas e OEE vêm do CLP. O operador só **justifica** paradas e **gerencia OPs**.
- **"De onde vem a meta (% da meta)?"** Meta padrão = 85% (OEE de classe mundial) × velocidade de referência. Pode ser customizada por linha e turno.
- **"Os dados são em tempo real?"** Sim: status/velocidade por minuto, OEE do turno consolidado continuamente.
- **"E se a internet cair?"** O box guarda e reenvia (buffer local).
- **"Integra com nosso ERP?"** Sim: conector de banco de dados/ERP para importar OPs.

## 5. Se algo der errado

- **Relatórios com erro** → confira o endereço (`front.staging…`); recarregue.
- **Turno atual zerado** → mostre "Turno anterior" e *Essa Semana*.
- **Operador em inglês / sem dados** → confira que é `operator-bispharma.staging…`; recarregue após o login.
- **Algo em inglês logo após o login** → navegue para outra página e volte (o pacote de idioma carrega em 1–2 s).

## 6. Depois da demo

- Justificativas e OPs criadas ao vivo ficam nos dados da Bispharma (staging). Se quiser limpar: `db/migrations/t-ent5-demo-readiness` mostra o padrão (backup antes de apagar).
- Pendências técnicas: ver o PR #1426 (seletor de justificativa do front4 para a CPACK, cookie Partitioned do Superset para `staging.packiot.com`, idioma em deep-link).
