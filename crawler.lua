-- crawler.lua : 起点URL(urls.txt)からリンクを辿って同一ドメイン内を
-- 幅優先探索(BFS)でクロールし、HTMLから本文を抜き出してインデックス化する
--
-- 使い方: lua5.4 crawler.lua
--   1. urls.txt (1行1URL) を「クロールの起点(シード)」として読み込む
--   2. シードに含まれるドメインだけを対象に、ページ内の <a href> を
--      辿って幅優先探索する（無関係な外部ドメインへは広がらない）
--   3. 各ドメインの robots.txt を尊重する（Disallow/Allow/Crawl-delay）
--   4. MAX_PAGES 件 or MAX_DEPTH 階層に達したら打ち切る
--   5. <title> とタグを除去した本文をインデックスに追加する
--   6. crawled.db に保存する（build_index.lua が作る search.db とは別ファイル）
--
-- 以前のバージョン（urls.txt を単に取得するだけ）との違い:
--   ページ内のリンクを辿って自動的に対象を広げる。ただし無制限に広がると
--   対象サーバへの負荷や無関係なドメインへの越境が起きるため、
--   同一ドメイン限定・件数上限・深さ上限・robots.txt遵守・取得間隔、
--   の5つで歯止めをかけている。
local http    = require("socket.http")
local https   = require("ssl.https")
local ltn12   = require("ltn12")
local socket  = require("socket")
local urllib  = require("socket.url")
local Index   = require("index")

local USER_AGENT       = "LuaSearchEngineLearningCrawler/0.1 (+https://github.com/Chloro989/lua_search)"
-- robots.txt の "User-agent:" 行とマッチングする際に使うトークン
-- （USER_AGENT からバージョン番号やURLの説明部分を除いた「名前」だけの版）
local ROBOTS_AGENT_TOKEN = "luasearchenginelearningcrawler"

local FETCH_DELAY = 1.2   -- 秒。1リクエストごとに空ける最低間隔（robots.txtのCrawl-delayが
                           -- これより長ければそちらを優先する）
local MAX_PAGES    = 20   -- 実際にHTTPリクエストを送る回数の上限（対象サーバへの配慮）
local MAX_DEPTH    = 3    -- 起点からのリンク階層の上限（0=起点そのもの）

--------------------------------------------------------------------
-- 大文字小文字を区別しないタグ/属性マッチ用のヘルパー
--------------------------------------------------------------------
-- Luaの文字列パターンには大文字小文字を区別しないマッチが無いので、
-- 各アルファベットを [Aa] のような文字クラスに展開して代用する。
-- lua.org の一部ページが <TITLE>（大文字）でタグを書いていたための対策
-- （前回の作業で発覚。詳細は HANDOFF.md）。
local function ci(tag)
  return (tag:gsub("%a", function(c) return "[" .. c:lower() .. c:upper() .. "]" end))
end

--------------------------------------------------------------------
-- HTTP/HTTPS 取得
--------------------------------------------------------------------
local function read_seeds(path)
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

-- 生のHTTP/HTTPS GET。robots.txt取得と本文取得の両方から使う共通部分。
-- テーブル形式のリクエストにすると User-Agent ヘッダーを付けられる
-- （対象サイトに「何者からのアクセスか」を名乗るのが礼儀のため）。
local function fetch_raw(target_url)
  local request
  if target_url:match("^https://") then
    request = https.request
  elseif target_url:match("^http://") then
    request = http.request
  else
    return nil, nil, "http:// または https:// で始まるURLではありません"
  end

  local response = {}
  local ok, code, headers, status = request{
    url     = target_url,
    sink    = ltn12.sink.table(response),
    headers = { ["User-Agent"] = USER_AGENT },
  }
  if not ok or code ~= 200 then
    return nil, nil, string.format("HTTP %s", tostring(code or status))
  end
  local content_type = headers and headers["content-type"] or ""
  return table.concat(response), content_type
end

