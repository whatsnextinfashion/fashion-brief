#!/usr/bin/ruby
# encoding: utf-8
#
# Fashion Brief — a pre-programmed "Feedly" for fashion / luxury / retail executives.
# Runs with the Ruby that ships with macOS and with GitHub Actions (nothing to install).
#
#  1. Fetches the feeds of the media list below.
#  2. AI triage (Google Gemini, free): keeps only fashion business news (collabs, P&L, store openings,
#     M&A, appointments, China, macro hitting brand margins) with a merchandising /
#     VP-CEO angle, and translates every headline into English.
#  3. Writes docs/index.html (headlines + direct link to the media) — served by GitHub Pages.
#
#  On GitHub:  runs every morning by itself, free AI via Google Gemini (see README.md).
#  On a Mac:   ruby veille_mode.rb   (without GEMINI_API_KEY: keyword triage, no translation)
#  Options:    --days 3   --no-open
Encoding.default_external = Encoding::UTF_8
ENV["TZ"] = "Europe/Paris" # all dates ("today", 7am, 6pm) are in Paris time
$stdout.sync = true # show progress live in the GitHub logs
require "net/http"; require "uri"; require "json"; require "rexml/document"
require "time"; require "digest"; require "cgi"; require "openssl"; require "fileutils"

HERE  = File.expand_path(File.dirname(__FILE__))
CACHE = File.join(HERE, "veille_cache.json")
ARTS  = File.join(HERE, "veille_articles.json")
ARCHIVE = File.join(HERE, "veille_archive.json") # the articles shown on the site (7 days x 50/day)
# Normal runs look at today + yesterday. While the site is not complete (less than 5 days, or some articles
# not yet sorted by the AI, e.g. after a Gemini outage), look back 7 days so the gaps get filled.
# (Also when the AI rules changed: the whole week is then re-sorted with the new rules.)
PROMPT_V = 10 # bump when the triage rules change, so cached articles are re-triaged
WINDOW_DAYS = begin
  shown = JSON.parse(File.read(ARCHIVE))
  shown.map { |e| e["day"] }.uniq.size < 5 || shown.any? { |e| e["by"] != "ai" || e["v"] != PROMPT_V } ? 7 : 2
rescue StandardError
  7
end
OUT   = File.join(HERE, "docs", "index.html")
UA = "Mozilla/5.0 (Macintosh) FashionBrief/1.0"

def gnews(q, lang = "en")
  loc = lang == "fr" ? "hl=fr&gl=FR&ceid=FR:fr" : "hl=en-US&gl=US&ceid=US:en"
  q = q.gsub("when:2d", "when:#{WINDOW_DAYS}d") # 7 days while the site is filling up, then 2 days
  "https://news.google.com/rss/search?q=#{URI.encode_www_form_component(q)}&#{loc}"
end

# ─── MY MEDIA LIST ─── (add / remove lines freely)
# Media without a public RSS feed (or blocked / paywalled) go through Google News.
SOURCES = [
  ["Vogue Business",  gnews("site:voguebusiness.com when:2d")],
  ["WSJ",             gnews("site:wsj.com (fashion OR luxury OR apparel OR retailer) when:2d")],
  ["WWD",             "https://wwd.com/business-news/feed/"],
  ["WWD",             "https://wwd.com/feed/"],
  # FashionNetwork = the reference: several searches (each returns up to 100 articles) to get as many as possible
  ["FashionNetwork",  gnews("site:fashionnetwork.com when:2d", "fr")],
  ["FashionNetwork",  gnews("site:fashionnetwork.com when:2d")],
  ["FashionNetwork",  gnews("site:fashionnetwork.com (luxe OR luxury OR maroquinerie OR \"leather goods\") when:2d", "fr")],
  ["FashionNetwork",  gnews("site:fashionnetwork.com (résultats OR \"chiffre d'affaires\" OR ventes OR results OR sales OR revenue) when:2d", "fr")],
  ["FashionNetwork",  gnews("site:fashionnetwork.com (nomme OR nommée OR appoints OR CEO OR \"directeur artistique\" OR \"creative director\") when:2d", "fr")],
  ["FashionNetwork",  gnews("site:fashionnetwork.com (magasin OR boutique OR store OR flagship OR ouvre OR opens OR retail) when:2d", "fr")],
  ["FashionNetwork",  gnews("site:fashionnetwork.com (rachat OR acquisition OR acquiert OR investit OR investment OR IPO OR fusion) when:2d", "fr")],
  ["FashionNetwork",  gnews("site:fashionnetwork.com (collaboration OR collab OR capsule OR partenariat OR partnership) when:2d", "fr")],
  ["FashionNetwork",  gnews("site:fashionnetwork.com (Chine OR China OR Asie OR Asia OR Inde OR India OR \"Moyen-Orient\" OR Dubai) when:2d")],
  ["FashionNetwork",  gnews("site:fashionnetwork.com (sneakers OR sportswear OR denim OR \"prêt-à-porter\" OR ready-to-wear) when:2d")],
  ["Jing Daily",      gnews("site:jingdaily.com when:2d")],
  ["Journal du Luxe", gnews("site:journalduluxe.fr when:2d", "fr")],
  ["Drapers",         gnews("site:drapersonline.com when:2d")],
  ["FashionUnited",   "https://fashionunited.com/rss-news"],
  ["The Good Goods",  "https://thegoodgoods.fr/feed/"],
  ["The Bold Way",    gnews("site:theboldway.fr", "fr")],
  ["Les Échos",       gnews("site:lesechos.fr (luxe OR mode OR distribution OR retail) when:2d", "fr")],
  ["Financial Times", "https://www.ft.com/retail-consumer?format=rss"],
  ["Financial Times", "https://www.ft.com/luxury-goods?format=rss"],
  ["Bloomberg",       gnews("site:bloomberg.com (luxury OR fashion OR apparel OR retail OR consumer) when:2d")],
]

CATEGORIES = ["Earnings & P&L", "Collaborations", "Store openings & retail", "M&A & investment",
              "Appointments", "Regulation & policy", "Macro & geopolitics", "Strategy & product"]
ZONES = ["Europe", "China & Asia", "Middle East", "US", "Global"]
# Without AI: zone guessed from words in the headline.
ZONE_RX = {
  "China & Asia" => /\b(China|Chinese|Shanghai|Beijing|Hong Kong|Asia|Asian|Japan|Tokyo|Korea|Seoul|India|Singapore|Chine|Asie|Japon|Corée|Inde)\b/i,
  "Middle East" => /\b(Middle East|Dubai|UAE|Saudi|Riyadh|Qatar|Doha|Abu Dhabi|Gulf|Moyen-Orient|Arabie)\b/i,
  "US" => /\b(US|U\.S\.|America|American|New York|Los Angeles|Etats-Unis|États-Unis|américain\w*)\b/,
  "Europe" => /\b(Europe|European|EU|France|French|Paris|Italy|Italian|Milan|UK|Britain|British|London|Germany|German|Spain|Spanish|Fran[cç]ais|Italie|Allemagne|Espagne|Royaume-Uni)\b/,
}

