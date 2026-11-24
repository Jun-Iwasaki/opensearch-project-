<!---
title: PodmanでOpenSearch環境をローカル構築する（kuromoji + ingest-attachment）
tags:
  - OpenSearch
  - Podman
  - Docker
  - 全文検索
  - MacOS
private: false
--->

ローカル検証用の OpenSearch + Dashboards 環境を Podman で構築する手順です。日本語全文検索に必要な **analysis-kuromoji** と PDF/Office 文書取り込みに使う **ingest-attachment** プラグインをあらかじめ組み込んだイメージをビルドします。

## OpenSearch とは

**OpenSearch** は Amazon が主導するオープンソースの分散検索・分析エンジンです。Elasticsearch 7.10 をフォークして 2021 年に誕生しました。Apache License 2.0 で提供されており、商用利用も無償で行えます。

主な特徴は以下のとおりです。

| 特徴 | 説明 |
|---|---|
| 全文検索 | 転置インデックスと BM25 スコアリングによる高速・高精度な全文検索 |
| ベクトル検索 | kNN（k-Nearest Neighbor）による意味的類似度検索（RAG 構成にも対応） |
| 分散アーキテクチャ | 複数ノードへの自動シャード分散・レプリケーションによる高可用性 |
| REST API | すべての操作を HTTP + JSON で実行可能 |
| Dashboards | Kibana 派生の可視化・管理 UI が同梱 |

本記事では **単一ノード構成** でローカル検証環境を構築します。

## 動作環境

| 項目 | 条件 |
|---|---|
| OS | macOS（Apple Silicon / Intel 共通） |
| コンテナランタイム | Podman 4 以上（`podman machine` が使えること） |
| メモリ | Podman VM に **4GB 以上** 割り当て（2GB では OpenSearch が OOM で落ちる） |
| ディスク | 数 GB 以上の空き（OpenSearch イメージ約 1GB + データ） |
| Node.js | 18 以上（検索 Web アプリを使う場合のみ） |
| Python | 3.x（サンプルデータ生成スクリプトを使う場合のみ） |

:::note warn
本構成はセキュリティプラグインを無効化しており、**認証・TLS なし**で動作します。ローカル検証専用です。インターネットに公開されたネットワークでは使用しないでください。
:::

## なぜ kuromoji が必要か

OpenSearch（および Elasticsearch）の標準アナライザーは英語を前提に設計されており、**スペース区切りで単語を分割**します。日本語はスペースなしで単語が連続するため、標準アナライザーでは「東京都」「東京」「都」などを個別に認識できず、まともな全文検索ができません。

**analysis-kuromoji** は日本語の形態素解析エンジン（Lucene Kuromoji）を OpenSearch に組み込むプラグインです。

```
標準アナライザー: "東京都在住のエンジニア" → ["東京都在住のエンジニア"]（1トークン）
kuromoji        : "東京都在住のエンジニア" → ["東京", "都", "在住", "エンジニア"]
```

これにより「東京」「エンジニア」といった単語単位での検索・スコアリングが機能するようになります。インデックス作成時に以下のようなカスタムアナライザーとして設定します。

```json
{
  "analysis": {
    "analyzer": {
      "ja_analyzer": {
        "type": "custom",
        "tokenizer": "kuromoji_tokenizer",
        "filter": [
          "kuromoji_baseform",
          "kuromoji_part_of_speech",
          "cjk_width",
          "ja_stop",
          "kuromoji_stemmer",
          "lowercase"
        ]
      }
    }
  }
}
```

| フィルター | 役割 |
|---|---|
| `kuromoji_baseform` | 動詞・形容詞を基本形に正規化（「走っている」→「走る」） |
| `kuromoji_part_of_speech` | 助詞・助動詞など検索に不要な品詞を除去 |
| `cjk_width` | 全角英数字を半角に正規化 |
| `ja_stop` | 日本語のストップワードを除去 |
| `kuromoji_stemmer` | 長音を正規化（「コンピューター」→「コンピュータ」） |
| `lowercase` | 英字を小文字に統一 |

## 構成

| コンポーネント | 用途 |
|---|---|
| OpenSearch | 検索エンジン本体（`localhost:9200`） |
| OpenSearch Dashboards | 管理・可視化 UI（`localhost:5601`） |
| analysis-kuromoji | 日本語形態素解析プラグイン |
| ingest-attachment | PDF/Office 文書からテキスト抽出（Apache Tika） |

