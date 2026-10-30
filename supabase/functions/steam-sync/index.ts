// Edge Function "steam-sync"
// Recebe o perfil Steam da pessoa logada, busca os jogos e conquistas dela na
// Steam Web API e grava no banco. A chave da Steam fica no segredo STEAM_API_KEY.
//
// Chamada pelo site: POST { profile: "https://steamcommunity.com/id/fulano", offset: 0 }
// Resposta: { steam_id, steam_name, total_games, processed, next_offset | null }

import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const STEAM = "https://api.steampowered.com";
const GAMES_PER_CALL = 25; // quantos jogos processar por chamada (evita estourar o tempo limite)
const LANG = "brazilian"; // idioma dos nomes das conquistas

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

async function steamGet(path: string, params: Record<string, string>) {
  const url = new URL(STEAM + path);
  for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);
  const r = await fetch(url);
  if (!r.ok) throw new Error(`Steam respondeu ${r.status} em ${path}`);
  return r.json();
}

// Aceita: SteamID64, link /profiles/<id>, link /id/<apelido> ou só o apelido.
async function resolveSteamId(key: string, input: string): Promise<string> {
  const s = input.trim();
  const m64 = s.match(/^(?:https?:\/\/steamcommunity\.com\/profiles\/)?(\d{17})\/?$/);
  if (m64) return m64[1];
  const vanity = (s.match(/steamcommunity\.com\/id\/([^\/?#]+)/)?.[1] ?? s).replace(/\/$/, "");
  const data = await steamGet("/ISteamUser/ResolveVanityURL/v1/", { key, vanityurl: vanity });
  if (data?.response?.success !== 1) throw new Error("Não achei esse perfil na Steam. Confira o link.");
  return data.response.steamid as string;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const key = Deno.env.get("STEAM_API_KEY");
    if (!key) return json({ error: "STEAM_API_KEY não configurada no Supabase." }, 500);

    // Quem está chamando? (usa o token de login enviado pelo site)
    const authHeader = req.headers.get("Authorization") ?? "";
    const userClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: { user }, error: userErr } = await userClient.auth.getUser();
    if (userErr || !user) return json({ error: "Faça login para vincular a Steam." }, 401);

    // Cliente com permissão total, só usado aqui no servidor.
    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const body = await req.json().catch(() => ({}));
    const offset = Number(body.offset ?? 0);
    let steamId: string | null = null;

    if (body.profile) {
      steamId = await resolveSteamId(key, String(body.profile));
    } else {
      const { data: prof } = await admin.from("profiles").select("steam_id").eq("id", user.id).single();
      steamId = prof?.steam_id ?? null;
    }
    if (!steamId) return json({ error: "Informe o link do seu perfil Steam." }, 400);

    // Nome do perfil (também confirma que o perfil é público).
    const summ = await steamGet("/ISteamUser/GetPlayerSummaries/v2/", { key, steamids: steamId });
    const player = summ?.response?.players?.[0];
    if (!player) throw new Error("Perfil Steam não encontrado.");
    if (player.communityvisibilitystate !== 3) {
      return json({ error: "Seu perfil Steam está privado. Deixe o perfil e os detalhes de jogos como Público e tente de novo." }, 400);
    }

    // Jogos da biblioteca.
    const owned = await steamGet("/IPlayerService/GetOwnedGames/v1/", {
      key, steamid: steamId, include_appinfo: "1", include_played_free_games: "1", format: "json",
    });
    const allGames: Array<{ appid: number; name: string; playtime_forever: number; img_icon_url?: string }> =
      owned?.response?.games ?? [];
    if (!allGames.length) {
      return json({ error: "A Steam não devolveu jogos. Em Privacidade do perfil, deixe 'Detalhes do jogo' como Público." }, 400);
    }
    allGames.sort((a, b) => b.playtime_forever - a.playtime_forever);

    await admin.from("profiles").update({
      steam_id: steamId, steam_name: player.personaname ?? null,
    }).eq("id", user.id);

    const slice = allGames.slice(offset, offset + GAMES_PER_CALL);
    let processed = 0;

    for (const g of slice) {
      // Lista de conquistas do jogo (em português quando a Steam tiver).
      let schema;
      try {
        schema = await steamGet("/ISteamUserStats/GetSchemaForGame/v2/", { key, appid: String(g.appid), l: LANG });
      } catch { continue; }
      const achs: Array<{ name: string; displayName: string; description?: string; icon: string; hidden: number }> =
        schema?.game?.availableGameStats?.achievements ?? [];
      if (!achs.length) continue; // jogo sem conquistas: não entra na biblioteca

      const icon = g.img_icon_url
        ? `https://media.steampowered.com/steamcommunity/public/images/apps/${g.appid}/${g.img_icon_url}.jpg`
        : null;
      const { data: game, error: gErr } = await admin.from("games").upsert(
        { source: "steam", source_key: String(g.appid), name: g.name, platform: "Steam", icon_url: icon },
        { onConflict: "source,source_key" },
      ).select("id").single();
      if (gErr || !game) continue;

      await admin.from("achievements").upsert(
        achs.map((a, i) => ({
          game_id: game.id, api_name: a.name, name: a.displayName,
          description: a.hidden && !a.description ? "Conquista secreta" : (a.description ?? ""),
          icon_url: a.icon, hidden: !!a.hidden, sort_order: i,
        })),
        { onConflict: "game_id,api_name" },
      );

      await admin.from("user_games").upsert(
        { user_id: user.id, game_id: game.id, playtime_minutes: g.playtime_forever },
        { onConflict: "user_id,game_id" },
      );

      // O que a pessoa já desbloqueou nesse jogo.
      let got;
      try {
        got = await steamGet("/ISteamUserStats/GetPlayerAchievements/v1/", { key, steamid: steamId, appid: String(g.appid), l: LANG });
      } catch { processed++; continue; }
      const unlocked: Array<{ apiname: string; achieved: number; unlocktime: number }> =
        (got?.playerstats?.achievements ?? []).filter((a: { achieved: number }) => a.achieved === 1);
      if (unlocked.length) {
        const { data: ids } = await admin.from("achievements")
          .select("id, api_name").eq("game_id", game.id)
          .in("api_name", unlocked.map((a) => a.apiname));
        const byApi = new Map((ids ?? []).map((r) => [r.api_name, r.id]));
        const rows = unlocked
          .filter((a) => byApi.has(a.apiname))
          .map((a) => ({
            user_id: user.id, achievement_id: byApi.get(a.apiname), unlocked: true,
            unlocked_at: a.unlocktime ? new Date(a.unlocktime * 1000).toISOString() : null, source: "steam",
          }));
        if (rows.length) await admin.from("user_achievements").upsert(rows, { onConflict: "user_id,achievement_id" });
      }
      processed++;
    }

    const nextOffset = offset + GAMES_PER_CALL < allGames.length ? offset + GAMES_PER_CALL : null;
    if (nextOffset === null) {
      await admin.from("profiles").update({ steam_synced_at: new Date().toISOString() }).eq("id", user.id);
    }

    return json({
      steam_id: steamId, steam_name: player.personaname,
      total_games: allGames.length, processed, next_offset: nextOffset,
    });
  } catch (e) {
    return json({ error: (e as Error).message ?? "Erro inesperado." }, 500);
  }
});
