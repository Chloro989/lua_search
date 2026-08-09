# 引継ぎ: Lua製 検索エンジン（転置インデックス + BM25）

## プロジェクトの目的
学習目的で、Lua を使って検索エンジンの中核（転置インデックス、BM25スコアリング、SQLite永続化）を
外部の全文検索ライブラリに頼らず自作している。

## 環境
- OS: Ubuntu (WSL2上, ホスト名 WD1, ユーザー: ubuntu)
- Lua: 5.4.4 (`lua5.4` コマンド。`lua` は 5.1 系が別に入っているので **必ず `lua5.4` を使うこと**)
- luarocks: 3.8.0、`lua_version = 5.4` に設定済み（`root` 用 `/root/.luarocks/config-5.4.lua` と
  システム全体 `/etc/luarocks/config-5.4.lua` の両方に設定済み）
- 導入済みライブラリ（`lua5.4 -e 'print(require("X"))'` で動作確認済み）:
  - `lsqlite3` （`/usr/local/lib/lua/5.4/lsqlite3.so`）
  - `lfs` (luafilesystem) （`/usr/local/lib/lua/5.4/lfs.so`）
  - `socket` (luasocket) （`/usr/local/share/lua/5.4/socket.lua`）
- `libsqlite3-dev` も導入済み

### 環境構築でハマった点（再発時の参考）
1. `sudo luarocks install X` が `/usr/local/lib/luarocks/rocks-5.1` に書き込もうとして権限エラー
   → luarocks のデフォルトターゲットが Lua 5.1 になっていたのが根本原因
2. `luarocks config lua_version 5.4` は **実行ユーザーごとに別ファイルに書かれる**
   （`sudo` なら `/root/.luarocks/`、一般ユーザーなら `~/.luarocks/`）ので、
   sudo あり/なし両方で実行するなら両方に設定するか、
   `sudo luarocks config --scope system lua_version 5.4` でシステム全体に設定する
3. `lsqlite3` のビルド時は `sqlite3.h` が必要 → `libsqlite3-dev` を先に入れる

## ファイル一覧（`C:\Users\darki\Documents\VScode\lua\claude\`）
- `index.lua` … 本体。トークナイザ、転置インデックス構造、BM25検索、前方一致展開、SQLite保存/読込
- `main.lua` … インメモリ版の動作確認デモ（最初に作ったもの。永続化には非対応）
- `build_index.lua` … サンプル文書からインデックスを構築し `search.db` に保存するスクリプト
- `search_cli.lua` … `search.db` を読み込んで検索するだけの独立プロセス（永続化の動作確認用）
- `search.db` … 生成物。`build_index.lua` を実行すると作られる（消して作り直して構わない）

## index.lua の設計判断（変更時に踏まえてほしい前提）

### トークナイザ
- ASCII: 空白・記号区切りの単語単位（例: `"Lua search"` → `lua`, `search`）
- 非ASCII（日本語）: 形態素解析器を使わず、2文字スライディング bi-gram
  （例: `"検索エンジン"` → `検索, 索エ, エン, ンジ, ジン`）
- ~~既知のバグ: `"Lua"` で `"LuaJIT"` がヒットしない~~ → **2026-08-09 に前方一致展開で解決**（下記）

### 前方一致展開（2026-08-09 追加）
`"Lua"` で `"LuaJIT"` を拾えない問題を、**インデックスの持ち方は変えず検索時に解決**した。
（他候補だった「英数字もN-gram化」「インデックス時にプレフィックス登録」はインデックスが
肥大するため不採用。保存形式を変えずに済む方式をユーザーが選択。）

- `expand_prefix(idx, term)` … クエリ語を「それで始まる語彙すべて」に展開
  - 対象は **ASCII英数字トークンのみ**。日本語 bi-gram は常に2文字なので前方一致しても
    自分自身しか出てこず、展開する意味がない
  - `PREFIX_MIN = 2`。1文字クエリは展開しない（`"a"` が語彙の大半に当たるのを防ぐ）
  - 語彙をソートした配列 `idx._sorted_terms` を遅延構築し、`lower_bound` の二分探索で
    範囲を絞る（前方一致する語はソート順で必ず連続する、という性質を利用）
  - このキャッシュは `M.add` と `M.load` で `nil` にして無効化している
- `M.search(idx, query, limit, opts)` に第4引数 `opts` を追加。`opts.prefix = false` で
  展開を切れる（旧挙動との比較用）。既存の3引数呼び出しは前方一致ONで動く

#### スコアリング上の注意（ここが一番の設計判断）
展開語を**それぞれ独立に BM25 にかけて合計してはいけない**。IDFが語ごとに計算されるため、
珍しい語ほど高得点になり順位が壊れる。実測した失敗例:

| コーパス | `"lua"` で検索した結果（誤った実装） |
|---|---|
| 6文書中5文書に `lua`、1文書だけ `luajit` | 1位 OpenResty(1.6263) … **luaを1度も含まない文書**<br>2位以下 Lua入門など(0.3前後) |

