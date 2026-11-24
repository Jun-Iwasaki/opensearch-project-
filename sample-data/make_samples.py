"""日本語のサンプルPDF/PowerPointを documents/ に生成する。"""
from pathlib import Path
from reportlab.lib.pagesizes import A4
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from pptx import Presentation
from reportlab.pdfgen import canvas

# フォントを埋め込まないと Tika (PDFBox) が解析に失敗するため TTF を埋め込む
FONT = "JaFont"
pdfmetrics.registerFont(TTFont(FONT, "/Library/Fonts/Arial Unicode.ttf"))

DOCS = {
    "kyoto-travel-guide.pdf": (
        "京都観光ガイド",
        [
            "京都は千年以上の歴史を持つ古都です。清水寺や金閣寺など、世界遺産に登録された寺院が数多くあります。",
            "秋は紅葉の名所として知られ、十一月中旬から下旬にかけて多くの観光客が訪れます。",
            "市内の移動にはバスや地下鉄が便利です。早朝に訪れると混雑を避けられます。",
        ],
    ),
    "opensearch-intro.pdf": (
        "OpenSearch入門ガイド",
        [
            "OpenSearchはオープンソースの分散検索・分析エンジンです。全文検索やログ分析に利用できます。",
            "日本語の文章を検索するには、形態素解析器kuromojiを用いたアナライザーを設定します。",
            "PDFファイルを検索対象にするには、ingest-attachmentプラグインで本文を抽出してインデックスに登録します。",
        ],
    ),
    "security-policy.pdf": (
        "情報セキュリティ方針",
        [
            "当社は、お客様の個人情報を適切に保護するため、アクセス権限の管理と定期的な監査を実施します。",
            "パスワードは十二文字以上とし、多要素認証の利用を必須とします。",
            "インシデントが発生した場合は、速やかに情報セキュリティ担当者へ報告してください。",
        ],
    ),
}

# (タイトル, [スライド(見出し, 本文, 発表者ノート)])
PPTX_DOCS = {
    "sales-strategy.pptx": (
        "新製品発表資料",
        [
            ("来期の販売戦略", "東京と大阪で先行発売を行います。\n全国展開は第二四半期を予定しています。", "価格改定は十月から実施"),
            ("市場分析", "競合他社の動向と顧客満足度の調査結果をまとめました。", "顧客アンケートは三千人規模"),
        ],
    ),
    "opensearch-training.pptx": (
        "OpenSearch研修スライド",
        [
            ("全文検索の基礎", "転置インデックスにより、大量の文章を高速に検索できます。", "初心者向けに図を使って説明する"),
            ("日本語検索の設定", "kuromojiで形態素解析を行い、単語単位で検索します。\nPowerPointやPDFも本文を抽出して検索できます。", "ingest-attachmentプラグインを紹介"),
        ],
    ),
}

out = Path(__file__).parent / "documents"
out.mkdir(exist_ok=True)

for name, (title, paragraphs) in DOCS.items():
    c = canvas.Canvas(str(out / name), pagesize=A4)
    c.setTitle(title)
    c.setFont(FONT, 20)
    c.drawString(50, 780, title)
    c.setFont(FONT, 11)
    y = 740
    for p in paragraphs:
        # 約38文字ごとに折り返す
        for i in range(0, len(p), 38):
            c.drawString(50, y, p[i : i + 38])
            y -= 20
        y -= 10
    c.save()
    print("created", out / name)

for name, (title, slides) in PPTX_DOCS.items():
    prs = Presentation()
    cover = prs.slides.add_slide(prs.slide_layouts[0])
    cover.shapes.title.text = title
    for heading, body, note in slides:
        slide = prs.slides.add_slide(prs.slide_layouts[1])
        slide.shapes.title.text = heading
        slide.placeholders[1].text = body
        slide.notes_slide.notes_text_frame.text = note
    prs.save(str(out / name))
    print("created", out / name)
