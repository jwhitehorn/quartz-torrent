require 'quartz_torrent/util'
require 'quartz_torrent/filemanager'
require 'quartz_torrent/metainfo'
require "quartz_torrent/piecemanagerrequestmetadata.rb"
require "quartz_torrent/peerholder.rb"
require 'digest/sha1' 
require 'fileutils' 

# This class is used when we don't have the info struct for the torrent (no .torrent file) and must
# download it piece by piece from peers. It keeps track of the pieces we have.
#
# When a piece is requested from a peer and that peer responds with a reject saying it doesn't have
# that metainfo piece, we take a simple approach and mark that peer as bad, and don't request any more 
# pieces from that peer even though they may have other pieces. This simplifies the code.
module QuartzTorrent
  class MetainfoPieceState
    BlockSize = 16384
  
    # Create a new MetainfoPieceState that can be used to manage downloading the metainfo
    # for a torrent. The metainfo is stored in a file under baseDirectory named <infohash>.info,
    # where <infohash> is infoHash hex-encoded. The parameter metainfoSize should be the size of
    # the metainfo, and info can be used to pass in the complete metainfo Info object if it is available. This
    # is needed for when other peers request the metainfo from us.
    def initialize(baseDirectory, infoHash, metainfoSize = nil, info = nil)
 
      @logger = LogManager.getLogger("metainfo_piece_state")

      @requestTimeout = 5
      @baseDirectory = baseDirectory
      @infoFileName = MetainfoPieceState.generateInfoFileName(infoHash)

      path = infoFilePath

      completed = MetainfoPieceState.downloaded(baseDirectory, infoHash)
      metainfoSize = File.size(path) if ! metainfoSize && completed

      if !completed && info 
        File.open(path, "wb") do |file|
          bencoded = info.bencode
          metainfoSize = bencoded.length
          file.write bencoded
          # Sanity check
          testInfoHash = Digest::SHA1.digest( bencoded )
          raise "The computed infoHash #{QuartzTorrent.bytesToHex(testInfoHash)} doesn't match the original infoHash #{QuartzTorrent.bytesToHex(infoHash)}" if testInfoHash != infoHash
        end
      end

      raise "Unless the metainfo has already been successfully downloaded or the torrent file is available, the metainfoSize is needed" if ! metainfoSize

      # We use the PieceManager to manage the pieces of the metainfo file. The PieceManager is designed
      # for the pieces and blocks of actual torrent data, so we need to build a fake metainfo object that
      # describes our one metainfo file itself so that we can store the pieces if it on disk.
      # In this case we map metainfo pieces to 'torrent' pieces, and our blocks are the full length of the 
      # metainfo piece.
      torrinfo = Metainfo::Info.new
      torrinfo.pieceLen = BlockSize
      torrinfo.files = []
      torrinfo.files.push Metainfo::FileInfo.new(metainfoSize, @infoFileName)
    

      @pieceManager = PieceManager.new(baseDirectory, torrinfo)
      @pieceManagerRequests = {}

      @numPieces = metainfoSize/BlockSize
      @numPieces += 1 if (metainfoSize%BlockSize) != 0
      @completePieces = Bitfield.new(@numPieces)
      @completePieces.setAll if info || completed

      @lastPieceLength = metainfoSize - (@numPieces-1)*BlockSize
  
      @badPeers = PeerHolder.new
      @requestedPieces = Bitfield.new(@numPieces)
      @requestedPieces.clearAll

      @metainfoLength = metainfoSize

      # Time at which the piece in requestedPiece was requested. Used for timeouts.
      @pieceRequestTime = []
    end

    # Check if the metainfo has already been downloaded successfully during a previous session.
    # Returns the completed, Metainfo::Info object if it is complete, and nil otherwise.
    def self.downloaded(baseDirectory, infoHash)
      logger = LogManager.getLogger("metainfo_piece_state")
      infoFileName = generateInfoFileName(infoHash)
      path = "#{baseDirectory}#{File::SEPARATOR}#{infoFileName}"

      result = nil
      if File.exists?(path)
        File.open(path, "rb") do |file|
          bencoded = file.read
          # Sanity check
          testInfoHash = Digest::SHA1.digest( bencoded )
          if testInfoHash == infoHash
            result = Metainfo::Info.createFromBdecode(BEncode.load(bencoded, {:ignore_trailing_junk => 1})) 
          else
            logger.info "the computed SHA1 hash doesn't match the specified infoHash in #{path}"
          end
        end
      else
        logger.info "the metainfo file #{path} doesn't exist"
      end
      result
    end

    attr_accessor :infoFileName
    attr_accessor :metainfoLength

    # Return the number of bytes of the metainfo that we have downloaded so far.
    def metainfoCompletedLength
      num = @completePieces.countSet
      # Last block may be smaller
      extra = 0
      if @completePieces.set?(@completePieces.length-1)
        num -= 1
        extra = @lastPieceLength
      end
      num*BlockSize + extra
    end

    # Return true if the specified piece is completed. The piece is specified by index.
    def pieceCompleted?(pieceIndex)
      if pieceIndex >= 0 && pieceIndex < @completePieces.length
        @completePieces.set? pieceIndex
      else
        false
      end
    end

    # Do we have all the pieces of the metadata?
    def complete?
      @completePieces.allSet?
    end
  
    # Get the completed metainfo. Raises an exception if it's not yet complete.
    def completedMetainfo
      raise "Metadata is not yet complete" if ! complete?
    end

    # Save the specified piece to disk asynchronously.
    def savePiece(pieceIndex, data)
      id = @pieceManager.writeBlock pieceIndex, 0, data
      @pieceManagerRequests[id] = PieceManagerRequestMetadata.new(:write, pieceIndex)
      id
    end

    # Read a piece from disk. This method is asynchronous; it returns a handle that can be later
    # used to retreive the result.
    def readPiece(pieceIndex)
      length = BlockSize
      length = @lastPieceLength if pieceIndex == @numPieces - 1
      id = @pieceManager.readBlock pieceIndex, 0, length
      #result = manager.nextResult
      @pieceManagerRequests[id] = PieceManagerRequestMetadata.new(:read, pieceIndex)
      id
    end

    # Check the results of savePiece and readPiece. This method returns a list
    # of the PieceManager results.
    def checkResults
      results = []
      while true
        result = @pieceManager.nextResult
        break if ! result

        results.push result
          
        metaData = @pieceManagerRequests.delete(result.requestId)
        if ! metaData
          @logger.error "Can't find metadata for PieceManager request #{result.requestId}"
          next
        end 

        if metaData.type == :write
          if result.successful?
            @completePieces.set(metaData.data)
          else
            @requestedPieces.clear(metaData.data)
            @pieceRequestTime[metaData.data] = nil
            @logger.error "Writing metainfo piece failed: #{result.error}"
          end
        elsif metaData.type == :read
          if ! result.successful?
            @logger.error "Reading metainfo piece failed: #{result.error}"
          end
        end
      end
      results
    end

    # Return a list of torrent pieces that can still be requested. These are pieces that are not completed and are not requested.
    def findRequestablePieces
      piecesRequired = []

      removeOldRequests

      @numPieces.times do |pieceIndex|
        piecesRequired.push pieceIndex if ! @completePieces.set?(pieceIndex) && ! @requestedPieces.set?(pieceIndex)
      end

      piecesRequired
    end

    # Return a list of peers from whom we can request pieces. These are peers for whom we have an established connection, and 
    # are not marked as bad. See markPeerBad.
    def findRequestablePeers(classifiedPeers)
      result = []

      classifiedPeers.establishedPeers.each do |peer|
        result.push peer if ! @badPeers.findByAddr(peer.trackerPeer.ip, peer.trackerPeer.port)
      end

      result
    end

    # Set whether the piece with the passed pieceIndex is requested or not.
    def setPieceRequested(pieceIndex, bool)
      if bool
        @requestedPieces.set pieceIndex
        @pieceRequestTime[pieceIndex] = Time.new
      else
        @requestedPieces.clear pieceIndex
        @pieceRequestTime[pieceIndex] = nil
      end
    end

    # Mark the specified peer as 'bad'. We won't try requesting pieces from this peer. Used, for example, when
    # a peer rejects our request for a metadata piece. 
    def markPeerBad(peer)
      @badPeers.add peer
    end

    # Flush all pieces to disk
    def flush
      id = @pieceManager.flush
      @pieceManagerRequests[id] = PieceManagerRequestMetadata.new(:flush, nil)
      @pieceManager.wait
    end

    # Wait for the next a pending request to complete.
    def wait
      @pieceManager.wait
    end

    # Return the name of the file where this class will store the Torrent Info struct.
    def self.generateInfoFileName(infoHash)
      "#{QuartzTorrent.bytesToHex(infoHash)}.info"
    end

    # Remove the metainfo file
    def remove
      path = infoFilePath
      FileUtils.rm path
    end

    # Stop the underlying PieceManager.
    def stop
      @pieceManager.stop
    end

    private
    # Remove any pending requests after a timeout.
    def removeOldRequests
      now = Time.new
      @requestedPieces.length.times do |i|
        if @requestedPieces.set? i
          if now - @pieceRequestTime[i] > @requestTimeout
            @requestedPieces.clear i
            @pieceRequestTime[i] = nil
          end
        end
      end
    end

    def infoFilePath
      "#{@baseDirectory}#{File::SEPARATOR}#{@infoFileName}"
    end
  end
end