## 前提確認

```bash
# podman を PATH に追加（毎回、または ~/.zshrc に追記）
export PATH=$PATH:/opt/podman/bin:/usr/local/bin

podman --version
```

## Step 1: Podman VM の作成とメモリ設定

:::note warn
メモリは **4GB 必須** です。2GB のままだと OpenSearch が OOM（Exit 137）で落ちます。
:::

```bash
# 新しい VM を初期化（すでにある場合は skip）
podman machine init

# メモリを 4GB に設定
podman machine set --memory 4096

# VM を起動
podman machine start

# メモリの確認
podman machine inspect | grep -i memory
```

## Step 2: Docker config の修正（macOS の場合）

macOS の Podman 環境では `~/.docker/config.json` に `credsStore: osxkeychain` が含まれていると、ヘルパーが未インストールのため image pull が失敗します。

```bash
cat ~/.docker/config.json
```

`credsStore` が含まれていた場合は空にします。

```bash
# 元のファイルはバックアップしておく
cp ~/.docker/config.json ~/.docker/config.json.bak
echo '{}' > ~/.docker/config.json
```

## Step 3: プロジェクトの設定ファイル

以下の 2 ファイルを用意します。

### Dockerfile.opensearch

```Dockerfile.opensearch
FROM opensearchproject/opensearch:latest
RUN /usr/share/opensearch/bin/opensearch-plugin install --batch analysis-kuromoji ingest-attachment
```

### docker-compose.yml

:::note warn
`version:` キーは書かないでください。最新の Docker Compose では obsolete 警告が出ます。
:::

```docker-compose.yml
services:
  opensearch-node1:
    build:
      context: .
      dockerfile: Dockerfile.opensearch
    image: opensearch-kuromoji:latest
    container_name: opensearch-node1
    environment:
      - cluster.name=opensearch-cluster
      - node.name=opensearch-node1
      - discovery.seed_hosts=opensearch-node1
      - cluster.initial_cluster_manager_nodes=opensearch-node1
      - bootstrap.memory_lock=false          # Podman VM では true にすると Exit 78
      - "OPENSEARCH_JAVA_OPTS=-Xms1g -Xmx1g"
      - "DISABLE_INSTALL_DEMO_CONFIG=true"
      - "DISABLE_SECURITY_PLUGIN=true"       # ローカル専用のため認証を無効化
    ulimits:
      memlock:
        soft: -1
        hard: -1
      nofile:
        soft: 65536
        hard: 65536
    volumes:
      - opensearch-data1:/usr/share/opensearch/data
    ports:
      - 9200:9200
      - 9600:9600
    networks:
      - opensearch-net

  opensearch-dashboards:
    image: opensearchproject/opensearch-dashboards:latest
    container_name: opensearch-dashboards
    ports:
      - 5601:5601
    environment:
      - 'OPENSEARCH_HOSTS=["http://opensearch-node1:9200"]'
      - "DISABLE_SECURITY_DASHBOARDS_PLUGIN=true"
    depends_on:
      - opensearch-node1
    networks:
      - opensearch-net

volumes:
  opensearch-data1:

networks:
  opensearch-net:
```

#### opensearch-node1 の設定項目

| 設定 | 値 | 説明 |
|---|---|---|
| `cluster.name` | `opensearch-cluster` | クラスタの識別名。複数ノードを束ねる際に揃える必要がある |
| `node.name` | `opensearch-node1` | このノードの識別名 |
| `discovery.seed_hosts` | `opensearch-node1` | クラスタ探索の初期接触先。単一ノードのため自分自身を指定 |
| `cluster.initial_cluster_manager_nodes` | `opensearch-node1` | 初回クラスタ形成時のクラスタマネージャー候補。初回起動後は無視される |
| `bootstrap.memory_lock` | `false` | JVM ヒープをメモリにロックするかどうか。`true` にすると Podman VM では ulimits の制限で起動失敗（Exit 78）するため `false` 固定 |
| `OPENSEARCH_JAVA_OPTS` | `-Xms1g -Xmx1g` | JVM のヒープサイズ。最小・最大を同じ値にそろえるのが推奨。4GB VM に対して 1GB を割り当てる |
| `DISABLE_INSTALL_DEMO_CONFIG` | `true` | 起動時にデモ用の TLS 証明書・セキュリティ設定を自動インストールするスクリプトを無効化する |
| `DISABLE_SECURITY_PLUGIN` | `true` | セキュリティプラグイン（認証・認可・TLS）を完全に無効化する。ローカル検証専用の設定で、本番環境では使用しない |

