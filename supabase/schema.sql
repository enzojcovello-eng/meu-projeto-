-- Troféus: banco de dados no Supabase
-- Rode este arquivo inteiro no SQL Editor do Supabase (ver GUIA-DE-INSTALACAO.md).
-- Pode rodar de novo sem medo: tudo usa "if not exists" ou "on conflict".

-- ---------------------------------------------------------------
-- Perfis (um por conta). O e-mail real é opcional.
-- ---------------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  username text not null unique,
  email text,
  steam_id text,
  steam_name text,
  steam_synced_at timestamptz,
  created_at timestamptz not null default now()
);

-- Nomes de usuário: só letras, números, ponto, traço e sublinhado, 3 a 24 caracteres.
alter table public.profiles drop constraint if exists profiles_username_format;
alter table public.profiles add constraint profiles_username_format
  check (username ~ '^[a-z0-9._-]{3,24}$');

-- ---------------------------------------------------------------
-- Jogos. "builtin" = veio com o site; "steam" = veio da Steam.
-- ---------------------------------------------------------------
create table if not exists public.games (
  id bigint generated always as identity primary key,
  source text not null check (source in ('builtin', 'steam')),
  source_key text not null,
  name text not null,
  platform text not null,
  icon_url text,
  created_at timestamptz not null default now(),
  unique (source, source_key)
);

-- ---------------------------------------------------------------
-- Conquistas de cada jogo.
-- ---------------------------------------------------------------
create table if not exists public.achievements (
  id bigint generated always as identity primary key,
  game_id bigint not null references public.games (id) on delete cascade,
  api_name text not null,
  name text not null,
  name_en text,
  description text,
  how_to text,
  category text,
  icon_url text,
  hidden boolean not null default false,
  sort_order integer not null default 0,
  unique (game_id, api_name)
);
create index if not exists achievements_game_idx on public.achievements (game_id, sort_order);

-- ---------------------------------------------------------------
-- Jogos da biblioteca de cada pessoa.
-- ---------------------------------------------------------------
create table if not exists public.user_games (
  user_id uuid not null references auth.users (id) on delete cascade,
  game_id bigint not null references public.games (id) on delete cascade,
  playtime_minutes integer,
  added_at timestamptz not null default now(),
  primary key (user_id, game_id)
);

-- ---------------------------------------------------------------
-- Conquistas marcadas por cada pessoa. Conta nova = tabela vazia = tudo zerado.
-- ---------------------------------------------------------------
create table if not exists public.user_achievements (
  user_id uuid not null references auth.users (id) on delete cascade,
  achievement_id bigint not null references public.achievements (id) on delete cascade,
  unlocked boolean not null default true,
  unlocked_at timestamptz,
  source text not null default 'manual' check (source in ('manual', 'steam')),
  video_url text,
  primary key (user_id, achievement_id)
);

-- ---------------------------------------------------------------
-- Cria o perfil automaticamente quando alguém se cadastra.
-- O site manda username e email (opcional) nos metadados do cadastro.
-- ---------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, username, email)
  values (
    new.id,
    lower(coalesce(new.raw_user_meta_data ->> 'username', split_part(new.email, '@', 1))),
    nullif(new.raw_user_meta_data ->> 'contact_email', '')
  );
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------
-- Login por nome de usuário: devolve o e-mail de login (real ou interno).
-- Quem não informou e-mail usa um endereço interno que nunca recebe mensagem.
-- ---------------------------------------------------------------
create or replace function public.login_email_for(p_username text)
returns text
language sql
security definer
set search_path = public
stable
as $$
  select u.email
  from auth.users u
  join public.profiles p on p.id = u.id
  where p.username = lower(trim(p_username))
  limit 1;
$$;
revoke all on function public.login_email_for(text) from public;
grant execute on function public.login_email_for(text) to anon, authenticated;

-- Checa se um nome de usuário já existe (usado no cadastro).
create or replace function public.username_taken(p_username text)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (select 1 from public.profiles where username = lower(trim(p_username)));
$$;
grant execute on function public.username_taken(text) to anon, authenticated;

