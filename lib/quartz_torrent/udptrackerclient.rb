module QuartzTorrent
  # A tracker client that uses the UDP protocol as defined by http://xbtt.sourceforge.net/udp_tracker_protocol.html
  class UdpTrackerClient < TrackerClient
    # Set UDP receive length to a value that allows up to 100 peers to be returned in an announce.
    ReceiveLength = 620 
    def initialize(announceUrl, infoHash, dataLength, timeout = 2)
      super(announceUrl, infoHash, dataLength)
      @timeout = timeout
      @logger = LogManager.getLogger("udp_tracker_client")
      if @announceUrl =~ /udp:\/\/([^:]+):(\d+)/
        @host = $1
        @trackerPort = $2
      else
        throw "UDP Tracker announce URL is invalid: #{announceUrl}"
      end
    end

    def request(event = nil)
      if event == :started
        event = UdpTrackerMessage::EventStarted
      elsif event == :stopped
        event = UdpTrackerMessage::EventStopped
      elsif event == :completed
        event = UdpTrackerMessage::EventCompleted
      else
        event = UdpTrackerMessage::EventNone
      end

      begin
        socket = UDPSocket.new
        socket.connect @host, @trackerPort

        @logger.debug "Sending UDP tracker request to #{@host}:#{@trackerPort}"

        # Send connect request
        req = UdpTrackerConnectRequest.new
        socket.send req.serialize, 0
        resp = UdpTrackerConnectResponse.unserialize(readWithTimeout(socket,ReceiveLength,@timeout))
        raise "Invalid connect response: response transaction id is different from the request transaction id" if resp.transactionId != req.transactionId
        connectionId = resp.connectionId

        dynamicParams = @dynamicRequestParamsBuilder.call

        # Send announce request      
        req = UdpTrackerAnnounceRequest.new(connectionId)
        req.peerId = @peerId
        req.infoHash = @infoHash
        req.downloaded = dynamicParams.downloaded
        req.left = dynamicParams.left
        req.uploaded = dynamicParams.uploaded
        req.event = event
        #req.port = socket.addr[1]
        req.port = @port
        socket.send req.serialize, 0
        resp = UdpTrackerAnnounceResponse.unserialize(readWithTimeout(socket,ReceiveLength,@timeout))
        socket.close

        peers = []
        resp.ips.length.times do |i|
          ip = resp.ips[i].unpack("CCCC").join('.')
          port = resp.ports[i].unpack("n").first
          peers.push TrackerPeer.new ip, port
        end
        peers

        result = TrackerResponse.new(true, nil, peers)
        result.interval = resp.interval if resp.interval
        result
      rescue
        TrackerResponse.new(false, $!, [])
      end
    end
  end

  private
  # Throws exception if timeout occurs
  def readWithTimeout(socket, length, timeout)
    rc = IO.select([socket], nil, nil, timeout)
    if ! rc
      raise "Waiting for response from UDP tracker #{@host}:#{@trackerPort} timed out after #{@timeout} seconds"
    elsif rc[0].size > 0
      socket.recvfrom(length)[0]
    else
      raise "Error receiving response from UDP tracker #{@host}:#{@trackerPort}"
    end
  end

end
