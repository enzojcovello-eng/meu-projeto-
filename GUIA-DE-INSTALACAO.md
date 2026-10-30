# Troféus: guia de instalação

Este site deixa cada pessoa criar uma conta, montar a lista de jogos dela e marcar as conquistas que já tem. O progresso fica salvo num banco de dados na internet, então funciona em qualquer celular ou computador. Quem quiser pode vincular a Steam para puxar os jogos e as conquistas automaticamente.

Tudo que você vai usar tem plano gratuito. O passo a passo leva uns 30 minutos.

O que você vai criar:

1. Um projeto no Supabase (banco de dados + login).
2. Uma chave da Steam (só se quiser o vínculo com a Steam).
3. O site publicado no GitHub Pages.

## Passo 1: criar o projeto no Supabase

1. Entre em https://supabase.com e crie uma conta (pode usar a conta do GitHub).
2. Clique em *New project*. Dê um nome (por exemplo `trofeus`), crie uma senha para o banco (guarde ela) e escolha a região *South America (São Paulo)*.
3. Espere o projeto terminar de criar (1 a 2 minutos).

## Passo 2: montar o banco de dados

1. No menu da esquerda, clique em *SQL Editor*.
2. Abra o arquivo `supabase/schema.sql` deste repositório, copie o conteúdo inteiro e cole no editor.
3. Clique em *Run*. Deve aparecer "Success". Isso cria as tabelas, as regras de segurança e já cadastra o Rocket League com os 88 troféus.

Pode rodar esse arquivo mais de uma vez sem problema.

## Passo 3: deixar o e-mail opcional

Por padrão o Supabase exige confirmação por e-mail. Como aqui o e-mail é opcional, desligue isso:

1. Menu *Authentication* > *Providers* > *Email*.
2. Desmarque *Confirm email*.
3. Salve.

Quem se cadastra sem e-mail recebe um endereço interno (que nunca recebe mensagem) só para o login funcionar. Quem informa e-mail pode usar o "Esqueci a senha" do Supabase no futuro.

## Passo 4: pegar a URL e a chave do projeto

1. Menu *Project Settings* (engrenagem) > *API*.
2. Copie o *Project URL* e a chave *anon public*.
3. Abra o arquivo `site/config.js` e cole os dois valores no lugar dos textos `SEU-PROJETO` e `COLE-AQUI-A-CHAVE-ANON`.

Esses dois valores podem ficar públicos: a chave anon só faz o que as regras de segurança do banco permitem (cada pessoa só vê o que é dela).

## Passo 5 (opcional): vínculo com a Steam

Pule este passo se não quiser a Steam. O resto do site funciona sem ele.

### 5a. Chave da Steam

1. Entre em https://steamcommunity.com/dev/apikey com sua conta Steam.
2. Em *Domain name* escreva qualquer coisa (por exemplo `trofeus`) e aceite os termos.
3. Copie a chave que aparece.

### 5b. Publicar a função no Supabase

A função que conversa com a Steam fica em `supabase/functions/steam-sync/index.ts`. Para publicar, use o terminal do seu computador:

1. Instale o Node.js (https://nodejs.org) se ainda não tiver.
2. Abra o terminal na pasta deste repositório e rode, um por vez:

```
npx supabase login
npx supabase link --project-ref SEU-PROJECT-REF
npx supabase secrets set STEAM_API_KEY=SUA-CHAVE-DA-STEAM
npx supabase functions deploy steam-sync
```

O `SEU-PROJECT-REF` é o código que aparece na URL do projeto (`https://supabase.com/dashboard/project/<project-ref>`). No primeiro comando o navegador abre para você autorizar.

### 5c. Como a pessoa usa

Na página *Conta*, ela cola o link do perfil Steam. O perfil e os "detalhes do jogo" precisam estar como *Público* nas configurações de privacidade da Steam. O site busca os jogos que têm conquistas, coloca na lista dela e já marca o que ela desbloqueou. Jogos com muitas conquistas levam alguns segundos cada.

## Passo 6: publicar o site no GitHub Pages

1. No GitHub, abra o repositório > *Settings* > *Pages*.
2. Em *Build and deployment*, escolha *Deploy from a branch*, ramo `main`, pasta `/ (root)`. Salve.
3. Em 1 a 2 minutos o site fica no ar em `https://SEU-USUARIO.github.io/NOME-DO-REPOSITORIO/site/`.

Se preferir outro serviço (Netlify, Vercel, Cloudflare Pages), é só publicar a pasta `site/`. O site é estático, sem servidor próprio.

## Sobre o PlayStation

A Sony não tem uma API pública de troféus, e os métodos não oficiais usam o token de login da conta, o que quebra as regras da PSN e pode dar bloqueio. Por isso o site não vincula com o PS5. Jogos de PlayStation entram pelo catálogo do site (hoje só o Rocket League) e os troféus são marcados à mão.

Para adicionar outro jogo de PlayStation ao catálogo, insira as linhas dele nas tabelas `games` e `achievements` pelo SQL Editor, no mesmo formato do Rocket League no fim do `schema.sql`.

## Problemas comuns

- *"O site ainda não está ligado ao banco de dados"*: o `config.js` não foi preenchido (passo 4).
- *"Usuário ou senha incorretos"* logo depois de criar a conta: o passo 3 não foi feito (confirmação de e-mail ainda ligada).
- *"Seu perfil Steam está privado"*: na Steam, Perfil > Editar perfil > Privacidade: deixe *Meu perfil* e *Detalhes do jogo* como Público.
- *"STEAM_API_KEY não configurada"*: falta o comando `secrets set` do passo 5b.
