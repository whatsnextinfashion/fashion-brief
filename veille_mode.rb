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
# Normal runs look at today + yesterday. While the site has less than 5 days of history, look back 7 days
# so that the whole week is filled at once.
WINDOW_DAYS = ((JSON.parse(File.read(ARCHIVE)).map { |e| e["day"] }.uniq.size rescue 0) < 5) ? 7 : 2
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
  ["FashionNetwork",  gnews("site:fashionnetwork.com when:2d", "fr")],
  ["FashionNetwork",  gnews("site:fashionnetwork.com when:2d")],
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
              "Appointments", "China & Asia", "Regulation & policy", "Macro & geopolitics", "Strategy & product"]

TRADE = ["WWD", "Drapers", "FashionUnited", "FashionNetwork", "Vogue Business", "Jing Daily",
         "Journal du Luxe", "The Good Goods", "The Bold Way"]
KEYWORDS = {
  "Earnings & P&L" => /\b(sales|revenue|profit|earnings|results|quarter|margin|guidance|chiffre d'affaires|résultats|bénéfice|ventes|trimestre|marge)\b/i,
  "Collaborations" => /\b(collab\w*|partnership|capsule|teams up|partenariat)\b/i,
  "Store openings & retail" => /\b(opens?|opening|flagship|stores?|boutiques?|pop-up|ouvre|ouverture|magasins?|points? de vente)\b/i,
  "M&A & investment" => /\b(acqui\w+|merger|stake|takeover|buys?|investment|IPO|rachat|rachète|cession|fusion|levée)\b/i,
  "Appointments" => /\b(appoint\w*|names?|CEO|chief executive|creative director|steps down|nomm\w+|directeur|directrice)\b/i,
  "China & Asia" => /\b(China|Chinese|Shanghai|Hong Kong|Asia|Japan|Korea|Chine|Asie|Japon|Corée)\b/i,
  "Regulation & policy" => /\b(regulation|regulator|directive|law|bill|ban|ecodesign|greenwashing|de minimis|customs|duty|due diligence|EPR|r[ée]glementation|loi|directive|interdiction|douane|éco-conception)\b/i,
  "Macro & geopolitics" => /\b(tariffs?|trade war|inflation|consumer confidence|recession|currency|droits de douane)\b/i,
}
FASHION = /(fashion|luxury|apparel|retail|brand|LVMH|Kering|Hermès|Chanel|Prada|Gucci|Inditex|Zara|H&M|Nike|Adidas|Richemont|Tapestry|mode|luxe|prêt-à-porter|habillement|textile|maroquinerie|sneaker|beauty|beauté|department store)/i

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
               "date" => parse_date(d && d.text).iso8601, "summary" => gn ? "" : clean(ds && ds.text)[0, 400] }
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
PROMPT_V = 9 # bump when the triage rules change, so cached articles are re-triaged
PROMPT = <<~P
  You are the press-monitoring assistant of a fashion / luxury / retail executive (VP / CEO) with a merchandising mindset.
  For each article (headline + optional summary, in English or French), decide whether it belongs in their business news brief.

  The goal: about 50 business-oriented FASHION news per day. Be generous with business news.

  KEEP (any brand, any segment - luxury, premium, designer, mass market, sportswear, leather goods, shoes - and
  general industry topics): results / P&L / sales; collaborations; store openings & closures, new markets, retail
  & e-commerce; M&A, investments, IPOs, bankruptcies; appointments (CEO, creative directors...); strategy, pricing,
  assortment, merchandising, distribution, supply chain & sourcing; consumer & market trends with figures;
  China, Asia, India, Middle East markets; macro, tariffs, geopolitics impacting fashion; sustainability as a
  business topic; REGULATION impacting fashion retail & business (fast-fashion laws, customs / de minimis, EU
  textile rules, ecodesign, EPR, green claims, due diligence, labelling, e-commerce rules, duty-free...).
  REJECT ONLY pure style & entertainment content: red carpets and celebrity looks, "best skirt/bag of the season",
  colour or silhouette trends, what to wear / how to style, editors' picks, wish lists, gift guides, street style,
  beauty looks, runway reviews with no business angle, horoscopes, job ads, and news with no link to the
  fashion / retail business at all.
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
  "title_en": "<headline in natural English; translate if it is in French>",
  "angle": "<in English, 1 sentence, max 20 words: why it matters for the business / merchandising>"}.
  For keep=false, just return {"id": ..., "keep": false}.

  Articles:
P

def line(a)
  "id=#{a['id']} | #{a['source']} | #{a['title']}#{a['summary'].empty? ? '' : ' | ' + a['summary'][0, 160]}"
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
  todo.each_slice(60).each_with_index do |b, i| # 60 per request = fewer requests (free daily quota)
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
MIN_SCORE   = 2  # articles rated 2+ by the AI can be shown (1 = not business news)
PER_DAY     = 50 # the 50 most important articles of EACH day (refreshed at 7am and 6pm)
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
    "score" => (c["score"] || 2).to_i.clamp(1, 5), "angle" => c["angle"].to_s,
    "by" => c["by"] == "ai" ? "ai" : "kw", "origin" => a["origin"] || "media",
    "luxury" => c["luxury"] == true || (c["by"] != "ai" && !!("#{a['title']} #{a['summary']}" =~ WATCH_RX)),
    "watch" => c["watch"] == true || (c["by"] != "ai" && !!("#{a['title']} #{a['summary']}" =~ WATCH_RX)) }
