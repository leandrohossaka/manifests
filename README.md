import logging
import os

import dotenv
import pandas as pd
import plotly.graph_objects as go
import streamlit as st
from langchain.prompts import PromptTemplate
from langchain_community.llms import Ollama
from pyathena import connect

import auth as auth
import db_connection as db

dotenv.load_dotenv()

db.create_table()

with open('./assets/theme.css') as f:
    css = f.read()

st.markdown(f'<style>{css}</style>', unsafe_allow_html=True)

# Configuração do logger
log_file = 'log_llm.txt'
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(log_file),
        logging.StreamHandler()
    ]
)


# Configurações do AWS
AWS_ACCESS_KEY = os.getenv('AWS_ACCESS_KEY')
AWS_SECRET_KEY = os.getenv('AWS_SECRET_KEY')
AWS_REGION = os.getenv('AWS_REGION')
S3_STAGING_DIR = os.getenv('S3_STAGING_DIR')
WORK_GROUP = os.getenv('WORK_GROUP')

# Inicia os modelos Ollama
llm_classificador = Ollama(model="llama3", temperature=0.1)
llm_sql = Ollama(model="anbimasql", temperature=0.1)
llm_resposta = Ollama(model="llama3", temperature=0.1)


# Template para classificação da pergunta
template_classificacao = """
Você é um assistente inteligente.
Sabendo que temos uma tabela chamada: 'todos_fundos.dados_anbima' com as seguintes colunas:

- codinst (int): Código da instituição - identificador único para a instituição responsável pelo fundo.
- inst_cnpj (string): CNPJ da instituição - número do Cadastro Nacional da Pessoa Jurídica da instituição responsável pelo fundo.
- inst_razao_social (string): Razão social da instituição - nome oficial da instituição responsável pelo fundo.
- codfundo (int): Código do fundo - identificador único para o fundo de investimento.
- fundo_cnpj (string): CNPJ do fundo - número do Cadastro Nacional da Pessoa Jurídica do fundo de investimento.
- fundo_razao_social (string): Razão social do fundo - nome oficial do fundo de investimento.
- periodo_divulg (int): Período de divulgação - período ao qual os dados se referem.
- codtipo (int): Código do tipo de fundo - identificador do tipo de fundo (por exemplo, renda fixa, ações, multimercado).
- tipo_fundo (string): Tipo do fundo - descrição do tipo de fundo de investimento.
- composicao (string): Composição do fundo - informações sobre a composição dos ativos no fundo.
- data (date): Data referente às informações financeiras.
- pl (float): Patrimônio líquido - valor total do patrimônio líquido do fundo.
- valcota (float): Valor da cota - valor de cada cota do fundo.
- rentdia (float): Rentabilidade diária - rentabilidade do fundo em um dia específico.
- rentmes (float): Rentabilidade mensal - rentabilidade do fundo no mês.
- rentano (float): Rentabilidade anual - rentabilidade do fundo no ano.
- num_cotistas (float): Número de cotistas - número total de cotistas do fundo.
- resgate_total (float): Resgate total - valor total dos resgates efetuados no período.
- captliq (float): Captação líquida - diferença entre a captação e o resgate, ou seja, o valor líquido captado pelo fundo.
- volume_total_aplicacoes (float): Volume total de aplicações - valor total das aplicações no fundo.
- codigo_classe_subclasse (string): Código de classe/subclasse - identificador da classe e subclasse do fundo de investimento.

Classifique a pergunta a seguir em uma das três categorias:

1. **Saudação**: Perguntas que são saudações como "Olá", "Bom dia", "Boa tarde", "Oi", etc.
2. **Gerar SQL**: Perguntas que estão relacionadas a dados e exigem a geração de uma consulta SQL.
3. **Não relacionadas**: Perguntas que não se enquadram nas duas categorias anteriores.

Pergunta: {question}

Classificação:
"""

