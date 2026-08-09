-- main.lua : index.lua の動作確認
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

local st = Index.stats(idx)
print(string.format("文書数=%d  異なり語数=%d  posting総数=%d  平均文書長=%.1f",
                    st.docs, st.terms, st.postings, st.avgdl))
print()

-- 転置インデックスの中身を覗いてみる
print('-- postings["転置"] --')
for _, e in ipairs(idx.postings["転置"] or {}) do
  print(string.format("  doc%d (tf=%d) : %s", e.id, e.tf, idx.docs[e.id].title))
end
print()

for _, q in ipairs({ "転置インデックス", "Lua", "検索 スコアリング", "形態素" }) do
  print("== 検索: " .. q .. " ==")
  local hits = Index.search(idx, q, 3)
  if #hits == 0 then
    print("  ヒットなし")
  end
  for rank, r in ipairs(hits) do
    print(string.format("  %d. [%.4f] %s", rank, r.score, r.title))
  end
  print()
end
