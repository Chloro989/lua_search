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
-- 例: "検索エンジン" → 検索, 索エ, エン, ンジ, ジン
--     "Lua search"  → lua, search
--
-- 日本語を bi-gram にするのは、形態素解析器なしで
-- 「部分一致でも引っかかるインデックス」を作るための定番手法。
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
    -- _sorted_terms : 前方一致検索用のソート済み語彙キャッシュ（遅延構築）
    --                 postings を変更したら nil にして作り直させる
  }
end

function M.add(idx, id, title, body)
  if idx.docs[id] then
    error("duplicate document id: " .. tostring(id))
  end

  idx._sorted_terms = nil   -- 語彙が増えるのでキャッシュを捨てる

  local tokens = M.tokenize(title .. " " .. body)

  idx.N         = idx.N + 1
  idx.docs[id]  = { title = title, body = body }
  idx.len[id]   = #tokens
  idx.total_len = idx.total_len + #tokens

  -- まず文書内での出現回数(tf)を数える
  local tf = {}
  for _, t in ipairs(tokens) do
    tf[t] = (tf[t] or 0) + 1
  end

  -- posting list に追加
  for term, freq in pairs(tf) do
    local p = idx.postings[term]
    if not p then
      p = {}
      idx.postings[term] = p
      idx.df[term] = 0
    end
    p[#p + 1] = { id = id, tf = freq }
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
        local tf   = tf_sum[id]
        local dl   = idx.len[id]
        local norm = tf + K1 * (1 - B + B * dl / avgdl)
        local s    = idf * (tf * (K1 + 1)) / norm

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
--   postings (term, doc_id, tf)             -- 転置インデックスそのもの
--   meta     (key, value)                   -- N, total_len
--
-- df（何文書に含まれるか）はあえて保存しない。
-- postings から COUNT(DISTINCT doc_id) で復元できるものを
-- 別テーブルに二重管理すると、更新のたびに同期がズレる危険があるため。

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
      tf     INTEGER NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_postings_term
      ON postings(term);

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
    "INSERT INTO postings (term, doc_id, tf) VALUES (?, ?, ?)")
  for term, plist in pairs(idx.postings) do
    for _, e in ipairs(plist) do
      post_stmt:bind(1, term)
      post_stmt:bind(2, e.id)
      post_stmt:bind(3, e.tf)
      if post_stmt:step() ~= sqlite3.DONE then
        error("insert posting failed: " .. db:errmsg())
      end
      post_stmt:reset()
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

  for row in db:nrows("SELECT term, doc_id, tf FROM postings") do
    local p = idx.postings[row.term]
    if not p then
      p = {}
      idx.postings[row.term] = p
    end
    p[#p + 1] = { id = row.doc_id, tf = row.tf }
  end

  -- df は postings から復元する（保存していないため）
  for term, plist in pairs(idx.postings) do
    idx.df[term] = #plist
  end

  idx._sorted_terms = nil   -- 読み込みで語彙が入れ替わるのでキャッシュを無効化

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