end

def rank(e)
  # highest score first, AI-rated before keyword-only, luxury first on equal score, then the most recent
  [-e["score"], e["by"] == "ai" ? 0 : 1, e["watch"] ? 0 : 1, e["luxury"] ? 0 : 1, -Time.parse(e["date"]).to_i]
end

# Articles from the extra searches only count when they match their purpose.
def eligible?(e)
  case e["origin"]
  when "brands" then e["watch"]                                        # other media: only about MY BRANDS
  when "regulation" then e["cat"] == "Regulation & policy" || e["watch"] # only regulation (or my brands)
  else true                                                            # MY MEDIA: everything kept by the AI
  end
end

# Each day (by publication date, Paris time) shows its 50 most important articles. The 7am and 6pm runs
# refresh today's (and yesterday's) selection; older days stay as they were, for 7 days.
def build(_days)
  arts = File.exist?(ARTS) ? JSON.parse(File.read(ARTS)) : []
  cache = load_cache
  archive = load_archive.map { |e| e.reject { |k, _| %w[edition edition_at].include?(k) } }
  fresh = arts.map { |a| entry(a, cache) }.compact.select { |e| eligible?(e) }
  touched = arts.map { |a| paris_day(a["date"]) }.uniq # the days this run can still improve
  frozen = archive.reject { |e| touched.include?(e["day"]) }
  # articles already shown for those days stay candidates, unless the AI dropped them (e.g. duplicate)
  previous = archive.select { |e| touched.include?(e["day"]) }.reject do |e|
    (c = cache[e["id"]]) && c["v"] == PROMPT_V && (!c["keep"] || c["score"].to_i < MIN_SCORE)
  end
  pool = fresh + previous.reject { |e| fresh.any? { |f| f["id"] == e["id"] } }
  selected = pool.group_by { |e| e["day"] }.values.flat_map { |es| es.sort_by { |e| rank(e) }.first(PER_DAY) }
  oldest = (Time.now - (KEEP_DAYS - 1) * 86_400).strftime("%Y-%m-%d")
  all = (frozen + selected).select { |e| e["day"] >= oldest }
  # newest day first; inside a day, the most important first
  all = all.group_by { |e| e["day"] }.sort_by { |d, _| d }.reverse.flat_map { |_, es| es.sort_by { |e| rank(e) } }
  puts "Per day: " + all.group_by { |e| e["day"] }.map { |d, es| "#{d}: #{es.size}" }.join(", ")
  File.write(ARCHIVE, JSON.generate(all))
  html = DATA.read.sub("__DATA__") { JSON.generate(all).gsub("</", "<\\/") }
             .sub("__GEN__", Time.now.utc.iso8601).sub("__DAYS__", KEEP_DAYS.to_s)
             .sub("__TODAY__", Time.now.strftime("%Y-%m-%d"))
             .sub("__CATS__") { JSON.generate(CATEGORIES) }
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
.app{display:grid;grid-template-columns:250px 1fr;min-height:100vh}
aside{border-right:1px solid var(--line);padding:22px 16px;position:sticky;top:0;height:100vh;overflow:auto;background:var(--panel)}
h1{font:600 22px "Playfair Display",serif;margin:0 0 2px}
.gen{color:var(--muted);font-size:12px;margin-bottom:18px}
.grp{font-size:11px;letter-spacing:.08em;text-transform:uppercase;color:var(--muted);margin:18px 0 6px}
.f{display:flex;justify-content:space-between;width:100%;border:0;background:none;color:var(--ink);font:inherit;
   padding:6px 8px;border-radius:6px;cursor:pointer;text-align:left}
.f:hover{background:var(--bg)}.f.on{background:var(--hi);color:var(--accent);font-weight:600}
.f span{color:var(--muted);font-size:12px}
main{padding:22px 32px;max-width:900px}
.bar{display:flex;gap:10px;align-items:center;margin-bottom:16px;flex-wrap:wrap}
input,select{font:inherit;padding:8px 12px;border:1px solid var(--line);border-radius:8px;background:var(--panel);color:var(--ink)}
input{flex:1;min-width:180px}
.day{font-size:12px;letter-spacing:.08em;text-transform:uppercase;color:var(--muted);margin:22px 0 4px}
.it{display:block;padding:14px 4px;border-bottom:1px solid var(--line)}
.it:hover .t{color:var(--accent)}
.it.read{opacity:.5}
.meta{font-size:12px;color:var(--muted);display:flex;gap:8px;align-items:center;flex-wrap:wrap}
.src{font-weight:600;color:var(--ink)}
.tag{background:var(--hi);color:var(--accent);padding:1px 8px;border-radius:20px;font-size:11px}
.lux{background:var(--accent);color:var(--panel);padding:1px 8px;border-radius:20px;font-size:11px;font-weight:600}
.t{font-weight:600;font-size:16px;margin:3px 0}
.a{color:var(--muted);font-size:13.5px}
.dots{color:var(--accent);letter-spacing:1px}
.empty{color:var(--muted);padding:40px 0}
.menu{display:none}
@media (max-width:760px){.app{grid-template-columns:1fr}aside{position:static;height:auto;display:none}aside.open{display:block}
 main{padding:16px}.menu{display:inline-block}}
