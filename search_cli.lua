-- search_cli.lua : SQLite からインデックスを読み込んで検索するだけの独立プロセス
-- build_index.lua と *メモリを共有していない* 別プロセスとして実行される点が重要。
local Index = require("index")

local DB_PATH = "search.db"
local idx = Index.load(DB_PATH)

local st = Index.stats(idx)
print(string.format("読み込み完了: %s  (文書数=%d  異なり語数=%d)", DB_PATH, st.docs, st.terms))
print()

-- 使い方: lua5.4 search_cli.lua "クエリ"          … BM25検索（OR）
--         lua5.4 search_cli.lua -p "フレーズ"     … フレーズ検索
--         lua5.4 search_cli.lua -a "クエリ"       … AND検索
local mode  = ({ ["-p"] = "phrase", ["-a"] = "and" })[arg[1]] or "or"
local query = (mode ~= "or" and arg[2] or arg[1]) or "転置インデックス"

if mode == "phrase" then
  print("== フレーズ検索: " .. query .. " ==")
  local hits = Index.search_phrase(idx, query, 5)
  if #hits == 0 then
    print("  ヒットなし")
  end
  for rank, r in ipairs(hits) do
    print(string.format("  %d. [count=%d] %s", rank, r.count, r.title))
  end
elseif mode == "and" then
  print("== AND検索: " .. query .. " ==")
  local hits = Index.search_and(idx, query, 5)
  if #hits == 0 then
    print("  ヒットなし")
  end
  for rank, r in ipairs(hits) do
    print(string.format("  %d. [%.4f] %s", rank, r.score, r.title))
  end
else
  print("== 検索: " .. query .. " ==")
  local hits = Index.search(idx, query, 5)
  if #hits == 0 then
    print("  ヒットなし")
  end
  for rank, r in ipairs(hits) do
    print(string.format("  %d. [%.4f] %s", rank, r.score, r.title))
  end
end