# Template para geração de SQL a partir da pergunta
template_sql = """
Você é um especialista em Athena AWS. Sua tarefa é gerar consultas SQL ou responder com uma mensagem específica com base na pergunta fornecida. Aqui está o que você deve fazer:

**Geração de Consulta SQL**: Se a pergunta de entrada estiver diretamente relacionada à tabela 'todos_fundos.dados_anbima' e envolver alguma das colunas listadas abaixo, gere uma consulta SQL sintaticamente correta para recuperar as informações solicitadas. Certifique-se de que a consulta:
- Inclua filtros de colunas somente quando mencionado explicitamente na pergunta.
- Não consulte colunas que não existem nas tabelas e use alias somente onde necessário.
- Da mesma forma, quando solicitado sobre média (função AVG) ou razão, garanta que a função de agregação apropriada seja usada.
- Preste atenção aos critérios de filtragem mencionados na pergunta e incorpore-os usando a cláusula WHERE em sua consulta SQL.
- Se a pergunta envolver múltiplas condições, use operadores lógicos como AND, OR para combiná-las de forma eficaz.
- Ao lidar com colunas de data ou timestamp, use funções de data apropriadas (por exemplo, DATE_PART, EXTRACT) para extrair partes específicas da data ou realizar cálculos de data.
- Se a pergunta envolver agrupamento de dados (por exemplo, encontrar totais ou médias para diferentes categorias), use a cláusula GROUP BY juntamente com funções de agregação apropriadas.
- Considere usar aliases para tabelas e colunas para melhorar a legibilidade da consulta, especialmente em caso de joins ou subconsultas complexas.
- Se necessário, use subconsultas ou expressões de tabela comuns (CTEs) para dividir o problema em partes menores e mais gerenciáveis.
- Para períodos específicos, ajuste os filtros de data de acordo com o ano mencionado na pergunta:
- Se a pergunta mencionar '2023', ajuste o intervalo de datas para o ano de 2023.
- Se a pergunta mencionar '2024', ajuste o intervalo de datas para o ano de 2024.
- Ajuste o intervalo de datas conforme necessário, garantindo que as datas estejam dentro do período disponível (abril de 2023 a abril de 2024).

- A consulta deve ser precisa e considerar corretamente os períodos de tempo quando aplicável.
- **Atenção**: A base de dados cobre o período de abril de 2023 a abril de 2024. Qualquer intervalo de tempo solicitado fora desse período deve ser ajustado para os limites disponíveis. 
- Se a pergunta envolver múltiplos meses ou períodos, use funções de agregação apropriadas e agrupe os resultados conforme necessário.
- Forneça apenas a consulta SQL.
- Não forneça explicações ou justificativas.
- Use a função LIMIT 1 somente quando a pergunta solicitar explicitamente a melhor, maior ou única resposta.
- Não use a função CURRENT_DATE. O conjunto de dados cobre o período de abril de 2023 a abril de 2024. Portanto, ao interpretar períodos de tempo relativos, ajuste os intervalos de acordo com os limites disponíveis no conjunto de dados.

**Colunas em 'todos_fundos.dados_anbima'**:
- codinst (int): Código identificador da instituição que administra o fundo.
- inst_cnpj (string): CNPJ da instituição que administra o fundo.
- inst_razao_social (string): Razão social da instituição que administra o fundo.
- codfundo (int): Código identificador do fundo.
- fundo_cnpj (string): CNPJ do fundo.
- fundo_razao_social (string): Razão social do fundo.
- periodo_divulg (int): Período de divulgação dos dados. Valores possíveis: 1 (diária), 28 (mensal) ou 365 (anual).
- codtipo (int): Código identificador do tipo do fundo.
- tipo_fundo (string): Tipo do fundo. Valores possíveis incluem: Multimercados, Renda Fixa, Previdência, FII, FIP, Ações, Cambial, ETF, FIDC, OFF-SHORE.
- composicao (string): Composição do fundo. Valores possíveis incluem: FM, FC, FF, FI.
- data (date): Data das informações no formato date.
- pl (float): Patrimônio líquido do fundo na data especificada.
- valcota (float): Valor da cota do fundo na data especificada.
- rentdia (float): Rentabilidade diária do fundo.
- rentmes (float): Rentabilidade mensal do fundo.
- rentano (float): Rentabilidade anual do fundo.
- num_cotistas (float): Número de cotistas do fundo na data especificada.
- total_redemption (float): Valor total dos resgates realizados no fundo na data especificada.
- captliq (float): Capital líquido do fundo na data especificada.
- volume_total_aplicacoes (float): Volume total de aplicações no fundo na data especificada.
- codigo_classe_subclasse (string): Código identificador da classe e subclasse do fundo.

Pergunta: {question}
"""