TRADE = ["WWD", "Drapers", "FashionUnited", "FashionNetwork", "Vogue Business", "Jing Daily",
         "Journal du Luxe", "The Good Goods", "The Bold Way"]
KEYWORDS = {
  "Earnings & P&L" => /\b(sales|revenue|profit|earnings|results|quarter|margin|guidance|chiffre d'affaires|résultats|bénéfice|ventes|trimestre|marge)\b/i,
  "Collaborations" => /\b(collab\w*|partnership|capsule|teams up|partenariat)\b/i,
  "Store openings & retail" => /\b(opens?|opening|flagship|stores?|boutiques?|pop-up|ouvre|ouverture|magasins?|points? de vente)\b/i,
  "M&A & investment" => /\b(acqui\w+|merger|stake|takeover|buys?|investment|IPO|rachat|rachète|cession|fusion|levée)\b/i,
  "Appointments" => /\b(appoint\w*|names?|CEO|chief executive|creative director|steps down|nomm\w+|directeur|directrice)\b/i,
  "Regulation & policy" => /\b(regulation|regulator|directive|law|bill|ban|ecodesign|greenwashing|de minimis|customs|duty|due diligence|EPR|r[ée]glementation|loi|directive|interdiction|douane|éco-conception)\b/i,
  "Macro & geopolitics" => /\b(tariffs?|trade war|inflation|consumer confidence|recession|currency|droits de douane)\b/i,
}
# Out of scope (not fashion) unless it is a collaboration with a fashion brand. Used without AI and to clean
# articles sorted with older rules.
OUT_OF_SCOPE = /\b(jewel\w*|joaill\w*|bijou\w*|watches|watchmak\w*|horlog\w*|montres?|beauty|beauté|cosm[eé]ti\w*|fragrances?|parfum\w*|perfumes?|skincare|make-?up|maquillage|spirits|wines?|hotels?|hôtel\w*)\b/i
COLLAB = /\b(collab\w*|capsule|partnership|partenariat|teams up|x [A-Z])\b/i

FASHION_WORDS = /\b(fashion|clothing|apparel|garments?|ready-to-wear|leather|maroquinerie|mode|habillement|vêtements?|textile|couture|footwear|shoes|chaussures|sneakers?|denim)\b/i

def out_of_scope?(text)
  text =~ OUT_OF_SCOPE && text !~ COLLAB
end

FASHION = /(fashion|luxury|apparel|retail|brand|LVMH|Kering|Hermès|Chanel|Prada|Gucci|Inditex|Zara|H&M|Nike|Adidas|Richemont|Tapestry|mode|luxe|prêt-à-porter|habillement|textile|maroquinerie|sneaker|department store)/i

# Media accepted from the brand & regulation searches (recognised business / fashion / news media).
TRUSTED = /\A(WWD|Vogue Business|Vogue|Business of Fashion|The Business of Fashion|FashionNetwork|FashionUnited|Drapers|Jing Daily|Journal du Luxe|Les Échos|Financial Times|Bloomberg|WSJ|Reuters|AFP|Associated Press|AP News|CNBC|Forbes|Fortune|Business Insider|Insider|The New York Times|New York Times|Washington Post|The Guardian|The Times|The Telegraph|Evening Standard|BBC|The Economist|Harper's BAZAAR|Harper's Bazaar|ELLE|Elle|Grazia|L'Officiel|Hypebeast|Highsnobiety|Glossy|Modern Retail|Retail Dive|Retail Gazette|Retail Week|Luxury Daily|Le Monde|Le Figaro|Madame Figaro|Le Parisien|Libération|L'Express|Le Point|Challenges|Capital|BFM|BFMTV|La Tribune|L'Opinion|Les Echos Week-End|Il Sole 24 Ore|Corriere della Sera|MF Fashion|Pambianco|Handelsblatt|Süddeutsche Zeitung|El País|Expansión|South China Morning Post|SCMP|Nikkei Asia|Nikkei|Caixin|Hindustan Times|The Times of India|Times of India|The Economic Times|Economic Times|Mint|Livemint|Business Standard|The Hindu|Vogue India|Arabian Business|The National|Gulf News|Yahoo Finance|MarketWatch|Barron's|Axios|Semafor|Politico|Euronews|Fashion Dive)\z/i

def normalize_source(s)
  s = s.to_s.strip
  { /fashionnetwork/i => "FashionNetwork", /wall street journal|\bwsj\b/i => "WSJ", /bloomberg/i => "Bloomberg",
    /financial times|\bft\.com/i => "Financial Times", /women'?s wear daily/i => "WWD", /les [ée]chos/i => "Les Échos",
    /business of fashion/i => "Business of Fashion", /fashionunited/i => "FashionUnited", /reuters/i => "Reuters",
    /south china morning post/i => "South China Morning Post", /harper'?s bazaar/i => "Harper's Bazaar",
    /times of india/i => "The Times of India", /new york times/i => "The New York Times", /livemint/i => "Mint" }
    .each { |rx, name| return name if s =~ rx }
  s[0, 40]
end

# ─── Fetching ───
def http_get(url, limit = 4)
  uri = URI(url)
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 15, read_timeout: 20) do |h|
    h.request(Net::HTTP::Get.new(uri, "User-Agent" => UA))
  end
  return http_get(URI.join(url, res["location"]).to_s, limit - 1) if res.is_a?(Net::HTTPRedirection) && limit > 0
  raise "HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)
  res.body.force_encoding("UTF-8")
end

def clean(s)
  CGI.unescapeHTML((s || "").gsub(/<[^>]+>/, " ")).gsub(/\s+/, " ").strip
end

def parse_date(s)
  (s ? Time.parse(s) : Time.now).utc
rescue
  Time.now.utc
end

