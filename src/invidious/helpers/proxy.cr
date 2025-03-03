# See https://github.com/crystal-lang/crystal/issues/2963
class HTTPProxy
  getter proxy_host : String
  getter proxy_port : Int32
  getter options : Hash(Symbol, String)
  getter tls : OpenSSL::SSL::Context::Client?

  def initialize(@proxy_host, @proxy_port = 80, @options = {} of Symbol => String)
  end

  def open(host, port, tls = nil, connection_options = {} of Symbol => Float64 | Nil)
    dns_timeout = connection_options.fetch(:dns_timeout, nil)
    connect_timeout = connection_options.fetch(:connect_timeout, nil)
    read_timeout = connection_options.fetch(:read_timeout, nil)

    socket = TCPSocket.new @proxy_host, @proxy_port, dns_timeout, connect_timeout
    socket.read_timeout = read_timeout if read_timeout
    socket.sync = true

    socket << "CONNECT #{host}:#{port} HTTP/1.1\r\n"

    if options[:user]?
      credentials = Base64.strict_encode("#{options[:user]}:#{options[:password]}")
      credentials = "#{credentials}\n".gsub(/\s/, "")
      socket << "Proxy-Authorization: Basic #{credentials}\r\n"
    end

    socket << "\r\n"

    resp = parse_response(socket)

    if resp[:code]? == 200
      {% if !flag?(:without_openssl) %}
        if tls
          tls_socket = OpenSSL::SSL::Socket::Client.new(socket, context: tls, sync_close: true, hostname: host)
          socket = tls_socket
        end
      {% end %}

      return socket
    else
      socket.close
      raise IO::Error.new(resp.inspect)
    end
  end

  private def parse_response(socket)
    resp = {} of Symbol => Int32 | String | Hash(String, String)

    begin
      version, code, reason = socket.gets.as(String).chomp.split(/ /, 3)

      headers = {} of String => String

      while (line = socket.gets.as(String)) && (line.chomp != "")
        name, value = line.split(/:/, 2)
        headers[name.strip] = value.strip
      end

      resp[:version] = version
      resp[:code] = code.to_i
      resp[:reason] = reason
      resp[:headers] = headers
    rescue
    end

    return resp
  end
end

class HTTPClient < HTTP::Client
  def set_proxy(proxy : HTTPProxy)
    begin
      @socket = proxy.open(host: @host, port: @port, tls: @tls, connection_options: proxy_connection_options)
    rescue IO::Error
      @socket = nil
    end
  end

  def unset_proxy
    @socket = nil
  end

  def proxy_connection_options
    opts = {} of Symbol => Float64 | Nil

    opts[:dns_timeout] = @dns_timeout
    opts[:connect_timeout] = @connect_timeout
    opts[:read_timeout] = @read_timeout

    return opts
  end

  def exec(request)
    if self.host == "www.youtube.com"
      request.headers["x-youtube-client-name"] ||= "1"
      request.headers["x-youtube-client-version"] ||= "1.20180719"
      request.headers["user-agent"] ||= random_user_agent
      request.headers["accept-charset"] ||= "ISO-8859-1,utf-8;q=0.7,*;q=0.7"
      request.headers["accept"] ||= "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
      request.headers["accept-language"] ||= "en-us,en;q=0.5"
      request.headers["cookie"] = "#{(CONFIG.cookies.map { |c| "#{c.name}=#{c.value}" }).join("; ")}; #{request.headers["cookie"]?}"
    end

    super
  end
end

def get_proxies(country_code = "US")
  # return get_spys_proxies(country_code)
  return get_nova_proxies(country_code)
end

def filter_proxies(proxies)
  proxies.select! do |proxy|
    begin
      client = HTTPClient.new(YT_URL)
      client.read_timeout = 10.seconds
      client.connect_timeout = 10.seconds

      proxy = HTTPProxy.new(proxy_host: proxy[:ip], proxy_port: proxy[:port])
      client.set_proxy(proxy)

      client.head("/").status_code == 200
    rescue ex
      false
    end
  end

  return proxies
end

