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
require "net/http"; require "uri"; require "json"; require "rexml/document"
require "time"; require "digest"; require "cgi"; require "openssl"; require "fileutils"

HERE  = File.expand_path(File.dirname(__FILE__))
CACHE = File.join(HERE, "veille_cache.json")
ARTS  = File.join(HERE, "veille_articles.json")
OUT   = File.join(HERE, "docs", "index.html")
UA = "Mozilla/5.0 (Macintosh) FashionBrief/1.0"

def gnews(q, lang = "en")
  loc = lang == "fr" ? "hl=fr&gl=FR&ceid=FR:fr" : "hl=en-US&gl=US&ceid=US:en"
  "https://news.google.com/rss/search?q=#{URI.encode_www_form_component(q)}&#{loc}"
end

# ─── MY MEDIA LIST ─── (add / remove lines freely)
# Media without a public RSS feed (or blocked / paywalled) go through Google News.
SOURCES = [
  ["Vogue Business",  gnews("site:voguebusiness.com when:7d")],
  ["WSJ",             gnews("site:wsj.com (fashion OR luxury OR apparel OR retailer) when:7d")],
  ["WWD",             "https://wwd.com/business-news/feed/"],
  ["WWD",             "https://wwd.com/feed/"],
  ["FashionNetwork",  gnews("site:fashionnetwork.com when:3d", "fr")],
  ["FashionNetwork",  gnews("site:fashionnetwork.com when:3d")],
  ["Jing Daily",      gnews("site:jingdaily.com when:7d")],
  ["Journal du Luxe", gnews("site:journalduluxe.fr when:7d", "fr")],
  ["Drapers",         gnews("site:drapersonline.com when:7d")],
  ["FashionUnited",   "https://fashionunited.com/rss-news"],
  ["The Good Goods",  "https://thegoodgoods.fr/feed/"],
  ["The Bold Way",    gnews("site:theboldway.fr", "fr")],
  ["Les Échos",       gnews("site:lesechos.fr (luxe OR mode OR distribution OR retail) when:7d", "fr")],
  ["Financial Times", "https://www.ft.com/retail-consumer?format=rss"],
  ["Financial Times", "https://www.ft.com/luxury-goods?format=rss"],
  ["Bloomberg",       gnews("site:bloomberg.com (luxury OR fashion OR apparel OR retail OR consumer) when:7d")],
]

CATEGORIES = ["Earnings & P&L", "Collaborations", "Store openings & retail", "M&A & investment",
              "Appointments", "China & Asia", "Macro & geopolitics", "Strategy & product"]

TRADE = ["WWD", "Drapers", "FashionUnited", "FashionNetwork", "Vogue Business", "Jing Daily",
         "Journal du Luxe", "The Good Goods", "The Bold Way"]
