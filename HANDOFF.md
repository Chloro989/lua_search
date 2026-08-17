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
  - `socket` (luasocket) （luarocks版 `3.1.0-1`）
  - `ssl` / `ssl.https` (luasec、luarocks版 `1.3.2-1`) … HTTPS通信も動作確認済み
    （下記「luasecのHTTPS不具合」の項を参照。現在は解決済み）
- `libsqlite3-dev` / `libssl-dev` も導入済み

### 環境構築でハマった点（再発時の参考）
1. `sudo luarocks install X` が `/usr/local/lib/luarocks/rocks-5.1` に書き込もうとして権限エラー
   → luarocks のデフォルトターゲットが Lua 5.1 になっていたのが根本原因
2. `luarocks config lua_version 5.4` は **実行ユーザーごとに別ファイルに書かれる**
   （`sudo` なら `/root/.luarocks/`、一般ユーザーなら `~/.luarocks/`）ので、
   sudo あり/なし両方で実行するなら両方に設定するか、
   `sudo luarocks config --scope system lua_version 5.4` でシステム全体に設定する
3. `lsqlite3` のビルド時は `sqlite3.h` が必要 → `libsqlite3-dev` を先に入れる
4. **luasecのHTTPS不具合（2026-08-17 発見・解決済み）**:
   - 症状: `require("ssl.https")` 自体は通るが、実際にHTTPSリクエストすると
     `/usr/share/lua/5.4/ssl/https.lua:66: bad argument #2 to 'method'
     (string expected, got light userdata)` で例外になる。`http://`（TLSなし）は
     正常動作していた（`http://info.cern.ch/` で確認）ので、HTTPS限定の問題だった
   - 原因①: `lua-sec` (1.0.2-1) が **apt** でインストールされていたのに対し、
     実際に読み込まれる `socket`/`socket.http` は **luarocks** 版だった
     （apt版 `lua-socket` は `3.0~rc1+git...`、luarocks版は別バージョン）。
     apt版 `lua-sec` はapt版 `lua-socket` を前提にビルドされているため、
     luarocks版 `socket` と組み合わせるとC拡張のABIが噛み合わずクラッシュしていた
   - 対処①: `sudo luarocks install luasec` で luasec を luasocket と同じ
     luarocks系統に揃えてビルドし直す。ただし **sudoのパスワード入力が必要で、
     Claude Code側からは非対話実行できず、ユーザー側の端末で手動実行してもらった**
   - 原因②: ①の再ビルドが `Could not find header file for OPENSSL
     (No file openssl/ssl.h ...)` で失敗。`libssl3`（実行時ライブラリ）はあったが
     `libssl-dev`（コンパイル用ヘッダ）が入っていなかった
   - 対処②: `sudo apt install libssl-dev` を先に実行してから
     `sudo luarocks install luasec` を再実行 → `luasec 1.3.2-1`
     （luarocks版、luasocket `3.1.0-1` と同系統）が入り解決。
     `https://www.lua.org/about.html` などで動作確認済み

## ファイル一覧（`C:\Users\darki\Documents\VScode\lua\claude\`）
- `index.lua` … 本体。トークナイザ、転置インデックス構造、BM25検索、前方一致展開、SQLite保存/読込
- `main.lua` … インメモリ版の動作確認デモ（最初に作ったもの。永続化には非対応）
- `build_index.lua` … サンプル文書からインデックスを構築し `search.db` に保存するスクリプト
- `search_cli.lua` … `search.db` を読み込んで検索するだけの独立プロセス（永続化の動作確認用）
- `search.db` … 生成物。`build_index.lua` を実行すると作られる（消して作り直して構わない）
- `crawler.lua` … `urls.txt` に列挙したページを取得し `crawled.db` に保存するクローラ
- `urls.txt` … クローラが取得するURLの一覧（1行1URL、`#`でコメント）。**現状 `http://` のみ対応**
- `crawled.db` … 生成物。`crawler.lua` を実行すると作られる（`search.db` とは別ファイル）

## index.lua の設計判断（変更時に踏まえてほしい前提）

### トークナイザ
- ASCII: 空白・記号区切りの単語単位（例: `"Lua search"` → `lua`, `search`）
- 非ASCII（日本語）: 形態素解析器を使わず、2文字スライディング bi-gram
  （例: `"検索エンジン"` → `検索, 索エ, エン, ンジ, ジン, ン` ※末尾に注意、下記）