template_resposta = """
Com base no resultado da consulta SQL, formule uma resposta detalhada diretamente a partir dos valores obtidos.
Sempre responda em português.
Evite iniciar a resposta com expressões do tipo: aqui está a sua resposta correta ou completa ou aqui está a resposta clara e direta

- Primeiro, leia o resultado da consulta.
- Em seguida, interprete os dados para fornecer uma explicação clara e compreensível que responda à pergunta. Sem mencionar nada sobre SQL.

Aqui está a descrição de cada coluna, incluindo a unidade ou formato dos valores retornados:

codinst (int): Código identificador da instituição que administra o fundo. (Exemplo: 1234)
inst_cnpj (string): CNPJ da instituição que administra o fundo. (Exemplo: 00.000.000/0001-00)
inst_razao_social (string): Razão social da instituição que administra o fundo. (Exemplo: Fundo de Investimento XYZ S.A.)
codfundo (int): Código identificador do fundo. (Exemplo: 5678)
fundo_cnpj (string): CNPJ do fundo. (Exemplo: 11.111.111/0001-11)
fundo_razao_social (string): Razão social do fundo. (Exemplo: Fundo de Renda Fixa ABC)
periodo_divulg (int): Período de divulgação dos dados. (Valores possíveis: 1 (diária), 28 (mensal) ou 365 (anual))
codtipo (int): Código identificador do tipo do fundo. (Exemplo: 234)
tipo_fundo (string): Tipo do fundo. (Exemplo: Multimercados, Renda Fixa, Previdência, FII, FIP, Ações, Cambial, ETF, FIDC, OFF-SHORE)
composicao (string): Composição do fundo. (Exemplo: FM, FC, FF, FI)
data (date): Data das informações no formato date. (Formato: AAAA-MM-DD, Exemplo: 2024-08-26)
pl (float): Patrimônio líquido do fundo na data especificada. (Valor em reais, Exemplo: R$ 1.000.000,00)
valcota (float): Valor da cota do fundo na data especificada. (Valor em reais, Exemplo: R$ 100,00)
rentdia (float): Rentabilidade diária do fundo. (Percentual, Exemplo: 0,15%)
rentmes (float): Rentabilidade mensal do fundo. (Percentual, Exemplo: 2,5%)
rentano (float): Rentabilidade anual do fundo. (Percentual, Exemplo: 12%)
num_cotistas (float): Número de cotistas do fundo na data especificada. (Exemplo: 1500)
total_redemption (float): Valor total dos resgates realizados no fundo na data especificada. (Valor em reais, Exemplo: R$ 500.000,00)
captliq (float): Capital líquido do fundo na data especificada. (Valor em reais, Exemplo: R$ 200.000,00)
volume_total_aplicacoes (float): Volume total de aplicações no fundo na data especificada. (Valor em reais, Exemplo: R$ 1.200.000,00)
codigo_classe_subclasse (string): Código identificador da classe e subclasse do fundo. (Exemplo: FII01)

Resposta detalhada para a pergunta: {question}

{answer}
"""

# PromptTemplate para classificação
prompt_classificacao = PromptTemplate(
    input_variables=["question"],
    template=template_classificacao,
)

# PromptTemplate para gerar SQL
prompt_sql = PromptTemplate(
    input_variables=["question"],
    template=template_sql,
)

