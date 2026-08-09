-- search_cli.lua : SQLite からインデックスを読み込んで検索するだけの独立プロセス
-- build_index.lua と *メモリを共有していない* 別プロセスとして実行される点が重要。
local Index = require("index")

local DB_PATH = "search.db"
local idx = Index.load(DB_PATH)

local st = Index.stats(idx)
print(string.format("読み込み完了: %s  (文書数=%d  異なり語数=%d)", DB_PATH, st.docs, st.terms))
print()

local query = arg[1] or "転置インデックス"
print("== 検索: " .. query .. " ==")
local hits = Index.search(idx, query, 5)
if #hits == 0 then
  print("  ヒットなし")
end
for rank, r in ipairs(hits) do
  print(string.format("  %d. [%.4f] %s", rank, r.score, r.title))
end