- ~~既知のバグ: `"Lua"` で `"LuaJIT"` がヒットしない~~ → **2026-08-09 に前方一致展開で解決**（下記）
- **末尾の重複 uni-gram**: 非ASCIIランの最後の1文字は、直前の bi-gram に含まれているにも
  かかわらず単独 uni-gram としても登録される（`M.tokenize` のコード冒頭コメント参照。
  意図的な仕様）。フレーズ検索を実装する際、クエリ文字列を単体でトークン化すると
  この重複がクエリの末尾に必ず付き、文書側の位置と噛み合わずヒットしなくなるバグを踏んだ。
  → `phrase_tokenize()` という専用トークナイザを別途用意して解決（下記）

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
  postings  = {},   -- term -> { {id=, tf=, positions={p1,p2,...}}, ... }
  df        = {},   -- term -> document frequency
  len       = {},   -- id -> 文書のトークン数
  N         = 0,    -- 総文書数
  total_len = 0,
  _sorted_terms    = nil,   -- 前方一致検索用キャッシュ（遅延構築、add/load で無効化）
  _postings_sorted = false, -- 各 postings[term] が doc_id 昇順ソート済みか（AND検索用）
}
```
`tf` は `#positions` として求まる値であり、`positions`（出現位置＝トークン列での
1始まりインデックス）と独立に持っているわけではない。`M.add` で両方同時に作る。

### BM25
- 定数 `K1 = 1.2`, `B = 0.75`（コード冒頭付近、変更しやすいようローカル変数として分離済み）
- 1語1文書分のスコア計算式は `bm25_component(idx, avgdl, idf, doc_id, tf)` に共通化してある。
  `M.search`（前方一致展開後のグループ単位）と `M.search_and`（AND絞り込み後）の
  両方から呼ばれる。同じ式を2箇所に書いて片方だけ直し忘れる事故を防ぐための切り出し

### フレーズ検索（2026-08-09 追加）
`M.search_phrase(idx, phrase, limit)` … クエリのトークン列が文書内で連続した位置に
出現する文書だけを返す。スコアではなく出現回数 `count` を返す。

- `M.search`（BM25・OR検索・前方一致展開）とは別関数として独立させた。
  厳密一致・位置一致を要求するフレーズ検索は、あいまい一致（前方一致展開）や
  スコアの重ね合わせ（BM25）と意味論的に相性が悪いため（Elasticsearchでも
  `match_phrase` は通常の `match` と別クエリタイプ）
- 実装: クエリの各トークンについて `doc_id -> {position: true, ...}` の集合を作り、
  先頭トークンの各出現位置を起点に、2番目以降のトークンが `起点+1, 起点+2, ...`
  の位置にあるかを判定する
- **`M.tokenize` ではなく専用の `phrase_tokenize()` を使う**（上のトークナイザの項参照）。
  `M.tokenize` はクエリ文字列単体をトークン化すると末尾に重複 uni-gram が付き、
  文書側の位置とズレて何もヒットしなくなるバグがあったため。`phrase_tokenize` は
  非ASCIIランの末尾で重複 uni-gram を出さない（bi-gram の並びだけで元の文字列を
  一意に復元できるため、末尾の重複は情報として不要と判断し削除）
- 前方一致展開は掛けていない（クエリの語をそのまま厳密一致で使う）

### AND検索・マージアルゴリズム（2026-08-09 追加）
`M.search_and(idx, query, limit)` … クエリの全語を含む文書だけを、BM25でスコアリングして返す。

- `M.search`（OR検索。1語でも含めば候補）とは逆の「全語必須」の検索。
  「短いリストから交差を取ると早く絞り込める」という定番の最適化込みで、
  ソート済み配列2本を2ポインタで同時に舐める古典的な**マージアルゴリズム**で
  posting list 同士の共通部分（交差）を求める
- `ensure_postings_sorted(idx)` … 各 `postings[term]` を `doc_id` 昇順にソートするキャッシュ。
  `idx._postings_sorted` フラグで管理し、`_sorted_terms` と同じ設計（`M.add`/`M.load` で無効化）。
  語彙全体を毎回ソートするのではなく「全部ソート済みか」を1個のフラグで持つだけの簡易版
