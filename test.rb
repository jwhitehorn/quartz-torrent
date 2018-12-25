#magnet:?xt=urn:btih:mq4oxed44vng7gq5mbpmwsyfk3kyvodd&tr=http://open.touki.ru/announce.php
$LOAD_PATH.unshift('./lib')
require 'quartz_torrent'
include QuartzTorrent

peerclient = PeerClient.new(".")
peerclient.port = 5555

link = "magnet:?xt=urn:btih:mq4oxed44vng7gq5mbpmwsyfk3kyvodd&tr=http://open.touki.ru/announce.php"

infohash = peerclient.addTorrentByMagnetURI MagnetURI.new(link)
peerclient.setUploadRateLimit infohash, 0 #prevent uploading

peerclient.start

while true do
  peerclient.torrentData.each do |infohash, torrent|
    name = torrent.recommendedName
    pct = 0
    if torrent.info
      pct = (torrent.completedBytes.to_f / torrent.info.dataLength.to_f * 100.0).round(2)
    end
    puts "#{name}: #{pct}%"
  end
  sleep 2
end

peerclient.stop
