#!/usr/bin/env ruby
# Regenerates Applications/TextMate/about/Contributions.html from the git
# history of the current checkout. Run from the repository root:
#
#     bin/gen_credits.rb
#
# Commit and browse links point at REPO_URL. Author names become links to a
# GitHub profile only when the address is a @users.noreply.github.com one
# (which encodes the login) or is listed in EMAIL_TO_LOGIN — the email-search
# API the previous version of this script queried no longer exists.

require 'cgi'
require 'date'
require 'digest/md5'

REPO_URL = 'https://github.com/robios/textmate'
BRANCH   = 'textmate-2.5'
OUTPUT   = File.expand_path('../Applications/TextMate/about/Contributions.html', __dir__)

# md5(author email) => github login, seeded from the retired lookup cache
EMAIL_TO_LOGIN = {
  '1178ce2f664a6cee9a05a3e11af5d8d2' => 'aaronbrethorst',
  '3b0ef5e2a5f1aa3ccf3f23a20adf8873' => 'Hoverbear',
  'ff3502050b3b1b00cb6c810d5c41ffc9' => 'bradchoate',
  'ee646002e51a3c83e01db85ae42187ff' => 'dmcdougall',
  '85af9ad71af2dc0166b7c0c5780fa086' => 'caldwell',
  'fa64968e4a3c8e20364bb92ba7511ff9' => 'dvennink',
  '0669ff1e3ada91e7f1e7714f6f9a67f6' => 'etienne',
  '49ed289f3de94dbcd7c10392bcc40b53' => 'fernando82',
  '7b3ae2214891a47b26b4db98949c1bb0' => 'gknops',
  '34820bca697fbf1598774b393c5ca4fe' => 'whitlockjc',
  'ec9254734cd341f1b104d558dc4fc36a' => 'joachimm',
  '09c16a631eeba332147a8d620e1369cc' => 'muellerj',
  '6890db3146e20bfb99be3bc7bc3bfeec' => 'lczekaj',
  'e34425c11547a48a4701c9d1720dadf8' => 'infininight',
  '65efe3355478c8db96bc82f22fd3aa20' => 'nathanieltagg',
  '4e89e196a1f8fa34a6bdc6d165f75e5e' => 'Ralle',
  'ccc5b318408880a67eeebf0d18177fb5' => 'rhencke',
  '4cf620221f7e622260f8424b8142451f' => 'ryanmaxwell',
  '5780111eb4b5565816d9388b091e1057' => 'youngrok',
  '1bafa0ecf5643c71e6d5dea309889d21' => 'bobrocke',
  '16e62cebf0c65d7018b263d0f8be36c1' => 'sclukey',
  'bee584c4bc4deac1ee91006b97a8fc53' => 'mstarke',
  '578b7853042db14893ee5ec2ce043f98' => 'yyyc514',
  '8838005371ab9c0b1d40f0504bf8832a' => 'garysweaver',
  '1b97e22672bc2577ebbb63ef895debd4' => 'jtmkrueger',
  '3413d8cb793e54a6e062391875fd2636' => 'jacob-carlborg',
  'a8cb0cb6a2406ee9d85ea72f7c040697' => 'jsuder',
  'af76f04ca3004be2d6b0690bd0a6ff7c' => 'luikore',
  'bbe6320b030b1bb50349e4554d3169d6' => 'AJ-Acevedo',
  'a734c5fda1ef1237fa6a26a64940d0b1' => 'Dirklectisch',
  '7640cae93abde468b73f35d6620a9b04' => 'caleb',
  'f889181fc58ccb702822b54fe3702d24' => 'codykrieger',
  '571db4b87bd7d2fec3dcd5524cb7d9ae' => 'rdwampler',
  'a4c0d688809489ab98a162b10c57381c' => 'dusek',
  '7e9f543f0ffdb7c9a899e628fe76e7f3' => 'jtbandes',
  '04581c59babdab9788e932ecb79f9617' => 'zadr',
  '0ee1291a38e3c76fdfaadb2a0fa3428a' => 'duanemoody',
  '71c216d75354dda636b879dfc95654fb' => 'charliepark',
  'c8591aebaf7659f1ff429898345f446a' => 'olegam',
  'f275727e33d63e05cc0abab1bfc41da7' => 'sudara',
  # fork-era authors
  'e904dfc2f19fa297256c24c2a620c629' => 'tectiv3',
  'd6f3935af9c42698b6e33e8f3ae2bc41' => 'tectiv3',
  'd7e4957767431c67d811a9286c9d01d7' => 'robios',
}.freeze