def fetch(name, url)
  doc = REXML::Document.new(http_get(url))
  gn = url.include?("news.google.com")
  items = []
  doc.each_element("//item | //*[local-name()='entry']") do |it|
    txt = lambda { |*ks| it.elements.find { |c| ks.include?(c.name) } }
    t, l, d, ds = txt.call("title"), txt.call("link"), txt.call("pubDate", "published", "updated"), txt.call("description", "summary")
    title = t ? clean(t.text) : ""
    link = l ? ((l.text || "").strip.empty? ? l.attributes["href"].to_s : l.text.strip) : ""
    next if title.empty? || link !~ %r{\Ahttps?://}i # security: only real web links, never "javascript:" etc.
    2.times { title = title.sub(/\s+-\s+[^-]+\z/, "") } if gn # Google News appends " - Media"
    next if title.size < 20 || title =~ /Application error|Page \d+|^News\b|FashionNetwork France|^Find fashion jobs/i
    source = name
    if [BRAND_FEED, REG_FEED].include?(name) # searches: show the real media name (e.g. "Reuters", "Le Figaro")
      pub = txt.call("source")
      source = normalize_source(pub ? clean(pub.text) : "")
      next unless source =~ TRUSTED # quality & safety: only recognised media, no unknown / spam sites
    end
    origin = name == BRAND_FEED ? "brands" : name == REG_FEED ? "regulation" : "media"
    items << { "source" => source, "title" => title, "link" => link, "origin" => origin,
               "date" => parse_date(d && d.text).iso8601, "summary" => gn ? "" : clean(ds && ds.text)[0, 800] }
  end
  items
rescue StandardError => e
  warn "  ! #{name}: #{e.message[0, 80]}"
  []
end

def article_id(a)
  Digest::SHA1.hexdigest(a["title"].downcase.gsub(/[^[:alnum:]]/, ""))[0, 12]
end

# Fresh news only: articles published TODAY (Paris time), plus YESTERDAY's so that the evening
# news published after the 6pm run is picked up by the next 7am run. Nothing older.
# MY MEDIA (SOURCES) are the main feed. Two extras, on top of it:
#  - "brands": other recognised media, kept ONLY when the article is about one of MY BRANDS;
#  - "regulation": recognised media, kept ONLY when it is regulation impacting fashion retail / business.
BRAND_FEED = "__brands__"
REG_FEED   = "__regulation__"
# Names too ambiguous for a web search on their own (the AI still knows them through the WATCHLIST).
AMBIGUOUS = ["Bode", "The Row", "Pronounce", "Torani", "AMPM", "Caruso", "Celine", "Bally", "Etro", "Charvet"]

# Extra feeds: any media talking about MY BRANDS (Google News search, English + French, last 2 days).
def brand_feeds
  names = WATCHLIST.values.join(", ").split(", ").map { |n| n.sub(/\s*\(.*\)/, "").strip } - AMBIGUOUS
  names.each_slice(8).flat_map do |group|
    q = "(" + group.map { |n| "\"#{n}\"" }.join(" OR ") + ") when:2d"
    [[BRAND_FEED, gnews(q)], [BRAND_FEED, gnews(q, "fr")]]
  end
end

# Extra feeds: regulation that can impact fashion retail & business (any media, last 2 days).
REGULATION_FEEDS = [
  [REG_FEED, gnews('(fashion OR apparel OR textile OR luxury OR retail) (regulation OR law OR directive OR ' \
                     'ban OR "de minimis" OR customs OR tariff OR greenwashing OR ecodesign OR "due diligence") when:2d')],
  [REG_FEED, gnews('(mode OR textile OR luxe OR habillement OR commerce) (loi OR réglementation OR directive OR ' \
                     '"fast fashion" OR douane OR "droits de douane" OR greenwashing OR "éco-conception" OR REP) when:2d', "fr")],
]

def collect(days)
  feeds = SOURCES + brand_feeds + REGULATION_FEEDS
  puts "Fetching #{SOURCES.size} media feeds + #{feeds.size - SOURCES.size} searches (my brands, regulation)..."
  raw = feeds.each_slice(8).flat_map { |batch| batch.map { |n, u| Thread.new { fetch(n, u) } }.flat_map(&:value) }
  start = Time.now - (days - 1) * 86_400
  cutoff = Time.new(start.year, start.month, start.day, 0, 0, 0) # midnight, Paris time
  unique = {}
  raw.each do |a| # same article found twice: keep the version from MY MEDIA
    a["id"] = article_id(a)
    unique[a["id"]] = a if !unique[a["id"]] || (a["origin"] == "media" && unique[a["id"]]["origin"] != "media")
  end
  arts = unique.values.select { |a| t = Time.parse(a["date"]); t >= cutoff && t <= Time.now + 3600 }
               .sort_by { |a| a["date"] }.reverse
  puts "  #{raw.size} articles fetched, #{arts.size} unique published since #{cutoff.strftime('%a %d %b %H:%M')} (Paris)."
  File.write(ARTS, JSON.generate(arts))
  arts
end

# ─── MY BRANDS (watchlist) ─── highest priority; add / remove names freely
WATCHLIST = {
  "Luxury houses & groups" => "Louis Vuitton, Dior, Chanel, Hermès, Gucci, Saint Laurent, Bottega Veneta, Prada, Miu Miu, " \
    "Fendi, Celine, Loewe, Balenciaga, Givenchy, Burberry, Giorgio Armani, Versace, Valentino, Dolce & Gabbana, " \
    "Salvatore Ferragamo, Moncler, Maison Margiela, Alexander McQueen, Goyard, Moynat",
  "Craftsmanship, tailoring & leather" => "Loro Piana, Brunello Cucinelli, Berluti, Stefano Ricci, Charvet, Delvaux, " \
    "Valextra, John Lobb, Corthay, Schiaparelli, Etro, Ermenegildo Zegna, Brioni, Kiton, Cesare Attolini, Serapian, " \
    "Lardini, Bally, Jean Paul Gaultier, Alaïa, Courrèges, Caruso, Valstar, Pringle of Scotland, Smythson",
  "American luxury & designers" => "Ralph Lauren (Purple Label), Tom Ford, The Row, Oscar de la Renta, Carolina Herrera, " \
    "Khaite, Bode, Fear of God, Thom Browne, Proenza Schouler, Rick Owens, Chrome Hearts, Lela Rose, Brandon Maxwell, " \
    "Gabriela Hearst",
  "Indian luxury & couture" => "Sabyasachi, Rahul Mishra, Anita Dongre, Tarun Tahiliani, Gaurav Gupta, Raw Mango, " \
    "Abu Jani Sandeep Khosla, Falguni Shane Peacock, Anamika Khanna, Ritu Kumar, Torani, Payal Singhal, AMPM, NorBlack NorWhite",
  "Chinese luxury & couture" => "Shang Xia, Guo Pei, Shiatzy Chen, Uma Wang, Robert Wun, Ms MIN, Chen Peng, Feng Chen Wang, " \
    "Sankuanz, Huishan Zhang, Pronounce, Maison Sans Titre, Xu Zhi, Samuel Gui Yang, Ziggy Chen",
  "International designer houses" => "Kenzo, Jacquemus, Dries Van Noten, Sacai, Issey Miyake, Acne Studios",
  "Emerging houses" => "Songmont, Marge Sherwood, Mansur Gavriel",
}
# Without AI, only unambiguous names are matched (e.g. not "Bode", "The Row" or "Celine").
WATCH_RX = /\b(Louis Vuitton|Dior|Chanel|Herm[eè]s|Gucci|Saint Laurent|Bottega Veneta|Prada|Miu Miu|Fendi|Loewe|Balenciaga|Givenchy|Burberry|Armani|Versace|Valentino|Dolce|Ferragamo|Moncler|Margiela|McQueen|Goyard|Moynat|Loro Piana|Cucinelli|Berluti|Stefano Ricci|Charvet|Delvaux|Valextra|John Lobb|Corthay|Schiaparelli|Zegna|Brioni|Kiton|Attolini|Serapian|Lardini|Gaultier|Ala[iï]a|Courr[eè]ges|Pringle of Scotland|Smythson|Ralph Lauren|Tom Ford|Oscar de la Renta|Carolina Herrera|Khaite|Fear of God|Thom Browne|Proenza Schouler|Rick Owens|Chrome Hearts|Brandon Maxwell|Gabriela Hearst|Sabyasachi|Rahul Mishra|Anita Dongre|Tahiliani|Gaurav Gupta|Raw Mango|Abu Jani|Falguni|Anamika Khanna|Ritu Kumar|Payal Singhal|NorBlack|Shang Xia|Guo Pei|Shiatzy Chen|Uma Wang|Robert Wun|Feng Chen Wang|Sankuanz|Huishan Zhang|Ziggy Chen|Kenzo|Jacquemus|Dries Van Noten|Sacai|Issey Miyake|Acne Studios|Songmont|Marge Sherwood|Mansur Gavriel|LVMH|Kering|Richemont)\b/i

# ─── AI triage ───
PROMPT = <<~P
  You are the press-monitoring assistant of a fashion / luxury / retail executive (VP / CEO) with a merchandising mindset.
  For each article (headline + optional summary, in English or French), decide whether it belongs in their business news brief.

  The goal: about 100 business-oriented FASHION news per day. Be generous with fashion business news.

  SCOPE = FASHION ONLY: ready-to-wear, couture, leather goods & bags, shoes, fashion accessories, menswear &
  tailoring, knitwear, denim, sportswear & outdoor APPAREL, fashion retail & e-commerce, department stores,
  textile, sourcing & manufacturing for fashion. Fashion groups (LVMH, Kering, Inditex, H&M...) count when the
  news concerns the group or its fashion business.
  OUT OF SCOPE (reject): jewellery, watches, beauty, cosmetics, fragrance, eyewear-only tech, hotels, food,
  wine & spirits, cars, real estate, art, general finance or tech - UNLESS the article is about a collaboration
  with a fashion brand or the fashion business of a fashion house (e.g. a fashion house's results).

  KEEP (any fashion brand, any segment, and general fashion-industry topics): results / P&L / sales;
  collaborations; store openings & closures, new markets, retail & e-commerce; M&A, investments, IPOs,
  bankruptcies; appointments (CEO, creative directors...); strategy, pricing, assortment, merchandising,
  distribution, supply chain & sourcing; consumer & market trends with figures; macro, tariffs, geopolitics
  impacting fashion; sustainability as a business topic; REGULATION impacting fashion retail & business
  (fast-fashion laws, customs / de minimis, EU textile rules, ecodesign, EPR, green claims, due diligence...).
  REJECT also pure style & entertainment content: red carpets and celebrity looks, "best skirt/bag of the season",
  colour or silhouette trends, what to wear / how to style, editors' picks, wish lists, gift guides, street style,
  runway reviews with no business angle, horoscopes, job ads.
  DUPLICATES: if several articles (even in different languages) cover the same story, keep ONE (the most complete)
  and set keep=false for the others.

  Categories: %CATS%

  PRIORITIES (they change the SCORE, they never exclude anything):
  - Luxury fashion (ready-to-wear, couture, leather goods, shoes, tailoring of luxury & designer houses) first.
  - WATCHLIST brands below: a GUIDE only - if an article is about one of them, keep it and add +1 notch.
    Other brands and general topics are just as welcome and are rated normally.
  %WATCH%

  Score (importance for a fashion business executive): 5 = must know today (major group results, big M&A, top
  CEO / creative-director change); 4 = important; 3 = useful business news; 2 = minor but still business news;
  1 = not really business news (it will not be shown).

  Reply ONLY with JSON: a list of objects {"id": ..., "keep": true/false, "cat": "<category>",
  "score": 1-5, "luxury": true ONLY if the story is mainly about a luxury FASHION house/group or the luxury fashion
  market (false for non-fashion luxury, premium/accessible brands such as Lacoste, Coach, Canada Goose, Hugo Boss,
  Pandora, general retail/department stores and macro news),
  "watch": true if the story is about a WATCHLIST brand (or its group, when the news concerns its fashion business),
  "zone": "Europe" | "China & Asia" | "Middle East" | "US" | "Global" (the main market concerned; "Global" if
  several or none; Asia includes Japan, Korea, India, South-East Asia),
  "title_en": "<headline in natural English; translate if it is in French>",
  "summary": "<in English, exactly 2 concise sentences recapping the article with the key figures and facts
  (sales, %, amounts, who, where, when). Use ONLY facts present in the headline and text given - NEVER invent a
  number or a detail. If only the headline is given, write 2 short factual sentences without any new figure.>"}.
  For keep=false, just return {"id": ..., "keep": false}.

  Articles:
P

def line(a)
  "id=#{a['id']} | #{a['source']} | #{a['title']}#{a['summary'].empty? ? '' : ' | TEXT: ' + a['summary'][0, 500]}"
end

# ─── AI: Google Gemini, free tier ───
# The key is read from the GEMINI_API_KEY environment variable (a GitHub "secret").
# It is sent in a request header only — never in a URL, a file or the logs.
# Free tier without a billing account on Google = it can never cost money.
GEMINI = "https://generativelanguage.googleapis.com/v1beta"

def gemini_request(path, key, body = nil)
  uri = URI(GEMINI + path)
  Net::HTTP.start(uri.host, 443, use_ssl: true, open_timeout: 15, read_timeout: 90) do |h|
    headers = { "x-goog-api-key" => key, "content-type" => "application/json" }
    body ? h.post(uri.path, JSON.generate(body), headers) : h.get(uri.path + "?pageSize=200", headers)
  end
end

# Picks the best available "flash" model automatically (model names change over time).
def gemini_models(key)
  forced = ENV["VEILLE_GEMINI_MODEL"].to_s
  return [forced] unless forced.empty?
  res = gemini_request("/models", key)
  raise "Gemini key refused (HTTP #{res.code}) - check the GEMINI_API_KEY secret" unless res.code == "200"
  names = JSON.parse(res.body)["models"].to_a
               .select { |m| m["supportedGenerationMethods"].to_a.include?("generateContent") }
               .map { |m| m["name"].sub("models/", "") }
               .select { |n| n =~ /flash/ && n !~ /image|tts|audio|live|thinking|exp|embedding|8b/ }
  version = lambda { |n| n[/(\d+(?:\.\d+)?)/, 1].to_f }
  # stable before preview (less overloaded); newest first; full "flash" before "flash-lite"
  names.sort_by { |n| [n.include?("preview") ? 1 : 0, -version.call(n), n.include?("lite") ? 1 : 0, n.size] }
end

def ask_ai(batch, models, key)
  prompt = PROMPT.sub("%CATS%", CATEGORIES.join(", ")).sub("%WATCH%", WATCHLIST.map { |k, v| "- #{k}: #{v}" }.join("\n")) + batch.map { |a| "- " + line(a) }.join("\n")
  body = { contents: [{ role: "user", parts: [{ text: prompt }] }],
           generationConfig: { temperature: 0, responseMimeType: "application/json" } }
  attempt = 0
  while (model = models.first) && attempt < 6
    attempt += 1
    begin
      res = gemini_request("/models/#{model}:generateContent", key, body)
      if %w[400 404].include?(res.code) && models.size > 1
        warn "  ! #{model} unavailable (HTTP #{res.code}), dropping it"
        models.shift
        next
      end
      raise "HTTP #{res.code} #{res.body[0, 120]}" unless res.code == "200"
      parts = JSON.parse(res.body).dig("candidates", 0, "content", "parts").to_a
      text = parts.map { |p| p["text"].to_s }.join
      return JSON.parse(text[text.index("[")..text.rindex("]")])
    rescue StandardError => e
      warn "  ! #{model} (attempt #{attempt}): #{e.message.gsub(/\s+/, ' ')[0, 140]}"
      # Overloaded (503), out of free quota (429) or too slow: move on to the next Gemini model.
      models.push(models.shift) if models.size > 1
      sleep(e.message.include?("HTTP 429") ? 15 : 3)
    end
  end
  nil
end

def keyword_classify(a)
  text = "#{a['title']} #{a['summary']}"
  cats = KEYWORDS.select { |_, rx| text =~ rx }.keys
  # without AI: stricter keyword rule (at least 2 business signals)
  watch = !!(text =~ WATCH_RX)
  return { "keep" => false } if out_of_scope?(text)
  return { "keep" => false } if cats.empty? || !(cats.size >= 2 || watch) || !(TRADE.include?(a["source"]) || text =~ FASHION || watch)
  # capped at 3 so that AI-rated articles always rank first in the top 50
  { "keep" => true, "cat" => cats.first, "score" => 3, "angle" => "" }
end

def load_cache
  File.exist?(CACHE) ? JSON.parse(File.read(CACHE)) : {}
end

def classify(arts, cache)
  todo = arts.reject { |a| cache[a["id"]] && cache[a["id"]]["v"] == PROMPT_V } # re-triage when the rules change
  key = ENV["GEMINI_API_KEY"].to_s
  if key.empty?
    puts "No GEMINI_API_KEY: keyword triage only (less accurate, no translation)."
    return
  end
  begin
    models = gemini_models(key)
  rescue StandardError => e
    warn "  ! #{e.message}"
    return
  end
  if models.empty?
    warn "  ! No Gemini 'flash' model available: keyword triage only."
    return
  end
  puts "AI triage of #{todo.size} new articles (Gemini, free tier; models: #{models.first(4).join(", ")})..."
  failures = 0
  deadline = Time.now + 12 * 60 # time budget: always publish the page well before GitHub's 20-minute limit
  todo.each_slice(30).each_with_index do |b, i| # 30 per request (each answer now includes a 2-sentence summary)
    if Time.now > deadline
      warn "  ! time budget reached: the remaining articles will be triaged on the next run"
      break
    end
    sleep 6 if i > 0 # free tier: stay well under the requests-per-minute limit
    res = ask_ai(b, models, key)
    if res.nil?
      failures += 1
      break if failures >= 2 # AI down or daily quota reached: stop, keywords take over
      next
    end
    res.each { |r| cache[r["id"].to_s] = r.merge("by" => "ai", "v" => PROMPT_V) if r.is_a?(Hash) && r["id"] }
  end
  dedupe(arts, cache, models, key) if Time.now < deadline + 120
  live = arts.map { |a| a["id"] } + load_archive.map { |e| e["id"] }
  File.write(CACHE, JSON.generate(cache.select { |k, _| live.include?(k) })) # keep the cache small
end

# Second AI pass: the same story is often covered by several media (and was triaged in different
# batches), so we ask Gemini to group the kept headlines by story and keep only the best one.
def dedupe(arts, cache, models, key)
  kept = arts.select { |a| (c = cache[a["id"]]) && c["keep"] && c["score"].to_i >= MIN_SCORE }
  return if kept.size < 2
  list = kept.map { |a| "id=#{a['id']} | #{a['source']} | #{cache[a['id']]['title_en'] || a['title']}" }.join("\n")
  prompt = "Here are news headlines. Several may cover THE SAME STORY (same company + same event), even if worded " \
           "differently or from different media. Return ONLY JSON: a list of groups, each group a list of ids " \
           "covering the same story. Only include groups with 2 or more ids.\n\n#{list}"
  body = { contents: [{ role: "user", parts: [{ text: prompt }] }],
           generationConfig: { temperature: 0, responseMimeType: "application/json" } }
  groups = nil
  4.times do
    model = models.first
    begin
      res = gemini_request("/models/#{model}:generateContent", key, body)
      raise "HTTP #{res.code}" unless res.code == "200"
      text = JSON.parse(res.body).dig("candidates", 0, "content", "parts").to_a.map { |p| p["text"].to_s }.join
      groups = JSON.parse(text[text.index("[")..text.rindex("]")])
      break
    rescue StandardError => e
      warn "  ! dedupe with #{model}: #{e.message[0, 80]}"
      models.push(models.shift) if models.size > 1
      sleep 3
    end
  end
  return unless groups.is_a?(Array)
  removed = 0
  published = load_archive.map { |e| e["id"] }
  groups.each do |g|
    ids = Array(g).map(&:to_s).select { |id| cache[id] && cache[id]["keep"] }
    next if ids.size < 2
    # a story already published in an earlier edition stays the reference: no repeat in the next edition
    best = (ids & published).first || ids.max_by { |id| [cache[id]["score"].to_i, cache[id]["angle"].to_s.size] }
    (ids - [best]).each { |id| cache[id] = cache[id].merge("keep" => false, "dup_of" => best); removed += 1 }
  end
  puts "Removed #{removed} duplicate stories."
end

# ─── HTML page ───
MIN_SCORE   = 2   # articles rated 2+ by the AI can be shown (1 = not business news)
PER_RUN     = 50  # each update (7am and 6pm) adds the 50 most important NEW articles
PER_DAY     = 100 # so up to 100 articles per day (50 + 50)
KEEP_DAYS   = 7  # articles older than 7 days disappear from the site automatically
LUXURY = /\b(luxury|luxe|LVMH|Louis Vuitton|Dior|Kering|Gucci|Balenciaga|Saint Laurent|Herm[eè]s|Chanel|Richemont|Cartier|Prada|Miu Miu|Moncler|Armani|Burberry|Valentino|Zegna|Cucinelli|Loro Piana|Bottega|Fendi|Celine|Loewe|Tiffany|Bulgari|Rolex)\b/i

def paris_day(iso)
  Time.parse(iso).localtime.strftime("%Y-%m-%d") # TZ is Europe/Paris (set at the top)
end

def load_archive
  File.exist?(ARCHIVE) ? JSON.parse(File.read(ARCHIVE)) : []
end

# Turns a triaged article into a page entry (nil if it is not kept).
def entry(a, cache)
  c = cache[a["id"]] || keyword_classify(a)
  return nil unless c["keep"]
  return nil if c["by"] == "ai" && c["score"].to_i < MIN_SCORE
  title = c["title_en"].to_s.strip.empty? ? a["title"] : c["title_en"]
  { "id" => a["id"], "source" => a["source"], "link" => a["link"], "date" => a["date"], "day" => paris_day(a["date"]),
    "title" => title, "original" => (title == a["title"] ? "" : a["title"]),
    "cat" => (CATEGORIES.include?(c["cat"]) ? c["cat"] : "Strategy & product"),
    "score" => (c["score"] || 2).to_i.clamp(1, 5), "summary" => c["summary"].to_s,
    "zone" => ZONES.include?(c["zone"]) ? c["zone"] : guess_zone("#{a['title']} #{a['summary']}"),
    "by" => c["by"] == "ai" ? "ai" : "kw", "v" => c["v"], "origin" => a["origin"] || "media",
    "luxury" => c["luxury"] == true || (c["by"] != "ai" && !!("#{a['title']} #{a['summary']}" =~ WATCH_RX)),
    "watch" => c["watch"] == true || (c["by"] != "ai" && !!("#{a['title']} #{a['summary']}" =~ WATCH_RX)) }
end

def guess_zone(text)
  ZONE_RX.each { |zone, rx| return zone if text =~ rx }
  "Global"
end

def rank(e)
  # highest score first, AI-rated before keyword-only, my brands, luxury, FashionNetwork, then the most recent
  [-e["score"], e["by"] == "ai" ? 0 : 1, e["watch"] ? 0 : 1, e["luxury"] ? 0 : 1,
   e["source"] == "FashionNetwork" ? 0 : 1, -Time.parse(e["date"]).to_i]
end

# Articles from the extra searches only count when they match their purpose.
def eligible?(e)
  case e["origin"]
  when "brands" then e["watch"]                                        # other media: only about MY BRANDS
  when "regulation" then e["cat"] == "Regulation & policy" || e["watch"] # only regulation (or my brands)
  else true                                                            # MY MEDIA: everything kept by the AI
  end
end

# Each update (7am, 6pm) ADDS the 50 most important new articles (max 100 per day, by publication date,
# Paris time). Articles already on the site stay, unless the AI drops them (duplicate, out of scope).
# While the site is filling up (7-day window), there is no 50 limit so the past days get filled at once.
def build(_days)
  arts = File.exist?(ARTS) ? JSON.parse(File.read(ARTS)) : []
  cache = load_cache
  archive = load_archive.map { |e| e.reject { |k, _| %w[edition edition_at].include?(k) } }
  fresh = arts.map { |a| entry(a, cache) }.compact.select { |e| eligible?(e) }
  fresh_by_id = fresh.map { |e| [e["id"], e] }.to_h
  arts_ids = arts.map { |a| a["id"] }
  touched = arts.map { |a| paris_day(a["date"]) }.uniq # the days this run can still complete
  frozen = archive.reject { |e| touched.include?(e["day"]) }
  previous = archive.select { |e| touched.include?(e["day"]) }.reject do |e|
    (c = cache[e["id"]]) && c["v"] == PROMPT_V &&
      (!c["keep"] || c["score"].to_i < MIN_SCORE || (arts_ids.include?(e["id"]) && !fresh_by_id[e["id"]]))
  end.map { |e| fresh_by_id[e["id"]] || e } # refreshed with the latest AI summary / zone
  shown = previous.map { |e| e["id"] }
  per_day = Hash.new(0)
  previous.each { |e| per_day[e["day"]] += 1 }
  limit = WINDOW_DAYS == 7 ? Float::INFINITY : PER_RUN
  added = []
  fresh.reject { |e| shown.include?(e["id"]) }.sort_by { |e| rank(e) }.each do |e|
    break if added.size >= limit
    next if per_day[e["day"]] >= PER_DAY
    added << e
    per_day[e["day"]] += 1
  end
  puts "This update adds #{added.size} new articles."
  oldest = (Time.now - (KEEP_DAYS - 1) * 86_400).strftime("%Y-%m-%d")
  all = (frozen + previous + added).select { |e| e["day"] >= oldest }
  # safety net (also when the AI is too lenient): jewellery, beauty, watches... with no fashion word and no collab
  all.reject! do |e|
    t = "#{e['title']} #{e['original']}"
    out_of_scope?(t) && (e["v"] != PROMPT_V || t !~ FASHION_WORDS)
  end
  # never twice the same article (same id or same headline)
  seen = {}
  all = all.sort_by { |e| e["v"] == PROMPT_V ? 0 : 1 }.select do |e| # keep the up-to-date version
    k = e["title"].to_s.downcase.gsub(/[^[:alnum:]]/, "")[0, 80]
    ok = !seen[e["id"]] && !seen[k]
    seen[e["id"]] = seen[k] = true
    ok
  end
  # newest day first; inside a day, the most important first
  all = all.group_by { |e| e["day"] }.sort_by { |d, _| d }.reverse.flat_map { |_, es| es.sort_by { |e| rank(e) } }
  puts "Per day: " + all.group_by { |e| e["day"] }.map { |d, es| "#{d}: #{es.size}" }.join(", ")
  File.write(ARCHIVE, JSON.generate(all))
  html = DATA.read.sub("__DATA__") { JSON.generate(all).gsub("</", "<\\/") }
             .sub("__GEN__", Time.now.utc.iso8601).sub("__DAYS__", KEEP_DAYS.to_s)
             .sub("__TODAY__", Time.now.strftime("%Y-%m-%d"))
             .sub("__CATS__") { JSON.generate(CATEGORIES) }.sub("__ZONES__") { JSON.generate(ZONES) }
  FileUtils.mkdir_p(File.dirname(OUT))
  File.write(OUT, html)
  puts "Done: #{all.size} articles on the site -> #{OUT}"
end

days = (ARGV.index("--days") ? ARGV[ARGV.index("--days") + 1].to_i : WINDOW_DAYS)
case ARGV.first
when "build" then build(days)
else
  classify(collect(days), load_cache)
  build(days)
  system("open", OUT) unless ARGV.include?("--no-open") || ENV["CI"]
end

__END__
<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Fashion Brief</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&family=Playfair+Display:wght@600&display=swap" rel="stylesheet">
<style>
:root{--bg:#f7f6f3;--panel:#fff;--ink:#1b1b1b;--muted:#77736c;--line:#e7e4de;--accent:#8a6d3b;--hi:#f1ead9}
@media (prefers-color-scheme:dark){:root{--bg:#141414;--panel:#1c1c1c;--ink:#ecebe8;--muted:#9a968f;--line:#2c2c2c;--accent:#d2b47a;--hi:#2a2519}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.45 Inter,system-ui,sans-serif}
a{color:inherit;text-decoration:none}
button{font:inherit;color:inherit}
.app{display:grid;grid-template-columns:260px 1fr;min-height:100vh}
aside{border-right:1px solid var(--line);padding:22px 16px;position:sticky;top:0;height:100vh;overflow:auto;background:var(--panel)}
h1{font:600 22px "Playfair Display",serif;margin:0 0 2px}
.gen{color:var(--muted);font-size:12px;margin-bottom:14px}
.grp{display:flex;justify-content:space-between;align-items:baseline;font-size:11px;letter-spacing:.08em;text-transform:uppercase;color:var(--muted);margin:18px 0 6px}
.grp button{border:0;background:none;color:var(--accent);font-size:11px;cursor:pointer;text-transform:none;letter-spacing:0}
.f{display:flex;align-items:center;gap:8px;width:100%;border:0;background:none;padding:5px 8px;border-radius:6px;cursor:pointer;text-align:left}
.f:hover{background:var(--bg)}
.f .box{width:14px;height:14px;border:1.5px solid var(--muted);border-radius:3px;flex:none;display:grid;place-items:center;font-size:10px;line-height:1}
.f.on{background:var(--hi);color:var(--accent);font-weight:600}.f.on .box{background:var(--accent);border-color:var(--accent);color:var(--panel)}
.f .lbl{flex:1}.f .n{color:var(--muted);font-size:12px;font-weight:400}
.clear{margin-top:16px;width:100%;padding:8px;border:1px solid var(--line);border-radius:8px;background:none;cursor:pointer;color:var(--muted)}
main{padding:22px 32px;max-width:920px}
.tabs{display:flex;gap:6px;margin-bottom:14px}
.tab{border:1px solid var(--line);background:var(--panel);padding:7px 16px;border-radius:20px;cursor:pointer;font-weight:500}
.tab.on{background:var(--ink);color:var(--bg);border-color:var(--ink)}
.bar{display:flex;gap:10px;align-items:center;margin-bottom:10px;flex-wrap:wrap}
input,select{font:inherit;padding:8px 12px;border:1px solid var(--line);border-radius:8px;background:var(--panel);color:var(--ink)}
input{flex:1;min-width:180px}
.active{font-size:12px;color:var(--muted);margin-bottom:6px}
.day{font-size:12px;letter-spacing:.08em;text-transform:uppercase;color:var(--muted);margin:22px 0 4px}
.it{display:flex;gap:12px;padding:14px 4px;border-bottom:1px solid var(--line)}
.it .body{flex:1;min-width:0}
.it.read .body{opacity:.55}
.it a:hover .t{color:var(--accent)}
.meta{font-size:12px;color:var(--muted);display:flex;gap:8px;align-items:center;flex-wrap:wrap}
.src{font-weight:600;color:var(--ink)}
.tag{background:var(--hi);color:var(--accent);padding:1px 8px;border-radius:20px;font-size:11px}
.zone{border:1px solid var(--line);padding:0 8px;border-radius:20px;font-size:11px}
.lux{background:var(--accent);color:var(--panel);padding:1px 8px;border-radius:20px;font-size:11px;font-weight:600}
.t{font-weight:600;font-size:16px;margin:4px 0}
.s{color:var(--muted);font-size:13.5px}
.save{flex:none;align-self:flex-start;border:1px solid var(--line);background:var(--panel);border-radius:8px;padding:5px 10px;cursor:pointer;font-size:12px;white-space:nowrap}
.save.on{background:var(--accent);border-color:var(--accent);color:var(--panel)}
.empty{color:var(--muted);padding:40px 0}
.note{font-size:12px;color:var(--muted);margin:4px 0 10px}
.menu{display:none}
@media (max-width:760px){.app{grid-template-columns:1fr}aside{position:static;height:auto;display:none}aside.open{display:block}
 main{padding:16px}.menu{display:inline-block}}
</style></head><body>
<div class="app">
<aside id="side"><h1>Fashion Brief</h1><div class="gen" id="gen"></div>
<div class="grp">Topics<button data-clear="cats">clear</button></div><div id="cats"></div>
<div class="grp">Zones<button data-clear="zones">clear</button></div><div id="zones"></div>
<div class="grp">Media<button data-clear="srcs">clear</button></div><div id="srcs"></div>
<button class="clear" id="clearall">Clear all filters</button></aside>
<main>
<div class="tabs"><button class="tab" data-view="feed">Feed</button><button class="tab" data-view="saved">Saved <span id="nsaved"></span></button>
<button class="tab menu" onclick="side.classList.toggle('open')">☰ Filters</button></div>
<div class="bar">
<input id="q" placeholder="Search (brand, country, group…)">
<select id="sort"><option value="date">Latest</option><option value="score">Most important</option></select>
<select id="imp"><option value="all">All</option><option value="today">Today only</option><option value="watch">My brands</option><option value="lux">Luxury fashion</option></select></div>
<div class="active" id="active"></div>
<div id="list"></div></main></div>
<script>
const A=__DATA__, CATS=__CATS__, ZONES=__ZONES__, GEN=new Date("__GEN__"), TODAY="__TODAY__";
document.getElementById('gen').textContent='Updated '+GEN.toLocaleString('en-GB',{day:'numeric',month:'short',hour:'2-digit',minute:'2-digit',timeZone:'Europe/Paris'})+' (Paris)'+' · 50 new articles at 7am & 6pm · last __DAYS__ days';
const $=s=>document.querySelector(s), esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const safeLink=u=>/^https?:\/\//i.test(u||'')?u:'#';
// --- saved preferences (this browser only) ---
const load=(k,d)=>{try{const v=JSON.parse(localStorage.getItem(k));return v??d}catch(e){return d}};
const store=(k,v)=>{try{localStorage.setItem(k,JSON.stringify(v))}catch(e){}};
let P=Object.assign({view:'feed',cats:[],zones:[],srcs:[],sort:'date',imp:'all'},load('brief_prefs',{}));
let READ=load('brief_read',{}), SAVED=load('brief_saved',{});
const savePrefs=()=>store('brief_prefs',P);
const field={cats:'cat',zones:'zone',srcs:'source'};
function base(){return P.view==='saved'?Object.values(SAVED).sort((x,y)=>(y.savedAt||'').localeCompare(x.savedAt||'')):A}
function match(a,skip){ // skip = the group being counted, so counts show what each choice would add
 for(const g of ['cats','zones','srcs']){ if(g===skip)continue; if(P[g].length&&!P[g].includes(a[field[g]]))return false }
 const q=$('#q').value.toLowerCase();
 if(q&&!((a.title||'')+(a.original||'')+(a.summary||a.angle||'')+(a.source||'')).toLowerCase().includes(q))return false;
 if(P.imp==='today'&&a.day!==TODAY)return false;
 if(P.imp==='watch'&&!a.watch)return false;
 if(P.imp==='lux'&&!a.luxury)return false;
 return true}
function group(el,vals){
 const B=base(), n=v=>B.filter(a=>match(a,el)&&a[field[el]]===v).length;
 $('#'+el).innerHTML=vals.map(v=>`<button class="f ${P[el].includes(v)?'on':''}" data-g="${el}" data-v="${esc(v)}"><span class="box">${P[el].includes(v)?'✓':''}</span><span class="lbl">${esc(v)}</span><span class="n">${n(v)}</span></button>`).join('');
}
function draw(){
 document.querySelectorAll('.tab[data-view]').forEach(t=>t.classList.toggle('on',t.dataset.view===P.view));
 $('#nsaved').textContent='('+Object.keys(SAVED).length+')';
 $('#sort').value=P.sort; $('#imp').value=P.imp;
 const B=base();
 group('cats',CATS.filter(c=>B.some(a=>a.cat===c)||P.cats.includes(c)));
 group('zones',ZONES.filter(z=>B.some(a=>a.zone===z)||P.zones.includes(z)));
 group('srcs',[...new Set(B.map(a=>a.source))].concat(P.srcs).filter((v,i,s)=>v&&s.indexOf(v)===i).sort());
 const sel=[...P.cats,...P.zones,...P.srcs];
 $('#active').textContent=sel.length?'Filters: '+sel.join(' + '):'';
 let L=B.filter(a=>match(a,null));
 L=[...L].sort(P.sort==='score'
   ?(x,y)=>(y.score||0)-(x.score||0)||(y.date||'').localeCompare(x.date||'')
   :(x,y)=>(y.day||'').localeCompare(x.day||'')||(y.date||'').localeCompare(x.date||''));
 let h=P.view==='saved'?'<div class="note">Saved articles are kept on this device and never expire. Click "Saved" again to remove one.</div>':'', last='';
 for(const a of L){const d=new Date(a.date), day=new Date((a.day||a.date.slice(0,10))+'T12:00:00Z').toLocaleDateString('en-GB',{weekday:'long',day:'numeric',month:'long',timeZone:'UTC'});
  if(P.sort==='date'&&day!==last){h+=`<div class="day">${esc(day)}</div>`;last=day}
  const sv=!!SAVED[a.id];
  h+=`<div class="it ${READ[a.id]?'read':''}"><div class="body">
  <div class="meta"><span class="src">${esc(a.source)}</span><span>${d.toLocaleTimeString('en-GB',{hour:'2-digit',minute:'2-digit',timeZone:'Europe/Paris'})}</span>
  ${a.watch?`<span class="lux">My brand</span>`:a.luxury?`<span class="lux">Luxury</span>`:``}<span class="tag">${esc(a.cat)}</span>${a.zone?`<span class="zone">${esc(a.zone)}</span>`:''}</div>
  <a href="${esc(safeLink(a.link))}" target="_blank" rel="noopener noreferrer" data-id="${esc(a.id)}"${a.original?` title="Original: ${esc(a.original)}"`:''}><div class="t">${esc(a.title)}</div></a>
  ${(a.summary||a.angle)?`<div class="s">${esc(a.summary||a.angle)}</div>`:''}</div>
  <button class="save ${sv?'on':''}" data-save="${esc(a.id)}">${sv?'★ Saved':'☆ Save'}</button></div>`}
 $('#list').innerHTML=h+(L.length?'':`<div class="empty">${P.view==='saved'?'No saved article yet. Click "☆ Save" on an article to keep it here.':'No articles match these filters.'}</div>`);
}
document.addEventListener('click',e=>{
 const f=e.target.closest('.f[data-g]'); if(f){const g=f.dataset.g,v=f.dataset.v; P[g]=P[g].includes(v)?P[g].filter(x=>x!==v):[...P[g],v]; savePrefs(); draw(); return}
 const c=e.target.closest('[data-clear]'); if(c){P[c.dataset.clear]=[]; savePrefs(); draw(); return}
 if(e.target.closest('#clearall')){P.cats=[];P.zones=[];P.srcs=[];P.imp='all';$('#q').value=''; savePrefs(); draw(); return}
 const t=e.target.closest('.tab[data-view]'); if(t){P.view=t.dataset.view; savePrefs(); draw(); return}
 const s=e.target.closest('[data-save]'); if(s){const id=s.dataset.save;
  if(SAVED[id])delete SAVED[id]; else {const a=A.find(x=>x.id===id)||SAVED[id]; if(a)SAVED[id]=Object.assign({},a,{savedAt:new Date().toISOString()})}
  store('brief_saved',SAVED); draw(); return}
 const l=e.target.closest('a[data-id]'); if(l){READ[l.dataset.id]=1; store('brief_read',READ); l.closest('.it').classList.add('read')}
});
$('#q').oninput=draw;
$('#sort').onchange=()=>{P.sort=$('#sort').value; savePrefs(); draw()};
$('#imp').onchange=()=>{P.imp=$('#imp').value; savePrefs(); draw()};
draw();
</script></body></html>