</style></head><body>
<div class="app">
<aside id="side"><h1>Fashion Brief</h1><div class="gen" id="gen"></div>
<div class="grp">Topics</div><div id="cats"></div><div class="grp">Media</div><div id="srcs"></div></aside>
<main>
<div class="bar"><button class="f menu" onclick="side.classList.toggle('open')">☰ Filters</button>
<input id="q" placeholder="Search (brand, country, group…)">
<select id="sort"><option value="date">Latest</option><option value="score">Most important</option></select>
<select id="imp"><option value="1">All (7 days)</option><option value="today">Today only</option><option value="watch">My brands</option><option value="lux">Luxury fashion</option><option value="4">Must-read (★4+)</option></select></div>
<div id="list"></div></main></div>
<script>
const A=__DATA__, CATS=__CATS__, GEN=new Date("__GEN__"); let fc=null, fs=null;
document.getElementById('gen').textContent='Updated '+GEN.toLocaleString('en-GB',{day:'numeric',month:'short',hour:'2-digit',minute:'2-digit'})+' · top 50 per day · updated 7am & 6pm · last __DAYS__ days';
let read={}; try{read=JSON.parse(localStorage.getItem('brief_read')||'{}')}catch(e){}
const $=s=>document.querySelector(s), esc=s=>s.replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
function btns(el,vals,cur,set){const n=v=>A.filter(a=>v===null||(el==='cats'?a.cat:a.source)===v).length;
 $('#'+el).innerHTML=[null,...vals].map(v=>`<button class="f ${v===cur?'on':''}" data-v="${v??''}">${v??'All'}<span>${n(v)}</span></button>`).join('');
 $('#'+el).querySelectorAll('button').forEach(b=>b.onclick=()=>{set(b.dataset.v||null);draw()});}
function draw(){
 btns('cats',CATS.filter(c=>A.some(a=>a.cat===c)),fc,v=>fc=v);
 btns('srcs',[...new Set(A.map(a=>a.source))].sort(),fs,v=>fs=v);
 const q=$("#q").value.toLowerCase(), imp=$("#imp").value, min=(imp==="lux"||imp==="today"||imp==="watch")?1:+imp, TODAY="__TODAY__";
 let L=A.filter(a=>(!fc||a.cat===fc)&&(!fs||a.source===fs)&&a.score>=min&&(imp!=="lux"||a.luxury)&&(imp!=="watch"||a.watch)&&(imp!=="today"||a.day===TODAY)&&(!q||(a.title+a.original+a.angle+a.source).toLowerCase().includes(q)));
 if($('#sort').value==='score')L.sort((x,y)=>y.score-x.score||y.date.localeCompare(x.date));
 let h='',last='';
 for(const a of L){const d=new Date(a.date), ed=new Date(a.edition_at||a.date), day=ed.toLocaleDateString('en-GB',{weekday:'long',day:'numeric',month:'long'})+(a.edition?' · '+a.edition:'');
  if($('#sort').value==='date'&&day!==last){h+=`<div class="day">${esc(day)}</div>`;last=day}
  h+=`<a class="it ${read[a.id]?'read':''}" href="${esc(a.link)}" target="_blank" rel="noopener" data-id="${a.id}"${a.original?` title="Original: ${esc(a.original)}"`:''}>
  <div class="meta"><span class="src">${esc(a.source)}</span><span>${d.toLocaleTimeString('en-GB',{hour:'2-digit',minute:'2-digit'})}</span>
  ${a.watch?`<span class="lux">My brand</span>`:a.luxury?`<span class="lux">Luxury</span>`:``}<span class="tag">${esc(a.cat)}</span><span class="dots">${'★'.repeat(a.score)}</span></div>
  <div class="t">${esc(a.title)}</div>${a.angle?`<div class="a">→ ${esc(a.angle)}</div>`:''}</a>`}
 $('#list').innerHTML=h||'<div class="empty">No articles match these filters.</div>';
 document.querySelectorAll('.it').forEach(e=>e.onclick=()=>{read[e.dataset.id]=1;e.classList.add('read');
  try{localStorage.setItem('brief_read',JSON.stringify(read))}catch(_){}});
}
['q','sort','imp'].forEach(i=>$('#'+i).oninput=draw);draw();
</script></body></html>
