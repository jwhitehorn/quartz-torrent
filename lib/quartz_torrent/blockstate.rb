require 'quartz_torrent/util'
require 'quartz_torrent/bitfield'

module QuartzTorrent
 
  # Information representing a single block (a part of a piece) 
  class BlockInfo
    def initialize(pieceIndex, offset, length, peers, blockIndex)
      @pieceIndex = pieceIndex
      @offset = offset
      @length = length
      @peers = peers
      @blockIndex = blockIndex
    end
 
    # The index of the piece that this block belongs to. 
    attr_accessor :pieceIndex
    # Offset (in bytes) within the piece where the block begins.
    attr_accessor :offset
    # Length of the block in bytes.
    attr_accessor :length
    # A list of peers that have the piece this block belongs to. This block 
    # can be requested from these peers.
    attr_accessor :peers
    # Index of the block in units of the blockSize from the BlockState that created
    # this object.
    attr_accessor :blockIndex
  
    # Return a new Bittorrent Request message that requests this block.
    def getRequest
      m = Request.new
      m.pieceIndex = @pieceIndex
      m.blockOffset = @offset
      m.blockLength = @length
      m
    end

  end

  # Any given torrent is broken into pieces. Those pieces are broken into blocks.
  # This class can be used to keep track of which blocks are currently complete, which
  # have been requested but aren't available yet, and which are missing. 
  #
  # This class only supports one block size.
  class BlockState

    # Create a new BlockState. Parameter 'info' should be the Metainfo.info object
    # for the torrent, 'initialPieceBitfield' should be the already-existing pieces,
    # and 'blockSize' is the size of blocks.
    def initialize(info, initialPieceBitfield, blockSize = 16384)
      raise "Block size cannot be <= 0" if blockSize <= 0

      @logger = LogManager.getLogger("blockstate")
  
      @numPieces = initialPieceBitfield.length
      @pieceSize = info.pieceLen
      @numPieces = info.pieces.length
      @blocksPerPiece = (@pieceSize/blockSize + (@pieceSize%blockSize == 0 ? 0 : 1))
      @blockSize = blockSize
      # When calculating the number of blocks, the last piece is likely a partial piece...
      @numBlocks = @blocksPerPiece * (@numPieces-1)
      lastPieceLen = (info.dataLength - (@numPieces-1)*@pieceSize)
      @numBlocks += lastPieceLen / @blockSize
      @numBlocks += 1 if lastPieceLen % @blockSize != 0
      @lastBlockLength = (info.dataLength - (@numBlocks-1)*@blockSize)
      @totalLength = info.dataLength

      raise "Initial piece bitfield is the wrong length" if initialPieceBitfield.length != @numPieces
      raise "Piece size is not divisible by block size" if @pieceSize % blockSize != 0

      @completePieces = initialPieceBitfield
      @completeBlocks = Bitfield.new(@numBlocks)
      blockIndex = 0
      initialPieceBitfield.length.times do |pieceIndex|
        isSet = initialPieceBitfield.set?(pieceIndex)
        @blocksPerPiece.times do 
          # The last piece may be a smaller number of blocks.
          break if blockIndex >= @completeBlocks.length

          if isSet
            @completeBlocks.set blockIndex
          else
            @completeBlocks.clear blockIndex
          end
          blockIndex += 1
        end       
      end

      @requestedBlocks = Bitfield.new(@numBlocks)
      @requestedBlocks.clearAll
      @currentPieces = []
    end
 
    # Get the block size
    attr_reader :blockSize

    # Total length of the torrent in bytes.
    attr_reader :totalLength

    # Return a list of BlockInfo objects representing blocjs that should be requested from peers.
    def findRequestableBlocks(classifiedPeers, numToReturn = nil)
      # Have a list of the current pieces we are working on. Each time this method is 
      # called, check the blocks in the pieces in list order to find the blocks to return
      # for requesting. If a piece is completed, remove it from this list. If we need more blocks
      # than there are available in the list, add more pieces to the end of the list (in rarest-first
      # order).
      result = []

      # Update requestable peers to only be those that we can still request pieces from.
      peersHavingPiece = computePeersHavingPiece(classifiedPeers)
      requestable = @completeBlocks.union(@requestedBlocks).compliment!
      rarityOrder = nil

      currentPiece = 0
      while true
        if currentPiece >= @currentPieces.length
          # Add more pieces in rarest-first order. If there are no more pieces, break.
          rarityOrder = computeRarity(classifiedPeers) if ! rarityOrder
          added = false
          rarityOrder.each do |pair|
            pieceIndex = pair[1]
            peersWithPiece = peersHavingPiece[pieceIndex]
            if peersWithPiece && peersWithPiece.size > 0 && !@currentPieces.index(pieceIndex) && ! pieceCompleted?(pieceIndex)
              @logger.debug "Adding piece #{pieceIndex} to the current downloading list"
              @currentPieces.push pieceIndex
              added = true
              break
            end
          end
          if ! added          
            @logger.debug "There are no more pieces to add to the current downloading list"
            break
          end
        end        
    
        currentPieceIndex = @currentPieces[currentPiece]

        if pieceCompleted?(currentPieceIndex)
          @logger.debug "Piece #{currentPieceIndex} complete so removing it from the current downloading list" 
          @currentPieces.delete_at(currentPiece)
          next
        end

        peersWithPiece = peersHavingPiece[currentPieceIndex]
        if !peersWithPiece || peersWithPiece.size == 0
          @logger.debug "No peers have piece #{currentPieceIndex}" 
          currentPiece += 1
          next
        end

        eachBlockInPiece(currentPieceIndex) do |blockIndex|
          if requestable.set?(blockIndex)
            result.push createBlockinfoByPieceAndBlockIndex(currentPieceIndex, peersWithPiece, blockIndex)
            break if numToReturn && result.size >= numToReturn
          end
        end           

        break if numToReturn && result.size >= numToReturn
        currentPiece += 1
      end

      result
    end

    # Set whether the block represented by the passed BlockInfo is requested or not.
    def setBlockRequested(blockInfo, bool)
      if bool
        @requestedBlocks.set blockInfo.blockIndex
      else
        @requestedBlocks.clear blockInfo.blockIndex
      end
    end

    # Mark a block as completed. If clearRequested is :clear_requested, then the block is also marked
    # as no longer requested. If this block completes the piece and a block is passed, the pieceIndex 
    # is yielded to the block.
    def setBlockCompleted(pieceIndex, blockOffset, bool, clearRequested = :clear_requested)
      bi = blockIndexFromPieceAndOffset(pieceIndex, blockOffset)
      @requestedBlocks.clear bi if clearRequested == :clear_requested
      if bool
        @completeBlocks.set bi
        if allBlocksInPieceCompleted?(pieceIndex)
          yield pieceIndex if block_given?
          @completePieces.set pieceIndex
        end
      else
        @completeBlocks.clear bi
        @completePieces.clear pieceIndex
      end
    end

    # Is the specified block completed (downloaded)?
    def blockCompleted?(blockInfo)
      @completeBlocks.set? blockInfo.blockIndex
    end

    # Set whether the piece is completed or not.
    def setPieceCompleted(pieceIndex, bool)
      eachBlockInPiece(pieceIndex) do |blockIndex|
        if bool
          @completeBlocks.set blockIndex
        else
          @completeBlocks.clear blockIndex
        end
      end
      if bool
        @completePieces.set pieceIndex
      else
        @completePieces.clear pieceIndex
      end
    end

    # Is the specified piece completed (all blocks are downloaded)?
    def pieceCompleted?(pieceIndex)
      @completePieces.set? pieceIndex
    end

    # Get a bitfield representing the completed pieces.
    def completePieceBitfield
      result = Bitfield.new(@numPieces)
      result.copyFrom(@completePieces)
      result
    end

    # Get a bitfield representing the completed pieces.
    def completeBlockBitfield
      result = Bitfield.new(@numBlocks)
      result.copyFrom(@completeBlocks)
      result
    end

    # Number of bytes we have downloaded and verified.
    def completedLength
      num = @completeBlocks.countSet
      # Last block may be smaller
      extra = 0
      if @completeBlocks.set?(@completeBlocks.length-1)
        num -= 1
        extra = @lastBlockLength
      end
      num*@blockSize + extra
    end

    # Create a new BlockInfo object using the specified information. The peers list is empty.
    def createBlockinfoByPieceResponse(pieceIndex, offset, length)
      blockIndex = pieceIndex*@blocksPerPiece + offset/@blockSize
      raise "offset in piece is not divisible by block size" if offset % @blockSize != 0
      BlockInfo.new(pieceIndex, offset, length, [], blockIndex)
    end

    # Create a new BlockInfo object using the specified information. The peers list is empty.
    def createBlockinfoByBlockIndex(blockIndex)
      pieceIndex = blockIndex / @blockSize
      offset = (blockIndex % @blocksPerPiece)*@blockSize
      length = @blockSize
      raise "offset in piece is not divisible by block size" if offset % @blockSize != 0
      BlockInfo.new(pieceIndex, offset, length, [], blockIndex)
    end

    # Create a new BlockInfo object using the specified information. 
    def createBlockinfoByPieceAndBlockIndex(pieceIndex, peersWithPiece, blockIndex)
      # If this is the very last block, then it might be smaller than the rest.
      blockSize = @blockSize
      blockSize = @lastBlockLength if blockIndex == @numBlocks-1
      offsetWithinPiece = (blockIndex % @blocksPerPiece)*@blockSize
      BlockInfo.new(pieceIndex, offsetWithinPiece, blockSize, peersWithPiece, blockIndex)
    end

    private
    # Yield to a block each block index in a piece.
    def eachBlockInPiece(pieceIndex)
      (pieceIndex*@blocksPerPiece).upto(pieceIndex*@blocksPerPiece+@blocksPerPiece-1) do |blockIndex|
        break if blockIndex >= @numBlocks
        yield blockIndex
      end
    end

    def allBlocksInPieceCompleted?(pieceIndex)
      complete = true
      eachBlockInPiece(pieceIndex) do |blockIndex|
        if ! @completeBlocks.set?(blockIndex)
          complete = false
          break
        end
      end 

      complete
    end

    def blockIndexFromPieceAndOffset(pieceIndex, blockOffset)
      pieceIndex*@blocksPerPiece + blockOffset/@blockSize
    end

    # Return an array indexed by piece index where each element
    # is a list of peers with that piece.
    def computePeersHavingPiece(classifiedPeers)
      # Make a list of each peer having the specified piece
      peersHavingPiece = Array.new(@numPieces)
      # This first list represents rarity by number if peers having that piece. 1 = rarest.
      classifiedPeers.requestablePeers.each do |peer|
        @numPieces.times do |i|
          if peer.bitfield.set?(i)
            if peersHavingPiece[i]
              peersHavingPiece[i].push peer
            else
              peersHavingPiece[i] = [peer]
            end
          end
        end
      end
      peersHavingPiece
    end
    
    # Compute an array representing the relative rarity of each piece of the torrent.
    # The returned array has one entry for each piece of the torrent. Each entry is a two-element
    # array where the first element is the rarity of the piece where lower is more rare (i.e. 0 is rarest 
    # and represents 0 peers with that piece), and the second element in the entry is the piece index.
    # The returned array is sorted in order of ascending rarity value (rarest is first), but within each
    # class of the same rarity value the piece indices are randomized. For example, rarity 1 elements are
    # all before rarity 2 elements, but the piece indices with rarity 1 are in a random order.
    def computeRarity(classifiedPeers)
      # 1. Make a list of the rarity of pieces.
      rarity = Array.new(@numPieces,0)
      # This first list represents rarity by number if peers having that piece. 1 = rarest.
      classifiedPeers.requestablePeers.each do |peer|
        @numPieces.times do |i|
          rarity[i] += 1 if peer.bitfield.set?(i)
        end
      end

      # 2. Make a new list that indexes the first list by order of descending rarity.
      rarityOrder = Array.new(@numPieces)
      # The elements of this second list are pairs. The first element in the pair is the rarity, second is the piece index.
      @numPieces.times do |i|
        rarityOrder[i] = [rarity[i],i]
      end
      rarityOrder.sort!{ |a,b| a[0] <=> b[0] }

      # 3. Randomize the list order within classes of the same rarity.
      left = 0
      leftVal = rarityOrder[left][0]
      @numPieces.times do |i|
        if rarityOrder[i][0] != leftVal
          # New range
          rangeLen = i-left+1
          
          QuartzTorrent.arrayShuffleRange!(rarityOrder, left, rangeLen)

          left = i+1
          leftVal = rarityOrder[left][0] if left < @numPieces
        end
      end
      QuartzTorrent.arrayShuffleRange!(rarityOrder, left, @numPieces-left) if left < @numPieces
      
      rarityOrder
    end  

  end
  
end