KEYWORDS = {
  "Earnings & P&L" => /\b(sales|revenue|profit|earnings|results|quarter|margin|guidance|chiffre d'affaires|résultats|bénéfice|ventes|trimestre|marge)\b/i,
  "Collaborations" => /\b(collab\w*|partnership|capsule|teams up|partenariat)\b/i,
  "Store openings & retail" => /\b(opens?|opening|flagship|stores?|boutiques?|pop-up|ouvre|ouverture|magasins?|points? de vente)\b/i,
  "M&A & investment" => /\b(acqui\w+|merger|stake|takeover|buys?|investment|IPO|rachat|rachète|cession|fusion|levée)\b/i,
  "Appointments" => /\b(appoint\w*|names?|CEO|chief executive|creative director|steps down|nomm\w+|directeur|directrice)\b/i,
  "China & Asia" => /\b(China|Chinese|Shanghai|Hong Kong|Asia|Japan|Korea|Chine|Asie|Japon|Corée)\b/i,
  "Macro & geopolitics" => /\b(tariffs?|trade war|inflation|consumer confidence|recession|currency|droits de douane)\b/i,
}
FASHION = /(fashion|luxury|apparel|retail|brand|LVMH|Kering|Hermès|Chanel|Prada|Gucci|Inditex|Zara|H&M|Nike|Adidas|Richemont|Tapestry|mode|luxe|prêt-à-porter|habillement|textile|maroquinerie|sneaker|beauty|beauté|department store)/i

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
    items << { "source" => name, "title" => title, "link" => link,
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

def collect(days)
  puts "Fetching #{SOURCES.size} feeds..."
  raw = SOURCES.map { |n, u| Thread.new { fetch(n, u) } }.flat_map(&:value)
  cutoff = Time.now.utc - days * 86_400
  seen = {}
  arts = raw.sort_by { |a| a["date"] }.reverse.select do |a|
    a["id"] = article_id(a)
    ok = !seen[a["id"]] && Time.parse(a["date"]) >= cutoff
    seen[a["id"]] = true
    ok
  end
  puts "  #{raw.size} articles fetched, #{arts.size} unique over #{days} days."
  File.write(ARTS, JSON.generate(arts))
  arts
end

# ─── AI triage ───
PROMPT = <<~P
  You are the press-monitoring assistant of a fashion / luxury / retail executive (VP / CEO) with a merchandising mindset.
  For each article (headline + optional summary, in English or French), decide whether it belongs in their business news brief.

  KEEP: earnings / P&L / sales figures of fashion, luxury, sportswear or retail brands and groups; collaborations;
  store openings/closures, flagships, new markets; M&A, fundraising, disposals; executive and creative-director
  appointments; product / pricing / assortment / distribution strategy; China & Asia; macro, tariffs, geopolitics
  or consumer trends THAT AFFECT fashion brands' margins.
  REJECT: celebrities, red carpets, runway trends with no business angle, shopping tips, pure beauty with no business
  angle, general news unrelated to fashion/retail.
  DUPLICATES: if several articles (even in different languages) cover the same story, keep ONE (the most complete)
  and set keep=false for the others.

  Categories: %CATS%

  Reply ONLY with JSON: a list of objects {"id": ..., "keep": true/false, "cat": "<category>",
  "score": 1-5 (importance for a CEO), "title_en": "<headline in natural English; translate if it is in French>",
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
  Net::HTTP.start(uri.host, 443, use_ssl: true, open_timeout: 15, read_timeout: 180) do |h|
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
  # newest first; stable before preview; full "flash" before "flash-lite"
  names.sort_by { |n| [-version.call(n), n.include?("preview") ? 1 : 0, n.include?("lite") ? 1 : 0, n.size] }
end

def ask_ai(batch, models, key)
  prompt = PROMPT.sub("%CATS%", CATEGORIES.join(", ")) + batch.map { |a| "- " + line(a) }.join("\n")
  body = { contents: [{ role: "user", parts: [{ text: prompt }] }],
           generationConfig: { temperature: 0, responseMimeType: "application/json" } }
  attempt = 0
  while (model = models.first) && attempt < 4
    attempt += 1
    begin
      res = gemini_request("/models/#{model}:generateContent", key, body)
      if %w[400 404].include?(res.code) && models.size > 1
        warn "  ! model #{model} unavailable (HTTP #{res.code}), trying #{models[1]}"
        models.shift
        next
      end
      raise "HTTP #{res.code} #{res.body[0, 200]}" unless res.code == "200"
      parts = JSON.parse(res.body).dig("candidates", 0, "content", "parts").to_a
      text = parts.map { |p| p["text"].to_s }.join
      return JSON.parse(text[text.index("[")..text.rindex("]")])
    rescue StandardError => e
      warn "  ! AI (attempt #{attempt}): #{e.message[0, 160]}"
      sleep(e.message.include?("HTTP 429") ? 60 : 5 * attempt)
    end
  end
  nil
end

def keyword_classify(a)
  text = "#{a['title']} #{a['summary']}"
  cats = KEYWORDS.select { |_, rx| text =~ rx }.keys
  return { "keep" => false } if cats.empty? || !(TRADE.include?(a["source"]) || text =~ FASHION)
  { "keep" => true, "cat" => cats.first, "score" => [5, 2 + cats.size].min, "angle" => "" }
end

def load_cache
  File.exist?(CACHE) ? JSON.parse(File.read(CACHE)) : {}
end

def classify(arts, cache)
  todo = arts.reject { |a| cache.key?(a["id"]) }
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
  puts "AI triage of #{todo.size} new articles (Gemini #{models.first}, free tier)..."
  failures = 0
  todo.each_slice(25).each_with_index do |b, i|
    sleep 6 if i > 0 # free tier: stay well under the requests-per-minute limit
    res = ask_ai(b, models, key)
    if res.nil?
      failures += 1
      break if failures >= 2 # AI down or daily quota reached: stop, keywords take over
      next
    end
    res.each { |r| cache[r["id"].to_s] = r.merge("by" => "ai") if r.is_a?(Hash) && r["id"] }
  end
  live = arts.map { |a| a["id"] }
  File.write(CACHE, JSON.generate(cache.select { |k, _| live.include?(k) })) # keep the cache small
end

# ─── HTML page ───
def build(days)
  arts = File.exist?(ARTS) ? JSON.parse(File.read(ARTS)) : []
  cache = load_cache
  kept = arts.map do |a|
    c = cache[a["id"]] || keyword_classify(a)
    next unless c["keep"]
    title = c["title_en"].to_s.strip.empty? ? a["title"] : c["title_en"]
    a.merge("title" => title, "original" => (title == a["title"] ? "" : a["title"]),
            "cat" => (CATEGORIES.include?(c["cat"]) ? c["cat"] : "Strategy & product"),
            "score" => (c["score"] || 2).to_i.clamp(1, 5), "angle" => c["angle"].to_s)
  end.compact
  html = DATA.read.sub("__DATA__") { JSON.generate(kept).gsub("</", "<\\/") }
             .sub("__GEN__", Time.now.utc.iso8601).sub("__DAYS__", days.to_s)
             .sub("__CATS__") { JSON.generate(CATEGORIES) }
  FileUtils.mkdir_p(File.dirname(OUT))
  File.write(OUT, html)
  puts "Done: #{kept.size} fashion business articles kept out of #{arts.size} -> #{OUT}"
end

days = (ARGV.index("--days") ? ARGV[ARGV.index("--days") + 1].to_i : 3)
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
<select id="imp"><option value="1">All</option><option value="3">Important (★3+)</option><option value="4">Must-read (★4+)</option></select></div>
<div id="list"></div></main></div>
<script>
const A=__DATA__, CATS=__CATS__, GEN=new Date("__GEN__"); let fc=null, fs=null;
document.getElementById('gen').textContent='Updated '+GEN.toLocaleString('en-GB',{day:'numeric',month:'short',hour:'2-digit',minute:'2-digit'})+' · last __DAYS__ days';
let read={}; try{read=JSON.parse(localStorage.getItem('brief_read')||'{}')}catch(e){}
const $=s=>document.querySelector(s), esc=s=>s.replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
function btns(el,vals,cur,set){const n=v=>A.filter(a=>v===null||(el==='cats'?a.cat:a.source)===v).length;
 $('#'+el).innerHTML=[null,...vals].map(v=>`<button class="f ${v===cur?'on':''}" data-v="${v??''}">${v??'All'}<span>${n(v)}</span></button>`).join('');
 $('#'+el).querySelectorAll('button').forEach(b=>b.onclick=()=>{set(b.dataset.v||null);draw()});}
function draw(){
 btns('cats',CATS.filter(c=>A.some(a=>a.cat===c)),fc,v=>fc=v);
 btns('srcs',[...new Set(A.map(a=>a.source))].sort(),fs,v=>fs=v);
 const q=$('#q').value.toLowerCase(), min=+$('#imp').value;
 let L=A.filter(a=>(!fc||a.cat===fc)&&(!fs||a.source===fs)&&a.score>=min&&(!q||(a.title+a.original+a.angle+a.source).toLowerCase().includes(q)));
 if($('#sort').value==='score')L.sort((x,y)=>y.score-x.score||y.date.localeCompare(x.date));
 let h='',last='';
 for(const a of L){const d=new Date(a.date), day=d.toLocaleDateString('en-GB',{weekday:'long',day:'numeric',month:'long'});
  if($('#sort').value==='date'&&day!==last){h+=`<div class="day">${day}</div>`;last=day}
  h+=`<a class="it ${read[a.id]?'read':''}" href="${esc(a.link)}" target="_blank" rel="noopener" data-id="${a.id}"${a.original?` title="Original: ${esc(a.original)}"`:''}>
  <div class="meta"><span class="src">${esc(a.source)}</span><span>${d.toLocaleTimeString('en-GB',{hour:'2-digit',minute:'2-digit'})}</span>
  <span class="tag">${esc(a.cat)}</span><span class="dots">${'★'.repeat(a.score)}</span></div>
  <div class="t">${esc(a.title)}</div>${a.angle?`<div class="a">→ ${esc(a.angle)}</div>`:''}</a>`}
 $('#list').innerHTML=h||'<div class="empty">No articles match these filters.</div>';
 document.querySelectorAll('.it').forEach(e=>e.onclick=()=>{read[e.dataset.id]=1;e.classList.add('read');
  try{localStorage.setItem('brief_read',JSON.stringify(read))}catch(_){}});
}
['q','sort','imp'].forEach(i=>$('#'+i).oninput=draw);draw();
</script></body></html>