-- ---------------------------------------------------------------
-- Segurança: cada pessoa só enxerga e mexe no que é dela.
-- ---------------------------------------------------------------
alter table public.profiles enable row level security;
alter table public.games enable row level security;
alter table public.achievements enable row level security;
alter table public.user_games enable row level security;
alter table public.user_achievements enable row level security;

drop policy if exists "perfil: ler o próprio" on public.profiles;
create policy "perfil: ler o próprio" on public.profiles
  for select using (auth.uid() = id);
drop policy if exists "perfil: editar o próprio" on public.profiles;
create policy "perfil: editar o próprio" on public.profiles
  for update using (auth.uid() = id) with check (auth.uid() = id);

drop policy if exists "jogos: todos leem" on public.games;
create policy "jogos: todos leem" on public.games
  for select to authenticated using (true);

drop policy if exists "conquistas: todos leem" on public.achievements;
create policy "conquistas: todos leem" on public.achievements
  for select to authenticated using (true);

drop policy if exists "biblioteca: só a própria" on public.user_games;
create policy "biblioteca: só a própria" on public.user_games
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "progresso: só o próprio" on public.user_achievements;
create policy "progresso: só o próprio" on public.user_achievements
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ---------------------------------------------------------------
-- Jogo que vem com o site: Rocket League (troféus do PlayStation).
-- ---------------------------------------------------------------
insert into public.games (source, source_key, name, platform)
values ('builtin', 'rocket-league-ps', 'Rocket League', 'PlayStation')
on conflict (source, source_key) do update set name = excluded.name, platform = excluded.platform;