- `merge_intersect_ids(a, b)` … 2本のソート済み `doc_id` 配列を併合して交差を求める本体。
  3語以上のクエリはこれを逐次呼んで畳み込む（要素数が少ないリストから処理して早期に絞り込む）
- 交差が求まった文書集合だけを対象に、通常の `M.search` と同じ BM25 式（`bm25_component`）で
  スコアリングして並べる。AND条件で絞り込んだ後の順位付けなので同じ式を再利用できる

#### クエリのトークン化にまた `phrase_tokenize` を使う羽目になった話
最初 `M.tokenize(query)` でクエリをトークン化したところ、**空白区切りの複数語クエリが
軒並みヒットしない**バグを踏んだ。`M.search_phrase` のときと**全く同じ原因**（トークナイザの
項を参照）: `M.tokenize("検索 エンジン")` は `検索, 索, エン, ンジ, ジン, ン` のように、
語の直後に空白が来るたびに孤立文字（`索`, `ン`）が紛れ込む。AND検索は全語必須なので、
この孤立文字1つでも文書中に存在しなければ即座に不成立になり、ほぼ全てのクエリが
「ヒットなし」になっていた。`phrase_tokenize(query)` に切り替えて解決（このトークナイザは
空白をランの区切りとして正しく扱い、孤立文字を生成しない）。

#### この設計の限界（意図的な妥協）
AND検索は「クエリの各 bi-gram がその文書のどこかに存在するか」を見るだけで、
**隣接（＝フレーズとしての一致）までは要求しない**。そのため理論上は
「エン・ンジ・ジン が文書中の別々の場所に散らばっているだけ」で `"エンジン"` に
ヒットしてしまう可能性がある。これは n-gram 索引での AND 検索によくある近似
（MySQL/MariaDBのngram全文検索パーサーのAND検索も同様の挙動）。
厳密に隣接まで要求したいクエリには `M.search_phrase` を使う。

### SQLite永続化（テーブル設計）
```sql
docs     (id INTEGER PRIMARY KEY, title TEXT, body TEXT, len INTEGER)
postings (term TEXT, doc_id INTEGER, pos INTEGER, UNIQUE(term, doc_id, pos))
         -- 出現ごとに1行
meta     (key TEXT PRIMARY KEY, value TEXT)       -- N, total_len を保存
```
- **2026-08-09 にスキーマ変更**: `tf` カラムを廃止し `pos`（出現位置）に変更、
  1行=1出現に変更した。`tf` は `load` 時に `COUNT(*) GROUP BY term, doc_id`
  相当（= 集約した `positions` 配列の長さ）で導出する
- **`df` も `tf` も意図的に保存していない**。`load` 時に `postings` から再導出している
  （正規化のため。別途保持すると将来の文書削除機能で同期ズレを起こす懸念があった）。
  1行1出現にしたことで `tf` も `df` と同じ理屈で導出できるようになった
- `M.save(idx, path)` は毎回 `DELETE FROM docs/postings/meta` してから全件 INSERT
  する「全置き換え」方式。差分更新ではない
- **2026-08-09 に `UNIQUE(term, doc_id, pos)` を追加**（同じ出現の二重登録を防ぐ）。
  この複合UNIQUE制約が自動でB-tree索引を張るため、以前個別に作っていた
  `idx_postings_term`（term単体）と `idx_postings_term_doc`（term, doc_id）は
  左端一致（leftmost prefix）で完全にカバーされ冗長になった → 削除して整理した。
  実際に張られる索引名は `sqlite_autoindex_postings_1`（`lua5.4 -e` で
  `sqlite_master` を見て確認済み）
- **注意（旧スキーマからの移行）**: 既存の `search.db` があると `ensure_schema` は
  `CREATE TABLE IF NOT EXISTS` なので、列や UNIQUE 制約は自動更新されない。
  スキーマを変更したら毎回 `rm -f search.db` してから `build_index.lua` を再実行すること

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
3. ~~posting list に位置情報を持たせてフレーズ検索対応~~ → **完了（`M.search_phrase`。設計の項を参照）**
4. ~~posting list を doc_id でソートしAND検索（マージアルゴリズム）を実装~~
   → **完了（`M.search_and`。設計の項を参照）**