#### ulimits の設定項目

| 設定 | 値 | 説明 |
|---|---|---|
| `memlock` | `-1`（無制限） | メモリロック上限。`bootstrap.memory_lock=true` の際に必要だが、`false` でも設定しておくことが推奨されている |
| `nofile` | `65536` | プロセスが同時に開けるファイルディスクリプタ数の上限。OpenSearch は多数のファイルを同時に開くため、OS デフォルト（1024 程度）では不足する |

#### opensearch-dashboards の設定項目

| 設定 | 値 | 説明 |
|---|---|---|
| `OPENSEARCH_HOSTS` | `["http://opensearch-node1:9200"]` | Dashboards が接続する OpenSearch エンドポイント。コンテナ名 `opensearch-node1` で名前解決できる |
| `DISABLE_SECURITY_DASHBOARDS_PLUGIN` | `true` | Dashboards のセキュリティプラグインを無効化する。OpenSearch 本体のセキュリティを無効にした場合はこちらも合わせて無効化する必要がある |

## Step 4: ビルドと起動

```bash
podman compose -f docker-compose.yml up --detach --build
```

プラグインを追加・変更した場合は `--build` が必要です。

## Step 5: 起動確認

起動に数十秒かかります。以下が返れば成功です。

```bash
curl localhost:9200
```

```json
{
  "name" : "opensearch-node1",
  "cluster_name" : "opensearch-cluster",
  ...
}
```

クラスタ状態も確認します。

```bash
curl 'localhost:9200/_cluster/health?pretty'
```

```json
{
  "cluster_name" : "opensearch-cluster",
  "status" : "yellow",
  ...
}
```

:::note
`status: yellow` は正常です。単一ノード構成のためレプリカシャードを配置できず、常に yellow になります。
:::

Dashboards は http://localhost:5601 でブラウザから確認できます。

## カスタムアナライザーの設定方法

「なぜ kuromoji が必要か」で紹介したアナライザーを、実際にインデックスへ適用する方法を説明します。
ここでは curl でテキストデータを直接登録し、動作を確認します。

### インデックス作成時にアナライザーを設定する

インデックスを PUT する際、`settings.analysis` でアナライザーを定義し、`mappings.properties` で各フィールドに適用します。

```bash
curl -XPUT 'http://localhost:9200/my-index' \
  -H 'Content-Type: application/json' \
  -d '{
  "settings": {
    "analysis": {
      "analyzer": {
        "ja_analyzer": {
          "type": "custom",
          "tokenizer": "kuromoji_tokenizer",
          "filter": [
            "kuromoji_baseform",
            "kuromoji_part_of_speech",
            "cjk_width",
            "ja_stop",
            "kuromoji_stemmer",
            "lowercase"
          ]
        }
      }
    }
  },
  "mappings": {
    "properties": {
      "title":    { "type": "text",    "analyzer": "ja_analyzer" },
      "content":  { "type": "text",    "analyzer": "ja_analyzer" },
      "category": { "type": "keyword" }
    }
  }
}'
```

:::note
`category` は `keyword` 型で完全一致検索のみ対応します。全文検索が必要なフィールドは `text` 型 + `ja_analyzer` を指定します。
:::

### サンプルドキュメントを登録する

curl で JSON を直接 PUT します。ドキュメント ID は任意の文字列を指定できます。

```bash
curl -XPUT 'http://localhost:9200/my-index/_doc/1' \
  -H 'Content-Type: application/json' \
  -d '{
  "title":    "東京観光ガイド",
  "content":  "東京都在住のエンジニアにおすすめの観光スポットを紹介します。浅草寺や東京スカイツリーは外国人観光客にも人気です。",
  "category": "観光"
}'

curl -XPUT 'http://localhost:9200/my-index/_doc/2' \
  -H 'Content-Type: application/json' \
  -d '{
  "title":    "OpenSearch入門",
  "content":  "OpenSearchはElasticsearchをベースにしたオープンソースの全文検索エンジンです。日本語検索にはkuromojiプラグインを活用します。",
  "category": "技術"
}'

curl -XPUT 'http://localhost:9200/my-index/_doc/3' \
  -H 'Content-Type: application/json' \
  -d '{
  "title":    "情報セキュリティ方針",
  "content":  "社内システムへのアクセスには多要素認証を必須とします。パスワードは定期的に変更し、使い回しを禁止します。",
  "category": "セキュリティ"
}'
```

