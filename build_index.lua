-- build_index.lua : インデックスを構築して SQLite に保存する
local Index = require("index")

local corpus = {
  { "Luaの基礎", "Luaは軽量なスクリプト言語で、組み込み用途に広く使われています。" },
  { "検索エンジンの仕組み", "検索エンジンはクローラ、インデクサ、検索処理の三つから成ります。転置インデックスが中核です。" },
  { "転置インデックス入門", "転置インデックスは単語から文書への対応表です。全文検索の基本データ構造として使われます。" },
  { "BM25とは", "BM25は転置インデックスを使った検索のスコアリング関数です。TF-IDFを改良したものです。" },
  { "OpenRestyの話", "OpenRestyはNginxにLuaJITを組み込んだもので、高速なWeb APIを書けます。" },
  { "形態素解析について", "日本語の検索ではMeCabなどの形態素解析器を使うか、N-gramで分割します。" },
}

local idx = Index.new()
for i, d in ipairs(corpus) do
  Index.add(idx, i, d[1], d[2])
end

local DB_PATH = "search.db"
Index.save(idx, DB_PATH)

local st = Index.stats(idx)
print(string.format("保存完了: %s", DB_PATH))
print(string.format("文書数=%d  異なり語数=%d  posting総数=%d", st.docs, st.terms, st.postings))