# PromptTemplate para resposta detalhada
prompt_resposta = PromptTemplate(
    input_variables=["question", "answer"],
    template=template_resposta,
)


def classificar_pergunta(llm_classificador, pergunta):
    logging.info(f"Question: {pergunta}")
    prompt = prompt_classificacao.format(question=pergunta)
    resposta = llm_classificador(prompt).strip()
    logging.info(f"Classificação da pergunta: {resposta}")
    return resposta

def gerar_resposta_final(template, llm_resposta, pergunta, resultado):
    prompt = template.format(
        question=pergunta,
        answer=resultado
    )
    resposta = llm_resposta(prompt)
    logging.info("Resposta final gerada.")
    return resposta

def gerar_sql_da_pergunta(prompt, llm, pergunta):
    inputs = {"question": pergunta}
    response = (prompt | llm).invoke(inputs)
    sql_query = response.strip().replace('\n```sql\n', '').replace('\n', ' ')
    logging.info(f"SQL gerado: {sql_query}")
    return sql_query

def executar_consulta_sql(query):
    try:
        conn = connect(
            aws_access_key_id=AWS_ACCESS_KEY,
            aws_secret_access_key=AWS_SECRET_KEY,
            region_name=AWS_REGION,
            s3_staging_dir=S3_STAGING_DIR,
            work_group=WORK_GROUP
        )
        df = pd.read_sql(query, conn)
        logging.info("Consulta SQL executada com sucesso.")

        return df
    except Exception as e:
        logging.error(f"Erro ao conectar ou executar a consulta: {e}")
        st.error(f"Erro ao conectar ou executar a consulta: {e}")
        return None


def gerar_grafico(df):
    # Verifica se o DataFrame tem uma única coluna ou uma única linha
    if df.shape[0] == 1 or df.shape[1] == 1:
        return None
    
    fig = go.Figure()

    # Identifica colunas de dimensão temporal
    temporal_columns = ['data', 'mes', 'dia', 'semana']
    x_col = next((col for col in temporal_columns if col in df.columns), None)
    
    if x_col:
        # Verifica se a coluna de fundo está presente para traçar as linhas individualmente
        if 'codfundo' in df.columns or 'fundo_razao_social' in df.columns:
            fundo_col = 'codfundo' if 'codfundo' in df.columns else 'fundo_razao_social'
            for fundo in df[fundo_col].unique():
                df_fundo = df[df[fundo_col] == fundo]
                y_col = next(col for col in df.columns if col not in temporal_columns + [fundo_col])
                fig.add_trace(go.Scatter(x=df_fundo[x_col], y=df_fundo[y_col], mode='lines+markers', name=str(fundo)))
            fig.update_layout(
                title="Comparação de Captação Líquida",
                xaxis_title=x_col,
                yaxis_title="Captação Líquida",
            )
        else:
            # Caso tenha dimensão temporal mas sem divisão por fundo
            y_cols = [col for col in df.columns if col not in temporal_columns]
            for y_col in y_cols:
                fig.add_trace(go.Scatter(x=df[x_col], y=df[y_col], mode='lines+markers', name=y_col))
            fig.update_layout(
                title="Gráfico de Linha",
                xaxis_title=x_col,
                yaxis_title="Valores"
            )
    else:
        num_cols = len(df.columns)
        
        if num_cols == 2:
            # Gráfico de Barras ou Dispersão para dados sem dimensão temporal
            fig.add_trace(go.Bar(x=df[df.columns[0]], y=df[df.columns[1]], name=str(df[df.columns[0]].name)))
            fig.update_layout(
                title="Gráfico de Barras",
                xaxis_title=df.columns[0],
                yaxis_title=df.columns[1]
            )
        elif num_cols == 3:
            # Gráfico de Barras Agrupadas
            for i in range(len(df)):
                fig.add_trace(go.Bar(x=[df.iloc[i, 0]], y=[df.iloc[i, 1]], name=str(df.iloc[i, 2])))
            fig.update_layout(
                title="Gráfico de Barras Agrupadas",
                xaxis_title=df.columns[0],
                yaxis_title=df.columns[1],
                barmode='group'
            )
        else:
            return None
            
    # pra evitar abreviações
    fig.update_xaxes(tickvals=df[df.columns[0]], ticktext=df[df.columns[0]].astype(str))
    
    
    # Ajusta margens e tamanho do gráfico
    fig.update_layout(
        margin=dict(l=50, r=50, t=50, b=50),
        width=800, height=600
    )
    
    return fig