登録したドキュメント数を確認します。

```bash
curl 'http://localhost:9200/my-index/_count'
# → {"count":3, ...}
```

### アナライザーの動作を確認する

`_analyze` API でトークン分割結果を確認できます。

```bash
curl -XPOST 'http://localhost:9200/my-index/_analyze' \
  -H 'Content-Type: application/json' \
  -d '{
  "analyzer": "ja_analyzer",
  "text": "東京都在住のエンジニアがOpenSearchを活用する"
}'
```

```json
{
  "tokens": [
    { "token": "東京", "start_offset": 0, "end_offset": 2, "type": "word" },
    { "token": "都",   "start_offset": 2, "end_offset": 3, "type": "word" },
    { "token": "在住", "start_offset": 3, "end_offset": 5, "type": "word" },
    { "token": "エンジニア", "start_offset": 6, "end_offset": 11, "type": "word" },
    { "token": "opensearch", "start_offset": 12, "end_offset": 22, "type": "word" },
    { "token": "活用", "start_offset": 23, "end_offset": 25, "type": "word" }
  ]
}
```

助詞「が」「を」が除去され、`OpenSearch` が `lowercase` フィルターで `opensearch` に正規化されていることが確認できます。

### 検索クエリでのアナライザー

`match` クエリは検索キーワードにもインデックスと同じアナライザーを自動で適用します。そのため「東京都在住」と入力しても「東京」「都」「在住」に分割されてそれぞれマッチします。

```bash
curl -XPOST 'http://localhost:9200/my-index/_search' \
  -H 'Content-Type: application/json' \
  -d '{
  "query": {
    "match": {
      "content": "東京都在住のエンジニア"
    }
  }
}'
```

```json
{
  "hits": {
    "total": { "value": 1 },
    "hits": [
      {
        "_id": "1",
        "_score": 2.341,
        "_source": {
          "title": "東京観光ガイド",
          "content": "東京都在住のエンジニアにおすすめの観光スポットを紹介します。...",
          "category": "観光"
        }
      }
    ]
  }
}
```

:::note warn
`keyword` 型フィールド（`category` など）への `match` は完全一致になります。部分一致・形態素検索が必要なフィールドは必ず `text` 型 + `ja_analyzer` を指定してください。
:::

## Step 6: ベクトル検索用インデックスの登録（任意）

BM25 に加えてセマンティック検索（意味的な類似度検索）を使いたい場合は、ML Commons モデルをデプロイして `ja-documents-knn` インデックスへ登録します。

```bash
# ML Commons モデルのデプロイ（初回のみ。数分かかる）
./sample-data/setup_vector_search.sh
# → 完了時に MODEL_ID が表示される

# ja-documents-knn インデックスへ登録
./sample-data/ingest_documents_knn.sh sample-data/documents/ <MODEL_ID>
```

## Step 7: 検索 Web アプリの起動（任意）

```bash
cd webapp
npm install
npm start
# → http://localhost:3000 で検索 UI が起動
```

## 停止・再起動

```bash
# 停止（データは volume に保持される）
podman compose -f docker-compose.yml down

# 再起動（イメージ再ビルド不要）
podman compose -f docker-compose.yml up --detach

# データも含めて完全削除
podman compose -f docker-compose.yml down -v
```

## トラブルシューティング

| 症状 | 原因 | 対処 |
|---|---|---|
| OpenSearch が Exit 137 | OOM（メモリ不足） | `podman machine set --memory 4096` して VM 再作成 |
| OpenSearch が Exit 78 | `bootstrap.memory_lock=true` | `docker-compose.yml` で `false` のまま維持 |
| `podman compose` が動かない | PATH 未設定 | `export PATH=$PATH:/opt/podman/bin:/usr/local/bin` |
| image pull が失敗 | `credsStore: osxkeychain` | `~/.docker/config.json` を `{}` にする |
| ingest スクリプトが exit 22 | curl の `-f` がエラー本文を隠蔽 | `-f` を外して curl を手動実行し本文を確認 |
| モデルデプロイが失敗 | ML Commons メモリ閾値 | `native_memory_threshold: 99` の設定が必要（`setup_vector_search.sh` 参照） |
