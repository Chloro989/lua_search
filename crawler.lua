-- crawler.lua : urls.txt に列挙したページを取得し、HTMLから本文を抜き出してインデックス化する
--
-- 使い方: lua5.4 crawler.lua
--   1. urls.txt (1行1URL、# で始まる行はコメント) を読み込む
--   2. socket.http で順番に取得する（サーバへの配慮として1リクエストごとに間隔をあける）
--   3. <title> とタグを除去した本文をインデックスに追加する
--   4. crawled.db に保存する（build_index.lua が作る search.db とは別ファイル）
--
-- 注意: これは「自分で列挙したURLだけ」を取得する。ページ内のリンクを辿って
-- 自動的に対象を広げる、いわゆる本格的なクロールはしない
-- （対象サイトへの意図しない大量アクセスを避けるための設計判断）。
--
-- 既知の制約: このリポジトリの実行環境では luasec (ssl.https) が
-- luasocket とバージョン非互換で HTTPS が使えない状態だった
-- （HANDOFF.md 参照）。そのため今のところ http:// のURLのみ対応。
-- https:// を渡すとエラーになる。
local http   = require("socket.http")
local socket = require("socket")
local Index  = require("index")

local USER_AGENT  = "LuaSearchEngineLearningCrawler/0.1 (+https://github.com/Chloro989/lua_search)"
local FETCH_DELAY = 1.2   -- 秒。対象サーバへの配慮として1リクエストごとに空ける

local function read_urls(path)
  local urls = {}
  local f = assert(io.open(path, "r"), "urls.txt が開けません: " .. path)
  for line in f:lines() do
    local u = line:match("^%s*(.-)%s*$")   -- 前後の空白を削る
    if #u > 0 and not u:match("^#") then   -- 空行と # コメント行は無視
      urls[#urls + 1] = u
    end
  end
  f:close()
  return urls
end

local function fetch(url)
  if not url:match("^http://") then
    return nil, "https:// は現状未対応です（HANDOFF.md 参照）。http:// のURLを使ってください"
  end
  local body, code, _, status = http.request(url)
  if not body or code ~= 200 then
    return nil, string.format("HTTP %s", tostring(code or status))
  end
  return body
end

--------------------------------------------------------------------
-- 最小限のHTML→テキスト変換。
-- ちゃんとしたHTMLパーサは使わず、正規表現でタグを除去するだけの簡易版
-- （学習用途として割り切り。壊れたHTMLやコメント内のタグっぽい文字列などで
--  誤動作する可能性はある）。
--------------------------------------------------------------------
local function extract_title(html)
  local t = html:match("<title[^>]*>(.-)</title>")
  if not t then return "" end
  return t:gsub("%s+", " "):match("^%s*(.-)%s*$")
end

local ENTITIES = {
  ["&amp;"] = "&", ["&lt;"] = "<", ["&gt;"] = ">",
  ["&quot;"] = '"', ["&#39;"] = "'", ["&nbsp;"] = " ",
}

local function decode_entities(s)
  return (s:gsub("&#?%w+;", function(e) return ENTITIES[e] or e end))
end

local function extract_body_text(html)
  local s = html
  s = s:gsub("<script.-</script>", " ")
  s = s:gsub("<style.-</style>", " ")
  s = s:gsub("<!%-%-.-%-%->", " ")
  s = s:gsub("<[^>]+>", " ")   -- 残りの全タグを空白に置換
  s = decode_entities(s)
  s = s:gsub("%s+", " ")
  return s:match("^%s*(.-)%s*$")
end

--------------------------------------------------------------------

local urls = read_urls("urls.txt")
if #urls == 0 then
  print("urls.txt にURLがありません")
  os.exit(1)
end

local idx = Index.new()
local id  = 0

for i, url in ipairs(urls) do
  io.write(string.format("[%d/%d] %s ... ", i, #urls, url))
  io.flush()

  local html, err = fetch(url)
  if not html then
    print("失敗: " .. err)
  else
    local title = extract_title(html)
    local body  = extract_body_text(html)
    if #body == 0 then
      print("本文抽出できず、スキップ")
    else
      id = id + 1
      Index.add(idx, id, title ~= "" and title or url, body)
      print(string.format("OK (title=%q, 本文%d文字)", title, #body))
    end
  end

  if i < #urls then
    socket.sleep(FETCH_DELAY)
  end
end

local DB_PATH = "crawled.db"
Index.save(idx, DB_PATH)

local st = Index.stats(idx)
print()
print(string.format("保存完了: %s", DB_PATH))
print(string.format("文書数=%d  異なり語数=%d  posting総数=%d", st.docs, st.terms, st.postings))