--------------------------------------------------------------------
-- 文字コード変換（ISO-8859-1 → UTF-8）
--------------------------------------------------------------------
-- index.lua のトークナイザはUTF-8前提。lua.org は大半のページがUTF-8だが、
-- portugues.html のような一部の古いページは ISO-8859-1 (Latin-1) で
-- 書かれており、そのまま渡すとタイトルや本文が文字化けする
-- （実際にBFSクロールのテスト中に遭遇した）。
--
-- ISO-8859-1 は1バイト=1文字で、そのバイト値がそのままUnicodeのコード
-- ポイントと一致する（0x00-0xFF がそのまま U+0000-U+00FF）という
-- 性質があるため、外部ライブラリなしで単純な変換ができる。
-- 0x00-0x7F はASCIIと共通なのでそのまま、0x80-0xFF は2バイトのUTF-8
-- シーケンスに変換する。
local function iso8859_1_to_utf8(s)
  return (s:gsub("[\128-\255]", function(c)
    local cp = c:byte()
    return string.char(0xC0 | (cp >> 6), 0x80 | (cp & 0x3F))
  end))
end

-- Content-Type ヘッダーと <meta charset> の両方から文字コード宣言を探す
-- （どちらか一方にしか書かれていないページがあるため）。
local function detect_charset(content_type, html)
  local c = content_type and content_type:match("charset=([%w%-]+)")
  if not c then
    c = html:match(ci("charset") .. "%s*=%s*[\"']?([%w%-]+)")
  end
  return c and c:lower() or nil
end

-- 検出した文字コードに応じてUTF-8へ正規化する。ISO-8859-1 と Windows-1252
-- は0x80-0x9Fの範囲だけ意味が異なる（Windows-1252はその範囲に印刷可能な
-- 記号を割り当てている）が、本文中に出現する頻度は低いため、簡易実装として
-- 両方まとめてISO-8859-1として変換する（学習用途としての割り切り）。
-- 宣言が無い、またはUTF-8ならそのまま返す。
local function normalize_charset(html, content_type)
  local charset = detect_charset(content_type, html)
  if charset == "iso-8859-1" or charset == "latin1" or charset == "windows-1252" then
    return iso8859_1_to_utf8(html)
  end
  return html
end