insert into public.achievements (game_id, api_name, name, name_en, description, how_to, category, sort_order)
select (select id from public.games where source = 'builtin' and source_key = 'rocket-league-ps'), v.api_name, v.name, v.name_en, v.description, v.how_to, v.category, v.sort_order
from (values
  ('rl-ps-virtuoso', 'Virtuoso', 'Virtuoso', 'Desbloqueie todos os troféus.', 'É o troféu de platina: vem sozinho quando você pega todos os outros troféus do jogo base.', 'Jogo base (36 troféus)', 1),
  ('rl-ps-stocked', 'Armazenador', 'Stocked', 'Colete 150 itens.', 'Itens chegam jogando: drops depois das partidas, Rocket Pass gratuito e desafios semanais.', 'Jogo base (36 troféus)', 2),
  ('rl-ps-far-far-away', 'Muito, muito longe...', 'Far, Far Away', 'Dirija um total de 50 km.', 'Sai naturalmente jogando. Também dá para rodar pelo Free Play até completar.', 'Jogo base (36 troféus)', 3),
  ('rl-ps-super-victorious', 'Super Vitorioso', 'Super Victorious', 'Vença um total de 30 partidas em qualquer modo.', 'O jeito mais rápido é Exibição contra bots Rookie (os mais fáceis).', 'Jogo base (36 troféus)', 4),
  ('rl-ps-champion', 'Campeão', 'Champion', 'Vença o campeonato da temporada.', 'No modo Season (temporada offline contra bots), termine a fase regular e vença os playoffs. Escolha temporada curta e bots Rookie para ir rápido.', 'Jogo base (36 troféus)', 5),
  ('rl-ps-sequencia-de-vitorias', 'Sequência de Vitórias', '', 'Vença 10 partidas seguidas em qualquer modo.', 'Faça 10 Exibições seguidas contra bots Rookie, sem perder nenhuma. Se perder uma, a contagem volta do zero.', 'Jogo base (36 troféus)', 6),
  ('rl-ps-helens-pride', 'O orgulho de Helena', 'Helen''s Pride', 'Marque 6 gols em uma única partida.', 'Exibição sozinho, sem bots: empurre a bola para o gol 6 vezes antes do tempo acabar.', 'Jogo base (36 troféus)', 7),
  ('rl-ps-colecionador-de-carros', 'Colecionador de carros', '', 'Obtenha 5 carros.', 'Carros vêm de drops, Rocket Pass e recompensas. Basta jogar.', 'Jogo base (36 troféus)', 8),
  ('rl-ps-gotas-no-balde', 'Gotas no Balde', '', 'Colecione 50 itens.', 'Mesmo caminho do Armazenador, só que com menos itens.', 'Jogo base (36 troféus)', 9),
  ('rl-ps-rocketeer', 'Foguetes são comigo', 'Rocketeer', 'Complete uma temporada normal.', 'Jogue o modo Season até o fim da fase regular. Dá para escolher temporada curta e bots fáceis.', 'Jogo base (36 troféus)', 10),
  ('rl-ps-mecanico', 'Mecânico', '', 'Personalize o adesivo, acessório, impulso de foguete e roda de um carro.', 'Na Garage, no mesmo carro, troque o decal (adesivo), o topper (acessório/chapéu), o boost e as rodas.', 'Jogo base (36 troféus)', 11),
  ('rl-ps-bloqueio-infalivel', 'Bloqueio Infalível', '', 'Faça 20 defesas.', 'As defesas somam entre partidas. Defesa conta quando você tira do seu gol uma bola que ia entrar.', 'Jogo base (36 troféus)', 12),
  ('rl-ps-toque-mortifero', 'Toque Mortífero', '', 'Marque um gol atingindo seu oponente na bola.', 'Chute a bola de forma que ela bata no carro do adversário e entre no gol. Mais fácil contra um bot Rookie.', 'Jogo base (36 troféus)', 13),
  ('rl-ps-turbocharger', 'Velocista', 'Turbocharger', 'Use o impulso de foguete (boost) por um total de 5 minutos.', 'O tempo soma entre partidas. Numa Exibição sem bots, pegue os boosts grandes e segure o botão.', 'Jogo base (36 troféus)', 14),
  ('rl-ps-sargento-de-exercicios', 'Sargento de exercícios', '', 'Complete todos os exercícios de treinamento (qualquer dificuldade).', 'Menu Play > Training: complete os treinos de Striker (atacante), Goalie (goleiro) e Aerial (aéreo). A dificuldade Rookie é a mais fácil.', 'Jogo base (36 troféus)', 15),
  ('rl-ps-minuto-para-a-vitoria', 'Minuto para a vitória', '', 'Com 60 segundos restantes, ganhe uma partida que estava empatada ou prestes a perder.', 'Exibição contra bot Rookie: deixe o placar empatado ou o bot na frente até faltar 1 minuto, aí vire o jogo.', 'Jogo base (36 troféus)', 16),
  ('rl-ps-demonio-velocista', 'Demônio Velocista', '', 'Encha e esvazie completamente o boost 10 vezes em uma única partida.', 'Exibição sem bots: pegue um boost grande (100), gaste tudo até zerar, e repita 10 vezes na mesma partida.', 'Jogo base (36 troféus)', 17),
  ('rl-ps-pick-me-up', 'Transporte de pesados', 'Pick-Me Up', 'Colecione 5 itens.', 'Itens chegam jogando: drops, Rocket Pass gratuito e desafios.', 'Jogo base (36 troféus)', 18),
  ('rl-ps-motorista-de-paredes', 'Motorista de Paredes', '', 'Dirija pelas paredes da arena por um total de 5 minutos.', 'Soma entre partidas. No Free Play, suba na parede e vá dirigindo por ela.', 'Jogo base (36 troféus)', 19),
  ('rl-ps-parceiro-de-equipe', 'Parceiro de Equipe', '', 'Jogue contra todas as equipes no modo temporada.', 'Completar uma temporada inteira no modo Season já faz você enfrentar todos os times. Sai junto com o Foguetes são comigo.', 'Jogo base (36 troféus)', 20),
  ('rl-ps-sarpbc-para-sempre', 'SARPBC para sempre', '', 'Jogue um jogo com Octane e um com Backfire.', 'Faça uma Exibição com o Octane e outra com o Backfire. Pode ser com limite de 1 gol para ser rápido.', 'Jogo base (36 troféus)', 21),
  ('rl-ps-nostalgico', 'Nostálgico', '', 'Assista a um arquivo salvo no modo Replay.', 'No fim de uma partida, escolha Save Replay (salvar replay). Depois vá em Extras > Replays e assista.', 'Jogo base (36 troféus)', 22),
  ('rl-ps-vencedor', 'Vencedor', '', 'Vença um total de 5 partidas em qualquer modo.', 'Exibição contra bots Rookie é o mais rápido.', 'Jogo base (36 troféus)', 23),
  ('rl-ps-clean-sheet', 'Folha limpa', 'Clean Sheet', 'Vença uma partida sem sua equipe sofrer gols.', 'Exibição contra bots Rookie, ou sem bots: faça um gol e não deixe o adversário marcar.', 'Jogo base (36 troféus)', 24),
  ('rl-ps-ameaca-tripla', 'Ameaça tripla', '', 'Vença uma partida 3x3.', 'Exibição 3x3 contra bots Rookie.', 'Jogo base (36 troféus)', 25),
  ('rl-ps-em-dupla', 'Em Dupla', '', 'Vença uma partida 2x2.', 'Exibição 2x2 contra bots Rookie.', 'Jogo base (36 troféus)', 26),
  ('rl-ps-clube-solitario', 'Clube Solitário', '', 'Vença uma partida 1x1.', 'Exibição 1x1 contra bot Rookie.', 'Jogo base (36 troféus)', 27),
  ('rl-ps-arrancada-perfeita', 'Arrancada Perfeita', '', 'Vença sua primeira partida da temporada.', 'Inicie o modo Season com bots Rookie e vença o primeiro jogo.', 'Jogo base (36 troféus)', 28),
  ('rl-ps-ainda-e-um-exibido', 'Ainda é um Exibido', '', 'Marque um gol enquanto dirige de ré.', 'Exibição sem bots: deixe a bola perto do gol, vire de costas e empurre ela de ré para dentro.', 'Jogo base (36 troféus)', 29),
  ('rl-ps-sabe-tudo', 'Sabe tudo', '', 'Complete um exercício de treinamento.', 'Menu Play > Training e termine qualquer treino.', 'Jogo base (36 troféus)', 30),
  ('rl-ps-traveler', 'Viajante', 'Traveler', 'Jogue um jogo em seis arenas diferentes.', 'Em Exibição, troque de arena a cada partida até completar seis.', 'Jogo base (36 troféus)', 31),
  ('rl-ps-tinkerer', 'Funileiro', 'Tinkerer', 'Personalize um espaço de um carro.', 'Na Garage, troque qualquer peça do carro. Uma troca já basta.', 'Jogo base (36 troféus)', 32),
  ('rl-ps-first-timer', 'Principiante', 'First-Timer', 'Marque o seu primeiro gol.', 'Exibição sem bots: empurre a bola para o gol.', 'Jogo base (36 troféus)', 33),
  ('rl-ps-barras-bravas', 'Barras Bravas', '', 'Jogue um jogo online com alguém no seu grupo.', 'Convide um amigo para o grupo (party) e joguem juntos uma partida online.', 'Jogo base (36 troféus)', 34),
  ('rl-ps-friendly', 'Amigável', 'Friendly', 'Jogue uma partida de exibição.', 'Menu Play > Offline > Exhibition e jogue até o fim.', 'Jogo base (36 troféus)', 35),
  ('rl-ps-pitch-veteran', 'Veterano da pista', 'Pitch Veteran', 'Dispute um total de 20 partidas em qualquer modo.', 'Sai naturalmente. Exibições curtas também contam.', 'Jogo base (36 troféus)', 36),
  ('rl-ps-all-fours', 'De gatas', 'All Fours', 'Vença um jogo 4x4.', 'Jogue o modo Chaos (4x4) ou uma Exibição 4x4 contra bots Rookie e vença.', 'Pacote 4x4 e Utopia Coliseum', 37),
  ('rl-ps-gladiator', 'Gladiador', 'Gladiator', 'Faça um jogo no Utopia Coliseum.', 'Exibição > escolha a arena Utopia Coliseum e jogue até o fim.', 'Pacote 4x4 e Utopia Coliseum', 38),
  ('rl-ps-ases-pelos-ares', 'Ases pelos ares', '', 'Marque um gol aéreo.', 'Exibição sem bots: jogue a bola para o alto, pule, use o boost no ar e acerte a bola para o gol.', 'Pacote 4x4 e Utopia Coliseum', 39),
  ('rl-ps-winning-is-winning', 'O importante é vencer', 'Winning is Winning', 'Vença um campeonato da temporada usando Dominus em todas as partidas.', 'Equipe o Dominus, inicie uma temporada curta no modo Season com bots Rookie e não troque de carro até ganhar os playoffs.', 'Pacote Supersonic Fury', 40),
  ('rl-ps-an-inch-and-6-2-miles', '2,5 centímetros e 10 quilômetros', 'An Inch and 6.2 Miles', 'Dirija 10 km com as rodas Vortex, Cristiano ou Spinner.', 'Equipe uma dessas rodas na Garage e jogue normalmente, ou rode no Free Play até somar 10 km.', 'Pacote Supersonic Fury', 41),
  ('rl-ps-ride-or-die', 'Conduzir ou morrer', 'Ride or Die', 'Equipe Dominus ou Takumi com qualquer adesivo e vença um jogo.', 'Garage > Dominus ou Takumi > coloque um decal (adesivo) > vença uma Exibição contra bots Rookie.', 'Pacote Supersonic Fury', 42),
  ('rl-ps-dont-look-back', 'Não olhes para trás', 'Don''t Look Back', 'Use o boost Térmico, Queima Pneu ou Nitro por um total de 10 minutos.', 'Equipe um desses boosts na Garage. O tempo de boost vai somando entre partidas.', 'Pacote Supersonic Fury', 43),
  ('rl-ps-family-not-friends', 'Família, não amigos', 'Family, Not Friends', 'Jogue um jogo completo com Dominus ou Takumi.', 'Equipe Dominus ou Takumi e termine qualquer partida.', 'Pacote Supersonic Fury', 44),
  ('rl-ps-drift-king', 'Drift King', 'Drift King', 'Faça 180 derrapadas com Dominus ou Takumi.', 'Com Dominus ou Takumi, segure o botão de derrapagem (powerslide) e faça curvas. Soma entre partidas; Free Play é o jeito mais rápido.', 'Pacote Supersonic Fury', 45),
  ('rl-ps-survival-of-the-fittest', 'Sobrevivência do mais Forte', 'Survival of the Fittest', 'Equipe um acessório e vença uma partida contra bot Injusto (Unfair).', 'Equipe um chapéu (topper), inicie uma Exibição 1x1 contra bot no nível Unfair (o mais difícil) e vença.', 'Pacote Revenge of the Battle-Cars', 46),
  ('rl-ps-heartbreaker', 'Destruição de Coração', 'Heartbreaker', 'Vença um jogo contra bots Ídolos (All-Star) com um adesivo equipado.', 'Coloque um decal no carro e vença uma Exibição 1x1 contra bot All-Star.', 'Pacote Revenge of the Battle-Cars', 47),
  ('rl-ps-natural-progression', 'Progressão Natural', 'Natural Progression', 'Vença uma partida online com Backfire, Scarab ou Zippy.', 'Equipe um desses carros e vença uma partida online. Partida privada com um amigo também conta.', 'Pacote Revenge of the Battle-Cars', 48),
  ('rl-ps-throwback', 'Retrocesso', 'Throwback', 'Use o boost Accelerato ou Padrão com Octane ou Backfire jogando em Central Urbana.', 'Equipe Octane ou Backfire com boost Standard (Padrão) ou Accelerato e jogue uma Exibição em Urban Central usando o boost.', 'Pacote Revenge of the Battle-Cars', 49),
  ('rl-ps-hot-shot-part-two', 'Estrela Principal, Parte Dois', 'Hot Shot, Part Two', 'Seja destaque (MVP) usando Backfire, Scarab ou Zippy.', 'Jogue com um desses carros contra bots Rookie e termine a partida com a maior pontuação do time vencedor.', 'Pacote Revenge of the Battle-Cars', 50),
  ('rl-ps-my-world-is-fire', 'Meu mundo é fogo', 'My World is Fire', 'Equipe o boost Lança-chamas e vença uma partida online 4x4.', 'Equipe o boost Flamethrower (Lança-chamas) e vença uma partida do modo Chaos (4x4) online.', 'Pacote Chaos Run', 51),
  ('rl-ps-spectacular', 'Espetacular', 'Spectacular', 'Com Merc ou Grog, faça 10 gols contra bots de nível Profissional ou maior.', 'Exibição 1x1 contra bot Pro com Merc ou Grog. Os gols somam entre partidas.', 'Pacote Chaos Run', 52),
  ('rl-ps-savage', 'Selvagem', 'Savage', 'Com Breakout ou Ripper, faça 10 gols contra bots de nível Profissional ou maior.', 'Exibição 1x1 contra bot Pro com Breakout ou Ripper. Os gols somam entre partidas.', 'Pacote Chaos Run', 53),
  ('rl-ps-ruthless', 'Impiedoso', 'Ruthless', 'Faça um total de 50 chutes ao gol usando Merc, Grog ou Ripper.', 'Exibição sem bots com um desses carros, chutando sempre no gol. Soma entre partidas.', 'Pacote Chaos Run', 54),
  ('rl-ps-detonador-psico-master', 'Detonador Psico-Master', '', 'Destrua 3 bots adversários em Wasteland.', 'Exibição em Wasteland contra bots Rookie: bata nos carros deles em velocidade supersônica para destruí-los.', 'Pacote Chaos Run', 55),
  ('rl-ps-mad-scientist', 'Cientista Louco', 'Mad Scientist', 'Jogue um jogo completo em 3 arenas Rocket Labs diferentes.', 'Em Exibição, escolha arenas experimentais (Rocket Labs, como Pillars, Cosmic, Double Goal ou Underpass) e termine 3 partidas, uma em cada.', 'Pacote Neo Tokyo (Hoops, Snow Day e itens)', 56),
  ('rl-ps-icing-the-cake', 'Doce Frio', 'Icing the Cake', 'No Dia da Neve (Snow Day), marque um gol do seu lado do gelo.', 'Exibição de Snow Day sem bots: posicione o disco no seu campo e chute forte para o gol adversário.', 'Pacote Neo Tokyo (Hoops, Snow Day e itens)', 57),
  ('rl-ps-left-wing-right-wing', 'Ala Esquerda, Ala Direita', 'Left Wing, Right Wing', 'Vença um jogo de Dia da Neve com o time Laranja e outro com o Azul.', 'Duas Exibições de Snow Day sem bots: vença uma como Azul e outra como Laranja.', 'Pacote Neo Tokyo (Hoops, Snow Day e itens)', 58),
  ('rl-ps-fast-break', 'Super Rápido', 'Fast Break', 'Faça 2 enterradas no primeiro minuto de um jogo de Cestos (Hoops).', 'Exibição de Hoops sem bots: logo no início, leve a bola até a cesta e enterre duas vezes antes do relógio chegar a 4:00.', 'Pacote Neo Tokyo (Hoops, Snow Day e itens)', 59),
  ('rl-ps-buzzer-beater', 'Até ao Fim!', 'Buzzer Beater', 'Vença um jogo de Cestos estando empatado ou perdendo quando faltarem 30 segundos.', 'Exibição de Hoops contra bot Rookie: deixe o placar empatado ou o bot na frente até 0:30, aí vire o jogo.', 'Pacote Neo Tokyo (Hoops, Snow Day e itens)', 60),
  ('rl-ps-budding-artist', 'Artista em Ascensão', 'Budding Artist', 'Colecione um item pintado.', 'Itens pintados (com cor) caem em drops e no Rocket Pass.', 'Pacote Neo Tokyo (Hoops, Snow Day e itens)', 61),
  ('rl-ps-one-better', 'Ainda Melhor', 'One Better', 'Aumente o nível de um item certificado.', 'Equipe um item certificado (com título tipo Striker ou Goalkeeper) e jogue até o contador dele subir de nível.', 'Pacote Neo Tokyo (Hoops, Snow Day e itens)', 62),
  ('rl-ps-certifiable', 'Certificado', 'Certifiable', 'Alcance o nível Veterano num item certificado.', 'Continue usando o mesmo item certificado até ele chegar ao nível Veteran.', 'Pacote Neo Tokyo (Hoops, Snow Day e itens)', 63),
  ('rl-ps-gg', 'GG', '', 'Consiga o prêmio MVP numa partida com prorrogação.', 'Exibição contra bot Rookie: deixe empatado até o fim, vença na prorrogação e termine com a maior pontuação.', 'Pacote AquaDome (Rumble)', 64),
  ('rl-ps-triade', 'Tríade', '', 'Marque um gol, faça uma defesa e dê uma assistência num único jogo.', 'Exibição 2x2 ou 3x3 contra bots Rookie: faça um gol, salve uma bola no seu gol e dê um passe que vire gol do seu companheiro.', 'Pacote AquaDome (Rumble)', 65),
  ('rl-ps-poder-infinito', 'Poder infinito!', '', 'Ative todos os poderes no modo Rumble.', 'Jogue Rumble e use todos os tipos de poder que aparecerem. Soma entre partidas.', 'Pacote AquaDome (Rumble)', 66),
  ('rl-ps-stopped-cold', 'Congelado', 'Stopped Cold', 'No Rumble, congele um chute do oponente antes que ele entre no gol.', 'Jogue Rumble e, quando pegar o poder Freezer, use na bola que está indo para o seu gol.', 'Pacote AquaDome (Rumble)', 67),
  ('rl-ps-tartaruga-marinha', 'Tartaruga marinha', '', 'Vá para o AquaDome e marque um gol enquanto estiver de costas (de cabeça para baixo).', 'Exibição no AquaDome sem bots: deixe a bola perto do gol, vire o carro de cabeça para baixo e empurre a bola para dentro.', 'Pacote AquaDome (Rumble)', 68),
  ('rl-ps-levanta-sr-bubbles', 'Levanta, sr. Bubbles!', '', 'Faça um gol aéreo jogando no AquaDome.', 'Exibição no AquaDome sem bots: jogue a bola para o alto e acerte no ar para o gol.', 'Pacote AquaDome (Rumble)', 69),
  ('rl-ps-rocket-repleter', 'Rocket equipado', '', 'Chute 535 vezes no gol.', 'Chutes a gol somam entre partidas. Exibição sem bots chutando sempre no gol acelera.', 'Pacote AquaDome (Rumble)', 70),
  ('rl-ps-eleitor-registrado', 'Eleitor registrado', '', 'Vá em Preferências da Arena e use todos os seus votos.', 'Configurações > Arena Preferences (Preferências da Arena): marque o máximo de arenas favoritas permitido.', 'Pacote Starbase ARC (Dropshot)', 71),
  ('rl-ps-anjos-do-espaco', 'Anjos do espaço', '', 'Equipe o boost Íon ou o acessório Halo e vença uma partida em Starbase ARC.', 'Equipe boost Ion ou topper Halo e vença uma Exibição em Starbase ARC contra bots Rookie.', 'Pacote Starbase ARC (Dropshot)', 72),
  ('rl-ps-desafie-os-elementos', 'Desafie os elementos', '', 'Complete uma partida em terras devastadas, no fundo do mar e no espaço.', 'Jogue uma Exibição em Wasteland, outra no AquaDome e outra em Starbase ARC.', 'Pacote Starbase ARC (Dropshot)', 73),
  ('rl-ps-controle-de-dano', 'Controle de dano', '', 'Vença uma partida de Chute em queda (Dropshot) sem o adversário marcar.', 'Exibição de Dropshot contra bot Rookie: marque e não deixe o bot quebrar o piso do seu lado.', 'Pacote Starbase ARC (Dropshot)', 74),
  ('rl-ps-full-course', 'Serviço completo', 'Full Course', 'Marque um total de 18 gols em Chute em queda (Dropshot).', 'Exibição de Dropshot sem bots. Os gols somam entre partidas.', 'Pacote Starbase ARC (Dropshot)', 75),
  ('rl-ps-buckminster-x10', 'Buckminster x10', '', 'Cause dano num total de 320 painéis em Chute em queda (Dropshot).', 'Em Dropshot, cada vez que a bola carregada bate no piso adversário danifica painéis. Soma entre partidas; Exibição sem bots acelera.', 'Pacote Starbase ARC (Dropshot)', 76),
  ('rl-ps-ta-chovendo-aqui', 'Tá chovendo aqui!', '', 'Instale um item deluxe e conclua uma partida numa arena com clima turbulento.', 'Equipe um item deluxe e jogue uma arena com chuva ou tempestade (versão Stormy de alguma arena).', 'Pacote Champions Field (online)', 77),
  ('rl-ps-so-diversao', 'Só diversão', '', 'Conclua uma partida online no Campo dos Campeões (Champions Field).', 'Partida online que caia em Champions Field. Partida privada nessa arena também pode servir.', 'Pacote Champions Field (online)', 78),
  ('rl-ps-novo-perfil', 'Novo perfil! Quem é você?', '', 'Mude sua faixa do jogador (banner), borda do avatar e título.', 'Garage > Player Banner, Avatar Border e Player Title: troque os três.', 'Pacote Champions Field (online)', 79),
  ('rl-ps-trocando-segredos', 'Trocando segredos', '', 'Troque 5 itens da mesma qualidade para receber um da qualidade seguinte.', 'Menu Trade In: escolha 5 itens da mesma raridade (ex.: 5 Raros) e confirme a troca.', 'Pacote Champions Field (online)', 80),
  ('rl-ps-rank-up', 'Classificado', 'Rank Up', 'Conclua todas as partidas de classificação em qualquer lista competitiva.', 'Jogue as primeiras partidas de qualquer playlist Ranked até receber seu rank.', 'Pacote Champions Field (online)', 81),
  ('rl-ps-craque-do-volante', 'Craque do volante', '', 'Faça ou dê assistência para 30 gols em partidas online casuais ou competitivas.', 'Sai jogando online. Gols e assistências somam.', 'Pacote Champions Field (online)', 82),
  ('rl-ps-junte-se-ao-clube', 'Junte-se ao clube!', '', 'Crie ou entre num clube do Rocket League.', 'Menu Social > Clubs: crie um clube ou aceite convite de um amigo.', 'Pacote Clubes', 83),
  ('rl-ps-antes-acompanhado', 'Antes acompanhado do que só', '', 'Jogue e complete uma partida online com um ou mais colegas de clube.', 'Forme grupo (party) com alguém do seu clube e joguem uma partida online até o fim.', 'Pacote Clubes', 84),
  ('rl-ps-novo-desafiante', 'Novo desafiante', '', 'Jogue e complete uma partida de torneio online.', 'Menu Play > Tournaments: inscreva-se num torneio e jogue a primeira partida até o fim.', 'Pacote Clubes', 85),
  ('rl-ps-sociavel', 'Sociável', '', 'Jogue e complete 10 partidas online com colegas de clube.', 'Igual ao Antes acompanhado do que só, só que 10 vezes.', 'Pacote Clubes', 86),
  ('rl-ps-pelo-clube', 'Pelo clube', '', 'Marque um gol numa Partida de Clube (só emparelhamento online).', 'Com um grupo só de membros do mesmo clube, entre numa fila online e marque um gol.', 'Pacote Clubes', 87),
  ('rl-ps-o-melhor-da-partida', 'O melhor da partida', '', 'Marque um gol numa Partida de Clube (só emparelhamento online).', 'O PlayStation mostra a mesma descrição do Pelo clube. Pelo nome, o mais provável é que peça ser o MVP (melhor da partida) numa Partida de Clube.', 'Pacote Clubes', 88)
) as v(api_name, name, name_en, description, how_to, category, sort_order)
on conflict (game_id, api_name) do update set name = excluded.name, name_en = excluded.name_en, description = excluded.description, how_to = excluded.how_to, category = excluded.category, sort_order = excluded.sort_order;