# Função para processar a pergunta
def processar_pergunta(pergunta, llm, llm_resposta, llm_classificacao):
    classificacao = classificar_pergunta(llm_classificacao, pergunta).lower()

    if "saudação" in classificacao:
        return "Olá! Como posso te ajudar hoje?", None, None

    elif "gerar sql" in classificacao:
        sql_query = gerar_sql_da_pergunta(prompt_sql, llm, pergunta)

        sql_keywords = ["SELECT", "FROM", "WHERE", "JOIN", "GROUP BY", "ORDER BY", "LIMIT"]

        if sql_query and any(keyword in sql_query.upper() for keyword in sql_keywords):
            df = executar_consulta_sql(sql_query)
            if df is not None and not df.empty:
                grafico = gerar_grafico(df)
                resposta_final = gerar_resposta_final(prompt_resposta, llm_resposta, pergunta, df.to_string())
                return resposta_final, grafico, sql_query

            else:
                return "A consulta não retornou resultados, o banco de dados não contém informação sobre o assunto.", None, sql_query 

        else:
            return "A consulta SQL não pôde ser gerada ou a pergunta não era relacionada a dados.", None, sql_query

    else:
        return "Desculpe, não tenho conhecimento sobre esse assunto.", None, None


# Formulário para entrada do usuário
def exibir_formulario():
    with input_placeholder.form(key='formulario_chat', clear_on_submit=True):
        pergunta = st.text_input("Digite sua pergunta:")
        submit_button = st.form_submit_button(label='Enviar')
        return pergunta, submit_button

# Função para processar a pergunta e atualizar o histórico de mensagens
def processar_e_atualizar(pergunta):
    logging.info("Iniciando o processamento da pergunta.")
    with st.spinner("Processando..."):
        resposta, grafico, sql_query = processar_pergunta(pergunta, llm_classificador, llm_sql, llm_resposta)
        st.session_state.mensagens.append({
            "tipo": "user",
            "texto": pergunta
        })
        st.session_state.mensagens.append({
            "tipo": "ia",
            "texto": resposta,
            "grafico": grafico,
        })

        grafico_json = {}
        if grafico is not None:
            grafico_json = grafico.to_json()

        # Salvar a conversa no banco de dados
        db.save_chat(st.session_state.user_id, pergunta, resposta, sql_query, grafico_json)

    st.rerun()

# Inicializar a lista de mensagens na sessão do Streamlit
if "mensagens" not in st.session_state:
    st.session_state.mensagens = []

# Mostrar histórico de perguntas e respostas
for msg in st.session_state.mensagens:
    if msg["tipo"] == "user":
        st.write(f"**Você:** {msg['texto']}")
    else:
        st.write(f"**dott.ai:** {msg['texto']}")

        if msg.get("grafico") is not None:
            st.plotly_chart(msg["grafico"], use_container_width=True)
        #else:
            #st.warning("Dados insuficientes para gerar o gráfico.")

# Mostrar a consulta SQL gerada
if "sql_query" in st.session_state:
    st.write("**Consulta SQL Gerada:**")
    st.code(st.session_state.sql_query, language="sql")

# Espaço reservado para o campo de entrada
input_placeholder = st.empty()

# Exibir o formulário e processar a entrada
pergunta, submit_button = exibir_formulario()
if submit_button and pergunta:
    processar_e_atualizar(pergunta)