`lua` は df=5 でIDFが低く、`luajit` は df=1 でIDFが6倍以上高いのが原因。
係数で減衰させる（`PREFIX_BOOST`）案も試したが 0.3 まで下げても1位が覆らず、対症療法なので破棄。

**採用した解**: `merge_group()` で展開語を**1つの語として合成**してから BM25 にかける。
- `df` = 展開語の**いずれか**を含む文書数（和集合の要素数）
- `tf` = その文書内での展開語の出現回数の**合計**

これでIDFはグループにつき1回だけ計算され、歪みが消える（上記コーパスで OpenResty は最下位に）。
副次的な利点として、展開語が1個のとき（=日本語クエリ、prefix無効時）は旧実装と**数値が完全一致**する
ので、回帰チェックが容易。

### 転置インデックス構造（インメモリ）
```lua
idx = {
  docs      = {},   -- id -> {title=, body=}
  postings  = {},   -- term -> { {id=, tf=}, ... }
  df        = {},   -- term -> document frequency
  len       = {},   -- id -> 文書のトークン数
  N         = 0,    -- 総文書数
  total_len = 0,
}
```

### BM25
- 定数 `K1 = 1.2`, `B = 0.75`（コード冒頭付近、変更しやすいようローカル変数として分離済み）

### SQLite永続化（テーブル設計）
```sql
docs     (id INTEGER PRIMARY KEY, title TEXT, body TEXT, len INTEGER)
postings (term TEXT, doc_id INTEGER, tf INTEGER)  -- idx_postings_term に索引あり
meta     (key TEXT PRIMARY KEY, value TEXT)       -- N, total_len を保存
```
- **`df` は意図的に保存していない**。`load` 時に `postings` から
  `#idx.postings[term]` で再導出している（正規化のため。df を別途保持すると
  将来の文書削除機能で同期ズレを起こす懸念があった）。
- `M.save(idx, path)` は毎回 `DELETE FROM docs/postings/meta` してから全件 INSERT
  する「全置き換え」方式。差分更新ではない。

## 永続化の動作確認（2026-08-09 完了）
以前は claude.ai サンドボックスに `lsqlite3` を入れられず `M.save`/`M.load` が未実行だったが、
**実機（WSL2 Ubuntu）で実行し動作確認済み**。実行時エラーなし。

```
文書数=6  異なり語数=184  posting総数=231
"転置インデックス" → 1位 転置インデックス入門 6.2238 / 2位 BM25とは 4.8520 / 3位 検索エンジンの仕組み 4.8411
```
`main.lua`（インメモリ）と `search_cli.lua`（SQLite経由・別プロセス）で**スコアが完全一致**。
`df` を保存せず `load` 時に postings から再導出する設計が正しいことも、これで裏付けられた
（df がズレていればスコアが変わるため、良い検証になっている）。

### 実行方法（Windows から）
プロジェクトは Windows 側 `C:\Users\darki\Documents\VScode\lua\claude` にあり、
WSL2 Ubuntu 側から `/mnt/c/...` 経由で実行している。DrvFs 上でも SQLite のロック問題は出ていない。
```bash
wsl.exe -d Ubuntu -- bash -lc 'cd /mnt/c/Users/darki/Documents/VScode/lua/claude && lua5.4 build_index.lua'
```

## 次にやりたいこと（優先度順、ユーザーと合意済み）
1. ~~`build_index.lua` → `search_cli.lua` の動作確認~~ → **完了（上記）**
2. ~~"Lua" → "LuaJIT" ヒット問題~~ → **完了（前方一致展開。設計の項を参照）**
3. posting list に位置情報を持たせてフレーズ検索対応
4. posting list を doc_id でソートしAND検索（マージアルゴリズム）を実装
5. `luasocket` でクローラを書いて実データを取り込む
6. postings に `UNIQUE(term, doc_id)` 制約を追加

### 前方一致展開の残課題（着手するなら）
- **前方一致は一方向**。`"Lua"` → `"LuaJIT"` は当たるが、`"LuaJIT"` → `"Lua"` は当たらない
  （`luajit` で始まる語彙に `lua` は含まれないため）。仕様として妥当だが、承知しておくこと
- **完全一致の優先付けがない**。`lua*` を1語として扱う設計上、`"lua"` 完全一致文書と
  `"luajit"` 文書は同じ土俵で BM25 されるだけ。完全一致を上に出したいなら
  「完全一致の項を別途加算する」などの追加が要る（現状は意図的に入れていない）
- **語彙の走査はインメモリ前提**。`M.load` が postings を全部メモリに読むので二分探索で足りている。
  将来インデックスが大きくなり SQLite から遅延で引くようにするなら、
  `SELECT ... WHERE term LIKE 'lua%'` が `idx_postings_term` で効く（前方一致なら索引が使える）

## ユーザーの学習スタンス
- 学習目的であることを明言済み。「FTS5など既製の全文検索エンジンに丸投げする」のではなく、
  「転置インデックスを自分で書く」方針をユーザー自身が選択している
  （SQLite保存の方針を聞いた際、"自前構造を保存"を選択）。
- 実装を丸ごと渡すより、コードの設計意図や既知の制約・バグを説明しながら進めるとよい。
