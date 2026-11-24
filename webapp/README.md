# OpenSearch 検索 Web アプリ

OpenSearch クラスタに接続し、ブラウザから全文検索を行う Node.js/Express 製の Web アプリケーションです。

---

## 目次

1. [ディレクトリ構成](#ディレクトリ構成)
2. [動作要件](#動作要件)
3. [セットアップ](#セットアップ)
4. [起動方法](#起動方法)
5. [環境変数](#環境変数)
6. [機能一覧](#機能一覧)
7. [API リファレンス](#api-リファレンス)
8. [検索仕様](#検索仕様)
9. [対応インデックス構造](#対応インデックス構造)

---

## ディレクトリ構成

```
webapp/
├── package.json       # 依存関係・スクリプト定義
├── server.js          # Express バックエンド（API サーバー）
├── README.md          # 本ドキュメント
└── public/
    └── index.html     # フロントエンド（HTML + CSS + JavaScript）
```

---

## 動作要件

| 項目 | バージョン |
|------|-----------|
| Node.js | 18 以上 |
| OpenSearch | 2.x / 3.x |

---

## セットアップ

```bash
cd webapp
npm install
```

---

## 起動方法

### 通常起動

```bash
npm start
# → http://localhost:3000 で起動
```

### 開発モード（ファイル変更を自動検知して再起動）

```bash
npm run dev
# ファイルを保存するたびに自動で再起動される（Node.js 18+ の --watch フラグを使用）
```

---

## 環境変数

アプリの接続先・ポート番号はすべて環境変数で制御します。

### 変数一覧

| 変数名 | 既定値 | 必須 | 説明 |
|--------|--------|------|------|
| `PORT` | `3000` | | アプリが Listen するポート番号 |
| `OPENSEARCH_URL` | `http://localhost:9200` | | OpenSearch クラスタのベース URL |
| `OPENSEARCH_USERNAME` | （なし） | | 基本認証ユーザー名。**設定した場合のみ認証を有効化** |
| `OPENSEARCH_PASSWORD` | `""` | | 基本認証パスワード。`OPENSEARCH_USERNAME` と合わせて設定 |

---

### 指定方法 1 — `.env` ファイルを使う（推奨）

プロジェクトルート（`webapp/`）に `.env` ファイルを作成し、起動前に読み込みます。

> **注意:** Node.js 20.6 以上では `node --env-file` フラグで `.env` を直接読み込めます。
> それ以前のバージョンでは `dotenv` パッケージを使うか、後述のシェルスクリプト方式を使ってください。

#### Node.js 20.6 以上の場合

`package.json` の `scripts` を以下のように変更します：

```json
"scripts": {
  "start": "node --env-file=.env server.js",
  "dev":   "node --env-file=.env --watch server.js"
}
```

その後 `.env` を作成して起動します：

```bash
cp .env.example .env   # サンプルをコピーして編集
npm start
```

#### Node.js 18 / 19 の場合（dotenv を使用）

```bash
npm install dotenv
```

`server.js` の先頭に以下を追加します：

```js
require('dotenv').config();
```

---

### `.env` ファイルの書き方

`.env` は `KEY=VALUE` 形式のテキストファイルです。`#` から始まる行はコメントになります。

#### ローカル開発用（認証なし）

```dotenv
# .env — ローカル開発環境
PORT=3000
OPENSEARCH_URL=http://localhost:9200
```

#### 認証ありのクラスタに接続する場合

```dotenv
# .env — 認証付きクラスタ
PORT=3000
OPENSEARCH_URL=https://my-opensearch-cluster.example.com:9200
OPENSEARCH_USERNAME=admin
OPENSEARCH_PASSWORD=P@ssw0rd!
```

#### ポートを変更したい場合

```dotenv
# .env — ポート 8080 で起動
PORT=8080
OPENSEARCH_URL=http://localhost:9200
```

> **セキュリティ上の注意:** `.env` にはパスワードが含まれるため、必ず `.gitignore` に追加してください。
> `.env.example` はパスワードを空欄にした雛形としてリポジトリに含めます。

---

### 指定方法 2 — コマンドライン（macOS / Linux）

起動コマンドの直前に `KEY=VALUE` を並べます。`.env` ファイルは不要です。

```bash
# 最小構成（ローカル OpenSearch）
OPENSEARCH_URL=http://localhost:9200 npm start

# 認証ありクラスタ
OPENSEARCH_URL=https://my-cluster.example.com:9200 \
OPENSEARCH_USERNAME=admin \
OPENSEARCH_PASSWORD=secret \
npm start

# ポート変更 + 認証あり
PORT=8080 \
OPENSEARCH_URL=http://localhost:9200 \
npm start
```

---

### 指定方法 3 — シェルスクリプト（再利用したい場合）

毎回コマンドラインで指定するのが煩わしい場合は、シェルスクリプトにまとめます。

```bash
#!/usr/bin/env bash
# start.sh
export PORT=3000
export OPENSEARCH_URL=http://localhost:9200
export OPENSEARCH_USERNAME=admin
export OPENSEARCH_PASSWORD=secret

npm start
```

```bash
chmod +x start.sh
./start.sh
```

---

### 指定方法 4 — Windows（コマンドプロンプト / PowerShell）

**コマンドプロンプト（cmd.exe）**

```cmd
set PORT=3000
set OPENSEARCH_URL=http://localhost:9200
set OPENSEARCH_USERNAME=admin
set OPENSEARCH_PASSWORD=secret
npm start
```

**PowerShell**

```powershell
$env:PORT = "3000"
$env:OPENSEARCH_URL = "http://localhost:9200"
$env:OPENSEARCH_USERNAME = "admin"
$env:OPENSEARCH_PASSWORD = "secret"
npm start
```

---

### `.env.example`（リポジトリ管理用の雛形）

`webapp/.env.example` として以下の内容が含まれています。
`.env` を新しく作る際はこのファイルをコピーしてください。

```bash
cp webapp/.env.example webapp/.env
```

```dotenv
# OpenSearch 検索 Web アプリ — 環境変数サンプル
# このファイルをコピーして .env を作成し、各値を編集してください。
# .env はリポジトリに含めないこと（.gitignore に追加する）。

# アプリが Listen するポート番号
PORT=3000

# OpenSearch クラスタの URL（末尾スラッシュは不要）
OPENSEARCH_URL=http://localhost:9200

# 認証が必要なクラスタの場合のみ設定。不要な場合はコメントアウトのまま。
# OPENSEARCH_USERNAME=admin
# OPENSEARCH_PASSWORD=
```

---

## 機能一覧

### 検索パネル

| 機能 | 説明 |
|------|------|
| **インデックス選択** | 利用可能なインデックスをドロップダウンで選択。システムインデックス（`.` 始まり）と管理用インデックス（`top_queries` 始まり）は自動的に除外される |
| **キーワード入力** | スペース区切りで複数キーワードを入力可能。Enter キーで検索実行（日本語 IME 変換中の確定 Enter は無視）|
| **フィールド選択チップ** | インデックス選択時に `text` 型フィールドをチップとして表示。選択したフィールドのみを検索対象にできる。未選択の場合は全 `text` フィールドが対象 |
| **content_type フィルター** | `attachment.content_type` フィールドの値一覧をドロップダウンで表示し、絞り込み検索が可能。該当フィールドを持たないインデックスでは非表示 |
| **件数 / ページ選択** | 1 ページあたりの表示件数を 5 / 10 / 20 / 50 件から選択 |
| **クリアボタン** | キーワード・content_type フィルター・フィールド選択をリセット |

### 検索結果

| 機能 | 説明 |
|------|------|
| **ハイライト表示** | 一致箇所を `<mark>` タグで黄色強調表示 |
| **スコア表示** | 各ドキュメントの関連度スコアをカードに表示 |
| **メタデータ表示** | `author` / `category` / `published_at` / `filename` / `content_type` を自動検出して表示 |
| **本文展開** | 「▶ 本文を表示」リンクをクリックすると `content` または `attachment.content` の全文をカード内に展開 |
| **ページネーション** | 1 / 2 / … / 末尾 形式のスマートページング。ページ切替時も検索条件を維持 |
| **処理時間表示** | OpenSearch の `took` 値（ミリ秒）を結果ヘッダーに表示 |

### その他

| 機能 | 説明 |
|------|------|
| **クラスタ健全性表示** | ヘッダーに緑（green）/ 黄（yellow）/ 赤（red）のドットとノード数をリアルタイム表示 |
| **検索履歴** | 直近 10 件のキーワードをブラウザの `localStorage` に保存。クリックで入力欄に反映し再検索 |
| **スケルトンローダー** | 検索中はカード型のプレースホルダーアニメーションを表示 |
| **エラー表示** | API エラー時は赤枠でエラーメッセージを表示 |

---

## API リファレンス

### `GET /api/health`

クラスタの疎通確認。

**レスポンス例**

```json
{ "status": "yellow", "nodes": 1 }
```

---

### `GET /api/indices`

検索対象インデックスの一覧を取得する。システムインデックス・`top_queries` 系・`open` 状態でないものは除外。

**レスポンス例**

```json
{
  "indices": [
    { "index": "ja-documents",     "docs.count": "5", "health": "yellow", "status": "open" },
    { "index": "ja-documents-knn", "docs.count": "5", "health": "yellow", "status": "open" }
  ]
}
```

---

### `GET /api/fields?index=<name>`

指定インデックスの `text` / `keyword` フィールド一覧を取得する。ネストしたフィールドはドット記法（例: `attachment.content`）で展開して返す。

**クエリパラメータ**

| パラメータ | 必須 | 説明 |
|-----------|------|------|
| `index` | ✔ | 対象インデックス名 |

**レスポンス例**

```json
{
  "fields": [
    { "field": "title",              "type": "text"    },
    { "field": "content",            "type": "text"    },
    { "field": "author",             "type": "keyword" },
    { "field": "attachment.content", "type": "text"    }
  ]
}
```

---

### `GET /api/content-types?index=<name>`

`attachment.content_type` フィールドの値一覧を集計して返す。該当フィールドが存在しない場合は空配列。

**レスポンス例**

```json
{
  "content_types": [
    { "value": "application/pdf", "count": 9 }
  ]
}
```

---

### `POST /api/search`

検索を実行する。

**リクエストボディ**

| フィールド | 型 | 必須 | 説明 |
|-----------|-----|------|------|
| `index` | string | ✔ | 検索対象インデックス名 |
| `query` | string | | キーワード。スペース区切りで OR 検索。省略または空文字で全件取得 |
| `fields` | string[] | | 検索対象フィールド名。省略時は全 `text` フィールドが対象 |
| `page` | number | | ページ番号（1 始まり、既定 `1`） |
| `pageSize` | number | | 1 ページあたりの件数（既定 `10`） |
| `filters` | object | | keyword フィールドの完全一致フィルター。例: `{"attachment.content_type": "application/pdf"}` |

**リクエスト例**

```json
{
  "index": "ja-documents",
  "query": "OpenSearch 全文検索",
  "fields": ["attachment.content"],
  "page": 1,
  "pageSize": 10,
  "filters": {}
}
```

**レスポンス例**

```json
{
  "total": 2,
  "page": 1,
  "pageSize": 10,
  "totalPages": 1,
  "took_ms": 8,
  "hits": [
    {
      "id": "opensearch-intro.pdf",
      "score": 2.345,
      "source": {
        "filename": "opensearch-intro.pdf",
        "attachment": {
          "content": "OpenSearchはオープンソースの分散検索・分析エンジンです...",
          "content_type": "application/pdf"
        }
      },
      "highlight": {
        "attachment.content": ["<mark>OpenSearch</mark>はオープンソースの分散検索..."]
      }
    }
  ]
}
```

---

## 検索仕様

### キーワード検索

- スペース区切りで複数キーワードを指定すると **OR 検索**になる
- 多くのキーワードに一致するドキュメントほどスコアが高くなり上位に表示される
- フィールド指定なし：`query_string` クエリで全 `text` フィールドを対象
- フィールド指定あり：`multi_match (best_fields)` クエリで指定フィールドのみを対象

### フィルター

- `filters` オブジェクトに指定した条件は `bool.filter` で適用される（スコアに影響しない完全一致）
- キーワード検索との組み合わせ（AND）が可能

### ハイライト

- `text` 型フィールドのみハイライト対象
- 1 フィールドあたり最大 1 フラグメント、150 文字を返す
- 一致箇所を `<mark>...</mark>` タグで囲んで返す

---

## 対応インデックス構造

### ドキュメント系（例: `ja-documents`）

ingest-attachment パイプラインで処理した PDF / Office ファイル向け。

| フィールド | 型 | 説明 |
|-----------|-----|------|
| `filename` | keyword | 元ファイル名 |
| `attachment.title` | text | ドキュメントタイトル |
| `attachment.content` | text | 抽出本文 |
| `attachment.author` | text | 作成者 |
| `attachment.content_type` | keyword | MIME タイプ（例: `application/pdf`） |
| `attachment.content_length` | long | 本文の文字数 |
| `attachment.date` | date | ドキュメント作成日 |