def get_nova_proxies(country_code = "US")
  country_code = country_code.downcase
  client = HTTP::Client.new(URI.parse("https://www.proxynova.com"))
  client.read_timeout = 10.seconds
  client.connect_timeout = 10.seconds

  headers = HTTP::Headers.new
  headers["User-Agent"] = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/68.0.3440.106 Safari/537.36"
  headers["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8"
  headers["Accept-Language"] = "Accept-Language: en-US,en;q=0.9"
  headers["Host"] = "www.proxynova.com"
  headers["Origin"] = "https://www.proxynova.com"
  headers["Referer"] = "https://www.proxynova.com/proxy-server-list/country-#{country_code}/"

  response = client.get("/proxy-server-list/country-#{country_code}/", headers)
  document = XML.parse_html(response.body)

  proxies = [] of {ip: String, port: Int32, score: Float64}
  document.xpath_nodes(%q(//tr[@data-proxy-id])).each do |node|
    ip = node.xpath_node(%q(.//td/abbr/script)).not_nil!.content
    ip = ip.match(/document\.write\('(?<sub1>[^']+)'.substr\(8\) \+ '(?<sub2>[^']+)'/).not_nil!
    ip = "#{ip["sub1"][8..-1]}#{ip["sub2"]}"
    port = node.xpath_node(%q(.//td[2])).not_nil!.content.strip.to_i

    anchor = node.xpath_node(%q(.//td[4]/div)).not_nil!
    speed = anchor["data-value"].to_f
    latency = anchor["title"].to_f
    uptime = node.xpath_node(%q(.//td[5]/span)).not_nil!.content.rchop("%").to_f

    # TODO: Tweak me
    score = (uptime*4 + speed*2 + latency)/7
    proxies << {ip: ip, port: port, score: score}
  end

  # proxies = proxies.sort_by { |proxy| proxy[:score] }.reverse
  return proxies
end

def get_spys_proxies(country_code = "US")
  client = HTTP::Client.new(URI.parse("http://spys.one"))
  client.read_timeout = 10.seconds
  client.connect_timeout = 10.seconds

  headers = HTTP::Headers.new
  headers["User-Agent"] = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/68.0.3440.106 Safari/537.36"
  headers["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8"
  headers["Accept-Language"] = "Accept-Language: en-US,en;q=0.9"
  headers["Host"] = "spys.one"
  headers["Origin"] = "http://spys.one"
  headers["Referer"] = "http://spys.one/free-proxy-list/#{country_code}/"
  headers["Content-Type"] = "application/x-www-form-urlencoded"
  body = {
    "xpp" => "5",
    "xf1" => "0",
    "xf2" => "0",
    "xf4" => "0",
    "xf5" => "1",
  }

  response = client.post("/free-proxy-list/#{country_code}/", headers, form: body)
  20.times do
    if response.status_code == 200
      break
    end
    response = client.post("/free-proxy-list/#{country_code}/", headers, form: body)
  end

  response = XML.parse_html(response.body)

  mapping = response.xpath_node(%q(.//body/script)).not_nil!.content
  mapping = mapping.match(/\}\('(?<p>[^']+)',\d+,\d+,'(?<x>[^']+)'/).not_nil!
  p = mapping["p"].not_nil!
  x = mapping["x"].not_nil!
  mapping = decrypt_port(p, x)

  proxies = [] of {ip: String, port: Int32, score: Float64}
  response = response.xpath_node(%q(//tr/td/table)).not_nil!
  response.xpath_nodes(%q(.//tr)).each do |node|
    if !node["onmouseover"]?
      next
    end

    ip = node.xpath_node(%q(.//td[1]/font[2])).to_s.match(/<font class="spy14">(?<address>[^<]+)</).not_nil!["address"]
    encrypted_port = node.xpath_node(%q(.//td[1]/font[2]/script)).not_nil!.content
    encrypted_port = encrypted_port.match(/<\\\/font>"\+(?<encrypted_port>[\d\D]+)\)$/).not_nil!["encrypted_port"]

    port = ""
    encrypted_port.split("+").each do |number|
      number = number.delete("()")
      left_side, right_side = number.split("^")
      result = mapping[left_side] ^ mapping[right_side]
      port = "#{port}#{result}"
    end
    port = port.to_i

    latency = node.xpath_node(%q(.//td[6])).not_nil!.content.to_f
    speed = node.xpath_node(%q(.//td[7]/font/table)).not_nil!["width"].to_f
    uptime = node.xpath_node(%q(.//td[8]/font/acronym)).not_nil!

    # Skip proxies that are down
    if uptime["title"].ends_with? "?"
      next
    end

    if md = uptime.content.match(/^\d+/)
      uptime = md[0].to_f
    else
      next
    end

    score = (uptime*4 + speed*2 + latency)/7

    proxies << {ip: ip, port: port, score: score}
  end

  proxies = proxies.sort_by { |proxy| proxy[:score] }.reverse
  return proxies
end

def decrypt_port(p, x)
  x = x.split("^")
  s = {} of String => String

  60.times do |i|
    if x[i]?.try &.empty?
      s[y_func(i)] = y_func(i)
    else
      s[y_func(i)] = x[i]
    end
  end

  x = s
  p = p.gsub(/\b\w+\b/, x)

  p = p.split(";")
  p = p.map { |item| item.split("=") }

  mapping = {} of String => Int32
  p.each do |item|
    if item == [""]
      next
    end

    key = item[0]
    value = item[1]
    value = value.split("^")

    if value.size == 1
      value = value[0].to_i
    else
      left_side = value[0].to_i?
      left_side ||= mapping[value[0]]
      right_side = value[1].to_i?
      right_side ||= mapping[value[1]]

      value = left_side ^ right_side
    end

    mapping[key] = value
  end

  return mapping
end

def y_func(c)
  return (c < 60 ? "" : y_func((c/60).to_i)) + ((c = c % 60) > 35 ? ((c.to_u8 + 29).unsafe_chr) : c.to_s(36))
end

PROXY_LIST = {
  "GB" => [{ip: "147.135.206.233", port: 3128}, {ip: "167.114.180.102", port: 8080}, {ip: "176.35.250.108", port: 8080}, {ip: "5.148.128.44", port: 80}, {ip: "62.7.85.234", port: 8080}, {ip: "88.150.135.10", port: 36624}],
  "DE" => [{ip: "138.201.223.250", port: 31288}, {ip: "138.68.73.59", port: 32574}, {ip: "159.69.211.173", port: 3128}, {ip: "173.249.43.105", port: 3128}, {ip: "212.202.244.90", port: 8080}, {ip: "5.56.18.35", port: 38827}],
  "FR" => [{ip: "137.74.254.242", port: 3128}, {ip: "151.80.143.155", port: 53281}, {ip: "178.33.150.97", port: 3128}, {ip: "37.187.2.31", port: 3128}, {ip: "5.135.164.72", port: 3128}, {ip: "5.39.91.73", port: 3128}, {ip: "51.38.162.2", port: 32231}, {ip: "51.38.217.121", port: 808}, {ip: "51.75.109.81", port: 3128}, {ip: "51.75.109.82", port: 3128}, {ip: "51.75.109.83", port: 3128}, {ip: "51.75.109.84", port: 3128}, {ip: "51.75.109.86", port: 3128}, {ip: "51.75.109.88", port: 3128}, {ip: "51.75.109.90", port: 3128}, {ip: "62.210.167.3", port: 3128}, {ip: "90.63.218.232", port: 8080}, {ip: "91.134.165.198", port: 9999}],
  "IN" => [{ip: "1.186.151.206", port: 36253}, {ip: "1.186.63.130", port: 39142}, {ip: "103.105.40.1", port: 16538}, {ip: "103.105.40.153", port: 16538}, {ip: "103.106.148.203", port: 60227}, {ip: "103.106.148.207", port: 51451}, {ip: "103.12.246.12", port: 8080}, {ip: "103.14.235.109", port: 8080}, {ip: "103.14.235.26", port: 8080}, {ip: "103.198.172.4", port: 50820}, {ip: "103.205.112.1", port: 23500}, {ip: "103.209.64.19", port: 6666}, {ip: "103.211.76.5", port: 8080}, {ip: "103.216.82.19", port: 6666}, {ip: "103.216.82.190", port: 6666}, {ip: "103.216.82.209", port: 54806}, {ip: "103.216.82.214", port: 6666}, {ip: "103.216.82.37", port: 6666}, {ip: "103.216.82.44", port: 8080}, {ip: "103.216.82.50", port: 53281}, {ip: "103.22.173.230", port: 8080}, {ip: "103.224.38.2", port: 83}, {ip: "103.226.142.90", port: 41386}, {ip: "103.236.114.38", port: 49638}, {ip: "103.240.161.107", port: 6666}, {ip: "103.240.161.108", port: 6666}, {ip: "103.240.161.109", port: 6666}, {ip: "103.240.161.59", port: 48809}, {ip: "103.245.198.101", port: 8080}, {ip: "103.250.148.82", port: 6666}, {ip: "103.251.58.51", port: 61489}, {ip: "103.253.169.115", port: 32731}, {ip: "103.253.211.182", port: 8080}, {ip: "103.253.211.182", port: 80}, {ip: "103.255.234.169", port: 39847}, {ip: "103.42.161.118", port: 8080}, {ip: "103.42.162.30", port: 8080}, {ip: "103.42.162.50", port: 8080}, {ip: "103.42.162.58", port: 8080}, {ip: "103.46.233.12", port: 83}, {ip: "103.46.233.13", port: 83}, {ip: "103.46.233.16", port: 83}, {ip: "103.46.233.17", port: 83}, {ip: "103.46.233.21", port: 83}, {ip: "103.46.233.23", port: 83}, {ip: "103.46.233.29", port: 81}, {ip: "103.46.233.29", port: 83}, {ip: "103.46.233.50", port: 83}, {ip: "103.47.153.87", port: 8080}, {ip: "103.47.66.2", port: 39804}, {ip: "103.49.53.1", port: 81}, {ip: "103.52.220.1", port: 49068}, {ip: "103.56.228.166", port: 53281}, {ip: "103.56.30.128", port: 8080}, {ip: "103.65.193.17", port: 50862}, {ip: "103.65.195.1", port: 33960}, {ip: "103.69.220.14", port: 3128}, {ip: "103.70.128.84", port: 8080}, {ip: "103.70.128.86", port: 8080}, {ip: "103.70.131.74", port: 8080}, {ip: "103.70.146.250", port: 59563}, {ip: "103.72.216.194", port: 38345}, {ip: "103.75.161.38", port: 21776}, {ip: "103.76.253.155", port: 3128}, {ip: "103.87.104.137", port: 8080}, {ip: "110.235.198.3", port: 57660}, {ip: "114.69.229.161", port: 8080}, {ip: "117.196.231.201", port: 37769}, {ip: "117.211.166.214", port: 3128}, {ip: "117.240.175.51", port: 3128}, {ip: "117.240.210.155", port: 53281}, {ip: "117.240.59.115", port: 36127}, {ip: "117.242.154.73", port: 33889}, {ip: "117.244.15.243", port: 3128}, {ip: "119.235.54.3", port: 8080}, {ip: "120.138.117.102", port: 59308}, {ip: "123.108.200.185", port: 83}, {ip: "123.108.200.217", port: 82}, {ip: "123.176.43.218", port: 40524}, {ip: "125.21.43.82", port: 8080}, {ip: "125.62.192.225", port: 82}, {ip: "125.62.192.33", port: 84}, {ip: "125.62.194.1", port: 83}, {ip: "125.62.213.134", port: 82}, {ip: "125.62.213.18", port: 83}, {ip: "125.62.213.201", port: 84}, {ip: "125.62.213.242", port: 83}, {ip: "125.62.214.185", port: 84}, {ip: "139.5.26.27", port: 53281}, {ip: "14.102.67.101", port: 30337}, {ip: "14.142.122.134", port: 8080}, {ip: "150.129.114.194", port: 6666}, {ip: "150.129.151.62", port: 6666}, {ip: "150.129.171.115", port: 6666}, {ip: "150.129.201.30", port: 6666}, {ip: "157.119.207.38", port: 53281}, {ip: "175.100.185.151", port: 53281}, {ip: "182.18.177.114", port: 56173}, {ip: "182.73.194.170", port: 8080}, {ip: "182.74.85.230", port: 51214}, {ip: "183.82.116.56", port: 8080}, {ip: "183.82.32.56", port: 49551}, {ip: "183.87.14.229", port: 53281}, {ip: "183.87.14.250", port: 44915}, {ip: "202.134.160.168", port: 8080}, {ip: "202.134.166.1", port: 8080}, {ip: "202.134.180.50", port: 8080}, {ip: "202.62.84.210", port: 53281}, {ip: "203.192.193.225", port: 8080}, {ip: "203.192.195.14", port: 31062}, {ip: "203.192.217.11", port: 8080}, {ip: "223.196.83.182", port: 53281}, {ip: "27.116.20.169", port: 36630}, {ip: "27.116.20.209", port: 36630}, {ip: "27.116.51.21", port: 36033}, {ip: "43.224.8.114", port: 50333}, {ip: "43.224.8.116", port: 6666}, {ip: "43.224.8.124", port: 6666}, {ip: "43.224.8.86", port: 6666}, {ip: "43.225.20.73", port: 8080}, {ip: "43.225.23.26", port: 8080}, {ip: "43.230.196.98", port: 36569}, {ip: "43.240.5.225", port: 31777}, {ip: "43.241.28.248", port: 8080}, {ip: "43.242.209.201", port: 8080}, {ip: "43.246.139.82", port: 8080}, {ip: "43.248.73.86", port: 53281}, {ip: "43.251.170.145", port: 54059}, {ip: "45.112.57.230", port: 61222}, {ip: "45.115.171.30", port: 47949}, {ip: "45.121.29.254", port: 54858}, {ip: "45.123.26.146", port: 53281}, {ip: "45.125.61.193", port: 32804}, {ip: "45.125.61.209", port: 32804}, {ip: "45.127.121.194", port: 53281}, {ip: "45.250.226.14", port: 3128}, {ip: "45.250.226.38", port: 8080}, {ip: "45.250.226.47", port: 8080}, {ip: "45.250.226.55", port: 8080}, {ip: "49.249.251.86", port: 53281}],
  "CN" => [{ip: "182.61.170.45", port: 3128}],
  "RU" => [{ip: "109.106.139.225", port: 45689}, {ip: "109.161.48.228", port: 53281}, {ip: "109.167.224.198", port: 51919}, {ip: "109.172.57.250", port: 23500}, {ip: "109.194.2.126", port: 61822}, {ip: "109.195.150.128", port: 37564}, {ip: "109.201.96.171", port: 31773}, {ip: "109.201.97.204", port: 41258}, {ip: "109.201.97.235", port: 39125}, {ip: "109.206.140.74", port: 45991}, {ip: "109.206.148.31", port: 30797}, {ip: "109.69.75.5", port: 46347}, {ip: "109.71.181.170", port: 53983}, {ip: "109.74.132.190", port: 42663}, {ip: "109.74.143.45", port: 36529}, {ip: "109.75.140.158", port: 59916}, {ip: "109.95.84.114", port: 52125}, {ip: "130.255.12.24", port: 31004}, {ip: "134.19.147.72", port: 44812}, {ip: "134.90.181.7", port: 54353}, {ip: "145.255.6.171", port: 31252}, {ip: "146.120.227.3", port: 8080}, {ip: "149.255.112.194", port: 48968}, {ip: "158.46.127.222", port: 52574}, {ip: "158.46.43.144", port: 39120}, {ip: "158.58.130.185", port: 50016}, {ip: "158.58.132.12", port: 56962}, {ip: "158.58.133.106", port: 41258}, {ip: "158.58.133.13", port: 21213}, {ip: "176.101.0.47", port: 34471}, {ip: "176.101.89.226", port: 33470}, {ip: "176.106.12.65", port: 30120}, {ip: "176.107.80.110", port: 58901}, {ip: "176.110.121.9", port: 46322}, {ip: "176.110.121.90", port: 21776}, {ip: "176.111.97.18", port: 8080}, {ip: "176.112.106.230", port: 33996}, {ip: "176.112.110.40", port: 61142}, {ip: "176.113.116.70", port: 55589}, {ip: "176.113.27.192", port: 47337}, {ip: "176.115.197.118", port: 8080}, {ip: "176.117.255.182", port: 53100}, {ip: "176.120.200.69", port: 44331}, {ip: "176.124.123.93", port: 41258}, {ip: "176.192.124.98", port: 60787}, {ip: "176.192.5.238", port: 61227}, {ip: "176.192.8.206", port: 39422}, {ip: "176.193.15.94", port: 8080}, {ip: "176.196.195.170", port: 48129}, {ip: "176.196.198.154", port: 35252}, {ip: "176.196.238.234", port: 44648}, {ip: "176.196.239.46", port: 35656}, {ip: "176.196.246.6", port: 53281}, {ip: "176.196.84.138", port: 51336}, {ip: "176.197.145.246", port: 32649}, {ip: "176.197.99.142", port: 47278}, {ip: "176.215.1.108", port: 60339}, {ip: "176.215.170.147", port: 35604}, {ip: "176.56.23.14", port: 35340}, {ip: "176.62.185.54", port: 53883}, {ip: "176.74.13.110", port: 8080}, {ip: "178.130.29.226", port: 53295}, {ip: "178.170.254.178", port: 46788}, {ip: "178.213.13.136", port: 53281}, {ip: "178.218.104.8", port: 49707}, {ip: "178.219.183.163", port: 8080}, {ip: "178.237.180.34", port: 57307}, {ip: "178.57.101.212", port: 38020}, {ip: "178.57.101.235", port: 31309}, {ip: "178.64.190.133", port: 46688}, {ip: "178.75.1.111", port: 50411}, {ip: "178.75.27.131", port: 41879}, {ip: "185.13.35.178", port: 40654}, {ip: "185.15.189.67", port: 30215}, {ip: "185.175.119.137", port: 41258}, {ip: "185.18.111.194", port: 41258}, {ip: "185.19.176.237", port: 53281}, {ip: "185.190.40.115", port: 31747}, {ip: "185.216.195.134", port: 61287}, {ip: "185.22.172.94", port: 10010}, {ip: "185.22.172.94", port: 1448}, {ip: "185.22.174.65", port: 10010}, {ip: "185.22.174.65", port: 1448}, {ip: "185.23.64.100", port: 3130}, {ip: "185.23.82.39", port: 59248}, {ip: "185.233.94.105", port: 59288}, {ip: "185.233.94.146", port: 57736}, {ip: "185.3.68.54", port: 53500}, {ip: "185.32.120.177", port: 60724}, {ip: "185.34.20.164", port: 53700}, {ip: "185.34.23.43", port: 63238}, {ip: "185.51.60.141", port: 39935}, {ip: "185.61.92.228", port: 33060}, {ip: "185.61.93.67", port: 49107}, {ip: "185.7.233.66", port: 53504}, {ip: "185.72.225.10", port: 56285}, {ip: "185.75.5.158", port: 60819}, {ip: "185.9.86.186", port: 39345}, {ip: "188.133.136.10", port: 47113}, {ip: "188.168.75.254", port: 56899}, {ip: "188.170.41.6", port: 60332}, {ip: "188.187.189.142", port: 38264}, {ip: "188.234.151.103", port: 8080}, {ip: "188.235.11.88", port: 57143}, {ip: "188.235.137.196", port: 23500}, {ip: "188.244.175.2", port: 8080}, {ip: "188.255.82.136", port: 53281}, {ip: "188.43.4.117", port: 60577}, {ip: "188.68.95.166", port: 41258}, {ip: "188.92.242.180", port: 52048}, {ip: "188.93.242.213", port: 49774}, {ip: "192.162.193.243", port: 36910}, {ip: "192.162.214.11", port: 41258}, {ip: "193.106.170.133", port: 38591}, {ip: "193.232.113.244", port: 40412}, {ip: "193.232.234.130", port: 61932}, {ip: "193.242.177.105", port: 53281}, {ip: "193.242.178.50", port: 52376}, {ip: "193.242.178.90", port: 8080}, {ip: "193.33.101.152", port: 34611}, {ip: "194.114.128.149", port: 61213}, {ip: "194.135.15.146", port: 59328}, {ip: "194.135.216.178", port: 56805}, {ip: "194.135.75.74", port: 41258}, {ip: "194.146.201.67", port: 53281}, {ip: "194.186.18.46", port: 56408}, {ip: "194.186.20.62", port: 21231}, {ip: "194.190.171.214", port: 43960}, {ip: "194.9.27.82", port: 42720}, {ip: "195.133.232.58", port: 41733}, {ip: "195.14.114.116", port: 59530}, {ip: "195.14.114.24", port: 56897}, {ip: "195.158.250.97", port: 41582}, {ip: "195.16.48.142", port: 36083}, {ip: "195.191.183.169", port: 47238}, {ip: "195.206.45.112", port: 53281}, {ip: "195.208.172.70", port: 8080}, {ip: "195.209.141.67", port: 31927}, {ip: "195.209.176.2", port: 8080}, {ip: "195.210.144.166", port: 30088}, {ip: "195.211.160.88", port: 44464}, {ip: "195.218.144.182", port: 31705}, {ip: "195.46.168.147", port: 8080}, {ip: "195.9.188.78", port: 53281}, {ip: "195.9.209.10", port: 35242}, {ip: "195.9.223.246", port: 52098}, {ip: "195.9.237.66", port: 8080}, {ip: "195.9.91.66", port: 33199}, {ip: "195.91.132.20", port: 19600}, {ip: "195.98.183.82", port: 30953}, {ip: "212.104.82.246", port: 36495}, {ip: "212.119.229.18", port: 33852}, {ip: "212.13.97.122", port: 30466}, {ip: "212.19.21.19", port: 53264}, {ip: "212.19.5.157", port: 58442}, {ip: "212.19.8.223", port: 30281}, {ip: "212.19.8.239", port: 55602}, {ip: "212.192.202.207", port: 4550}, {ip: "212.22.80.224", port: 34822}, {ip: "212.26.247.178", port: 38418}, {ip: "212.33.228.161", port: 37971}, {ip: "212.33.243.83", port: 38605}, {ip: "212.34.53.126", port: 44369}, {ip: "212.5.107.81", port: 56481}, {ip: "212.7.230.7", port: 51405}, {ip: "212.77.138.161", port: 41258}, {ip: "213.108.221.201", port: 32800}, {ip: "213.109.7.135", port: 59918}, {ip: "213.128.9.204", port: 35549}, {ip: "213.134.196.12", port: 38723}, {ip: "213.168.37.86", port: 8080}, {ip: "213.187.118.184", port: 53281}, {ip: "213.21.23.98", port: 53281}, {ip: "213.210.67.166", port: 53281}, {ip: "213.234.0.242", port: 56503}, {ip: "213.247.192.131", port: 41258}, {ip: "213.251.226.208", port: 56900}, {ip: "213.33.155.80", port: 44387}, {ip: "213.33.199.194", port: 36411}, {ip: "213.33.224.82", port: 8080}, {ip: "213.59.153.19", port: 53281}, {ip: "217.10.45.103", port: 8080}, {ip: "217.107.197.39", port: 33628}, {ip: "217.116.60.66", port: 21231}, {ip: "217.195.87.58", port: 41258}, {ip: "217.197.239.54", port: 34463}, {ip: "217.74.161.42", port: 34175}, {ip: "217.8.84.76", port: 46378}, {ip: "31.131.67.14", port: 8080}, {ip: "31.132.127.142", port: 35432}, {ip: "31.132.218.252", port: 32423}, {ip: "31.173.17.118", port: 51317}, {ip: "31.193.124.70", port: 53281}, {ip: "31.210.211.147", port: 8080}, {ip: "31.220.183.217", port: 53281}, {ip: "31.29.212.82", port: 35066}, {ip: "31.42.254.24", port: 30912}, {ip: "31.47.189.14", port: 38473}, {ip: "37.113.129.98", port: 41665}, {ip: "37.192.103.164", port: 34835}, {ip: "37.192.194.50", port: 50165}, {ip: "37.192.99.151", port: 51417}, {ip: "37.205.83.91", port: 35888}, {ip: "37.233.85.155", port: 53281}, {ip: "37.235.167.66", port: 53281}, {ip: "37.235.65.2", port: 47816}, {ip: "37.235.67.178", port: 34450}, {ip: "37.9.134.133", port: 41262}, {ip: "46.150.174.90", port: 53281}, {ip: "46.151.156.198", port: 56013}, {ip: "46.16.226.10", port: 8080}, {ip: "46.163.131.55", port: 48306}, {ip: "46.173.191.51", port: 53281}, {ip: "46.174.222.61", port: 34977}, {ip: "46.180.96.79", port: 42319}, {ip: "46.181.151.79", port: 39386}, {ip: "46.21.74.130", port: 8080}, {ip: "46.227.162.98", port: 51558}, {ip: "46.229.187.169", port: 53281}, {ip: "46.229.67.198", port: 47437}, {ip: "46.243.179.221", port: 41598}, {ip: "46.254.217.54", port: 53281}, {ip: "46.32.68.188", port: 39707}, {ip: "46.39.224.112", port: 36765}, {ip: "46.63.162.171", port: 8080}, {ip: "46.73.33.253", port: 8080}, {ip: "5.128.32.12", port: 51959}, {ip: "5.129.155.3", port: 51390}, {ip: "5.129.16.27", port: 48935}, {ip: "5.141.81.65", port: 61853}, {ip: "5.16.15.234", port: 8080}, {ip: "5.167.51.235", port: 8080}, {ip: "5.167.96.238", port: 3128}, {ip: "5.19.165.235", port: 30793}, {ip: "5.35.93.157", port: 31773}, {ip: "5.59.137.90", port: 8888}, {ip: "5.8.207.160", port: 57192}, {ip: "62.122.97.66", port: 59143}, {ip: "62.148.151.253", port: 53570}, {ip: "62.152.85.158", port: 31156}, {ip: "62.165.54.153", port: 55522}, {ip: "62.173.140.14", port: 8080}, {ip: "62.173.155.206", port: 41258}, {ip: "62.182.206.19", port: 37715}, {ip: "62.213.14.166", port: 8080}, {ip: "62.76.123.224", port: 8080}, {ip: "77.221.220.133", port: 44331}, {ip: "77.232.153.248", port: 60950}, {ip: "77.233.10.37", port: 54210}, {ip: "77.244.27.109", port: 47554}, {ip: "77.37.142.203", port: 53281}, {ip: "77.39.29.29", port: 49243}, {ip: "77.75.6.34", port: 8080}, {ip: "77.87.102.7", port: 42601}, {ip: "77.94.121.212", port: 36896}, {ip: "77.94.121.51", port: 45293}, {ip: "78.110.154.177", port: 59888}, {ip: "78.140.201.226", port: 8090}, {ip: "78.153.4.122", port: 9001}, {ip: "78.156.225.170", port: 41258}, {ip: "78.156.243.146", port: 59730}, {ip: "78.29.14.201", port: 39001}, {ip: "78.81.24.112", port: 8080}, {ip: "78.85.36.203", port: 8080}, {ip: "79.104.219.125", port: 3128}, {ip: "79.104.55.134", port: 8080}, {ip: "79.137.181.170", port: 8080}, {ip: "79.173.124.194", port: 47832}, {ip: "79.173.124.207", port: 53281}, {ip: "79.174.186.168", port: 45710}, {ip: "79.175.51.13", port: 54853}, {ip: "79.175.57.77", port: 55477}, {ip: "80.234.107.118", port: 56952}, {ip: "80.237.6.1", port: 34880}, {ip: "80.243.14.182", port: 49320}, {ip: "80.251.48.215", port: 45157}, {ip: "80.254.121.66", port: 41055}, {ip: "80.254.125.236", port: 80}, {ip: "80.72.121.185", port: 52379}, {ip: "80.89.133.210", port: 3128}, {ip: "80.91.17.113", port: 41258}, {ip: "81.162.61.166", port: 40392}, {ip: "81.163.57.121", port: 41258}, {ip: "81.163.57.46", port: 41258}, {ip: "81.163.62.136", port: 41258}, {ip: "81.23.112.98", port: 55269}, {ip: "81.23.118.106", port: 60427}, {ip: "81.23.177.245", port: 8080}, {ip: "81.24.126.166", port: 8080}, {ip: "81.30.216.147", port: 41258}, {ip: "81.95.131.10", port: 44292}, {ip: "82.114.125.22", port: 8080}, {ip: "82.151.208.20", port: 8080}, {ip: "83.221.216.110", port: 47326}, {ip: "83.246.139.24", port: 8080}, {ip: "83.97.108.8", port: 41258}, {ip: "84.22.154.76", port: 8080}, {ip: "84.52.110.36", port: 38674}, {ip: "84.52.74.194", port: 8080}, {ip: "84.52.77.227", port: 41806}, {ip: "84.52.79.166", port: 43548}, {ip: "84.52.84.157", port: 44331}, {ip: "84.52.88.125", port: 32666}, {ip: "85.113.48.148", port: 8080}, {ip: "85.113.49.220", port: 8080}, {ip: "85.12.193.210", port: 58470}, {ip: "85.15.179.5", port: 8080}, {ip: "85.173.244.102", port: 53281}, {ip: "85.174.227.52", port: 59280}, {ip: "85.192.184.133", port: 8080}, {ip: "85.192.184.133", port: 80}, {ip: "85.21.240.193", port: 55820}, {ip: "85.21.63.219", port: 53281}, {ip: "85.235.190.18", port: 42494}, {ip: "85.237.56.193", port: 8080}, {ip: "85.91.119.6", port: 8080}, {ip: "86.102.116.30", port: 8080}, {ip: "86.110.30.146", port: 38109}, {ip: "87.117.3.129", port: 3128}, {ip: "87.225.108.195", port: 8080}, {ip: "87.228.103.111", port: 8080}, {ip: "87.228.103.43", port: 8080}, {ip: "87.229.143.10", port: 48872}, {ip: "87.249.205.103", port: 8080}, {ip: "87.249.21.193", port: 43079}, {ip: "87.255.13.217", port: 8080}, {ip: "88.147.159.167", port: 53281}, {ip: "88.200.225.32", port: 38583}, {ip: "88.204.59.177", port: 32666}, {ip: "88.84.209.69", port: 30819}, {ip: "88.87.72.72", port: 8080}, {ip: "88.87.79.20", port: 8080}, {ip: "88.87.91.163", port: 48513}, {ip: "88.87.93.20", port: 33277}, {ip: "89.109.12.82", port: 47972}, {ip: "89.109.21.43", port: 9090}, {ip: "89.109.239.183", port: 41041}, {ip: "89.109.54.137", port: 36469}, {ip: "89.17.37.218", port: 52957}, {ip: "89.189.130.103", port: 32626}, {ip: "89.189.159.214", port: 42530}, {ip: "89.189.174.121", port: 52636}, {ip: "89.23.18.29", port: 53281}, {ip: "89.249.251.21", port: 3128}, {ip: "89.250.149.114", port: 60981}, {ip: "89.250.17.209", port: 8080}, {ip: "89.250.19.173", port: 8080}, {ip: "90.150.87.172", port: 81}, {ip: "90.154.125.173", port: 33078}, {ip: "90.188.38.81", port: 60585}, {ip: "90.189.151.183", port: 32601}, {ip: "91.103.208.114", port: 57063}, {ip: "91.122.100.222", port: 44331}, {ip: "91.122.207.229", port: 8080}, {ip: "91.144.139.93", port: 3128}, {ip: "91.144.142.19", port: 44617}, {ip: "91.146.16.54", port: 57902}, {ip: "91.190.116.194", port: 38783}, {ip: "91.190.80.100", port: 31659}, {ip: "91.190.85.97", port: 34286}, {ip: "91.203.36.188", port: 8080}, {ip: "91.205.131.102", port: 8080}, {ip: "91.205.146.25", port: 37501}, {ip: "91.210.94.212", port: 52635}, {ip: "91.213.23.110", port: 8080}, {ip: "91.215.22.51", port: 53305}, {ip: "91.217.42.3", port: 8080}, {ip: "91.217.42.4", port: 8080}, {ip: "91.220.135.146", port: 41258}, {ip: "91.222.167.213", port: 38057}, {ip: "91.226.140.71", port: 33199}, {ip: "91.235.7.216", port: 59067}, {ip: "92.124.195.22", port: 3128}, {ip: "92.126.193.180", port: 8080}, {ip: "92.241.110.223", port: 53281}, {ip: "92.252.240.1", port: 53281}, {ip: "92.255.164.187", port: 3128}, {ip: "92.255.195.57", port: 53281}, {ip: "92.255.229.146", port: 55785}, {ip: "92.255.5.2", port: 41012}, {ip: "92.38.32.36", port: 56113}, {ip: "92.39.138.98", port: 31150}, {ip: "92.51.16.155", port: 46202}, {ip: "92.55.59.63", port: 33030}, {ip: "93.170.112.200", port: 47995}, {ip: "93.183.86.185", port: 53281}, {ip: "93.188.45.157", port: 8080}, {ip: "93.81.246.5", port: 53281}, {ip: "93.91.112.247", port: 41258}, {ip: "94.127.217.66", port: 40115}, {ip: "94.154.85.214", port: 8080}, {ip: "94.180.106.94", port: 32767}, {ip: "94.180.249.187", port: 38051}, {ip: "94.230.243.6", port: 8080}, {ip: "94.232.57.231", port: 51064}, {ip: "94.24.244.170", port: 48936}, {ip: "94.242.55.108", port: 10010}, {ip: "94.242.55.108", port: 1448}, {ip: "94.242.57.136", port: 10010}, {ip: "94.242.57.136", port: 1448}, {ip: "94.242.58.108", port: 10010}, {ip: "94.242.58.108", port: 1448}, {ip: "94.242.58.14", port: 10010}, {ip: "94.242.58.14", port: 1448}, {ip: "94.242.58.142", port: 10010}, {ip: "94.242.58.142", port: 1448}, {ip: "94.242.59.245", port: 10010}, {ip: "94.242.59.245", port: 1448}, {ip: "94.247.241.70", port: 53640}, {ip: "94.247.62.165", port: 33176}, {ip: "94.253.13.228", port: 54935}, {ip: "94.253.14.187", port: 55045}, {ip: "94.28.94.154", port: 46966}, {ip: "94.73.217.125", port: 40858}, {ip: "95.140.19.9", port: 8080}, {ip: "95.140.20.94", port: 33994}, {ip: "95.154.137.66", port: 41258}, {ip: "95.154.159.119", port: 44242}, {ip: "95.154.82.254", port: 52484}, {ip: "95.161.157.227", port: 43170}, {ip: "95.161.182.146", port: 33877}, {ip: "95.161.189.26", port: 61522}, {ip: "95.165.163.146", port: 8888}, {ip: "95.165.172.90", port: 60496}, {ip: "95.165.182.18", port: 38950}, {ip: "95.165.203.222", port: 33805}, {ip: "95.165.244.122", port: 58162}, {ip: "95.167.123.54", port: 58664}, {ip: "95.167.241.242", port: 49636}, {ip: "95.171.1.92", port: 35956}, {ip: "95.172.52.230", port: 35989}, {ip: "95.181.35.30", port: 40804}, {ip: "95.181.56.178", port: 39144}, {ip: "95.181.75.228", port: 53281}, {ip: "95.188.74.194", port: 57122}, {ip: "95.189.112.214", port: 35508}, {ip: "95.31.10.247", port: 30711}, {ip: "95.31.197.77", port: 41651}, {ip: "95.31.2.199", port: 33632}, {ip: "95.71.125.50", port: 49882}, {ip: "95.73.62.13", port: 32185}, {ip: "95.79.36.55", port: 44861}, {ip: "95.79.55.196", port: 53281}, {ip: "95.79.99.148", port: 3128}, {ip: "95.80.65.39", port: 43555}, {ip: "95.80.93.44", port: 41258}, {ip: "95.80.98.41", port: 8080}, {ip: "95.83.156.250", port: 58438}, {ip: "95.84.128.25", port: 33765}, {ip: "95.84.154.73", port: 57423}],
  "CA" => [{ip: "144.217.161.149", port: 8080}, {ip: "24.37.9.6", port: 54154}, {ip: "54.39.138.144", port: 3128}, {ip: "54.39.138.145", port: 3128}, {ip: "54.39.138.151", port: 3128}, {ip: "54.39.138.152", port: 3128}, {ip: "54.39.138.153", port: 3128}, {ip: "54.39.138.154", port: 3128}, {ip: "54.39.138.155", port: 3128}, {ip: "54.39.138.156", port: 3128}, {ip: "54.39.138.157", port: 3128}, {ip: "54.39.53.104", port: 3128}, {ip: "66.70.167.113", port: 3128}, {ip: "66.70.167.116", port: 3128}, {ip: "66.70.167.117", port: 3128}, {ip: "66.70.167.119", port: 3128}, {ip: "66.70.167.120", port: 3128}, {ip: "66.70.167.125", port: 3128}, {ip: "66.70.188.148", port: 3128}, {ip: "70.35.213.229", port: 36127}, {ip: "70.65.233.174", port: 8080}, {ip: "72.139.24.66", port: 38861}, {ip: "74.15.191.160", port: 41564}],
  "JP" => [{ip: "47.91.20.67", port: 8080}, {ip: "61.118.35.94", port: 55725}],
  "IT" => [{ip: "109.70.201.97", port: 53517}, {ip: "176.31.82.212", port: 8080}, {ip: "185.132.228.118", port: 55583}, {ip: "185.49.58.88", port: 56006}, {ip: "185.94.89.179", port: 41258}, {ip: "213.203.134.10", port: 41258}, {ip: "217.61.172.12", port: 41369}, {ip: "46.232.143.126", port: 41258}, {ip: "46.232.143.253", port: 41258}, {ip: "93.67.154.125", port: 8080}, {ip: "93.67.154.125", port: 80}, {ip: "95.169.95.242", port: 53803}],
  "TH" => [{ip: "1.10.184.166", port: 57330}, {ip: "1.10.186.100", port: 55011}, {ip: "1.10.186.209", port: 32431}, {ip: "1.10.186.245", port: 34360}, {ip: "1.10.186.93", port: 53711}, {ip: "1.10.187.118", port: 62000}, {ip: "1.10.187.34", port: 51635}, {ip: "1.10.187.43", port: 38715}, {ip: "1.10.188.181", port: 51093}, {ip: "1.10.188.83", port: 31940}, {ip: "1.10.188.95", port: 30593}, {ip: "1.10.189.58", port: 48564}, {ip: "1.179.157.237", port: 46178}, {ip: "1.179.164.213", port: 8080}, {ip: "1.179.198.37", port: 8080}, {ip: "1.20.100.99", port: 53794}, {ip: "1.20.101.221", port: 55707}, {ip: "1.20.101.254", port: 35394}, {ip: "1.20.101.80", port: 36234}, {ip: "1.20.102.133", port: 40296}, {ip: "1.20.103.13", port: 40544}, {ip: "1.20.103.56", port: 55422}, {ip: "1.20.96.234", port: 53142}, {ip: "1.20.97.54", port: 60122}, {ip: "1.20.99.63", port: 32123}, {ip: "101.108.92.20", port: 8080}, {ip: "101.109.143.71", port: 36127}, {ip: "101.51.141.110", port: 42860}, {ip: "101.51.141.60", port: 60417}, {ip: "103.246.17.237", port: 3128}, {ip: "110.164.73.131", port: 8080}, {ip: "110.164.87.80", port: 35844}, {ip: "110.77.134.106", port: 8080}, {ip: "113.53.29.92", port: 47297}, {ip: "113.53.83.192", port: 32780}, {ip: "113.53.83.195", port: 35686}, {ip: "113.53.91.214", port: 8080}, {ip: "115.87.27.0", port: 53276}, {ip: "118.172.211.3", port: 58535}, {ip: "118.172.211.40", port: 30430}, {ip: "118.174.196.174", port: 23500}, {ip: "118.174.196.203", port: 23500}, {ip: "118.174.220.107", port: 41222}, {ip: "118.174.220.110", port: 39025}, {ip: "118.174.220.115", port: 41011}, {ip: "118.174.220.118", port: 59556}, {ip: "118.174.220.136", port: 55041}, {ip: "118.174.220.163", port: 31561}, {ip: "118.174.220.168", port: 47455}, {ip: "118.174.220.231", port: 40924}, {ip: "118.174.220.238", port: 46326}, {ip: "118.174.234.13", port: 53084}, {ip: "118.174.234.26", port: 41926}, {ip: "118.174.234.32", port: 57403}, {ip: "118.174.234.59", port: 59149}, {ip: "118.174.234.68", port: 42626}, {ip: "118.174.234.83", port: 38006}, {ip: "118.175.207.104", port: 38959}, {ip: "118.175.244.111", port: 8080}, {ip: "118.175.93.207", port: 50738}, {ip: "122.154.38.53", port: 8080}, {ip: "122.154.59.6", port: 8080}, {ip: "122.154.72.102", port: 8080}, {ip: "122.155.222.98", port: 3128}, {ip: "124.121.22.121", port: 61699}, {ip: "125.24.156.16", port: 44321}, {ip: "125.25.165.105", port: 33850}, {ip: "125.25.165.111", port: 40808}, {ip: "125.25.165.42", port: 47221}, {ip: "125.25.201.14", port: 30100}, {ip: "125.26.99.135", port: 55637}, {ip: "125.26.99.141", port: 38537}, {ip: "125.26.99.148", port: 31818}, {ip: "134.236.247.137", port: 8080}, {ip: "159.192.98.224", port: 3128}, {ip: "171.100.2.154", port: 8080}, {ip: "171.100.9.126", port: 49163}, {ip: "180.180.156.116", port: 48431}, {ip: "180.180.156.46", port: 48507}, {ip: "180.180.156.87", port: 36628}, {ip: "180.180.218.204", port: 51565}, {ip: "180.180.8.34", port: 8080}, {ip: "182.52.238.125", port: 58861}, {ip: "182.52.74.73", port: 36286}, {ip: "182.52.74.76", port: 34084}, {ip: "182.52.74.77", port: 34825}, {ip: "182.52.74.78", port: 48708}, {ip: "182.52.90.45", port: 53799}, {ip: "182.53.206.155", port: 34307}, {ip: "182.53.206.43", port: 45330}, {ip: "182.53.206.49", port: 54228}, {ip: "183.88.212.141", port: 8080}, {ip: "183.88.212.184", port: 8080}, {ip: "183.88.213.85", port: 8080}, {ip: "183.88.214.47", port: 8080}, {ip: "184.82.128.211", port: 8080}, {ip: "202.183.201.13", port: 8081}, {ip: "202.29.20.151", port: 43083}, {ip: "203.150.172.151", port: 8080}, {ip: "27.131.157.94", port: 8080}, {ip: "27.145.100.22", port: 8080}, {ip: "27.145.100.243", port: 8080}, {ip: "49.231.196.114", port: 53281}, {ip: "58.97.72.83", port: 8080}, {ip: "61.19.145.66", port: 8080}],
  "ES" => [{ip: "185.198.184.14", port: 48122}, {ip: "185.26.226.241", port: 36012}, {ip: "194.224.188.82", port: 3128}, {ip: "195.235.68.61", port: 3128}, {ip: "195.53.237.122", port: 3128}, {ip: "195.53.86.82", port: 3128}, {ip: "213.96.245.47", port: 8080}, {ip: "217.125.71.214", port: 33950}, {ip: "62.14.178.72", port: 53281}, {ip: "80.35.254.42", port: 53281}, {ip: "81.33.4.214", port: 61711}, {ip: "83.175.238.170", port: 53281}, {ip: "85.217.137.77", port: 3128}, {ip: "90.170.205.178", port: 33680}, {ip: "93.156.177.91", port: 53281}, {ip: "95.60.152.139", port: 37995}],
  "AE" => [{ip: "178.32.5.90", port: 36159}],
  "KR" => [{ip: "112.217.219.179", port: 3128}, {ip: "114.141.229.2", port: 58115}, {ip: "121.139.218.165", port: 31409}, {ip: "122.49.112.2", port: 38592}, {ip: "61.42.18.132", port: 53281}],
  "BR" => [{ip: "128.201.97.157", port: 53281}, {ip: "128.201.97.158", port: 53281}, {ip: "131.0.246.157", port: 35252}, {ip: "131.161.26.90", port: 8080}, {ip: "131.72.143.100", port: 41396}, {ip: "138.0.24.66", port: 53281}, {ip: "138.121.130.50", port: 50600}, {ip: "138.121.155.127", port: 61932}, {ip: "138.121.32.133", port: 23492}, {ip: "138.185.176.63", port: 53281}, {ip: "138.204.233.190", port: 53281}, {ip: "138.204.233.242", port: 53281}, {ip: "138.219.71.74", port: 52688}, {ip: "138.36.107.24", port: 41184}, {ip: "138.94.115.166", port: 8080}, {ip: "143.0.188.161", port: 53281}, {ip: "143.202.218.135", port: 8080}, {ip: "143.208.2.42", port: 53281}, {ip: "143.208.79.223", port: 8080}, {ip: "143.255.52.102", port: 40687}, {ip: "143.255.52.116", port: 57856}, {ip: "143.255.52.117", port: 37279}, {ip: "144.217.22.128", port: 8080}, {ip: "168.0.8.225", port: 8080}, {ip: "168.0.8.55", port: 8080}, {ip: "168.121.139.54", port: 40056}, {ip: "168.181.168.23", port: 53281}, {ip: "168.181.170.198", port: 31935}, {ip: "168.232.198.25", port: 32009}, {ip: "168.232.198.35", port: 42267}, {ip: "168.232.207.145", port: 46342}, {ip: "170.0.104.107", port: 60337}, {ip: "170.0.112.2", port: 50359}, {ip: "170.0.112.229", port: 50359}, {ip: "170.238.118.107", port: 34314}, {ip: "170.239.144.9", port: 3128}, {ip: "170.247.29.138", port: 8080}, {ip: "170.81.237.36", port: 37124}, {ip: "170.84.51.74", port: 53281}, {ip: "170.84.60.222", port: 42981}, {ip: "177.10.202.67", port: 8080}, {ip: "177.101.60.86", port: 80}, {ip: "177.103.231.211", port: 55091}, {ip: "177.12.80.50", port: 50556}, {ip: "177.131.13.9", port: 20183}, {ip: "177.135.178.115", port: 42510}, {ip: "177.135.248.75", port: 20183}, {ip: "177.184.206.238", port: 39508}, {ip: "177.185.148.46", port: 58623}, {ip: "177.200.83.238", port: 8080}, {ip: "177.21.24.146", port: 666}, {ip: "177.220.188.120", port: 47556}, {ip: "177.220.188.213", port: 8080}, {ip: "177.222.229.243", port: 23500}, {ip: "177.234.161.42", port: 8080}, {ip: "177.36.11.241", port: 3128}, {ip: "177.36.12.193", port: 23500}, {ip: "177.37.199.175", port: 49608}, {ip: "177.39.187.70", port: 37315}, {ip: "177.44.175.199", port: 8080}, {ip: "177.46.148.126", port: 3128}, {ip: "177.46.148.142", port: 3128}, {ip: "177.47.194.98", port: 21231}, {ip: "177.5.98.58", port: 20183}, {ip: "177.52.55.19", port: 60901}, {ip: "177.54.200.66", port: 57526}, {ip: "177.55.255.74", port: 37147}, {ip: "177.67.217.94", port: 53281}, {ip: "177.73.248.6", port: 54381}, {ip: "177.73.4.234", port: 23500}, {ip: "177.75.143.211", port: 35955}, {ip: "177.75.161.206", port: 3128}, {ip: "177.75.86.49", port: 20183}, {ip: "177.8.216.106", port: 8080}, {ip: "177.8.216.114", port: 8080}, {ip: "177.8.37.247", port: 56052}, {ip: "177.84.216.17", port: 50569}, {ip: "177.85.200.254", port: 53095}, {ip: "177.87.169.1", port: 53281}, {ip: "179.107.97.178", port: 3128}, {ip: "179.109.144.25", port: 8080}, {ip: "179.109.193.137", port: 53281}, {ip: "179.189.125.206", port: 8080}, {ip: "179.97.30.46", port: 53100}, {ip: "186.192.195.220", port: 38983}, {ip: "186.193.11.226", port: 48999}, {ip: "186.193.26.106", port: 3128}, {ip: "186.208.220.248", port: 3128}, {ip: "186.209.243.142", port: 3128}, {ip: "186.209.243.233", port: 3128}, {ip: "186.211.106.227", port: 34334}, {ip: "186.211.160.178", port: 36756}, {ip: "186.215.133.170", port: 20183}, {ip: "186.216.81.21", port: 31773}, {ip: "186.219.214.13", port: 32708}, {ip: "186.224.94.6", port: 48957}, {ip: "186.225.97.246", port: 43082}, {ip: "186.226.171.163", port: 48698}, {ip: "186.226.179.2", port: 56089}, {ip: "186.226.234.67", port: 33834}, {ip: "186.228.147.58", port: 20183}, {ip: "186.233.97.163", port: 8888}, {ip: "186.248.170.82", port: 53281}, {ip: "186.249.213.101", port: 53482}, {ip: "186.249.213.65", port: 52018}, {ip: "186.250.213.225", port: 60774}, {ip: "186.250.96.70", port: 8080}, {ip: "186.250.96.77", port: 8080}, {ip: "187.1.43.246", port: 53396}, {ip: "187.108.36.250", port: 20183}, {ip: "187.108.38.10", port: 20183}, {ip: "187.109.36.251", port: 20183}, {ip: "187.109.40.9", port: 20183}, {ip: "187.109.56.101", port: 20183}, {ip: "187.111.90.89", port: 53281}, {ip: "187.115.10.50", port: 20183}, {ip: "187.19.62.7", port: 59010}, {ip: "187.33.79.61", port: 33469}, {ip: "187.35.158.150", port: 38872}, {ip: "187.44.1.167", port: 8080}, {ip: "187.45.127.87", port: 20183}, {ip: "187.45.156.109", port: 8080}, {ip: "187.5.218.215", port: 20183}, {ip: "187.58.65.225", port: 3128}, {ip: "187.63.111.37", port: 3128}, {ip: "187.72.166.10", port: 8080}, {ip: "187.73.68.14", port: 53281}, {ip: "187.84.177.6", port: 45903}, {ip: "187.84.191.170", port: 43936}, {ip: "187.87.204.210", port: 45597}, {ip: "187.87.39.247", port: 31793}, {ip: "189.1.16.162", port: 23500}, {ip: "189.113.124.162", port: 8080}, {ip: "189.124.195.185", port: 37318}, {ip: "189.3.196.18", port: 61595}, {ip: "189.37.33.59", port: 35532}, {ip: "189.7.49.66", port: 42700}, {ip: "189.90.194.35", port: 30843}, {ip: "189.90.248.75", port: 8080}, {ip: "189.91.231.43", port: 3128}, {ip: "191.239.243.156", port: 3128}, {ip: "191.240.154.246", port: 23500}, {ip: "191.240.156.154", port: 36127}, {ip: "191.240.99.142", port: 9090}, {ip: "191.241.226.230", port: 53281}, {ip: "191.241.228.74", port: 20183}, {ip: "191.241.228.78", port: 20183}, {ip: "191.241.33.238", port: 39188}, {ip: "191.241.36.170", port: 8080}, {ip: "191.241.36.218", port: 3128}, {ip: "191.242.182.132", port: 8081}, {ip: "191.243.221.130", port: 3128}, {ip: "191.255.207.231", port: 20183}, {ip: "191.36.192.196", port: 3128}, {ip: "191.36.244.230", port: 51377}, {ip: "191.5.0.79", port: 53281}, {ip: "191.6.228.6", port: 53281}, {ip: "191.7.193.18", port: 38133}, {ip: "191.7.20.134", port: 3128}, {ip: "192.140.91.173", port: 20183}, {ip: "200.150.86.138", port: 44677}, {ip: "200.155.36.185", port: 3128}, {ip: "200.155.36.188", port: 3128}, {ip: "200.155.39.41", port: 3128}, {ip: "200.174.158.26", port: 34112}, {ip: "200.187.177.105", port: 20183}, {ip: "200.187.87.138", port: 20183}, {ip: "200.192.252.201", port: 8080}, {ip: "200.192.255.102", port: 8080}, {ip: "200.203.144.2", port: 50262}, {ip: "200.229.238.42", port: 20183}, {ip: "200.233.134.85", port: 43172}, {ip: "200.233.136.177", port: 20183}, {ip: "200.241.44.3", port: 20183}, {ip: "200.255.122.170", port: 8080}, {ip: "200.255.122.174", port: 8080}, {ip: "201.12.21.57", port: 8080}, {ip: "201.131.224.21", port: 56200}, {ip: "201.182.223.16", port: 37492}, {ip: "201.20.89.126", port: 8080}, {ip: "201.22.95.10", port: 8080}, {ip: "201.57.167.34", port: 8080}, {ip: "201.59.200.246", port: 80}, {ip: "201.6.167.178", port: 3128}, {ip: "201.90.36.194", port: 3128}, {ip: "45.226.20.6", port: 8080}, {ip: "45.234.139.129", port: 20183}, {ip: "45.234.200.18", port: 53281}, {ip: "45.235.87.4", port: 51996}, {ip: "45.6.136.38", port: 53281}, {ip: "45.6.80.131", port: 52080}, {ip: "45.6.93.10", port: 8080}, {ip: "45.71.108.162", port: 53281}],
  "PK" => [{ip: "103.18.243.154", port: 8080}, {ip: "110.36.218.126", port: 36651}, {ip: "110.36.234.210", port: 8080}, {ip: "110.39.162.74", port: 53281}, {ip: "110.39.174.58", port: 8080}, {ip: "111.68.108.34", port: 8080}, {ip: "125.209.116.182", port: 31653}, {ip: "125.209.78.21", port: 8080}, {ip: "125.209.82.78", port: 35087}, {ip: "180.92.156.150", port: 8080}, {ip: "202.142.158.114", port: 8080}, {ip: "202.147.173.10", port: 8080}, {ip: "202.147.173.10", port: 80}, {ip: "202.69.38.82", port: 8080}, {ip: "203.128.16.126", port: 59538}, {ip: "203.128.16.154", port: 33002}, {ip: "27.255.4.170", port: 8080}],
  "ID" => [{ip: "101.128.68.113", port: 8080}, {ip: "101.255.116.113", port: 53281}, {ip: "101.255.120.170", port: 6969}, {ip: "101.255.121.74", port: 8080}, {ip: "101.255.124.242", port: 8080}, {ip: "101.255.124.242", port: 80}, {ip: "101.255.56.138", port: 53560}, {ip: "103.10.171.132", port: 41043}, {ip: "103.10.81.172", port: 80}, {ip: "103.108.158.3", port: 48196}, {ip: "103.111.219.159", port: 53281}, {ip: "103.111.54.26", port: 49781}, {ip: "103.111.54.74", port: 8080}, {ip: "103.19.110.177", port: 8080}, {ip: "103.2.146.66", port: 49089}, {ip: "103.206.168.177", port: 53281}, {ip: "103.206.253.58", port: 49573}, {ip: "103.21.92.254", port: 33929}, {ip: "103.226.49.83", port: 23500}, {ip: "103.227.147.142", port: 37581}, {ip: "103.23.101.58", port: 8080}, {ip: "103.24.107.2", port: 8181}, {ip: "103.245.19.222", port: 53281}, {ip: "103.247.122.38", port: 8080}, {ip: "103.247.218.166", port: 3128}, {ip: "103.248.219.26", port: 53634}, {ip: "103.253.2.165", port: 33543}, {ip: "103.253.2.168", port: 51229}, {ip: "103.253.2.174", port: 30827}, {ip: "103.28.114.134", port: 8080}, {ip: "103.28.220.73", port: 53281}, {ip: "103.30.246.47", port: 3128}, {ip: "103.31.45.169", port: 57655}, {ip: "103.41.122.14", port: 53281}, {ip: "103.75.101.97", port: 8080}, {ip: "103.76.17.151", port: 23500}, {ip: "103.76.50.181", port: 8080}, {ip: "103.76.50.181", port: 80}, {ip: "103.76.50.182", port: 8080}, {ip: "103.78.74.170", port: 3128}, {ip: "103.78.80.194", port: 33442}, {ip: "103.8.122.5", port: 53297}, {ip: "103.80.236.107", port: 53281}, {ip: "103.80.238.203", port: 53281}, {ip: "103.86.140.74", port: 59538}, {ip: "103.94.122.254", port: 8080}, {ip: "103.94.125.244", port: 41508}, {ip: "103.94.169.19", port: 8080}, {ip: "103.94.7.254", port: 53281}, {ip: "106.0.51.50", port: 17385}, {ip: "110.93.13.202", port: 34881}, {ip: "112.78.37.6", port: 54791}, {ip: "114.199.110.58", port: 55898}, {ip: "114.199.112.170", port: 23500}, {ip: "114.199.123.194", port: 8080}, {ip: "114.57.33.162", port: 46935}, {ip: "114.57.33.214", port: 8080}, {ip: "114.6.197.254", port: 8080}, {ip: "114.7.15.146", port: 8080}, {ip: "114.7.162.254", port: 53281}, {ip: "115.124.75.226", port: 53990}, {ip: "115.124.75.228", port: 3128}, {ip: "117.102.78.42", port: 8080}, {ip: "117.102.93.251", port: 8080}, {ip: "117.102.94.186", port: 8080}, {ip: "117.102.94.186", port: 80}, {ip: "117.103.2.249", port: 58276}, {ip: "117.54.13.174", port: 34190}, {ip: "117.74.124.129", port: 8088}, {ip: "118.97.100.83", port: 35220}, {ip: "118.97.191.162", port: 80}, {ip: "118.97.191.203", port: 8080}, {ip: "118.97.36.18", port: 8080}, {ip: "118.97.73.85", port: 53281}, {ip: "118.99.105.226", port: 8080}, {ip: "119.252.168.53", port: 53281}, {ip: "122.248.45.35", port: 53281}, {ip: "122.50.6.186", port: 8080}, {ip: "122.50.6.186", port: 80}, {ip: "123.231.226.114", port: 47562}, {ip: "123.255.202.83", port: 32523}, {ip: "124.158.164.195", port: 8080}, {ip: "124.81.99.30", port: 3128}, {ip: "137.59.162.10", port: 3128}, {ip: "139.0.29.20", port: 59532}, {ip: "139.255.123.194", port: 4550}, {ip: "139.255.16.171", port: 31773}, {ip: "139.255.17.2", port: 47421}, {ip: "139.255.19.162", port: 42371}, {ip: "139.255.7.81", port: 53281}, {ip: "139.255.91.115", port: 8080}, {ip: "139.255.92.26", port: 53281}, {ip: "158.140.181.140", port: 54041}, {ip: "160.202.40.20", port: 55655}, {ip: "175.103.42.147", port: 8080}, {ip: "180.178.98.198", port: 8080}, {ip: "180.250.101.146", port: 8080}, {ip: "182.23.107.212", port: 3128}, {ip: "182.23.2.101", port: 49833}, {ip: "182.23.7.226", port: 8080}, {ip: "182.253.209.203", port: 3128}, {ip: "183.91.66.210", port: 80}, {ip: "202.137.10.179", port: 57338}, {ip: "202.137.25.53", port: 3128}, {ip: "202.137.25.8", port: 8080}, {ip: "202.138.242.76", port: 4550}, {ip: "202.138.249.202", port: 43108}, {ip: "202.148.2.254", port: 8000}, {ip: "202.162.201.94", port: 53281}, {ip: "202.165.47.26", port: 8080}, {ip: "202.43.167.130", port: 8080}, {ip: "202.51.126.10", port: 53281}, {ip: "202.59.171.164", port: 58567}, {ip: "202.93.128.98", port: 3128}, {ip: "203.142.72.114", port: 808}, {ip: "203.153.117.65", port: 54144}, {ip: "203.189.89.1", port: 53281}, {ip: "203.77.239.18", port: 37002}, {ip: "203.99.123.25", port: 61502}, {ip: "220.247.168.163", port: 53281}, {ip: "220.247.173.154", port: 53281}, {ip: "220.247.174.206", port: 53445}, {ip: "222.124.131.211", port: 47343}, {ip: "222.124.173.146", port: 53281}, {ip: "222.124.2.131", port: 8080}, {ip: "222.124.2.186", port: 8080}, {ip: "222.124.215.187", port: 38913}, {ip: "222.124.221.179", port: 53281}, {ip: "223.25.101.242", port: 59504}, {ip: "223.25.97.62", port: 8080}, {ip: "223.25.99.38", port: 80}, {ip: "27.111.44.202", port: 80}, {ip: "27.111.47.3", port: 51144}, {ip: "36.37.124.234", port: 36179}, {ip: "36.37.124.235", port: 36179}, {ip: "36.37.81.135", port: 8080}, {ip: "36.37.89.98", port: 32323}, {ip: "36.66.217.179", port: 8080}, {ip: "36.66.98.6", port: 53281}, {ip: "36.67.143.183", port: 48746}, {ip: "36.67.206.187", port: 8080}, {ip: "36.67.32.87", port: 8080}, {ip: "36.67.93.220", port: 3128}, {ip: "36.67.93.220", port: 80}, {ip: "36.89.10.51", port: 34115}, {ip: "36.89.119.149", port: 8080}, {ip: "36.89.157.23", port: 37728}, {ip: "36.89.181.155", port: 60165}, {ip: "36.89.188.11", port: 39507}, {ip: "36.89.194.113", port: 37811}, {ip: "36.89.226.254", port: 8081}, {ip: "36.89.232.138", port: 23500}, {ip: "36.89.39.10", port: 3128}, {ip: "36.89.65.253", port: 60997}, {ip: "43.243.141.114", port: 8080}, {ip: "43.245.184.202", port: 41102}, {ip: "43.245.184.238", port: 80}, {ip: "66.96.233.225", port: 35053}, {ip: "66.96.237.253", port: 8080}],
  "BD" => [{ip: "103.103.88.91", port: 8080}, {ip: "103.106.119.154", port: 8080}, {ip: "103.106.236.1", port: 8080}, {ip: "103.106.236.41", port: 8080}, {ip: "103.108.144.139", port: 53281}, {ip: "103.109.57.218", port: 8080}, {ip: "103.109.58.242", port: 8080}, {ip: "103.112.129.106", port: 31094}, {ip: "103.112.129.82", port: 53281}, {ip: "103.114.10.177", port: 8080}, {ip: "103.114.10.250", port: 8080}, {ip: "103.15.245.26", port: 8080}, {ip: "103.195.204.73", port: 21776}, {ip: "103.197.49.106", port: 49688}, {ip: "103.198.168.29", port: 21776}, {ip: "103.214.200.6", port: 59008}, {ip: "103.218.25.161", port: 8080}, {ip: "103.218.25.41", port: 8080}, {ip: "103.218.26.204", port: 8080}, {ip: "103.218.27.221", port: 8080}, {ip: "103.231.229.90", port: 53281}, {ip: "103.239.252.233", port: 8080}, {ip: "103.239.252.50", port: 8080}, {ip: "103.239.253.193", port: 8080}, {ip: "103.250.68.193", port: 51370}, {ip: "103.5.232.146", port: 8080}, {ip: "103.73.224.53", port: 23500}, {ip: "103.9.134.73", port: 65301}, {ip: "113.11.47.242", port: 40071}, {ip: "113.11.5.67", port: 40071}, {ip: "114.31.5.34", port: 52606}, {ip: "115.127.51.226", port: 42764}, {ip: "115.127.64.62", port: 39611}, {ip: "115.127.91.106", port: 8080}, {ip: "119.40.85.198", port: 36899}, {ip: "123.200.29.110", port: 23500}, {ip: "123.49.51.42", port: 55124}, {ip: "163.47.36.90", port: 3128}, {ip: "180.211.134.158", port: 23500}, {ip: "180.211.193.74", port: 40536}, {ip: "180.92.238.226", port: 53451}, {ip: "182.160.104.213", port: 8080}, {ip: "202.191.126.58", port: 23500}, {ip: "202.4.126.170", port: 8080}, {ip: "202.5.37.241", port: 33623}, {ip: "202.5.57.5", port: 61729}, {ip: "202.79.17.65", port: 60122}, {ip: "203.188.248.52", port: 23500}, {ip: "27.147.146.78", port: 52220}, {ip: "27.147.164.10", port: 52344}, {ip: "27.147.212.38", port: 53281}, {ip: "27.147.217.154", port: 43252}, {ip: "27.147.219.102", port: 49464}, {ip: "43.239.74.137", port: 8080}, {ip: "43.240.103.252", port: 8080}, {ip: "45.125.223.57", port: 8080}, {ip: "45.125.223.81", port: 8080}, {ip: "45.251.228.122", port: 41418}, {ip: "45.64.132.137", port: 8080}, {ip: "45.64.132.137", port: 80}, {ip: "61.247.186.137", port: 8080}],
  "MX" => [{ip: "148.217.94.54", port: 3128}, {ip: "177.244.28.77", port: 53281}, {ip: "187.141.73.147", port: 53281}, {ip: "187.185.15.35", port: 53281}, {ip: "187.188.46.172", port: 53455}, {ip: "187.216.83.185", port: 8080}, {ip: "187.216.90.46", port: 53281}, {ip: "187.243.253.182", port: 33796}, {ip: "189.195.132.86", port: 43286}, {ip: "189.204.158.161", port: 8080}, {ip: "200.79.180.115", port: 8080}, {ip: "201.140.113.90", port: 37193}, {ip: "201.144.14.229", port: 53281}, {ip: "201.163.73.93", port: 53281}],
  "PH" => [{ip: "103.86.187.242", port: 23500}, {ip: "122.54.101.69", port: 8080}, {ip: "122.54.65.150", port: 8080}, {ip: "125.5.20.134", port: 53281}, {ip: "146.88.77.51", port: 8080}, {ip: "182.18.200.92", port: 8080}, {ip: "219.90.87.91", port: 53281}, {ip: "58.69.12.210", port: 8080}],
  "EG" => [{ip: "41.65.0.167", port: 8080}],
  "VN" => [{ip: "1.55.240.156", port: 53281}, {ip: "101.99.23.136", port: 3128}, {ip: "103.15.51.160", port: 8080}, {ip: "113.161.128.169", port: 60427}, {ip: "113.161.161.143", port: 57967}, {ip: "113.161.173.10", port: 3128}, {ip: "113.161.35.108", port: 30028}, {ip: "113.164.79.177", port: 46281}, {ip: "113.190.235.50", port: 34619}, {ip: "115.78.160.247", port: 8080}, {ip: "117.2.155.29", port: 47228}, {ip: "117.2.17.26", port: 53281}, {ip: "117.2.22.41", port: 41973}, {ip: "117.4.145.16", port: 51487}, {ip: "118.69.219.185", port: 55184}, {ip: "118.69.61.212", port: 53281}, {ip: "118.70.116.227", port: 61651}, {ip: "118.70.219.124", port: 53281}, {ip: "221.121.12.238", port: 36077}, {ip: "27.2.7.59", port: 52148}],
  "CD" => [{ip: "41.79.233.45", port: 8080}],
  "TR" => [{ip: "151.80.65.175", port: 3128}, {ip: "176.235.186.242", port: 37043}, {ip: "178.250.92.18", port: 8080}, {ip: "185.203.170.92", port: 8080}, {ip: "185.203.170.94", port: 8080}, {ip: "185.203.170.95", port: 8080}, {ip: "185.51.36.152", port: 41258}, {ip: "195.137.223.50", port: 41336}, {ip: "195.155.98.70", port: 52598}, {ip: "212.156.146.22", port: 40080}, {ip: "213.14.31.122", port: 44621}, {ip: "31.145.137.139", port: 31871}, {ip: "31.145.138.129", port: 31871}, {ip: "31.145.138.146", port: 34159}, {ip: "31.145.187.172", port: 30636}, {ip: "78.188.4.124", port: 34514}, {ip: "88.248.23.216", port: 36426}, {ip: "93.182.72.36", port: 8080}, {ip: "95.0.194.241", port: 9090}],
}