--------------------------------------------------------------------
-- robots.txt
--------------------------------------------------------------------
-- 簡易パーサ: User-agent / Disallow / Allow / Crawl-delay のみ対応。
-- Disallow / Allow の値は前方一致のみで判定し、Googleが独自拡張した
-- ワイルドカード(*)や末尾アンカー($)には対応しない（学習用途としての
-- 割り切り。標準的な robots.txt の大半はこれで十分カバーできる）。
--
-- グループ選択: 連続する "User-agent:" 行は同じグループとしてまとめ、
-- 次に Disallow/Allow が1つでも現れたらそこでグループが確定する。
-- 自分の ROBOTS_AGENT_TOKEN に完全一致するグループがあればそれを優先し、
-- なければ "*" のグループを使う。該当グループが無ければ制限なし扱い。
local function parse_robots(text, agent_token)
  local groups = {}
  local current = nil

  for line in (text .. "\n"):gmatch("(.-)\n") do
    line = line:gsub("#.*$", "")
    line = line:match("^%s*(.-)%s*$")
    if #line > 0 then
      local key, value = line:match("^([%w-]+)%s*:%s*(.*)$")
      if key then
        key = key:lower()
        if key == "user-agent" then
          if not current or #current.rules > 0 then
            current = { agents = {}, rules = {}, crawl_delay = nil }
            groups[#groups + 1] = current
          end
          current.agents[#current.agents + 1] = value:lower()
        elseif current then
          if key == "disallow" and #value > 0 then
            current.rules[#current.rules + 1] = { path = value, allow = false }
          elseif key == "allow" and #value > 0 then
            current.rules[#current.rules + 1] = { path = value, allow = true }
          elseif key == "crawl-delay" then
            current.crawl_delay = tonumber(value)
          end
        end
      end
    end
  end

  local exact, wildcard
  for _, g in ipairs(groups) do
    for _, a in ipairs(g.agents) do
      if a == agent_token then exact = exact or g end
      if a == "*" then wildcard = wildcard or g end
    end
  end
  return exact or wildcard
end

-- path が group のルールで許可されているか。Disallow/Allow のうち
-- 最長一致したパターンを優先する（規約上の一般的な解決方法）。
-- 一致するルールが無ければデフォルトで許可。
local function path_allowed(group, path)
  if not group then return true end
  local best_len, best_allow = -1, true
  for _, r in ipairs(group.rules) do
    if path:sub(1, #r.path) == r.path and #r.path > best_len then
      best_len, best_allow = #r.path, r.allow
    end
  end
  return best_allow
end

local robots_cache = {}   -- "scheme://host" -> group または false(制限なし)

local function fetch_robots(scheme, host)
  local key = scheme .. "://" .. host
  if robots_cache[key] ~= nil then return robots_cache[key] or nil end

  local body = fetch_raw(key .. "/robots.txt")
  local group = body and parse_robots(body, ROBOTS_AGENT_TOKEN) or nil
  robots_cache[key] = group or false
  return group
end

local function is_allowed(scheme, host, path)
  return path_allowed(fetch_robots(scheme, host), path)
end

local function delay_for(scheme, host)
  local group = fetch_robots(scheme, host)
  if group and group.crawl_delay and group.crawl_delay > FETCH_DELAY then
    return group.crawl_delay
  end
  return FETCH_DELAY
end

--------------------------------------------------------------------
-- URL正規化・リンク抽出
--------------------------------------------------------------------
-- フラグメント(#...)を取り除き、ホスト名を小文字化して正規化する。
-- 同じページを指す "foo.html" と "foo.html#section" を別URL扱いして
-- 二重にクロールしてしまうのを防ぐのが目的。
local function normalize_link(u)
  local ok, parsed = pcall(urllib.parse, u)
  if not ok or not parsed or not parsed.scheme or not parsed.host then return nil end
  local scheme = parsed.scheme:lower()
  if scheme ~= "http" and scheme ~= "https" then return nil end

  parsed.fragment = nil
  parsed.userinfo = nil
  parsed.host = parsed.host:lower()
  if not parsed.path or parsed.path == "" then parsed.path = "/" end

  local ok2, built = pcall(urllib.build, parsed)
  if not ok2 then return nil end
  return built
end

local function host_of(u)
  local ok, parsed = pcall(urllib.parse, u)
  return ok and parsed and parsed.host and parsed.host:lower() or nil
end

-- html 中の <a href="..."> をすべて拾い、base_url を基準に絶対URL化する。
-- ちゃんとしたHTMLパーサは使わず正規表現ベース（学習用途としての割り切り。
-- extract_body_text と同じ理由・同じ限界）。
local A_TAG_PATTERN    = ci("<a") .. "%f[%A][^>]->"
local HREF_ATTR_PATTERN = ci("href")

local function extract_links(html, base_url)
  local links = {}
  local seen  = {}

  for tag in html:gmatch(A_TAG_PATTERN) do
    local href = tag:match(HREF_ATTR_PATTERN .. "%s*=%s*\"([^\"]*)\"")
              or tag:match(HREF_ATTR_PATTERN .. "%s*=%s*'([^']*)'")
              or tag:match(HREF_ATTR_PATTERN .. "%s*=%s*([^%s>]+)")
    if href and #href > 0 then
      local ok, abs = pcall(urllib.absolute, base_url, href)
      if ok and abs then
        local norm = normalize_link(abs)
        if norm and not seen[norm] then
          seen[norm] = true
          links[#links + 1] = norm
        end
      end
    end
  end
  return links
end

--------------------------------------------------------------------
-- HTML→テキスト変換（前バージョンから変更なし）
--------------------------------------------------------------------
local TITLE_PATTERN  = ci("<title") .. "[^>]*>(.-)" .. ci("</title>")
local SCRIPT_PATTERN = ci("<script") .. ".-" .. ci("</script>")
local STYLE_PATTERN  = ci("<style") .. ".-" .. ci("</style>")

local function extract_title(html)
  local t = html:match(TITLE_PATTERN)
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
  s = s:gsub(SCRIPT_PATTERN, " ")
  s = s:gsub(STYLE_PATTERN, " ")
  s = s:gsub("<!%-%-.-%-%->", " ")
  s = s:gsub("<[^>]+>", " ")   -- 残りの全タグを空白に置換（タグ名の大小は問わない）
  s = decode_entities(s)
  s = s:gsub("%s+", " ")
  return s:match("^%s*(.-)%s*$")
end

--------------------------------------------------------------------
-- 幅優先探索(BFS)クロール本体
--------------------------------------------------------------------
local seeds = read_seeds("urls.txt")
if #seeds == 0 then
  print("urls.txt にURLがありません")
  os.exit(1)
end

-- シードに含まれるドメインだけを対象にする（見知らぬドメインへ
-- 無制限に越境しないためのガード）
local allowed_domains = {}
for _, u in ipairs(seeds) do
  local h = host_of(u)
  if h then allowed_domains[h] = true end
end

local queue   = {}   -- FIFO。{url=, depth=}
local visited = {}
local head    = 1

for _, u in ipairs(seeds) do
  local norm = normalize_link(u)
  if norm and not visited[norm] then
    visited[norm] = true
    queue[#queue + 1] = { url = norm, depth = 0 }
  end
end

local idx           = Index.new()
local id            = 0
local pages_fetched = 0   -- 実際にHTTPリクエストを送った回数（MAX_PAGESの対象）
local attempt        = 0   -- 表示用の通し番号（スキップも含む）

while head <= #queue and pages_fetched < MAX_PAGES do
  local item = queue[head]
  head = head + 1
  attempt = attempt + 1

  local parsed = urllib.parse(item.url)
  local scheme, host, path = parsed.scheme, parsed.host, parsed.path or "/"

  io.write(string.format("[%d] depth=%d %s ... ", attempt, item.depth, item.url))
  io.flush()

  if not allowed_domains[host] then
    print("スキップ（対象ドメイン外）")
  elseif not is_allowed(scheme, host, path) then
    print("スキップ（robots.txtで禁止）")
  else
    pages_fetched = pages_fetched + 1
    local body, content_type, err = fetch_raw(item.url)

    if not body then
      print("失敗: " .. err)
    elseif content_type and not content_type:lower():match("text/html") then
      print("スキップ（非HTML: " .. content_type .. "）")
    else
      body = normalize_charset(body, content_type)
      local title = extract_title(body)
      local text  = extract_body_text(body)
      if #text == 0 then
        print("本文抽出できず")
      else
        id = id + 1
        Index.add(idx, id, title ~= "" and title or item.url, text)
        print(string.format("OK (title=%q, 本文%d文字)", title, #text))
      end

      if item.depth < MAX_DEPTH then
        for _, link in ipairs(extract_links(body, item.url)) do
          local lh = host_of(link)
          if lh and allowed_domains[lh] and not visited[link] then
            visited[link] = true
            queue[#queue + 1] = { url = link, depth = item.depth + 1 }
          end
        end
      end
    end

    socket.sleep(delay_for(scheme, host))
  end
end

if pages_fetched >= MAX_PAGES and head <= #queue then
  print(string.format(
    "MAX_PAGES(%d)に達したため打ち切り。キューに残り%d件あり（取得されなかった）",
    MAX_PAGES, #queue - head + 1))
end

local DB_PATH = "crawled.db"
Index.save(idx, DB_PATH)

local st = Index.stats(idx)
print()
print(string.format("保存完了: %s", DB_PATH))
print(string.format("文書数=%d  異なり語数=%d  posting総数=%d", st.docs, st.terms, st.postings))