def login_for(email)
  return $1 if email =~ /^(?:\d+\+)?([A-Za-z0-9-]+)@users\.noreply\.github\.com$/
  EMAIL_TO_LOGIN[Digest::MD5.hexdigest(email)]
end

def commit_entry(sha, name, email, date, subject, body)
  emailhash = Digest::MD5.hexdigest(email)
  userpic = "https://www.gravatar.com/avatar/#{emailhash}?s=48&amp;d=https://a248.e.akamai.net/assets.github.com%2Fimages%2Fgravatars%2Fgravatar-user-420.png"
  login = login_for(email)
  author = login ? "<a href=\"https://github.com/#{login}\">#{CGI.escapeHTML(name)}</a>" : CGI.escapeHTML(name)

  expander = ''
  desc = ''
  unless body.empty?
    expander = "\n      <span class=\"hidden-text-expander inline\"><a href=\"javascript:;\" class=\"js-details-target\">…</a></span>"
    desc = "\n    <div class=\"commit-desc\"><pre>#{CGI.escapeHTML(body)}\n</pre></div>"
  end

  <<~HTML
    <li class="commit commit-group-item">
        <img class="gravatar" src="#{userpic}" height="36" width="36">
        <p class="commit-title">
          <a href="#{REPO_URL}/commit/#{sha}" class="message">#{CGI.escapeHTML(subject)}</a>#{expander}
        </p>#{desc}
        <div class="commit-meta">
          <div class="commit-links">
            <a href="#{REPO_URL}/commit/#{sha}" class="gobutton">
              <span class="sha">#{sha[0, 10]}<span class="mini-icon mini-icon-arr-right-mini"></span></span>
            </a>
            <a href="#{REPO_URL}/tree/#{sha}" class="browse-button" title="Browse the code at this point in the history" rel="nofollow">Browse code <span class="mini-icon mini-icon-arr-right"></span></a>
          </div>
          <div class="authorship">
            <span class="author-name">#{author}</span>
            authored <time class="js-relative-date" datetime="#{date.strftime('%FT%T%:z')}" title="#{date.strftime('%F %T')}">#{date.strftime('%B %-d, %Y')}</time>
          </div>
        </div>
    </li>
  HTML
end

entries = 0
groups = []                     # [heading, [entry, …]] in log order
log = `git log -z --date=iso --pretty=format:"%H%n%an%n%ae%n%ad%n%s%n%b"`
log.force_encoding(Encoding::UTF_8).scrub.split(/\x00/).each do |commit|
  sha, name, email, datestr, subject, body = commit.split(/\n/, 6)
  next if name == 'Allan Odgaard'
  next if email.nil? || email.empty?

  date = DateTime.parse(datestr)
  body = (body || '').strip
  heading = date.strftime('%b %-d, %Y')
  groups << [heading, []] unless groups.last && groups.last[0] == heading
  groups.last[1] << commit_entry(sha, name, email, date, subject, body)
  entries += 1
end

html = +<<~HEADER
  <!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01//EN"
  \t"http://www.w3.org/TR/html4/strict.dtd">

  <html>

  <head>
  \t<meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
  \t<link href="css/stylesheet.css" rel="stylesheet" type="text/css" />
  \t<link rel="stylesheet" type="text/css" href="css/contributions.css" charset="utf-8" />
  \t<script type="text/javascript" src="js/contributions.js" charset="utf-8"></script>
  \t<title>Contributions</title>
  </head>

  <body>
  <h1 id="contributions">Contributions</h1>

  <p>See <a href="#{REPO_URL}/commits/#{BRANCH}">commits at GitHub</a>.</p>

  <div>

HEADER

groups.each do |heading, items|
  html << "\n<h3 class=\"commit-group-heading\">#{heading}</h3>\n\n"
  html << "<ol class=\"commit-group\">\n\n"
  html << items.join("\n")
  html << "\n</ol>\n"
end

html << "\n</div>\n\n</body>\n</html>\n"

File.write(OUTPUT, html)
puts "#{OUTPUT}: #{entries} commits, #{groups.size} day groups"
