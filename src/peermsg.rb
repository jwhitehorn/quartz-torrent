require './src/bitfield.rb'
module QuartzTorrent

  class PeerRequest
  end

  class PeerHandshake
    ProtocolName = "BitTorrent protocol"
    InfoHashLen = 20
    PeerIdLen = 20

    def initialize
      @infoHash = nil
      @peerId = nil
    end

    def peerId=(v)
      raise "PeerId is not #{PeerIdLen} bytes long" if v.length != PeerIdLen
      @peerId = v
    end

    def infoHash=(v)
      raise "InfoHash is not #{InfoHashLen} bytes long" if v.length != InfoHashLen
      @infoHash = v
    end

    attr_reader :peerId
    attr_reader :infoHash

    # Serialize this PeerHandshake message to the passed io object. Throws exceptions on failure.
    def serializeTo(io)
      raise "PeerId is not set" if ! @peerId
      raise "InfoHash is not set" if ! @infoHash
      result = [ProtocolName.length].pack("C")
      result << ProtocolName
      result << [0,0,0,0,0,0,0,0].pack("C8") # Reserved
      result << @infoHash
      result << @peerId
      
      io.write result
    end

    # Unserialize a PeerHandshake message from the passed io object and 
    # return it. Throws exceptions on failure.
    def self.unserializeFrom(io)
      result = PeerHandshake.new
      len = io.read(1).unpack("C")[0]
      proto = io.read(len)
      raise "Unrecognized peer protocol name '#{proto}'" if proto != ProtocolName
      io.read(8) # reserved
      result.infoHash = io.read(InfoHashLen)
      result.peerId = io.read(PeerIdLen)
      result
    end
  end

  # All messages other than handshake have a 4-byte length, 1-byte message id, and payload.
  class PeerWireMessage
    MessageChoke = 0
    MessageUnchoke = 1
    MessageInterested = 2
    MessageUninterested = 3
    MessageHave = 4
    MessageBitfield = 5
    MessageRequest = 6
    MessagePiece = 7
    MessageCancel = 8

    @@classForMessage = nil

    def initialize(messageId)
      @messageId = messageId
    end

    attr_reader :messageId

    def serializeTo(io)
      io.write [payloadLength+1].pack("N")
      io.write [@messageId].pack("C")
    end
  
    # Subclasses must implement this method. It should return an integer.
    def payloadLength
      raise "Subclasses of PeerWireMessage must implement payloadLength but #{self.class} didn't"
    end

    def self.unserializeFrom(io)
      length = io.read(4).unpack("N")[0]
      raise "Received peer message with length #{length}. All messages must have length >= 1" if length < 1
      id = io.read(1).unpack("C")[0]
      payload = io.read(length-1)

      raise "Unsupported peer message id #{id}" if id >= self.classForMessage.length

      result = self.classForMessage[id].new
      result.unserialize(payload)
      result
    end

    def unserialize(payload)
      raise "Subclasses of PeerWireMessage must implement unserialize but #{self.class} didn't"
    end

    def to_s
      "#{this.class} message"
    end

    private
    def self.classForMessage
      @@classForMessage = [Choke, Unchoke, Interested, Uninterested, Have, BitfieldMessage, Request, Piece, Cancel] if @@classForMessage.nil?
      @@classForMessage
    end
  end

  class Choke < PeerWireMessage
    def initialize
      super(MessageChoke)
    end
    def payloadLength
      0
    end

    def unserialize(payload)
    end
  end
  
  class Unchoke < PeerWireMessage
    def initialize
      super(MessageUnchoke)
    end
    def payloadLength
      0
    end
    def unserialize(payload)
    end
  end

  class Interested < PeerWireMessage
    def initialize
      super(MessageInterested)
    end
    def payloadLength
      0
    end
    def unserialize(payload)
    end
  end

  class Uninterested < PeerWireMessage
    def initialize
      super(MessageUninterested)
    end
    def payloadLength
      0
    end
    def unserialize(payload)
    end
  end

  class Have < PeerWireMessage
    def initialize
      super(MessageHave)
    end

    attr_accessor :peiceIndex
  
    def payloadLength
      4
    end

    def serializeTo(io)
      super(io)
      io.write [@peiceIndex].pack("N")
    end

    def unserialize(payload)
      @peiceIndex = payload.unpack["N"][0]
    end

    def to_s
      s = super
      s + ": peice index=#{@peiceIndex}"
    end
  end

  class BitfieldMessage < PeerWireMessage
    def initialize
      super(MessageBitfield)
    end

    attr_accessor :bitfield
  
    def payloadLength
      bitfield.byteLength
    end

    def serializeTo(io)
      super(io)
      io.write @bitfield.serialize
    end

    def unserialize(payload)
      @bitfield = Bitfield.new(0) if ! @bitfield
      @bitfield.unserialize(payload)
    end
  end
  
  class Request < PeerWireMessage
    def initialize
      super(MessageRequest)
    end

    attr_accessor :pieceIndex
    attr_accessor :blockOffset
    attr_accessor :blockLength

    def payloadLength
      12
    end

    def serializeTo(io)
      super(io)
      io.write [@pieceIndex, @blockOffset, @blockLength].pack("NNN")
    end

    def unserialize(payload)
      @pieceIndex, @blockOffset, @blockLength = payload.unpack("NNN")
    end

    def to_s
      s = super
      s + ": peice index=#{@peiceIndex}, block offset=#{@blockOffset}, block length=#{@blockLength}"
    end
  end
 
  class Piece < PeerWireMessage
    def initialize
      super(MessagePiece)
    end

    attr_accessor :pieceIndex
    attr_accessor :blockOffset
    attr_accessor :data

    def payloadLength
      8 + @data.length     
    end

    def serializeTo(io)
      super(io)
      io.write [@pieceIndex, @blockOffset, @data].pack("NNa*")
    end

    def unserialize(payload)
      @pieceIndex, @blockOffset, @data = payload.unpack("NNa*")
    end

    def to_s
      s = super
      s + ": peice index=#{@peiceIndex}, block offset=#{@blockOffset}"
    end
  end
 
  class Cancel < PeerWireMessage
    def initialize
      super(MessageCancel)
    end

    attr_accessor :pieceIndex
    attr_accessor :blockOffset
    attr_accessor :blockLength

    def payloadLength
      12
    end

    def serializeTo(io)
      super(io)
      io.write [@pieceIndex, @blockOffset, @blockLength].pack("NNN")
    end

    def unserialize(payload)
      @pieceIndex, @blockOffset, @blockLength = payload.unpack("NNN")
    end

    def to_s
      s = super
      s + ": peice index=#{@peiceIndex}, block offset=#{@blockOffset}, block length=#{@blockLength}"
    end
  end

end
