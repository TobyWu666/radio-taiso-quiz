-- ラジオ体操クイズ 排行榜（Supabase）
-- 用法：Supabase 專案 → SQL Editor → New query → 貼上全部 → Run
-- 可以重複執行，不會清掉既有成績。

create table if not exists public.scores (
  pid        text primary key check (pid ~ '^[a-f0-9]{16,64}$'),
  name       text not null check (char_length(name) between 1 and 10),
  score      int  not null check (score between 0 and 12),
  time_ms    int  not null check (time_ms between 12000 and 3600000),
  updated_at timestamptz not null default now()
);

-- 玩家不能直接讀寫資料表，只能透過下面兩個函式
alter table public.scores enable row level security;
revoke all on public.scores from anon, authenticated;

-- 前 10 名
create or replace function public.top_scores()
returns json
language sql stable security definer
set search_path = public
as $$
  select json_build_object('ok', true, 'rows', coalesce(json_agg(r), '[]'::json))
  from (
    select name, score, time_ms as "timeMs", updated_at as "at"
    from scores
    order by score desc, time_ms asc, updated_at asc
    limit 10
  ) r;
$$;

-- 登錄成績：每台裝置（pid）只保留最佳成績
create or replace function public.submit_score(p_pid text, p_name text, p_score int, p_time_ms int)
returns json
language plpgsql security definer
set search_path = public
as $$
declare
  v_name text := left(btrim(regexp_replace(coalesce(p_name, ''), '[<>[:cntrl:]]', '', 'g')), 10);
  v_old scores%rowtype;
  v_improved boolean := true;
begin
  if p_pid is null or p_pid !~ '^[a-f0-9]{16,64}$' then
    return json_build_object('ok', false, 'error', '識別碼錯誤');
  end if;
  if v_name = '' then
    return json_build_object('ok', false, 'error', '請輸入暱稱');
  end if;
  if p_score is null or p_score < 0 or p_score > 12 then
    return json_build_object('ok', false, 'error', '分數不合理');
  end if;
  if p_time_ms is null or p_time_ms < 12000 or p_time_ms > 3600000 then
    return json_build_object('ok', false, 'error', '時間不合理');
  end if;

  select * into v_old from scores where pid = p_pid for update;
  if not found then
    insert into scores (pid, name, score, time_ms) values (p_pid, v_name, p_score, p_time_ms)
    on conflict (pid) do nothing;
  else
    v_improved := p_score > v_old.score or (p_score = v_old.score and p_time_ms < v_old.time_ms);
    if v_improved then
      update scores set name = v_name, score = p_score, time_ms = p_time_ms, updated_at = now() where pid = p_pid;
    else
      update scores set name = v_name where pid = p_pid;  -- 換暱稱仍然更新
    end if;
  end if;

  return (
    select json_build_object('ok', true, 'improved', v_improved, 'rows', coalesce(json_agg(r), '[]'::json))
    from (
      select name, score, time_ms as "timeMs", updated_at as "at", (pid = p_pid) as "me"
      from scores
      order by score desc, time_ms asc, updated_at asc
      limit 10
    ) r
  );
end;
$$;

grant usage on schema public to anon, authenticated;
revoke all on function public.top_scores() from public;
revoke all on function public.submit_score(text, text, int, int) from public;
grant execute on function public.top_scores() to anon, authenticated;
grant execute on function public.submit_score(text, text, int, int) to anon, authenticated;
