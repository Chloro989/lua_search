-- index.lua : 転置インデックスと BM25 検索（外部ライブラリ不要 / Lua 5.3+）

local M = {}

--------------------------------------------------------------------
-- 1. トークナイザ
--------------------------------------------------------------------
-- 文字列を「1文字ずつ」の配列に分解する。
-- UTF-8 の先頭バイト + 継続バイト(0x80-0xBF)、というパターンで切る。
local function to_chars(s)
  local t = {}
  for c in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    t[#t + 1] = c
  end
  return t
end

-- ASCII 1バイト文字かどうか
local function is_ascii(c)
  return #c == 1
end

-- テキストをトークン列に変換する。
--   ASCII        → 単語単位（空白・記号で区切る）
--   それ以外(日本語) → 2文字ずつのスライディング bi-gram
--
-- 例: "検索エンジン" → 検索, 索エ, エン, ンジ, ジン, ン
--     "Lua search"  → lua, search
--
-- 日本語を bi-gram にするのは、形態素解析器なしで
-- 「部分一致でも引っかかるインデックス」を作るための定番手法。
--
-- 注意: 非ASCIIの「ひと続きの文字列(ラン)」が終わる箇所では、
-- 直前の bi-gram に含まれる最後の1文字を *さらに* 単独の uni-gram
-- としても登録する（上の例で末尾に "ン" が単独で付くのはこのため）。
-- これはランの最後の文字だけが単独でも検索に引っかかるようにする
-- ための意図的な仕様。ただし M.search_phrase はこれをそのまま使わず
-- 専用の phrase_tokenize() を使う（下の説明を参照）。
function M.tokenize(text)
  local cs = to_chars(text:lower())
  local tokens = {}
  local buf = {}

  local function flush()
    if #buf > 0 then
      tokens[#tokens + 1] = table.concat(buf)
      buf = {}
    end
  end

  local i = 1
  while i <= #cs do
    local c = cs[i]
    if is_ascii(c) then
      if c:match("[%w]") then
        buf[#buf + 1] = c          -- 英数字は連結して1単語に
      else
        flush()                     -- 空白・記号は区切り
      end
    else
      flush()                       -- 日本語が来たら英単語を確定
      local nxt = cs[i + 1]
      if nxt and not is_ascii(nxt) then
        tokens[#tokens + 1] = c .. nxt   -- bi-gram
      else
        tokens[#tokens + 1] = c          -- 末尾の1文字は uni-gram
      end
    end
    i = i + 1
  end
  flush()

  return tokens
end

-- フレーズ検索専用のトークン化。M.tokenize との違いは、非ASCIIランの
-- 末尾で発生する「重複の uni-gram」を出さないこと。
--
-- なぜ専用に分けたか:
--   文書側の postings は M.tokenize でインデックスされているので、
--   ある語が「文中に埋め込まれている」限り、末尾の重複 uni-gram は
--   絶対に出現しない（次の文字が続くので常に bi-gram になる）。
--   ところがフレーズクエリ文字列は「それ単体」でトークン化するので、
--   クエリの末尾がちょうどランの末尾と一致してしまい、
--   本来ドキュメント中には存在しないはずの重複トークンが混ざる。
--   これが原因で「検索エンジン」のようなフレーズが1件もヒットしない
--   というバグになっていた（クエリ側だけ検索, 索エ, エン, ンジ, ジン, ン
--   の6トークンになり、6番目の "ン" の位置が文書側と噛み合わない）。
--
--   実際には bi-gram の並びだけで元の文字列は一意に復元できるので
--   （"ジン" が分かればその中に「5文字目=ジ, 6文字目=ン」が含まれている）、
--   末尾の uni-gram は情報として完全に冗長。フレーズの連続性判定には
--   不要なので、素直に省く。
--
--   ラン長が1文字だけの場合は bi-gram が作れないので、その1文字を
--   そのまま使う（この場合は普通の単語検索と同じ挙動になる）。
local function phrase_tokenize(text)
  local cs = to_chars(text:lower())
  local tokens = {}

  local i = 1
  while i <= #cs do
    local c = cs[i]
    if is_ascii(c) then
      if c:match("[%w]") then
        local buf = { c }
        i = i + 1
        while i <= #cs and is_ascii(cs[i]) and cs[i]:match("[%w]") do
          buf[#buf + 1] = cs[i]
          i = i + 1
        end
        tokens[#tokens + 1] = table.concat(buf)
      else
        i = i + 1
      end
    else
      -- 非ASCIIランの終端 j を探す
      local j = i
      while j + 1 <= #cs and not is_ascii(cs[j + 1]) do
        j = j + 1
      end
      if j == i then
        tokens[#tokens + 1] = c   -- ラン長1: bi-gram が作れないのでそのまま
      else
        for k = i, j - 1 do
          tokens[#tokens + 1] = cs[k] .. cs[k + 1]
        end
      end
      i = j + 1
    end
  end

  return tokens
end

--------------------------------------------------------------------
-- 2. インデックス構造
--------------------------------------------------------------------
-- postings[term] = { {id=..., tf=...}, {id=..., tf=...}, ... }
--   ↑ これが「転置インデックス」。
--     普通のインデックス（文書 → 単語）を逆さまにして
--     単語 → その語を含む文書のリスト、という形で持つ。
--     検索時に全文書を走査せず、語から一発で候補が引けるのが利点。
--
-- df[term]  = その語を含む文書数（Document Frequency）
-- len[id]   = 文書のトークン数（文書長。BM25 の正規化に使う）

function M.new()
  return {
    docs      = {},   -- id -> {title=, body=}
    postings  = {},   -- term -> posting list
    df        = {},   -- term -> document frequency
    len       = {},   -- id -> document length
    N         = 0,    -- 総文書数
    total_len = 0,    -- 全文書のトークン数合計
    -- _sorted_terms    : 前方一致検索用のソート済み語彙キャッシュ（遅延構築）
    -- _postings_sorted : 各 postings[term] を doc_id 昇順にソート済みか（AND検索用）
    --                 postings を変更したら両方 nil/false にして作り直させる
  }
end

function M.add(idx, id, title, body)
  if idx.docs[id] then
    error("duplicate document id: " .. tostring(id))
  end

  idx._sorted_terms    = nil     -- 語彙が増えるのでキャッシュを捨てる
  idx._postings_sorted = false   -- 新しい doc_id が挿入されるのでソート済み扱いを取り消す

  local tokens = M.tokenize(title .. " " .. body)

  idx.N         = idx.N + 1
  idx.docs[id]  = { title = title, body = body }
  idx.len[id]   = #tokens
  idx.total_len = idx.total_len + #tokens

  -- 文書内での出現位置(トークン列でのインデックス、1始まり)を語ごとに集める。
  -- tf はこの配列の長さとして導出する（フレーズ検索用の位置情報と
  -- 二重管理にならないよう、tf を独立した値として持たない）。
  local occ = {}
  for i, t in ipairs(tokens) do
    local positions = occ[t]
    if not positions then
      positions = {}
      occ[t] = positions
    end
    positions[#positions + 1] = i
  end

  -- posting list に追加
  for term, positions in pairs(occ) do
    local p = idx.postings[term]
    if not p then
      p = {}
      idx.postings[term] = p
      idx.df[term] = 0
    end
    p[#p + 1] = { id = id, tf = #positions, positions = positions }
    idx.df[term] = idx.df[term] + 1
  end
end

--------------------------------------------------------------------
-- 3. BM25 スコアリング
--------------------------------------------------------------------
-- score(D, Q) = Σ IDF(q) * ( tf * (k1+1) ) / ( tf + k1*(1 - b + b*|D|/avgdl) )
--
--   IDF  : 珍しい語ほど高得点（「の」みたいな頻出語を軽くする）
--   tf   : 出現回数が多いほど高得点。ただし k1 で飽和させる
--   |D|/avgdl : 長い文書が有利になりすぎないよう正規化。b がその強さ

local K1 = 1.2   -- tf の飽和度。定番は 1.2〜2.0
local B  = 0.75  -- 文書長正規化の強さ。0 で無効、1 で最大

-- 1語1文書分の BM25 スコア成分。M.search と M.search_and の両方から使う
-- （同じ式を2箇所に書いて片方だけ直し忘れる、という事故を防ぐため共通化）。
local function bm25_component(idx, avgdl, idf, doc_id, tf)
  local dl   = idx.len[doc_id]
  local norm = tf + K1 * (1 - B + B * dl / avgdl)
  return idf * (tf * (K1 + 1)) / norm
end

--------------------------------------------------------------------
-- 3.5 英数字トークンの前方一致展開
--------------------------------------------------------------------
-- 課題: トークナイザは ASCII を「単語単位」で切るので、
--       "lua" で検索しても "luajit" を含む文書に当たらなかった。
--
-- 方針: インデックスの持ち方は変えず、*検索時* にクエリ語を
--       「その語で始まる語彙すべて」に展開して OR 検索する。
--       lua → {lua, luajit, luarocks, ...}
--
--       インデックスが肥大しない／保存形式を変えなくてよいのが利点。
--       代わりに検索のたびに語彙を引く必要があるので、
--       ソート済みの語彙配列を作って二分探索で範囲を絞る。
--       （前方一致する語はソート順で必ず連続して並ぶ、という性質を使う）

local PREFIX_MIN = 2   -- これより短いクエリ語は展開しない（"a" が全部に当たるのを防ぐ）

-- postings のキーをソートした配列を返す（idx にキャッシュする）
local function sorted_terms(idx)
  local cached = idx._sorted_terms
  if cached then return cached end

  local arr = {}
  for term in pairs(idx.postings) do
    arr[#arr + 1] = term
  end
  table.sort(arr)
  idx._sorted_terms = arr
  return arr
end

-- arr の中で key 以上の値が現れる最初の位置（C++ の lower_bound 相当）
local function lower_bound(arr, key)
  local lo, hi = 1, #arr + 1
  while lo < hi do
    local mid = (lo + hi) // 2
    if arr[mid] < key then lo = mid + 1 else hi = mid end
  end
  return lo
end

-- クエリ語を「それで始まる語彙のリスト」に展開する
local function expand_prefix(idx, term)
  -- 日本語 bi-gram は常に2文字なので前方一致しても自分自身しか出てこない。
  -- 展開の対象は ASCII 英数字トークンだけに限る。
  if #term < PREFIX_MIN or not term:match("^[%w]+$") then
    return { term }
  end

  local arr  = sorted_terms(idx)
  local out  = {}
  local i    = lower_bound(arr, term)
  while i <= #arr and arr[i]:sub(1, #term) == term do
    out[#out + 1] = arr[i]
    i = i + 1
  end
  return out
end

-- 展開した語を「1つの語」とみなして BM25 の材料（df と tf）を合成する。
--
-- ここが前方一致検索のキモ。展開語をバラバラに BM25 にかけて足すと壊れる:
--   コーパスの 5/6 に "lua" があり "luajit" が 1文書だけ、という状況だと
--   珍しい "luajit" の IDF が "lua" の 6倍以上になり、
--   「"lua" で検索したのに lua を含まない文書が1位」という結果になる。
--   （実測: OpenResty 1.6263 vs Lua入門 0.3172）
--
-- なので lua* というグループを 1語として扱う:
--   df  = 展開語の *いずれか* を含む文書数（和集合の要素数）
--   tf  = その文書内での展開語の出現回数の合計
-- こうすれば IDF はグループにつき1回だけ計算され、歪みが起きない。
local function merge_group(idx, terms)
  local tf_sum = {}   -- doc_id -> tf の合計
  local ids    = {}   -- 出現順の doc_id リスト（= 和集合）

  for _, term in ipairs(terms) do
    local plist = idx.postings[term]
    if plist then
      for _, e in ipairs(plist) do
        if tf_sum[e.id] == nil then
          tf_sum[e.id] = 0
          ids[#ids + 1] = e.id
        end
        tf_sum[e.id] = tf_sum[e.id] + e.tf
      end
    end
  end

  return ids, tf_sum
end

function M.search(idx, query, limit, opts)
  limit = limit or 10
  if idx.N == 0 then return {} end

  opts = opts or {}
  local use_prefix = opts.prefix
  if use_prefix == nil then use_prefix = true end

  local avgdl  = idx.total_len / idx.N
  local scores = {}
  local hits   = {}

  for _, qterm in ipairs(M.tokenize(query)) do
    local terms = use_prefix and expand_prefix(idx, qterm) or { qterm }
    local ids, tf_sum = merge_group(idx, terms)

    local df = #ids   -- 和集合の大きさがそのままグループの df
    if df > 0 then
      local idf = math.log(1 + (idx.N - df + 0.5) / (df + 0.5))

      for _, id in ipairs(ids) do
        local tf = tf_sum[id]
        local s  = bm25_component(idx, avgdl, idf, id, tf)

        if scores[id] == nil then
          scores[id] = 0
          hits[#hits + 1] = id
        end
        scores[id] = scores[id] + s
      end
    end
  end

  table.sort(hits, function(a, b)
    if scores[a] == scores[b] then return tostring(a) < tostring(b) end
    return scores[a] > scores[b]
  end)

  local results = {}
  for i = 1, math.min(limit, #hits) do
    local id = hits[i]
    results[i] = {
      id    = id,
      score = scores[id],
      title = idx.docs[id].title,
      body  = idx.docs[id].body,
    }
  end
  return results
end

--------------------------------------------------------------------
-- 3.6 フレーズ検索
--------------------------------------------------------------------
-- クエリのトークン列がそのままの並びで隣接して出現する文書だけを返す。
-- 例: "検索エンジン" は bi-gram で 検索,索エ,エン,ンジ,ジン に分かれるので、
--     ある文書内でこれら5トークンの出現位置が連番（p, p+1, p+2, p+3, p+4）に
--     なっている箇所があれば一致とみなす。
--
-- 通常の M.search（BM25 / OR検索 / 前方一致展開）とは別の関数にしている。
-- 理由: フレーズ検索は「厳密な語のみ・位置が合うものだけ」を求める性質上、
-- 前方一致展開（あいまい一致）や BM25（スコアの重ね合わせ）とは相性が悪く、
-- 混ぜるとクエリ意味論が複雑になる（Elasticsearch 等でも match_phrase は
-- 通常の match とは別クエリタイプとして分離されている）。
--
-- スコアの代わりに、その文書内でフレーズが何回出現したか(count)を返す。
function M.search_phrase(idx, phrase, limit)
  limit = limit or 10
  local tokens = phrase_tokenize(phrase)
  if #tokens == 0 or idx.N == 0 then return {} end

  -- 各トークンについて「doc_id -> 位置の集合(set)」を作る。
  -- 1語でもインデックスに存在しなければ、どの文書もフレーズ全体には一致し得ない。
  local term_maps = {}
  for i, t in ipairs(tokens) do
    local plist = idx.postings[t]
    if not plist then return {} end

    local by_doc = {}
    for _, e in ipairs(plist) do
      local set = {}
      for _, p in ipairs(e.positions) do
        set[p] = true
      end
      by_doc[e.id] = set
    end
    term_maps[i] = by_doc
  end

  -- 候補文書は「先頭トークンを含む文書」に限定できる
  -- （フレーズが一致するなら先頭トークンは必ずそこにあるため）。
  local hits    = {}
  local counts  = {}
  local first_map = term_maps[1]

  for doc_id in pairs(idx.docs) do
    local start_positions = first_map[doc_id]
    if start_positions then
      local n = 0
      for start_pos in pairs(start_positions) do
        local matched = true
        for i = 2, #tokens do
          local set = term_maps[i][doc_id]
          if not set or not set[start_pos + (i - 1)] then
            matched = false
            break
          end
        end
        if matched then
          n = n + 1
        end
      end
      if n > 0 then
        counts[doc_id] = n
        hits[#hits + 1] = doc_id
      end
    end
  end

  table.sort(hits, function(a, b)
    if counts[a] == counts[b] then return tostring(a) < tostring(b) end
    return counts[a] > counts[b]
  end)

  local results = {}
  for i = 1, math.min(limit, #hits) do
    local id = hits[i]
    results[i] = {
      id    = id,
      count = counts[id],
      title = idx.docs[id].title,
      body  = idx.docs[id].body,
    }
  end
  return results
end

--------------------------------------------------------------------
-- 3.7 AND検索（マージアルゴリズム）
--------------------------------------------------------------------
-- クエリの全語を含む文書だけを返す。M.search は「1語でも含めば候補、
-- 含む語が多いほど高スコア」という OR 検索なので、それとは別に用意する。
--
-- 素朴にやるなら「1語目の posting list を舐めて、他の全語について
-- その doc_id を含むか調べる」で済むが、それだと語ごとに毎回
-- 線形/ハッシュ探索が必要になる。ここでは各 posting list を
-- doc_id 昇順にソートしておき、2本のポインタを同時に進める
-- 「マージアルゴリズム」（ソート済み配列のマージソートの併合部分と同じ発想）
-- で共通部分を求める。両方とも昇順なので、小さい方のポインタだけを
-- 進めれば取りこぼしなく O(n+m) で交差が取れる。

-- 各 posting list を doc_id 昇順にソートする（idx にキャッシュする）。
-- 語彙全体を毎回ソートするのは無駄なので、まだの語だけ直す設計にはせず
-- 「全部まとめてソート済みか」という1個のフラグで管理する。
-- postings は M.add / M.load でしか変化しないので、キャッシュの粒度としては
-- これで十分（_sorted_terms と同じ考え方）。
local function ensure_postings_sorted(idx)
  if idx._postings_sorted then return end
  for _, plist in pairs(idx.postings) do
    table.sort(plist, function(a, b) return a.id < b.id end)
  end
  idx._postings_sorted = true
end

-- 2本の doc_id 昇順配列を併合して共通部分を求める（マージアルゴリズム本体）。
local function merge_intersect_ids(a, b)
  local result = {}
  local i, j = 1, 1
  while i <= #a and j <= #b do
    if a[i] == b[j] then
      result[#result + 1] = a[i]
      i = i + 1
      j = j + 1
    elseif a[i] < b[j] then
      i = i + 1
    else
      j = j + 1
    end
  end
  return result
end

function M.search_and(idx, query, limit)
  limit = limit or 10
  if idx.N == 0 then return {} end

  -- クエリのトークン化には M.tokenize ではなく phrase_tokenize を使う。
  -- 理由は M.search_phrase と同じ: M.tokenize は非ASCIIランの末尾で
  -- 重複 uni-gram を出す仕様があり、空白区切りの複数語クエリ
  -- （"転置 BM25" のように語の直後に空白が来る）だと、その空白の
  -- 直前でランが終わるたびに余計な必須語が混入してしまう。
  -- 例: M.tokenize("検索 エンジン") には 索, ン という孤立文字が
  -- 紛れ込み、AND条件として絶対に満たせない語が混ざってしまっていた。
  --
  -- なお AND検索は「クエリの各 bi-gram がその文書のどこかに存在するか」
  -- を見るだけで、隣接（＝phrase一致）までは要求しない。そのため
  -- 「エン・ンジ・ジン が別々の場所に散らばっているだけの文書」を
  -- 誤ってヒットさせる可能性はある（n-gram索引でのAND検索によくある
  -- 近似で、フレーズとしての厳密一致が要るなら M.search_phrase を使う）。
  local seen  = {}
  local terms = {}
  for _, t in ipairs(phrase_tokenize(query)) do
    if not seen[t] then
      seen[t] = true
      terms[#terms + 1] = t
    end
  end
  if #terms == 0 then return {} end

  -- 1語でもインデックスに無い語があれば、AND条件は絶対に満たせない
  for _, t in ipairs(terms) do
    if not idx.postings[t] then return {} end
  end

  ensure_postings_sorted(idx)

  -- doc_id だけの配列を語ごとに取り出す（postings は既に doc_id 昇順）
  local id_lists = {}
  for i, t in ipairs(terms) do
    local ids = {}
    for _, e in ipairs(idx.postings[t]) do
      ids[#ids + 1] = e.id
    end
    id_lists[i] = ids
  end

  -- 短いリストほど早く候補を絞れるので、要素数が少ない順に併合する
  table.sort(id_lists, function(a, b) return #a < #b end)

  local candidate_ids = id_lists[1]
  for i = 2, #id_lists do
    candidate_ids = merge_intersect_ids(candidate_ids, id_lists[i])
    if #candidate_ids == 0 then return {} end
  end

  -- 交差が求まった文書集合だけを対象に BM25 でスコアリングして並べる
  -- （AND条件で絞り込んだ後の順位付けなので、通常の M.search と同じ式を使う）
  local candidate_set = {}
  for _, id in ipairs(candidate_ids) do
    candidate_set[id] = true
  end

  local avgdl  = idx.total_len / idx.N
  local scores = {}
  for _, term in ipairs(terms) do
    local df  = idx.df[term]
    local idf = math.log(1 + (idx.N - df + 0.5) / (df + 0.5))

    for _, e in ipairs(idx.postings[term]) do
      if candidate_set[e.id] then
        scores[e.id] = (scores[e.id] or 0) + bm25_component(idx, avgdl, idf, e.id, e.tf)
      end
    end
  end

  table.sort(candidate_ids, function(a, b)
    if scores[a] == scores[b] then return tostring(a) < tostring(b) end
    return scores[a] > scores[b]
  end)

  local results = {}
  for i = 1, math.min(limit, #candidate_ids) do
    local id = candidate_ids[i]
    results[i] = {
      id    = id,
      score = scores[id],
      title = idx.docs[id].title,
      body  = idx.docs[id].body,
    }
  end
  return results
end

--------------------------------------------------------------------
-- 4. 統計情報（デバッグ用）
--------------------------------------------------------------------
function M.stats(idx)
  local terms, postings = 0, 0
  for _, p in pairs(idx.postings) do
    terms = terms + 1
    postings = postings + #p
  end
  return {
    docs     = idx.N,
    terms    = terms,
    postings = postings,
    avgdl    = idx.N > 0 and idx.total_len / idx.N or 0,
  }
end

--------------------------------------------------------------------
-- 5. SQLite への永続化
--------------------------------------------------------------------
-- テーブル設計:
--   docs     (id, title, body, len)         -- 文書本体と長さ
--   postings (term, doc_id, pos)            -- 出現ごとに1行（フレーズ検索用の位置情報）
--            UNIQUE(term, doc_id, pos) が付いており、同じ出現の二重登録を防ぐ
--   meta     (key, value)                   -- N, total_len
--
-- df（何文書に含まれるか）と tf（文書内の出現回数）はあえて保存しない。
-- postings から COUNT(DISTINCT doc_id) / COUNT(*) で復元できるものを
-- 別テーブルや別カラムに二重管理すると、更新のたびに同期がズレる危険があるため。
-- これは1行1出現にしたことで tf も df と同じ理屈で導出できるようになった。
--
-- 索引について: UNIQUE(term, doc_id, pos) は SQLite が自動でこの3列複合の
-- 索引を作る。B-treeは左端一致（leftmost prefix）で使えるので、
-- 「term だけで検索」「term と doc_id で検索」のどちらもこの1本の索引で
-- まかなえる。以前あった idx_postings_term / idx_postings_term_doc という
-- 別々の索引は冗長になったため、この UNIQUE 制約の追加を機に整理した。

local sqlite3 = require("lsqlite3")

local function checked(db, ok, ...)
  if not ok then
    error("sqlite error: " .. db:errmsg())
  end
  return ...
end

-- スキーマを作成する（既にあれば何もしない）
local function ensure_schema(db)
  checked(db, db:exec([[
    CREATE TABLE IF NOT EXISTS docs (
      id    INTEGER PRIMARY KEY,
      title TEXT NOT NULL,
      body  TEXT NOT NULL,
      len   INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS postings (
      term   TEXT NOT NULL,
      doc_id INTEGER NOT NULL,
      pos    INTEGER NOT NULL,
      UNIQUE(term, doc_id, pos)
    );

    CREATE TABLE IF NOT EXISTS meta (
      key   TEXT PRIMARY KEY,
      value TEXT NOT NULL
    );
  ]]) == sqlite3.OK)
end

-- idx をまるごと SQLite ファイルに書き出す（既存の内容は上書き）
function M.save(idx, path)
  local db = sqlite3.open(path)
  ensure_schema(db)

  checked(db, db:exec("BEGIN TRANSACTION;") == sqlite3.OK)
  checked(db, db:exec("DELETE FROM docs;")     == sqlite3.OK)
  checked(db, db:exec("DELETE FROM postings;") == sqlite3.OK)
  checked(db, db:exec("DELETE FROM meta;")     == sqlite3.OK)

  local doc_stmt = db:prepare(
    "INSERT INTO docs (id, title, body, len) VALUES (?, ?, ?, ?)")
  for id, d in pairs(idx.docs) do
    doc_stmt:bind(1, id)
    doc_stmt:bind(2, d.title)
    doc_stmt:bind(3, d.body)
    doc_stmt:bind(4, idx.len[id])
    if doc_stmt:step() ~= sqlite3.DONE then
      error("insert doc failed: " .. db:errmsg())
    end
    doc_stmt:reset()
  end
  doc_stmt:finalize()

  local post_stmt = db:prepare(
    "INSERT INTO postings (term, doc_id, pos) VALUES (?, ?, ?)")
  for term, plist in pairs(idx.postings) do
    for _, e in ipairs(plist) do
      for _, pos in ipairs(e.positions) do
        post_stmt:bind(1, term)
        post_stmt:bind(2, e.id)
        post_stmt:bind(3, pos)
        if post_stmt:step() ~= sqlite3.DONE then
          error("insert posting failed: " .. db:errmsg())
        end
        post_stmt:reset()
      end
    end
  end
  post_stmt:finalize()

  local meta_stmt = db:prepare(
    "INSERT INTO meta (key, value) VALUES (?, ?)")
  for _, kv in ipairs({ { "N", idx.N }, { "total_len", idx.total_len } }) do
    meta_stmt:bind(1, kv[1])
    meta_stmt:bind(2, tostring(kv[2]))
    if meta_stmt:step() ~= sqlite3.DONE then
      error("insert meta failed: " .. db:errmsg())
    end
    meta_stmt:reset()
  end
  meta_stmt:finalize()

  checked(db, db:exec("COMMIT;") == sqlite3.OK)
  db:close()
end

-- SQLite ファイルから idx を復元する
function M.load(path)
  local db = sqlite3.open(path)
  ensure_schema(db)

  local idx = M.new()

  for row in db:nrows("SELECT id, title, body, len FROM docs") do
    idx.docs[row.id] = { title = row.title, body = row.body }
    idx.len[row.id]  = row.len
  end

  -- postings は「出現ごとに1行」で保存されているので、(term, doc_id) ごとに
  -- 位置情報を集約してから idx.postings[term] のエントリを組み立てる。
  -- ORDER BY pos で読むことで、positions 配列がトークン出現順になる
  -- （フレーズ検索は隣接判定に絶対位置しか使わないため順序自体は必須ではないが、
  --  デバッグ時に見やすいので揃えておく）。
  local by_term_doc = {}   -- term -> doc_id -> positions
  for row in db:nrows("SELECT term, doc_id, pos FROM postings ORDER BY term, doc_id, pos") do
    local by_doc = by_term_doc[row.term]
    if not by_doc then
      by_doc = {}
      by_term_doc[row.term] = by_doc
    end
    local positions = by_doc[row.doc_id]
    if not positions then
      positions = {}
      by_doc[row.doc_id] = positions
    end
    positions[#positions + 1] = row.pos
  end

  for term, by_doc in pairs(by_term_doc) do
    local p = {}
    for doc_id, positions in pairs(by_doc) do
      p[#p + 1] = { id = doc_id, tf = #positions, positions = positions }
    end
    idx.postings[term] = p
  end

  -- df は postings から復元する（保存していないため）
  for term, plist in pairs(idx.postings) do
    idx.df[term] = #plist
  end

  idx._sorted_terms    = nil     -- 読み込みで語彙が入れ替わるのでキャッシュを無効化
  idx._postings_sorted = false   -- load 直後の並び順は未保証（下記 M.load 参照）

  for row in db:nrows("SELECT key, value FROM meta") do
    if row.key == "N" then
      idx.N = tonumber(row.value)
    elseif row.key == "total_len" then
      idx.total_len = tonumber(row.value)
    end
  end

  db:close()
  return idx
end

return M