5. ~~`luasocket` でクローラを書いて実データを取り込む~~ → **完了**
6. ~~postings に `UNIQUE(term, doc_id)` 制約を追加~~
   → **完了（`UNIQUE(term, doc_id, pos)`。SQLite永続化の項を参照）**

**当初リストの6項目は全て完了。次の候補（未合意・要相談）**:
- 前方一致展開・AND検索・フレーズ検索を組み合わせる（各項の「残課題」参照）
- `crawler.lua` をリンク追跡型の本格的なクローラに拡張する（現状は列挙したURLのみ）
- 文書削除・差分更新（今は `M.save` が毎回全置き換え）
- 複数フィールド対応（title/bodyを別々に重み付けしてスコアリングする等）

### クローラの実装状況（2026-08-17）
`crawler.lua` / `urls.txt` を追加。`https://www.lua.org/` 配下5ページ
（about.html, start.html, manual/5.4/manual.html, pil/1.html, pil/1.1.html）を実際に
取得 → 抽出 → 索引化 → `crawled.db` 保存 → BM25検索・フレーズ検索・AND検索の全部で
ヒットする、という一連の流れを実機で動作確認済み。

```
文書数=5  異なり語数=2957
検索(BM25) "coroutine"           → 1位 Lua 5.4 Reference Manual
フレーズ検索 "Programming in Lua" → 1位 Programming in Lua : 1 (count=3)
AND検索 "lua metatable"          → 1位 Lua 5.4 Reference Manual
```

- **HTTP/HTTPS両対応**: `fetch()` はURLのスキームで `socket.http` / `ssl.https` を
  切り替える。どちらもテーブル形式のリクエスト（`sink` + `headers`）を使うので
  User-Agentヘッダーを付けられる
- **踏んだバグ**: `<title>` 抽出が最初 `<title[^>]*>(.-)</title>` という小文字決め打ち
  パターンだったため、`about.html`/`start.html`/`manual.html` のような
  `<TITLE>`（大文字）でタグを書く古い書式のページでタイトルが空になった。
  Luaの文字列パターンには大文字小文字を区別しないマッチが無いため、
  `ci(tag)` というヘルパーでタグ名の各アルファベットを `[Aa]` のような
  文字クラスに展開して代用する形で解決（`<script>`/`<style>` の除去にも同様に適用）。
  残りの全タグ除去 `<[^>]+>` はもともとタグ名の大小を問わないので対象外
- HTMLからのテキスト抽出は正規表現によるタグ除去のみの簡易版（`<title>` 抽出、
  `<script>`/`<style>`/コメント除去、残りのタグを空白に置換、主要なHTMLエンティティ
  をデコード）。ちゃんとしたHTMLパーサではないので、上記のような大文字タグ以外にも
  壊れたHTMLや稀なエンティティで誤動作する可能性はある
- リンクを辿って自動的に対象を広げる「クロール」はしていない。`urls.txt` に
  列挙したURLだけを取得する設計（対象サイトへの意図しない大量アクセスを避けるため）
- 取得間隔は `FETCH_DELAY = 1.2` 秒（`crawler.lua` 冒頭）。User-Agentは
  `LuaSearchEngineLearningCrawler/0.1 (+https://github.com/Chloro989/lua_search)`
  として自己申告している
- `lua.org` の `robots.txt` は404（存在しない）ことを事前に確認済み

### フレーズ検索の残課題（着手するなら）
- **前方一致展開と組み合わせていない**。`"Lua"` でのフレーズ検索は `luajit` を含まない
  （常に厳密一致）。組み合わせるなら「展開語のいずれかで連続一致すればOK」という
  形になるはずだが、計算量・スコアの意味論ともに複雑になるため保留
- **`search_cli.lua` に `-p` フラグを追加済み**（`lua5.4 search_cli.lua -p "検索エンジン"`）。
  BM25検索・フレーズ検索・AND検索を全部試せる

### AND検索の残課題（着手するなら）
- **前方一致展開と組み合わせていない**（フレーズ検索と同じ理由・同じ保留）
- **隣接判定なし**（上記「この設計の限界」参照）。n-gramがバラバラの位置にあるだけの
  文書を誤ってヒットさせる可能性がある
- **`search_cli.lua` に `-a` フラグを追加済み**（`lua5.4 search_cli.lua -a "転置 BM25"`）

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
